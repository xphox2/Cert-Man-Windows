<#
.SYNOPSIS
    Set up IIS for Let's Encrypt automation: install the web-server role + management/scripting
    tools, and (optionally) create a website with host-name bindings.

.DESCRIPTION
    The preflight (preflight.ps1) only validates ACME + DNS. This script handles the IIS
    scenario separately, so each concern is its own callable script.

    With no site parameters it just installs/repairs the IIS role and the PowerShell module.
    Give -SiteName + -HostNames to also create a site with HTTP bindings (so win-acme can
    discover/secure it). HTTPS bindings are added later by win-acme during issuance.

.PARAMETER SiteName
    Name of the IIS website to create (optional). If it already exists, bindings are added to it.

.PARAMETER HostNames
    One or more host names to bind (e.g. app.example.com, portal.example.com).

.PARAMETER PhysicalPath
    Site root folder. Default C:\inetpub\<SiteName>.

.PARAMETER Port
    HTTP port for the bindings. Default 80.

.PARAMETER AppPool
    App pool name. Default = SiteName. Created if missing.

.EXAMPLE
    # Just install the IIS role + tools:
    .\Setup-IIS.ps1

.EXAMPLE
    # Install IIS and create a site bound to three host names:
    .\Setup-IIS.ps1 -SiteName Wildcards -HostNames app.example.com,portal.example.com,api.example.com

.NOTES
    Run elevated. Companion to preflight.ps1 and Runbooks 01/02. Idempotent.
#>
[CmdletBinding()]
param(
    [string]$SiteName,
    [string[]]$HostNames,
    [string]$PhysicalPath,
    [int]$Port = 80,
    [string]$AppPool
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell prompt.'
}

# --- 1. Install IIS role + management/scripting tools -----------------------
Write-Host '==> Ensuring IIS web-server role + management tools...' -ForegroundColor Cyan
$feat = Get-WindowsFeature -Name Web-Server
if (-not $feat.Installed) {
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Write-Host '    IIS Web-Server role installed.'
} else { Write-Host '    IIS Web-Server role already installed.' }
# WebAdministration PowerShell module (for scripting bindings)
Install-WindowsFeature -Name Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null

Import-Module WebAdministration -ErrorAction Stop
Write-Host '    WebAdministration module loaded.' -ForegroundColor Green

# --- 2. Optionally create a website + host-name bindings --------------------
if ($SiteName) {
    if (-not $PhysicalPath) { $PhysicalPath = Join-Path 'C:\inetpub' $SiteName }
    if (-not $AppPool) { $AppPool = $SiteName }

    New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null

    if (-not (Test-Path "IIS:\AppPools\$AppPool")) {
        New-WebAppPool -Name $AppPool | Out-Null
        Write-Host "==> Created app pool '$AppPool'." -ForegroundColor Cyan
    }

    $hosts = @($HostNames)
    if ($hosts.Count -eq 0) { $hosts = @('') }   # default binding with no host header

    if (-not (Test-Path "IIS:\Sites\$SiteName")) {
        $first = $hosts[0]
        New-Website -Name $SiteName -PhysicalPath $PhysicalPath -ApplicationPool $AppPool `
            -Port $Port -HostHeader $first -Force | Out-Null
        Write-Host "==> Created site '$SiteName' -> $PhysicalPath (pool '$AppPool')." -ForegroundColor Cyan
        $rest = $hosts | Select-Object -Skip 1
    } else {
        Write-Host "==> Site '$SiteName' already exists; adding bindings." -ForegroundColor Cyan
        $rest = $hosts
    }

    foreach ($h in $rest) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        $exists = Get-WebBinding -Name $SiteName -Protocol http -ErrorAction SilentlyContinue |
            Where-Object { $_.bindingInformation -eq "*:$Port`:$h" }
        if (-not $exists) {
            New-WebBinding -Name $SiteName -Protocol http -Port $Port -HostHeader $h | Out-Null
            Write-Host "    + http binding  *:$Port`:$h"
        }
    }

    # Drop a placeholder page so the site responds
    $index = Join-Path $PhysicalPath 'index.html'
    if (-not (Test-Path $index)) {
        Set-Content -Path $index -Value "<html><body><h1>$SiteName</h1><p>Ready for Let's Encrypt.</p></body></html>" -Encoding UTF8
    }

    Write-Host ''
    Write-Host "Site '$SiteName' is ready. Current bindings:" -ForegroundColor Green
    Get-WebBinding -Name $SiteName | Select-Object protocol, bindingInformation | Format-Table -AutoSize
}

Write-Host ''
Write-Host 'IIS setup complete.' -ForegroundColor Green
Write-Host 'Next: issue certificates with Runbook 01 (HTTP-01) or Runbook 02 (DNS-01 / wildcard).' -ForegroundColor Yellow
