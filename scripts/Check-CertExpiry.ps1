<#
.SYNOPSIS
    Independent TLS certificate expiry monitor (Layer 1 of Runbook 06).

.DESCRIPTION
    Connects to each host:port, performs a TLS handshake, reads the SERVED leaf certificate,
    and reports days-to-expiry. Because it inspects what is actually on the wire (not the local
    store or a renewal tool's log), it catches "renewed but never re-bound" failures.

    Emits a human table, a Prometheus-style line per target (for scraping), sets a non-zero
    exit code if anything breaches the critical threshold, and can email on warn/critical.

    NOTE: Does a DIRECT TLS handshake. Endpoints requiring STARTTLS (e.g. SMTP:25, some LDAP)
    are not supported here — monitor those with a protocol-aware probe instead.

.PARAMETER Targets
    One or more 'host:port' (port defaults to 443 if omitted, e.g. 'www.example.com').

.PARAMETER TargetsFile
    Path to a text file of 'host:port' lines (# comments allowed). Combined with -Targets.

.PARAMETER WarnDays
    Days-to-expiry at/below which a target is WARN. Default 15.

.PARAMETER CriticalDays
    Days-to-expiry at/below which a target is CRITICAL (drives exit code 2). Default 7.

.PARAMETER SmtpServer / -To / -From
    If set, email a summary when any target is WARN or CRITICAL.

.PARAMETER RegisterTask
    Register this script as a daily Scheduled Task (runs as SYSTEM) with the supplied params.

.EXAMPLE
    .\Check-CertExpiry.ps1 -Targets www.example.com,rdp.example.com:3389 -WarnDays 15 -CriticalDays 7

.EXAMPLE
    .\Check-CertExpiry.ps1 -TargetsFile .\monitored-hosts.txt -SmtpServer smtp.example.com -To ops@example.com -RegisterTask

.NOTES
    Exit codes: 0 = all OK, 1 = at least one WARN (no CRITICAL), 2 = at least one CRITICAL/unreachable.
#>
[CmdletBinding()]
param(
    [string[]]$Targets,
    [string]$TargetsFile,
    [int]$WarnDays = 15,
    [int]$CriticalDays = 7,
    [int]$TimeoutSeconds = 10,
    [string]$SmtpServer,
    [string]$To,
    [string]$From = "certmon@$env:COMPUTERNAME",
    [switch]$RegisterTask
)

$ErrorActionPreference = 'Stop'

# --- Optional: register as a daily scheduled task and exit ------------------
if ($RegisterTask) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Targets)      { $argList += @('-Targets', ($Targets -join ',')) }
    if ($TargetsFile)  { $argList += @('-TargetsFile', "`"$TargetsFile`"") }
    $argList += @('-WarnDays', $WarnDays, '-CriticalDays', $CriticalDays)
    if ($SmtpServer)   { $argList += @('-SmtpServer', $SmtpServer, '-To', $To, '-From', $From) }
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
    $trigger = New-ScheduledTaskTrigger -Daily -At 07:00
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'SSL-Cert-Expiry-Monitor' -Action $action -Trigger $trigger `
        -Principal $principal -Description 'Independent TLS cert expiry monitor (handbook Runbook 06)' -Force | Out-Null
    Write-Host 'Registered scheduled task: SSL-Cert-Expiry-Monitor (daily 07:00).' -ForegroundColor Green
    return
}

# --- Build target list ------------------------------------------------------
$list = New-Object System.Collections.Generic.List[string]
if ($Targets) { $Targets | ForEach-Object { $list.Add($_.Trim()) } }
if ($TargetsFile) {
    if (-not (Test-Path $TargetsFile)) { throw "TargetsFile not found: $TargetsFile" }
    Get-Content $TargetsFile | ForEach-Object {
        $t = $_.Trim(); if ($t -and -not $t.StartsWith('#')) { $list.Add($t) }
    }
}
if ($list.Count -eq 0) { throw 'No targets. Supply -Targets and/or -TargetsFile.' }

# --- Probe one target -------------------------------------------------------
function Get-ServedCert {
    param([string]$HostName, [int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw "connect timeout after ${TimeoutSeconds}s"
        }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false,
            ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))   # accept any; we only read the cert
        $ssl.AuthenticateAsClient($HostName)
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
    } finally { $tcp.Close() }
}

# --- Run --------------------------------------------------------------------
$results = foreach ($entry in $list) {
    $parts = $entry -split ':'
    $h = $parts[0]; $p = if ($parts.Count -ge 2) { [int]$parts[1] } else { 443 }
    $row = [ordered]@{ Target = "$h`:$p"; Subject = ''; NotAfter = $null; Days = $null; Status = '' }
    try {
        $cert = Get-ServedCert -HostName $h -Port $p
        $days = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        $row.Subject  = $cert.Subject
        $row.NotAfter = $cert.NotAfter
        $row.Days     = $days
        $row.Status   = if ($days -le $CriticalDays) { 'CRITICAL' }
                        elseif ($days -le $WarnDays)  { 'WARN' } else { 'OK' }
    } catch {
        $row.Status = 'UNREACHABLE'; $row.Subject = $_.Exception.Message
    }
    [PSCustomObject]$row
}

# --- Output -----------------------------------------------------------------
$results | Format-Table Target, Days, Status, NotAfter, Subject -AutoSize | Out-String | Write-Host

Write-Host '--- Prometheus ---'
foreach ($r in $results) {
    $d = if ($null -ne $r.Days) { $r.Days } else { -1 }
    Write-Host ("ssl_cert_days_to_expiry{{target=`"{0}`",status=`"{1}`"}} {2}" -f $r.Target, $r.Status, $d)
}

$bad = $results | Where-Object Status -in 'WARN', 'CRITICAL', 'UNREACHABLE'
if ($bad -and $SmtpServer -and $To) {
    $body = ($bad | Format-Table Target, Days, Status, NotAfter -AutoSize | Out-String)
    Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To `
        -Subject "[SSL MONITOR] $($bad.Count) certificate(s) need attention on $env:COMPUTERNAME" `
        -Body $body -ErrorAction SilentlyContinue
}

if ($results.Status -contains 'CRITICAL' -or $results.Status -contains 'UNREACHABLE') { exit 2 }
elseif ($results.Status -contains 'WARN') { exit 1 }
else { exit 0 }
