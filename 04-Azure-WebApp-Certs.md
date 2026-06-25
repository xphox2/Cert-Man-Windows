# 04 — Azure Web App Certificates Runbook

**Scope:** TLS certificates for **Azure Web Apps / App Service**.

> **Approach:** like the Windows side, we don't deploy third-party applications. We use **Azure's built-in free certificate** where it fits, and our **own Posh-ACME automation** ([Runbook 05](05-Azure-PoshACME-Runbook.md)) for Let's Encrypt where it doesn't. (Earlier drafts referenced a community "Acmebot" Functions app — we do **not** use it; it's a third-party app you'd have to run and trust in your tenant.)

## ⚠️ Decide first: do you actually need Let's Encrypt here?

Azure App Service includes a **free App Service Managed Certificate (ASMC)** that **auto-renews with zero maintenance** — Azure reissues it every ~6 months, **45 days before expiry, and updates the bindings automatically** ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-certificate)). For a single hostname, **use the free managed cert — do not run Let's Encrypt.** It already does what this handbook is about (hands-off rotation), with nothing to deploy or operate.

Reach for **Let's Encrypt via our Posh-ACME runbook** ([05](05-Azure-PoshACME-Runbook.md)) **only** when the free cert can't do what you need:

| Your need | Use |
|-----------|-----|
| Single hostname (apex or subdomain), App Service only | **Free App Service Managed Certificate** (below) — nothing to run |
| **Wildcard** (`*.example.com`) | **Let's Encrypt — [Runbook 05](05-Azure-PoshACME-Runbook.md)** |
| **Export / reuse** one cert across App Gateway, Front Door, a VM, or on-prem | **Let's Encrypt — [Runbook 05](05-Azure-PoshACME-Runbook.md)** |
| Same CA as your on-prem estate, or private DNS / App Service Environment / client-cert use | **Let's Encrypt — [Runbook 05](05-Azure-PoshACME-Runbook.md)** |

ASMC's hard limits (the reason the right column exists): **no wildcard**, **not exportable**, no private DNS, not supported in App Service Environment, no client-cert/thumbprint use ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-certificate)).

---

## Path 1 — Free App Service Managed Certificate (the default)

Use this for a single hostname. It's a portal-only, few-click setup; Azure handles issuance, renewal, and re-binding forever.

### Prerequisites
- [ ] App Service plan **Basic (B1) or higher** (Free/Shared can't bind custom-domain TLS).
- [ ] **Custom domain added and verified** on the Web App (CNAME/A + `asuid` TXT — the portal's *Add custom domain* flow walks you through it).

### Steps
1. Web App → **Settings → Custom domains**.
2. On the custom domain row → **Add binding** → **Create App Service Managed Certificate** → pick the hostname → **Create**.
3. Set the binding to **SNI SSL**.
4. Browse `https://<your-host>` — trusted cert, no warning.

That's it. Azure auto-renews ~45 days before expiry and updates the binding; **nothing to schedule or monitor** on your side. (Optional: still add the host to independent expiry monitoring per [Runbook 06](06-Monitoring-and-Alerting.md) as a cross-check.)

> **Validated:** the free managed cert path was tested end-to-end (issued, bound, serving HTTPS) on 2026-06-25.

---

## Path 2 — Let's Encrypt (wildcard / export / multi-service)

When the decision table sends you here (almost always for a **wildcard**), use our own **Posh-ACME automation**, documented step-by-step in **[Runbook 05 — Azure Posh-ACME](05-Azure-PoshACME-Runbook.md)**.

In short, that runbook uses our [`scripts/Renew-PoshACME.ps1`](scripts/Renew-PoshACME.ps1) (Azure mode) running as an **Azure Automation runbook**:

```
Azure Automation runbook (our script, scheduled)
   -> Posh-ACME issues the cert via DNS-01 against Azure DNS (managed identity)
   -> uploads the PFX to Azure Key Vault
   -> App Service imports the cert from Key Vault (auto-syncs within 24h)
```

No third-party application is deployed — only the **Posh-ACME** PowerShell module (an ACME client, the Azure analogue of win-acme), wrapped in our script. Continue in **[Runbook 05](05-Azure-PoshACME-Runbook.md)**.

---

### References
- Microsoft Learn: [App Service certificates overview](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-certificate) · [secure a custom domain (TLS binding)](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-bindings)
- Our Let's Encrypt Azure path: [Runbook 05](05-Azure-PoshACME-Runbook.md) · [Posh-ACME docs](https://poshac.me/docs/v4/)
