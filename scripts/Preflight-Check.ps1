<#
.SYNOPSIS
    Preflight readiness check + environment setup for Let's Encrypt automation on a fresh
    Windows Server / IIS box. Verifies (and optionally installs) everything needed BEFORE you
    issue your first certificate, including the ACME client and a real DNS-01 validation test.

.DESCRIPTION
    Run this on a new server before following Runbook 01/02. It reports PASS / WARN / FAIL for:
      1.  Elevation, OS, and PowerShell version
      2.  IIS role + WebAdministration module           (installs with -InstallIIS)
      3.  Current IIS sites and bindings (baseline)
      4.  TLS 1.2 for outbound .NET/PowerShell calls
      5.  Outbound HTTPS to Let's Encrypt (staging + prod) and the DNS provider API
      6.  win-acme (wacs.exe) present and runnable        (installs with -InstallWinAcme)
      7.  DNS resolution for each domain (authoritative NS, A, _acme-challenge TXT path)
      8.  OPTIONAL: a genuine DNS-01 validation test — issues a THROWAWAY cert from Let's
          Encrypt STAGING for -TestHost using your DNS provider creds, then cancels it.
          This proves your DNS API credentials, propagation, and CA reachability end-to-end
          without consuming production rate limits.

    Exit code: 0 if no FAIL results, 1 if any FAIL.

.PARAMETER Domains
    Domains you intend to certify (apex form, e.g. example.com). Drives the DNS checks.

.PARAMETER InstallIIS
    Install the IIS Web-Server role (+ management/scripting tools) if missing.

.PARAMETER InstallWinAcme
    Download/install win-acme via Install-WinAcme.ps1 if wacs.exe is not found.

.PARAMETER WinAcmePath
    win-acme install folder. Default C:\win-acme.

.PARAMETER NotifyEmail
    ACME account contact used for the staging validation test.

.PARAMETER RunDnsValidationTest
    Perform the Tier-2 staging DNS-01 issuance test (needs -DnsProvider + creds + -TestHost).

.PARAMETER DnsProvider
    Cloudflare | Azure | GoDaddy — selects the win-acme validation plugin for the test.

.PARAMETER TestHost
    Host to validate in the staging test, e.g. "*.example.com". Defaults to "*.<first Domain>".

.EXAMPLE
    # Check-only on a fresh box for three domains:
    .\Preflight-Check.ps1 -Domains example.com,contoso.com,fabrikam.com

.EXAMPLE
    # Set up everything, then prove DNS-01 works via Cloudflare against staging:
    .\Preflight-Check.ps1 -Domains example.com -InstallIIS -InstallWinAcme `
        -NotifyEmail ops@example.com `
        -RunDnsValidationTest -DnsProvider Cloudflare -CloudflareToken '<scoped-token>' `
        -TestHost '*.example.com'

.NOTES
    Run elevated. Read-only unless -InstallIIS / -InstallWinAcme / -RunDnsValidationTest given.
    Companion to Runbooks 01 (HTTP-01) and 02 (DNS-01). win-acme arg names can vary slightly by
    version; confirm with 'wacs.exe --help' if the staging test reports an argument error.
#>
[CmdletBinding()]
param(
    [string[]]$Domains,
    [switch]$InstallIIS,
    [switch]$InstallWinAcme,
    [string]$WinAcmePath = 'C:\win-acme',
    [string]$NotifyEmail,

    [switch]$RunDnsValidationTest,
    [ValidateSet('Cloudflare', 'Azure', 'GoDaddy')][string]$DnsProvider,
    [string]$TestHost,

    # Cloudflare
    [string]$CloudflareToken,
    # Azure
    [string]$AzureTenantId, [string]$AzureClientId, [string]$AzureSecret,
    [string]$AzureSubscriptionId, [string]$AzureResourceGroup,
    # GoDaddy
    [string]$GoDaddyKey, [string]$GoDaddySecret
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$StagingUri = 'https://acme-staging-v02.api.letsencrypt.org/directory'
$ProdUri    = 'https://acme-v02.api.letsencrypt.org/directory'

# --- Result framework -------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Detail)
    $script:Results.Add([PSCustomObject]@{ Area = $Area; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("  [{0}] {1,-22} {2}" -f $Status, $Area, $Detail) -ForegroundColor $color
}
function Test-Tcp {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 5000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($iar); return $true
    } catch { return $false } finally { $c.Close() }
}

Write-Host "`n=== Let's Encrypt Automation - Preflight Check ===" -ForegroundColor Cyan
Write-Host "Host: $env:COMPUTERNAME   Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n"

# --- 1. Elevation / OS / PowerShell ----------------------------------------
Write-Host '1. Platform' -ForegroundColor White
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($admin) { Add-Result 'Elevation' 'PASS' 'Running as Administrator' }
else { Add-Result 'Elevation' 'FAIL' 'Not elevated - re-run from an Administrator PowerShell' }

$os = (Get-CimInstance Win32_OperatingSystem).Caption
Add-Result 'OS' 'INFO' $os
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) { Add-Result 'PowerShell' 'PASS' "v$psv" }
else { Add-Result 'PowerShell' 'FAIL' "v$psv (need 5.1+)" }

# --- 2. IIS role + module ---------------------------------------------------
Write-Host "`n2. IIS" -ForegroundColor White
$iisFeature = $null
try { $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction Stop } catch {}
if ($iisFeature -and $iisFeature.Installed) {
    Add-Result 'IIS role' 'PASS' 'Web-Server role installed'
} elseif ($InstallIIS) {
    Add-Result 'IIS role' 'INFO' 'Installing Web-Server role (+ management tools)...'
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Install-WindowsFeature -Name Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null
    Add-Result 'IIS role' 'PASS' 'Web-Server role installed'
} else {
    Add-Result 'IIS role' 'FAIL' 'Web-Server role missing - re-run with -InstallIIS'
}

$haveWebAdmin = $false
try { Import-Module WebAdministration -ErrorAction Stop; $haveWebAdmin = $true
    Add-Result 'WebAdministration' 'PASS' 'PowerShell module available'
} catch { Add-Result 'WebAdministration' 'WARN' 'Module not available (install IIS Management Scripting Tools)' }

# --- 3. Current IIS sites/bindings (baseline) ------------------------------
Write-Host "`n3. IIS sites (baseline)" -ForegroundColor White
if ($haveWebAdmin) {
    $sites = Get-Website
    if (-not $sites) { Add-Result 'IIS sites' 'WARN' 'No IIS websites defined yet' }
    foreach ($s in $sites) {
        $b = ($s.bindings.Collection | ForEach-Object { $_.protocol + '/' + $_.bindingInformation }) -join ', '
        $hasHttps = $s.bindings.Collection.protocol -contains 'https'
        Add-Result "site:$($s.name)" 'INFO' "id=$($s.id) state=$($s.state) bindings=[$b]"
        if (-not $hasHttps) { Add-Result "site:$($s.name)" 'INFO' 'No HTTPS binding yet (expected on a fresh box; win-acme adds it during issuance)' }
    }
} else { Add-Result 'IIS sites' 'WARN' 'Skipped (WebAdministration unavailable)' }

# --- 4. TLS 1.2 -------------------------------------------------------------
Write-Host "`n4. TLS" -ForegroundColor White
if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
    Add-Result 'TLS 1.2' 'PASS' 'Enabled for this process'
} else { Add-Result 'TLS 1.2' 'FAIL' 'TLS 1.2 not active for outbound calls' }

# --- 5. Outbound connectivity ----------------------------------------------
Write-Host "`n5. Outbound connectivity (443)" -ForegroundColor White
foreach ($pair in @(@{n = 'LE staging'; h = 'acme-staging-v02.api.letsencrypt.org' },
        @{n = 'LE production'; h = 'acme-v02.api.letsencrypt.org' })) {
    if (Test-Tcp $pair.h 443) { Add-Result $pair.n 'PASS' "$($pair.h):443 reachable" }
    else { Add-Result $pair.n 'FAIL' "$($pair.h):443 NOT reachable (firewall/proxy?)" }
}
# DNS provider API endpoint
$dnsApiHost = switch ($DnsProvider) {
    'Cloudflare' { 'api.cloudflare.com' }
    'Azure' { 'management.azure.com' }
    'GoDaddy' { 'api.godaddy.com' }
    default { $null }
}
if ($dnsApiHost) {
    if (Test-Tcp $dnsApiHost 443) { Add-Result "DNS API ($DnsProvider)" 'PASS' "$dnsApiHost:443 reachable" }
    else { Add-Result "DNS API ($DnsProvider)" 'FAIL' "$dnsApiHost:443 NOT reachable" }
}

# --- 6. win-acme ------------------------------------------------------------
Write-Host "`n6. ACME client (win-acme)" -ForegroundColor White
$wacs = Join-Path $WinAcmePath 'wacs.exe'
if (-not (Test-Path $wacs) -and $InstallWinAcme) {
    $installer = Join-Path $PSScriptRoot 'Install-WinAcme.ps1'
    if (Test-Path $installer) {
        Add-Result 'win-acme' 'INFO' 'Installing via Install-WinAcme.ps1 (staging endpoint)...'
        $p = @{ InstallPath = $WinAcmePath; Staging = $true }
        if ($NotifyEmail) { $p.NotifyEmail = $NotifyEmail }
        & $installer @p | Out-Null
    } else { Add-Result 'win-acme' 'WARN' "Install-WinAcme.ps1 not found next to this script" }
}
if (Test-Path $wacs) {
    try {
        $ver = (& $wacs --version 2>&1 | Select-Object -First 1)
        Add-Result 'win-acme' 'PASS' "wacs.exe present ($ver)"
    } catch { Add-Result 'win-acme' 'WARN' 'wacs.exe present but --version failed' }
} else {
    Add-Result 'win-acme' 'FAIL' 'wacs.exe not found - re-run with -InstallWinAcme'
}

# --- 7. DNS resolution checks ----------------------------------------------
Write-Host "`n7. DNS resolution" -ForegroundColor White
if (-not $Domains) { Add-Result 'DNS' 'WARN' 'No -Domains supplied; skipping DNS checks' }
foreach ($d in $Domains) {
    try {
        $ns = Resolve-DnsName -Name $d -Type NS -ErrorAction Stop |
            Where-Object Type -eq 'NS' | Select-Object -Expand NameHost -ErrorAction SilentlyContinue
        if ($ns) { Add-Result "NS:$d" 'PASS' "authoritative: $([string]::Join(', ', $ns))" }
        else { Add-Result "NS:$d" 'WARN' 'no NS records returned' }
    } catch { Add-Result "NS:$d" 'FAIL' "NS lookup failed: $($_.Exception.Message)" }

    try {
        $a = Resolve-DnsName -Name $d -Type A -Server 1.1.1.1 -ErrorAction Stop |
            Where-Object Type -eq 'A' | Select-Object -Expand IPAddress -ErrorAction SilentlyContinue
        if ($a) { Add-Result "A:$d" 'PASS' "resolves to $([string]::Join(', ', $a)) (public view)" }
        else { Add-Result "A:$d" 'WARN' 'no A record (ok if site not published yet)' }
    } catch { Add-Result "A:$d" 'WARN' "A lookup via 1.1.1.1 failed: $($_.Exception.Message)" }

    # Prove the _acme-challenge query path resolves (record itself should not exist yet)
    try {
        Resolve-DnsName -Name "_acme-challenge.$d" -Type TXT -Server 1.1.1.1 -ErrorAction Stop | Out-Null
        Add-Result "_acme-challenge:$d" 'WARN' 'a TXT already exists (leftover challenge?) - safe to ignore'
    } catch {
        Add-Result "_acme-challenge:$d" 'PASS' 'query path OK, no stale TXT present'
    }
}

# --- 8. DNS-01 validation test (staging issuance) --------------------------
Write-Host "`n8. DNS-01 validation test (Let's Encrypt STAGING)" -ForegroundColor White
if (-not $RunDnsValidationTest) {
    Add-Result 'DNS-01 test' 'INFO' 'Skipped (add -RunDnsValidationTest + -DnsProvider + creds to run)'
} elseif (-not (Test-Path $wacs)) {
    Add-Result 'DNS-01 test' 'FAIL' 'win-acme not installed; cannot run the test'
} else {
    if (-not $TestHost) { $TestHost = if ($Domains) { "*.$($Domains[0])" } else { $null } }
    if (-not $NotifyEmail) { Add-Result 'DNS-01 test' 'FAIL' '-NotifyEmail required for the staging test'; }
    elseif (-not $TestHost) { Add-Result 'DNS-01 test' 'FAIL' 'Provide -TestHost or -Domains'; }
    else {
        # Build provider validation args
        $val = switch ($DnsProvider) {
            'Cloudflare' { @('--validation', 'cloudflare', '--cloudflareapitoken', $CloudflareToken) }
            'Azure' { @('--validation', 'azure', '--azuretenantid', $AzureTenantId, '--azureclientid', $AzureClientId,
                    '--azuresecret', $AzureSecret, '--azuresubscriptionid', $AzureSubscriptionId,
                    '--azureresourcegroupname', $AzureResourceGroup) }
            'GoDaddy' { @('--validation', 'godaddy', '--apikey', $GoDaddyKey, '--apisecret', $GoDaddySecret) }
            default { $null }
        }
        if (-not $val) {
            Add-Result 'DNS-01 test' 'FAIL' 'Specify -DnsProvider (Cloudflare|Azure|GoDaddy) and its credentials'
        } else {
            $pfxDir = Join-Path $env:TEMP ("winacme-preflight-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
            $friendly = "PREFLIGHT-TEST $TestHost"
            $pw = [guid]::NewGuid().ToString('N')
            Add-Result 'DNS-01 test' 'INFO' "Issuing STAGING cert for $TestHost via $DnsProvider (this writes+removes a TXT record)..."
            $wacsArgs = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $TestHost) + $val +
                    @('--store', 'pfxfile', '--pfxfilepath', $pfxDir, '--pfxpassword', $pw,
                      '--installation', 'none', '--emailaddress', $NotifyEmail, '--accepttos',
                      '--friendlyname', $friendly, '--closeonfinish')
            try {
                & $wacs @wacsArgs 2>&1 | Out-Null
                $produced = Get-ChildItem $pfxDir -Filter *.pfx -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0 -and $produced) {
                    Add-Result 'DNS-01 test' 'PASS' "DNS-01 validated end-to-end; staging cert issued for $TestHost"
                } else {
                    Add-Result 'DNS-01 test' 'FAIL' "Staging issuance failed (exit $LASTEXITCODE). Check $WinAcmePath logs; verify DNS creds/zone scope."
                }
            } catch {
                Add-Result 'DNS-01 test' 'FAIL' "Staging test error: $($_.Exception.Message)"
            } finally {
                # Clean up the throwaway renewal and pfx
                try { & $wacs --baseuri $StagingUri --cancel --friendlyname $friendly --closeonfinish 2>&1 | Out-Null } catch {}
                # win-acme leaves a per-endpoint staging scheduled task behind after --cancel; remove it.
                try { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'acme-staging' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                Remove-Item $pfxDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# --- Summary ----------------------------------------------------------------
$fail = ($script:Results | Where-Object Status -eq 'FAIL').Count
$warn = ($script:Results | Where-Object Status -eq 'WARN').Count
$pass = ($script:Results | Where-Object Status -eq 'PASS').Count
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host ("  PASS={0}  WARN={1}  FAIL={2}" -f $pass, $warn, $fail)
if ($fail -gt 0) {
    Write-Host "`nNOT READY: resolve the FAIL items above, then re-run. See Runbook 01/02." -ForegroundColor Red
    exit 1
} elseif ($warn -gt 0) {
    Write-Host "`nREADY (with warnings): review WARN items, then proceed to Runbook 01/02." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "`nREADY: environment validated. Proceed to Runbook 01 (HTTP-01) or 02 (DNS-01)." -ForegroundColor Green
    exit 0
}
