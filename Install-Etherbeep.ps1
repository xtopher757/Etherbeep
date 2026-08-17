#Requires -Version 5.1

<#
.SYNOPSIS
    Installs Etherbeep for the current user. No admin rights needed.

.DESCRIPTION
    Copies Etherbeep into the user's local app folder, makes a desktop shortcut and a
    Start menu entry, and puts the folder on the user's PATH so "etherbeep" works from
    any terminal. Nothing is written outside the user's own profile, so this runs on a
    locked down bench PC without an administrator.

    Run it from the folder you unzipped Etherbeep into.

.PARAMETER InstallPath
    Where to install. Default %LOCALAPPDATA%\Etherbeep.

.PARAMETER Startup
    Also start Etherbeep automatically when this user logs on. Worth using on a bench
    PC that sits waiting for a device all day.

.PARAMETER NoShortcut
    Do not create the desktop and Start menu shortcuts.

.PARAMETER NoPath
    Do not add the install folder to the user's PATH.

.PARAMETER Uninstall
    Remove everything this installer created.

.EXAMPLE
    .\Install-Etherbeep.ps1

    Install for the current user.

.EXAMPLE
    .\Install-Etherbeep.ps1 -Startup

    Install and start it automatically at logon.

.EXAMPLE
    .\Install-Etherbeep.ps1 -Uninstall

    Remove it again.
#>
[CmdletBinding()]
param(
    [string]$InstallPath,
    [switch]$Startup,
    [switch]$NoShortcut,
    [switch]$NoPath,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$script:AppName = 'Etherbeep'
$script:Payload = @('Etherbeep.ps1', 'Etherbeep.cmd')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Text)
    Write-Host ('  ' + $Text) -ForegroundColor Gray
}

function Write-Good {
    param([string]$Text)
    Write-Host ('  ' + $Text) -ForegroundColor Green
}

function Test-OnWindows {
    # $IsWindows only exists in PowerShell 6 and later. Windows PowerShell 5.1 is
    # Windows by definition, so its absence means yes.
    if (Test-Path Variable:\IsWindows) { return [bool]$IsWindows }
    return $true
}

function Get-UpdatedPath {
    <#
        Adds a folder to a PATH string. Returns $null when it is already there, so
        the caller can skip writing the registry and avoid growing PATH on re-runs.
    #>
    param(
        [string]$CurrentPath,
        [string]$Directory
    )

    $wanted = $Directory.TrimEnd('\')
    $parts = @()
    if ($CurrentPath) {
        $parts = @($CurrentPath -split ';' | Where-Object { $_.Trim() -ne '' })
    }

    foreach ($part in $parts) {
        if ($part.Trim().TrimEnd('\') -eq $wanted) { return $null }
    }

    $parts += $Directory
    return ($parts -join ';')
}

function Remove-FromPath {
    <#
        Takes a folder back out of a PATH string. Returns $null when it was not there.
    #>
    param(
        [string]$CurrentPath,
        [string]$Directory
    )

    if (-not $CurrentPath) { return $null }

    $wanted = $Directory.TrimEnd('\')
    $kept = @()
    $removed = $false

    foreach ($part in ($CurrentPath -split ';')) {
        if ($part.Trim() -eq '') { continue }
        if ($part.Trim().TrimEnd('\') -eq $wanted) { $removed = $true; continue }
        $kept += $part
    }

    if (-not $removed) { return $null }
    return ($kept -join ';')
}

function Get-ShortcutFolder {
    param([ValidateSet('Desktop', 'StartMenu', 'Startup')][string]$Kind)

    switch ($Kind) {
        'Desktop' { return [Environment]::GetFolderPath('Desktop') }
        'StartMenu' { return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') }
        'Startup' { return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup') }
    }
}

function New-EtherbeepShortcut {
    <#
        Points the shortcut straight at powershell.exe with the window hidden, so
        starting Etherbeep never flashes a console window on the bench PC.
    #>
    param(
        [string]$LinkPath,
        [string]$ScriptPath
    )

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($LinkPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath)
        $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
        $shortcut.Description = 'Audible ping monitor for bench work'
        $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\SHELL32.dll') + ',18'
        $shortcut.Save()
    }
    finally {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { }
    }
}

function Remove-IfPresent {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -Recurse
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

if (-not (Test-OnWindows)) {
    Write-Host ''
    Write-Host '  Etherbeep installs on Windows only.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if (-not $InstallPath) {
    $InstallPath = Join-Path $env:LOCALAPPDATA $script:AppName
}
$InstallPath = [System.IO.Path]::GetFullPath($InstallPath)

$desktopLink = Join-Path (Get-ShortcutFolder -Kind 'Desktop') ($script:AppName + '.lnk')
$startMenuLink = Join-Path (Get-ShortcutFolder -Kind 'StartMenu') ($script:AppName + '.lnk')
$startupLink = Join-Path (Get-ShortcutFolder -Kind 'Startup') ($script:AppName + '.lnk')
$installedScript = Join-Path $InstallPath 'Etherbeep.ps1'

Write-Host ''
Write-Host ('  ' + $script:AppName + ' installer') -ForegroundColor Cyan
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
    foreach ($link in @($desktopLink, $startMenuLink, $startupLink)) {
        if (Remove-IfPresent -Path $link) { Write-Step ('removed ' + $link) }
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $trimmed = Remove-FromPath -CurrentPath $userPath -Directory $InstallPath
    if ($null -ne $trimmed) {
        [Environment]::SetEnvironmentVariable('Path', $trimmed, 'User')
        Write-Step 'removed the install folder from your PATH'
    }

    # Only delete a folder that really is an Etherbeep install.
    if ((Test-Path -LiteralPath $installedScript) -or
        (Test-Path -LiteralPath (Join-Path $InstallPath 'settings.json'))) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
        Write-Step ('removed ' + $InstallPath)
    }
    elseif (Test-Path -LiteralPath $InstallPath) {
        Write-Warning ('{0} does not look like an Etherbeep install, leaving it alone.' -f $InstallPath)
    }

    Write-Host ''
    Write-Good 'Etherbeep removed.'
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

$sourceFolder = $PSScriptRoot
if (-not $sourceFolder -and $MyInvocation.MyCommand.Path) {
    $sourceFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $sourceFolder) {
    Write-Host ''
    Write-Host '  Run this installer from the folder you unzipped Etherbeep into.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$missing = @()
foreach ($file in $script:Payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceFolder $file))) { $missing += $file }
}
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ('  Missing next to the installer: {0}' -f ($missing -join ', ')) -ForegroundColor Yellow
    Write-Host '  Unzip the whole download and run the installer from that folder.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if (-not (Test-Path -LiteralPath $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$sameFolder = ([System.IO.Path]::GetFullPath($sourceFolder).TrimEnd('\') -eq $InstallPath.TrimEnd('\'))

foreach ($file in $script:Payload) {
    $target = Join-Path $InstallPath $file
    if (-not $sameFolder) {
        Copy-Item -LiteralPath (Join-Path $sourceFolder $file) -Destination $target -Force
    }
    # Windows blocks scripts that came from a download until they are unblocked.
    try { Unblock-File -LiteralPath $target -ErrorAction Stop } catch { }
}
Write-Step ('installed to ' + $InstallPath)

if (-not $NoShortcut) {
    New-EtherbeepShortcut -LinkPath $desktopLink -ScriptPath $installedScript
    Write-Step 'desktop shortcut created'

    New-EtherbeepShortcut -LinkPath $startMenuLink -ScriptPath $installedScript
    Write-Step 'Start menu entry created'
}

if ($Startup) {
    New-EtherbeepShortcut -LinkPath $startupLink -ScriptPath $installedScript
    Write-Step 'will start automatically when you log on'
}
elseif (Test-Path -LiteralPath $startupLink) {
    Remove-Item -LiteralPath $startupLink -Force
    Write-Step 'removed the old logon entry (re-run with -Startup to keep it)'
}

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $updated = Get-UpdatedPath -CurrentPath $userPath -Directory $InstallPath
    if ($null -ne $updated) {
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Step 'added to your PATH (open a new terminal to pick it up)'
    }
    else {
        Write-Step 'already on your PATH'
    }
}

Write-Host ''
Write-Good 'Etherbeep is installed.'
Write-Host ''
Write-Host '  Start it            double-click the Etherbeep desktop shortcut'
Write-Host '  From a terminal     etherbeep'
Write-Host '  Different target    etherbeep -Target 192.168.0.1'
Write-Host '  Soak test with log  etherbeep -Console -LogFile .'
Write-Host '  Remove it           .\Install-Etherbeep.ps1 -Uninstall'
Write-Host ''
