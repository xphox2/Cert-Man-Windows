<#
  Cert-Man-Windows : Preflight Setup
  Interactive readiness check + auto-fix for Let's Encrypt automation on Windows/IIS.

  Run it (elevated not required up front - it will self-elevate):

      irm https://raw.githubusercontent.com/xphox2/Cert-Man-Windows/main/preflight.ps1 | iex

  It checks the environment, offers to fix what's missing (IIS role, win-acme, etc.),
  loops until everything is green, then optionally runs a real DNS-01 validation test
  against Let's Encrypt staging. ASCII-only, no BOM (so it pipes cleanly to iex).
#>

$Url         = 'https://raw.githubusercontent.com/xphox2/Cert-Man-Windows/main/preflight.ps1'
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

# ---------------------------------------------------- DNS-01 staging test --
function Invoke-DnsTest {
    $wacs = Join-Path $WinAcmePath 'wacs.exe'
    if (-not (Test-Path $wacs)) { Write-Host '   win-acme not installed; skipping DNS test.' -ForegroundColor Yellow; return }

    $testHost = Read-Host '   Wildcard/host to validate (e.g. *.example.com), or ENTER to skip'
    if (-not $testHost) { return }
    $email = Read-Host '   Contact email for the Let''s Encrypt account'
    Write-Host ''
    Write-Host '   DNS provider:   1) Cloudflare    2) Azure DNS    3) GoDaddy' -ForegroundColor White
    $choice = Read-Host '   Choose 1-3'
    $val = switch ($choice) {
        '1' { $t = Read-Host '   Cloudflare API token'; @('--validation', 'cloudflare', '--cloudflareapitoken', $t) }
        '2' {
            $tn = Read-Host '   Azure Tenant ID';    $ci = Read-Host '   Azure Client (App) ID'
            $sc = Read-Host '   Azure Client Secret'; $su = Read-Host '   Azure Subscription ID'
            $rg = Read-Host '   Azure DNS Resource Group'
            @('--validation', 'azure', '--azuretenantid', $tn, '--azureclientid', $ci, '--azuresecret', $sc,
              '--azuresubscriptionid', $su, '--azureresourcegroupname', $rg)
        }
        '3' { $k = Read-Host '   GoDaddy API key'; $s = Read-Host '   GoDaddy API secret'; @('--validation', 'godaddy', '--apikey', $k, '--apisecret', $s) }
        default { $null }
    }
    if (-not $val) { Write-Host '   Skipped.' -ForegroundColor Yellow; return }

    # The DNS provider plugin is a SEPARATE download from the base win-acme build - install it on demand.
    $pluginMatch = switch ($choice) {
        '1' { 'plugin.validation.dns.cloudflare' }
        '2' { 'plugin.validation.dns.azure' }
        '3' { 'plugin.validation.dns.godaddy' }
    }
    Write-Host ''
    Status 'FIX' "$pluginMatch" 'installing DNS provider plugin...'
    try { Install-WinAcmePlugin $pluginMatch; Status 'OK' 'DNS provider plugin' 'installed' }
    catch { Status 'FAIL' 'DNS provider plugin' $_.Exception.Message; return }

    $tmp = Join-Path $env:TEMP ('pf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $fn = "PREFLIGHT $testHost"; $pw = [guid]::NewGuid().ToString('N')
    $log = Join-Path $WinAcmePath 'preflight-dns-test.log'
    Write-Host ''
    Write-Host '   Running a staging issuance (writes + removes a TXT record)...' -ForegroundColor Cyan
    $a = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $testHost) + $val +
         @('--store', 'pfxfile', '--pfxfilepath', $tmp, '--pfxpassword', $pw, '--installation', 'none',
           '--emailaddress', $email, '--accepttos', '--friendlyname', $fn, '--closeonfinish', '--verbose')
    $out = $null
    try { $out = & $wacs @a 2>&1 } catch { $out = $_.Exception.Message }
    $out | Out-File -FilePath $log -Encoding utf8
    $ok = ($LASTEXITCODE -eq 0) -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    try { & $wacs --baseuri $StagingUri --cancel --friendlyname $fn --closeonfinish 2>&1 | Out-Null } catch {}
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if ($ok) {
        Status 'OK' 'DNS-01 validation' "staging cert issued for $testHost - your DNS automation works!"
    } else {
        Status 'FAIL' 'DNS-01 validation' 'staging issuance did not complete'
        Write-Host '   --- win-acme output (last 25 lines) ------------------------' -ForegroundColor DarkYellow
        @($out) | Select-Object -Last 25 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
        Write-Host '   ------------------------------------------------------------' -ForegroundColor DarkYellow
        Write-Host "   Full output saved to: $log" -ForegroundColor Yellow
        Write-Host '   Common causes: wrong API token, token lacks DNS-edit on this zone,' -ForegroundColor Yellow
        Write-Host '   or the zone is hosted by a different provider than selected.' -ForegroundColor Yellow
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
