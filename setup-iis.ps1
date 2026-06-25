<#
  Cert-Man-Windows : IIS Certificate Setup
  Run AFTER the preflight reports READY. This script:
    1. Validates IIS (offers to install the role if missing) and win-acme.
    2. Scans every IIS site/binding and plans the minimum set of WILDCARD certs
       (host names sharing a parent domain collapse onto one cert; apex added as a SAN).
    3. Shows what is already covered vs. what needs generating.
    4. If everything checks out, OFFERS to generate the missing certs on the LIVE
       Let's Encrypt server (DNS-01) and bind them to the IIS sites.

  Run it:
      irm https://xphox2.github.io/Cert-Man-Windows/setup-iis.ps1 | iex
#>

$Url         = 'https://xphox2.github.io/Cert-Man-Windows/setup-iis.ps1'
$WinAcmePath = 'C:\win-acme'
$ProdUri     = 'https://acme-v02.api.letsencrypt.org/directory'
$StagingUri  = 'https://acme-staging-v02.api.letsencrypt.org/directory'

# ----------------------------------------------------------------- helpers --
function Test-AdminNow {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Status {
    param([string]$Tag, [string]$Name, [string]$Detail)
    $color = switch ($Tag) { 'OK' { 'Green' } 'NEED' { 'Red' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'APEX' { 'Magenta' } 'FIX' { 'Cyan' } default { 'Gray' } }
    Write-Host ('   [{0,-4}] ' -f $Tag) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host ("  - $Detail") -ForegroundColor DarkGray } else { Write-Host '' }
}
function Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host '   Cert-Man-Windows  -  IIS Certificate Setup' -ForegroundColor Cyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''
}
function Get-File { param([string]$Url, [string]$Dest) (New-Object System.Net.WebClient).DownloadFile($Url, $Dest) }

# --------------------------------------------- bootstrap: elevate + clean console --
if ((-not $PSCommandPath) -or (-not (Test-AdminNow))) {
    Banner
    $self = Join-Path $env:TEMP 'cmw-setup-iis.ps1'
    try { (New-Object System.Net.WebClient).DownloadFile($Url, $self) }
    catch { try { Invoke-WebRequest $Url -OutFile $self -UseBasicParsing } catch {} }
    Unblock-File $self -ErrorAction SilentlyContinue
    $a = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self)
    Write-Host '  Opening a clean elevated window (accept the UAC prompt if shown)...' -ForegroundColor Yellow
    try {
        if (Test-AdminNow) { Start-Process powershell -ArgumentList $a }
        else { Start-Process powershell -Verb RunAs -ArgumentList $a }
    } catch { Write-Host '  Launch was cancelled. Re-run and accept the prompt.' -ForegroundColor Red }
    return
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# --------------------------------------------- public suffix handling -------
$script:PslRules = $null
function Initialize-Psl {
    $script:PslRules = New-Object System.Collections.Generic.HashSet[string]
    $f = Join-Path $WinAcmePath 'public_suffix_list.dat'
    if (Test-Path $f) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('//')) { [void]$script:PslRules.Add($t.ToLower()) }
        }
    }
}
function Get-RegistrableDomain {
    param([string]$HostName)
    $h = $HostName.ToLower().TrimEnd('.'); $labels = $h.Split('.')
    if ($labels.Count -le 2 -or $script:PslRules.Count -eq 0) {
        if ($labels.Count -le 2) { return $h } else { return ($labels[-2..-1] -join '.') }
    }
    $suffixLabelCount = 1
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $cand = ($labels[$i..($labels.Count - 1)]) -join '.'
        $parent = if ($i + 1 -lt $labels.Count) { ($labels[($i + 1)..($labels.Count - 1)]) -join '.' } else { '' }
        if ($script:PslRules.Contains('!' + $cand)) { $suffixLabelCount = ($labels.Count - 1 - $i); break }
        if ($script:PslRules.Contains($cand)) { $suffixLabelCount = ($labels.Count - $i); break }
        if ($parent -and $script:PslRules.Contains('*.' + $parent)) { $suffixLabelCount = ($labels.Count - $i); break }
    }
    $take = $suffixLabelCount + 1
    if ($labels.Count -lt $take) { return $h }
    return ($labels[($labels.Count - $take)..($labels.Count - 1)] -join '.')
}

# --------------------------------------------- cert store helpers -----------
function Find-NewestCovering {
    param([string[]]$Sans)
    $best = $null
    foreach ($c in (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)) {
        if ($c.NotAfter -lt (Get-Date)) { continue }
        $names = @($c.DnsNameList | ForEach-Object { $_.Unicode.ToLower() })
        $all = $true; foreach ($s in $Sans) { if ($names -notcontains $s.ToLower()) { $all = $false; break } }
        if ($all -and (-not $best -or $c.NotBefore -gt $best.NotBefore)) { $best = $c }
    }
    return $best
}
function Get-CertSource {
    param($Cert)
    if (-not $Cert) { return '' }
    if ($Cert.Subject -eq $Cert.Issuer) { return 'self-signed' }
    if ($Cert.Issuer -match "Let's Encrypt|\bR1[0-9]\b|\bE[0-9]\b") { return "Let's Encrypt" }
    if ($Cert.Issuer -match 'GoDaddy') { return 'GoDaddy' }
    if ($Cert.Issuer -match 'DigiCert') { return 'DigiCert' }
    if ($Cert.Issuer -match 'Sectigo|COMODO') { return 'Sectigo' }
    if ($Cert.Issuer -match 'CN=([^,]+)') { return $matches[1] }
    return 'other CA'
}

# --------------------------------------------- win-acme plugin install ------
function Install-WinAcmePlugin {
    param([string]$Match)
    $rel = Invoke-RestMethod 'https://api.github.com/repos/win-acme/win-acme/releases/latest' -Headers @{ 'User-Agent' = 'cert-man' }
    $asset = $rel.assets | Where-Object { $_.name -like "$Match.*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "win-acme plugin '$Match' not found." }
    $zip = Join-Path $env:TEMP ($Match + '.zip')
    Get-File $asset.browser_download_url $zip
    Expand-Archive $zip $WinAcmePath -Force; Remove-Item $zip -Force
    Get-ChildItem $WinAcmePath -Include *.dll -Recurse | Unblock-File
}

# --------------------------------------------- generation -------------------
function Invoke-WacsRetry {
    # Run wacs.exe and retry on TRANSIENT Let's Encrypt errors ("Service busy; retry later",
    # ServiceUnavailable) - common on staging under back-to-back issuance. Does NOT retry real
    # failures (bad DNS token, duplicate-cert rate limit, etc.).
    param([string]$Wacs, [string[]]$WacsArgs, [scriptblock]$IsSuccess, [int]$MaxRetries = 2)
    $out = $null; $ok = $false
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try { $out = & $Wacs @WacsArgs 2>&1 } catch { $out = $_.Exception.Message }
        $ok = [bool](& $IsSuccess)
        if ($ok) { break }
        $transient = [bool](@($out) | Select-String -Quiet -Pattern 'Service busy|retry later|ServiceUnavailable|Service Unavailable')
        if (-not $transient -or $attempt -eq $MaxRetries) { break }
        Write-Host "         Let's Encrypt was busy (transient) - retrying in 15s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 15
    }
    return [pscustomobject]@{ Ok = $ok; Out = $out }
}

function Test-StagingCert {
    # Dry-run one cert against Let's Encrypt STAGING: proves DNS-01 works for this exact
    # SAN set without touching production rate limits or binding anything. Returns $true/$false.
    param([string]$Wacs, [string[]]$Sans, [string[]]$Val, [string]$Email)
    $hostArg = $Sans -join ','
    $tmp = Join-Path $env:TEMP ('cmw-stg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $tmp -Force | Out-Null
    $fn = "[CertMan-STAGING] $hostArg"
    $log = Join-Path $WinAcmePath ("staging-{0}.log" -f ($hostArg -replace '[^a-z0-9]', '_'))
    $a = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $hostArg) + $Val +
         @('--store', 'pfxfile', '--pfxfilepath', $tmp, '--pfxpassword', [guid]::NewGuid().ToString('N'),
           '--installation', 'none', '--emailaddress', $Email, '--accepttos', '--friendlyname', $fn, '--closeonfinish', '--verbose')
    $r = Invoke-WacsRetry -Wacs $Wacs -WacsArgs $a -IsSuccess { $LASTEXITCODE -eq 0 }
    $out = $r.Out
    $out | Out-File -FilePath $log -Encoding utf8
    $ok = $r.Ok -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    try { & $Wacs --baseuri $StagingUri --cancel --friendlyname $fn --closeonfinish 2>&1 | Out-Null } catch {}
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $ok) {
        @($out) | Select-Object -Last 18 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        Write-Host "         Full log: $log" -ForegroundColor Yellow
    }
    return [bool]$ok
}

function Invoke-Generate {
    param([object[]]$Need, [hashtable]$SiteIdMap, [hashtable]$SiteNameById)
    $wacs = Join-Path $WinAcmePath 'wacs.exe'

    Write-Host ''
    Write-Host ("  Generate {0} certificate(s) for the items marked NEED/WARN above." -f $Need.Count) -ForegroundColor White
    $email = Read-Host '   Contact email for the Let''s Encrypt account'
    Write-Host ''
    Write-Host '   DNS provider:   1) Cloudflare    2) Azure DNS    3) GoDaddy' -ForegroundColor White
    $choice = Read-Host '   Choose 1-3'
    $val = switch ($choice) {
        '1' { $t = Read-Host '   Cloudflare API token'; @('--validation', 'cloudflare', '--cloudflareapitoken', $t) }
        '2' {
            $tn = Read-Host '   Azure Tenant ID'; $ci = Read-Host '   Azure Client (App) ID'
            $sc = Read-Host '   Azure Client Secret'; $su = Read-Host '   Azure Subscription ID'
            $rg = Read-Host '   Azure DNS Resource Group'
            @('--validation', 'azure', '--azuretenantid', $tn, '--azureclientid', $ci, '--azuresecret', $sc, '--azuresubscriptionid', $su, '--azureresourcegroupname', $rg)
        }
        '3' { $k = Read-Host '   GoDaddy API key'; $s = Read-Host '   GoDaddy API secret'; @('--validation', 'godaddy', '--apikey', $k, '--apisecret', $s) }
        default { $null }
    }
    if (-not $val) { Write-Host '   No provider chosen; aborting generation.' -ForegroundColor Yellow; return }
    $pluginMatch = switch ($choice) { '1' { 'plugin.validation.dns.cloudflare' } '2' { 'plugin.validation.dns.azure' } '3' { 'plugin.validation.dns.godaddy' } }
    Status 'FIX' 'DNS provider plugin' 'installing...'
    try { Install-WinAcmePlugin $pluginMatch; Status 'OK' 'DNS provider plugin' 'installed' }
    catch { Status 'FAIL' 'DNS provider plugin' $_.Exception.Message; return }

    # --- Staging-first toggle (recommended) --------------------------------
    Write-Host ''
    $stagingFirst = (Read-Host "  Dry-run on Let's Encrypt STAGING first? (recommended - no rate-limit cost) [Y/n]") -notmatch '^(n|no)$'
    if ($stagingFirst) {
        Write-Host ''
        Write-Host '  --- STAGING dry-run (validates DNS-01 end to end; issues + discards test certs) ---' -ForegroundColor Cyan
        $allOk = $true
        foreach ($p in $Need) {
            Status 'FIX' $p.Title 'testing on staging...'
            if (Test-StagingCert -Wacs $wacs -Sans $p.Sans -Val $val -Email $email) { Status 'OK' $p.Title 'staging validated' }
            else { Status 'FAIL' $p.Title 'staging failed (output above)'; $allOk = $false }
        }
        if (-not $allOk) {
            Write-Host ''
            Write-Host '  One or more staging tests FAILED. Production was NOT touched.' -ForegroundColor Red
            Write-Host '  Fix the cause (usually DNS token scope or wrong provider), then re-run.' -ForegroundColor Yellow
            return
        }
        Write-Host ''
        Write-Host '  All staging tests passed.' -ForegroundColor Green
    }

    # --- Production issuance + IIS binding ----------------------------------
    Write-Host ''
    Write-Host '  >>> PRODUCTION: live, trusted certificates (count against rate limits, 50/domain/week). <<<' -ForegroundColor Yellow
    if ((Read-Host ("  Generate {0} certificate(s) on PRODUCTION now? [y/N]" -f $Need.Count)) -notmatch '^(y|yes)$') {
        Write-Host '  Skipped production generation.' -ForegroundColor Yellow; return
    }
    foreach ($p in $Need) {
        $hostArg = ($p.Sans -join ',')
        $gids = @($p.BindHosts | ForEach-Object { $SiteIdMap[$_] } | Select-Object -Unique)
        $primary = @($gids)[0]
        Write-Host ''
        Write-Host ("  === Generating: {0}  (IIS site id {1}) ===" -f $p.Title, $primary) -ForegroundColor Cyan
        $log = Join-Path $WinAcmePath ("issue-{0}.log" -f ($p.Base -replace '[^a-z0-9]', '_'))
        # Wildcard + manual source REQUIRES --installationsiteid. win-acme then binds the covered
        # hosts in that site AND re-binds them on every renewal.
        $a = @('--baseuri', $ProdUri, '--source', 'manual', '--host', $hostArg) + $val +
             @('--store', 'certificatestore', '--installation', 'iis', '--installationsiteid', "$primary",
               '--emailaddress', $email, '--accepttos', '--friendlyname', "[CertMan] $($p.Title)", '--closeonfinish', '--verbose')
        $r = Invoke-WacsRetry -Wacs $wacs -WacsArgs $a -IsSuccess { $LASTEXITCODE -eq 0 }
        $out = $r.Out
        $out | Out-File -FilePath $log -Encoding utf8

        $cert = Find-NewestCovering $p.Sans
        if (-not $r.Ok -or -not $cert -or (Get-CertSource $cert) -ne "Let's Encrypt") {
            Status 'FAIL' $p.Title 'issuance failed'
            @($out) | Select-Object -Last 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            Write-Host "      Full log: $log" -ForegroundColor Yellow
            continue
        }
        Status 'OK' $p.Title ("issued + bound, expires {0}" -f $cert.NotAfter.ToString('yyyy-MM-dd'))

        # If this wildcard's hosts span more than one IIS site, bind the extras too.
        if ($gids.Count -gt 1) {
            foreach ($h in $p.BindHosts) {
                foreach ($sid in @($SiteIdMap[$h])) {
                    if ($sid -eq $primary) { continue }
                    $sname = $SiteNameById["$sid"]
                    try {
                        $bnd = Get-WebBinding -Name $sname -Protocol https -HostHeader $h -ErrorAction SilentlyContinue
                        if (-not $bnd) { New-WebBinding -Name $sname -Protocol https -Port 443 -HostHeader $h -SslFlags 1 -ErrorAction Stop; $bnd = Get-WebBinding -Name $sname -Protocol https -HostHeader $h }
                        $bnd.AddSslCertificate($cert.Thumbprint, 'My') | Out-Null
                        Write-Host ("      also bound {0} on site {1}" -f $h, $sname) -ForegroundColor DarkGray
                    } catch { Write-Host ("      could not bind {0} on {1}: {2}" -f $h, $sname, $_.Exception.Message) -ForegroundColor Yellow }
                }
            }
        }
    }
    Write-Host ''
    Write-Host '  Done. win-acme created a renewal task per cert - it auto-renews AND re-binds IIS.' -ForegroundColor Green
}

# ----------------------------------------------------------------- main -----
Banner

# 1. Validate IIS (offer to install the role)
try { $iis = (Get-WindowsFeature Web-Server -ErrorAction Stop).Installed } catch { $iis = $false }
if (-not $iis) {
    Status 'NEED' 'IIS web-server role' 'not installed'
    if ((Read-Host '  Install the IIS role now? [Y/n]') -notmatch '^(n|no)$') {
        Status 'FIX' 'IIS web-server role' 'installing...'
        Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
        Install-WindowsFeature -Name Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null
        Status 'OK' 'IIS web-server role' 'installed'
    } else { Write-Host '  Cannot continue without IIS.' -ForegroundColor Red; return }
} else { Status 'OK' 'IIS web-server role' 'installed' }

try { Import-Module WebAdministration -ErrorAction Stop }
catch { Status 'FAIL' 'IIS module' 'WebAdministration unavailable - install IIS management scripting tools'; return }

# 2. win-acme present + pluggable?
$wacsExe = Join-Path $WinAcmePath 'wacs.exe'
$wacsOk = (Test-Path $wacsExe) -and ((Get-Item $wacsExe).Length / 1MB -gt 30)
if ($wacsOk) { Status 'OK' 'win-acme (pluggable)' $WinAcmePath }
else { Status 'WARN' 'win-acme (pluggable)' 'not ready - run the preflight first (generation will be disabled)' }

Initialize-Psl
Write-Host ''

# 3. Scan IIS bindings
$bindings = New-Object System.Collections.Generic.List[object]; $noHost = 0
$siteNameById = @{}
foreach ($site in Get-Website) {
    $siteNameById["$($site.id)"] = $site.Name
    foreach ($b in $site.bindings.Collection) {
        if ($b.protocol -notin 'http', 'https') { continue }
        $parts = $b.bindingInformation -split ':'
        $h = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        if ([string]::IsNullOrWhiteSpace($h)) { $noHost++; continue }
        $bindings.Add([pscustomobject]@{ Host = $h.ToLower(); Site = $site.Name; SiteId = "$($site.id)" })
    }
}
$uniqueHosts = @($bindings | Select-Object -Expand Host -Unique)
Write-Host ("  Scanned {0} site(s); {1} unique host name(s) across {2} binding(s)." -f (Get-Website).Count, $uniqueHosts.Count, $bindings.Count) -ForegroundColor White
if ($noHost) { Write-Host ("  ({0} binding(s) had no host header - skipped.)" -f $noHost) -ForegroundColor DarkGray }
if ($uniqueHosts.Count -eq 0) { Write-Host '  No host-named bindings. Add host headers to your sites first.' -ForegroundColor Yellow; return }

$siteMap = @{}; $siteIdMap = @{}
foreach ($h in $uniqueHosts) {
    $siteMap[$h] = @($bindings | Where-Object Host -eq $h | Select-Object -Expand Site -Unique)
    $siteIdMap[$h] = @($bindings | Where-Object Host -eq $h | Select-Object -Expand SiteId -Unique)
}

# 4. Group into wildcard certs
$groups = @{}
foreach ($h in $uniqueHosts) {
    $reg = Get-RegistrableDomain $h
    if ($h -eq $reg) { $base = $reg; $role = 'apex' } else { $base = ($h.Split('.', 2))[1]; $role = 'child' }
    if (-not $groups.ContainsKey($base)) { $groups[$base] = [pscustomobject]@{ Base = $base; Zone = $reg; Hosts = @(); ApexBound = $false; HasChild = $false } }
    $groups[$base].Hosts += [pscustomobject]@{ Host = $h; Role = $role }
    if ($role -eq 'apex') { $groups[$base].ApexBound = $true } else { $groups[$base].HasChild = $true }
}

# 5. Analyse + display
$plan = New-Object System.Collections.Generic.List[object]; $idx = 0
foreach ($g in ($groups.Values | Sort-Object Base)) {
    $idx++
    $sans = @(); if ($g.HasChild) { $sans += "*.$($g.Base)" }; if ($g.ApexBound -or -not $g.HasChild) { $sans += $g.Base }
    $sans = @($sans | Select-Object -Unique); $title = $sans -join ', '
    $cert = Find-NewestCovering $sans
    $tag = 'NEED'; $detail = 'no covering certificate - will generate'
    if ($cert) {
        $days = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays); $src = Get-CertSource $cert
        if ($days -le 30) { $tag = 'WARN'; $detail = "covered by $src, expires in $days days - renew/replace" }
        else { $tag = 'OK'; $detail = "covered by $src, $days days left" }
    } elseif (-not $g.HasChild) { $tag = 'APEX'; $detail = 'apex only - single-name cert' }

    Write-Host ''
    Status $tag ("Certificate {0}:  {1}" -f $idx, $title) $detail
    Write-Host ("          DNS zone: {0}    Covers {1} host(s):" -f $g.Zone, $g.Hosts.Count) -ForegroundColor DarkGray
    foreach ($hh in ($g.Hosts | Sort-Object Host)) {
        $m = if ($hh.Role -eq 'apex') { '(apex)' } else { '      ' }
        Write-Host ("            - {0,-34} {1}  [{2}]" -f $hh.Host, $m, ($siteMap[$hh.Host] -join ', ')) -ForegroundColor Gray
    }
    $plan.Add([pscustomobject]@{ Index = $idx; Title = $title; Sans = $sans; Base = $g.Base; Zone = $g.Zone; Tag = $tag
            BindHosts = @($g.Hosts | ForEach-Object { $_.Host }) })
}

# 6. Summary + offer live generation
$need = @($plan | Where-Object Tag -in 'NEED', 'WARN')
Write-Host ''
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ("   {0} certificate(s) cover {1} host name(s).  To generate/renew: {2}" -f $plan.Count, $uniqueHosts.Count, $need.Count) -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan

if ($need.Count -eq 0) {
    Write-Host ''
    Write-Host '  All host names are already covered by valid certificates. Nothing to do.' -ForegroundColor Green
} elseif (-not $wacsOk) {
    Write-Host ''
    Write-Host '  Run the preflight first to install win-acme, then re-run this script to generate:' -ForegroundColor Yellow
    Write-Host '    irm https://xphox2.github.io/Cert-Man-Windows/preflight.ps1 | iex' -ForegroundColor Gray
} else {
    Invoke-Generate -Need $need -SiteIdMap $siteIdMap -SiteNameById $siteNameById
}
Write-Host ''
Write-Host '   https://github.com/xphox2/Cert-Man-Windows  (Runbook 02 = wildcard issuance)' -ForegroundColor DarkGray
Write-Host ''
