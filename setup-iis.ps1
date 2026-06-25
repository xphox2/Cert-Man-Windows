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
    # Search both stores: win-acme puts IIS-installed certs in WebHosting, not My.
    foreach ($store in 'My', 'WebHosting') {
        foreach ($c in (Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue)) {
            if ($c.NotAfter -lt (Get-Date)) { continue }
            $names = @($c.DnsNameList | ForEach-Object { $_.Unicode.ToLower() })
            $all = $true; foreach ($s in $Sans) { if ($names -notcontains $s.ToLower()) { $all = $false; break } }
            if ($all -and (-not $best -or $c.NotBefore -gt $best.NotBefore)) { $best = $c }
        }
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

function Get-MissingBindings {
    # For every covered host, on every IIS site that hosts it, report where an HTTPS binding is
    # missing or is using a different/old certificate than $Cert. (win-acme's --installationsiteid
    # only binds ONE site, so multi-site wildcards can be left partially bound.)
    param([string[]]$BindHosts, $Cert, [hashtable]$SiteIdMap, [hashtable]$SiteNameById)
    $missing = @()
    if (-not $Cert) { return $missing }
    $tp = $Cert.Thumbprint.ToUpper()
    foreach ($h in $BindHosts) {
        foreach ($sid in @($SiteIdMap[$h])) {
            $sname = $SiteNameById["$sid"]
            if (-not $sname) { continue }
            $b = Get-WebBinding -Name $sname -Protocol https -HostHeader $h -ErrorAction SilentlyContinue
            if (-not $b) { $missing += [pscustomobject]@{ Host = $h; Site = $sname; State = 'no HTTPS binding' } }
            elseif ($b.certificateHash -and ($b.certificateHash.ToUpper() -ne $tp)) {
                $missing += [pscustomobject]@{ Host = $h; Site = $sname; State = 'bound to a different/old cert' }
            }
        }
    }
    return $missing
}

function Repair-Bindings {
    # Create/fix the HTTPS bindings in $Missing so each points at $Cert (local only, no CA calls).
    param([object[]]$Missing, $Cert)
    if (-not $Cert -or -not $Missing) { return 0 }
    $store = ($Cert.PSParentPath -split '\\')[-1]   # My or WebHosting
    $fixed = 0
    foreach ($m in $Missing) {
        try {
            $b = Get-WebBinding -Name $m.Site -Protocol https -HostHeader $m.Host -ErrorAction SilentlyContinue
            if (-not $b) {
                New-WebBinding -Name $m.Site -Protocol https -Port 443 -HostHeader $m.Host -SslFlags 1 -ErrorAction Stop
                $b = Get-WebBinding -Name $m.Site -Protocol https -HostHeader $m.Host
            }
            $b.AddSslCertificate($Cert.Thumbprint, $store) | Out-Null
            Write-Host ("      bound https://{0}  [site: {1}]" -f $m.Host, $m.Site) -ForegroundColor DarkGray
            $fixed++
        } catch { Write-Host ("      could not bind {0} on {1}: {2}" -f $m.Host, $m.Site, $_.Exception.Message) -ForegroundColor Yellow }
    }
    return $fixed
}

# --------------------------------------------- win-acme plugin install ------
function Get-WinAcmeRelease { Invoke-RestMethod 'https://api.github.com/repos/win-acme/win-acme/releases/latest' -Headers @{ 'User-Agent' = 'cert-man' } }
function Install-WinAcmePlugin {
    param([string]$Match)
    $asset = (Get-WinAcmeRelease).assets | Where-Object { $_.name -like "$Match.*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "win-acme plugin '$Match' not found." }
    $zip = Join-Path $env:TEMP ($Match + '.zip')
    Get-File $asset.browser_download_url $zip
    Expand-Archive $zip $WinAcmePath -Force; Remove-Item $zip -Force
    Get-ChildItem $WinAcmePath -Include *.dll -Recurse | Unblock-File
}
function Get-WinAcmeDnsProviders {
    try {
        @((Get-WinAcmeRelease).assets.name |
            Where-Object { $_ -match 'plugin\.validation\.dns\.' } |
            ForEach-Object { ($_ -replace 'plugin\.validation\.dns\.', '' -replace '\.v[0-9].*', '') } |
            Sort-Object -Unique)
    } catch {
        @('aliyun', 'azure', 'cloudflare', 'digitalocean', 'dnsmadeeasy', 'godaddy', 'googledns', 'hetzner',
            'linode', 'luadns', 'ns1', 'rfc2136', 'route53', 'simply', 'tencent', 'transip')
    }
}
function Get-DnsValidation {
    # Returns @{ Args; Plugin; Interactive; Label; AcmeDns } for the chosen DNS method, or $null.
    Write-Host ''
    Write-Host '   DNS for the _acme-challenge record:' -ForegroundColor White
    Write-Host '     1) acme-dns       - ANY registrar incl. no-API (Network Solutions); one-time CNAME, then auto-renews' -ForegroundColor White
    Write-Host '     2) Cloudflare' -ForegroundColor White
    Write-Host '     3) Azure DNS' -ForegroundColor White
    Write-Host '     4) GoDaddy' -ForegroundColor White
    Write-Host "     5) Other provider - choose from win-acme's full DNS list" -ForegroundColor White
    Write-Host '     6) Manual         - one-off; does NOT auto-renew' -ForegroundColor White
    switch (Read-Host '   Choose 1-6') {
        '1' {
            $srv = Read-Host '   acme-dns server URL (e.g. https://auth.acme-dns.io to test, or your own)'
            if (-not $srv) { $srv = 'https://auth.acme-dns.io' }
            return @{ Args = @('--validation', 'acme-dns', '--acmednsserver', $srv); Plugin = $null; Interactive = $true; Label = "acme-dns ($srv)"; AcmeDns = $true }
        }
        '2' { $t = Read-Host '   Cloudflare API token'; return @{ Args = @('--validation', 'cloudflare', '--cloudflareapitoken', $t); Plugin = 'plugin.validation.dns.cloudflare'; Interactive = $false; Label = 'Cloudflare' } }
        '3' { $tn = Read-Host '   Azure Tenant ID'; $ci = Read-Host '   Azure Client (App) ID'; $sc = Read-Host '   Azure Client Secret'; $su = Read-Host '   Azure Subscription ID'; $rg = Read-Host '   Azure DNS Resource Group'
            return @{ Args = @('--validation', 'azure', '--azuretenantid', $tn, '--azureclientid', $ci, '--azuresecret', $sc, '--azuresubscriptionid', $su, '--azureresourcegroupname', $rg); Plugin = 'plugin.validation.dns.azure'; Interactive = $false; Label = 'Azure DNS' } }
        '4' { $k = Read-Host '   GoDaddy API key'; $s = Read-Host '   GoDaddy API secret'; return @{ Args = @('--validation', 'godaddy', '--apikey', $k, '--apisecret', $s); Plugin = 'plugin.validation.dns.godaddy'; Interactive = $false; Label = 'GoDaddy' } }
        '5' {
            $providers = Get-WinAcmeDnsProviders
            Write-Host ''
            for ($i = 0; $i -lt $providers.Count; $i++) { Write-Host ('     {0,2}) {1}' -f ($i + 1), $providers[$i]) -ForegroundColor Gray }
            $idx = ([int](Read-Host '   Provider number')) - 1
            if ($idx -lt 0 -or $idx -ge $providers.Count) { Write-Host '   Invalid choice.' -ForegroundColor Yellow; return $null }
            $key = $providers[$idx]
            Write-Host ("   win-acme will prompt for {0}'s credentials (ref: https://www.win-acme.com/reference/plugins/validation/dns/{0})." -f $key) -ForegroundColor DarkGray
            return @{ Args = @('--validation', $key); Plugin = "plugin.validation.dns.$key"; Interactive = $true; Label = $key }
        }
        '6' { return @{ Args = @('--validation', 'manual'); Plugin = $null; Interactive = $true; Label = 'Manual'; Manual = $true } }
        default { return $null }
    }
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
        $transient = [bool](@($out) | Select-String -Quiet -Pattern 'Service busy|retry later|ServiceUnavailable|Service Unavailable|Certificate not found')
        if (-not $transient -or $attempt -eq $MaxRetries) { break }
        Write-Host "         Let's Encrypt was busy (transient) - retrying in 15s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 15
    }
    return [pscustomobject]@{ Ok = $ok; Out = $out }
}

function Get-CmwCacheDir { $d = Join-Path $WinAcmePath '.cmw-cache'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }
function Test-StagingValidatedRecently {
    # Did we already pass a STAGING dry-run for this base in the last N days? If so, skip
    # re-testing to avoid burning staging rate limits on iterative runs.
    param([string]$Base, [int]$Days = 7)
    $f = Join-Path (Get-CmwCacheDir) ("staging-ok-{0}.txt" -f ($Base -replace '[^a-z0-9]', '_'))
    if (-not (Test-Path $f)) { return $false }
    try { $t = [datetime]::FromBinary([long]((Get-Content $f -Raw).Trim())); return ((Get-Date) - $t).TotalDays -lt $Days }
    catch { return $false }
}
function Set-StagingValidated {
    param([string]$Base)
    $f = Join-Path (Get-CmwCacheDir) ("staging-ok-{0}.txt" -f ($Base -replace '[^a-z0-9]', '_'))
    (Get-Date).ToBinary().ToString() | Set-Content -Path $f -Encoding ascii
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

    # --- Rate-limit budget: show what this run would request BEFORE asking for anything ----
    Write-Host ''
    Write-Host '  Rate-limit budget for this run (new certificates to request, by registered domain):' -ForegroundColor White
    $byDomain = @{}
    foreach ($p in $Need) { $rd = Get-RegistrableDomain $p.Base; $byDomain[$rd] = 1 + ([int]$byDomain[$rd]) }
    foreach ($rd in ($byDomain.Keys | Sort-Object)) {
        Status ($(if ($byDomain[$rd] -gt 5) { 'WARN' } else { 'OK' })) $rd ("{0} new certificate(s) this run" -f $byDomain[$rd])
    }
    Write-Host "   Let's Encrypt limits: 50 certs/registered-domain/week, 5 duplicate (identical names)/week, 5 failed validations/hour." -ForegroundColor DarkGray
    Write-Host '   Already-valid certs were skipped above. win-acme reuses its 24h cache, so re-running within a day requests nothing new.' -ForegroundColor DarkGray
    Write-Host ''
    if ((Read-Host '  Proceed to generate? (reviewing the plan above costs nothing) [y/N]') -notmatch '^(y|yes)$') {
        Write-Host '  Plan only - nothing was requested from Let''s Encrypt.' -ForegroundColor Yellow; return
    }

    $email = Read-Host '   Contact email for the Let''s Encrypt account'
    $sel = Get-DnsValidation
    if (-not $sel) { Write-Host '   No provider chosen; aborting generation.' -ForegroundColor Yellow; return }
    $val = $sel.Args
    $interactive = $sel.Interactive

    if ($sel.Plugin) {
        Status 'FIX' 'DNS provider plugin' "installing $($sel.Label)..."
        try { Install-WinAcmePlugin $sel.Plugin; Status 'OK' 'DNS provider plugin' 'installed' }
        catch { Status 'FAIL' 'DNS provider plugin' $_.Exception.Message; return }
    }
    if ($sel.AcmeDns) {
        Write-Host ''
        Write-Host '   acme-dns: win-acme prompts for an acme-dns server, registers, and prints a one-time CNAME to' -ForegroundColor Yellow
        Write-Host '   create at your registrar (Network Solutions, etc.). Once that CNAME exists, renewals are automatic.' -ForegroundColor Yellow
    } elseif ($sel.Manual) {
        Write-Host ''
        Write-Host '   MANUAL DNS: win-acme prints a _acme-challenge TXT per cert; create it, wait ~1 min, follow the prompt.' -ForegroundColor Yellow
        Write-Host '   NOTE: manual certs do NOT auto-renew. For hands-off 3rd-party DNS, use acme-dns instead.' -ForegroundColor Yellow
    } elseif ($interactive) {
        Write-Host ''
        Write-Host ("   $($sel.Label): win-acme will prompt for this provider's credentials during issuance (and stores them for renewal).") -ForegroundColor Yellow
    }

    # --- Optional PFX export (for other devices / non-IIS services) --------
    $pfxDir = $null; $pfxPw = $null; $copyScript = $null
    Write-Host ''
    if ((Read-Host '  Also export a PFX of each cert (to copy to other devices/services)? [y/N]') -match '^(y|yes)$') {
        $d = Read-Host ('  PFX output folder [default C:\CertMan\pfx]')
        $pfxDir = if ($d) { $d } else { 'C:\CertMan\pfx' }
        New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
        $pfxPw = Read-Host '  PFX password (protects the exported file)'
        if (-not $pfxPw) { $pfxPw = [guid]::NewGuid().ToString('N'); Write-Host "  (no password entered - generated one: $pfxPw )" -ForegroundColor DarkGray }
        Write-Host "  PFX(s) will be written to $pfxDir and refreshed on each renewal." -ForegroundColor DarkGray

        # Optional post-renewal copy hook: win-acme runs a script after EACH renewal to push the fresh PFX out.
        $destInput = Read-Host '  Auto-copy the PFX to other devices after EACH renewal? Destination folder(s), comma-separated (UNC or local), or blank to skip'
        if ($destInput) {
            $dests = @($destInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $destLiteral = '@(' + (($dests | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
            New-Item -ItemType Directory -Path 'C:\CertMan' -Force | Out-Null
            $copyScript = 'C:\CertMan\post-renew-copy.ps1'
            # Self-contained wrapper (values baked in) so win-acme can run it as SYSTEM with no parameter quoting.
            $w = @(
                '# Auto-generated by setup-iis.ps1 - copies renewed PFX to other devices. Runs as SYSTEM after each win-acme renewal.',
                ('$src   = ' + "'" + ($pfxDir -replace "'", "''") + "'"),
                ('$dests = ' + $destLiteral),
                '$log   = "C:\CertMan\post-renew-copy.log"',
                'foreach ($dst in $dests) {',
                '  try {',
                '    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }',
                '    Copy-Item (Join-Path $src "*.pfx") -Destination $dst -Force -ErrorAction Stop',
                '    ("{0} OK   -> {1}" -f (Get-Date -Format s), $dst) | Add-Content $log',
                '  } catch {',
                '    ("{0} FAIL -> {1} : {2}" -f (Get-Date -Format s), $dst, $_.Exception.Message) | Add-Content $log',
                '  }',
                '}'
            )
            Set-Content -Path $copyScript -Value $w -Encoding UTF8
            Write-Host "  Post-renewal hook installed -> $copyScript (logs to C:\CertMan\post-renew-copy.log)" -ForegroundColor DarkGray
            Write-Host '  NOTE: renewals run as SYSTEM - UNC targets must allow the computer account (DOMAIN\MACHINE$).' -ForegroundColor Yellow
            Write-Host '  If that is not possible, share a LOCAL folder here and have each device PULL from it instead.' -ForegroundColor Yellow
        }
    }

    # --- Staging-first toggle (recommended) --------------------------------
    Write-Host ''
    # Interactive providers (acme-dns / manual / prompt-for-creds) skip the automated staging dry-run.
    $stagingFirst = if ($interactive) {
        Write-Host '  Interactive DNS: skipping the automated staging dry-run.' -ForegroundColor DarkGray
        $false
    } else {
        (Read-Host "  Dry-run on Let's Encrypt STAGING first? (recommended - no rate-limit cost) [Y/n]") -notmatch '^(n|no)$'
    }
    if ($stagingFirst) {
        Write-Host ''
        Write-Host '  --- STAGING dry-run (validates DNS-01 end to end; issues + discards test certs) ---' -ForegroundColor Cyan
        $allOk = $true
        foreach ($p in $Need) {
            if (Test-StagingValidatedRecently $p.Base) {
                Status 'OK' $p.Title 'staging validated in last 7 days - skipping (saves staging limits)'; continue
            }
            Status 'FIX' $p.Title 'testing on staging...'
            if (Test-StagingCert -Wacs $wacs -Sans $p.Sans -Val $val -Email $email) {
                Status 'OK' $p.Title 'staging validated'; Set-StagingValidated $p.Base
            }
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
        # Store: always the Windows cert store (for IIS); optionally ALSO a pfxfile for other devices.
        $storeArgs = if ($pfxDir) { @('--store', 'certificatestore,pfxfile', '--pfxfilepath', $pfxDir, '--pfxpassword', $pfxPw) } else { @('--store', 'certificatestore') }
        # Install to IIS; if a copy hook was configured, also run it as a post-renewal script step.
        $instArgs = @('--installation', $(if ($copyScript) { 'iis,script' } else { 'iis' }), '--installationsiteid', "$primary")
        if ($copyScript) { $instArgs += @('--script', $copyScript) }
        $a = @('--baseuri', $ProdUri, '--source', 'manual', '--host', $hostArg) + $val + $storeArgs + $instArgs +
             @('--emailaddress', $email, '--accepttos', '--friendlyname', "[CertMan] $($p.Title)", '--closeonfinish', '--verbose')
        if ($interactive) {
            # acme-dns / manual: interactive, do NOT capture output (win-acme prompts for the endpoint/
            # registration or the TXT record and reads your keypress). No transient-retry on this path.
            if ($sel.AcmeDns) { Write-Host '  >>> acme-dns: follow win-acme''s prompts (it uses your one-time CNAME). <<<' -ForegroundColor Yellow }
            elseif ($sel.Manual) { Write-Host '  >>> Manual: win-acme will show a TXT record; add it at your DNS, wait ~1 min, follow the prompt. <<<' -ForegroundColor Yellow }
            else { Write-Host "  >>> $($sel.Label): enter the provider's credentials when win-acme prompts. <<<" -ForegroundColor Yellow }
            & $wacs @a
            $ok = ($LASTEXITCODE -eq 0)
        } else {
            $r = Invoke-WacsRetry -Wacs $wacs -WacsArgs $a -IsSuccess { $LASTEXITCODE -eq 0 }
            $ok = $r.Ok
            $r.Out | Out-File -FilePath $log -Encoding utf8
        }

        # win-acme's exit code is the source of truth for success (it issued AND bound).
        if (-not $ok) {
            Status 'FAIL' $p.Title 'issuance failed'
            if (-not $interactive) {
                @($r.Out) | Select-Object -Last 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
                Write-Host "      Full log: $log" -ForegroundColor Yellow
            } else {
                Write-Host "      See win-acme output above, and C:\ProgramData\win-acme logs." -ForegroundColor Yellow
            }
            continue
        }
        $cert = Find-NewestCovering $p.Sans
        $exp = if ($cert) { $cert.NotAfter.ToString('yyyy-MM-dd') } else { 'check store' }
        Status 'OK' $p.Title ("issued, expires {0}" -f $exp)
        if ($pfxDir) {
            $pfx = @(Get-ChildItem $pfxDir -Filter '*.pfx' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($pfx) { Write-Host ("      PFX exported: {0}  (password as entered)" -f $pfx[0].FullName) -ForegroundColor DarkGray }
        }

        # win-acme's --installationsiteid binds only the primary site; reconcile EVERY covered host
        # across ALL of its sites so multi-site wildcards are fully bound.
        if ($cert) {
            $miss = @(Get-MissingBindings -BindHosts $p.BindHosts -Cert $cert -SiteIdMap $SiteIdMap -SiteNameById $SiteNameById)
            if ($miss.Count) {
                Write-Host ("      binding {0} additional host(s)..." -f $miss.Count) -ForegroundColor DarkGray
                Repair-Bindings -Missing $miss -Cert $cert | Out-Null
            }
        }
    }
    Write-Host ''
    if ($sel.Manual) {
        Write-Host '  Done. NOTE: manual-DNS certs do NOT auto-renew (renewal needs a manual TXT record too).' -ForegroundColor Yellow
        Write-Host '  Re-run before expiry, or use acme-dns (Runbook 02 Section A) for hands-off renewal.' -ForegroundColor Yellow
    } else {
        Write-Host '  Done. win-acme created a renewal task per cert - it auto-renews AND re-binds IIS.' -ForegroundColor Green
    }
    if ($pfxDir) {
        Write-Host ("  PFX files for other devices/services are in: {0}" -f $pfxDir) -ForegroundColor Green
        Write-Host '  Copy them to each device and import/bind (see scripts\Deploy-*.ps1 for RDP/SQL/Exchange/HTTP.SYS).' -ForegroundColor DarkGray
        if ($copyScript) {
            Write-Host '  Post-renewal hook is active: win-acme re-runs the copy after every renewal (log: C:\CertMan\post-renew-copy.log).' -ForegroundColor Green
        } else {
            Write-Host '  They are refreshed automatically on every renewal - re-distribute (or script a copy) after each renew.' -ForegroundColor DarkGray
        }
    }
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

    # Binding reconciliation: even when a cert exists, a covered host may be unbound (e.g. a wildcard
    # spanning multiple IIS sites where only one site got bound). Detect it.
    $bindHosts = @($g.Hosts | ForEach-Object { $_.Host })
    $missing = @(Get-MissingBindings -BindHosts $bindHosts -Cert $cert -SiteIdMap $siteIdMap -SiteNameById $siteNameById)
    if ($missing.Count) {
        Write-Host ("          ! {0} covered host(s) are NOT bound to this cert (fixable, no cost):" -f $missing.Count) -ForegroundColor Yellow
        foreach ($mm in $missing) { Write-Host ("              - {0}  [{1}]  ({2})" -f $mm.Host, $mm.Site, $mm.State) -ForegroundColor Yellow }
    }
    $plan.Add([pscustomobject]@{ Index = $idx; Title = $title; Sans = $sans; Base = $g.Base; Zone = $g.Zone; Tag = $tag
            BindHosts = $bindHosts; Cert = $cert; Missing = $missing })
}

# 6. Summary + offer live generation
$need = @($plan | Where-Object Tag -in 'NEED', 'WARN')
$missingTotal = @($plan | ForEach-Object { $_.Missing } | Where-Object { $_ })
Write-Host ''
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ("   {0} certificate(s) cover {1} host name(s).  To generate/renew: {2}.  Unbound hosts: {3}" -f $plan.Count, $uniqueHosts.Count, $need.Count, $missingTotal.Count) -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan

# 6a. Reconcile bindings for hosts that already have a valid cert but aren't bound (no CA cost).
if ($missingTotal.Count) {
    Write-Host ''
    Status 'WARN' 'Binding check' ("{0} host(s) have a valid certificate but a missing/incorrect HTTPS binding" -f $missingTotal.Count)
    if ((Read-Host '  Fix these HTTPS bindings now? (local only - no certificates requested) [Y/n]') -notmatch '^(n|no)$') {
        $fixed = 0
        foreach ($pp in $plan) { if ($pp.Cert -and $pp.Missing.Count) { $fixed += (Repair-Bindings -Missing $pp.Missing -Cert $pp.Cert) } }
        Write-Host ("  Binding repair complete - {0} binding(s) added/updated." -f $fixed) -ForegroundColor Green
    }
}

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
