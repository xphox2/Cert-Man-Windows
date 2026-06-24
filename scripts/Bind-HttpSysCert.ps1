<#
.SYNOPSIS
    Post-renewal hook: (re)bind a renewed certificate to an HTTP.SYS endpoint via netsh.

.DESCRIPTION
    For custom services that terminate TLS through HTTP.SYS (not IIS) — self-hosted .NET/Kestrel-on-HTTP.SYS
    apps, WinRM-over-HTTPS, custom APIs. Deletes any existing sslcert binding for the given
    ipport (or hostnameport) and adds a fresh one for the new thumbprint.

    Wire into win-acme:
      --store certificatestore --installation script `
      --script "...\Bind-HttpSysCert.ps1" `
      --scriptparameters "-NewThumbprint {CertThumbprint} -IpPort 0.0.0.0:8443"

.PARAMETER NewThumbprint
    Thumbprint of the renewed cert in LocalMachine\My.

.PARAMETER IpPort
    IP:port to bind (e.g. 0.0.0.0:8443). Use this OR -HostnamePort.

.PARAMETER HostnamePort
    hostname:port for SNI bindings (e.g. api.example.com:443). Use this OR -IpPort.

.PARAMETER AppId
    GUID identifying the owning application. A stable random GUID is fine; reuse the same one
    across renewals. Defaults to a fixed handbook GUID if omitted.

.PARAMETER RestartService
    Optional name of a service to restart after binding (if it caches the cert at startup).

.PARAMETER LogPath
    Append-only log. Default C:\logs\httpsys-cert-deploy.log.

.EXAMPLE
    .\Bind-HttpSysCert.ps1 -NewThumbprint ABC123... -IpPort 0.0.0.0:8443 -RestartService MyApiSvc

.EXAMPLE
    .\Bind-HttpSysCert.ps1 -NewThumbprint ABC123... -HostnamePort api.example.com:443

.NOTES
    Run as Administrator. Reference:
    https://learn.microsoft.com/windows-server/administration/windows-commands/netsh-http
#>
[CmdletBinding(DefaultParameterSetName = 'IpPort')]
param(
    [Parameter(Mandatory)][string]$NewThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'IpPort')][string]$IpPort,
    [Parameter(Mandatory, ParameterSetName = 'HostnamePort')][string]$HostnamePort,
    [string]$AppId = '{6b2d8f4a-1c3e-4a9b-9d7c-5e0f1a2b3c4d}',
    [string]$RestartService,
    [string]$LogPath = 'C:\logs\httpsys-cert-deploy.log'
)

$ErrorActionPreference = 'Stop'
function Write-Log { param($m, $level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $m
    New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    Add-Content -Path $LogPath -Value $line; Write-Host $line
}

try {
    $hash = ($NewThumbprint -replace '\s', '').ToLower()
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint.ToLower() -eq $hash }
    if (-not $cert) { throw "Certificate $NewThumbprint not found in LocalMachine\My." }
    Write-Log "Target cert: $($cert.Subject)  expires $($cert.NotAfter)"

    if ($PSCmdlet.ParameterSetName -eq 'IpPort') {
        $selector = "ipport=$IpPort"; $target = $IpPort
    } else {
        $selector = "hostnameport=$HostnamePort"; $target = $HostnamePort
    }

    Write-Log "Removing any existing binding for $target ..."
    & netsh http delete sslcert $selector 2>$null | Out-Null   # ok if none exists

    Write-Log "Adding sslcert binding for $target with thumbprint $hash ..."
    $add = & netsh http add sslcert $selector certhash=$hash appid="$AppId" certstorename=MY
    if ($LASTEXITCODE -ne 0) { throw "netsh add sslcert failed: $add" }

    Write-Log 'Current binding:'
    & netsh http show sslcert $selector | ForEach-Object { Write-Log "  $_" }

    if ($RestartService) {
        Write-Log "Restarting service '$RestartService' ..."
        Restart-Service -Name $RestartService -Force
    }

    Write-Log 'HTTP.SYS certificate binding completed successfully.' 'SUCCESS'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
