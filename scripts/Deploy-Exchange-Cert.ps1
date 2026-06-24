<#
.SYNOPSIS
    Post-renewal hook: enable a renewed certificate for Exchange Server services and restart them.

.DESCRIPTION
    Called by win-acme via --installation script, or run manually on the Exchange server.
    Uses Enable-ExchangeCertificate to assign the new cert to the chosen services
    (IIS/SMTP/IMAP/POP), then restarts the affected services so they pick it up.

    Wire into win-acme:
      --store certificatestore --installation script `
      --script "...\Deploy-Exchange-Cert.ps1" `
      --scriptparameters "-NewThumbprint {CertThumbprint} -Services IIS,SMTP"

.PARAMETER NewThumbprint
    Thumbprint of the renewed cert in LocalMachine\My.

.PARAMETER Services
    Comma-separated Exchange services to enable: any of IIS, SMTP, IMAP, POP, UM, UMCallRouter.
    Default 'IIS,SMTP'.

.PARAMETER LogPath
    Append-only log. Default C:\logs\exchange-cert-deploy.log.

.EXAMPLE
    .\Deploy-Exchange-Cert.ps1 -NewThumbprint ABC123... -Services IIS,SMTP,IMAP,POP

.NOTES
    Must run where the Exchange Management Shell / snap-in is available, as an account with
    Exchange admin rights. Assigning SMTP may prompt about replacing the default cert; -Force handles it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NewThumbprint,
    [string]$Services = 'IIS,SMTP',
    [string]$LogPath = 'C:\logs\exchange-cert-deploy.log'
)

$ErrorActionPreference = 'Stop'
function Write-Log { param($m, $level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $m
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    Add-Content -Path $LogPath -Value $line; Write-Host $line
}

try {
    Write-Log "Starting Exchange certificate deployment (services: $Services)."
    $NewThumbprint = $NewThumbprint -replace '\s', ''

    # Load Exchange tooling if not already present
    if (-not (Get-Command Enable-ExchangeCertificate -ErrorAction SilentlyContinue)) {
        Write-Log 'Loading Exchange Management snap-in...'
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
    }

    $cert = Get-ExchangeCertificate -Thumbprint $NewThumbprint -ErrorAction Stop
    Write-Log "Target cert: $($cert.Subject)  expires $($cert.NotAfter)"

    Write-Log "Enabling cert for services: $Services ..."
    Enable-ExchangeCertificate -Thumbprint $NewThumbprint -Services $Services -Force -Confirm:$false

    # Restart only the services relevant to the assignment
    $svcMap = @{
        IIS  = @('W3SVC', 'WAS')
        SMTP = @('MSExchangeTransport', 'MSExchangeFrontEndTransport')
        IMAP = @('MSExchangeIMAP4', 'MSExchangeIMAP4BE')
        POP  = @('MSExchangePOP3', 'MSExchangePOP3BE')
    }
    $toRestart = @()
    foreach ($s in ($Services -split ',').Trim()) { if ($svcMap[$s]) { $toRestart += $svcMap[$s] } }
    foreach ($svc in ($toRestart | Select-Object -Unique)) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            Write-Log "Restarting $svc ..."
            Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log 'Exchange certificate deployment completed successfully.' 'SUCCESS'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
