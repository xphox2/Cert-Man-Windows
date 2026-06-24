<#
.SYNOPSIS
    Bootstrap win-acme on a Windows Server: download the latest release, extract,
    unblock the DLLs, and write a baseline settings.json.

.DESCRIPTION
    Used by Runbooks 01/02/03. Idempotent — re-running upgrades the binaries in place
    and rewrites settings.json from the supplied parameters.

.PARAMETER InstallPath
    Folder to install win-acme into. Default C:\win-acme.

.PARAMETER NotifyEmail
    Ops address that win-acme emails on renewal FAILURE. Recommended.

.PARAMETER SmtpServer
    SMTP server for failure notifications (optional but recommended).

.PARAMETER Staging
    Point settings.json at the Let's Encrypt STAGING directory. ALWAYS use this first.
    Omit (or use -Production) only after a successful staging run.

.PARAMETER RenewalDays
    Renew when the cert is this many days old. 55 for 90-day certs (default),
    ~20 for 45-day certs.

.EXAMPLE
    .\Install-WinAcme.ps1 -NotifyEmail ops@example.com -SmtpServer smtp.example.com -Staging

.NOTES
    Run elevated. The renewal scheduled task runs as SYSTEM.
    win-acme: https://www.win-acme.com/  (successor fork: https://simple-acme.com/)
#>
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\win-acme',
    [string]$NotifyEmail,
    [string]$SmtpServer,
    [int]$SmtpPort = 587,
    [string]$SmtpUser,
    [string]$SmtpPassword,
    [switch]$Staging,
    [switch]$Production,
    [int]$RenewalDays = 55,
    [ValidateSet('cloudflare', 'azure', 'godaddy', 'route53', 'digitalocean')]
    [string[]]$DnsPlugin
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell prompt.'
}

$useStaging = $true
if ($Production) { $useStaging = $false }
elseif ($Staging) { $useStaging = $true }
else {
    Write-Warning 'Neither -Staging nor -Production specified; defaulting to STAGING (safe).'
}
$baseUri = if ($useStaging) {
    'https://acme-staging-v02.api.letsencrypt.org/directory'
} else {
    'https://acme-v02.api.letsencrypt.org/directory'
}

Write-Host "==> Installing win-acme to $InstallPath (endpoint: $baseUri)" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

# --- Download latest x64 PLUGGABLE release ---------------------------------
# Use the pluggable build (NOT trimmed): the trimmed build cannot load the external
# DNS validation plugins (Cloudflare/Azure/GoDaddy) that wildcard/DNS-01 issuance needs.
Write-Host '==> Resolving latest release from GitHub...'
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/win-acme/win-acme/releases/latest' `
    -Headers @{ 'User-Agent' = 'winacme-bootstrap' }
$asset = $release.assets | Where-Object name -like '*x64.pluggable.zip' | Select-Object -First 1
if (-not $asset) { throw 'Could not find an x64.pluggable.zip asset on the latest release.' }

$zip = Join-Path $env:TEMP $asset.name
Write-Host "==> Downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip

Write-Host '==> Extracting...'
Expand-Archive -Path $zip -DestinationPath $InstallPath -Force
Remove-Item $zip -Force

# --- Optional: install DNS validation plugin(s) (separate downloads) -------
foreach ($p in $DnsPlugin) {
    $match = "plugin.validation.dns.$p"
    $pa = $release.assets | Where-Object { $_.name -like "$match.*.zip" } | Select-Object -First 1
    if (-not $pa) { Write-Warning "DNS plugin '$p' not found in latest release; skipping."; continue }
    Write-Host "==> Installing DNS plugin: $($pa.name)..."
    $pz = Join-Path $env:TEMP $pa.name
    Invoke-WebRequest -Uri $pa.browser_download_url -OutFile $pz
    Expand-Archive -Path $pz -DestinationPath $InstallPath -Force
    Remove-Item $pz -Force
}

Write-Host '==> Unblocking DLLs/EXE...'
Get-ChildItem -Path $InstallPath -Include *.dll, *.exe -Recurse | Unblock-File

# --- Write baseline settings.json ------------------------------------------
Write-Host '==> Writing settings.json...'
$settings = [ordered]@{
    BaseUri       = $baseUri
    ScheduledTask = [ordered]@{
        RenewalDays        = $RenewalDays
        RenewalDaysRange   = 0
        StartBoundary      = '09:00:00'
        RandomDelay        = '04:00:00'
        ExecutionTimeLimit = '02:00:00'
    }
    Store         = [ordered]@{
        CertificateStore = [ordered]@{ DefaultStore = 'My' }
        PfxFile          = [ordered]@{ DefaultPath = 'C:\certs' }
    }
}
if ($NotifyEmail) {
    $settings.Notification = [ordered]@{
        SmtpServer        = $SmtpServer
        SmtpPort          = $SmtpPort
        SmtpUser          = $SmtpUser
        SmtpPassword      = $SmtpPassword
        SenderAddress     = "letsencrypt@$($env:COMPUTERNAME)"
        ReceiverAddresses = @($NotifyEmail)
        EmailOnSuccess    = $false
    }
}
$settingsPath = Join-Path $InstallPath 'settings.json'
$settings | ConvertTo-Json -Depth 6 | Set-Content -Path $settingsPath -Encoding UTF8

# Lock down the folder to SYSTEM + Administrators (account key lives here)
Write-Host '==> Restricting folder ACL to SYSTEM + Administrators...'
icacls $InstallPath /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

Write-Host ''
Write-Host "win-acme installed at $InstallPath" -ForegroundColor Green
Write-Host "  Endpoint : $baseUri"
Write-Host "  Settings : $settingsPath"
Write-Host ''
Write-Host 'Next: issue a certificate per Runbook 01 (HTTP-01) or 02 (DNS-01).' -ForegroundColor Yellow
if ($useStaging) {
    Write-Host 'You are on STAGING. After a successful test run, re-run with -Production and re-issue.' -ForegroundColor Yellow
}
