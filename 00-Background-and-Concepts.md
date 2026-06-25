# 00 — Background & Concepts

> Read this once. It explains *why* we automate, and the handful of ACME concepts every runbook assumes you understand. The runbooks themselves are step-by-step and do not re-explain these.

---

## 1. Why certificate lifetimes forced this project

For years a TLS certificate lasted **365 days** (or longer). That era is over. The CA/Browser Forum — the body that governs all publicly trusted certificates — voted in April 2025 ([Ballot SC-081v3](https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/)) to phase maximum certificate lifetimes down on this schedule:

| Date | Max TLS cert lifetime |
|------|----------------------|
| March 15, 2026 | 200 days |
| March 15, 2027 | 100 days |
| March 15, 2029 | **47 days** |

Let's Encrypt is ahead of that curve:

- **90 days** — the long-standing Let's Encrypt default.
- **45 days** — Let's Encrypt's `tlsserver` profile begins switching during 2026 ([90→45 announcement](https://letsencrypt.org/2025/12/02/from-90-to-45)).
- **6 days** — short-lived certificates, now generally available ([GA Jan 2026](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)).

**Operational consequence:** an estate that did ~2 renewals/year per cert will, under 47-day certs, renew roughly **every two to three weeks, forever**. There is no manual process that survives this. Everything in this handbook exists to make renewal a hands-off background activity with independent monitoring to catch the rare silent failure.

**Renewal-window rule of thumb:** renew when about **one-third of the lifetime remains**.

| Cert lifetime | Renew at | Failure budget before outage |
|---------------|----------|------------------------------|
| 90 days | ~30 days before expiry | ~30 days |
| 45 days | ~15 days before expiry | ~15 days |
| 6 days | every 2–3 days | hours |

---

## 2. ACME in one page

**ACME** (Automatic Certificate Management Environment, [RFC 8555](https://datatracker.ietf.org/doc/html/rfc8555/)) is the protocol every tool here speaks. The flow:

1. **Account** — the client generates an account key pair and registers it (with a contact email) at the CA. All later requests are signed with the account key.
2. **Order** — the client asks for a certificate covering one or more identifiers (domain names), e.g. `example.com` and `*.example.com`.
3. **Authorization + Challenge** — for each name, the CA demands proof you control it. The client satisfies a **challenge** (see §3).
4. **Validation** — the CA checks the challenge.
5. **Issuance** — once all names are validated, the client submits a CSR and the CA returns the signed certificate.

You rarely touch this directly — win-acme (Windows) and Posh-ACME (Azure) do it for you. But the **challenge type** is a decision you *do* make, because it determines which runbook applies.

---

## 3. The three challenge types (this drives runbook choice)

| | **HTTP-01** | **DNS-01** | **TLS-ALPN-01** |
|---|---|---|---|
| How it proves control | Serves a token file at `http://<domain>/.well-known/acme-challenge/<token>` | Publishes a TXT record at `_acme-challenge.<domain>` | Presents a special self-signed cert on :443 via ALPN |
| Port required | 80 (inbound from internet) | none (outbound API only) | 443 (inbound from internet) |
| Issues **wildcards**? | ❌ No | ✅ **Yes (only method)** | ❌ No |
| Works for **internal** hosts? | ❌ No | ✅ Yes | ❌ No |
| Needs a DNS provider API? | No | ✅ Yes | No |
| Complexity | Low | Medium | High (rarely used) |

**Decision rules used throughout this handbook:**

- Public host, port 80 reachable, no wildcard → **HTTP-01** (simplest). → Runbook 01.
- Wildcard needed, **or** host not internet-reachable, **or** port 80 blocked → **DNS-01**. → Runbooks 02 / 03 / 04 / 05.
- TLS-ALPN-01 — we do **not** use it; it has no advantage for our scenarios and limited tooling support.

---

## 4. DNS-01 and our four DNS situations

DNS-01 works by writing a temporary `_acme-challenge` TXT record, so the client needs **API access to the authoritative DNS for that name**. We have four cases:

| DNS hosting | How DNS-01 is done |
|-------------|--------------------|
| **Azure DNS** | Native plugin / managed identity. Best fit for the Azure runbooks. |
| **Cloudflare** | Scoped API token (`Zone:DNS:Edit` + `Zone:Read`). Well supported everywhere. |
| **GoDaddy / other registrar** | Provider API key/secret. Plugin support varies — confirm before relying on it. |
| **On-prem / internal AD DNS** | Internal DNS has no public API, so we use **CNAME delegation** (below). |

### CNAME delegation pattern (for on-prem / API-less DNS)

You do **not** need to expose your internal DNS. Delegate just the challenge record to a zone that *does* have an API:

1. In your public/API-capable provider (Cloudflare or Azure DNS), create a small zone or use an existing one, e.g. `acme.example.com`, or deploy [acme-dns](https://github.com/joohoi/acme-dns).
2. For each host that needs a cert, add a **static CNAME** in the host's real DNS zone:
   ```
   _acme-challenge.internal-host.example.com.  CNAME  internal-host.acme.example.com.
   ```
3. Point the ACME client's DNS plugin at the **delegated** zone (`acme.example.com`). It writes the TXT there; the CA follows the CNAME and reads it.

The host name itself stays on internal DNS; only the throwaway challenge record is delegated. This is the standard way to do DNS-01 for internal servers.

---

## 5. Rate limits — why we always test in staging

Let's Encrypt **production** enforces limits ([rate-limit docs](https://letsencrypt.org/docs/rate-limits/)). The ones that hurt during setup/testing:

| Limit | Value |
|-------|-------|
| Certificates per registered domain | 50 per 7 days |
| **Duplicate** certificates (exact same name set) | **5 per 7 days** |
| Failed validations | 5 per account, per hostname, per hour |
| New accounts per IP | 10 per 3 hours |

Repeatedly testing automation against production will exhaust the **duplicate-certificate** limit fast and lock you out for a week. So:

> **Always point new automation at the staging directory first:**
> `https://acme-staging-v02.api.letsencrypt.org/directory`

Staging mirrors production but with far higher limits. Its certs are issued by **"(STAGING)"** intermediates and are **not browser-trusted** — that's expected; you're testing the *workflow*, not serving traffic. Cut over to production (`https://acme-v02.api.letsencrypt.org/directory`) only once the staging run succeeds end-to-end. Each runbook calls out the cutover; the procedure is consolidated in [07](07-Operations-and-Troubleshooting.md).

### ARI — renewals don't count against limits

**ACME Renewal Information** ([RFC 9773](https://datatracker.ietf.org/doc/html/rfc9773/)) lets the CA tell the client *when* to renew, and **ARI-driven renewals are exempt from rate limits**. Modern ACME clients use it automatically. Practical upshot: you can't accidentally rate-limit yourself by renewing — only by issuing many *new* distinct certs. Prefer ARI-aware clients; don't disable it.

---

## 6. Wildcards — rules to remember

- A wildcard (`*.example.com`) covers `a.example.com`, `b.example.com`, … but **not** the apex `example.com` (add it as a separate SAN) and **not** multi-level `a.b.example.com`.
- Wildcards can **only** be issued via **DNS-01**.
- One wildcard cert can replace dozens of per-host certs — fewer renewals, but the DNS credential that issues it is more powerful, so scope and protect it carefully.

---

## 7. Revocation / OCSP — what changed

Let's Encrypt **shut down OCSP in August 2025** ([end-of-life notice](https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life)). Revocation status is now distributed via **CRLs**. For us this means:

- Newly issued certs may have **no OCSP URL** — don't build monitoring or stapling checks that assume one.
- Don't rely on OCSP stapling health as a signal. Monitor **expiry** and **issuance** instead (see [06](06-Monitoring-and-Alerting.md)).

---

## 8. Monitoring rationale (the rule that prevents outages)

Automation **fails silently**: an expired DNS token, a moved `wacs.exe`, a revoked managed-identity role — the scheduled task "runs" and reports success while the cert quietly ages out. The defense is **independent, dual-layer monitoring**:

- **Layer 1 — Expiry:** something that checks the *actual served certificate's* days-to-expiry, independent of the renewal tool, and alerts at 30 / 15 / 7 days.
- **Layer 2 — Issuance/renewal success:** confirm renewals actually happened (Certificate Transparency log watch, or the tool's own success log/webhook).

Details and the ready-made `Check-CertExpiry.ps1` script are in [06](06-Monitoring-and-Alerting.md).

---

## 9. Certificate authority choice

**Primary: Let's Encrypt.** Free, trusted, largest ecosystem, leading the short-lifetime transition, excellent tooling.

**Failover only** (note for awareness, not standard use):

- **ZeroSSL** — full ACME, but has had reliability/rate issues. Acceptable as a secondary CA, not primary.
- **Google Trust Services** — free ACME, requires a GCP project and External Account Binding (EAB) credentials.
- **Buypass Go** — discontinued free ACME (Oct 2025); not an option.

All tools in this handbook are CA-agnostic (just change the ACME directory URL), so a failover CA is a config change, not a re-architecture.

---

## 10. Glossary

| Term | Meaning |
|------|---------|
| **ACME** | The automation protocol (RFC 8555) clients use to talk to the CA. |
| **Challenge** | Proof-of-control test: HTTP-01, DNS-01, or TLS-ALPN-01. |
| **Account key** | The key pair identifying your ACME account at the CA. Protect it. |
| **SAN** | Subject Alternative Name — additional hostnames on one certificate. |
| **Thumbprint** | SHA-1 hash identifying a cert in the Windows store; how non-IIS services bind. |
| **Staging** | Let's Encrypt's test environment — untrusted certs, relaxed limits. |
| **ARI** | ACME Renewal Information — CA tells client when to renew; renewals are rate-limit exempt. |
| **PFX / PKCS#12** | Password-protected file bundling a cert + private key; format for import/binding. |
| **Key Vault** | Azure secret/cert store; the hub for Azure auto-rotation. |
| **CNAME delegation** | Redirecting `_acme-challenge` to an API-capable zone so internal hosts can use DNS-01. |

---

### Authoritative sources

- Let's Encrypt docs: [challenge types](https://letsencrypt.org/docs/challenge-types/), [rate limits](https://letsencrypt.org/docs/rate-limits/), [staging](https://letsencrypt.org/docs/staging-environment/)
- [RFC 8555 (ACME)](https://datatracker.ietf.org/doc/html/rfc8555/) · [RFC 9773 (ARI)](https://datatracker.ietf.org/doc/html/rfc9773/)
- [CA/Browser Forum SC-081v3](https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/)
- Let's Encrypt: [90→45 days](https://letsencrypt.org/2025/12/02/from-90-to-45) · [6-day GA](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability) · [OCSP EOL](https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life)
