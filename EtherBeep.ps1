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

    Three console layouts, all 46x12, from the Claude Design exploration in
    EtherBeep Console.dc.html - pick with -Layout:

      tape    (1a, default) a scrolling log in fixed columns - time, a
              2-char state marker, cycle, rtt - so cycle times compare down
              the page. Append-only, keeps scrollback, no cursor tricks.
      status  (1b) the same log in a 7-row block, plus one status row
              redrawn in place at the bottom: state, streak dots, elapsed,
              and a running ports-confirmed tally. The 5s "waiting"
              heartbeat disappears - the timer ticks in one spot instead.
      glance  (1c) no scrollback at all. A filled band of colour carries
              the state, the last cycle time gets its own line, and history
              shrinks to two aligned rows of the last four ports. Readable
              at arm's length with both hands on the cable.

    status and glance render through a double-buffered frame compositor: rows
    are described as coloured segments, diffed against what is on screen, and
    only the changed ones go out - as one string in one write, with inline SGR
    and cursor escapes. A ticking timer costs one row per second, and a
    repaint with nothing changed costs no output at all. They need cursor
    control, so with output redirected they fall back to tape rather than
    draw nothing.

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
    [ValidateSet("tape","status","glance")]
    [string] $Layout = "tape",          # console layout; see the three designs in the README
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
    # Kept short (80ms a rep, 40ms between): a sweep is a rapid sequence of
    # these, so a long tone runs into the operator's next cable move and the
    # blocking cost lands on every port.
    for ($n = 0; $n -lt $script:BeepReps; $n++) {
        try { [console]::beep(1568, 35); [console]::beep(2349, 45) } catch { }
        if ($n -lt $script:BeepReps - 1) { Start-Sleep -Milliseconds 40 }
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

# ---------------------------------------------------------------------------
# Fixed-layout panels ("status" = design 1b, "glance" = design 1c)
#
# Both repaint 11 rows in place rather than scrolling, which is the whole
# point of them: the elapsed timer ticks in one spot instead of emitting a
# heartbeat line every 5s.
#
# Rendering is a double-buffered frame compositor, the useful half of what a
# curses library would do for us (ncurses itself is a non-starter here: on
# Windows it means shipping a PDCurses DLL, and this tool has to stay two
# files you can copy to a bench). Panels describe rows as coloured segments;
# nothing is emitted until Complete-PanelFrame diffs the finished frame
# against what is already on screen and writes only the rows that changed -
# as a SINGLE string with inline SGR and cursor escapes. Repainting an
# unchanged screen therefore costs one comparison per row and zero output,
# where the previous version issued up to ~33 separate Write-Host calls.
#
# Two invariants keep it safe across conhost and Windows Terminal:
#
#   * no newline is ever emitted - rows are placed with explicit cursor
#     positioning. If the window scrolled once, the pinned row would slide
#     off and every later write would target the wrong line.
#   * the layout occupies rows 0..10 of the 12-row window, so row 11 stays
#     blank and even a full-width write on row 10 has somewhere to land.
#
# Glyphs are restricted to what code page 437 can encode - Windows
# PowerShell 5.1 renders anything else as "?" when the console output
# encoding is the default OEM page. So the design's U+25AA/U+25AB streak
# squares become CP437's filled square and light-shade block.
$script:PanelRows = 11
$script:PanelCols = 46
$script:Rule      = '─' * 42          # U+2500, CP437 0xC4
$script:DotFull   = '■'               # U+25A0, CP437 0xFE (design: U+25AA)
$script:DotOpen   = '░'               # U+2591, CP437 0xB0 (design: U+25AB)
$script:ESC       = [char]27
$script:UseAnsi   = $false
$script:VtPrior   = $null             # console mode to put back on exit
$script:frame     = @{}               # row -> @{ Segs; Key } being composed
$script:shown     = @{}               # row -> Key currently on screen

# ConsoleColor name -> SGR foreground code. The low eight are 30-37; the
# bright eight are the same plus 60. Background is foreground plus 10.
$script:AnsiFg = @{
    Black       = 30; DarkBlue = 34; DarkGreen = 32; DarkCyan  = 36
    DarkRed     = 31; DarkMagenta = 35; DarkYellow = 33; Gray   = 37
    DarkGray    = 90; Blue     = 94; Green     = 92; Cyan      = 96
    Red         = 91; Magenta  = 95; Yellow    = 93; White     = 97
}

function Enable-VtOutput {
    # Turn on ENABLE_VIRTUAL_TERMINAL_PROCESSING so conhost interprets the SGR
    # and cursor escapes rather than printing them. Windows 10 1511+; on older
    # consoles this fails and the compositor falls back to per-row Write-Host.
    # Non-Windows hosts do VT natively with no mode to set.
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $true
    }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class EtherBeepVt {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
"@
    } catch { }   # already loaded from a previous run in this session
    try {
        $h = [EtherBeepVt]::GetStdHandle(-11)          # STD_OUTPUT_HANDLE
        $mode = 0
        if (-not [EtherBeepVt]::GetConsoleMode($h, [ref]$mode)) { return $false }
        $script:VtPrior = $mode
        if ($mode -band 0x0004) { return $true }       # already on (Windows Terminal)
        return [EtherBeepVt]::SetConsoleMode($h, $mode -bor 0x0004)
    } catch { return $false }
}

function Restore-VtOutput {
    if ($null -eq $script:VtPrior) { return }
    try { $null = [EtherBeepVt]::SetConsoleMode([EtherBeepVt]::GetStdHandle(-11), $script:VtPrior) } catch { }
}

function Initialize-Panel {
    # Returns $false when this host cannot position the cursor - piped output,
    # a redirected stream, a non-console host. Both panels are nothing but
    # positioned writes, so without it they would draw absolutely nothing;
    # the caller falls back to the scrolling layout rather than run blank.
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -gt 0 -and $w -lt $script:PanelCols) { $script:PanelCols = $w }
    } catch { }
    # IsOutputRedirected is the reliable test. SetCursorPosition alone is not:
    # on Windows it throws when stdout is a file, but on Unix hosts it happily
    # succeeds and moves nothing, so the panel would "draw" into a pipe as one
    # long smear of concatenated rows.
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { }
    try {
        $probe = [Console]::CursorTop
        [Console]::SetCursorPosition(0, $probe)
    } catch {
        return $false
    }
    $script:UseAnsi = Enable-VtOutput
    try { [Console]::CursorVisible = $false } catch { }
    try { [Console]::Clear() } catch { }
    # Clear() wiped the screen, so nothing is on it - drop any remembered rows
    # or the first frame would diff against stale content and skip them.
    $script:shown = @{}
    return $true
}

function Resolve-PanelSegments {
    # Clip a row's segments to the panel width and pad the tail, so the
    # previous frame's longer text can never survive underneath this one.
    param([array] $Segs)
    $out = @(); $used = 0
    foreach ($s in $Segs) {
        if ($used -ge $script:PanelCols) { break }
        $t = [string]$s.T
        if ($t.Length -eq 0) { continue }
        if ($used + $t.Length -gt $script:PanelCols) {
            $t = $t.Substring(0, $script:PanelCols - $used)
        }
        $out += @{ T = $t; F = $s.F; B = $s.B }
        $used += $t.Length
    }
    if ($used -lt $script:PanelCols) {
        $out += @{ T = (' ' * ($script:PanelCols - $used)); F = $null; B = $null }
    }
    return $out
}

function Write-PanelSegments {
    # Buffer a row into the frame being composed. Nothing reaches the console
    # until Complete-PanelFrame, so a panel can describe all 11 rows and still
    # cost one write - and rows identical to what is on screen cost nothing.
    param([int] $Row, [array] $Segs)
    $segs = Resolve-PanelSegments $Segs
    $key = (($segs | ForEach-Object { "$($_.F)/$($_.B)/$($_.T)" }) -join ([char]1))
    $script:frame[$Row] = @{ Segs = $segs; Key = $key }
}

function Write-PanelRow {
    param([int] $Row, [string] $Text, [string] $Color = "Gray")
    Write-PanelSegments $Row @(@{ T = $Text; F = $Color; B = $null })
}

function Complete-PanelFrame {
    # Diff the composed frame against the screen and emit only what moved.
    $changed = @()
    for ($i = 0; $i -lt $script:PanelRows; $i++) {
        if (-not $script:frame.ContainsKey($i)) { continue }
        if ($script:frame[$i].Key -ne $script:shown[$i]) { $changed += $i }
    }
    if ($changed.Count -eq 0) { return }

    if ($script:UseAnsi) {
        # One string, one write: no partially-drawn frame is ever visible, and
        # the cursor parks below the panel at the end of the same write.
        $sb = New-Object System.Text.StringBuilder
        foreach ($i in $changed) {
            $null = $sb.Append("$($script:ESC)[$($i + 1);1H")
            foreach ($s in $script:frame[$i].Segs) {
                $codes = @()
                if ($s.F) { $codes += $script:AnsiFg[$s.F] }
                if ($s.B) { $codes += ($script:AnsiFg[$s.B] + 10) }
                if ($codes.Count) {
                    $null = $sb.Append("$($script:ESC)[" + ($codes -join ';') + "m")
                    $null = $sb.Append($s.T)
                    $null = $sb.Append("$($script:ESC)[0m")
                } else {
                    $null = $sb.Append($s.T)
                }
            }
        }
        $null = $sb.Append("$($script:ESC)[$($script:PanelRows + 1);1H")
        [Console]::Out.Write($sb.ToString())
    } else {
        # Pre-VT console: same diff, but placed with the console API and
        # coloured by Write-Host. Still far less output than repainting all.
        foreach ($i in $changed) {
            try { [Console]::SetCursorPosition(0, $i) } catch { continue }
            foreach ($s in $script:frame[$i].Segs) {
                if ($s.B)      { Write-Host $s.T -ForegroundColor $s.F -BackgroundColor $s.B -NoNewline }
                elseif ($s.F)  { Write-Host $s.T -ForegroundColor $s.F -NoNewline }
                else           { Write-Host $s.T -NoNewline }
            }
        }
        try { [Console]::SetCursorPosition(0, $script:PanelRows) } catch { }
    }

    foreach ($i in $changed) { $script:shown[$i] = $script:frame[$i].Key }
}

function Get-StreakDots {
    param([int] $Streak, [int] $Of)
    $f = [Math]::Min([Math]::Max($Streak, 0), $Of)
    return ($script:DotFull * $f) + ($script:DotOpen * ($Of - $f))
}

function Format-Idle {
    param([timespan] $Span)
    if ($Span.TotalMinutes -lt 60) { return ("{0}m" -f [int]$Span.TotalMinutes) }
    return ("{0}h{1:00}m" -f [int]$Span.TotalHours, $Span.Minutes)
}

function Format-Field {
    # "     label        value" - label at column 5, value right-aligned so it
    # ends at $EndCol. The design uses EndCol 20 on the port-up panel and 21
    # on the armed/standby ones; kept as a parameter rather than averaged so
    # each panel matches its own mock.
    param([string] $Label, [string] $Value, [int] $EndCol)
    $left = "     " + $Label
    return $left.PadRight([Math]::Max($left.Length, $EndCol - $Value.Length)) + $Value
}

function Show-StatusPanel {
    # Design 1b: scrolling log up top, one status row redrawn in place at the
    # bottom. The log block is top-aligned and holds 7 rows; the newest entry
    # is the only green one, and the whole block dims in standby.
    param([string] $DispState, [int] $Streak, [int] $HuntSecs, [string] $Idle, [string] $Rate)
    $dim = ($DispState -eq "standby")
    Write-PanelRow 0 ("EtherBeep  {0}  {1}" -f $script:Target, $script:LinkLabel) "DarkGray"
    Write-PanelRow 1 $script:Rule "DarkGray"

    $rows = @($script:hist)
    if ($rows.Count -gt 7) { $rows = @($rows[($rows.Count - 7)..($rows.Count - 1)]) }
    for ($i = 0; $i -lt 7; $i++) {
        if ($i -ge $rows.Count) { Write-PanelRow (2 + $i) "" "DarkGray"; continue }
        $e = $rows[$i]
        $c = if ($dim) { "DarkGray" } elseif ($i -eq $rows.Count - 1) { "Green" } else { "Gray" }
        Write-PanelRow (2 + $i) ("{0}  UP    {1,-7}  {2}ms" -f $e.Stamp, $e.Cycle, $e.Rtt) $c
    }
    Write-PanelRow 9 $script:Rule "DarkGray"

    $dots  = Get-StreakDots $Streak $script:Required
    $tally = "{0} up" -f $script:portsUp
    if ($DispState -eq "up") {
        $last = if ($script:hist.Count) { $script:hist[$script:hist.Count - 1] } else { $null }
        $cyc  = if ($last) { $last.Cycle } else { "" }
        $rtt  = if ($last) { "{0}ms rtt" -f $last.Rtt } else { "" }
        # " UP " is reverse video - background colour on a run of spaces, which
        # is all the design's filled band ever was.
        $mid = ("   {0}  {1}  {2}   " -f $dots, $cyc, $rtt).PadRight(25)
        Write-PanelSegments 10 @(
            @{ T = " UP "; F = "Black";    B = "Green" }
            @{ T = $mid;   F = "Gray";     B = $null   }
            @{ T = $tally; F = "DarkGray"; B = $null   }
        )
    } elseif ($DispState -eq "armed") {
        $left = ("ARMED  {0}  hunting {1}s" -f $dots, $HuntSecs).PadRight(29)
        Write-PanelSegments 10 @(
            @{ T = $left;  F = "Yellow";   B = $null }
            @{ T = $tally; F = "DarkGray"; B = $null }
        )
    } else {
        Write-PanelRow 10 ("STANDBY".PadRight(13) + "$Rate poll".PadRight(11) + "idle $Idle") "DarkGray"
    }
}

function Show-GlancePanel {
    # Design 1c: no scrollback at all. A filled band carries the state, the
    # last cycle time gets its own line, and history shrinks to two aligned
    # rows of the last four ports.
    param([string] $DispState, [int] $Streak, [int] $HuntSecs, [string] $Idle, [string] $Rate)

    switch ($DispState) {
        "up"      { $label = "PORT  UP"; $bf = "Black";    $bb = "Green"    }
        "armed"   { $label = "ARMED";    $bf = "Yellow";   $bb = "DarkGray" }
        default   { $label = "STANDBY";  $bf = "DarkGray"; $bb = "Black"    }
    }
    # Floor, not an [int] cast: PowerShell rounds .5 to even, so a 7-char
    # label in 46 columns ([int]19.5 -> 20) would sit one column right of
    # where the design puts it, while a 5-char one would happen to land right.
    $padL = [int][Math]::Floor(($script:PanelCols - $label.Length) / 2)
    $band = (' ' * $padL) + $label
    $band = $band.PadRight($script:PanelCols)
    Write-PanelSegments 0 @(@{ T = $band; F = $bf; B = $bb })
    Write-PanelRow 1 "" "DarkGray"

    if ($DispState -eq "up") {
        $last = if ($script:hist.Count) { $script:hist[$script:hist.Count - 1] } else { $null }
        $cyc  = if ($last) { $last.Cycle } else { "-" }
        $rtt  = if ($last) { "{0}ms" -f $last.Rtt } else { "-" }
        Write-PanelRow 2 (Format-Field "cycle" $cyc 20) "Gray"
        Write-PanelRow 3 ((Format-Field "rtt" $rtt 20) + "      streak " + (Get-StreakDots $Streak $script:Required)) "DarkGray"
    } elseif ($DispState -eq "armed") {
        Write-PanelRow 2 (Format-Field "hunting" ("{0}s" -f $HuntSecs) 21) "DarkGray"
        Write-PanelRow 3 ("     plug in a port      streak " + (Get-StreakDots $Streak $script:Required)) "DarkGray"
    } else {
        Write-PanelRow 2 (Format-Field "idle" $Idle 21) "DarkGray"
        Write-PanelRow 3 ("     $Rate poll · wakes on the next change") "DarkGray"
    }

    Write-PanelRow 4 "" "DarkGray"
    Write-PanelRow 5 $script:Rule "DarkGray"

    $rows = @($script:hist)
    if ($rows.Count -gt 4) { $rows = @($rows[($rows.Count - 4)..($rows.Count - 1)]) }
    $stamps = "  "; $cycles = "  "
    foreach ($e in $rows) {
        $stamps += ([string]$e.Stamp).PadRight(10)
        $cycles += ([string]$e.Cycle).PadRight(10)
    }
    # The mock dims these from #767676 to #4a4a4a in standby, but conhost has
    # no grey between DarkGray and Black, so both land on DarkGray and the
    # history rows cannot visibly dim. The band carries that signal instead.
    Write-PanelRow 6 $stamps.TrimEnd() "DarkGray"
    Write-PanelRow 7 $cycles.TrimEnd() "DarkGray"
    Write-PanelRow 8 "" "DarkGray"
    Write-PanelRow 9 $script:Rule "DarkGray"
    Write-PanelRow 10 ("{0}  {1}  ·  ctrl+c stop" -f $script:Target, $script:LinkLabel) "DarkGray"
}

function Update-Panel {
    param([string] $DispState, [int] $Streak, [int] $HuntSecs, [timespan] $IdleSpan, [string] $Rate)
    $idle = Format-Idle $IdleSpan
    if ($script:Layout -eq "status") {
        Show-StatusPanel $DispState $Streak $HuntSecs $idle $Rate
    } else {
        Show-GlancePanel $DispState $Streak $HuntSecs $idle $Rate
    }
    # The panels only buffered rows; this is what reaches the console, and it
    # parks the cursor below the layout as part of the same write.
    Complete-PanelFrame
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
$warned      = $false
try {
    $tPrefix = ($Target -split '\.')[0..2] -join '.'
    $ifs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$tPrefix.*" -and $_.IPAddress -ne $Target })
    if ($ifs.Count -gt 1) {
        Write-Host "warn: $($ifs.Count) interfaces on $tPrefix.x - pings may leave the wrong NIC" -ForegroundColor Yellow
        $warned = $true
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

# Shared by every layout: the short link descriptor the panels put in their
# header/footer, and script-scoped copies of what the render functions read.
$script:LinkLabel = if ($linkApplied) { "100M full" } else { "auto neg" }
$script:Target    = $Target
$script:Required  = $Required
$script:Layout    = $Layout
$script:hist      = New-Object System.Collections.ArrayList
$script:portsUp   = 0
$script:lastKey   = $null

if ($Layout -ne "tape") {
    # The panels clear the screen, so give a startup warning a beat to be read
    # before it is wiped - it is the one message worth not losing.
    if ($warned) { Start-Sleep -Milliseconds 1500 }
    if (-not (Initialize-Panel)) {
        $Layout = "tape"; $script:Layout = "tape"
        Write-Host "note: no cursor control here - falling back to the tape layout" -ForegroundColor Yellow
    }
}

if ($Layout -eq "tape") {
    # Fixed 3-line header: title, one link/note status line, a rule. Everything
    # after this is the scrolling log - no line ever prints above the rule.
    Write-Host ("EtherBeep  {0}  {1} pings" -f $Target, $Required) -ForegroundColor Cyan
    if ($linkApplied) {
        Write-Host "link  100M full  ·  $nicName" -ForegroundColor DarkGray
    } else {
        Write-Host "note  $linkReason · auto negotiation" -ForegroundColor DarkGray
    }
    Write-Host $script:Rule -ForegroundColor DarkGray
}

$pinger  = New-Object System.Net.NetworkInformation.Ping
$streak  = 0
$fails   = 0
$state   = "armed"           # armed | up
$armedAt = Get-Date          # when the hunt for the current port began
$downAt  = $null             # first missed ping of the current unplug
$lastHb  = Get-Date
$lastEvt = Get-Date          # last beep or re-arm - what "idle" is measured from
$standby = $false
$skipSleep = $false          # set on re-arm: hunt immediately, but still repaint

# The standby poll rate as text, needed continuously by the panels (their
# standby view names it) rather than only at the moment standby is entered.
$script:Rate = if ($StandbyGapMs -ge 1000) { "{0:0.#}s" -f ($StandbyGapMs / 1000) }
               else { "{0}ms" -f $StandbyGapMs }

# No "port N of M" counting on purpose: 2-port and 4-port units run the same
# script, and an ordered counter only stays honest if every port is tried
# exactly once in order. A dead port or a re-test silently shifts it, and a
# counter that misreports which port just passed is worse than no counter.
# One beep = one port answered; the operator knows which port they plugged in.
# The panels' "N up" tally is a different thing and safe: a running session
# total that makes no claim about which port, so nothing can desync it.
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
            if ($Layout -eq "tape") { Write-Log "··" "awake" }
        }
    }

    if ($state -eq "armed") {
        if ($ok) {
            $streak++
            if ($streak -ge $Required) {
                # The beep IS the product - fire it before printing anything.
                Invoke-PortBeep
                $since = Format-Since ((Get-Date) - $armedAt).TotalMilliseconds
                # History feeds the panels' log block and their two-row
                # summary; capped at 7 because that is the tallest consumer.
                $null = $script:hist.Add([pscustomobject]@{
                    Stamp = (Get-Date -Format "HH:mm:ss"); Cycle = $since; Rtt = $rtt })
                while ($script:hist.Count -gt 7) { $script:hist.RemoveAt(0) }
                # A running session total, not "port 2 of 4" - it makes no claim
                # about WHICH port, so a dead port or a re-test cannot make it
                # lie the way an ordered counter would.
                $script:portsUp++
                if ($Layout -eq "tape") { Write-Log "UP" ("{0,-7}  {1}ms" -f $since, $rtt) "Green" }
                $state = "up"; $fails = 0; $lastHb = Get-Date
            }
            # streak in progress: no gap - fire the next ping immediately
        } else {
            $streak = 0
            if ($Layout -eq "tape" -and -not $standby -and ((Get-Date) - $lastHb).TotalSeconds -ge 5) {
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
            if ($Layout -eq "tape" -and -not $standby -and ((Get-Date) - $lastHb).TotalSeconds -ge 60) {
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
                # Skip the up-state sleep and hunt at armed cadence now. A flag
                # rather than `continue` so the repaint below still runs - the
                # re-arm is exactly the transition the panels need to show.
                $skipSleep = $true
            }
        }
        if (-not $skipSleep) {
            Start-Sleep -Milliseconds $(if ($standby) { $StandbyGapMs } else { $UpGapMs })
        }
        $skipSleep = $false
    }

    # Nothing has happened for StandbyMin: back off the poll rate. A unit left
    # plugged in overnight is otherwise 20 pings a second until morning.
    if (-not $standby -and $StandbyMin -gt 0 -and
        ((Get-Date) - $lastEvt).TotalMinutes -ge $StandbyMin) {
        $standby = $true
        if ($Layout -eq "tape") { Write-Log "··" "standby · $script:Rate poll" }
    }

    # Panels repaint in place, so they only redraw when something a viewer
    # could see actually changed: the state, the streak dots, a new port, or
    # the one field that ticks (hunting seconds, or standby idle minutes).
    # Keying on that instead of repainting every iteration keeps a 50ms poll
    # from driving 20 full redraws a second.
    if ($Layout -ne "tape") {
        $disp = if ($standby) { "standby" } elseif ($state -eq "up") { "up" } else { "armed" }
        $huntSecs = if ($disp -eq "armed") { [int]((Get-Date) - $armedAt).TotalSeconds } else { 0 }
        $idleSpan = (Get-Date) - $lastEvt
        $tick = switch ($disp) {
            "armed"   { $huntSecs }
            "standby" { [int]$idleSpan.TotalMinutes }
            default   { 0 }
        }
        $key = "$disp|$streak|$($script:hist.Count)|$script:portsUp|$tick"
        if ($key -ne $script:lastKey) {
            Update-Panel $disp $streak $huntSecs $idleSpan $script:Rate
            $script:lastKey = $key
        }
    }
}
} finally {
    # Drop below the panel before anything else prints, so a restore message
    # or the returning shell prompt lands under the layout instead of through
    # it, and give the cursor back either way.
    if ($Layout -ne "tape") {
        try { [Console]::SetCursorPosition(0, $script:PanelRows) } catch { }
        try { [Console]::CursorVisible = $true } catch { }
        Restore-VtOutput
    }
    # Put the adapter back the way we found it. Ctrl+C is the normal way this
    # script ends, so this is the path that actually runs - leaving a shared
    # bench NIC pinned at 100M would be a nasty surprise for whoever uses that
    # machine next.
    Restore-Link -NicName $nicName -Was $linkWas
}
