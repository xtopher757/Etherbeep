<#
.SYNOPSIS
    One-line web installer for Etherbeep. Downloads the newest published release from
    GitHub and runs the normal installer. No admin rights needed.

.DESCRIPTION
    This is the script behind the QR code on the shop wall. Run it with:

        irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1 | iex

    This URL never changes. What it installs is always the newest published release:
    the files are downloaded from the repository's latest GitHub Release, so merges to
    main do not reach the shop floor until a release is cut. If no release exists yet
    it says so and falls back to the newest development version on main.

    Everything lands in a temporary folder and is handed to Install-Etherbeep.ps1,
    which does the actual install: copy to %LOCALAPPDATA%\Etherbeep, desktop and
    Start menu shortcuts, user PATH. Nothing here needs an administrator and nothing
    is written outside your own user profile.

    Running through "iex" applies no execution policy, so this works on a locked
    down bench PC exactly as it comes.

.PARAMETER Startup
    Also start Etherbeep automatically at logon. To pass it through the one-liner:

        iex "& { $(irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1) } -Startup"

.NOTES
    To test an unmerged branch, set ETHERBEEP_BRANCH before running. That skips the
    release lookup entirely and installs straight from the branch:

        $env:ETHERBEEP_BRANCH = 'some-branch'; irm ... | iex
#>
[CmdletBinding()]
param(
    [switch]$Startup
)

$ErrorActionPreference = 'Stop'

$repo = 'xtopher757/Etherbeep'
$files = @('Etherbeep.ps1', 'Etherbeep.cmd', 'Install-Etherbeep.ps1')

# Sources to try, in order. All files always come from a single source, so a tech can
# never end up with a script from one version and an installer from another.
$sources = @()
if ($env:ETHERBEEP_BRANCH) {
    $sources += @{
        Name = ('branch {0}' -f $env:ETHERBEEP_BRANCH)
        Base = ('https://raw.githubusercontent.com/{0}/{1}' -f $repo, $env:ETHERBEEP_BRANCH)
        Note = ('using test branch {0}, not a published release' -f $env:ETHERBEEP_BRANCH)
    }
}
else {
    $sources += @{
        Name = 'latest release'
        Base = ('https://github.com/{0}/releases/latest/download' -f $repo)
        Note = $null
    }
    $sources += @{
        Name = 'main branch'
        Base = ('https://raw.githubusercontent.com/{0}/main' -f $repo)
        Note = 'no published release found, using the newest development version'
    }
}

Write-Host ''
Write-Host '  Etherbeep web installer' -ForegroundColor Cyan
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray

# Windows PowerShell 5.1 on an older Windows 10 build may still default to TLS 1.0,
# which GitHub refuses. Add TLS 1.2 to whatever is already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('etherbeep-install-' + $stamp)
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    $got = $false
    $lastError = ''

    foreach ($source in $sources) {
        $complete = $true
        foreach ($file in $files) {
            $url = '{0}/{1}' -f $source.Base, $file
            try {
                Invoke-WebRequest -Uri $url -OutFile (Join-Path $work $file) -UseBasicParsing
            }
            catch {
                $lastError = '{0}: {1}' -f $url, $_.Exception.Message
                $complete = $false
                break
            }
        }

        if ($complete) {
            if ($source.Note) {
                Write-Host ('  note: {0}' -f $source.Note) -ForegroundColor Yellow
            }
            Write-Host ('  downloaded from the {0}' -f $source.Name) -ForegroundColor Gray
            $got = $true
            break
        }
    }

    if (-not $got) {
        Write-Host ''
        Write-Host '  Could not download Etherbeep.' -ForegroundColor Red
        Write-Host ('  Last error: {0}' -f $lastError) -ForegroundColor Red
        Write-Host ''
        Write-Host '  Check that this PC can reach github.com, then try again.' -ForegroundColor Yellow
        Write-Host '  You can also download it in a browser from:' -ForegroundColor Yellow
        Write-Host ('    https://github.com/{0}/releases/latest' -f $repo) -ForegroundColor Yellow
        Write-Host ''
        return
    }

    # The files never touched a browser, so they carry no Mark of the Web, but
    # clear it anyway in case a proxy or AV product added one.
    foreach ($file in $files) {
        try { Unblock-File -LiteralPath (Join-Path $work $file) -ErrorAction Stop } catch { }
    }

    $installer = Join-Path $work 'Install-Etherbeep.ps1'
    if ($Startup) {
        & $installer -Startup
    }
    else {
        & $installer
    }
}
finally {
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { }
}
