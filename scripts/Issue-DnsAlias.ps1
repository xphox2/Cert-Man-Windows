<#
.SYNOPSIS
    Issue a Let's Encrypt cert for a domain whose registrar has NO DNS API (Network Solutions, etc.)
    using Posh-ACME DNS challenge aliases - pure Windows PowerShell, no acme-dns server.

.DESCRIPTION
    DNS-01 needs a TXT at _acme-challenge.<domain>. If the registrar has no API, nothing can write
    there automatically. The fix: add ONE static CNAME at the registrar that redirects _acme-challenge
    to a delegation zone you DO control (Azure DNS, Cloudflare, Route53, or your own). Posh-ACME then
    writes the TXT into THAT zone with its plugin; Let's Encrypt follows the CNAME. Auto-renews, and
    the registrar is never touched again.

    This is provider-agnostic: you pick the delegation zone's DNS provider at runtime - nothing is
    assumed about the cert domain's DNS. Runs on Windows PowerShell 5.1+ (and pwsh).

.PARAMETER Domain
    Cert name(s). Wildcard + apex of the same root share one challenge, e.g. '*.example.com','example.com'.

.PARAMETER DnsAlias
    The FQDN in YOUR delegation zone where the TXT is written, e.g. example.acme.xphox.net. Your CNAME
    points _acme-challenge.<domain> at this. One value covers wildcard + apex of the same root.

.PARAMETER Contact
    Account contact email for Let's Encrypt.

.PARAMETER Production
    Use the Let's Encrypt PRODUCTION endpoint. Omit to use STAGING (recommended first - no rate limits).

.PARAMETER PfxPass
    Password for the generated PFX (default: poshacme).

.PARAMETER RegisterRenewTask
    Also register a daily SYSTEM scheduled task that runs Submit-Renewal unattended.

.EXAMPLE
    .\Issue-DnsAlias.ps1                       # fully interactive (staging)
.EXAMPLE
    .\Issue-DnsAlias.ps1 -Domain '*.example.com','example.com' -DnsAlias example.acme.xphox.net -Contact me@xphox.net -Production

.NOTES
    Delegation zone setup: in YOUR zone (e.g. acme.xphox.net) you just need to be able to create records
    via the chosen provider's API. The CNAME at the no-API registrar is created ONCE. See Runbook 02 SectionA.
#>
[CmdletBinding()]
param(
    [string[]]$Domain,
    [string]$DnsAlias,
    [string]$Contact,
    [switch]$Production,
    [string]$PfxPass = 'poshacme',
    [switch]$RegisterRenewTask
)

$ErrorActionPreference = 'Stop'
function Say { param($m, $c = 'Gray') Write-Host $m -ForegroundColor $c }

# Shared config home so an interactive run and the renewal task see the same orders.
$env:POSHACME_HOME = 'C:\ProgramData\Posh-ACME'
New-Item -ItemType Directory -Path $env:POSHACME_HOME -Force | Out-Null

Write-Host ''
Say '=== Issue Let''s Encrypt cert via DNS alias (Posh-ACME, no acme-dns server) ===' 'Cyan'

# --- Ensure Posh-ACME -------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
    Say 'Installing Posh-ACME module (CurrentUser)...' 'Yellow'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module Posh-ACME -Scope CurrentUser -Force
}
Import-Module Posh-ACME

# --- Endpoint ---------------------------------------------------------------
$server = if ($Production) { 'LE_PROD' } else { 'LE_STAGE' }
Set-PAServer $server
Say ("ACME endpoint: {0}" -f $(if ($Production) { 'PRODUCTION' } else { 'STAGING (test - no rate-limit cost)' })) $(if ($Production) { 'Red' } else { 'Green' })

# --- Gather request ---------------------------------------------------------
if (-not $Domain) {
    $raw = Read-Host 'Cert name(s), comma-separated (e.g. *.example.com,example.com)'
    $Domain = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $Contact) { $Contact = Read-Host 'Contact email for the Let''s Encrypt account' }
if (-not $DnsAlias) {
    Say ''
    Say 'The DNS ALIAS is a name in a delegation zone YOU control where the TXT will be written,'
    Say 'e.g. example.acme.xphox.net (you must control the acme.xphox.net zone via an API below).'
    $DnsAlias = Read-Host 'DNS alias FQDN'
}

# --- Delegation provider (the zone that holds the alias) ---------------------
function Get-DelegationPlugin {
    Say ''
    Say 'Delegation zone DNS provider (where the alias record lives):' 'White'
    Say '  1) Cloudflare' 'White'
    Say '  2) Azure DNS' 'White'
    Say '  3) Route53 (AWS)' 'White'
    Say '  4) Other Posh-ACME plugin (enter args by hand)' 'White'
    switch (Read-Host 'Choose 1-4') {
        '1' { $t = Read-Host -AsSecureString 'Cloudflare API token (Zone.DNS edit on the delegation zone)'; return @{ Plugin = 'Cloudflare'; Args = @{ CFToken = $t } } }
        '2' {
            $sub = Read-Host 'Azure Subscription ID'; $ten = Read-Host 'Azure Tenant ID'
            $app = Read-Host 'Azure App (client) ID'; $sec = Read-Host -AsSecureString 'Azure client secret'
            $cred = New-Object System.Management.Automation.PSCredential($app, $sec)
            return @{ Plugin = 'Azure'; Args = @{ AZSubscriptionId = $sub; AZTenantId = $ten; AZAppCred = $cred } }
        }
        '3' { $ak = Read-Host 'AWS Access Key ID'; $sk = Read-Host -AsSecureString 'AWS Secret Access Key'; return @{ Plugin = 'Route53'; Args = @{ R53AccessKey = $ak; R53SecretKey = $sk } } }
        '4' {
            $pl = Read-Host 'Posh-ACME plugin name (see https://poshac.me/docs/v4/Plugins/)'
            Say 'Enter PluginArgs as key=value lines; blank line to finish. For secrets use the plugin''s *Insecure key.' 'DarkGray'
            $h = @{}
            while ($true) { $l = Read-Host 'key=value (blank = done)'; if (-not $l) { break }; $kv = $l -split '=', 2; if ($kv.Count -eq 2) { $h[$kv[0].Trim()] = $kv[1].Trim() } }
            return @{ Plugin = $pl; Args = $h }
        }
        default { return $null }
    }
}
$sel = Get-DelegationPlugin
if (-not $sel) { Say 'No provider chosen; aborting.' 'Yellow'; return }

# --- The one-time CNAME(s) to create at the registrar -----------------------
$challengeNames = @($Domain | ForEach-Object { '_acme-challenge.' + ($_ -replace '^\*\.', '') } | Sort-Object -Unique)
Say ''
Say '=== CREATE THIS CNAME at the cert domain''s registrar (one time, then never again) ===' 'Yellow'
foreach ($c in $challengeNames) { Write-Host ("    {0,-45} CNAME   {1}" -f ($c + '.'), ($DnsAlias + '.')) -ForegroundColor White }
Say ''
Say "win-acme/Posh-ACME will write the TXT at $DnsAlias in your delegation zone; the CA follows the CNAME." 'DarkGray'
$null = Read-Host 'Create the CNAME(s) above, wait ~1 min for propagation, then press ENTER to issue'

# --- Issue ------------------------------------------------------------------
$certParams = @{
    Domain = $Domain; AcceptTOS = $true; Contact = $Contact
    Plugin = $sel.Plugin; PluginArgs = $sel.Args; DnsAlias = $DnsAlias
    PfxPass = $PfxPass; Force = $true; Verbose = $true
}
Say ''
Say "Issuing $($Domain -join ', ') via delegation plugin '$($sel.Plugin)'..." 'Cyan'
New-PACertificate @certParams

$cert = Get-PACertificate
if (-not $cert) { Say 'Issuance did not produce a certificate - review the output above.' 'Red'; return }
Say ''
Say '=== ISSUED ===' 'Green'
Say ("  Names    : {0}" -f ($cert.AllSANs -join ', '))
Say ("  Expires  : {0}" -f $cert.NotAfter)
Say ("  PFX      : {0}" -f $cert.PfxFullChain)
Say ("  PFX pass : {0}" -f $PfxPass)
Say ("  Cert/Key : {0}" -f $cert.CertFile)
Say ''
Say 'Renew anytime with:  Submit-Renewal -AllOrders   (Posh-ACME stored the plugin, args, and alias).' 'DarkGray'

# --- Optional unattended renewal task ---------------------------------------
if ($RegisterRenewTask) {
    try {
        # Portable encryption so a SYSTEM-run task can decrypt the stored plugin creds.
        Set-PAAccount -UseAltPluginEncryption:$true -ErrorAction SilentlyContinue
        $cmd = "`$env:POSHACME_HOME='C:\ProgramData\Posh-ACME'; Import-Module Posh-ACME; Submit-Renewal -AllOrders"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        $trigger = New-ScheduledTaskTrigger -Daily -At 3am
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'PoshACME-Renew' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Say 'Registered daily renewal task "PoshACME-Renew" (SYSTEM, 03:00).' 'Green'
    } catch { Say ("Could not register renewal task: {0}" -f $_.Exception.Message) 'Yellow' }
}
Say ''
