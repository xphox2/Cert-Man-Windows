# 03 — Windows Non-IIS Services Runbook

**Use this when** the certificate is for a Windows service that is **not** IIS and won't pick up a renewed cert on its own:
- **RDP** (Remote Desktop / RD Session Host)
- **SQL Server** (force-encryption / TLS)
- **Exchange Server** (IMAP/POP/SMTP/IIS services)
- **Custom services on HTTP.SYS** (anything bound with `netsh http add sslcert`, e.g. a self-hosted .NET/Kestrel-on-HTTP.SYS app, WinRM, a custom API)

**Tools:** win-acme with a **post-renewal script** (`--installation script`), or **Posh-ACME + Posh-ACME.Deploy**.
**Validation:** usually **DNS-01** ([02](02-Windows-DNS01-Wildcard.md)); these hosts are often internal. HTTP-01 works too if the host is public and port 80 is free.

> **Why a script is needed:** IIS auto-rebinds on renewal. Other services bind a certificate by **thumbprint** (or service config) and must be told about the *new* thumbprint and usually **restarted**. The renewal tool issues the cert; a **post-renewal hook** re-binds it. That hook is the whole job of this runbook.

---

## The model

```
 win-acme / Posh-ACME renews the cert  (DNS-01)
                  │
                  ▼
 New cert lands in LocalMachine\My  (new thumbprint)
                  │
                  ▼
 Post-renewal SCRIPT runs automatically:
   1. (import PFX if needed)
   2. bind new thumbprint to the service
   3. restart / reload the service
                  │
                  ▼
 Service now serves the renewed cert — hands-off
```

The ready-to-use scripts live in **[scripts/](scripts/)**:

| Service | Script | What it does |
|---------|--------|--------------|
| RDP | `Deploy-RDP-Cert.ps1` | Sets `SSLCertificateSHA1Hash` on `RDP-Tcp`, restarts `TermService` |
| SQL Server | `Deploy-SQLServer-Cert.ps1` | Grants the SQL service account read on the private key, sets the cert in the SQL config, restarts the instance |
| Exchange | `Deploy-Exchange-Cert.ps1` | `Enable-ExchangeCertificate` for IMAP/POP/SMTP/IIS, restarts the affected services |
| Custom HTTP.SYS | `Bind-HttpSysCert.ps1` | `netsh http delete/add sslcert` for an `ipport`/`hostnameport` |

---

## Wiring a script into win-acme

win-acme calls your script after each successful issuance/renewal and passes the cert details as parameters. Issue with `--installation script`:

```powershell
cd C:\win-acme
.\wacs.exe --source manual --host "rdp.example.com" `
  --validation azure --azuretenantid "<t>" --azureclientid "<c>" --azuresecret "<s>" `
    --azuresubscriptionid "<sub>" --azureresourcegroupname "<dns-rg>" `
  --store certificatestore `
  --installation script `
  --script "E:\NOC\SSL_Rotation_Windows\scripts\Deploy-RDP-Cert.ps1" `
  --scriptparameters "-NewThumbprint {CertThumbprint} -FriendlyName {FriendlyName}" `
  --emailaddress ops@example.com --accepttos --closeonfinish --verbose
```

### win-acme script substitution variables

win-acme replaces these tokens in `--scriptparameters` at run time:

| Token | Meaning |
|-------|---------|
| `{CertThumbprint}` | Thumbprint of the **new** certificate |
| `{CertFriendlyName}` / `{FriendlyName}` | Friendly name of the renewal |
| `{CacheFile}` | Path to the freshly issued **PFX** in the cache |
| `{CachePassword}` | Password for `{CacheFile}` |
| `{StoreType}` / `{StorePath}` | Where the cert was stored |
| `{RenewalId}` | The renewal's id |

> If your service needs the cert in `LocalMachine\My` (RDP, SQL, Exchange), keep `--store certificatestore` and the cert is imported for you — the script only needs `{CertThumbprint}`. If the service wants a **file**, use `--store pfxfile --pfxfilepath C:\certs` and pass `{CacheFile}`/`{CachePassword}` to the script.

When the renewal task fires later, win-acme re-runs the **same** script with the new thumbprint — automatically.

---

## Service-by-service

### RDP (Remote Desktop)

RDP binds via a registry value pointing at the cert thumbprint.

```powershell
# Manual one-off (the renewal script does this for you):
& "E:\NOC\SSL_Rotation_Windows\scripts\Deploy-RDP-Cert.ps1" -NewThumbprint "<thumbprint>"
```
What it sets: `HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp\SSLCertificateSHA1Hash`, then restarts `TermService`. Verify with `mstsc` to `rdp.example.com` — no certificate warning.

### SQL Server

SQL needs (a) the SQL service account to have **read on the private key**, and (b) the cert thumbprint set in SQL's config, then a restart.

```powershell
& "E:\NOC\SSL_Rotation_Windows\scripts\Deploy-SQLServer-Cert.ps1" `
    -NewThumbprint "<thumbprint>" -InstanceName "MSSQLSERVER" -ForceEncryption
```
Verify: connect with `Encrypt=True` and confirm the served cert subject. The script handles the MachineKeys ACL grant that is the usual failure point.

### Exchange Server

```powershell
& "E:\NOC\SSL_Rotation_Windows\scripts\Deploy-Exchange-Cert.ps1" `
    -NewThumbprint "<thumbprint>" -Services "IIS,SMTP,IMAP,POP"
```
Runs `Enable-ExchangeCertificate -Thumbprint <new> -Services ...` and restarts the relevant transport/IMAP/POP services. Run on the Exchange server (needs Exchange Management Shell).

### Custom HTTP.SYS service

Any service that terminates TLS through HTTP.SYS (not IIS) binds with `netsh`.

```powershell
& "E:\NOC\SSL_Rotation_Windows\scripts\Bind-HttpSysCert.ps1" `
    -NewThumbprint "<thumbprint>" -IpPort "0.0.0.0:8443" -AppId "{a uuid for your app}"
```
The script deletes the old binding and adds the new one for the given `ipport` (or use `-HostnamePort name:443` for SNI). Restart your service if it caches the cert at startup.

---

## Alternative: Posh-ACME + Posh-ACME.Deploy

Prefer PowerShell end-to-end (or your provider isn't in win-acme)? Use [Posh-ACME](https://poshac.me/). It does **not** auto-create a scheduled task, so we register one (see `scripts\Renew-PoshACME.ps1`).

```powershell
Install-Module Posh-ACME -Scope AllUsers
Set-PAServer LE_STAGE                      # staging first; LE_PROD for production

# Issue (Azure DNS example) — wildcard supported
$pArgs = @{ AZSubscriptionId='<sub>'; AZTenantId='<tenant>'; AZAppCred=(Get-Credential) }
New-PACertificate '*.example.com','example.com' -AcceptTOS -Contact ops@example.com `
    -Plugin Azure -PluginArgs $pArgs -Install

# Renewal + deploy driver, scheduled daily:
& "E:\NOC\SSL_Rotation_Windows\scripts\Renew-PoshACME.ps1" -RegisterTask
```

`Posh-ACME.Deploy` offers helpers (e.g. `Set-RDCertificate`, `Set-IISCertificate`) you can call from the renewal driver's post-hook. See the script header for the hook pattern.

---

## Verify & monitor

```powershell
# What thumbprint is the service actually using?
# RDP:
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').SSLCertificateSHA1Hash
# HTTP.SYS:
netsh http show sslcert ipport=0.0.0.0:8443
```

Then add the host to the **independent monitor** ([06](06-Monitoring-and-Alerting.md)) — for non-IIS services this is *especially* important, because a broken post-renewal script is invisible until something can't connect. `Check-CertExpiry.ps1` supports checking arbitrary `host:port`.

---

## Appendix: `settings.json` reference

Location: `%programdata%\win-acme\settings.json` (or alongside `wacs.exe` in a portable install). Key fields used across all Windows runbooks:

```json
{
  "Client": {
    "ConfigurationPath": null
  },
  "Acme": {
    "Validation": { "PreValidateDns": true }
  },
  "BaseUri": "https://acme-v02.api.letsencrypt.org/directory",
  "ScheduledTask": {
    "RenewalDays": 55,
    "RenewalDaysRange": 0,
    "StartBoundary": "09:00:00",
    "RandomDelay": "04:00:00",
    "ExecutionTimeLimit": "02:00:00"
  },
  "Store": {
    "CertificateStore": { "DefaultStore": "My" },
    "PfxFile": { "DefaultPath": "C:\\certs" }
  },
  "Notification": {
    "SmtpServer": "smtp.example.com",
    "SmtpPort": 587,
    "SmtpUser": "alerts@example.com",
    "SmtpPassword": "<app-password>",
    "SenderAddress": "letsencrypt@example.com",
    "ReceiverAddresses": [ "ops@example.com" ],
    "EmailOnSuccess": false
  }
}
```

| Field | Why it matters |
|-------|----------------|
| `BaseUri` | **staging vs production** directory — the single most important toggle. |
| `ScheduledTask.RenewalDays` | Renew when cert is this many days old. `55` for 90-day certs; lower to **~20** for 45-day certs. |
| `ScheduledTask.RandomDelay` | Spreads load so all servers don't hit the CA at once. |
| `Notification.*` | Email alerts on failure — set this so silent failures still notify. `EmailOnSuccess:false` keeps noise down. |
| `Store.CertificateStore.DefaultStore` | `My` = LocalMachine\Personal, where services bind by thumbprint. |
| `Store.PfxFile.DefaultPath` | Where PFX files go when a service needs a file rather than the store. |

> Field names vary slightly across win-acme versions; run `.\wacs.exe --help` and consult the [settings reference](https://www.win-acme.com/reference/settings) to confirm for your build. `Install-WinAcme.ps1` writes a working baseline.

---

### References
- win-acme: [script installation plugin](https://www.win-acme.com/reference/plugins/installation/script) · [store plugins](https://www.win-acme.com/reference/plugins/store/)
- [Posh-ACME](https://poshac.me/docs/v4/) · [Posh-ACME.Deploy](https://github.com/rmbolger/Posh-ACME.Deploy)
- [netsh http](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-http) · [SQL Server encryption](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-sql-server-encryption)
