# 07 — Operations & Troubleshooting

Incident response, the common failure modes, the gotchas that bite, rate-limit recovery, and the staging→production cutover procedure used by every runbook.

---

## INCIDENT: "Certificate expires in < 7 days" (or already expired)

Work top to bottom. Stop when the cert renews.

### 1. Identify what's broken

```powershell
# Windows / win-acme
cd C:\win-acme
.\wacs.exe --list                                   # is the renewal still registered?
Get-ScheduledTaskInfo -TaskName (Get-ScheduledTask -TaskPath "\win-acme*\").TaskName
# Look at the newest log:
Get-ChildItem "$env:programdata\win-acme\*\Log\*.txt" -Recurse |
  Sort LastWriteTime -Desc | Select -First 1 | Get-Content -Tail 60
```
For **Azure**: open the Automation Account's failed job stream for the Posh-ACME runbook ([05](05-Azure-PoshACME-Runbook.md)). *(A free App Service Managed Certificate has no job to check — Azure renews it.)*

### 2. Force a renewal with full logging

```powershell
.\wacs.exe --renew --force --verbose                # win-acme
```
The verbose output names the failing step (validation, DNS, store, install). That's your root cause — jump to the matching row in the failure table below.

### 3. If it's environmental and slow to fix, restore service fast

- **Public host, expired:** if HTTP-01 normally works but is currently broken (e.g. HSTS), switch this host to **DNS-01** ([02](02-Windows-DNS01-Wildcard.md)) — it doesn't need port 80.
- **Can't fix in time:** issue the cert on a working machine to a **PFX** (`--store pfxfile`), copy it over, import, and bind by thumbprint with the relevant [script](scripts/) (RDP/SQL/Exchange/HTTP.SYS). Buys you the renewal window back.

### 4. Confirm recovery & close

```powershell
& "E:\NOC\SSL_Rotation_Windows\scripts\Check-CertExpiry.ps1" -Targets "host:443"
```
Verify the served cert has a fresh expiry, then record the cause in the incident log and, if it was a config gap, fix the underlying automation so it can't recur.

---

## Common failure modes

| Symptom / log message | Root cause | Fix |
|---|---|---|
| HTTP-01 `Timeout`/`Connection refused` during validation | Port 80 not reachable from internet (firewall / NSG / ISP) | Open inbound TCP 80, or switch host to DNS-01 ([02](02-Windows-DNS01-Wildcard.md)) |
| HTTP-01 `307`/redirect, validation fails | **HSTS** or a forced HTTP→HTTPS redirect intercepts `/.well-known/` | Use DNS-01 for this host |
| DNS-01 `incorrect TXT record` / `no TXT found` | TXT hadn't propagated, or wrong zone/credential scope, or CNAME-delegation typo | Verify zone + token scope; check `nslookup -type=TXT _acme-challenge.host`; fix the `_acme-challenge` CNAME ([02 §A](02-Windows-DNS01-Wildcard.md#section-a--cname-delegation-for-on-prem--api-less-dns)) |
| DNS-01 auth error from provider API | Token expired / wrong permissions (needs DNS edit on that zone) | Re-issue the scoped token; update the renewal |
| `too many certificates already issued` / `rateLimited` | Hit a Let's Encrypt limit (usually duplicate-cert from repeated prod testing) | Wait out the window; **test in staging** — see Rate-limit recovery below |
| Renewal "succeeds" but service still serves old cert | Non-IIS service didn't re-bind (post-renewal script missing/failed) | Add/repair the `--installation script` hook ([03](03-Windows-NonIIS-Services.md)); re-run the deploy script manually |
| Scheduled task runs, nothing renews | `wacs.exe` moved/deleted, or renewal store lost | Reinstall to the **same path**; re-create the renewal |
| Can't export PFX for a non-IIS service | Cert stored with non-exportable key | Re-issue with `--store pfxfile`, or set the store to allow export *before* issuance |
| Azure Web App not picking up renewed cert | Imported a **version-specific** Key Vault id, or App Service lost `Key Vault Certificate User` | Re-import with the **non-version-specific** id; re-grant the role ([05](05-Azure-PoshACME-Runbook.md#step-5--bind-the-cert-to-the-web-app)) |
| Azure DNS-01 fails | Automation managed identity missing **DNS Zone Contributor** on the zone | Grant the role scoped to the zone ([05](05-Azure-PoshACME-Runbook.md#step-1--identity--permissions)) |
| Browser shows "(STAGING)" / untrusted issuer | Cert came from the **staging** endpoint | Cut over to production (below) and re-issue |

---

## Gotchas to know before they bite

- **HSTS + HTTP-01** — don't combine; use DNS-01 on HSTS hosts.
- **Certificate / public-key pinning** — renewing changes the cert. If anything pins the **thumbprint** (HPKP, client allow-lists, mobile apps), it breaks on renewal. Pin the **public key** or, better, don't pin. Check before automating a host that clients pin.
- **Non-exportable private keys** — decide storage (`certificatestore` vs `pfxfile`) **before** first issuance; changing later means re-issuing.
- **Account key** — `%programdata%\win-acme\...\account` (and Posh-ACME state) controls your ACME account. Back it up; ACL it to `SYSTEM`/Administrators only; losing it just means a new account (and fresh rate-limit counters), but leaking it is a security event.
- **OCSP is gone** (Aug 2025) — don't build checks that expect an OCSP URL; rely on expiry + CT monitoring ([06](06-Monitoring-and-Alerting.md)).
- **Wildcard scope** — `*.example.com` does not cover the apex `example.com` (add it as a SAN) nor `a.b.example.com`.
- **Clock skew** — large time drift breaks ACME (JWS) signing. Keep servers on NTP.

---

## Rate-limit recovery

Production limits that actually bite ([details](00-Background-and-Concepts.md#5-rate-limits--why-we-always-test-in-staging)): **50 certs/registered-domain/week**, **5 duplicate (identical name set)/week**, **5 failed validations/hostname/hour**.

If you're limited:

1. **Stop hammering production.** Every failed attempt can consume budget.
2. **Move testing to staging** (`https://acme-staging-v02.api.letsencrypt.org/directory`) — get the workflow correct there with no production impact.
3. **Wait out the window** (rolling, ~1 week for the cert/duplicate limits; ~1 hour for failed-validation). There is no manual reset.
4. **Avoid recurrence:** rely on **ARI** (renewals are rate-limit exempt), and never loop production issuance in a test script.

> The failed-validation limit is the one you hit while *debugging* DNS-01. Debug in staging.

---

## Staging → Production cutover (canonical procedure)

Every runbook references this. The mechanism is the same everywhere: **the ACME directory URL is the only thing that differs between staging and production.**

| | Directory URL |
|---|---|
| **Staging** (test) | `https://acme-staging-v02.api.letsencrypt.org/directory` |
| **Production** (trusted) | `https://acme-v02.api.letsencrypt.org/directory` |

**win-acme**
1. Edit `settings.json` → `BaseUri` to the production URL.
2. `.\wacs.exe --cancel --friendlyname "<staging renewal>"`.
3. Re-run the original issuance command. Verify the issuer is a real LE intermediate and the browser trusts it.

**Azure (Posh-ACME / Automation, Runbook 05)**
1. Change `Set-PAServer`/`-DirectoryUrl` to production.
2. Run the runbook once manually; verify the vault has a production cert and the Web App syncs.

**Always confirm cutover succeeded:**
```powershell
& "E:\NOC\SSL_Rotation_Windows\scripts\Check-CertExpiry.ps1" -Targets "host:443"
# Issuer must NOT contain "(STAGING)"; browser must trust it.
```

---

## Routine operational tasks

| Task | How |
|------|-----|
| List all renewals on a server | `wacs.exe --list` |
| Force-renew one cert now | `wacs.exe --renew --force --id <id>` (uses duplicate-cert budget — sparingly) |
| Remove a cert from automation | `wacs.exe --cancel --friendlyname "<name>"` |
| Rotate a DNS API token | Issue new scoped token, re-run issuance to update the stored credential, revoke old token |
| Add a new host to monitoring | Append `host:port` to `monitored-hosts.txt` ([06](06-Monitoring-and-Alerting.md)) |
| Back up ACME account/state | Copy `%programdata%\win-acme` (Windows) / Posh-ACME state blob (Azure) to secure storage |

---

### References
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/) · [staging](https://letsencrypt.org/docs/staging-environment/)
- win-acme [troubleshooting](https://www.win-acme.com/manual/troubleshooting) · [Let's Encrypt community](https://community.letsencrypt.org/)
- HSTS/pinning context in [00 §3 & §6](00-Background-and-Concepts.md)
