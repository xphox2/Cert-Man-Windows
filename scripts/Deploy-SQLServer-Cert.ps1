<#
.SYNOPSIS
    Post-renewal hook: bind a renewed certificate to a SQL Server instance for TLS, grant the
    SQL service account read on the private key, and restart the instance.

.DESCRIPTION
    Called by win-acme via --installation script, or run manually. SQL Server reads its TLS
    certificate thumbprint from the registry under the instance's SuperSocketNetLib key and
    requires the SQL service account to have read access to the cert's private key.

    Wire into win-acme:
      --store certificatestore --installation script `
      --script "...\Deploy-SQLServer-Cert.ps1" `
      --scriptparameters "-NewThumbprint {CertThumbprint} -InstanceName MSSQLSERVER"

.PARAMETER NewThumbprint
    Thumbprint of the renewed cert in LocalMachine\My.

.PARAMETER InstanceName
    SQL instance. 'MSSQLSERVER' for default instance (default), or the named instance.

.PARAMETER ForceEncryption
    Also set ForceEncryption = 1 for the instance.

.PARAMETER LogPath
    Append-only log. Default C:\logs\sql-cert-deploy.log.

.EXAMPLE
    .\Deploy-SQLServer-Cert.ps1 -NewThumbprint ABC123... -InstanceName MSSQLSERVER -ForceEncryption

.NOTES
    Run as Administrator. The cert CN/SAN must match the FQDN clients use to connect.
    Reference: https://learn.microsoft.com/sql/database-engine/configure-windows/configure-sql-server-encryption
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NewThumbprint,
    [string]$InstanceName = 'MSSQLSERVER',
    [switch]$ForceEncryption,
    [string]$LogPath = 'C:\logs\sql-cert-deploy.log'
)

$ErrorActionPreference = 'Stop'
function Write-Log { param($m, $level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $m
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    Add-Content -Path $LogPath -Value $line; Write-Host $line
}

try {
    Write-Log "Starting SQL Server certificate deployment for instance '$InstanceName'."
    $NewThumbprint = ($NewThumbprint -replace '\s', '').ToLower()

    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint.ToLower() -eq $NewThumbprint }
    if (-not $cert) { throw "Certificate $NewThumbprint not found in LocalMachine\My." }
    Write-Log "Target cert: $($cert.Subject)  expires $($cert.NotAfter)"

    # --- Grant SQL service account read on the private key ------------------
    $svcName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
    if (-not $svc) { throw "SQL service '$svcName' not found." }
    $svcAccount = $svc.StartName
    Write-Log "SQL service account: $svcAccount"

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($rsa -and $rsa.Key.UniqueName) {
        $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $rsa.Key.UniqueName
        if (Test-Path $keyPath) {
            $acl = Get-Acl $keyPath
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($svcAccount, 'Read', 'Allow')))
            Set-Acl -Path $keyPath -AclObject $acl
            Write-Log "Granted read on private key to $svcAccount."
        }
    } else {
        Write-Log 'Could not resolve private key file path; verify key permissions manually.' 'WARN'
    }

    # --- Point SQL at the cert thumbprint -----------------------------------
    # Locate the instance's SuperSocketNetLib registry key
    $instId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).$InstanceName
    if (-not $instId) { throw "Could not resolve registry instance id for '$InstanceName'." }
    $sslKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\MSSQLServer\SuperSocketNetLib"
    Set-ItemProperty -Path $sslKey -Name 'Certificate' -Value $NewThumbprint
    Write-Log "Set SuperSocketNetLib\Certificate = $NewThumbprint"
    if ($ForceEncryption) {
        Set-ItemProperty -Path $sslKey -Name 'ForceEncryption' -Value 1 -Type DWord
        Write-Log 'Set ForceEncryption = 1'
    }

    Write-Log "Restarting SQL service '$svcName' (and dependents)..."
    Restart-Service -Name $svcName -Force

    Write-Log 'SQL Server certificate deployment completed successfully.' 'SUCCESS'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
