<#
.SYNOPSIS
    win-acme DNS-01 "create" hook for ONE-TIME manual validation. Displays the TXT record to
    add, then waits until it is visible on authoritative + public DNS before returning - so
    win-acme never asks Let's Encrypt to validate prematurely (which would invalidate the
    token and force you to edit DNS again).

.DESCRIPTION
    Wired automatically by generate-cert.ps1 (DNS option 7). win-acme runs this and BLOCKS
    until it exits 0:

        powershell -File Wait-AcmeDnsRecord.ps1 -RecordName {RecordName} -Token {Token} ...

    Add the displayed TXT record ONCE. This polls the zone's authoritative nameservers (what
    Let's Encrypt itself queries) plus several public resolvers (NOT the local cache, which can
    be stale), and only continues once the record is verified. It does not fail early, so the
    token never changes and you never have to re-edit DNS.

.NOTES
    Part of Cert-Man-Windows. Manual DNS, no provider API required.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecordName,
    [Parameter(Mandatory)][string]$Token,
    [int]$WaitMinutes  = 60,   # how long between "still waiting" reminders
    [int]$PollSeconds  = 20,   # delay between checks
    [int]$QuorumPublic = 3,    # public resolvers that must agree when authoritative is unknown
    [int]$MaxHours     = 12    # absolute ceiling (effectively "wait as long as it takes")
)

$ErrorActionPreference = 'SilentlyContinue'
$Resolvers = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '208.67.222.222')

function Get-Txt {
    param($Server, $Name)
    try {
        $r = Resolve-DnsName -Name $Name -Type TXT -Server $Server -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
        @($r | Where-Object { $_.Type -eq 'TXT' } | ForEach-Object { ($_.Strings -join '') })
    } catch { @() }
}
function Get-Auth {
    # Walk up from the record name to the first label that has NS records (= the zone apex),
    # then resolve those nameservers to IPs. This is what Let's Encrypt will query.
    param($Name)
    $labels = $Name.Split('.')
    for ($i = 0; $i -lt $labels.Count - 1; $i++) {
        $zone = ($labels[$i..($labels.Count - 1)] -join '.')
        $ns = @(Resolve-DnsName -Name $zone -Type NS -Server 1.1.1.1 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'NS' } | ForEach-Object { $_.NameHost })
        if ($ns.Count) {
            $ips = @()
            foreach ($h in $ns) { $ips += @(Resolve-DnsName -Name $h -Type A -Server 1.1.1.1 -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) }
            return [pscustomobject]@{ Zone = $zone; Ips = @($ips | Select-Object -Unique) }
        }
    }
    return [pscustomobject]@{ Zone = $null; Ips = @() }
}

$bar = ('=' * 72)
Write-Host ''
Write-Host $bar -ForegroundColor Cyan
Write-Host '  ONE-TIME DNS VALIDATION - create THIS TXT record at your DNS provider:' -ForegroundColor Cyan
Write-Host $bar -ForegroundColor Cyan
Write-Host ''
Write-Host '    Type : TXT' -ForegroundColor White
Write-Host ('    Name : {0}' -f $RecordName) -ForegroundColor Yellow
Write-Host ('    Value: {0}' -f $Token) -ForegroundColor Yellow
Write-Host '    TTL  : 60 (or the lowest your provider allows)' -ForegroundColor White
Write-Host ''
Write-Host '  Add it ONCE. This keeps checking authoritative + public DNS and continues only once' -ForegroundColor Gray
Write-Host '  the record is visible, so the request will not fail and the value never changes.' -ForegroundColor Gray
Write-Host ''

# Persist the record to a file too, in case the console scrolls.
$todo = Join-Path $env:TEMP 'MANUAL-DNS-TODO.txt'
@("Create TXT record:", "  Name : $RecordName", "  Value: $Token") | Set-Content -Path $todo -Encoding utf8

$auth = Get-Auth $RecordName
if ($auth.Zone) { Write-Host ('  Authoritative zone: {0} ({1} nameserver IP(s))' -f $auth.Zone, $auth.Ips.Count) -ForegroundColor DarkGray }
else { Write-Host '  Authoritative nameservers not found yet; using public resolvers for now.' -ForegroundColor DarkGray }
Write-Host ''

$stopAt = (Get-Date).AddHours($MaxHours)
$warnAt = (Get-Date).AddMinutes($WaitMinutes)
$try = 0
while ((Get-Date) -lt $stopAt) {
    $try++
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    if (-not $auth.Ips.Count) { $auth = Get-Auth $RecordName }   # delegation may have just settled

    # Authoritative check - exactly what Let's Encrypt resolves, so it is the real gate.
    $authResp = 0; $authHit = 0
    foreach ($ip in $auth.Ips) {
        $vals = Get-Txt $ip $RecordName
        if ($vals.Count) { $authResp++; if ($vals -contains $Token) { $authHit++ } }
    }
    $authOk = ($auth.Ips.Count -gt 0) -and ($authResp -gt 0) -and ($authHit -eq $authResp)

    # Public resolver check - online (non-local) DNS, which can lag due to caching.
    $pubHit = 0
    foreach ($s in $Resolvers) { if ((Get-Txt $s $RecordName) -contains $Token) { $pubHit++ } }
    $pubOk = $pubHit -ge $QuorumPublic

    $aTxt = if ($auth.Ips.Count) { ('auth {0}/{1}' -f $authHit, $auth.Ips.Count) } else { 'auth n/a' }
    Write-Host ('  [{0}] try {1,-3} {2}; public {3}/{4} see it...' -f (Get-Date -Format 'HH:mm:ss'), $try, $aTxt, $pubHit, $Resolvers.Count) -ForegroundColor DarkGray

    # Proceed when authoritative agrees (preferred). If NS could not be found, fall back to a public quorum.
    if ($authOk -or ((-not $auth.Ips.Count) -and $pubOk)) {
        Write-Host ''
        Write-Host '  DNS record verified across DNS - continuing with the certificate request.' -ForegroundColor Green
        Start-Sleep -Seconds 5   # let everything settle so Let's Encrypt's own lookup agrees
        Remove-Item $todo -ErrorAction SilentlyContinue
        exit 0
    }

    if ((Get-Date) -gt $warnAt) {
        Write-Host ('  Still not visible after {0} min - NOT failing, still waiting.' -f $WaitMinutes) -ForegroundColor Yellow
        Write-Host ('  Re-check the record (exact Name/Value above, TXT type, no extra quotes). Saved to: {0}' -f $todo) -ForegroundColor Yellow
        $warnAt = (Get-Date).AddMinutes($WaitMinutes)
    }
    Start-Sleep -Seconds $PollSeconds
}

Write-Host ''
Write-Host ('  Gave up after {0}h waiting for DNS. Re-run the issuance once the record is in place.' -f $MaxHours) -ForegroundColor Red
exit 1
