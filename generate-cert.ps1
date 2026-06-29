<#
  Cert-Man-Windows : Generate Certificate (export only - NO IIS)

  A standalone issuer. Unlike setup-iis.ps1 it does NOT scan IIS and does NOT
  bind/install anything to IIS ("the loading part"). You simply TYPE the host
  name(s) for the certificate; it validates via DNS-01 on the live Let's Encrypt
  server and writes a password-protected PFX you can copy to other devices.

  Use this on a dedicated UTIL / issuer server: generate the cert here, then
  share the PFX out to the servers/devices that actually serve it (bind it with
  the scripts\Deploy-*.ps1 helpers, or import it manually).

  win-acme still creates a renewal task here, so the PFX is refreshed on every
  renewal; an optional post-renewal hook can auto-copy it to other devices.

  Run it:
      irm https://xphox2.github.io/Cert-Man-Windows/generate-cert.ps1 | iex
#>

$Url         = 'https://xphox2.github.io/Cert-Man-Windows/generate-cert.ps1'
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
    Write-Host '   Cert-Man-Windows  -  Generate Certificate (no IIS)' -ForegroundColor Cyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''
}
function Get-File { param([string]$Url, [string]$Dest) (New-Object System.Net.WebClient).DownloadFile($Url, $Dest) }

# --------------------------------------------- bootstrap: elevate + clean console --
if ((-not $PSCommandPath) -or (-not (Test-AdminNow))) {
    Banner
    $self = Join-Path $env:TEMP 'cmw-generate-cert.ps1'
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
    $h = $HostName.ToLower().TrimEnd('.').TrimStart('*').TrimStart('.'); $labels = $h.Split('.')
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

# --------------------------------------------- cert store helper ------------
function Find-NewestCovering {
    param([string[]]$Sans)
    $best = $null
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
function Set-WinAcmePreValidation {
    # Tune win-acme's BUILT-IN DNS pre-validation so manual issuance waits for propagation and
    # checks PUBLIC resolvers (not the local cache). After you press Enter, win-acme resolves the
    # zone's authoritative nameservers (via these public servers) and re-checks the TXT every
    # interval up to RetryCount times BEFORE asking Let's Encrypt to validate - so it does not
    # submit (and cannot fail) until the record is actually visible. No scripts are written.
    param([int]$WaitMinutes = 30)
    $wacs = Join-Path $WinAcmePath 'wacs.exe'
    $cfg  = Join-Path $WinAcmePath 'settings.json'
    if (-not (Test-Path $cfg)) { try { & $wacs --version 2>&1 | Out-Null } catch {} }  # first run creates it
    $interval = 30
    $retries  = [math]::Max(4, [int]([math]::Ceiling(($WaitMinutes * 60) / $interval)))
    $servers  = @('8.8.8.8', '1.1.1.1', '9.9.9.9', '8.8.4.4')
    try {
        $j = if (Test-Path $cfg) { Get-Content $cfg -Raw | ConvertFrom-Json } else { [pscustomobject]@{ Validation = [pscustomobject]@{} } }
        if (-not $j.Validation) { $j | Add-Member -NotePropertyName Validation -NotePropertyValue ([pscustomobject]@{}) -Force }
        $j.Validation.PreValidateDns = $true
        $j.Validation.PreValidateDnsRetryCount = $retries
        $j.Validation.PreValidateDnsRetryInterval = $interval
        $j.Validation.DnsServers = $servers
        ($j | ConvertTo-Json -Depth 20) | Set-Content -Path $cfg -Encoding utf8
        return [pscustomobject]@{ Ok = $true; Retries = $retries; Interval = $interval; Servers = $servers }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
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
    Write-Host '     6) Manual         - one-off; win-acme shows the TXT, you press Enter (default ~5 min DNS wait)' -ForegroundColor White
    Write-Host '     7) Manual + auto-verify (ONE-TIME) - win-acme shows the TXT record(s); after you add them it' -ForegroundColor White
    Write-Host '                          polls PUBLIC DNS until visible (waits longer, will not submit early). No renewal task.' -ForegroundColor White
    switch (Read-Host '   Choose 1-7') {
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
        '7' {
            $wm = Read-Host '   Minutes to wait for DNS propagation after you press Enter (default 30)'
            $wait = if ($wm -match '^[0-9]+$' -and [int]$wm -gt 0) { [int]$wm } else { 30 }
            $pv = Set-WinAcmePreValidation -WaitMinutes $wait
            if ($pv.Ok) {
                Write-Host ("   win-acme will re-check PUBLIC DNS ({0}) every {1}s, up to {2} times (~{3} min)," -f ($pv.Servers -join ', '), $pv.Interval, $pv.Retries, $wait) -ForegroundColor DarkGray
                Write-Host '   and only ask Let''s Encrypt to validate once the TXT record is actually visible.' -ForegroundColor DarkGray
            } else {
                Write-Host ("   Could not tune pre-validation ({0}); win-acme will use its defaults (~5 min)." -f $pv.Error) -ForegroundColor Yellow
            }
            return @{ Args = @('--validation', 'manual'); Plugin = $null; Interactive = $true; Label = "Manual + auto-verify (one-time, waits ~${wait}m for DNS)"; Manual = $true; OneTime = $true; AutoVerify = $true }
        }
        default { return $null }
    }
}

# --------------------------------------------- generation plumbing ----------
function Invoke-WacsRetry {
    # Run wacs.exe and retry on TRANSIENT Let's Encrypt errors ("Service busy; retry later",
    # ServiceUnavailable). Does NOT retry real failures (bad DNS token, rate limit, etc.).
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
    # SAN set without touching production rate limits or storing anything. Returns $true/$false.
    param([string]$Wacs, [string[]]$Sans, [string[]]$Val, [string]$Email)
    $hostArg = $Sans -join ','
    $tmp = Join-Path $env:TEMP ('cmw-stg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $tmp -Force | Out-Null
    $fn = "[CertMan-STAGING] $hostArg"
    $log = Join-Path $WinAcmePath ("staging-{0}.log" -f ($hostArg -replace '[^a-z0-9]', '_'))
    # --notaskscheduler: this is a throwaway staging test - do NOT let win-acme create a scheduled task for it.
    $a = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $hostArg) + $Val +
         @('--store', 'pfxfile', '--pfxfilepath', $tmp, '--pfxpassword', [guid]::NewGuid().ToString('N'),
           '--installation', 'none', '--notaskscheduler', '--emailaddress', $Email, '--accepttos', '--friendlyname', $fn, '--closeonfinish', '--verbose')
    $r = Invoke-WacsRetry -Wacs $Wacs -WacsArgs $a -IsSuccess { $LASTEXITCODE -eq 0 }
    $out = $r.Out
    $out | Out-File -FilePath $log -Encoding utf8
    $ok = $r.Ok -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    try { & $Wacs --baseuri $StagingUri --cancel --friendlyname $fn --closeonfinish 2>&1 | Out-Null } catch {}
    try { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'acme-staging' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $ok) {
        @($out) | Select-Object -Last 18 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        Write-Host "         Full log: $log" -ForegroundColor Yellow
    }
    return [bool]$ok
}

# --------------------------------------------- input: host names ------------
function Read-CertHosts {
    # Prompt for the SAN set for ONE certificate. Accepts comma/space separated names,
    # supports wildcards (*.example.com). Returns a de-duplicated lowercase string[] or $null.
    Write-Host ''
    Write-Host '  Enter the host name(s) for THIS certificate (comma-separated). All names go on ONE cert.' -ForegroundColor White
    Write-Host '    examples:  app.example.com' -ForegroundColor DarkGray
    Write-Host '               *.example.com, example.com                       (wildcard + apex)' -ForegroundColor DarkGray
    Write-Host '               a.example.com, b.example.com                     (SAN / multi-name)' -ForegroundColor DarkGray
    Write-Host '               example.com, *.example.com, *.1.example.com,     (apex + multiple' -ForegroundColor DarkGray
    Write-Host '                 *.2.example.com, *.3.example.com                 wildcards, any depth)' -ForegroundColor DarkGray
    Write-Host '    note: a wildcard (*.x) covers ONLY one label - *.example.com does NOT cover the apex' -ForegroundColor DarkGray
    Write-Host '          (example.com) nor a deeper label (*.1.example.com). Add each level you need.' -ForegroundColor DarkGray
    $raw = Read-Host '  Host name(s)'
    if (-not $raw) { return $null }
    $names = @($raw -split '[,\s]+' | ForEach-Object { $_.Trim().ToLower().TrimEnd('.') } | Where-Object { $_ })
    $names = @($names | Select-Object -Unique)
    if (-not $names.Count) { return $null }
    # Basic sanity: each name must look like a hostname (allow a leading *. for wildcards).
    foreach ($n in $names) {
        if ($n -notmatch '^(\*\.)?([a-z0-9_-]+\.)+[a-z]{2,}$') {
            Write-Host ("  '{0}' does not look like a valid host name." -f $n) -ForegroundColor Yellow
            return $null
        }
    }
    return $names
}

# --------------------------------------------- per-cert workflow ------------
function Invoke-GenerateOne {
    param([string[]]$Sans, [string]$Email, [hashtable]$Session)
    $wacs    = Join-Path $WinAcmePath 'wacs.exe'
    $hostArg = ($Sans -join ',')
    $zones   = @($Sans | ForEach-Object { Get-RegistrableDomain $_ } | Select-Object -Unique | Sort-Object)
    $base    = $zones[0]
    $title   = $hostArg

    Write-Host ''
    Status 'NEED' ("Certificate:  {0}" -f $title) ("DNS zone(s): {0}" -f ($zones -join ', '))
    if ($Sans.Count -gt 1) {
        Write-Host ("   This is ONE certificate covering all {0} name(s) above (a single multi-SAN cert)." -f $Sans.Count) -ForegroundColor DarkGray
        Write-Host '   DNS-01 requires one TXT record per name, so win-acme will ask for several - that is normal.' -ForegroundColor DarkGray
    }
    if ($zones.Count -gt 1) {
        Write-Host '   This cert spans more than one DNS zone. The DNS method you pick must be able to' -ForegroundColor Yellow
        Write-Host '   create the _acme-challenge record in EVERY zone above (or use Manual / acme-dns).' -ForegroundColor Yellow
    }

    # --- DNS validation method (one per cert) ------------------------------
    $s = Get-DnsValidation
    if (-not $s) { Write-Host '   No DNS method chosen; skipping this certificate.' -ForegroundColor Yellow; return }
    if ($s.Plugin -and -not $Session.DonePlugins.ContainsKey($s.Plugin)) {
        Status 'FIX' 'DNS provider plugin' "installing $($s.Label)..."
        try { Install-WinAcmePlugin $s.Plugin; $Session.DonePlugins[$s.Plugin] = $true; Status 'OK' 'DNS provider plugin' "installed ($($s.Label))" }
        catch { Status 'FAIL' 'DNS provider plugin' $_.Exception.Message; return }
    }
    if ($s.AcmeDns) { Write-Host '   acme-dns: win-acme prints a one-time CNAME to create at your registrar; then renewals are automatic.' -ForegroundColor Yellow }
    if ($s.AutoVerify) {
        Write-Host '   ONE-TIME auto-verify: for EACH name, win-acme prints a TXT record to create. Add it at your DNS,' -ForegroundColor Yellow
        Write-Host '   then press Enter - win-acme re-checks PUBLIC DNS and waits until the record is visible before' -ForegroundColor Yellow
        Write-Host '   asking Let''s Encrypt to validate, so it will not fail if propagation is slow. No renewal task (one-time).' -ForegroundColor Yellow
    }
    elseif ($s.Manual) { Write-Host '   MANUAL DNS: win-acme prints a TXT record; this cert will NOT auto-renew.' -ForegroundColor Yellow }

    # --- PFX export (the whole point of this script - always on) ------------
    $pfxDefault = Join-Path $WinAcmePath 'pfx'
    $d = Read-Host ("  PFX output folder [default $pfxDefault]")
    $pfxDir = if ($d) { $d } else { $pfxDefault }
    New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
    $pfxPw = Read-Host '  PFX password (protects the exported file)'
    if (-not $pfxPw) { $pfxPw = [guid]::NewGuid().ToString('N'); Write-Host "  (no password entered - generated one: $pfxPw )" -ForegroundColor DarkGray }

    # Optionally ALSO drop it in this machine's LocalMachine\My store (e.g. to bind locally too).
    $alsoStore = (Read-Host '  Also import into THIS machine''s certificate store (LocalMachine\My)? [y/N]') -match '^(y|yes)$'

    # --- Optional post-renewal copy hook -----------------------------------
    $copyScript = $null; $hookLog = $null
    $destInput = Read-Host '  Auto-copy the PFX to other devices after EACH renewal? Destination folder(s), comma-separated (UNC or local), or blank to skip'
    if ($destInput) {
        $dests = @($destInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $destLiteral = '@(' + (($dests | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
        $copyScript = Join-Path $WinAcmePath 'post-renew-copy.ps1'
        $hookLog = Join-Path $WinAcmePath 'post-renew-copy.log'
        $w = @(
            '# Auto-generated by generate-cert.ps1 - copies renewed PFX to other devices. Runs as SYSTEM after each win-acme renewal.',
            ('$src   = ' + "'" + ($pfxDir -replace "'", "''") + "'"),
            ('$dests = ' + $destLiteral),
            ('$log   = ' + "'" + ($hookLog -replace "'", "''") + "'"),
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
        Write-Host "  Post-renewal hook installed -> $copyScript (logs to $hookLog)" -ForegroundColor DarkGray
        Write-Host '  NOTE: renewals run as SYSTEM - UNC targets must allow the computer account (DOMAIN\MACHINE$).' -ForegroundColor Yellow
        Write-Host '  If that is not possible, share a LOCAL folder here and have each device PULL from it instead.' -ForegroundColor Yellow
    }

    # --- Staging dry-run (only for automated DNS methods) ------------------
    Write-Host ''
    if (-not $s.Interactive) {
        $doStaging = (Read-Host "  Dry-run on Let's Encrypt STAGING first? (recommended - no rate-limit cost) [Y/n]") -notmatch '^(n|no)$'
        if ($doStaging) {
            if (Test-StagingValidatedRecently $base) {
                Status 'OK' $title 'staging validated in last 7 days - skipping (saves staging limits)'
            } else {
                Status 'FIX' $title 'testing on staging...'
                if (Test-StagingCert -Wacs $wacs -Sans $Sans -Val $s.Args -Email $Email) {
                    Status 'OK' $title 'staging validated'; Set-StagingValidated $base
                } else {
                    Status 'FAIL' $title 'staging failed (output above). Production was NOT touched.'
                    return
                }
            }
        }
    } else {
        Write-Host '  Interactive DNS (acme-dns / manual / prompt) - validates live during production issuance.' -ForegroundColor DarkGray
    }

    # --- Production issuance (NO IIS binding) ------------------------------
    Write-Host ''
    Write-Host '  >>> PRODUCTION: live, trusted certificate (counts against rate limits, 50/domain/week). <<<' -ForegroundColor Yellow
    if ($s.Manual -or $s.AcmeDns) {
        Write-Host '  Say YES to continue: win-acme will then DISPLAY the TXT record(s) for you to create.' -ForegroundColor Cyan
        Write-Host '  Nothing is issued until you add them and DNS verifies - this is the step where records appear.' -ForegroundColor Cyan
    }
    if ((Read-Host '  Proceed and show the DNS record(s) to create now? [y/N]') -notmatch '^(y|yes)$') {
        Write-Host '  Skipped - nothing was requested from Let''s Encrypt.' -ForegroundColor Yellow; return
    }

    $log = Join-Path $WinAcmePath ("issue-{0}.log" -f ($hostArg -replace '[^a-z0-9]', '_'))
    # Store: always pfxfile; optionally ALSO the Windows cert store (My) for local use. NEVER IIS.
    $storeArgs = if ($alsoStore) {
        @('--store', 'certificatestore,pfxfile', '--certificatestore', 'My', '--pfxfilepath', $pfxDir, '--pfxpassword', $pfxPw)
    } else {
        @('--store', 'pfxfile', '--pfxfilepath', $pfxDir, '--pfxpassword', $pfxPw)
    }
    # Installation: NONE (no IIS / no service binding). If a copy hook exists, run it as the only step.
    $instArgs = if ($copyScript) { @('--installation', 'script', '--script', $copyScript) } else { @('--installation', 'none') }
    $a = @('--baseuri', $ProdUri, '--source', 'manual', '--host', $hostArg) + $s.Args + $storeArgs + $instArgs +
         @('--emailaddress', $Email, '--accepttos', '--friendlyname', "[CertMan] $title", '--closeonfinish', '--verbose')
    # One-time methods: do NOT create a renewal scheduled task (renewal would re-prompt for a new TXT).
    if ($s.OneTime) { $a += '--notaskscheduler' }

    Write-Host ''
    Write-Host ("  === Generating: {0} ===" -f $title) -ForegroundColor Cyan
    if ($s.Interactive) {
        if ($s.AcmeDns) { Write-Host '  >>> acme-dns: follow win-acme''s prompts (it uses your one-time CNAME). <<<' -ForegroundColor Yellow }
        elseif ($s.AutoVerify) { Write-Host '  >>> For each name: add the TXT record win-acme shows, then press Enter. It waits for public DNS, then issues. <<<' -ForegroundColor Yellow }
        elseif ($s.Manual) { Write-Host '  >>> Manual: win-acme will show a TXT record; add it at your DNS, wait ~1 min, follow the prompt. <<<' -ForegroundColor Yellow }
        else { Write-Host "  >>> $($s.Label): enter the provider's credentials when win-acme prompts. <<<" -ForegroundColor Yellow }
        & $wacs @a
        $ok = ($LASTEXITCODE -eq 0)
    } else {
        $r = Invoke-WacsRetry -Wacs $wacs -WacsArgs $a -IsSuccess { $LASTEXITCODE -eq 0 }
        $ok = $r.Ok
        $r.Out | Out-File -FilePath $log -Encoding utf8
    }

    if (-not $ok) {
        Status 'FAIL' $title 'issuance failed'
        if (-not $s.Interactive) {
            @($r.Out) | Select-Object -Last 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            Write-Host "      Full log: $log" -ForegroundColor Yellow
        } else {
            Write-Host "      See win-acme output above, and C:\ProgramData\win-acme logs." -ForegroundColor Yellow
        }
        return
    }

    # Report what landed.
    $pfx = @(Get-ChildItem $pfxDir -Filter '*.pfx' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $exp = 'check store/PFX'
    if ($alsoStore) { $cert = Find-NewestCovering $Sans; if ($cert) { $exp = $cert.NotAfter.ToString('yyyy-MM-dd') } }
    Status 'OK' $title ("issued, expires {0}" -f $exp)
    if ($pfx) { Write-Host ("      PFX exported: {0}  (password as entered)" -f $pfx[0].FullName) -ForegroundColor Green }
    if ($alsoStore -and $cert) { Write-Host ("      Also in LocalMachine\My  (thumbprint {0})" -f $cert.Thumbprint) -ForegroundColor DarkGray }
    if ($s.Manual) {
        Write-Host '      NOTE: MANUAL DNS - this cert does NOT auto-renew. Re-run before expiry.' -ForegroundColor Yellow
    } else {
        Write-Host '      win-acme created a renewal task - the PFX is refreshed on every renewal.' -ForegroundColor DarkGray
    }
}

# ----------------------------------------------------------------- main -----
Banner

# 1. win-acme present + pluggable? (NO IIS requirement here.)
$wacsExe = Join-Path $WinAcmePath 'wacs.exe'
$wacsOk = (Test-Path $wacsExe) -and ((Get-Item $wacsExe).Length / 1MB -gt 30)
if ($wacsOk) {
    Status 'OK' 'win-acme (pluggable)' $WinAcmePath
} else {
    Status 'WARN' 'win-acme (pluggable)' 'not ready'
    Write-Host ''
    Write-Host '  Run the preflight first to install win-acme, then re-run this script:' -ForegroundColor Yellow
    Write-Host '    irm https://xphox2.github.io/Cert-Man-Windows/preflight.ps1 | iex' -ForegroundColor Gray
    Write-Host ''
    return
}

Initialize-Psl

Write-Host ''
Write-Host '  Generate-only mode: this script does NOT scan or bind IIS. It issues the cert(s)' -ForegroundColor White
Write-Host '  you name and exports a PFX you can copy to other devices/servers.' -ForegroundColor White

$email = Read-Host '   Contact email for the Let''s Encrypt account'
$session = @{ DonePlugins = @{} }

# 2. Loop: one certificate per pass.
do {
    $sans = Read-CertHosts
    if (-not $sans) { Write-Host '  No valid host names entered.' -ForegroundColor Yellow }
    else { Invoke-GenerateOne -Sans $sans -Email $email -Session $session }
    Write-Host ''
} while ((Read-Host '  Generate ANOTHER certificate? [y/N]') -match '^(y|yes)$')

Write-Host ''
Write-Host ("  Done. Exported PFX files live under {0} (and any copy-hook destinations)." -f (Join-Path $WinAcmePath 'pfx')) -ForegroundColor Green
Write-Host '  Copy them to each device and import/bind (see scripts\Deploy-*.ps1 for RDP/SQL/Exchange/HTTP.SYS).' -ForegroundColor DarkGray
Write-Host '   https://github.com/xphox2/Cert-Man-Windows  (Runbook 03 = non-IIS deployment)' -ForegroundColor DarkGray
Write-Host ''
