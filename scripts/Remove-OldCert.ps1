<#
.SYNOPSIS
    Safely remove a superseded certificate from LocalMachine\My after migrating to Let's Encrypt
    (Runbook 08, Step 4).

.DESCRIPTION
    Before deleting, RE-CHECKS that the thumbprint is no longer referenced by any IIS HTTPS
    binding, HTTP.SYS binding, or the RDP listener. If it is still referenced, the script
    REFUSES to delete (unless -Force) and lists what still points at it — so you can never
    orphan a live binding. Backs up the cert first when -BackupPath is given.

.PARAMETER Thumbprint
    Thumbprint of the OLD certificate to remove (spaces/case ignored).

.PARAMETER BackupPath
    Folder to export the cert to before deletion (.cer always; .pfx too if the key is
    exportable). Strongly recommended so rollback is possible during the cutover window.

.PARAMETER DeleteKey
    Also delete the associated private key (default: leave it).

.PARAMETER Force
    Delete even if the thumbprint is still referenced. Dangerous — only if you know the
    reference is stale.

.EXAMPLE
    .\Remove-OldCert.ps1 -Thumbprint A1B2C3... -BackupPath C:\cert-backups

.NOTES
    Run as Administrator. Run Inventory-Certs.ps1 first. See Runbook 08.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Thumbprint,
    [string]$BackupPath,
    [switch]$DeleteKey,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$tp = ($Thumbprint -replace '\s', '').ToUpper()

# --- Find references (same logic as Inventory-Certs.ps1) --------------------
function Get-References {
    param([string]$Hash)
    $hits = New-Object System.Collections.Generic.List[string]
    # IIS
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($site in Get-Website) {
            foreach ($b in (Get-WebBinding -Name $site.Name -Protocol https -ErrorAction SilentlyContinue)) {
                if (($b.certificateHash -as [string]) -and ($b.certificateHash.ToUpper() -eq $Hash)) {
                    $hits.Add("IIS '$($site.Name)' [$($b.bindingInformation)]")
                }
            }
        }
    } catch {}
    # HTTP.SYS
    try {
        $out = & netsh http show sslcert 2>$null; $cur = $null
        foreach ($line in $out) {
            if ($line -match '^\s*(IP:port|Hostname:port)\s*:\s*(.+?)\s*$') { $cur = $matches[2] }
            elseif ($line -match '^\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)\s*$' -and $matches[1].ToUpper() -eq $Hash) {
                $hits.Add("HTTP.SYS [$cur]")
            }
        }
    } catch {}
    # RDP
    try {
        $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $val = (Get-ItemProperty -Path $p -Name SSLCertificateSHA1Hash -ErrorAction Stop).SSLCertificateSHA1Hash
        if ($val) {
            $hex = (([byte[]]$val | ForEach-Object { $_.ToString('X2') }) -join '').ToUpper()
            if ($hex -eq $Hash) { $hits.Add('RDP listener (RDP-Tcp)') }
        }
    } catch {}
    return $hits
}

$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint.ToUpper() -eq $tp }
if (-not $cert) { throw "No certificate with thumbprint $tp found in LocalMachine\My." }
Write-Host "Target: $($cert.Subject)" -ForegroundColor Cyan
Write-Host "  Issuer : $($cert.Issuer)"
Write-Host "  Expires: $($cert.NotAfter)"

# --- Safety gate ------------------------------------------------------------
$refs = Get-References -Hash $tp
if ($refs.Count -gt 0) {
    Write-Host "`nThis certificate is STILL REFERENCED by:" -ForegroundColor Red
    $refs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    if (-not $Force) {
        Write-Host "`nAborting. Move these references to the new Let's Encrypt cert first," -ForegroundColor Yellow
        Write-Host "or re-run with -Force if you are certain the reference is stale." -ForegroundColor Yellow
        exit 2
    }
    Write-Host "`n-Force specified: proceeding despite live references." -ForegroundColor Yellow
}

# --- Backup ----------------------------------------------------------------
if ($BackupPath) {
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    $stamp = $cert.NotAfter.ToString('yyyyMMdd')
    $cerOut = Join-Path $BackupPath "old-$($tp.Substring(0,12))-$stamp.cer"
    Export-Certificate -Cert $cert -FilePath $cerOut -Type CERT | Out-Null
    Write-Host "Backed up public cert -> $cerOut" -ForegroundColor Green
    try {
        $pfxOut = Join-Path $BackupPath "old-$($tp.Substring(0,12))-$stamp.pfx"
        $pw = ConvertTo-SecureString -String ([guid]::NewGuid().ToString('N')) -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfxOut -Password $pw | Out-Null
        Write-Host "Backed up PFX (random password - store it if you need rollback) -> $pfxOut" -ForegroundColor Green
    } catch {
        Write-Host "PFX export skipped (private key not exportable): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# --- Remove ----------------------------------------------------------------
$leaf = "Cert:\LocalMachine\My\$tp"
if ($DeleteKey) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
    $store.Open('ReadWrite'); $store.Remove($cert); $store.Close()
    Write-Host "Removed certificate and key for $tp." -ForegroundColor Green
} else {
    Remove-Item -Path $leaf -Force
    Write-Host "Removed certificate $tp (private key left in place)." -ForegroundColor Green
}

Write-Host "Done. Verify the site still serves the Let's Encrypt cert (Check-CertExpiry.ps1)." -ForegroundColor Yellow
