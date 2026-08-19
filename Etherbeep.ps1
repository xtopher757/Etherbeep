#Requires -Version 5.1

<#
.SYNOPSIS
    Audible ping monitor for bench work. A small always-on-top window that beeps when the
    target goes down and when it comes back.

.DESCRIPTION
    Etherbeep pings a target once a second and plays a distinct tone every time the link
    state changes, so you can work at the far end of a cable run without watching a screen.

        Rising three-tone  = UP    (target is replying)
        Falling two-tone   = DOWN  (target stopped replying)

    The window is deliberately tiny. It sits on top of everything else, it never takes
    focus away from what you are working in, and you can drag it anywhere by grabbing it.
    Green means up, red means down, readable from across the bench.

    Defaults are set for the shop bench: target 192.168.1.1 over the USB Ethernet adapter.
    Run it with no arguments and it just works.

    A single dropped packet does not raise an alarm. The target is only called DOWN after
    -FailCount consecutive misses (default 2), which keeps normal packet loss quiet.

    No modules, no installs, no internet. Windows PowerShell 5.1 and PowerShell 7 both work.

    Window controls
        drag anywhere   move it
        double-click    switch between the small and the wide layout
        right-click     menu: sound, always on top, reset position, exit; an
                        "Update available" entry appears when a newer version
                        is published
        x               close

.PARAMETER Target
    Host name or IP to ping. Default 192.168.1.1.

.PARAMETER Interval
    Seconds between pings during work hours. Default 1.

.PARAMETER StandbyFrom
    Start of the off-hours standby window, local time. Default 16:00.

.PARAMETER StandbyTo
    End of the off-hours standby window, local time. Default 06:00.

.PARAMETER StandbyInterval
    Seconds between pings while in standby. Default 30. Etherbeep keeps watching all
    night, it just stops hammering the bench. State changes still beep, so a device
    that comes up at 5am is still announced, and Etherbeep returns to the fast interval
    for five minutes after any change so the tech gets responsive feedback.

.PARAMETER WakeMinutes
    How long standby stays suspended after a state change, in minutes. Default 5.
    0 keeps the slow interval even when something changes.

.PARAMETER NoStandby
    Ping at the work-hours interval around the clock.

.PARAMETER TimeoutMs
    Milliseconds to wait for each reply before counting it as a miss. Default 800.

.PARAMETER FailCount
    Consecutive misses before the target is called DOWN. Default 2.

.PARAMETER OkCount
    Consecutive replies before the target is called UP. Default 1.

.PARAMETER Reminder
    Seconds between short reminder chirps that repeat the current state. 0 disables them
    (default). Use this when you are away from the bench and want to hear that Etherbeep
    is still running. Reminders are silent during standby.

.PARAMETER LogFile
    Write a CSV record of every ping and every state change. Pass a file path, or pass a
    folder (for example -LogFile .) to have the file named automatically.

.PARAMETER Quiet
    Run silently. The window still shows everything.

.PARAMETER Zoom
    Window and text scale, 0.6 to 3.0. Default 1. Use a bigger number on a high resolution
    screen or when the bench PC is an arm's length away.

.PARAMETER NoTopMost
    Do not keep the window above other windows.

.PARAMETER ResetPosition
    Ignore the saved window position and start in the bottom right corner.

.PARAMETER Console
    Run as a scrolling text monitor in the console instead of the window. Useful for
    logging a long soak test, and used automatically if the window cannot be created.

.PARAMETER Count
    Stop after this many pings. 0 (default) runs until you stop it.

.PARAMETER NoUpdateCheck
    Do not look for a newer published version. Etherbeep normally asks github.com once
    a day, one tiny request with nothing downloaded, and shows a notice when a newer
    release exists. It never updates itself either way; re-run the install line or
    re-scan the QR code to update.

.PARAMETER SkipAdapterCheck
    Do not look up the network adapter. Use this if adapter lookup is slow on a bench PC.

.PARAMETER Pause
    Console mode only. Wait for a key press before closing.

.PARAMETER Version
    Print the version and exit.

.EXAMPLE
    .\Etherbeep.ps1

    Watch 192.168.1.1 with bench defaults, in the small always-on-top window.

.EXAMPLE
    .\Etherbeep.ps1 -Target 192.168.0.1 -Reminder 30

    Watch a different gateway and chirp the current state every 30 seconds.

.EXAMPLE
    .\Etherbeep.ps1 -StandbyFrom 17:30 -StandbyTo 07:00

    Watch the bench gateway and drop to the slow standby interval outside 07:00 to 17:30.

.EXAMPLE
    .\Etherbeep.ps1 -Console -LogFile .

    Run a soak test in the console and record every ping to a CSV in the current folder,
    for attaching to a repair ticket.

.NOTES
    Exit code 0 if the target was up at the end, 1 if it was down.
#>
[CmdletBinding()]
param(
    [Alias('t', 'Address', 'IP')]
    [ValidateNotNullOrEmpty()]
    [string]$Target = '192.168.1.1',

    [Alias('i')]
    [ValidateRange(0.1, 3600)]
    [double]$Interval = 1,

    [ValidateNotNullOrEmpty()]
    [string]$StandbyFrom = '16:00',

    [ValidateNotNullOrEmpty()]
    [string]$StandbyTo = '06:00',

    [ValidateRange(1, 3600)]
    [double]$StandbyInterval = 30,

    [ValidateRange(0, 240)]
    [double]$WakeMinutes = 5,

    [switch]$NoStandby,

    [ValidateRange(50, 60000)]
    [int]$TimeoutMs = 800,

    [Alias('DownAfter')]
    [ValidateRange(1, 100)]
    [int]$FailCount = 2,

    [Alias('UpAfter')]
    [ValidateRange(1, 100)]
    [int]$OkCount = 1,

    [Alias('r')]
    [ValidateRange(0, 86400)]
    [int]$Reminder = 0,

    [Alias('Log')]
    [string]$LogFile,

    [Alias('Silent')]
    [switch]$Quiet,

    [ValidateRange(0.6, 3.0)]
    [double]$Zoom = 1.0,

    [switch]$NoTopMost,

    [switch]$ResetPosition,

    [Alias('Text')]
    [switch]$Console,

    [ValidateRange(0, 2147483647)]
    [int]$Count = 0,

    [switch]$NoUpdateCheck,

    [switch]$SkipAdapterCheck,

    [switch]$Pause,

    [switch]$Version
)

$ErrorActionPreference = 'Stop'

$script:AppName = 'Etherbeep'
$script:AppVersion = '1.1.0'

if ($Version) {
    Write-Output ('{0} {1}' -f $script:AppName, $script:AppVersion)
    exit 0
}

$script:SoundWorks = -not $Quiet
$script:LastError = $null
$script:ExitCode = 0

# ===========================================================================
# Standby schedule
#
# The bench runs unattended overnight waiting for a device to appear, so
# outside work hours Etherbeep slows down instead of pinging every second all
# night. It never stops watching. Any state change pulls it back to the fast
# interval for a few minutes so whoever is standing there gets live feedback.
# ===========================================================================

$script:WakeGraceMinutes = $WakeMinutes
$script:WakeUntil = [datetime]::MinValue
$script:InStandby = $false

function ConvertTo-TimeOfDay {
    <#
        Accepts 16:00 and 4:00 PM. Rejects anything else outright: a typo here would
        otherwise be read as a year or a day count and turn into an all-day standby.
    #>
    param(
        [string]$Text,
        [string]$ParameterName
    )

    $bad = '{0} "{1}" is not a time of day. Use 24 hour form such as 16:00, or 4:00 PM.' -f $ParameterName, $Text

    $trimmed = $Text.Trim()
    if ($trimmed -notmatch '^\d{1,2}:\d{2}(:\d{2})?\s*([AaPp]\.?[Mm]\.?)?$') { throw $bad }

    $moment = [datetime]::MinValue
    if (-not [datetime]::TryParse($trimmed, [ref]$moment)) { throw $bad }

    return $moment.TimeOfDay
}

$script:StandbyFromSpan = ConvertTo-TimeOfDay -Text $StandbyFrom -ParameterName 'StandbyFrom'
$script:StandbyToSpan = ConvertTo-TimeOfDay -Text $StandbyTo -ParameterName 'StandbyTo'

# Equal times would mean a standby window of either zero or the whole day. Treat it
# as "no standby" rather than guessing.
$script:StandbyEnabled = (-not $NoStandby) -and ($script:StandbyFromSpan -ne $script:StandbyToSpan)

function Test-InStandbyWindow {
    param([datetime]$Moment)

    if (-not $script:StandbyEnabled) { return $false }

    $timeOfDay = $Moment.TimeOfDay
    if ($script:StandbyFromSpan -lt $script:StandbyToSpan) {
        # A window inside one day, for example 01:00 to 05:00.
        return ($timeOfDay -ge $script:StandbyFromSpan -and $timeOfDay -lt $script:StandbyToSpan)
    }
    # A window over midnight, for example 16:00 to 06:00.
    return ($timeOfDay -ge $script:StandbyFromSpan -or $timeOfDay -lt $script:StandbyToSpan)
}

function Get-PollInterval {
    <#
        The interval to wait before the next ping, and whether that is the standby
        one. Updates $script:InStandby as a side effect so the reminder chirp and
        both front ends can read it.
    #>

    $now = Get-Date
    $standby = (Test-InStandbyWindow -Moment $now) -and ($now -ge $script:WakeUntil)
    $script:InStandby = $standby

    if ($standby) { return $StandbyInterval }
    return $Interval
}

function Reset-WakeGrace {
    # Called on every state change: stay responsive for a few minutes afterwards.
    if ($script:WakeGraceMinutes -le 0) { return }
    $script:WakeUntil = (Get-Date).AddMinutes($script:WakeGraceMinutes)
}

$script:StandbyAnnounced = $null

function Get-StandbyChange {
    <#
        Returns 'Enter' the first time a poll lands inside the standby window,
        'Leave' the first time one lands outside it, otherwise $null. Also writes
        the change to the log so an overnight CSV explains its own ping spacing.
    #>

    if ($null -eq $script:StandbyAnnounced) {
        $script:StandbyAnnounced = $script:InStandby
        return $null
    }
    if ($script:StandbyAnnounced -eq $script:InStandby) { return $null }

    $script:StandbyAnnounced = $script:InStandby

    if ($script:InStandby) {
        Write-LogRow -Event 'STANDBY' -Latency $null -Status '' -Detail (
            'off hours, ping every {0}s' -f $StandbyInterval)
        return 'Enter'
    }

    Write-LogRow -Event 'ACTIVE' -Latency $null -Status '' -Detail (
        'work hours, ping every {0}s' -f $Interval)
    return 'Leave'
}

function Format-StandbySchedule {
    if (-not $script:StandbyEnabled) { return 'off (pinging at the work-hours rate around the clock)' }

    $text = '{0:hh\:mm} to {1:hh\:mm}, ping every {2}s' -f `
        $script:StandbyFromSpan, $script:StandbyToSpan, $StandbyInterval
    if (Test-InStandbyWindow -Moment (Get-Date)) { $text = $text + '   (in standby now)' }
    return $text
}

# ===========================================================================
# Update check (notify only)
#
# Once a day Etherbeep asks github.com what the newest published release is,
# using a single HEAD request - no API, no token, nothing downloaded. When
# something newer than this copy exists, the window and the console say so.
# Nothing updates itself: a tech re-runs the install line or re-scans the QR
# when convenient. Every failure is silent, and in the window the request is
# fully asynchronous, so monitoring never waits on the network.
# ===========================================================================

$script:UpdateRepo = 'xtopher757/Etherbeep'
$script:UpdateAvailable = $null
$script:LastUpdateCheckDay = ''
$script:PendingUpdateCheck = $null

function Get-LatestReleaseUrl {
    return ('https://github.com/{0}/releases/latest' -f $script:UpdateRepo)
}

function Set-UpdateAvailableFromLocation {
    <#
        releases/latest answers with a redirect. With at least one release published
        it points at /releases/tag/<tag>; with none it points at the plain /releases
        page, which parses as "nothing to compare against".
    #>
    param([string]$Location)

    if (-not $Location) { return $false }
    if ($Location -notmatch '/releases/tag/v?([0-9]+(?:\.[0-9]+)+)/?$') { return $false }

    try {
        if ([version]$Matches[1] -gt [version]$script:AppVersion) {
            $script:UpdateAvailable = $Matches[1]
            return $true
        }
    }
    catch { }
    return $false
}

function Test-UpdateCheckDue {
    param([datetime]$Now = (Get-Date))

    if ($NoUpdateCheck) { return $false }
    if ($script:UpdateAvailable) { return $false }

    $today = $Now.ToString('yyyy-MM-dd')
    if ($script:LastUpdateCheckDay -eq '') { return $true }        # at startup
    if ($script:LastUpdateCheckDay -eq $today) { return $false }   # already done today
    return ($Now.Hour -ge 2 -and $Now.Hour -lt 6)                  # small hours only
}

function Get-LocationFromWebError {
    # .NET Framework hands a redirect back as a normal response when auto-redirect
    # is off; newer .NET throws instead, with the response inside the exception.
    # Accept either.
    param($ErrorRecord)

    $current = $ErrorRecord.Exception
    while ($current) {
        if ($current -is [System.Net.WebException] -and $current.Response) {
            $location = $null
            try {
                $location = $current.Response.Headers['Location']
                $current.Response.Close()
            }
            catch { }
            return $location
        }
        $current = $current.InnerException
    }
    return $null
}

function Invoke-UpdateCheckSync {
    # Console mode: worst case a three second pause, once a day.
    $script:LastUpdateCheckDay = (Get-Date).ToString('yyyy-MM-dd')

    $location = $null
    try {
        $request = [System.Net.WebRequest]::CreateHttp((Get-LatestReleaseUrl))
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $false
        $request.Timeout = 3000
        $response = $request.GetResponse()
        try { $location = $response.Headers['Location'] } finally { $response.Close() }
    }
    catch {
        $location = Get-LocationFromWebError -ErrorRecord $_
    }
    return (Set-UpdateAvailableFromLocation -Location $location)
}

function Start-UpdateCheck {
    # Window mode: returns a pending check for the UI timer to poll.
    $script:LastUpdateCheckDay = (Get-Date).ToString('yyyy-MM-dd')

    try {
        $request = [System.Net.WebRequest]::CreateHttp((Get-LatestReleaseUrl))
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $false
        return @{
            Task    = $request.GetResponseAsync()
            Request = $request
            Started = (Get-Date)
        }
    }
    catch { return $null }
}

function Complete-UpdateCheck {
    <#
        Polls a pending check. Returns $true once it is finished, whatever the
        outcome, so the caller can clear it. The Timeout property does not apply
        to the asynchronous path, so a stuck request is abandoned by hand.
    #>
    param($Pending)

    if (-not $Pending) { return $true }

    if (-not $Pending.Task.IsCompleted) {
        if (((Get-Date) - $Pending.Started).TotalSeconds -lt 10) { return $false }
        try { $Pending.Request.Abort() } catch { }
        return $true
    }

    $location = $null
    try {
        $response = $Pending.Task.Result
        try { $location = $response.Headers['Location'] } finally { $response.Close() }
    }
    catch {
        $location = Get-LocationFromWebError -ErrorRecord $_
    }
    Set-UpdateAvailableFromLocation -Location $location | Out-Null
    return $true
}

# ===========================================================================
# Sound
#
# Console::Beep drives the same tone generator on every Windows build since 7,
# and needs no audio library. If the PC has no way to make the sound it fails
# once and Etherbeep goes quiet rather than throwing on every state change.
# ===========================================================================

function Invoke-Tone {
    param(
        [int[]]$Frequencies,
        [int]$Milliseconds = 90
    )

    if (-not $script:SoundWorks) { return }

    foreach ($frequency in $Frequencies) {
        try {
            [Console]::Beep($frequency, $Milliseconds)
        }
        catch {
            $script:SoundWorks = $false
            return
        }
    }
}

function Invoke-StartupTone { Invoke-Tone -Frequencies 880, 1175 -Milliseconds 80 }
function Invoke-UpTone { Invoke-Tone -Frequencies 784, 1046, 1568 -Milliseconds 90 }
function Invoke-DownTone { Invoke-Tone -Frequencies 988, 622 -Milliseconds 200 }

function Invoke-ReminderTone {
    param([string]$State)

    if ($State -eq 'Up') { Invoke-Tone -Frequencies 1568 -Milliseconds 60 }
    else { Invoke-Tone -Frequencies 440 -Milliseconds 120 }
}

# ===========================================================================
# Formatting
# ===========================================================================

function Format-Duration {
    param([TimeSpan]$Span)

    if ($Span.TotalDays -ge 1) {
        return ('{0}d {1:00}:{2:00}:{3:00}' -f [int]$Span.TotalDays, $Span.Hours, $Span.Minutes, $Span.Seconds)
    }
    return ('{0:00}:{1:00}:{2:00}' -f $Span.Hours, $Span.Minutes, $Span.Seconds)
}

function Format-Milliseconds {
    param([Nullable[double]]$Value)

    if ($null -eq $Value) { return '--' }
    if ($Value -lt 10) { return ('{0:0.0} ms' -f $Value) }
    return ('{0:0} ms' -f $Value)
}

# ===========================================================================
# Network adapter hint
#
# When the target stops replying it matters whether the USB NIC lost link or
# whether the link is fine and the device is not answering. This is a hint
# only. If the cmdlets are missing it stays silent.
# ===========================================================================

$script:AdapterLookupWorks = -not $SkipAdapterCheck

function Get-AdapterSummary {
    if (-not $script:AdapterLookupWorks) { return $null }

    try {
        if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $script:AdapterLookupWorks = $false
            return $null
        }

        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
        if ($adapters.Count -eq 0) { return $null }

        # Prefer a USB adapter, which is what the bench uses. Within that, prefer one
        # that actually has link.
        $usb = @($adapters | Where-Object {
            $_.InterfaceDescription -match 'USB' -or $_.Name -match 'USB'
        })

        $candidates = $adapters
        if ($usb.Count -gt 0) { $candidates = $usb }

        $chosen = $candidates | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if (-not $chosen) { $chosen = $candidates | Select-Object -First 1 }
        if (-not $chosen) { return $null }

        $name = $chosen.InterfaceDescription
        if (-not $name) { $name = $chosen.Name }

        if ($chosen.Status -eq 'Up') {
            return ('{0} - up, {1}' -f $name, $chosen.LinkSpeed)
        }
        return ('{0} - {1} (no link)' -f $name, $chosen.Status)
    }
    catch {
        $script:AdapterLookupWorks = $false
        return $null
    }
}

# ===========================================================================
# CSV log
# ===========================================================================

$script:LogWriter = $null
$script:LogPath = $null

function Open-Log {
    param([string]$Path)

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        $full = Join-Path (Get-Location).Path $full
    }
    $full = [System.IO.Path]::GetFullPath($full)

    # A folder means "pick a file name for me".
    if (Test-Path -LiteralPath $full -PathType Container) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeTarget = ($Target -replace '[^A-Za-z0-9._-]', '_')
        $full = Join-Path $full ('etherbeep-{0}-{1}.csv' -f $safeTarget, $stamp)
    }

    $folder = Split-Path -Parent $full
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $isNew = -not (Test-Path -LiteralPath $full)
    $writer = New-Object System.IO.StreamWriter($full, $true)
    $writer.AutoFlush = $true
    if ($isNew) {
        $writer.WriteLine('Timestamp,Event,Target,LatencyMs,Status,Detail')
    }

    $script:LogWriter = $writer
    $script:LogPath = $full
}

function Write-LogRow {
    param(
        [string]$Event,
        [Nullable[double]]$Latency,
        [string]$Status,
        [string]$Detail = ''
    )

    if (-not $script:LogWriter) { return }

    $latencyText = ''
    if ($null -ne $Latency) { $latencyText = ([string]$Latency) }

    $row = '{0},{1},{2},{3},{4},"{5}"' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $Event,
        $Target,
        $latencyText,
        $Status,
        ($Detail -replace '"', '""')

    try { $script:LogWriter.WriteLine($row) } catch { }
}

function Close-Log {
    if (-not $script:LogWriter) { return }
    try { $script:LogWriter.Flush(); $script:LogWriter.Dispose() } catch { }
    $script:LogWriter = $null
}

# ===========================================================================
# Ping and state machine
#
# Shared by both front ends. The window and the console differ only in how
# they draw what these produce.
# ===========================================================================

function New-PingResult {
    return [pscustomobject]@{
        Success    = $false
        Latency    = $null
        StatusText = ''
    }
}

function ConvertFrom-PingReply {
    param($Reply)

    $result = New-PingResult
    $result.StatusText = [string]$Reply.Status
    if ($Reply.Status -eq 'Success') {
        $result.Success = $true
        $result.Latency = [double]$Reply.RoundtripTime
    }
    return $result
}

function ConvertFrom-PingFailure {
    param($Exception)

    $result = New-PingResult
    $result.StatusText = 'SendFailed'

    $reason = ''
    $current = $Exception
    while ($current) {
        if ($current.Message) { $reason = $current.Message }
        $current = $current.InnerException
    }
    if ($reason -match 'host is known|No such host|not known|resolve') {
        $result.StatusText = 'NameNotResolved'
    }
    $script:LastError = $reason
    return $result
}

function Invoke-PingOnce {
    param($Pinger)

    $script:LastError = $null
    try {
        return (ConvertFrom-PingReply -Reply $Pinger.Send($Target, $TimeoutMs))
    }
    catch {
        return (ConvertFrom-PingFailure -Exception $_.Exception)
    }
}

function New-MonitorState {
    return [pscustomobject]@{
        State           = 'Unknown'
        ConsecutiveOk   = 0
        ConsecutiveFail = 0
        StateSince      = (Get-Date)
        SessionStart    = (Get-Date)
        Sent            = 0
        Received        = 0
        UpTicks         = [TimeSpan]::Zero
        DownTicks       = [TimeSpan]::Zero
        UpCount         = 0
        DownCount       = 0
        LongestOutage   = [TimeSpan]::Zero
        LatencyMin      = $null
        LatencyMax      = $null
        LatencyTotal    = 0.0
        LastLatency     = $null
        LastStatus      = ''
        LastReminder    = (Get-Date)
    }
}

function Update-MonitorState {
    <#
        Feeds one ping result into the state machine. Returns $null when nothing
        changed, or a transition object describing the change.
    #>
    param(
        [Parameter(Mandatory)]$Monitor,
        [Parameter(Mandatory)]$Result
    )

    $Monitor.Sent++
    $Monitor.LastLatency = $Result.Latency
    $Monitor.LastStatus = $Result.StatusText

    if ($Result.Success) {
        $Monitor.Received++
        $Monitor.ConsecutiveOk++
        $Monitor.ConsecutiveFail = 0
        $Monitor.LatencyTotal += $Result.Latency
        if ($null -eq $Monitor.LatencyMin -or $Result.Latency -lt $Monitor.LatencyMin) {
            $Monitor.LatencyMin = $Result.Latency
        }
        if ($null -eq $Monitor.LatencyMax -or $Result.Latency -gt $Monitor.LatencyMax) {
            $Monitor.LatencyMax = $Result.Latency
        }
    }
    else {
        $Monitor.ConsecutiveOk = 0
        $Monitor.ConsecutiveFail++
    }

    Write-LogRow -Event 'PING' -Latency $Result.Latency -Status $Result.StatusText

    $newState = $Monitor.State
    if ($Monitor.State -ne 'Up' -and $Monitor.ConsecutiveOk -ge $OkCount) { $newState = 'Up' }
    elseif ($Monitor.State -ne 'Down' -and $Monitor.ConsecutiveFail -ge $FailCount) { $newState = 'Down' }

    if ($newState -eq $Monitor.State) { return $null }

    $now = Get-Date
    $heldFor = $now - $Monitor.StateSince
    $from = $Monitor.State

    if ($from -eq 'Up') { $Monitor.UpTicks += $heldFor }
    elseif ($from -eq 'Down') {
        $Monitor.DownTicks += $heldFor
        if ($heldFor -gt $Monitor.LongestOutage) { $Monitor.LongestOutage = $heldFor }
    }

    if ($newState -eq 'Up') { $Monitor.UpCount++ } else { $Monitor.DownCount++ }

    $Monitor.State = $newState
    $Monitor.StateSince = $now
    $Monitor.LastReminder = $now

    # Something just happened, so somebody may be standing at the bench. Ping at the
    # fast rate for a few minutes even if the clock says standby.
    Reset-WakeGrace

    return [pscustomobject]@{
        From       = $from
        To         = $newState
        HeldFor    = $heldFor
        Latency    = $Result.Latency
        StatusText = $Result.StatusText
        Missed     = $Monitor.ConsecutiveFail
        At         = $now
    }
}

function Write-TransitionLog {
    <#
        Records a transition to the CSV and returns the adapter hint, so the caller
        can show it without looking the adapter up twice.
    #>
    param($Transition)

    if ($Transition.To -eq 'Up') {
        Write-LogRow -Event 'UP' -Latency $Transition.Latency -Status $Transition.StatusText -Detail (
            'previous state {0} for {1}' -f $Transition.From, (Format-Duration $Transition.HeldFor))
        return $null
    }

    $hint = Get-AdapterSummary
    $detail = 'after {0} missed replies' -f $Transition.Missed
    if ($hint) { $detail = '{0}; adapter: {1}' -f $detail, $hint }
    if ($script:LastError) { $detail = '{0}; {1}' -f $detail, $script:LastError }
    Write-LogRow -Event 'DOWN' -Latency $null -Status $Transition.StatusText -Detail $detail
    return $hint
}

function Invoke-TransitionTone {
    param($Transition)

    if ($Transition.To -eq 'Up') { Invoke-UpTone } else { Invoke-DownTone }
}

function Test-ReminderDue {
    param($Monitor)

    if ($Reminder -le 0) { return $false }
    if ($Monitor.State -eq 'Unknown') { return $false }
    if ($script:InStandby) { return $false }
    if (((Get-Date) - $Monitor.LastReminder).TotalSeconds -lt $Reminder) { return $false }

    $Monitor.LastReminder = Get-Date
    return $true
}

function Close-Monitor {
    <#
        Rolls the final part-finished state period into the totals so the summary
        adds up, and sets the exit code.
    #>
    param($Monitor)

    $held = (Get-Date) - $Monitor.StateSince
    if ($Monitor.State -eq 'Up') { $Monitor.UpTicks += $held }
    elseif ($Monitor.State -eq 'Down') {
        $Monitor.DownTicks += $held
        if ($held -gt $Monitor.LongestOutage) { $Monitor.LongestOutage = $held }
    }

    Write-LogRow -Event 'STOP' -Latency $null -Status $Monitor.State -Detail (
        'sent={0} received={1} lost={2}' -f $Monitor.Sent, $Monitor.Received,
        ($Monitor.Sent - $Monitor.Received))

    if ($Monitor.State -eq 'Down') { $script:ExitCode = 1 }
}

function Get-LossPercent {
    param($Monitor)

    if ($Monitor.Sent -le 0) { return 0.0 }
    return ((($Monitor.Sent - $Monitor.Received) / $Monitor.Sent) * 100)
}

function Write-StartLog {
    Write-LogRow -Event 'START' -Latency $null -Status '' -Detail (
        'interval={0}s timeout={1}ms downAfter={2} upAfter={3}' -f $Interval, $TimeoutMs, $FailCount, $OkCount)
}

# ===========================================================================
# Window front end (default)
# ===========================================================================

function Initialize-WindowType {
    <#
        Builds a Form subclass that never steals focus. WS_EX_NOACTIVATE keeps clicks
        on the window from pulling focus out of whatever the tech is working in, and
        WS_EX_TOOLWINDOW keeps it out of Alt+Tab and the taskbar.

        Returns the type name, or $null if this PC cannot compile it. The caller then
        falls back to a plain top-most form, which behaves the same except that a
        click on it takes focus.
    #>

    if ('Etherbeep.QuietForm' -as [type]) { return 'Etherbeep.QuietForm' }

    $code = @'
namespace Etherbeep {
    public class QuietForm : System.Windows.Forms.Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override System.Windows.Forms.CreateParams CreateParams {
            get {
                System.Windows.Forms.CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                return cp;
            }
        }
    }
}
'@

    try {
        $references = @(
            [System.Windows.Forms.Form].Assembly.Location,
            [System.Drawing.Point].Assembly.Location
        )
        Add-Type -TypeDefinition $code -ReferencedAssemblies $references -ErrorAction Stop
        return 'Etherbeep.QuietForm'
    }
    catch {
        return $null
    }
}

$script:SettingsPath = $null
if ($env:LOCALAPPDATA) {
    $script:SettingsPath = Join-Path $env:LOCALAPPDATA 'Etherbeep\settings.json'
}

function Get-SavedSettings {
    if (-not $script:SettingsPath) { return $null }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $null }

    try { return (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Save-Settings {
    param($Settings)

    if (-not $script:SettingsPath) { return }

    try {
        $folder = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding ASCII
    }
    catch { }
}

function Test-PointVisible {
    param([int]$X, [int]$Y)

    try {
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            if ($screen.WorkingArea.Contains($X, $Y)) { return $true }
        }
    }
    catch { return $false }
    return $false
}

# Everything the window needs, in one script-scope bag.
#
# The three functions below are kept at script scope, and reach the controls through
# that bag, rather than being nested inside Start-WindowMonitor and closing over its
# locals. Both resolve correctly from a WinForms event handler, but only this one is
# obvious at a glance.
$script:UiState = $null

function Get-ScaledSize {
    param([double]$Value)
    return [int][Math]::Round($Value * $Zoom)
}

function Set-EtherbeepLayout {
    param([bool]$Wide)

    $ui = $script:UiState
    if (-not $ui) { return }

    $width = Get-ScaledSize 196
    if (-not $Wide) { $width = Get-ScaledSize 116 }
    $height = Get-ScaledSize 54

    $ui.Form.ClientSize = New-Object System.Drawing.Size($width, $height)

    $pad = Get-ScaledSize 8
    $closeSize = Get-ScaledSize 16

    $ui.Close.SetBounds(($width - $closeSize - (Get-ScaledSize 2)), (Get-ScaledSize 2), $closeSize, $closeSize)
    $ui.State.SetBounds($pad, (Get-ScaledSize 3), ($width - $pad - $closeSize), (Get-ScaledSize 27))
    $ui.TargetLabel.SetBounds($pad, (Get-ScaledSize 3), ($width - $pad - $closeSize - (Get-ScaledSize 2)), (Get-ScaledSize 27))
    $ui.Detail.SetBounds($pad, (Get-ScaledSize 30), ($width - ($pad * 2)), (Get-ScaledSize 20))

    $ui.TargetLabel.Visible = $Wide
}

function Update-EtherbeepWindow {
    $ui = $script:UiState
    if (-not $ui) { return }

    $m = $ui.Monitor
    if (-not $m) { return }

    switch ($m.State) {
        'Up' {
            $ui.Form.BackColor = $ui.ColorUp
            $ui.State.Text = 'UP'
        }
        'Down' {
            $ui.Form.BackColor = $ui.ColorDown
            $ui.State.Text = 'DOWN'
        }
        default {
            $ui.Form.BackColor = $ui.ColorUnknown
            $ui.State.Text = '...'
        }
    }

    $tail = ''
    if ($script:InStandby) { $tail = '   standby' }
    if ($script:UpdateAvailable) { $tail = $tail + ('   update v{0}' -f $script:UpdateAvailable) }

    if ($m.State -eq 'Unknown') {
        $ui.Detail.Text = ('waiting for {0}{1}' -f $Target, $tail)
        return
    }

    $ui.Detail.Text = '{0}   {1}   {2:0}% loss{3}' -f `
        (Format-Duration ((Get-Date) - $m.StateSince)),
        (Format-Milliseconds $m.LastLatency),
        (Get-LossPercent $m),
        $tail
}

function Start-WindowMonitor {
    <#
        The window front end. Pings run as tasks polled by a UI timer, so a slow or
        timing out reply never freezes dragging.

        Sets $script:WindowRan when the window was actually created, rather than
        returning it, so that a stray value from any WinForms call cannot be mistaken
        for the result.
    #>

    $script:WindowRan = $false

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        return
    }

    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

    $formType = Initialize-WindowType
    if (-not $formType) { $formType = 'System.Windows.Forms.Form' }

    # ---- geometry -------------------------------------------------------

    $wide = $true
    $saved = $null
    if (-not $ResetPosition) { $saved = Get-SavedSettings }
    if ($saved -and $null -ne $saved.Wide) { $wide = [bool]$saved.Wide }

    $colorUp = [System.Drawing.Color]::FromArgb(27, 127, 59)
    $colorDown = [System.Drawing.Color]::FromArgb(192, 57, 43)
    $colorUnknown = [System.Drawing.Color]::FromArgb(85, 91, 98)
    $colorText = [System.Drawing.Color]::White
    $colorDim = [System.Drawing.Color]::FromArgb(225, 225, 225)

    $form = New-Object $formType
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ShowInTaskbar = $false
    $form.TopMost = (-not $NoTopMost)
    $form.BackColor = $colorUnknown
    $form.Text = $script:AppName
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.KeyPreview = $true

    $fontState = New-Object System.Drawing.Font('Segoe UI', (Get-ScaledSize 14), [System.Drawing.FontStyle]::Bold)
    $fontSmall = New-Object System.Drawing.Font('Segoe UI', (Get-ScaledSize 8))
    $fontClose = New-Object System.Drawing.Font('Segoe UI', (Get-ScaledSize 8), [System.Drawing.FontStyle]::Bold)

    $labelState = New-Object System.Windows.Forms.Label
    $labelState.Font = $fontState
    $labelState.ForeColor = $colorText
    $labelState.AutoSize = $false
    $labelState.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $labelState.Text = '...'

    $labelTarget = New-Object System.Windows.Forms.Label
    $labelTarget.Font = $fontSmall
    $labelTarget.ForeColor = $colorDim
    $labelTarget.AutoSize = $false
    $labelTarget.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $labelTarget.Text = $Target

    $labelDetail = New-Object System.Windows.Forms.Label
    $labelDetail.Font = $fontSmall
    $labelDetail.ForeColor = $colorDim
    $labelDetail.AutoSize = $false
    $labelDetail.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $labelDetail.Text = 'starting'

    $labelClose = New-Object System.Windows.Forms.Label
    $labelClose.Font = $fontClose
    $labelClose.ForeColor = $colorDim
    $labelClose.AutoSize = $false
    $labelClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $labelClose.Text = 'x'
    $labelClose.Cursor = [System.Windows.Forms.Cursors]::Hand

    $form.Controls.AddRange(@($labelState, $labelTarget, $labelDetail, $labelClose))

    # Published before the first layout pass, because every handler below reads it.
    $script:UiState = @{
        Form         = $form
        State        = $labelState
        TargetLabel  = $labelTarget
        Detail       = $labelDetail
        Close        = $labelClose
        Monitor      = $null
        Pinger       = $null
        ColorUp      = $colorUp
        ColorDown    = $colorDown
        ColorUnknown = $colorUnknown
    }

    Set-EtherbeepLayout -Wide $wide

    # A one pixel border keeps the window readable against any background.
    $form.Add_Paint({
        param($src, $e)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(20, 20, 20))
        try {
            $e.Graphics.DrawRectangle($pen, 0, 0, ($src.ClientSize.Width - 1), ($src.ClientSize.Height - 1))
        }
        finally { $pen.Dispose() }
    })

    # ---- position -------------------------------------------------------

    $startX = 0
    $startY = 0
    $placed = $false

    if ($saved -and $null -ne $saved.X -and $null -ne $saved.Y) {
        $candidateX = [int]$saved.X
        $candidateY = [int]$saved.Y
        # Only reuse the saved spot if that part of the desktop still exists.
        if (Test-PointVisible -X ($candidateX + 10) -Y ($candidateY + 10)) {
            $startX = $candidateX
            $startY = $candidateY
            $placed = $true
        }
    }

    if (-not $placed) {
        try {
            $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $startX = $area.Right - $form.Width - (Get-ScaledSize 16)
            $startY = $area.Bottom - $form.Height - (Get-ScaledSize 16)
        }
        catch {
            $startX = 100
            $startY = 100
        }
    }

    $form.Location = New-Object System.Drawing.Point($startX, $startY)

    # ---- dragging -------------------------------------------------------

    $script:DragFrom = $null
    $script:DragWindowAt = $null

    $onMouseDown = {
        param($src, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:DragFrom = [System.Windows.Forms.Cursor]::Position
            $script:DragWindowAt = $script:EtherbeepForm.Location
        }
    }

    $onMouseMove = {
        param($src, $e)
        if ($null -eq $script:DragFrom) { return }
        $now = [System.Windows.Forms.Cursor]::Position
        $script:EtherbeepForm.Location = New-Object System.Drawing.Point(
            ($script:DragWindowAt.X + $now.X - $script:DragFrom.X),
            ($script:DragWindowAt.Y + $now.Y - $script:DragFrom.Y))
    }

    $onMouseUp = {
        param($src, $e)
        $script:DragFrom = $null
    }

    $script:EtherbeepForm = $form

    foreach ($control in @($form, $labelState, $labelTarget, $labelDetail)) {
        $control.Add_MouseDown($onMouseDown)
        $control.Add_MouseMove($onMouseMove)
        $control.Add_MouseUp($onMouseUp)
    }

    # ---- menu and buttons -----------------------------------------------

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $itemSound = New-Object System.Windows.Forms.ToolStripMenuItem 'Sound'
    $itemSound.Checked = $script:SoundWorks
    $itemSound.Add_Click({
        $script:SoundWorks = -not $script:SoundWorks
        $this.Checked = $script:SoundWorks
    })

    $itemTop = New-Object System.Windows.Forms.ToolStripMenuItem 'Always on top'
    $itemTop.Checked = $form.TopMost
    $itemTop.Add_Click({
        $script:EtherbeepForm.TopMost = -not $script:EtherbeepForm.TopMost
        $this.Checked = $script:EtherbeepForm.TopMost
    })

    $itemReset = New-Object System.Windows.Forms.ToolStripMenuItem 'Move to corner'
    $itemReset.Add_Click({
        try {
            $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $script:EtherbeepForm.Location = New-Object System.Drawing.Point(
                ($area.Right - $script:EtherbeepForm.Width - 16),
                ($area.Bottom - $script:EtherbeepForm.Height - 16))
        }
        catch { }
    })

    $itemUpdate = New-Object System.Windows.Forms.ToolStripMenuItem 'Update available'
    $itemUpdate.Visible = $false
    $itemUpdate.Add_Click({
        # Opens the release page so the tech can see what changed. Updating is
        # still the QR code or the install line.
        try { Start-Process (Get-LatestReleaseUrl) } catch { }
    })
    $script:EtherbeepUpdateItem = $itemUpdate

    $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $itemExit.Add_Click({ $script:EtherbeepForm.Close() })

    $menu.Items.AddRange(@(
        $itemSound,
        $itemTop,
        $itemReset,
        $itemUpdate,
        (New-Object System.Windows.Forms.ToolStripSeparator),
        $itemExit))

    # The window never takes focus on its own. A deliberate right-click is the one
    # time it should, otherwise the menu cannot be dismissed properly.
    $onRightClick = {
        param($src, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            try { $script:EtherbeepForm.Activate() } catch { }
            $script:EtherbeepMenu.Show([System.Windows.Forms.Cursor]::Position)
        }
    }

    $script:EtherbeepMenu = $menu

    foreach ($control in @($form, $labelState, $labelTarget, $labelDetail)) {
        $control.Add_MouseUp($onRightClick)
    }

    $onDoubleClick = {
        param($src, $e)
        $script:EtherbeepWide = -not $script:EtherbeepWide
        Set-EtherbeepLayout -Wide $script:EtherbeepWide
    }
    $script:EtherbeepWide = $wide

    foreach ($control in @($form, $labelState, $labelDetail)) {
        $control.Add_DoubleClick($onDoubleClick)
    }

    $labelClose.Add_Click({ $script:EtherbeepForm.Close() })

    $form.Add_KeyDown({
        param($src, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:EtherbeepForm.Close() }
    })

    # ---- monitoring ------------------------------------------------------

    $monitor = New-MonitorState
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $script:PendingPing = $null
    $script:NextPingAt = Get-Date

    Write-StartLog
    Invoke-StartupTone

    $script:UiState.Monitor = $monitor
    $script:UiState.Pinger = $pinger

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100

    $timer.Add_Tick({
        $ui = $script:UiState
        $m = $ui.Monitor

        try {
            if ($null -eq $script:PendingPing) {
                if ((Get-Date) -ge $script:NextPingAt) {
                    $script:LastError = $null
                    $script:PendingPing = $ui.Pinger.SendPingAsync($Target, $TimeoutMs)
                }
            }
            elseif ($script:PendingPing.IsCompleted) {
                $task = $script:PendingPing
                $script:PendingPing = $null

                if ($task.IsFaulted -or $task.IsCanceled) {
                    # Reading .Result on either of these throws, so never touch it.
                    $result = ConvertFrom-PingFailure -Exception $task.Exception
                }
                else {
                    $result = ConvertFrom-PingReply -Reply $task.Result
                }

                $transition = Update-MonitorState -Monitor $m -Result $result
                if ($transition) {
                    Write-TransitionLog -Transition $transition | Out-Null
                    Update-EtherbeepWindow
                    Invoke-TransitionTone -Transition $transition
                }
                elseif (Test-ReminderDue -Monitor $m) {
                    Invoke-ReminderTone -State $m.State
                }

                # Worked out after the transition, because a state change pulls the
                # fast interval back even during the standby window.
                $script:NextPingAt = (Get-Date).AddSeconds((Get-PollInterval))
                Get-StandbyChange | Out-Null

                if ($Count -gt 0 -and $m.Sent -ge $Count) {
                    $ui.Form.Close()
                    return
                }
            }

            if ($null -eq $script:PendingUpdateCheck) {
                if (Test-UpdateCheckDue) { $script:PendingUpdateCheck = Start-UpdateCheck }
            }
            elseif (Complete-UpdateCheck -Pending $script:PendingUpdateCheck) {
                $script:PendingUpdateCheck = $null
                if ($script:UpdateAvailable -and $script:EtherbeepUpdateItem) {
                    $script:EtherbeepUpdateItem.Text = ('Update available - v{0}' -f $script:UpdateAvailable)
                    $script:EtherbeepUpdateItem.Visible = $true
                }
            }

            Update-EtherbeepWindow
        }
        catch {
            # A failure here must not kill the window. Show it and keep going.
            $ui.Detail.Text = 'error: ' + $_.Exception.Message
        }
    })

    $form.Add_Shown({
        param($src, $e)
        $script:EtherbeepTimer.Start()
    })
    $script:EtherbeepTimer = $timer

    $form.Add_FormClosing({
        param($src, $e)
        try { $script:EtherbeepTimer.Stop() } catch { }
        Save-Settings -Settings ([pscustomobject]@{
            X    = $script:EtherbeepForm.Location.X
            Y    = $script:EtherbeepForm.Location.Y
            Wide = $script:EtherbeepWide
        })
    })

    try {
        $script:WindowRan = $true
        [System.Windows.Forms.Application]::Run($form)
    }
    finally {
        try { $timer.Stop(); $timer.Dispose() } catch { }
        try { $pinger.Dispose() } catch { }
        try { $fontState.Dispose(); $fontSmall.Dispose(); $fontClose.Dispose() } catch { }
        try { $menu.Dispose() } catch { }
        try { $form.Dispose() } catch { }
        Close-Monitor -Monitor $monitor
    }
}

# ===========================================================================
# Console front end (-Console, and the fallback)
# ===========================================================================

$script:CanUseConsole = $false
$script:CanReadKeys = $false
$script:StatusLength = 0

function Initialize-ConsoleIo {
    try { $script:CanUseConsole = -not [Console]::IsOutputRedirected }
    catch { $script:CanUseConsole = $false }

    try {
        $null = [Console]::KeyAvailable
        $script:CanReadKeys = $true
    }
    catch { $script:CanReadKeys = $false }

    if ($script:CanReadKeys) {
        # Turn Ctrl+C into a normal key press so the session summary always prints.
        try { [Console]::TreatControlCAsInput = $true } catch { }
    }
}

function Get-ConsoleWidth {
    # The visible window, not the buffer: on the classic Windows console the buffer
    # is often wider than the window, and anything sized to the buffer runs off the
    # right edge or wraps. Re-read on every call so resizing mid-run is picked up.
    $width = 0
    try { $width = [Console]::WindowWidth } catch { }
    if ($width -le 0) {
        try { $width = [Console]::BufferWidth } catch { }
    }
    if ($width -ge 20) { return $width }
    if ($width -gt 0) { return 20 }
    return 80
}

function Get-RuleWidth {
    # Header and summary rulers: full width in a narrow window, capped in a wide one.
    return [Math]::Min(68, (Get-ConsoleWidth) - 1)
}

function Write-StatusLine {
    param([string]$Text)

    if (-not $script:CanUseConsole) { return }

    $limit = (Get-ConsoleWidth) - 1
    if ($Text.Length -gt $limit) { $Text = $Text.Substring(0, $limit) }

    # Pad over whatever the previous status left behind, but never past the window
    # edge: one wrapped repaint would push every later line out of alignment.
    $width = [Math]::Min([Math]::Max($script:StatusLength, $Text.Length), $limit)
    try { [Console]::Write("`r" + $Text.PadRight($width)) } catch { return }
    $script:StatusLength = $Text.Length
}

function Clear-StatusLine {
    if (-not $script:CanUseConsole -or $script:StatusLength -le 0) { return }
    $width = [Math]::Min($script:StatusLength, (Get-ConsoleWidth) - 1)
    try { [Console]::Write("`r" + (' ' * $width) + "`r") } catch { }
    $script:StatusLength = 0
}

function Write-Line {
    # Writes a permanent line without disturbing the live status line.
    param(
        [string]$Text,
        [string]$Color
    )

    Clear-StatusLine
    if ($Color) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}

function Set-WindowTitle {
    param([string]$Text)
    try { $Host.UI.RawUI.WindowTitle = $Text } catch { }
}

function Test-QuitRequested {
    if (-not $script:CanReadKeys) { return $false }

    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { return $true }
            if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
        }
    }
    catch { $script:CanReadKeys = $false }

    return $false
}

function Wait-Interruptible {
    # Sleeps in short slices so Q and Ctrl+C feel instant. Returns $true to quit.
    param([int]$Milliseconds)

    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        if (Test-QuitRequested) { return $true }
        $slice = [Math]::Min(100, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    return (Test-QuitRequested)
}

function Start-ConsoleMonitor {
    Initialize-ConsoleIo

    $rule = '=' * (Get-RuleWidth)
    $thin = '-' * (Get-RuleWidth)
    $adapter = Get-AdapterSummary

    Write-Host ''
    Write-Host $rule -ForegroundColor Cyan
    Write-Host ('  {0} {1}   audible ping monitor' -f $script:AppName, $script:AppVersion) -ForegroundColor Cyan
    Write-Host $rule -ForegroundColor Cyan
    Write-Host ('  Target     : {0}' -f $Target)
    Write-Host ('  Ping every : {0}s, timeout {1} ms' -f $Interval, $TimeoutMs)
    Write-Host ('  Standby    : {0}' -f (Format-StandbySchedule))
    Write-Host ('  Calls DOWN : after {0} missed repl{1}' -f $FailCount, $(if ($FailCount -eq 1) { 'y' } else { 'ies' }))
    Write-Host ('  Calls UP   : after {0} good repl{1}' -f $OkCount, $(if ($OkCount -eq 1) { 'y' } else { 'ies' }))

    $soundText = 'on   (rising = up, falling = down)'
    if ($Quiet) { $soundText = 'off  (-Quiet)' }
    Write-Host ('  Sound      : {0}' -f $soundText)

    if ($Reminder -gt 0) { Write-Host ('  Reminder   : chirp current state every {0}s' -f $Reminder) }
    if ($script:LogPath) { Write-Host ('  Log        : {0}' -f $script:LogPath) }
    if ($adapter) { Write-Host ('  Adapter    : {0}' -f $adapter) }

    Write-Host $thin -ForegroundColor DarkGray
    Write-Host '  Press Q or Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''

    Write-StartLog
    Invoke-StartupTone

    if (-not $Quiet -and -not $script:SoundWorks) {
        Write-Host '  Note: this PC cannot play tones. Watch the screen instead.' -ForegroundColor Yellow
        Write-Host ''
    }

    if (Test-UpdateCheckDue) {
        if (Invoke-UpdateCheckSync) {
            Write-Host ('  A newer version is published: v{0} (this is {1}).' -f `
                $script:UpdateAvailable, $script:AppVersion) -ForegroundColor Yellow
            Write-Host '  Re-run the install line or re-scan the QR code to update.' -ForegroundColor Yellow
            Write-Host ''
        }
    }

    $monitor = New-MonitorState
    $pinger = New-Object System.Net.NetworkInformation.Ping

    Set-WindowTitle ('{0} - starting - {1}' -f $script:AppName, $Target)

    try {
        while ($true) {
            $iterationStart = Get-Date

            $result = Invoke-PingOnce -Pinger $pinger
            $transition = Update-MonitorState -Monitor $monitor -Result $result

            if ($transition) {
                $stamp = $transition.At.ToString('HH:mm:ss')
                $hint = Write-TransitionLog -Transition $transition

                if ($transition.To -eq 'Up') {
                    if ($transition.From -eq 'Down') {
                        Write-Line -Color Green -Text ('  [{0}]  UP     back after {1}   ({2})' -f `
                            $stamp, (Format-Duration $transition.HeldFor), (Format-Milliseconds $transition.Latency))
                    }
                    else {
                        Write-Line -Color Green -Text ('  [{0}]  UP     {1} is replying   ({2})' -f `
                            $stamp, $Target, (Format-Milliseconds $transition.Latency))
                    }
                }
                else {
                    Write-Line -Color Red -Text ('  [{0}]  DOWN   no reply from {1} ({2})' -f `
                        $stamp, $Target, $transition.StatusText)
                    if ($hint) {
                        Write-Line -Color DarkYellow -Text ('           adapter: {0}' -f $hint)
                    }
                }

                Invoke-TransitionTone -Transition $transition
                Set-WindowTitle ('{0} - {1} - {2}' -f $script:AppName, $monitor.State.ToUpper(), $Target)
            }
            elseif (Test-ReminderDue -Monitor $monitor) {
                Invoke-ReminderTone -State $monitor.State
            }

            # Worked out after the transition, because a state change pulls the fast
            # interval back even during the standby window.
            $pollSeconds = Get-PollInterval
            $standbyChange = Get-StandbyChange
            if ($standbyChange -eq 'Enter') {
                Write-Line -Color DarkCyan -Text ('  [{0}]  STANDBY  off hours, ping every {1}s' -f `
                    (Get-Date -Format 'HH:mm:ss'), $StandbyInterval)
            }
            elseif ($standbyChange -eq 'Leave') {
                Write-Line -Color DarkCyan -Text ('  [{0}]  ACTIVE   work hours, ping every {1}s' -f `
                    (Get-Date -Format 'HH:mm:ss'), $Interval)
            }

            if (Test-UpdateCheckDue) {
                if (Invoke-UpdateCheckSync) {
                    Write-Line -Color Yellow -Text ('  [{0}]  UPDATE   v{1} is published, re-scan the QR to update' -f `
                        (Get-Date -Format 'HH:mm:ss'), $script:UpdateAvailable)
                }
            }

            $tail = ''
            if ($script:InStandby) { $tail = '  [standby]' }
            if ($script:UpdateAvailable) { $tail = $tail + ('  [update v{0}]' -f $script:UpdateAvailable) }

            if ($monitor.State -eq 'Unknown') {
                Write-StatusLine ('  waiting for first reply from {0} ...   sent {1}{2}' -f `
                    $Target, $monitor.Sent, $tail)
            }
            else {
                Write-StatusLine ('  {0} for {1}   sent {2}  lost {3} ({4:0.0}%)  last {5}{6}' -f `
                    $monitor.State.ToUpper(), (Format-Duration ((Get-Date) - $monitor.StateSince)),
                    $monitor.Sent, ($monitor.Sent - $monitor.Received), (Get-LossPercent $monitor),
                    (Format-Milliseconds $monitor.LastLatency), $tail)
            }

            if ($Count -gt 0 -and $monitor.Sent -ge $Count) { break }

            $elapsedMs = [int]((Get-Date) - $iterationStart).TotalMilliseconds
            $sleepMs = [int][Math]::Round($pollSeconds * 1000) - $elapsedMs
            if ($sleepMs -lt 0) { $sleepMs = 0 }

            if (Wait-Interruptible -Milliseconds $sleepMs) { break }
        }
    }
    finally {
        try { $pinger.Dispose() } catch { }
        try { [Console]::TreatControlCAsInput = $false } catch { }
        Set-WindowTitle 'Windows PowerShell'
    }

    Close-Monitor -Monitor $monitor
    Write-ConsoleSummary -Monitor $monitor
}

function Write-ConsoleSummary {
    param($Monitor)

    # Sized at print time: the window may have been resized during a long soak.
    $Thin = '-' * (Get-RuleWidth)

    $lost = $Monitor.Sent - $Monitor.Received
    $average = $null
    if ($Monitor.Received -gt 0) { $average = $Monitor.LatencyTotal / $Monitor.Received }

    Clear-StatusLine
    Write-Host ''
    Write-Host $Thin -ForegroundColor DarkGray
    Write-Host ('  Session summary        {0}   ran {1}' -f `
        $Target, (Format-Duration ((Get-Date) - $Monitor.SessionStart)))
    Write-Host ('    Pings sent   : {0}   replies {1}   lost {2} ({3:0.0}%)' -f `
        $Monitor.Sent, $Monitor.Received, $lost, (Get-LossPercent $Monitor))
    Write-Host ('    Latency      : min {0}   avg {1}   max {2}' -f `
        (Format-Milliseconds $Monitor.LatencyMin), (Format-Milliseconds $average),
        (Format-Milliseconds $Monitor.LatencyMax))
    Write-Host ('    Time up      : {0}' -f (Format-Duration $Monitor.UpTicks))
    Write-Host ('    Time down    : {0}   longest outage {1}' -f `
        (Format-Duration $Monitor.DownTicks), (Format-Duration $Monitor.LongestOutage))
    Write-Host ('    Changes      : {0} up, {1} down' -f $Monitor.UpCount, $Monitor.DownCount)
    if ($script:LogPath) { Write-Host ('    Log saved    : {0}' -f $script:LogPath) }
    Write-Host $Thin -ForegroundColor DarkGray
    Write-Host ''
}

# ===========================================================================
# Entry point
# ===========================================================================

try {
    if ($LogFile) {
        try { Open-Log -Path $LogFile }
        catch { Write-Warning ('Could not open log file: {0}' -f $_.Exception.Message) }
    }

    $script:WindowRan = $false

    if (-not $Console) {
        try {
            Start-WindowMonitor | Out-Null
        }
        catch {
            # Loading the assembly can succeed on a PC that still cannot build a
            # window, so the real failure often lands here rather than at Add-Type.
            # Anything thrown before the window opened means fall back to the
            # console. Anything after it opened is a genuine fault worth reporting.
            if ($script:WindowRan) { throw }
            Write-Verbose ('Window unavailable: {0}' -f $_.Exception.Message)
        }

        if (-not $script:WindowRan) {
            Write-Warning 'This PC cannot show the Etherbeep window. Falling back to console mode.'
        }
    }

    if (-not $script:WindowRan) {
        Start-ConsoleMonitor
    }
}
catch {
    $script:ExitCode = 2
    $message = '{0} stopped: {1}' -f $script:AppName, $_.Exception.Message

    # In window mode there may be no console to print to, so say it in a dialog.
    $shown = $false
    if (-not $Console) {
        try {
            [System.Windows.Forms.MessageBox]::Show($message, $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            $shown = $true
        }
        catch { }
    }
    if (-not $shown) {
        Clear-StatusLine
        Write-Host ''
        Write-Host ('  ' + $message) -ForegroundColor Red
        Write-Host ''
    }
}
finally {
    Clear-StatusLine
    Close-Log

    if ($Pause -and $Console) {
        Write-Host '  Press any key to close this window.' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey($true) }
        catch { try { Read-Host | Out-Null } catch { } }
    }
}

exit $script:ExitCode
