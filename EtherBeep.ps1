#Requires -Version 5.1
<#
.SYNOPSIS
    EtherBeep - port sweep: beep the instant each port answers 3 pings.

.DESCRIPTION
    Tiny bench companion: docks in a screen corner and pings the unit gateway
    (192.168.0.1) with in-process .NET pings (no ping.exe spawn, 250ms timeout,
    ~1ms LAN RTTs). Three CONSECUTIVE successes -> a two-tone beep, so the
    operator hears the port come alive without watching any window - well
    before speedWATCH's next poll.

    Built for sweeping the unit's ports with ONE cable: move the cable to the
    next port and EtherBeep re-arms in ~100ms, so the only wait left is the
    cable's own link negotiation. Each port beeps a step higher in pitch (port
    1 lowest, port 4 highest) and a three-note chord marks the last port, so
    the operator can run a whole unit by ear without looking. The counter then
    resets for the next unit. Ctrl+C to stop.

    Speed notes: the hot loop is pure .NET Ping - zero CIM/adapter calls, zero
    process spawns. All four ports answer on the same IP, so ARP stays warm
    across the swap. When the cable is out the interface has no route and
    .NET Ping fails instantly rather than burning TimeoutMs, which is what
    makes the re-arm cheap; the per-port timing printed after each beep is
    measured from the unplug, so it shows the true cycle cost. .NET Ping
    cannot source-bind like ping.exe -S; that is safe here because only the
    USB adapter carries a directly-connected 192.168.0.0/24 route (a one-time
    startup check warns if that's ambiguous).

    The floor is physical, not in this script: copper autonegotiation takes
    ~1-2s on gigabit before any ping can succeed. Forcing the test adapter to
    100M full-duplex cuts that substantially if the unit supports it.
#>
[CmdletBinding()]
param(
    [string] $Target = "192.168.0.1",
    [ValidateRange(1, 24)]  [int] $Ports = 4,        # ports per unit; chord + reset after the last
    [ValidateRange(1, 10)]  [int] $Required = 3,     # consecutive successes to beep
    [ValidateRange(50, 2000)] [int] $TimeoutMs = 250,
    [ValidateRange(0, 2000)]  [int] $ArmedGapMs = 50,  # gap between probes while waiting
    [ValidateRange(0, 2000)]  [int] $UpGapMs = 50,   # gap between probes while up (unplug watch)
    [ValidateRange(1, 20)]  [int] $DownFails = 3,    # consecutive failures to re-arm
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

function Invoke-PortBeep {
    # One two-tone beep, pitched by port number so the operator can tell ports
    # apart by ear alone: port 1 lowest, each subsequent port a step higher.
    # [console]::beep BLOCKS for its duration - only ever called after a port
    # is confirmed up, never while hunting, so it costs no detection latency.
    param([int] $Port)
    $f1 = [int](784 * [Math]::Pow(1.26, ($Port - 1)))
    if ($f1 -gt 12000) { $f1 = 12000 }
    $f2 = [int]($f1 * 1.335)
    try { [console]::beep($f1, 80); [console]::beep($f2, 110) } catch { }
}

function Invoke-UnitBeep {
    # Distinct rising chord: the last port of a unit is done, counter resets.
    try { [console]::beep(1047, 90); [console]::beep(1319, 90); [console]::beep(1568, 130) } catch { }
}

if (-not $NoLayout) { Set-CornerWindow -Corner $Corner }

Write-Host "EtherBeep  target=$Target  ($Ports ports, $Required pings)" -ForegroundColor Cyan

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
$port    = 0                 # ports confirmed on the unit currently under test
$armedAt = Get-Date          # when the hunt for the current port began
$downAt  = $null             # first missed ping of the current unplug
$lastHb  = Get-Date
Write-Host "waiting for port 1/$Ports ($Target)..." -ForegroundColor Gray

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
                $port++
                Invoke-PortBeep -Port $port
                $ms = [int]((Get-Date) - $armedAt).TotalMilliseconds
                Write-Host ("{0} port {1}/{2} UP  ({3}ms, {4}ms rtt)" -f `
                    (Get-Date -Format "HH:mm:ss"), $port, $Ports, $ms, $rtt) -ForegroundColor Green
                if ($port -ge $Ports) {
                    Invoke-UnitBeep
                    Write-Host ("{0} unit done - {1}/{1} ports" -f (Get-Date -Format "HH:mm:ss"), $Ports) -ForegroundColor Cyan
                    $port = 0
                }
                $state = "up"; $fails = 0; $lastHb = Get-Date
            }
            # streak in progress: no gap - fire the next ping immediately
        } else {
            $streak = 0
            if (((Get-Date) - $lastHb).TotalSeconds -ge 5) {
                $secs = [int]((Get-Date) - $armedAt).TotalSeconds
                Write-Host ("{0} waiting port {1}/{2} ({3}s)" -f `
                    (Get-Date -Format "HH:mm:ss"), ($port + 1), $Ports, $secs) -ForegroundColor DarkGray
                $lastHb = Get-Date
            }
            Start-Sleep -Milliseconds $ArmedGapMs
        }
    } else {
        # UP: the operator is about to yank the cable for the next port, so
        # watch at a tight cadence - this gap, not the ping, is what sets the
        # port-to-port turnaround. With the cable out the interface has no
        # route and each Send fails instantly, so re-arm lands in roughly
        # (DownFails - 1) * UpGapMs.
        if ($ok) {
            $fails = 0
            $downAt = $null
            if (((Get-Date) - $lastHb).TotalSeconds -ge 60) {
                Write-Host ("{0} still up on port {1}" -f `
                    (Get-Date -Format "HH:mm:ss"), $(if ($port -eq 0) { $Ports } else { $port })) -ForegroundColor DarkGray
                $lastHb = Get-Date
            }
        } else {
            $fails++
            if ($fails -eq 1) { $downAt = Get-Date }   # first miss = the cable actually left
            if ($fails -ge $DownFails) {
                $state = "armed"; $streak = 0
                # Time the port from the first miss, not from the re-arm, so the
                # figure printed after the next beep is the whole cable-to-beep
                # cost and not just the part after we made our minds up.
                $armedAt = $downAt; $lastHb = Get-Date
                continue   # skip the up-state sleep; hunt at armed cadence now
            }
        }
        Start-Sleep -Milliseconds $UpGapMs
    }
}
