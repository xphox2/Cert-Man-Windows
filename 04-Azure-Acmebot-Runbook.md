# 04 — Azure Web App (Acmebot) Runbook — PRIMARY

**Use this for:** Let's Encrypt certificates on **Azure Web Apps / App Service** (and Functions, Container Apps), with hands-off auto-renewal.
**Tool:** **[Acmebot](https://github.com/shibayan)** — an Azure Functions app (with a web dashboard) that issues and renews Let's Encrypt certs into **Azure Key Vault**, from which Azure services auto-import.
**Validation:** DNS-01 (so wildcards and apex are supported).
**Result:** Cert in Key Vault → App Service syncs it within 24h → renewals are automatic and exempt from rate limits (ARI). No VMs, no scripts.

> Want a scripted/runbook approach with no Functions app instead? Use **[05](05-Azure-PoshACME-Runbook.md)**.

---

## Choose your Acmebot

| | **App Service Acmebot** | **Key Vault Acmebot** |
|---|---|---|
| Repo | [shibayan/appservice-acmebot](https://github.com/shibayan/appservice-acmebot) | [shibayan/keyvault-acmebot](https://github.com/shibayan/keyvault-acmebot) |
| Best when | Certs are consumed **only by App Service** | Certs shared across **App Service + Front Door + App Gateway + API Management**, or you want one central cert store |
| Binds certs to App Service | Directly | Via Key Vault import (each service points at the vault) |
| Pick this if… | Single/few Web Apps | Multi-service estate, "one source of truth" |

Both deploy the same way, support wildcards/SANs, DNS-01, a dashboard, and ARI-aware auto-renewal. **If in doubt and you only have Web Apps, use App Service Acmebot.** If certs will be reused by Front Door/App Gateway, use Key Vault Acmebot.

---

## Architecture

```
   Dashboard / API (you create a cert order)
            │
            ▼
   Acmebot Function App ──ACME──► Let's Encrypt
            │  writes _acme-challenge TXT (DNS-01)
            ▼
        Azure DNS (or Cloudflare, etc.)
            │  validated
            ▼
   Cert issued ──► stored in Azure Key Vault (PFX)
            │
            ▼
   App Service / Front Door / App Gateway
   auto-import the cert from Key Vault (≤24h, no downtime)
            │
            ▼
   Daily Acmebot timer re-checks & renews via ARI (rate-limit exempt)
```

---

## Prerequisites

- [ ] Azure subscription with rights to deploy a Function App, Key Vault, and assign RBAC.
- [ ] The Web App exists, with the **custom domain already added & verified** (the `CNAME`/`A` + `asuid` TXT validation done) — Acmebot issues the cert; you still need the hostname mapped.
- [ ] DNS for the domain in **Azure DNS** (cleanest) or another [supported provider](https://github.com/shibayan/appservice-acmebot/wiki/DNS-Provider-Configuration) (Cloudflare, Route53, GoDaddy, …).
- [ ] `az` CLI logged in (`az login`) or use the portal.
- [ ] Decide App Service Plan tier: TLS/SNI bindings need **Basic (B1) or higher** (Free/Shared can't bind custom-domain certs).

---

## Step 1 — Deploy Acmebot

Easiest is the **"Deploy to Azure"** button in the repo README — it provisions the Function App, Storage, Application Insights, and (optionally) a new Key Vault.

Fill in:
- **Resource group / region**
- **App Name Prefix** (globally unique → dashboard at `https://<prefix>-functions.azurewebsites.net`)
- **Mail Address** (ACME account contact)
- **Acme Endpoint** — set to **staging** first: `https://acme-staging-v02.api.letsencrypt.org/directory`
- **Key Vault** — create new, or select an existing central vault (Key Vault Acmebot).

Authentication: the dashboard is protected by **Azure AD (Easy Auth)**. After deploy, add yourself/the ops group as an authorized user (App Service → Authentication) so only staff can reach it.

---

## Step 2 — Grant the Function's managed identity its roles (least privilege)

Acmebot uses its **system-assigned managed identity**. Grant exactly:

```bash
PRINCIPAL=$(az functionapp identity show -g <rg> -n <prefix>-functions --query principalId -o tsv)

# Create/update certs in the vault
az role assignment create --assignee $PRINCIPAL \
  --role "Key Vault Certificates Officer" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>"

# Write the _acme-challenge TXT records (scope to the ZONE, not the whole sub)
az role assignment create --assignee $PRINCIPAL \
  --role "DNS Zone Contributor" \
  --scope "/subscriptions/<sub>/resourceGroups/<dns-rg>/providers/Microsoft.Network/dnszones/example.com"
```

> Using Cloudflare/another provider instead of Azure DNS? Skip the DNS Zone role and put the provider's **scoped API token** in the Function App's configuration per the [DNS provider wiki](https://github.com/shibayan/appservice-acmebot/wiki/DNS-Provider-Configuration). Hierarchical settings on Flex Consumption use `__` (e.g. `Acmebot__Cloudflare__ApiToken`).

---

## Step 3 — Let App Service read certs from Key Vault

So the Web App can import the issued cert, grant the **App Service resource provider** read access on the vault (this is a fixed well-known principal):

```bash
az role assignment create \
  --assignee "abfa0a7c-a6b6-4736-8310-5855508787cd" \
  --role "Key Vault Certificate User" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>"
```

> `abfa0a7c-a6b6-4736-8310-5855508787cd` is Microsoft's global **Microsoft.Azure.WebSites** service principal — the same in every tenant. If your vault uses **access policies** rather than RBAC, grant it **Get** on secrets + certificates instead.

---

## Step 4 — Issue a certificate (STAGING) via the dashboard

1. Browse to `https://<prefix>-functions.azurewebsites.net` and sign in.
2. **Add Certificate** → choose the DNS zone → enter the names. For a wildcard, add both `*.example.com` and `example.com`.
3. Submit. Acmebot runs the DNS-01 orchestration and writes the cert into Key Vault.
4. Confirm in the vault:
   ```bash
   az keyvault certificate list --vault-name <vault> -o table
   ```
   The issuer will be a **(STAGING)** intermediate — expected.

If it fails, it's almost always the DNS Zone role/scope or the wrong zone selected → [07](07-Operations-and-Troubleshooting.md).

---

## Step 5 — Bind the cert to the Web App

App Service imports from Key Vault and creates the SNI SSL binding:

```bash
# Import the Key Vault cert into the Web App (use the NON-version-specific id)
az webapp config ssl import -g <rg> -n <webapp> \
  --key-vault <vault> --key-vault-certificate-name example-com

# Bind it to the custom domain (SNI)
THUMB=$(az webapp config ssl list -g <rg> --query "[?name=='example.com'].thumbprint" -o tsv)
az webapp config ssl bind -g <rg> -n <webapp> --certificate-thumbprint $THUMB --ssl-type SNI
```

**Critical:** App Service stores the **non-version-specific** Key Vault certificate reference, so when Acmebot writes a new version on renewal, the Web App **auto-syncs within 24 hours with no downtime** and no re-binding. Don't pin a specific version.

---

## Step 6 — Cut over to PRODUCTION

1. In the Function App configuration, change the ACME endpoint to production:
   `Acmebot__Endpoint = https://acme-v02.api.letsencrypt.org/directory` (setting name per your Acmebot version), then restart the Function App.
2. In the dashboard, **delete the staging cert order and re-add it** so a production cert is issued into the vault.
3. Re-run the `az webapp config ssl import` from Step 5 (or just wait for the ≤24h sync) so the production cert version is picked up. Verify the browser now trusts it.

---

## Step 7 — Confirm auto-renewal & monitor

- Acmebot runs a **daily timer** that renews managed certs via **ARI** (well before expiry, rate-limit exempt). Nothing to schedule.
- Built-in **Application Insights**: create an alert on Function **failures/exceptions** so a broken renewal pages someone.
  ```bash
  # Example: alert on any Function execution failure
  az monitor metrics alert create -g <rg> -n acmebot-failures \
    --scopes "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<prefix>-functions" \
    --condition "total FunctionExecutionCount where Status == 'Failed' > 0" \
    --window-size 1h --evaluation-frequency 15m \
    --action "/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/actionGroups/<ag>"
  ```
- Add the public hostname to the **independent expiry monitor** ([06](06-Monitoring-and-Alerting.md)) as a cross-check that the binding is actually serving the renewed cert.

---

## Done — what you built

- A Function-based Acmebot issuing Let's Encrypt certs into Key Vault.
- Web App (and optionally Front Door / App Gateway) auto-importing on renewal, zero downtime.
- Daily ARI-driven renewal + Azure Monitor alerting + independent expiry monitoring.

## Why Let's Encrypt here instead of the free App Service Managed Certificate?

| | App Service Managed Certificate | Let's Encrypt via Acmebot |
|---|---|---|
| Cost | Free | Free (tiny Function cost) |
| **Wildcard** | ❌ Not supported | ✅ Yes |
| Multi-SAN | Limited | ✅ Yes |
| Exportable / reusable across services | ❌ No | ✅ Yes (in Key Vault) |
| Same CA as our on-prem certs | No (DigiCert) | ✅ Yes (one CA everywhere) |

Use the managed cert for a throwaway single subdomain; use this runbook for anything needing wildcard, SAN, export, Front Door/App Gateway sharing, or CA consistency with the Windows estate.

---

### References
- [App Service Acmebot](https://github.com/shibayan/appservice-acmebot) · [Key Vault Acmebot](https://github.com/shibayan/keyvault-acmebot) · [DNS provider config](https://github.com/shibayan/appservice-acmebot/wiki/DNS-Provider-Configuration)
- Microsoft Learn: [import a Key Vault certificate to App Service](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-certificate) · [secure a custom domain (TLS binding)](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-bindings) · [Key Vault RBAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
