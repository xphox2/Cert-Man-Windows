<#
  Cert-Man-Windows : Preflight Setup
  Interactive readiness check + auto-fix for Let's Encrypt automation on Windows/IIS.

  Run it (elevated not required up front - it will self-elevate):

      irm https://xphox2.github.io/Cert-Man-Windows/preflight.ps1 | iex

  It checks the environment, offers to fix what's missing (IIS role, win-acme, etc.),
  loops until everything is green, then optionally runs a real DNS-01 validation test
  against Let's Encrypt staging. ASCII-only, no BOM (so it pipes cleanly to iex).
#>

$Url         = 'https://xphox2.github.io/Cert-Man-Windows/preflight.ps1'
$WinAcmePath = 'C:\win-acme'
$StagingUri  = 'https://acme-staging-v02.api.letsencrypt.org/directory'

# ----------------------------------------------------------------- helpers --
function Test-AdminNow {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
function Status {
    param([string]$Tag, [string]$Name, [string]$Detail)
    $color = switch ($Tag) { 'OK' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'FIX' { 'Cyan' } default { 'Gray' } }
    Write-Host ('   [{0,-4}] ' -f $Tag) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host ("  - $Detail") -ForegroundColor DarkGray } else { Write-Host '' }
}
function Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host "   Let's Encrypt Automation  -  Preflight Setup" -ForegroundColor Cyan
    Write-Host '   Cert-Man-Windows' -ForegroundColor DarkCyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''
}

# --------------------------------------------- bootstrap: elevate + clean console --
# When launched via `irm ... | iex`, $PSCommandPath is empty and the piped console makes
# Read-Host appear to "freeze" until you press Enter. Fix: relaunch from a downloaded FILE
# in a fresh window (elevated), which gives a proper interactive console. Also self-elevates.
if ((-not $PSCommandPath) -or (-not (Test-AdminNow))) {
    Banner
    $self = Join-Path $env:TEMP 'cmw-preflight.ps1'
    try { (New-Object System.Net.WebClient).DownloadFile($Url, $self) }
    catch { try { Invoke-WebRequest $Url -OutFile $self -UseBasicParsing } catch {} }
    Unblock-File $self -ErrorAction SilentlyContinue
    $a = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self)
    Write-Host '  Opening a clean elevated window (accept the UAC prompt if shown)...' -ForegroundColor Yellow
    try {
        if (Test-AdminNow) { Start-Process powershell -ArgumentList $a }
        else { Start-Process powershell -Verb RunAs -ArgumentList $a }
    } catch {
        Write-Host '  Launch was cancelled. Re-run and accept the prompt.' -ForegroundColor Red
    }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # makes downloads fast in Windows PowerShell 5.1

# --------------------------------------------------------------- fixers ----
function Get-WinAcmeRelease {
    Invoke-RestMethod 'https://api.github.com/repos/win-acme/win-acme/releases/latest' -Headers @{ 'User-Agent' = 'cert-man-preflight' }
}
function Get-File {
    param([string]$Url, [string]$Dest)
    # WebClient is far faster than Invoke-WebRequest for large files in PS 5.1.
    (New-Object System.Net.WebClient).DownloadFile($Url, $Dest)
}
function Install-WinAcmeInline {
    # Clean reinstall so a previous TRIMMED build can't leave stale files behind.
    Remove-Item $WinAcmePath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $WinAcmePath -Force | Out-Null
    # Use the PLUGGABLE build (the trimmed build cannot load external DNS plugins).
    $asset = (Get-WinAcmeRelease).assets | Where-Object name -like '*x64.pluggable.zip' | Select-Object -First 1
    if (-not $asset) { throw 'Could not find win-acme pluggable release asset.' }
    Write-Host ('      downloading win-acme pluggable build ({0} MB)...' -f [math]::Round($asset.size / 1MB, 0)) -ForegroundColor DarkGray
    $zip = Join-Path $env:TEMP 'winacme.zip'
    Get-File $asset.browser_download_url $zip
    Expand-Archive $zip $WinAcmePath -Force
    Remove-Item $zip -Force
    Get-ChildItem $WinAcmePath -Include *.dll, *.exe -Recurse | Unblock-File
}
function Install-WinAcmePlugin {
    param([string]$Match)   # e.g. 'plugin.validation.dns.cloudflare'
    $asset = (Get-WinAcmeRelease).assets | Where-Object { $_.name -like "$Match.*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "win-acme plugin '$Match' not found in latest release." }
    $zip = Join-Path $env:TEMP ($Match + '.zip')
    Get-File $asset.browser_download_url $zip
    Expand-Archive $zip $WinAcmePath -Force
    Remove-Item $zip -Force
    Get-ChildItem $WinAcmePath -Include *.dll -Recurse | Unblock-File
}

# --------------------------------------------------------------- checks ----
function Get-Checks {
    $checks = @()
    $checks += [pscustomobject]@{ Name = 'PowerShell 5.1+'; Ok = ($PSVersionTable.PSVersion.Major -ge 5)
        Detail                            = "v$($PSVersionTable.PSVersion)"; CanFix = $false; Fix = $null }

    $le = (Test-Tcp 'acme-v02.api.letsencrypt.org' 443) -and (Test-Tcp 'acme-staging-v02.api.letsencrypt.org' 443)
    $checks += [pscustomobject]@{ Name = "Internet to Let's Encrypt"; Ok = $le
        Detail = $(if ($le) { 'reachable on :443' } else { 'cannot reach - check firewall/proxy' }); CanFix = $false; Fix = $null }

    $wacsExe = Join-Path $WinAcmePath 'wacs.exe'
    $hasW = Test-Path $wacsExe
    # Reliable build discriminator: pluggable wacs.exe is ~40 MB and CAN load external DNS plugins;
    # the trimmed build is ~19 MB and cannot. (Both ship 0 loose DLLs, so file size is the signal.)
    $sizeMB = if ($hasW) { (Get-Item $wacsExe).Length / 1MB } else { 0 }
    $pluggable = $sizeMB -gt 30
    $checks += [pscustomobject]@{ Name = 'win-acme (pluggable, DNS-capable)'; Ok = ($hasW -and $pluggable)
        Detail = $(if (-not $hasW) { 'not installed' } elseif (-not $pluggable) { ('trimmed build (~{0} MB) - needs pluggable for DNS plugins' -f [math]::Round($sizeMB, 0)) } else { "pluggable build at $WinAcmePath" })
        CanFix = $true; Fix = { Install-WinAcmeInline } }

    $checks
}

# ---------------------------------------------------- DNS provider menu ----
function Get-WinAcmeDnsProviders {
    # The full list of in-box win-acme DNS plugins, derived live from the latest release.
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

# ---------------------------------------------------- DNS-01 staging test --
function Invoke-DnsTest {
    $wacs = Join-Path $WinAcmePath 'wacs.exe'
    if (-not (Test-Path $wacs)) { Write-Host '   win-acme not installed; skipping DNS test.' -ForegroundColor Yellow; return }

    $testHost = Read-Host '   Wildcard/host to validate (e.g. *.example.com), or ENTER to skip'
    if (-not $testHost) { return }
    $email = Read-Host '   Contact email for the Let''s Encrypt account'
    $sel = Get-DnsValidation
    if (-not $sel) { Write-Host '   Skipped.' -ForegroundColor Yellow; return }

    if ($sel.Plugin) {
        Write-Host ''
        Status 'FIX' $sel.Label 'installing DNS provider plugin...'
        try { Install-WinAcmePlugin $sel.Plugin; Status 'OK' 'DNS provider plugin' 'installed' }
        catch { Status 'FAIL' 'DNS provider plugin' $_.Exception.Message; return }
    }
    if ($sel.AcmeDns) {
        Write-Host ''
        Write-Host '   acme-dns is interactive: win-acme will ask you to pick an acme-dns server, then REGISTER and' -ForegroundColor Yellow
        Write-Host '   print a CNAME to create at your registrar (e.g. Network Solutions). First run = register + show' -ForegroundColor Yellow
        Write-Host '   the CNAME; create it, wait ~1 min, then re-run this test to confirm validation succeeds.' -ForegroundColor Yellow
    }

    $tmp = Join-Path $env:TEMP ('pf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $fn = "PREFLIGHT $testHost"; $pw = [guid]::NewGuid().ToString('N')
    $log = Join-Path $WinAcmePath 'preflight-dns-test.log'
    $a = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $testHost) + $sel.Args +
         @('--store', 'pfxfile', '--pfxfilepath', $tmp, '--pfxpassword', $pw, '--installation', 'none',
           '--emailaddress', $email, '--accepttos', '--friendlyname', $fn, '--closeonfinish', '--verbose')

    Write-Host ''
    Write-Host "   Running a STAGING issuance to validate DNS-01 via $($sel.Label)..." -ForegroundColor Cyan
    $out = $null
    if ($sel.Interactive) {
        # acme-dns / manual must be interactive (win-acme prompts for the endpoint/registration or the TXT).
        & $wacs @a
        $ok = ($LASTEXITCODE -eq 0) -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    } else {
        try { $out = & $wacs @a 2>&1 } catch { $out = $_.Exception.Message }
        $out | Out-File -FilePath $log -Encoding utf8
        $ok = ($LASTEXITCODE -eq 0) -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    }
    try { & $wacs --baseuri $StagingUri --cancel --friendlyname $fn --closeonfinish 2>&1 | Out-Null } catch {}
    # win-acme makes a per-endpoint scheduled task on issuance; --cancel drops the renewal but NOT the task,
    # leaving an orphaned 'win-acme renew (acme-staging-v02...)' job. Remove it (production 'acme-v02' never matches).
    try { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'acme-staging' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if ($ok) {
        Status 'OK' 'DNS-01 validation' "staging cert issued for $testHost via $($sel.Label) - your DNS automation works!"
    } else {
        Status 'FAIL' 'DNS-01 validation' "staging issuance did not complete ($($sel.Label))"
        if ($out) {
            Write-Host '   --- win-acme output (last 25 lines) ------------------------' -ForegroundColor DarkYellow
            @($out) | Select-Object -Last 25 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
            Write-Host "   Full output saved to: $log" -ForegroundColor Yellow
        } else {
            Write-Host '   See the win-acme output above (and C:\ProgramData\win-acme logs).' -ForegroundColor Yellow
        }
        if ($sel.AcmeDns) {
            Write-Host '   acme-dns: if it printed a CNAME, create it at your registrar, wait ~1 min, then re-run this test.' -ForegroundColor Yellow
        } else {
            Write-Host '   Common causes: wrong credentials, the key lacks DNS-edit on this zone, or the wrong provider.' -ForegroundColor Yellow
        }
    }
}

# ----------------------------------------------------------- main loop -----
Banner
Write-Host '  Checking your environment...' -ForegroundColor White
Write-Host ''

$round = 0
while ($true) {
    $round++
    $checks = Get-Checks
    foreach ($c in $checks) { Status ($(if ($c.Ok) { 'OK' } else { 'FAIL' })) $c.Name $c.Detail }
    Write-Host ''

    $bad = @($checks | Where-Object { -not $_.Ok })
    if ($bad.Count -eq 0) {
        Write-Host '  All checks passed - this server is READY for Let''s Encrypt automation.' -ForegroundColor Green
        break
    }

    $fixable = @($bad | Where-Object CanFix)
    $manual = @($bad | Where-Object { -not $_.CanFix })
    foreach ($m in $manual) { Write-Host "  ! Needs your attention (cannot auto-fix): $($m.Name) - $($m.Detail)" -ForegroundColor Yellow }

    if ($fixable.Count -eq 0) {
        Write-Host '  Resolve the item(s) above, then re-run this command.' -ForegroundColor Yellow
        break
    }
    if ($round -gt 6) { Write-Host '  Stopping after several attempts. Please review the items above.' -ForegroundColor Yellow; break }

    $ans = Read-Host ("  Fix {0} issue(s) automatically now? [Y/n]" -f $fixable.Count)
    if ($ans -match '^(n|no)$') { Write-Host '  Okay, stopping. Re-run any time.' -ForegroundColor Yellow; break }

    Write-Host ''
    foreach ($f in $fixable) {
        Status 'FIX' $f.Name 'working...'
        try { & $f.Fix; Status 'OK' $f.Name 'fixed' }
        catch { Status 'FAIL' $f.Name $_.Exception.Message }
    }
    Write-Host ''
    Write-Host '  Re-checking...' -ForegroundColor White
    Write-Host ''
}

# ------------------------------------------------ ready: optional DNS test -
$allOk = -not (@(Get-Checks | Where-Object { -not $_.Ok }).Count)
if ($allOk) {
    Write-Host ''
    $go = Read-Host '  Run a DNS-01 validation test now (proves wildcard issuance works)? [y/N]'
    if ($go -match '^(y|yes)$') { Write-Host ''; Invoke-DnsTest }

    Write-Host ''
    Write-Host '  ACME + DNS are ready. Per-scenario setup scripts:' -ForegroundColor Cyan
    Write-Host '   - Set up IIS (role + site/binding) .. scripts\Setup-IIS.ps1' -ForegroundColor Gray
    Write-Host '   - Wildcard / DNS-01 issuance ....... Runbook 02' -ForegroundColor Gray
    Write-Host '   - Public IIS site (HTTP-01) ........ Runbook 01' -ForegroundColor Gray
    Write-Host '   - Replace an existing/vendor cert .. Runbook 08' -ForegroundColor Gray
    Write-Host '   https://github.com/xphox2/Cert-Man-Windows' -ForegroundColor DarkGray
    Write-Host ''
}
