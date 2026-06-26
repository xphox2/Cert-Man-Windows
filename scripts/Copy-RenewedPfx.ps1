<#
.SYNOPSIS
    Copy renewed PFX file(s) from a source folder to one or more destinations. Designed as a
    win-acme POST-RENEWAL hook so other devices/services get the fresh cert automatically.

.DESCRIPTION
    win-acme writes the renewed PFX into the pfxfile store folder on every renewal. Point this
    script at that folder and at your destination(s); it copies the *.pfx out and logs the result.

    `setup-iis.ps1` can generate and wire an equivalent hook for you automatically (PFX export ->
    "Auto-copy after each renewal"). Use THIS script when wiring a renewal manually, e.g.:

        wacs.exe ... --installation iis,script `
            --script "C:\win-acme\Copy-RenewedPfx.ps1" `
            --scriptparameters "-SourceDir 'C:\win-acme' -Destinations '\\dev1\certs','\\dev2\certs'"

.PARAMETER SourceDir
    Folder win-acme writes the PFX into (the --pfxfilepath / pfxfile store folder).

.PARAMETER Destinations
    One or more destination folders (local or UNC) to copy every *.pfx into.

.PARAMETER LogFile
    Append a one-line result per destination here. Default C:\win-acme\post-renew-copy.log.

.NOTES
    win-acme's renewal task runs as SYSTEM. For UNC destinations the COMPUTER account
    (DOMAIN\MACHINE$) must have write access, or each device should PULL from a local share here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string[]]$Destinations,
    [string]$LogFile = 'C:\win-acme\post-renew-copy.log'
)

$ErrorActionPreference = 'Stop'
$logDir = Split-Path $LogFile -Parent
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$pfx = @(Get-ChildItem -Path (Join-Path $SourceDir '*.pfx') -ErrorAction SilentlyContinue)
if (-not $pfx) { ("{0} WARN no PFX found in {1}" -f (Get-Date -Format s), $SourceDir) | Add-Content $LogFile; return }

foreach ($dst in $Destinations) {
    try {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item -Path (Join-Path $SourceDir '*.pfx') -Destination $dst -Force -ErrorAction Stop
        ("{0} OK   {1} file(s) -> {2}" -f (Get-Date -Format s), $pfx.Count, $dst) | Add-Content $LogFile
    } catch {
        ("{0} FAIL -> {1} : {2}" -f (Get-Date -Format s), $dst, $_.Exception.Message) | Add-Content $LogFile
    }
}
