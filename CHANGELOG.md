# Changelog — SSL Certificate Rotation Automation Handbook

All notable changes to this operations handbook are documented here. Newest entries on top.

## [0.1.40] — 2026-06-29

### Changed (`generate-cert.ps1` — make clear the production prompt is where DNS records appear)
- For **manual / acme-dns** methods, the TXT (or CNAME) records can only be displayed **after** the live order is created, because the challenge tokens do not exist until then. Operators were answering **No** at the `Generate on PRODUCTION now?` prompt expecting to see the records first, so nothing was requested. The prompt is reworded to **`Proceed and show the DNS record(s) to create now? [y/N]`** with a note that **nothing is issued until you add the records and DNS verifies** — saying Yes is the step that displays the records and starts the guided, pre-validated wait. No behavior change; wording/clarity only.

## [0.1.39] — 2026-06-29

### Fixed (`generate-cert.ps1` option 7 — no TXT shown / no success / "prompts individually")
- **Root cause (verified against a live win-acme install):** the one-time method used win-acme's `--validation script` plugin, which runs the create script as a **hidden subprocess whose console output win-acme does not surface** — so the operator never saw the TXT record to add and never saw a success/verify message. It looked like it did nothing.
- **Rewrote option 7 to use win-acme's NATIVE `--validation manual`**, which **prints each TXT record to the console** (`Record: _acme-challenge.… / Type: TXT / Please press <Enter>…`), combined with win-acme's **built-in DNS pre-validation** tuned via `settings.json`: `DnsServers` set to **public resolvers** (8.8.8.8 / 1.1.1.1 / 9.9.9.9 / 8.8.4.4), `PreValidateDns=true`, and `PreValidateDnsRetryCount`/`Interval` sized to the minutes you choose (default 30). After you press Enter, win-acme resolves the zone's **authoritative** nameservers via those public servers and re-checks the TXT every 30 s until it is visible **before** asking Let's Encrypt to validate — so it does not submit (and cannot fail) while propagation is still in flight, and it never reads the local cache. This is simpler, fully visible, and writes no scripts (so it also stays clear of behavioral AV).
- **Clarified multi-name issuance.** Entering several names (e.g. `domain.com, *.domain.com, *.1.domain.com`) produces **ONE multi-SAN certificate**; DNS-01 requires **one TXT record per name**, so win-acme prompts for several in sequence — that is expected, not separate certs. The script now says so up front.
- **Removed** the now-unused `scripts/Wait-AcmeDnsRecord.ps1` and `scripts/Clear-AcmeDnsRecord.ps1` (added in 0.1.38) — the validation path no longer generates or downloads any script.

## [0.1.38] — 2026-06-29

### Fixed (antivirus / "Block at First Sight" false positive on `generate-cert.ps1`)
- **Root cause:** `generate-cert.ps1` previously **synthesized executable PowerShell at runtime** (it wrote `manual-dns-verify.ps1` / `manual-dns-cleanup.ps1` to disk and had win-acme run them) and embedded that code as a large here-string with an effectively-infinite `while ($true)` DNS-polling loop. Static scanning was clean (AMSI whole-file CLEAN, Defender file-scan of the artifacts found no threats), but Defender's **Block at First Sight** (cloud reputation + behavioral ML) flags this *generate-a-script-then-execute-it* "dropper" pattern on a brand-new, zero-prevalence file — whereas `preflight.ps1` (long-standing, never writes scripts) is trusted. That is the difference between the two scripts.
- **Fix:** the manual one-time DNS verify/cleanup hooks are now **committed repo files** — [`scripts/Wait-AcmeDnsRecord.ps1`](scripts/Wait-AcmeDnsRecord.ps1) and [`scripts/Clear-AcmeDnsRecord.ps1`](scripts/Clear-AcmeDnsRecord.ps1) — that `generate-cert.ps1` **downloads** (GitHub Pages, raw fallback) and `Unblock-File`s, exactly like the existing `scripts/*.ps1` helpers. The main script no longer writes any executable PowerShell at runtime, and the embedded code-as-string block is gone, so it no longer trips behavioral AV. Tunables (`WaitMinutes` / `PollSeconds` / `QuorumPublic`) are passed as named script parameters via win-acme `--dnscreatescriptarguments`.
- **Also:** the polling loop is now a **bounded deadline loop** (default ceiling 12 h, configurable) instead of `while ($true)` — same "never fail early, keep waiting" behavior, without the infinite-loop heuristic. The authoritative-NS + public-resolver verification logic is unchanged.

## [0.1.37] — 2026-06-29

### Added (`generate-cert.ps1` — generate + export, no IIS)
- **New standalone script `generate-cert.ps1`** for a dedicated UTIL / issuer server: it does **NOT** scan or bind IIS ("the loading part"). You **type** the host name(s); it validates via DNS-01 on live Let's Encrypt and **exports a password-protected PFX** (default `C:\win-acme\pfx`) you copy out to the servers/devices that actually serve it. Runs like the others: `irm https://xphox2.github.io/Cert-Man-Windows/generate-cert.ps1 | iex`. Self-elevates, loops to issue several certs, optionally also imports into `LocalMachine\My`, and can install the post-renewal PFX copy hook.
- **Multiple wildcards + apex on ONE certificate.** The host prompt accepts comma-separated names at any wildcard depth, e.g. `domain.com, *.domain.com, *.1.domain.com, *.2.domain.com, *.3.domain.com`. All names collapse to a single DNS zone, so DNS credentials are requested once.
- **New DNS method `7) Manual + auto-verify (ONE-TIME)`** built on win-acme's DNS **validation-script** plugin. win-acme **blocks until our generated verify script confirms propagation**, so it never submits to Let's Encrypt early — meaning **the token is never invalidated and you add the TXT record exactly once** (fixes the classic "press Enter too soon → new token → re-edit DNS" loop). The verify loop polls **authoritative nameservers** (what Let's Encrypt actually queries) **plus six public resolvers** (8.8.8.8 / 8.8.4.4 / 1.1.1.1 / 1.0.0.1 / 9.9.9.9 / 208.67.222.222) — explicitly **not** local DNS — clearing the local client cache each pass. On timeout it **extends and keeps waiting instead of failing**, so an order is never aborted out from under you. The TXT record is also saved to `%TEMP%\MANUAL-DNS-TODO.txt`. This method passes **`--notaskscheduler`** (one-time cert, no renewal task) since manual DNS can't auto-renew unattended.

## [0.1.36] — 2026-06-25

### Documentation accuracy pass (audited all docs + flows against the current scripts)
- **Runbook 02:** DNS menu corrected to the real **6 options** (acme-dns / Cloudflare / Azure / GoDaddy / Other provider / Manual) — was described as 4. §A rewritten so the **win-acme-native CNAME-following** path (`AllowDnsSubstitution`, no server, what `setup-iis.ps1` uses) is first-class alongside Posh-ACME `-DnsAlias` and self-hosted acme-dns; "acme-dns is Linux-only" corrected to "no native Windows binary; runs as a Docker container." PFX export + per-domain DNS + copy hook now noted.
- **README:** `setup-iis.ps1` description now mentions per-domain DNS keys, PFX export (`C:\win-acme\pfx`), and the post-renewal copy hook.
- **00:** added that win-acme follows the `_acme-challenge` CNAME automatically (no acme-dns server needed); acme-dns is one of several delegation targets.
- **03:** stale `C:\certs` PFX default corrected to `C:\win-acme\pfx`; added the PFX-distribution + password-persistence (`EncryptConfig`/DPAPI) + copy-hook-runs-as-SYSTEM note.
- **08:** removed the incorrect `--source iis` wildcard rebind suggestion (wildcards require `--source manual … --installationsiteid`, or use `setup-iis.ps1`).
- **09:** repositioned acme-dns as **one option** (win-acme CNAME-following / Posh-ACME `-DnsAlias` need no server); flagged `auth.acme-dns.io` as test-only; corrected the "run acme-dns.exe on Windows" line (no official Windows binary — use Docker). Fixed a broken §A anchor link.
- **Diagrams:** `runbook02-dns01.mmd` now shows all 6 DNS methods (re-rendered SVG/PNG).
- **Training deck:** added the missing **Runbook 09 / acme-dns** slide (now 9 slides), updated the CNAME slide to note win-acme follows the CNAME automatically, renumbered footers, rebuilt the PDF.

## [0.1.35] — 2026-06-25

### Fixed (don't delete exported certs on win-acme reinstall)
- **`preflight.ps1`'s win-acme (re)install used to wipe the entire `C:\win-acme` folder** (`Remove-Item $WinAcmePath -Recurse`), which would have deleted `C:\win-acme\pfx` (exported certs), the post-renewal hook, and the cache whenever win-acme was upgraded/repaired. It now removes **only win-acme's own binaries/config/logs** and **preserves** `pfx\`, `.cmw-cache`, and `post-renew-copy.*`. So exported certs survive win-acme upgrades. (win-acme's own extract-over updates never deleted them; this was our clean-reinstall step.)

## [0.1.34] — 2026-06-25

### Changed
- PFX export default is now **`C:\win-acme\pfx`** (a `pfx` subfolder of the win-acme install dir), keeping exported certs out of the program-file root while still under the single win-acme tree. The copy-hook script + log remain at `C:\win-acme\`. `scripts/Copy-RenewedPfx.ps1` example `-SourceDir` updated to `C:\win-acme\pfx`.

## [0.1.33] — 2026-06-25

### Changed
- **Everything now lives in one folder: the win-acme install dir (`C:\win-acme`).** The PFX export default is now `$WinAcmePath` (was `C:\CertMan\pfx`), and the post-renewal copy hook script + its log are written there too (`C:\win-acme\post-renew-copy.ps1` / `.log`, was `C:\CertMan\...`). No more separate `C:\CertMan` tree — cache, logs, certs, PFX, and the hook are all colocated with win-acme. `scripts/Copy-RenewedPfx.ps1` default `-LogFile` updated to match.

## [0.1.32] — 2026-06-25

### Fixed (prevent the staging task instead of deleting it)
- The staging dry-runs in `preflight.ps1`, `setup-iis.ps1`, and `scripts/Preflight-Check.ps1` now pass win-acme's **`--notaskscheduler`** flag, so win-acme **never creates** the throwaway `acme-staging` scheduled task in the first place (cleaner than the v0.1.31 delete-after-the-fact approach, which is kept as a safety net to sweep orphans from older runs). Production issuance is unchanged — it still gets its renewal task. Root cause: win-acme auto-creates a scheduled task per ACME endpoint on every successful issuance; the staging dry-run is a real (staging) issuance, so it was triggering that.

## [0.1.31] — 2026-06-25

### Fixed
- **Orphaned `win-acme renew (acme-staging-v02...)` scheduled task.** win-acme creates a scheduled task per ACME endpoint on issuance. Our staging dry-runs (`preflight.ps1`, `setup-iis.ps1`, `scripts/Preflight-Check.ps1`) `--cancel` the staging *renewal* but win-acme left the now-empty **staging task** behind — so users saw two jobs (a real production one plus a dead staging one). All three scripts now remove the orphaned staging task after the dry-run (matched on the `acme-staging` endpoint name, so the production `acme-v02` task is never touched).
- To clean an existing orphan on a machine that already ran a staging test: `Get-ScheduledTask | ? { $_.TaskName -match 'acme-staging' } | Unregister-ScheduledTask -Confirm:$false` (elevated).

## [0.1.30] — 2026-06-25

### Added (per-domain DNS credentials)
- **`setup-iis.ps1` now selects DNS per registrable domain.** It detects the distinct zones across the planned certs (e.g. `xphox.net`, `xphox.com`, `technicallabs.org`) and — when there's more than one — asks whether **one provider/API key manages them all** or you need **a different provider/key per domain**. Each cert then issues, dry-runs (staging), and renews using its own domain's DNS selection; plugins install once per distinct provider; staging-first and the manual/auto-renew notes are evaluated per cert. Single-domain runs are unchanged (one prompt).

## [0.1.29] — 2026-06-25

### Added (auto-distribute renewed certs)
- **Post-renewal copy hook** in `setup-iis.ps1`. When PFX export is on, it offers to auto-copy the PFX to other devices after **every** renewal: it generates a self-contained `C:\CertMan\post-renew-copy.ps1` (destinations baked in — no parameter-quoting issues) and wires it as a win-acme post-renewal step (`--installation iis,script --script ...`). Logs to `C:\CertMan\post-renew-copy.log`. Warns that renewals run as SYSTEM, so UNC targets must allow the computer account (else use a local share the devices pull from).
- **`scripts/Copy-RenewedPfx.ps1`** — standalone parameterized version of the same hook for manual win-acme wiring (`-SourceDir`, `-Destinations`, `-LogFile`).

## [0.1.28] — 2026-06-25

### Added
- **`setup-iis.ps1` PFX export option** — after planning the certs, it now offers to also export a `.pfx` of each cert (default `C:\CertMan\pfx`, password-protected) alongside the IIS binding, by adding `pfxfile` to the win-acme store set (`--store certificatestore,pfxfile`). The PFX is **refreshed on every renewal**, so the same cert can be copied to **other devices / non-IIS services** (then bound with the `scripts\Deploy-*.ps1` helpers). Per-cert and final output print the PFX paths.

### Confirmed
- **win-acme follows `_acme-challenge` CNAMEs** to a delegated zone automatically (`Validation.AllowDnsSubstitution = true` by default) — so CNAME delegation to a zone you control (e.g. a Cloudflare zone) works directly with win-acme/`setup-iis.ps1`, no acme-dns server and no Posh-ACME required. Sources: [win-acme settings](https://www.win-acme.com/reference/settings), [DNS validation](https://www.win-acme.com/reference/plugins/validation/dns/).

## [0.1.27] — 2026-06-25

### Added (Windows/PowerShell-native path for no-API registrars)
- **`scripts/Issue-DnsAlias.ps1`** — issue a Let's Encrypt cert for a domain whose registrar has **no DNS API** (Network Solutions, etc.) using **Posh-ACME DNS challenge aliases**. You delegate `_acme-challenge` (one CNAME) to a delegation zone you control; Posh-ACME writes the TXT there via that provider's plugin. **No acme-dns server, no Linux, no Docker** — pure Windows PowerShell. Provider-agnostic (Cloudflare / Azure / Route53 / any Posh-ACME plugin, chosen at runtime), staging-first by default, prints the exact one-time CNAME, and optionally registers an unattended renewal task.
- Runbook 02 §A rewritten to lead with this (delegate-to-a-zone-you-control = recommended Windows/PowerShell path) and reposition **acme-dns as the alternative** (a dedicated, Linux-only server). Clarifies that `auth.acme-dns.io` is a public test instance, not production-safe.

## [0.1.26] — 2026-06-25

### Fixed
- **acme-dns aborted with `missing --acmednsserver`.** win-acme's acme-dns plugin **requires** the `--acmednsserver <url>` argument (it does not prompt for it under our unattended flags). The acme-dns menu option in `preflight.ps1` and `setup-iis.ps1` now asks for the acme-dns server URL (default `https://auth.acme-dns.io`) and passes `--acmednsserver`.

## [0.1.25] — 2026-06-25

### Fixed (support every DNS option, no per-provider guessing)
- **"Other provider" now lets win-acme prompt for credentials** instead of asking you to hand-type each plugin's argument names (which the scripts would have been guessing). It downloads the chosen plugin and runs `--validation <plugin>` interactively, so **all ~20 win-acme DNS plugins work** without us hard-coding any provider's argument names. These certs still auto-renew (win-acme stores the credentials).
- Verified the guided providers against win-acme docs: **Azure** (`--azuresecret`, `--azuretenantid`, `--azureclientid`, `--azuresubscriptionid`, `--azureresourcegroupname`) and **GoDaddy** (`--apikey`, `--apisecret`) are correct; Cloudflare was already confirmed by live test.
- Renewal/auto-renew messaging in `setup-iis.ps1` now distinguishes **Manual** (no auto-renew) from acme-dns / generic-plugin providers (which do auto-renew) — previously any interactive provider was mislabeled "manual".

## [0.1.24] — 2026-06-25

### Added
- **`scripts/Deploy-AcmeDns.ps1`** — one-command acme-dns server deploy: generates `config.cfg` from parameters, runs the official container with the correct ports (53/udp+tcp, 80, 443) and persistent volumes, verifies it's up, and prints the exact DNS delegation records (NS + glue A) to add. Cross-platform (Docker; Windows PowerShell or `pwsh` on Linux); `-ApiTls none` for a quick HTTP-only test.
- **`acme-dns/docker-compose.yml` + `config.cfg.example`** — declarative alternative for compose users. Runbook 09 Step 3 now leads with the script, then compose, then plain Docker. README scripts list updated.

## [0.1.23] — 2026-06-25

### Added
- **`09-AcmeDNS-Server-Setup.md`** — full guide to self-hosting an **acme-dns** server (the server side of the no-API-registrar path): DNS subdomain delegation (NS + glue A), `config.cfg` reference, run via Docker / systemd / Windows (NSSM), hardening (`allowfrom` CIDR, `disable_registration`, firewall, DB backup), verification, and per-customer onboarding (register → one CNAME → wire win-acme/Posh-ACME). Covers the **MSP model** (one server, every customer CNAMEs to it). New architecture diagram (`docs/diagrams/runbook09-acmedns.*`); README + diagrams index + Runbook 02 §A linked. Sourced from [acme-dns](https://github.com/acme-dns/acme-dns).

## [0.1.22] — 2026-06-25

### Added (DNS provider coverage — works with any registrar)
- **acme-dns option** in `preflight.ps1` and `setup-iis.ps1`. The universal, auto-renewing answer for registrars with **no usable API** (e.g. **Network Solutions / MyDomain.com**): win-acme's built-in `--validation acme-dns` (interactive registration, one-time `_acme-challenge` CNAME, then automatic). The preflight DNS test validates it end-to-end against staging.
- **"Other provider"** option that lists **win-acme's full ~20 in-box DNS plugins** (fetched live from the release — Route53, DNSMadeEasy, DigitalOcean, Linode, Hetzner, LuaDNS, NS1, RFC2136, TransIP, Aliyun, Tencent, …), auto-downloads the chosen plugin, and accepts its arguments. No longer limited to 3 providers.
- Shared `Get-DnsValidation` selector in both scripts (acme-dns / Cloudflare / Azure / GoDaddy / Other / Manual); interactive paths (acme-dns, Manual) run win-acme un-captured so its prompts are visible.

### Changed
- Runbook 02 **§A rewritten** as an **acme-dns** section (Network Solutions example, one-time CNAME, self-host vs public `auth.acme-dns.io`, MSP "one server, all customers CNAME to it" model). Provider-coverage note added; README updated. Sourced from [acme-dns](https://github.com/acme-dns/acme-dns) and [win-acme acme-dns docs](https://www.win-acme.com/reference/plugins/validation/dns/acme-dns).

## [0.1.21] — 2026-06-25

### Changed (drop the third-party Acmebot dependency — build it ourselves)
- **Removed the community "Acmebot" Functions app** from the handbook. Our principle, now stated explicitly: we use ACME client **tools** (win-acme on Windows, **Posh-ACME** on Azure) wrapped in **our own scripts** — we do **not** deploy third-party **applications** into the tenant.
- **Azure Let's Encrypt is now our `Renew-PoshACME.ps1` Azure Automation runbook** ([Runbook 05](05-Azure-PoshACME-Runbook.md)), promoted from "alternative" to the path. Runbook 04 is now **`04-Azure-WebApp-Certs.md`** (renamed): decide-first — free managed cert for a single hostname, our Posh-ACME runbook for wildcard/export/multi-service.
- Updated the master decision-flow diagram (Azure → free managed cert **or** Runbook 05; no Acmebot nodes), README tables/tools/notes, and the Acmebot references in Runbooks 00/06/07. Removed the Acmebot architecture diagram; re-rendered the master + monitoring diagrams and rebuilt the training deck (now 9 pages).

## [0.1.20] — 2026-06-25

### Changed (Azure guidance is now decision-first)
- **Runbook 04 leads with the decision, not Acmebot.** Azure App Service includes a **free, auto-renewing App Service Managed Certificate** (reissued ~6-monthly, 45 days before expiry, bindings updated automatically). For a **single hostname you should use that and skip Let's Encrypt** — the runbook now opens with that decision and a one-step "free managed cert" path. Acmebot/Let's Encrypt is positioned as the answer **only** for what the free cert can't do: **wildcards**, **exportable/shared** certs (App Gateway, Front Door, VM, on-prem), CA consistency, private DNS, or App Service Environment.
- **README** updated to match: the master decision-flow diagram now routes Azure *single hostname → free managed cert* (vs *wildcard/export → Acmebot*), the quick-lookup table and Azure note are decision-first, and the diagram SVG/PNG + training-deck PDF were re-rendered. Sourced from [Microsoft Learn](https://learn.microsoft.com/en-us/azure/app-service/configure-ssl-certificate) (ASMC limits: no wildcard, not exportable, no private DNS / ASE / client-cert).

## [0.1.19] — 2026-06-24

### Documentation accuracy pass (sync docs/flows with the validated implementation)
- **Runbook 01:** the manual download note now says **pluggable** (not trimmed) build, and Step 5 verification checks **both `My` and `WebHosting`** stores (win-acme's IIS install lands in `WebHosting`).
- **Runbook 02:** corrected the claim that the preflight "installs IIS" — the preflight is **ACME + DNS only**; the IIS role + wildcard generation is the `setup-iis.ps1` step. Added the Manual provider to the prompt list.
- **Runbook 08:** the wildcard takeover command now uses the proven `--source manual --host "*.x" --installation iis --installationsiteid <id>` pattern (not `--source iis` with a wildcard), added a `WebHosting`-store note, and the staged variant now finds/binds the cert from whichever store it's in. Points to `setup-iis.ps1` for multi-site binding.
- **`scripts/Inventory-Certs.ps1` / `Remove-OldCert.ps1`:** now scan **both `My` and `WebHosting`** (and report/operate on the cert's actual store) so IIS-installed certs aren't invisible to inventory/removal.

## [0.1.18] — 2026-06-24

### Added
- **`setup-iis.ps1` Manual DNS option (any 3rd-party provider).** A 4th DNS choice runs win-acme's built-in `--validation manual`: it displays the `_acme-challenge` TXT record, you create it at any DNS provider, then continue — interactively (output is shown live, not captured). The staging dry-run is skipped for manual (to avoid creating TXT records twice), and the script clearly warns that **manual certs do not auto-renew unattended** and points to CNAME delegation (Runbook 02 §A) for hands-off renewal on a 3rd-party DNS. Runbook 02 updated.

## [0.1.17] — 2026-06-24

### Fixed
- **Multi-site wildcards left partially bound.** `--installationsiteid` makes win-acme bind a wildcard only within **one** IIS site, so other sites hosting names under the same wildcard were left without HTTPS bindings — and the plan still showed the cert as "OK" because a cert existed. Added a **binding reconciliation pass**: `Get-MissingBindings` checks every covered host on every site for a missing/incorrect HTTPS binding, the plan now flags unbound hosts, and `Repair-Bindings` fixes them **locally (no certificate requests)**. Reconciliation runs both standalone (offered whenever unbound covered hosts are found, even if nothing needs issuing) and automatically after each production issuance, so a wildcard's hosts are fully bound across all sites.

## [0.1.16] — 2026-06-24

### Changed (CTO pass: minimize Let's Encrypt rate-limit burn during testing)
- **Staging validation memory.** After a base passes the staging dry-run, a 7-day marker is written under `C:\win-acme\.cmw-cache`; subsequent runs **skip re-testing** that base on staging, so iterative runs don't keep burning staging limits.
- **Rate-limit budget panel + free-review gate.** Before anything is requested (or credentials entered), the script now shows the new certificates it would request **grouped by registered domain**, restates the Let's Encrypt limits (50/domain/week, 5 duplicate/week, 5 failed-validations/hour), and requires an explicit `Proceed to generate? [y/N]` — reviewing the plan now costs nothing.
- Reinforced existing protections in comments: only `NEED`/`WARN` certs are issued (already-valid certs in `My`/`WebHosting` are skipped), and `--force` is never used so win-acme reuses its 24h cache (re-running within a day requests nothing new).

## [0.1.15] — 2026-06-24

### Fixed
- **`setup-iis.ps1` reported FAIL even when issuance + binding succeeded.** win-acme installs IIS certs into the **`WebHosting`** store, but the script's coverage check only searched `My`. `Find-NewestCovering` now searches both `My` and `WebHosting` (so the plan also detects already-installed certs), and the production result is now gated on win-acme's **exit code** (the source of truth) rather than a store lookup.
- **Added `Certificate not found` to the transient-retry set.** A post-finalize `acme:error:malformed "Certificate not found"` (seen once on one of three back-to-back orders) is transient; `Invoke-WacsRetry` now retries it.
- Multi-site wildcard binding now uses the certificate's actual store (`WebHosting`) instead of assuming `My`.

## [0.1.14] — 2026-06-24

### Fixed
- **`setup-iis.ps1` production issuance aborted with `missing --installationsiteid`.** For a wildcard with `--source manual`, win-acme's IIS installation plugin **requires** `--installationsiteid`; without it, win-acme aborts during plugin setup **before** ordering (so no cert is issued and no rate limit is consumed). The script now captures each IIS site's **id** during the scan, passes `--installationsiteid <id>` for the site hosting each wildcard's bindings, and — if a wildcard's hosts span multiple sites — binds the extra sites explicitly via `New-WebBinding`/`AddSslCertificate`.

## [0.1.13] — 2026-06-24

### Fixed
- **`setup-iis.ps1` false-fails on transient Let's Encrypt staging errors.** Staging can return `ServiceUnavailable` / `{"error":"rateLimited","detail":"Service busy; retry later."}` at the finalize step under back-to-back issuance, even though DNS-01 validation already succeeded. Added `Invoke-WacsRetry`, which retries (up to 2×, 15 s apart) **only** on those transient errors — not on real failures (bad DNS token, duplicate-cert rate limit). Applied to both the staging dry-run and production issuance.

## [0.1.12] — 2026-06-24

### Added
- **`setup-iis.ps1` staging-first toggle.** Before any production issuance, it offers a **Let's Encrypt STAGING dry-run** that validates DNS-01 end-to-end for each planned cert (issues + discards a test cert, no rate-limit cost, nothing bound). If any staging test fails, **production is not touched** and it tells you why; only when all pass does it ask to proceed to production.

### Changed
- Production issuance now uses `--installation iis` so win-acme **binds the covered hosts and re-binds them on every future renewal** (the previous one-time manual binding wouldn't survive a renewal). The provider/token is collected once and reused for both staging and production.

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
