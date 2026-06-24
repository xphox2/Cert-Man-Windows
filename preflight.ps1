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

# ----------------------------------------------------------- self-elevate --
if (-not (Test-AdminNow)) {
    Banner
    Write-Host '  This needs Administrator rights to install/fix things.' -ForegroundColor Yellow
    Write-Host '  Relaunching in an elevated window (accept the UAC prompt)...' -ForegroundColor Yellow
    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoExit', '-NoProfile', '-Command', "irm $Url | iex"
    } catch {
        Write-Host '  Elevation was cancelled. Re-run from an Administrator PowerShell.' -ForegroundColor Red
    }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------- fixers ----
function Install-WinAcmeInline {
    New-Item -ItemType Directory -Path $WinAcmePath -Force | Out-Null
    $rel = Invoke-RestMethod 'https://api.github.com/repos/win-acme/win-acme/releases/latest' -Headers @{ 'User-Agent' = 'cert-man-preflight' }
    $asset = $rel.assets | Where-Object name -like '*x64.trimmed.zip' | Select-Object -First 1
    if (-not $asset) { throw 'Could not find win-acme release asset.' }
    $zip = Join-Path $env:TEMP 'winacme.zip'
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $WinAcmePath -Force
    Remove-Item $zip -Force
    Get-ChildItem $WinAcmePath -Include *.dll, *.exe -Recurse | Unblock-File
}

# --------------------------------------------------------------- checks ----
function Get-Checks {
    $checks = @()
    $checks += [pscustomobject]@{ Name = 'PowerShell 5.1+'; Ok = ($PSVersionTable.PSVersion.Major -ge 5)
        Detail                            = "v$($PSVersionTable.PSVersion)"; CanFix = $false; Fix = $null }

    $le = (Test-Tcp 'acme-v02.api.letsencrypt.org' 443) -and (Test-Tcp 'acme-staging-v02.api.letsencrypt.org' 443)
    $checks += [pscustomobject]@{ Name = "Internet to Let's Encrypt"; Ok = $le
        Detail = $(if ($le) { 'reachable on :443' } else { 'cannot reach - check firewall/proxy' }); CanFix = $false; Fix = $null }

    $iis = $false; try { $iis = (Get-WindowsFeature Web-Server -ErrorAction Stop).Installed } catch {}
    $checks += [pscustomobject]@{ Name = 'IIS web server role'; Ok = $iis
        Detail = $(if ($iis) { 'installed' } else { 'not installed' }); CanFix = $true
        Fix    = { Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
            Install-WindowsFeature Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null } }

    $wa = $false; try { Import-Module WebAdministration -ErrorAction Stop; $wa = $true } catch {}
    $checks += [pscustomobject]@{ Name = 'IIS PowerShell module'; Ok = $wa
        Detail = $(if ($wa) { 'available' } else { 'missing (IIS mgmt scripting tools)' }); CanFix = $true
        Fix    = { Install-WindowsFeature Web-Scripting-Tools -ErrorAction SilentlyContinue | Out-Null } }

    $hasW = Test-Path (Join-Path $WinAcmePath 'wacs.exe')
    $checks += [pscustomobject]@{ Name = 'win-acme ACME client'; Ok = $hasW
        Detail = $(if ($hasW) { $WinAcmePath } else { 'not installed' }); CanFix = $true
        Fix    = { Install-WinAcmeInline } }

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

    $tmp = Join-Path $env:TEMP ('pf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $fn = "PREFLIGHT $testHost"; $pw = [guid]::NewGuid().ToString('N')
    Write-Host ''
    Write-Host '   Running a staging issuance (writes + removes a TXT record)...' -ForegroundColor Cyan
    $a = @('--baseuri', $StagingUri, '--source', 'manual', '--host', $testHost) + $val +
         @('--store', 'pfxfile', '--pfxfilepath', $tmp, '--pfxpassword', $pw, '--installation', 'none',
           '--emailaddress', $email, '--accepttos', '--friendlyname', $fn, '--closeonfinish')
    try { & $wacs @a 2>&1 | Out-Null } catch {}
    $ok = ($LASTEXITCODE -eq 0) -and (Get-ChildItem $tmp -Filter *.pfx -ErrorAction SilentlyContinue)
    try { & $wacs --baseuri $StagingUri --cancel --friendlyname $fn --closeonfinish 2>&1 | Out-Null } catch {}
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ''
    if ($ok) { Status 'OK' 'DNS-01 validation' "staging cert issued for $testHost - your DNS automation works!" }
    else { Status 'FAIL' 'DNS-01 validation' "failed - check credentials/zone scope and $WinAcmePath logs" }
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
    Write-Host '  Next steps:' -ForegroundColor Cyan
    Write-Host '   - Wildcard / DNS-01 issuance ....... Runbook 02' -ForegroundColor Gray
    Write-Host '   - Public IIS site (HTTP-01) ........ Runbook 01' -ForegroundColor Gray
    Write-Host '   - Replace an existing/vendor cert .. Runbook 08' -ForegroundColor Gray
    Write-Host '   https://github.com/xphox2/Cert-Man-Windows' -ForegroundColor DarkGray
    Write-Host ''
}
