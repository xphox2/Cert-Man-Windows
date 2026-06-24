<#
  Cert-Man-Windows : Wildcard Certificate Planner
  Scans IIS sites/bindings, groups host names into the minimum set of wildcard
  certificates needed (collapsing names that share a parent domain), shows which
  are already covered, and prints the win-acme commands to generate the rest.

  Read-only. Run it:

      irm https://xphox2.github.io/Cert-Man-Windows/plan-certs.ps1 | iex
#>

$Url         = 'https://xphox2.github.io/Cert-Man-Windows/plan-certs.ps1'
$WinAcmePath = 'C:\win-acme'

# ----------------------------------------------------------------- helpers --
function Test-AdminNow {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Status {
    param([string]$Tag, [string]$Name, [string]$Detail)
    $color = switch ($Tag) { 'OK' { 'Green' } 'NEED' { 'Red' } 'WARN' { 'Yellow' } 'APEX' { 'Magenta' } default { 'Gray' } }
    Write-Host ('   [{0,-4}] ' -f $Tag) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host ("  - $Detail") -ForegroundColor DarkGray } else { Write-Host '' }
}
function Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host '   Cert-Man-Windows  -  Wildcard Certificate Planner' -ForegroundColor Cyan
    Write-Host '  ==================================================' -ForegroundColor Cyan
    Write-Host ''
}

# --------------------------------------------- bootstrap: elevate + clean console --
# Reading IIS config needs admin; piping to iex degrades the console. Relaunch from a
# downloaded FILE in a fresh elevated window for a proper, non-frozen interactive console.
if ((-not $PSCommandPath) -or (-not (Test-AdminNow))) {
    Banner
    $self = Join-Path $env:TEMP 'cmw-plan-certs.ps1'
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
    $h = $HostName.ToLower().TrimEnd('.')
    $labels = $h.Split('.')
    if ($labels.Count -le 2 -or $script:PslRules.Count -eq 0) {
        # fallback / simple TLD: last two labels are the registrable domain
        if ($labels.Count -le 2) { return $h }
        return ($labels[-2..-1] -join '.')
    }
    # Find the longest matching public suffix per the PSL algorithm.
    $suffixLabelCount = 1
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $cand = ($labels[$i..($labels.Count - 1)]) -join '.'
        $parentLabels = if ($i + 1 -lt $labels.Count) { ($labels[($i + 1)..($labels.Count - 1)]) -join '.' } else { '' }
        $wild = '*.' + $parentLabels
        if ($script:PslRules.Contains('!' + $cand)) { $suffixLabelCount = ($labels.Count - 1 - $i); break }
        if ($script:PslRules.Contains($cand)) { $suffixLabelCount = ($labels.Count - $i); break }
        if ($parentLabels -and $script:PslRules.Contains($wild)) { $suffixLabelCount = ($labels.Count - $i); break }
    }
    $take = $suffixLabelCount + 1
    if ($labels.Count -lt $take) { return $h }
    return ($labels[($labels.Count - $take)..($labels.Count - 1)] -join '.')
}

# --------------------------------------------- existing cert lookup ---------
function Find-CoveringCert {
    param([string[]]$Sans)
    foreach ($c in (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)) {
        if ($c.NotAfter -lt (Get-Date)) { continue }
        $names = @($c.DnsNameList | ForEach-Object { $_.Unicode.ToLower() })
        $all = $true
        foreach ($s in $Sans) { if ($names -notcontains $s.ToLower()) { $all = $false; break } }
        if ($all) { return $c }
    }
    return $null
}
function Get-CertSource {
    param($Cert)
    if ($Cert.Subject -eq $Cert.Issuer) { return 'self-signed' }
    if ($Cert.Issuer -match "Let's Encrypt|\bR1[0-9]\b|\bE[0-9]\b") { return "Let's Encrypt" }
    if ($Cert.Issuer -match 'GoDaddy') { return 'GoDaddy' }
    if ($Cert.Issuer -match 'DigiCert') { return 'DigiCert' }
    if ($Cert.Issuer -match 'Sectigo|COMODO') { return 'Sectigo' }
    if ($Cert.Issuer -match 'CN=([^,]+)') { return $matches[1] }
    return 'other CA'
}

# ----------------------------------------------------------------- main -----
Banner
try { Import-Module WebAdministration -ErrorAction Stop }
catch {
    Write-Host '  IIS / WebAdministration not available. Install IIS first (scripts\Setup-IIS.ps1).' -ForegroundColor Red
    return
}
Initialize-Psl
if ($script:PslRules.Count -eq 0) {
    Write-Host '  (public_suffix_list.dat not found in C:\win-acme - using simple last-2-labels rule.)' -ForegroundColor DarkYellow
    Write-Host ''
}

# 1. Collect host bindings across all sites
$bindings = New-Object System.Collections.Generic.List[object]
$noHost = 0
foreach ($site in Get-Website) {
    foreach ($b in $site.bindings.Collection) {
        if ($b.protocol -notin 'http', 'https') { continue }
        $parts = $b.bindingInformation -split ':'
        $h = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        if ([string]::IsNullOrWhiteSpace($h)) { $noHost++; continue }
        $bindings.Add([pscustomobject]@{ Host = $h.ToLower(); Site = $site.Name; Protocol = $b.protocol })
    }
}
$hostCount = (@($bindings | Select-Object -Expand Host -Unique)).Count
Write-Host ("  Scanned {0} site(s), found {1} unique host name(s) across {2} binding(s)." -f (Get-Website).Count, $hostCount, $bindings.Count) -ForegroundColor White
if ($noHost) { Write-Host ("  ({0} binding(s) had no host header - cannot be covered by a named cert; skipped.)" -f $noHost) -ForegroundColor DarkGray }
Write-Host ''

if ($bindings.Count -eq 0) { Write-Host '  No host-named bindings found. Add host headers to your sites first.' -ForegroundColor Yellow; return }

# 2. Group each host into its certificate group
$groups = @{}
foreach ($h in ($bindings | Select-Object -Expand Host -Unique)) {
    $reg = Get-RegistrableDomain $h
    if ($h -eq $reg) { $base = $reg; $role = 'apex' }
    else { $base = ($h.Split('.', 2))[1]; $role = 'child' }   # drop first label
    if (-not $groups.ContainsKey($base)) {
        $groups[$base] = [pscustomobject]@{ Base = $base; Zone = $reg; Hosts = (New-Object System.Collections.Generic.List[object]); ApexBound = $false; HasChild = $false }
    }
    $sites = @($bindings | Where-Object Host -eq $h | Select-Object -Expand Site -Unique)
    $groups[$base].Hosts.Add([pscustomobject]@{ Host = $h; Role = $role; Sites = $sites })
    if ($role -eq 'apex') { $groups[$base].ApexBound = $true } else { $groups[$base].HasChild = $true }
}

# 3. Analyse + display each proposed certificate
$plan = New-Object System.Collections.Generic.List[object]
$idx = 0
foreach ($g in ($groups.Values | Sort-Object Base)) {
    $idx++
    $sans = @()
    if ($g.HasChild) { $sans += "*.$($g.Base)" }
    if ($g.ApexBound -or -not $g.HasChild) { $sans += $g.Base }
    $sans = $sans | Select-Object -Unique
    $title = $sans -join ', '

    $cert = Find-CoveringCert $sans
    $tag = 'NEED'; $detail = 'no covering certificate in the store - generate it'
    if ($cert) {
        $days = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        $src = Get-CertSource $cert
        if ($days -le 30) { $tag = 'WARN'; $detail = "covered by $src cert, expires in $days days - renew/replace" }
        else { $tag = 'OK'; $detail = "covered by $src cert, $days days left" }
    } elseif (-not $g.HasChild) {
        $tag = 'APEX'; $detail = 'apex only - single-name cert (no wildcard needed)'
    }

    Write-Host ''
    Status $tag ("Certificate {0}:  {1}" -f $idx, $title) $detail
    Write-Host ("          DNS zone for validation: {0}" -f $g.Zone) -ForegroundColor DarkGray
    Write-Host ("          Covers {0} host(s):" -f $g.Hosts.Count) -ForegroundColor DarkGray
    foreach ($hh in ($g.Hosts | Sort-Object Host)) {
        $marker = if ($hh.Role -eq 'apex') { '(apex)' } else { '       ' }
        Write-Host ("            - {0,-34} {1}  [{2}]" -f $hh.Host, $marker, ($hh.Sites -join ', ')) -ForegroundColor Gray
    }
    $plan.Add([pscustomobject]@{ Index = $idx; Title = $title; Sans = $sans; Zone = $g.Zone; Tag = $tag; HasChild = $g.HasChild })
}

# 4. Summary + commands for the ones that need generating
$need = @($plan | Where-Object Tag -in 'NEED', 'WARN')
$wild = @($plan | Where-Object HasChild)
Write-Host ''
Write-Host '  ==================================================' -ForegroundColor Cyan
Write-Host ("   Plan: {0} certificate(s) cover {1} host name(s)." -f $plan.Count, $hostCount) -ForegroundColor Cyan
Write-Host ("   Wildcards: {0}   To generate/renew: {1}   Already OK: {2}" -f $wild.Count, $need.Count, @($plan | Where-Object Tag -eq 'OK').Count) -ForegroundColor Cyan
Write-Host '  ==================================================' -ForegroundColor Cyan

if ($need.Count) {
    Write-Host ''
    Write-Host '  Commands to generate the missing certificates (DNS-01 - fill in your provider + token):' -ForegroundColor White
    Write-Host '  Run the preflight first if win-acme/plugins are not installed yet.' -ForegroundColor DarkGray
    Write-Host ''
    foreach ($p in $need) {
        $hostArg = ($p.Sans -join ',')
        Write-Host ("  # Certificate {0}: {1}   (zone: {2})" -f $p.Index, $p.Title, $p.Zone) -ForegroundColor DarkCyan
        Write-Host ("  cd $WinAcmePath") -ForegroundColor Gray
        Write-Host ("  .\wacs.exe --source manual --host `"$hostArg`" ``") -ForegroundColor Gray
        Write-Host ("      --validation cloudflare --cloudflareapitoken <token> ``") -ForegroundColor Gray
        Write-Host ("      --store certificatestore --installation iis ``") -ForegroundColor Gray
        Write-Host ("      --emailaddress ops@$($p.Zone) --accepttos --closeonfinish --verbose") -ForegroundColor Gray
        Write-Host ''
    }
    Write-Host '  Azure DNS / GoDaddy variants and the on-prem CNAME-delegation pattern are in Runbook 02.' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '  All host names are already covered by valid certificates. Nothing to generate.' -ForegroundColor Green
}
Write-Host ''
Write-Host '   https://github.com/xphox2/Cert-Man-Windows  (Runbook 02 = wildcard issuance)' -ForegroundColor DarkGray
Write-Host ''
