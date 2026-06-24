# Changelog — SSL Certificate Rotation Automation Handbook

All notable changes to this operations handbook are documented here. Newest entries on top.

## [0.1.11] — 2026-06-24

### Changed
- **Consolidated the IIS workflow into one script, `setup-iis.ps1`** (root, `irm | iex`). It is the step after the preflight: validates IIS (installs the role if missing) and win-acme, scans all sites/bindings, plans the minimum set of wildcard certs (shared parents collapse onto one cert; apex as SAN; multi-level gets its own `*.sub`; PSL-aware), checks existing coverage, and — if everything checks out — **offers to generate the missing certs on the live (production) Let's Encrypt server** (DNS-01, provider chosen once) and bind each covered host to its IIS site.
- **Removed** `plan-certs.ps1` and `scripts/Setup-IIS.ps1` — both folded into `setup-iis.ps1`. README, Runbook 01 Step 0, and Runbook 02 updated to the two-step flow (preflight → setup-iis).

## [0.1.10] — 2026-06-24

### Added
- **`plan-certs.ps1`** — interactive (preflight-style) **wildcard certificate planner**. Scans every IIS site/binding, groups host names into the **minimum set of wildcard certs** by parent domain (so names sharing a parent collapse onto one cert; the apex is added as a SAN; multi-level names get their own `*.sub` cert), resolves the correct DNS zone via the Public Suffix List (handles `co.uk` etc.), checks the cert store for existing coverage (OK / renew-soon / missing), and prints the exact `wacs.exe` commands to generate what's missing. Self-elevates and runs via `irm https://xphox2.github.io/Cert-Man-Windows/plan-certs.ps1 | iex`.
- README Quick start and Runbook 02 now reference the planner. Verified the grouping/PSL logic against shared-parent, apex, multi-level, and `co.uk` host sets.

## [0.1.9] — 2026-06-24

### Added
- **GitHub Pages** publishing for a clean, stable one-liner URL:
  ```
  irm https://xphox2.github.io/Cert-Man-Windows/preflight.ps1 | iex
  ```
  Added `.nojekyll` so Pages serves the raw `.ps1` as-is (no Jekyll build). `preflight.ps1`'s self-relaunch URL, the README Quick start, and Runbooks 01/02 now use the Pages URL; the raw.githubusercontent URL remains as a documented fallback.

## [0.1.8] — 2026-06-24

### Fixed
- **"Output froze until I pressed Enter" under `irm | iex`.** Piping to `iex` yields a degraded console where `Read-Host` stalls. `preflight.ps1` now bootstraps like MassGrave: it downloads itself to a temp file and relaunches from `-File` in a fresh (elevated) window, giving a proper interactive console. This also replaces the old `irm|iex` self-elevation.

### Changed
- **Preflight is now scoped to ACME + DNS only** — removed the IIS role/module checks. Per the modular "one script per scenario" approach.
- **Added `scripts/Setup-IIS.ps1`** — installs the IIS role + management/scripting tools and optionally creates a site with host-name bindings. README Quick start and Runbook 01 Step 0 updated to use it alongside the preflight.

## [0.1.7] — 2026-06-24

### Fixed
- **Slow/hung win-acme download.** `Invoke-WebRequest` in Windows PowerShell 5.1 throttles large downloads via its progress bar (the 35 MB pluggable build could take minutes or appear to hang). `preflight.ps1` and `scripts/Install-WinAcme.ps1` now set `$ProgressPreference = 'SilentlyContinue'` and download via `System.Net.WebClient` — verified **35.6 MB in ~1 second**.
- **Wrong trimmed-vs-pluggable detection.** Both win-acme builds ship with 0 loose DLLs, so the previous DLL-count check could never pass. Detection now uses the reliable signal: `wacs.exe` size (pluggable ~40 MB vs trimmed ~19 MB; threshold 30 MB). An existing trimmed install is now correctly flagged and upgraded.
- `Install-WinAcmeInline` now does a clean reinstall (removes the old folder first) so a prior trimmed build leaves nothing stale. Confirmed end-to-end: the pluggable build self-reports as "pluggable, standalone" and exposes `--validation cloudflare` once the plugin is added.

## [0.1.6] — 2026-06-24

### Fixed
- **DNS-01 validation test failed with no logs.** Root cause: the installer fetched win-acme's **trimmed** build, which cannot load external DNS provider plugins, so `--validation cloudflare/azure/godaddy` failed instantly; the script also swallowed win-acme's output and pointed at the wrong log path.
  - `preflight.ps1` and `scripts/Install-WinAcme.ps1` now install the **pluggable** build.
  - `preflight.ps1` downloads the matching DNS provider plugin on demand before the test, **shows win-acme's output** (last 25 lines) on failure, and saves the full log to `C:\win-acme\preflight-dns-test.log`.
  - The win-acme readiness check now detects a **trimmed** install and offers to upgrade it to pluggable (so an existing trimmed install is auto-fixed on re-run).
- `scripts/Install-WinAcme.ps1` gains a `-DnsPlugin` parameter (cloudflare/azure/godaddy/route53/digitalocean) to fetch provider plugins during install. Runbook 02 plugin note updated.

## [0.1.5] — 2026-06-24

### Added
- **`preflight.ps1`** (repo root) — a self-contained, interactive, MassGrave-style one-liner:
  ```
  irm https://raw.githubusercontent.com/xphox2/Cert-Man-Windows/main/preflight.ps1 | iex
  ```
  Self-elevates, runs clean pass/fail checks, **prompts to auto-fix** missing pieces (installs the IIS role + win-acme inline), loops until green, then optionally runs an interactive DNS-01 validation test against Let's Encrypt staging. ASCII-only and BOM-free so it pipes cleanly to `iex`.

### Changed
- README gains a top-of-page **Quick start** with the one-liner; Runbook 01 Step 0 and Runbook 02 prerequisites now lead with it. The parameterized `scripts/Preflight-Check.ps1` remains for non-interactive/automation use.

## [0.1.4] — 2026-06-24

### Added
- **`scripts/Preflight-Check.ps1`** — a fresh-server readiness gate and setup helper. Verifies elevation/OS/PowerShell, the IIS role + WebAdministration module (installs with `-InstallIIS`), current IIS sites/bindings baseline, TLS 1.2, outbound reachability to Let's Encrypt (staging + prod) and the DNS provider API, win-acme presence (installs via `Install-WinAcme.ps1` with `-InstallWinAcme`), and per-domain DNS resolution. Includes an optional **DNS-01 validation test** that issues and then cancels a throwaway cert from Let's Encrypt **staging** (Cloudflare/Azure/GoDaddy) to prove DNS credentials, propagation, and CA reachability end-to-end. Prints READY / NOT READY and sets exit code accordingly. Verified running on Windows Server 2022 / PowerShell 5.1.

### Changed
- Runbook 01 gains a **Step 0 — Preflight**; Runbook 02 prerequisites lead with the preflight (including the DNS-01 staging test). README scripts entry updated.

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
