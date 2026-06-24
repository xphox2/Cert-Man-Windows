<#
.SYNOPSIS
    Post-renewal hook: bind a renewed certificate to RDP (Remote Desktop) and restart the service.

.DESCRIPTION
    Called automatically by win-acme via --installation script, or run manually.
    RDP selects its certificate by SHA-1 thumbprint stored in the registry under RDP-Tcp.
    This script (optionally imports a PFX, then) sets that thumbprint and restarts TermService.

    Wire into win-acme:
      --store certificatestore --installation script `
      --script "...\Deploy-RDP-Cert.ps1" `
      --scriptparameters "-NewThumbprint {CertThumbprint}"

    If you store as a PFX instead, pass:
      --scriptparameters "-PfxFile {CacheFile} -PfxPassword {CachePassword}"

.PARAMETER NewThumbprint
    Thumbprint of the renewed cert (already in LocalMachine\My). Preferred when using
    --store certificatestore.

.PARAMETER PfxFile
    Path to a PFX to import into LocalMachine\My first (when using --store pfxfile).

.PARAMETER PfxPassword
    Password for -PfxFile.

.PARAMETER LogPath
    Append-only log file. Default C:\logs\rdp-cert-deploy.log.

.EXAMPLE
    .\Deploy-RDP-Cert.ps1 -NewThumbprint ABC123...

.NOTES
    Run as Administrator/SYSTEM. Reference:
    https://learn.microsoft.com/windows-server/remote/remote-desktop-services/
#>
[CmdletBinding(DefaultParameterSetName = 'Thumbprint')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Thumbprint')]
    [string]$NewThumbprint,

    [Parameter(Mandatory, ParameterSetName = 'Pfx')]
    [string]$PfxFile,
    [Parameter(ParameterSetName = 'Pfx')]
    [string]$PfxPassword,

    [string]$LogPath = 'C:\logs\rdp-cert-deploy.log'
)

$ErrorActionPreference = 'Stop'
function Write-Log { param($m, $level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $m
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    Add-Content -Path $LogPath -Value $line; Write-Host $line
}

try {
    Write-Log 'Starting RDP certificate deployment.'

    if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
        Write-Log "Importing PFX $PfxFile into LocalMachine\My ..."
        $sec = if ($PfxPassword) { ConvertTo-SecureString $PfxPassword -AsPlainText -Force } else { (New-Object System.Security.SecureString) }
        $imported = Import-PfxCertificate -FilePath $PfxFile -CertStoreLocation Cert:\LocalMachine\My -Password $sec
        $NewThumbprint = $imported.Thumbprint
    }

    $NewThumbprint = $NewThumbprint -replace '\s', ''
    $cert = Get-Item "Cert:\LocalMachine\My\$NewThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Certificate $NewThumbprint not found in LocalMachine\My." }
    Write-Log "Target cert: $($cert.Subject)  expires $($cert.NotAfter)"

    # Bind to RDP via WMI (sets SSLCertificateSHA1Hash on the RDP-Tcp listener)
    Write-Log "Binding RDP listener to thumbprint $NewThumbprint ..."
    $ts = Get-WmiObject -Class 'Win32_TSGeneralSetting' -Namespace 'root\cimv2\TerminalServices' -Filter "TerminalName='RDP-Tcp'"
    $ts.SSLCertificateSHA1Hash = $NewThumbprint
    $ts.Put() | Out-Null

    # Ensure the RDP service account can read the private key
    Write-Log 'Granting NETWORK SERVICE read on the private key...'
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($rsa -and $rsa.Key.UniqueName) {
        $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $rsa.Key.UniqueName
        if (Test-Path $keyPath) {
            $acl = Get-Acl $keyPath
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NETWORK SERVICE', 'Read', 'Allow')))
            Set-Acl -Path $keyPath -AclObject $acl
        }
    }

    Write-Log 'Restarting Remote Desktop Services (TermService)...'
    Restart-Service -Name TermService -Force

    Write-Log 'RDP certificate deployment completed successfully.' 'SUCCESS'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
