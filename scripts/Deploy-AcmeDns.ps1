<#
.SYNOPSIS
    Stand up an acme-dns server in one command (Docker): generate config.cfg, run the container,
    verify, and print the DNS delegation records you must add. See Runbook 09.

.DESCRIPTION
    acme-dns is the universal, auto-renewing answer for registrars with no DNS API (Network
    Solutions, etc.): you run ONE acme-dns server and every customer adds a single CNAME to it.
    This script writes config.cfg from your parameters and launches the official container with the
    correct ports (53/udp+tcp, 80, 443) and persistent volumes.

    Requires Docker (Docker Desktop on Windows, or docker on Linux). Cross-platform: runs under
    Windows PowerShell or PowerShell 7 (pwsh) on Linux.

.PARAMETER Domain
    The subdomain you will delegate to this server, e.g. auth.xphox.net. acme-dns becomes
    authoritative for it.

.PARAMETER PublicIP
    The public IP of THIS host (used for the self A/glue record acme-dns answers for its zone).

.PARAMETER NsAdmin
    SOA contact mailbox in DNS form, e.g. admin.xphox.net (= admin@xphox.net). Defaults to
    admin.<parent-of-Domain>.

.PARAMETER NotificationEmail
    Email for the API's own Let's Encrypt certificate (when -ApiTls letsencrypt).

.PARAMETER ApiTls
    'letsencrypt' (default; acme-dns gets its own cert on :443 once DNS resolves to it) or 'none'
    (HTTP-only on :80 for quick local testing).

.PARAMETER DisableRegistration
    Set after you've registered all accounts so nobody can create new ones.

.PARAMETER BasePath
    Folder for config + data (sqlite DB, API certs). Default ./acme-dns.

.PARAMETER Image
    Container image. Default joohoi/acme-dns.

.EXAMPLE
    .\Deploy-AcmeDns.ps1 -Domain auth.xphox.net -PublicIP 198.51.100.10 -NotificationEmail admin@xphox.net

.NOTES
    After it runs, add the delegation records it prints (NS + glue A) at your PARENT zone. Full
    guide + hardening + onboarding: Runbook 09 (09-AcmeDNS-Server-Setup.md).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Domain,
    [Parameter(Mandatory)][string]$PublicIP,
    [string]$NsAdmin,
    [string]$NotificationEmail = '',
    [ValidateSet('letsencrypt', 'none')][string]$ApiTls = 'letsencrypt',
    [switch]$DisableRegistration,
    [string]$BasePath = './acme-dns',
    [string]$Image = 'joohoi/acme-dns'
)

$ErrorActionPreference = 'Stop'
function Say { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }

# --- Preconditions ----------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker not found. Install Docker (Desktop on Windows, or docker on Linux) and retry.'
}
if (-not $NsAdmin) {
    $parent = ($Domain -split '\.', 2)[1]
    $NsAdmin = if ($parent) { "admin.$parent" } else { "admin.$Domain" }
}
$apiPort = if ($ApiTls -eq 'none') { '80' } else { '443' }
$disableReg = if ($DisableRegistration) { 'true' } else { 'false' }

$cfgDir = Join-Path $BasePath 'config'
$dataDir = Join-Path $BasePath 'data'
New-Item -ItemType Directory -Path $cfgDir, $dataDir -Force | Out-Null
$cfgDirFull = (Resolve-Path $cfgDir).Path
$dataDirFull = (Resolve-Path $dataDir).Path

# --- Generate config.cfg ----------------------------------------------------
Write-Host "`n=== Deploying acme-dns for $Domain ===" -ForegroundColor Cyan
$cfg = @"
[general]
listen   = "0.0.0.0:53"
protocol = "both"
domain   = "$Domain"
nsname   = "$Domain"
nsadmin  = "$NsAdmin"
records  = [
    "$Domain. A $PublicIP",
    "$Domain. NS $Domain.",
]
debug = false

[database]
engine     = "sqlite3"
connection = "/var/lib/acme-dns/acme-dns.db"

[api]
ip                   = "0.0.0.0"
port                 = "$apiPort"
tls                  = "$ApiTls"
notification_email   = "$NotificationEmail"
acme_cache_dir       = "api-certs"
disable_registration = $disableReg
corsorigins          = ["*"]
use_header           = false
header_name          = "X-Forwarded-For"

[logconfig]
loglevel  = "info"
logtype   = "stdout"
logformat = "text"
"@
$cfgPath = Join-Path $cfgDir 'config.cfg'
Set-Content -Path $cfgPath -Value $cfg -Encoding ascii -NoNewline
Say "Wrote $cfgPath" 'Green'

# --- Run the container ------------------------------------------------------
docker rm -f acme-dns 2>$null | Out-Null
$ports = @('-p', '53:53', '-p', '53:53/udp', '-p', '80:80')
if ($ApiTls -ne 'none') { $ports += @('-p', '443:443') }
$dockerArgs = @('run', '-d', '--name', 'acme-dns', '--restart', 'unless-stopped') + $ports +
              @('-v', "${cfgDirFull}:/etc/acme-dns:ro", '-v', "${dataDirFull}:/var/lib/acme-dns", $Image)
Say "docker $($dockerArgs -join ' ')" 'DarkGray'
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw 'docker run failed (is the image reachable / ports free?).' }
Start-Sleep -Seconds 2
$running = (& docker ps --filter 'name=acme-dns' --format '{{.Status}}')
if ($running) { Say "Container running: $running" 'Green' } else { Say 'Container not running - check: docker logs acme-dns' 'Yellow' }

# --- Next steps -------------------------------------------------------------
Write-Host "`n=== ACTION REQUIRED: delegate $Domain to this host ===" -ForegroundColor Yellow
Write-Host "  Add these records in the PARENT zone (e.g. $(($Domain -split '\.',2)[1])):" -ForegroundColor Yellow
Write-Host ("    {0,-22} A    {1}    (glue)" -f $Domain, $PublicIP) -ForegroundColor White
Write-Host ("    {0,-22} NS   {0}." -f $Domain) -ForegroundColor White
Write-Host ''
Write-Host '  Then verify (once DNS propagates):' -ForegroundColor Cyan
Write-Host ("    dig NS $Domain +short") -ForegroundColor Gray
Write-Host ("    curl -i {0}://$Domain/register -X POST -H 'Content-Type: application/json' -d '{{}}'" -f $(if ($ApiTls -eq 'none') { 'http' } else { 'https' })) -ForegroundColor Gray
if ($ApiTls -ne 'none') { Write-Host "  (acme-dns obtains its API TLS cert automatically once $Domain resolves to this host.)" -ForegroundColor DarkGray }
Write-Host ''
Write-Host '  Onboarding a customer domain, hardening, and HA: Runbook 09 (09-AcmeDNS-Server-Setup.md).' -ForegroundColor DarkGray
Write-Host '  Then on a cert server: preflight.ps1 / setup-iis.ps1 -> choose acme-dns -> server URL above.' -ForegroundColor DarkGray
Write-Host ''
