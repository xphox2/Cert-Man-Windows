<#
.SYNOPSIS
    Inventory certificates in LocalMachine\My and show what references each one — the
    pre-flight check for replacing an existing cert (Runbook 08).

.DESCRIPTION
    For every certificate in the machine Personal store, reports Subject, Issuer (and a
    friendly source label: Self-signed / Let's Encrypt / other vendor), expiry, days left,
    thumbprint, and WHERE it is referenced:
      - IIS site HTTPS bindings
      - HTTP.SYS bindings (netsh http show sslcert)
      - the RDP listener

    The "ReferencedBy" column is the safety check before you migrate or delete anything:
    a thumbprint shared by multiple bindings/services must not be removed until each
    reference is moved to the new Let's Encrypt cert.

.PARAMETER ExpiringInDays
    If set, only list certs expiring within this many days (e.g. -ExpiringInDays 60 to find
    vendor certs due for replacement).

.EXAMPLE
    .\Inventory-Certs.ps1

.EXAMPLE
    .\Inventory-Certs.ps1 -ExpiringInDays 60

.NOTES
    Run as Administrator. Read-only — changes nothing. See Runbook 08.
#>
[CmdletBinding()]
param(
    [int]$ExpiringInDays
)

$ErrorActionPreference = 'Stop'

# --- Reference collectors ---------------------------------------------------
function Get-IisRefs {
    $map = @{}
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($site in Get-Website) {
            foreach ($b in (Get-WebBinding -Name $site.Name -Protocol https -ErrorAction SilentlyContinue)) {
                $hash = ($b.certificateHash -as [string])
                if ($hash) {
                    $key = $hash.ToUpper()
                    $ref = "IIS '$($site.Name)' [$($b.bindingInformation)]"
                    if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.Generic.List[string] }
                    $map[$key].Add($ref)
                }
            }
        }
    } catch { Write-Verbose "IIS not available: $($_.Exception.Message)" }
    return $map
}

function Get-HttpSysRefs {
    $map = @{}
    try {
        $out = & netsh http show sslcert 2>$null
        $current = $null
        foreach ($line in $out) {
            if ($line -match '^\s*(IP:port|Hostname:port)\s*:\s*(.+?)\s*$') { $current = $matches[2] }
            elseif ($line -match '^\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)\s*$') {
                $key = $matches[1].ToUpper()
                $ref = "HTTP.SYS [$current]"
                if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.Generic.List[string] }
                $map[$key].Add($ref)
            }
        }
    } catch { Write-Verbose "netsh sslcert read failed: $($_.Exception.Message)" }
    return $map
}

function Get-RdpRef {
    $map = @{}
    try {
        $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $val = (Get-ItemProperty -Path $p -Name SSLCertificateSHA1Hash -ErrorAction Stop).SSLCertificateSHA1Hash
        if ($val) {
            $hex = ([byte[]]$val | ForEach-Object { $_.ToString('X2') }) -join ''
            $map[$hex.ToUpper()] = [System.Collections.Generic.List[string]]@('RDP listener (RDP-Tcp)')
        }
    } catch { Write-Verbose "RDP cert not set or unreadable: $($_.Exception.Message)" }
    return $map
}

function Get-SourceLabel {
    param($cert)
    if ($cert.Subject -eq $cert.Issuer) { return 'Self-signed / default' }
    if ($cert.Issuer -match "Let's Encrypt|\bR1[0-9]\b|\bE[0-9]\b") { return "Let's Encrypt" }
    if ($cert.Issuer -match 'GoDaddy')   { return 'GoDaddy' }
    if ($cert.Issuer -match 'DigiCert')  { return 'DigiCert' }
    if ($cert.Issuer -match 'Sectigo|COMODO') { return 'Sectigo' }
    if ($cert.Issuer -match 'Entrust')   { return 'Entrust' }
    if ($cert.Issuer -match 'GlobalSign'){ return 'GlobalSign' }
    # fall back to issuer CN
    if ($cert.Issuer -match 'CN=([^,]+)') { return $matches[1] }
    return 'Other CA'
}

# --- Merge reference maps ---------------------------------------------------
$refs = @{}
foreach ($m in @((Get-IisRefs), (Get-HttpSysRefs), (Get-RdpRef))) {
    foreach ($k in $m.Keys) {
        if (-not $refs.ContainsKey($k)) { $refs[$k] = New-Object System.Collections.Generic.List[string] }
        $m[$k] | ForEach-Object { $refs[$k].Add($_) }
    }
}

# --- Build the report -------------------------------------------------------
$now = Get-Date
# Scan both stores: manually-imported certs live in My; win-acme's IIS-installed certs live in WebHosting.
$rows = foreach ($c in (Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\WebHosting)) {
    $days = [int][math]::Floor(($c.NotAfter - $now).TotalDays)
    if ($PSBoundParameters.ContainsKey('ExpiringInDays') -and $days -gt $ExpiringInDays) { continue }
    $tp = $c.Thumbprint.ToUpper()
    $cn = if ($c.Subject -match 'CN=([^,]+)') { $matches[1] } else { $c.Subject }
    [PSCustomObject]@{
        Subject      = $cn
        Source       = Get-SourceLabel $c
        Store        = ($c.PSParentPath -split '\\')[-1]
        NotAfter     = $c.NotAfter.ToString('yyyy-MM-dd')
        DaysLeft     = $days
        Thumbprint   = $tp
        ReferencedBy = if ($refs.ContainsKey($tp)) { ($refs[$tp] | Select-Object -Unique) -join '; ' } else { '(unused)' }
    }
}

$rows | Sort-Object DaysLeft | Format-Table Subject, Source, Store, NotAfter, DaysLeft, ReferencedBy, Thumbprint -AutoSize -Wrap | Out-String | Write-Host

$bound = $rows | Where-Object { $_.ReferencedBy -ne '(unused)' }
Write-Host ("Certificates: {0} total, {1} actively bound." -f $rows.Count, $bound.Count) -ForegroundColor Cyan
Write-Host "Next: pick the cert to replace, follow Runbook 08, then remove the old one with Remove-OldCert.ps1." -ForegroundColor Yellow
