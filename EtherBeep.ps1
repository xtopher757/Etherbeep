#Requires -Version 5.1
<#
.SYNOPSIS
    EtherBeep - beep the instant the unit answers 3 consecutive pings.

.DESCRIPTION
    Tiny bench companion: docks in a screen corner and pings the unit gateway
    (192.168.0.1) with in-process .NET pings (no ping.exe spawn, 250ms timeout,
    ~1ms LAN RTTs). Three CONSECUTIVE successes -> a rising two-tone beep, so
    the operator hears the unit come alive without watching any window - well
    before speedWATCH's next poll. After the beep it watches quietly (~1s
    cadence) and re-arms after 4 consecutive failures (cable pulled / unit
    swapped), ready to beep for the next unit. Ctrl+C to stop.

    Speed notes: the hot loop is pure .NET Ping - zero CIM/adapter calls, zero
    process spawns. Worst-case beep latency after the unit first answers is one
    armed-gap (200ms) + 3 RTTs. .NET Ping cannot source-bind like ping.exe -S;
    that is safe here because only the USB adapter carries a directly-connected
    192.168.0.0/24 route (a one-time startup check warns if that's ambiguous).
#>
[CmdletBinding()]
param(
    [string] $Target = "192.168.0.1",
    [ValidateRange(1, 10)]  [int] $Required = 3,     # consecutive successes to beep
    [ValidateRange(50, 2000)] [int] $TimeoutMs = 250,
    [ValidateRange(0, 2000)]  [int] $ArmedGapMs = 200, # gap between probes while waiting
    [ValidateRange(1, 20)]  [int] $DownFails = 4,    # consecutive failures to re-arm
    [ValidateSet("topright","topleft","bottomright","bottomleft")]
    [string] $Corner = "bottomleft",   # APN watcher owns topright by default
    [switch] $NoLayout
)
Set-StrictMode -Version Latest

function Set-CornerWindow {
    # Shrink this console to a small box and dock it in a screen corner. Same
    # title-stamp + FindWindow approach as tools/Watch-ForcedApn.ps1 (works
    # under conhost AND Windows Terminal). Best-effort - failures are silent.
    param([string] $Corner = "bottomleft", [int] $W = 420, [int] $H = 260)
    try {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class EtherBeepWin32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr h, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string c, string w);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr h, uint f);
}
"@
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = if ($Corner -like "*left*")  { $wa.Left } else { $wa.Right  - $W }
        $y = if ($Corner -like "bottom*") { $wa.Bottom - $H } else { $wa.Top }

        $fg  = [EtherBeepWin32]::GetForegroundWindow()
        $tag = "etherbeep_$PID"
        try { [console]::Title = $tag } catch { }
        Start-Sleep -Milliseconds 200
        $hwnd = [EtherBeepWin32]::FindWindow($null, $tag)
        if ($hwnd -eq [IntPtr]::Zero -and $fg -ne [IntPtr]::Zero) { $hwnd = $fg }
        if ($hwnd -eq [IntPtr]::Zero) {
            $cw = [EtherBeepWin32]::GetConsoleWindow()
            if ($cw -ne [IntPtr]::Zero) { $hwnd = [EtherBeepWin32]::GetAncestor($cw, 3) }  # GA_ROOTOWNER
        }
        try { [console]::Title = "EtherBeep  $Target" } catch { }
        if ($hwnd -ne [IntPtr]::Zero) {
            $null = [EtherBeepWin32]::ShowWindow($hwnd, 9)   # SW_RESTORE
            Start-Sleep -Milliseconds 100
            $null = [EtherBeepWin32]::SetWindowPos($hwnd, [IntPtr]::new(-1), [int]$x, [int]$y, $W, $H, 0x0040)
        }
    } catch { }
    try {
        $ui   = $Host.UI.RawUI
        $cols = 46; $rows = 12
        $win = $ui.WindowSize;  $win.Width = $cols; $win.Height = $rows; $ui.WindowSize = $win
        $buf = $ui.BufferSize;  $buf.Width = $cols; $buf.Height = 300;   $ui.BufferSize = $buf
        $win = $ui.WindowSize;  $win.Width = $cols; $win.Height = $rows; $ui.WindowSize = $win
    } catch { }
}

if (-not $NoLayout) { Set-CornerWindow -Corner $Corner }

Write-Host "EtherBeep  target=$Target  ($Required pings)" -ForegroundColor Cyan

# One-time route sanity check (slow CIM is fine ONCE, never in the hot loop):
# .NET Ping can't source-bind, so warn if the target's subnet is ambiguous.
try {
    $tPrefix = ($Target -split '\.')[0..2] -join '.'
    $ifs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$tPrefix.*" -and $_.IPAddress -ne $Target })
    if ($ifs.Count -gt 1) {
        Write-Host "warn: $($ifs.Count) interfaces on $tPrefix.x - pings may leave the wrong NIC" -ForegroundColor Yellow
    }
} catch { }

$pinger  = New-Object System.Net.NetworkInformation.Ping
$streak  = 0
$fails   = 0
$state   = "armed"           # armed | up
$upSince = $null
$lastHb  = Get-Date
Write-Host "waiting for unit ($Target)..." -ForegroundColor Gray

while ($true) {
    $ok = $false
    $rtt = 0
    try {
        $r = $pinger.Send($Target, $TimeoutMs)
        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $ok = $true; $rtt = [int]$r.RoundtripTime
        }
    } catch { }   # unreachable/no-route throws on some stacks - treat as fail

    if ($state -eq "armed") {
        if ($ok) {
            $streak++
            if ($streak -ge $Required) {
                # The beep IS the product - fire it before printing anything.
                try { [console]::beep(1175, 100); [console]::beep(1568, 140) } catch { }
                Write-Host ("{0} UP - beeped ({1}/{1}, {2}ms)" -f (Get-Date -Format "HH:mm:ss"), $Required, $rtt) -ForegroundColor Green
                $state = "up"; $upSince = Get-Date; $fails = 0; $lastHb = Get-Date
            }
            # streak in progress: no gap - fire the next ping immediately
        } else {
            $streak = 0
            Start-Sleep -Milliseconds $ArmedGapMs
        }
    } else {
        # UP: watch lazily for the unplug; re-arm after DownFails consecutive misses.
        if ($ok) {
            $fails = 0
            if (((Get-Date) - $lastHb).TotalSeconds -ge 60) {
                $mins = [int]((Get-Date) - $upSince).TotalMinutes
                Write-Host ("{0} still up ({1}m)" -f (Get-Date -Format "HH:mm:ss"), $mins) -ForegroundColor DarkGray
                $lastHb = Get-Date
            }
        } else {
            $fails++
            if ($fails -ge $DownFails) {
                Write-Host ("{0} down - re-armed" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Yellow
                $state = "armed"; $streak = 0
                continue   # skip the up-state sleep; hunt at armed cadence now
            }
        }
        Start-Sleep -Milliseconds 1000
    }
}
