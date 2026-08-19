<#
.SYNOPSIS
    One-line web installer for Etherbeep. Downloads the current release from GitHub
    and runs the normal installer. No admin rights needed.

.DESCRIPTION
    This is the script behind the QR code on the shop wall. Run it with:

        irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1 | iex

    It downloads Etherbeep.ps1, Etherbeep.cmd and Install-Etherbeep.ps1 into a
    temporary folder and then runs Install-Etherbeep.ps1, which does the actual
    install: copy to %LOCALAPPDATA%\Etherbeep, desktop and Start menu shortcuts,
    user PATH. Nothing here needs an administrator and nothing is written outside
    your own user profile.

    Running through "iex" applies no execution policy, so this works on a locked
    down bench PC exactly as it comes.

.PARAMETER Startup
    Also start Etherbeep automatically at logon. To pass it through the one-liner:

        iex "& { $(irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1) } -Startup"

.NOTES
    To test an unmerged branch, set ETHERBEEP_BRANCH before running:

        $env:ETHERBEEP_BRANCH = 'some-branch'; irm ... | iex
#>
[CmdletBinding()]
param(
    [switch]$Startup
)

$ErrorActionPreference = 'Stop'

$repo = 'xtopher757/Etherbeep'
$branch = 'main'
if ($env:ETHERBEEP_BRANCH) { $branch = $env:ETHERBEEP_BRANCH }

$files = @('Etherbeep.ps1', 'Etherbeep.cmd', 'Install-Etherbeep.ps1')
$baseUrl = 'https://raw.githubusercontent.com/{0}/{1}' -f $repo, $branch

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
    foreach ($file in $files) {
        $url = '{0}/{1}' -f $baseUrl, $file
        $target = Join-Path $work $file
        Write-Host ('  downloading {0}' -f $file) -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
        }
        catch {
            Write-Host ''
            Write-Host ('  Could not download {0}' -f $url) -ForegroundColor Red
            Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host ''
            Write-Host '  Check that this PC can reach github.com, then try again.' -ForegroundColor Yellow
            Write-Host '  You can also download the folder in a browser from:' -ForegroundColor Yellow
            Write-Host ('    https://github.com/{0}' -f $repo) -ForegroundColor Yellow
            Write-Host ''
            return
        }
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
