#Requires -Version 5.1
<#
.SYNOPSIS
    EtherBeep - port sweep: beep the instant a port answers 3 pings.

.DESCRIPTION
    Tiny bench companion: docks in a screen corner and pings the unit gateway
    (192.168.0.1) with in-process .NET pings (no ping.exe spawn, 250ms timeout,
    ~1ms LAN RTTs). Three CONSECUTIVE successes -> a short rising beep, so the
    operator hears the port come alive without watching any window - well
    before speedWATCH's next poll.

    Built for sweeping a unit's ports with ONE cable: move the cable to the
    next port and EtherBeep re-arms in ~100ms, so the only wait left is the
    cable's own link negotiation. Ctrl+C to stop.

    The log is fixed-width columns - time, a 2-char state marker, cycle,
    rtt - not free text, so cycle times compare down the page without
    re-reading each line. Layout from the "1a Aligned tape" console design
    (Claude Design handoff, EtherBeep Console.dc.html).

    Ports are deliberately not counted, so 2-port and 4-port units run the
    same script. A counter only stays honest if every port is tried exactly
    once in order - one dead port or one re-test shifts it, and it then
    reports the wrong port as passing. One beep = one port answered.

    Speed notes: the hot loop is pure .NET Ping - zero CIM/adapter calls, zero
    process spawns. Every port answers on the same IP, so ARP stays warm
    across the swap. When the cable is out the interface has no route and
    .NET Ping fails instantly rather than burning TimeoutMs, which is what
    makes the re-arm cheap; the per-port timing printed after each beep is
    measured from the unplug, so it shows the true cycle cost. .NET Ping
    cannot source-bind like ping.exe -S; that is safe here because only the
    USB adapter carries a directly-connected 192.168.0.0/24 route (a one-time
    startup check warns if that's ambiguous).

    The remaining wait is physical: copper autonegotiation takes ~1-2s on
    gigabit before any ping can succeed, which is why EtherBeep pins the test
    adapter to 100M full-duplex when it has admin, and puts it back on exit.

    After StandbyMin idle minutes it drops to a StandbyGapMs poll and wakes on
    the first ping that changes - a unit left plugged in overnight is
    otherwise 20 pings a second until morning.

    The beep is pitched high and repeats BeepReps times (2 by default) so it
    carries over shop noise - motors, compressors, air tools are mostly
    low/mid frequency, and Console.Beep has no volume control, so pitch and
    repetition are the only levers against a noisy room.
#>
[CmdletBinding()]
param(
    [string] $Target = "192.168.0.1",
    [ValidateRange(1, 10)]  [int] $Required = 3,     # consecutive successes to beep
    [ValidateRange(50, 2000)] [int] $TimeoutMs = 250,
    [ValidateRange(0, 2000)]  [int] $ArmedGapMs = 50,  # gap between probes while waiting
    [ValidateRange(0, 2000)]  [int] $UpGapMs = 50,   # gap between probes while up (unplug watch)
    [ValidateRange(1, 20)]  [int] $DownFails = 3,    # consecutive failures to re-arm
    [ValidateRange(0, 1440)] [int] $StandbyMin = 60, # idle minutes before standby (0 = never)
    [ValidateRange(100, 30000)] [int] $StandbyGapMs = 2000,
    [ValidateRange(1, 5)]  [int] $BeepReps = 2,       # times to repeat the beep - shop noise insurance
    [ValidateSet("topright","topleft","bottomright","bottomleft")]
    [string] $Corner = "bottomleft",   # APN watcher owns topright by default
    [switch] $NoLayout,
    [switch] $NoForce100                # leave the adapter's speed/duplex alone
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
    # The port is up. Rising fifth, G6 -> D7: pitched high on purpose - shop
    # noise (motors, compressors, air tools) is mostly low/mid frequency, and
    # this sits above most of it. [console]::beep has no volume control - it
    # plays at whatever the PC speaker or default output device is already
    # set to - so pitch and repetition are the only real levers against a
    # noisy room. -BeepReps repeats the whole phrase (default 2): redundancy
    # gives the ear a second chance to catch it against a transient clatter,
    # which does more for "was that heard" than a single longer tone would.
    # [console]::beep BLOCKS for its duration - only ever called after a port
    # is confirmed up, never while hunting, so it costs no detection latency.
    for ($n = 0; $n -lt $script:BeepReps; $n++) {
        try { [console]::beep(1568, 55); [console]::beep(2349, 70) } catch { }
        if ($n -lt $script:BeepReps - 1) { Start-Sleep -Milliseconds 60 }
    }
}

function Format-Since {
    # The per-port figure is only a cycle time when it actually was a cycle.
    # If the cable sat unplugged over lunch, printing "3841207ms" dressed up as
    # a swap measurement would be nonsense - say what it really was. Below 10s
    # it's a real cycle either way, just switch units at 1s so a 1900ms link
    # negotiation reads as "1.9s" instead of a wall of digits.
    param([double] $Ms)
    if ($Ms -lt 1000)  { return ("{0}ms" -f [int]$Ms) }
    if ($Ms -lt 10000) { return ("{0:0.0}s" -f ($Ms / 1000)) }
    if ($Ms -lt 90000) { return ("after {0}s" -f [int]($Ms / 1000)) }
    return ("after {0}m" -f [int]($Ms / 60000))
}

function Write-Log {
    # Every log line shares one column layout: HH:mm:ss, 2 spaces, a 2-char
    # state marker ("UP" or the ambient placeholder "··"), 4 spaces, then
    # free text. Centralized so the spacing can't drift between the five
    # call sites that use it - this exact layout is the point of the design.
    param([string] $State, [string] $Text, [string] $Color = "DarkGray")
    Write-Host ("{0}  {1}    {2}" -f (Get-Date -Format "HH:mm:ss"), $State, $Text) -ForegroundColor $Color
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Set-Link100 {
    # Pin the test adapter to 100M full-duplex. Gigabit autonegotiation is
    # ~1-2s per cable move and dominates the entire sweep - 100M skips most of
    # that cycle. Needs admin, bounces the link, so: startup only, never in the
    # hot loop.
    #
    # Speed/duplex is a driver advanced property and both its name and its
    # values differ per vendor ("100 Mbps Full Duplex", "100Mb Full", ...), so
    # match on the standard NDIS keyword and pick the value out of what the
    # driver actually declares rather than guessing a string.
    #
    # No Write-Host here on purpose: the caller renders exactly one header
    # line from the result, so this returns data, not console output.
    # Applied: link is (now) at 100M. Prior: previous DisplayValue to restore
    # on exit, or $null if nothing changed. Reason: why we didn't, when not
    # Applied.
    param([string] $NicName)
    $prop = Get-NetAdapterAdvancedProperty -Name $NicName -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -eq '*SpeedDuplex' } | Select-Object -First 1
    if (-not $prop) {
        return [pscustomobject]@{ Applied = $false; Prior = $null; Reason = "100M unsupported" }
    }
    # (?<!\d)100(?!\d) so "1000 Mbps Full Duplex" cannot match as "100".
    $want = @($prop.ValidDisplayValues) |
        Where-Object { $_ -match '(?<!\d)100(?!\d)' -and $_ -match '(?i)full' } | Select-Object -First 1
    if (-not $want) {
        return [pscustomobject]@{ Applied = $false; Prior = $null; Reason = "100M unsupported" }
    }
    $was = $prop.DisplayValue
    if ($was -eq $want) {
        return [pscustomobject]@{ Applied = $true; Prior = $null; Reason = $null }   # already there
    }
    try {
        Set-NetAdapterAdvancedProperty -Name $NicName -RegistryKeyword '*SpeedDuplex' `
            -DisplayValue $want -ErrorAction Stop
        return [pscustomobject]@{ Applied = $true; Prior = $was; Reason = $null }
    } catch {
        return [pscustomobject]@{ Applied = $false; Prior = $null; Reason = "100M failed" }
    }
}

function Restore-Link {
    param([string] $NicName, [string] $Was)
    if (-not $Was) { return }
    try {
        Set-NetAdapterAdvancedProperty -Name $NicName -RegistryKeyword '*SpeedDuplex' `
            -DisplayValue $Was -ErrorAction Stop
        Write-Host "link: restored to $Was" -ForegroundColor DarkGray
    } catch {
        # Worth shouting about: leaving a coworker's NIC pinned at 100M is the
        # kind of thing that gets debugged three weeks later.
        Write-Host "warn: could not restore speed/duplex - set it back with:" -ForegroundColor Yellow
        Write-Host "  Set-NetAdapterAdvancedProperty -Name '$NicName' -RegistryKeyword '*SpeedDuplex' -DisplayValue '$Was'" -ForegroundColor Yellow
    }
}

if (-not $NoLayout) { Set-CornerWindow -Corner $Corner }

# One-time startup work (slow CIM is fine ONCE, never in the hot loop): find
# the NIC on the target's subnet - warn if that's ambiguous, since .NET Ping
# can't source-bind - and pin it to 100M to cut autonegotiation out of every
# swap. Resolved before any header line prints, so the header's link/note
# line always reflects what actually happened, not what was attempted.
$nicName = $null
$linkWas = $null
$linkApplied = $false
$linkReason  = $null
try {
    $tPrefix = ($Target -split '\.')[0..2] -join '.'
    $ifs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$tPrefix.*" -and $_.IPAddress -ne $Target })
    if ($ifs.Count -gt 1) {
        Write-Host "warn: $($ifs.Count) interfaces on $tPrefix.x - pings may leave the wrong NIC" -ForegroundColor Yellow
    }
    if ($ifs.Count -ge 1) {
        $nic = Get-NetAdapter -InterfaceIndex $ifs[0].InterfaceIndex -ErrorAction SilentlyContinue
        if ($nic) { $nicName = $nic.Name }
    }
} catch { }

if ($NoForce100) {
    $linkReason = "100M skipped"
} elseif (-not $nicName) {
    $linkReason = "no NIC found"
} elseif (-not (Test-Admin)) {
    $linkReason = "not admin"
} else {
    $r = Set-Link100 -NicName $nicName
    $linkApplied = $r.Applied; $linkWas = $r.Prior; $linkReason = $r.Reason
    if ($linkApplied -and $linkWas) { Start-Sleep -Milliseconds 1500 }   # the change bounces the link
}

# Fixed 3-line header: title, one link/note status line, a rule. Everything
# after this is the scrolling log - no other line ever prints above the rule.
Write-Host ("EtherBeep  {0}  {1} pings" -f $Target, $Required) -ForegroundColor Cyan
if ($linkApplied) {
    Write-Host "link  100M full  ·  $nicName" -ForegroundColor DarkGray
} else {
    Write-Host "note  $linkReason · auto negotiation" -ForegroundColor DarkGray
}
Write-Host ('─' * 42) -ForegroundColor DarkGray

$pinger  = New-Object System.Net.NetworkInformation.Ping
$streak  = 0
$fails   = 0
$state   = "armed"           # armed | up
$armedAt = Get-Date          # when the hunt for the current port began
$downAt  = $null             # first missed ping of the current unplug
$lastHb  = Get-Date
$lastEvt = Get-Date          # last beep or re-arm - what "idle" is measured from
$standby = $false

# No port counting on purpose: 2-port and 4-port units run the same script,
# and a counter only stays honest if every port is tried exactly once in
# order. A dead port or a re-test silently shifts it, and a counter that
# misreports which port just passed is worse than no counter. One beep = one
# port answered; the operator knows which port they just plugged into.
try {
while ($true) {
    $ok = $false
    $rtt = 0
    try {
        $r = $pinger.Send($Target, $TimeoutMs)
        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $ok = $true; $rtt = [int]$r.RoundtripTime
        }
    } catch { }   # unreachable/no-route throws on some stacks - treat as fail

    # Standby wakes on the FIRST sign the bench is being touched - one ping
    # answering while armed, or one missing while up - not on the confirmed
    # result. Waiting for the full streak or all of DownFails would put the
    # standby gap in front of every one of them.
    $activity = if ($state -eq "armed") { $ok } else { -not $ok }
    if ($activity) {
        # Idle is measured from the last sign of life, not from the last beep:
        # a half-finished streak still means someone is at the bench, and
        # timing it from the beep would drop back into standby mid-streak.
        $lastEvt = Get-Date
        if ($standby) {
            $standby = $false
            Write-Log "··" "awake"
        }
    }

    if ($state -eq "armed") {
        if ($ok) {
            $streak++
            if ($streak -ge $Required) {
                # The beep IS the product - fire it before printing anything.
                Invoke-PortBeep
                $since = Format-Since ((Get-Date) - $armedAt).TotalMilliseconds
                Write-Log "UP" ("{0,-7}  {1}ms" -f $since, $rtt) "Green"
                $state = "up"; $fails = 0; $lastHb = Get-Date
            }
            # streak in progress: no gap - fire the next ping immediately
        } else {
            $streak = 0
            if (-not $standby -and ((Get-Date) - $lastHb).TotalSeconds -ge 5) {
                $secs = [int]((Get-Date) - $armedAt).TotalSeconds
                Write-Log "··" "waiting ${secs}s"
                $lastHb = Get-Date
            }
            Start-Sleep -Milliseconds $(if ($standby) { $StandbyGapMs } else { $ArmedGapMs })
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
            if (-not $standby -and ((Get-Date) - $lastHb).TotalSeconds -ge 60) {
                Write-Log "··" "still up"
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
        Start-Sleep -Milliseconds $(if ($standby) { $StandbyGapMs } else { $UpGapMs })
    }

    # Nothing has happened for StandbyMin: back off the poll rate. A unit left
    # plugged in overnight is otherwise 20 pings a second until morning.
    if (-not $standby -and $StandbyMin -gt 0 -and
        ((Get-Date) - $lastEvt).TotalMinutes -ge $StandbyMin) {
        $standby = $true
        $rate = if ($StandbyGapMs -ge 1000) { "{0:0.#}s" -f ($StandbyGapMs / 1000) }
                else { "{0}ms" -f $StandbyGapMs }
        Write-Log "··" "standby · $rate poll"
    }
}
} finally {
    # Put the adapter back the way we found it. Ctrl+C is the normal way this
    # script ends, so this is the path that actually runs - leaving a shared
    # bench NIC pinned at 100M would be a nasty surprise for whoever uses that
    # machine next.
    Restore-Link -NicName $nicName -Was $linkWas
}
