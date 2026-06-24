<#
.SYNOPSIS
    Posh-ACME issuance/renewal driver for two contexts:
      (A) Windows server  — renew local certs and run a post-renewal deploy hook (Runbook 03).
      (B) Azure Automation — issue/renew via Azure DNS and upload to Key Vault (Runbook 05).

.DESCRIPTION
    Posh-ACME does NOT create its own scheduled task, so this driver provides the renewal loop
    plus optional Task Scheduler registration. It only renews certs inside their renewal window
    (Submit-Renewal is a no-op otherwise), so it is safe to run daily.

.PARAMETER Mode
    'Server' (default) or 'Azure'.

.PARAMETER Domains
    Domain(s) for the cert, e.g. '*.example.com','example.com'. Required for first issuance.

.PARAMETER Plugin
    Posh-ACME DNS plugin name (e.g. Azure, Cloudflare). Required for first issuance.

.PARAMETER PluginArgs
    Hashtable of plugin args (see Posh-ACME plugin docs). For Azure Automation, use
    @{ AZSubscriptionId='<sub>'; AZUseIMDS=$true } to authenticate with the managed identity.

.PARAMETER Contact
    ACME account contact email.

.PARAMETER Staging
    Use the Let's Encrypt STAGING directory (LE_STAGE). Default for safety; use -Production to go live.

.PARAMETER DeployHook
    (Server mode) Path to a deploy script run after a successful renewal, receiving
    -NewThumbprint and -PfxFile/-PfxPassword (e.g. Deploy-RDP-Cert.ps1 / Bind-HttpSysCert.ps1).

.PARAMETER VaultName / -CertName
    (Azure mode) Key Vault and certificate name to import the renewed PFX into.

.PARAMETER RegisterTask
    (Server mode) Register this script as a daily Scheduled Task (SYSTEM).

.EXAMPLE
    # Server, first issuance via Cloudflare, then auto-deploy to RDP, schedule daily:
    .\Renew-PoshACME.ps1 -Domains rdp.example.com -Plugin Cloudflare `
        -PluginArgs @{ CFToken=(Read-Host -AsSecureString) } -Contact ops@example.com `
        -DeployHook .\Deploy-RDP-Cert.ps1 -Production -RegisterTask

.EXAMPLE
    # Azure Automation runbook body (managed identity):
    .\Renew-PoshACME.ps1 -Mode Azure -Domains '*.example.com','example.com' -Plugin Azure `
        -PluginArgs @{ AZSubscriptionId='<sub>'; AZUseIMDS=$true } `
        -Contact ops@example.com -VaultName myvault -CertName example-com -Production

.NOTES
    Requires the Posh-ACME module (and Az.* modules for Azure mode). See Runbooks 03 and 05.
#>
[CmdletBinding()]
param(
    [ValidateSet('Server', 'Azure')][string]$Mode = 'Server',
    [string[]]$Domains,
    [string]$Plugin,
    [hashtable]$PluginArgs,
    [string]$Contact,
    [switch]$Staging,
    [switch]$Production,
    [string]$DeployHook,
    [string]$VaultName,
    [string]$CertName,
    [switch]$RegisterTask,
    [string]$LogPath = 'C:\logs\posh-acme-renew.log'
)

$ErrorActionPreference = 'Stop'
function Write-Log { param($m, $level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $m
    try { New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
          Add-Content -Path $LogPath -Value $line } catch {}
    Write-Host $line
}

# --- Optional: register daily task and exit (Server mode) -------------------
if ($RegisterTask) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
           '-Mode', $Mode)
    if ($Domains)    { $a += @('-Domains', ($Domains -join ',')) }
    if ($Plugin)     { $a += @('-Plugin', $Plugin) }
    if ($Contact)    { $a += @('-Contact', $Contact) }
    if ($DeployHook) { $a += @('-DeployHook', "`"$DeployHook`"") }
    if ($Production) { $a += '-Production' } else { $a += '-Staging' }
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($a -join ' ')
    $trigger = New-ScheduledTaskTrigger -Daily -At 03:00
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Posh-ACME-Renewal' -Action $action -Trigger $trigger `
        -Principal $principal -Description 'Posh-ACME renewal driver (handbook Runbook 03/05)' -Force | Out-Null
    Write-Log 'Registered scheduled task: Posh-ACME-Renewal (daily 03:00).'
    return
}

try {
    Import-Module Posh-ACME -ErrorAction Stop
    $server = if ($Production) { 'LE_PROD' } else { 'LE_STAGE' }
    Write-Log "Mode=$Mode  ACME server=$server"
    Set-PAServer -DirectoryUrl $server

    if ($Mode -eq 'Azure') {
        Write-Log 'Authenticating to Azure with managed identity...'
        Import-Module Az.Accounts, Az.KeyVault -ErrorAction Stop
        Connect-AzAccount -Identity | Out-Null
    }

    # Decide: first issuance vs renewal of existing order
    $existing = Get-PACertificate -ErrorAction SilentlyContinue | Where-Object {
        $Domains -and ($_.AllSANs -contains $Domains[0] -or $_.Subject -like "*$($Domains[0])*")
    }

    if (-not $existing) {
        if (-not ($Domains -and $Plugin -and $Contact)) {
            throw 'First issuance requires -Domains, -Plugin, -PluginArgs, and -Contact.'
        }
        Write-Log "Issuing new certificate for: $($Domains -join ', ') via plugin $Plugin"
        $cert = New-PACertificate -Domain $Domains -AcceptTOS -Contact $Contact `
            -Plugin $Plugin -PluginArgs $PluginArgs -Force
        $renewed = $true
    } else {
        Write-Log "Submitting renewal (no-op unless within renewal window) for $($existing.Subject)"
        $before = $existing.NotAfter
        $cert = Submit-Renewal -MainDomain $existing.MainDomain
        $renewed = ($cert -and $cert.NotAfter -gt $before)
        if (-not $cert) { $cert = Get-PACertificate -MainDomain $existing.MainDomain }
    }

    if (-not $renewed) { Write-Log 'No renewal was due. Nothing to deploy.'; exit 0 }
    Write-Log "Certificate ready: $($cert.Subject)  expires $($cert.NotAfter)"

    # --- Post actions -------------------------------------------------------
    if ($Mode -eq 'Azure') {
        Write-Log "Importing renewed PFX into Key Vault '$VaultName' as '$CertName'..."
        $pw = ConvertTo-SecureString $cert.PfxPass -AsPlainText -Force
        Import-AzKeyVaultCertificate -VaultName $VaultName -Name $CertName `
            -FilePath $cert.PfxFullChain -Password $pw | Out-Null
        Write-Log 'Key Vault import complete. App Service will auto-sync within 24h.'
    }
    elseif ($DeployHook) {
        Write-Log "Running deploy hook: $DeployHook"
        & $DeployHook -NewThumbprint $cert.Thumbprint -PfxFile $cert.PfxFullChain -PfxPassword $cert.PfxPass
        if ($LASTEXITCODE -ne 0) { throw "Deploy hook exited with code $LASTEXITCODE" }
    }

    Write-Log 'Posh-ACME renewal driver completed successfully.' 'SUCCESS'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
