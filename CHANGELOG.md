# Changelog — SSL Certificate Rotation Automation Handbook

All notable changes to this operations handbook are documented here. Newest entries on top.

## [0.1.3] — 2026-06-24

### Added
- **`08-Replacing-Existing-Certs.md`** — vendor-agnostic migration runbook: take over a self-signed/default IIS cert, a GoDaddy/DigiCert/Sectigo/any commercial cert, or an imported wildcard with Let's Encrypt. Covers the key principle (ACME issues fresh and re-binds — prior CA is irrelevant), no-downtime cutover, safe cleanup, rollback, and the CA-change pinning trap. Cross-cutting companion to Runbooks 01/02/03.
- **`scripts/Inventory-Certs.ps1`** — lists every cert in `LocalMachine\My` with issuer/source label, expiry, thumbprint, and what references it (IIS bindings, HTTP.SYS, RDP) — the pre-flight safety check before replacing/removing a cert.
- **`scripts/Remove-OldCert.ps1`** — safely removes a superseded cert: refuses to delete while it's still referenced (unless `-Force`), backs it up first.
- New replacement-flow diagram (`docs/diagrams/runbook08-replace-existing.*`) and a 9th training-deck slide; deck PDF rebuilt.

### Changed
- README decision flow/lookup and Runbooks 01 & 02 now cross-link Runbook 08 for "replacing an existing cert" scenarios.
- All `scripts/*.ps1` re-saved as **UTF-8 with BOM** so Windows PowerShell 5.1 parses non-ASCII characters correctly on the server.

## [0.1.2] — 2026-06-24

### Added
- `docs/training-deck/` — a print-ready **training deck PDF** (`SSL-Cert-Rotation-Training-Deck.pdf`): A4-landscape title slide plus one slide per diagram, in handbook order, each with a runbook label and a one-line training caption.
- `deck.html` (the slide source, embeds the SVG diagrams) and `build-deck.js` (regenerates the PDF via the headless Chromium bundled with mermaid-cli: `node build-deck.js`).

## [0.1.1] — 2026-06-24

### Changed
- Replaced all ASCII-art flow diagrams with **Mermaid** diagrams across the README and runbooks 01–06. GitHub renders these inline as clean visual diagrams for training.

### Added
- `docs/diagrams/` — editable Mermaid source (`src/*.mmd`), plus **SVG and high-resolution PNG** exports of every flow for slides/printed handouts, a diagrams index (`README.md`), the render config (`mmdc-config.json`), and `render-diagrams.ps1` to regenerate images after edits.
- Each runbook now links its slide-ready PNG/SVG beneath the inline diagram.
- New CNAME-delegation diagram in Runbook 02 §A.

## [0.1.0] — 2026-06-24

Initial release of the SSL Certificate Rotation Automation operations handbook.

### Added
- `README.md` — handbook index and master "which runbook do I use?" decision flowchart, golden rules, tool overview.
- `00-Background-and-Concepts.md` — ACME/RFC 8555 fundamentals, certificate-lifetime timeline (90→45 days, CA/Browser Forum 47-day-by-2029 schedule), the three challenge types, DNS-01 with CNAME-delegation for on-prem DNS, rate limits, staging, ARI, wildcard rules, OCSP retirement, monitoring rationale, glossary.
- `01-Windows-IIS-HTTP01-Runbook.md` — public IIS sites via win-acme HTTP-01 (fully unattended, auto scheduled task + IIS binding).
- `02-Windows-DNS01-Wildcard.md` — internal IIS and wildcard certs via win-acme DNS-01 (Azure DNS, Cloudflare, GoDaddy, and CNAME delegation for API-less/on-prem DNS).
- `03-Windows-NonIIS-Services.md` — RDP, SQL Server, Exchange, and custom HTTP.SYS services via post-renewal scripts; Posh-ACME alternative; `settings.json` reference.
- `04-Azure-Acmebot-Runbook.md` — **primary** Azure path: App Service / Key Vault Acmebot deployment, least-privilege managed-identity RBAC, Key Vault auto-sync binding, vs. App Service Managed Certificate comparison.
- `05-Azure-PoshACME-Runbook.md` — alternative Azure path: Posh-ACME + Azure Automation runbook with managed identity, Key Vault upload, auto-sync binding.
- `06-Monitoring-and-Alerting.md` — dual-layer monitoring model, 30/15/7-day thresholds, independent expiry checks, per-tool renewal-success alerting, Certificate Transparency watch.
- `07-Operations-and-Troubleshooting.md` — incident runbook, failure-modes table, gotchas (HSTS, pinning, non-exportable keys, account key), rate-limit recovery, canonical staging→production cutover.
- `scripts/` — `Install-WinAcme.ps1`, `Deploy-RDP-Cert.ps1`, `Deploy-SQLServer-Cert.ps1`, `Deploy-Exchange-Cert.ps1`, `Bind-HttpSysCert.ps1`, `Check-CertExpiry.ps1`, `Renew-PoshACME.ps1`.
- `monitored-hosts.txt` — source-of-truth host list for the independent expiry monitor.

### Decisions captured
- Certificate authority: Let's Encrypt (primary); ZeroSSL / Google Trust Services noted as failover only.
- Windows exposure: mixed → both HTTP-01 and DNS-01 documented.
- DNS providers in scope: Azure DNS, Cloudflare, GoDaddy, and on-prem (via CNAME delegation).
- Azure: Acmebot as the recommended primary; Posh-ACME runbook as the scripted alternative.
- Certificate types: both wildcard and per-hostname (wildcards require DNS-01).
