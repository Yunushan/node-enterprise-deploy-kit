# Changelog

## Unreleased

- Added a Next.js Node.js compatibility gate: Windows and Unix preflight/runtime checks now verify `NextjsMinimumNodeVersion` / `NEXTJS_MINIMUM_NODE_VERSION` (default `20.9.0`), status evidence records `minimumNodeVersion` and `nodeVersionSatisfied`, and host-evidence/release-readiness validators require that proof for real Next.js support claims.
- Added support-matrix Node.js runtime tier metadata so production-recommended Next.js targets are separated from experimental and community-package runtime targets, and propagated that tier through evidence plans, coverage reports, and evidence bundle manifests.
- Added production-runtime release readiness filters so coverage, bundle creation, and release signoff can be scoped to production-recommended Node runtime targets, selected evidence bundles archive only matching target rows, and release readiness can reject bundles containing experimental/community runtime evidence.
- Added scoped, warning-strict support evidence plan generation with `-TargetId`, `-Category`, `-ProductionRecommendedOnly`, and `-FailOnWarnings` so real-host dispatch checklists can match the intended support claim before collection begins.
- Aligned missing-coverage collection commands with the coverage warning policy so reports emit warning-strict host commands by default and warning-tolerant commands with `-AllowWarnings`.
- Hardened host-evidence target validation so a declared `supportTargetId` must be corroborated by collected OS/platform metadata before it can prove a support matrix row.
- Hardened strict Next.js host-evidence validation so collected platform metadata must also prove the Node.js runtime platform floor: Windows build, Linux kernel/glibc, or macOS version/architecture where those floors apply.
- Hardened support-evidence coverage so target-mismatched evidence is not counted as covering a matrix row.
- Hardened saved bundle verification and support-evidence coverage so stale or edited evidence without the required Next.js runtime platform floor is rejected or treated as missing coverage.
- Hardened host-evidence artifact import so target-mismatched evidence is rejected before canonical evidence filenames are written, even when full validation is skipped.
- Hardened support-evidence bundle verification so archived bundles reject target-mismatched evidence even when the manifest, hashes, and evidence JSON agree on the wrong target.
- Fixed strict-warning host evidence collection so the manual `host-evidence` workflow can pass `fail_on_warnings` through both Windows `status.ps1` and Unix `status-node-app.sh` collectors.
- Hardened real-host evidence planning and coverage reports so every generated Windows, Linux, and macOS workflow dispatch entry is validated by the same guarded `host-evidence` input validator before release tooling accepts the collection guidance.
- Hardened `host-evidence` workflow dispatch validation so `evidence_name` must match the expected target/mode/service/proxy artifact name, including the `-fallback` suffix for fallback service-manager evidence.
- Added exact single-row host-evidence validation commands to support evidence plans and missing-coverage reports, and allowed `Test-HostEvidence.ps1` to validate a single JSON evidence file directly.
- Preserved per-row collection, workflow dispatch, and host-evidence validation commands in release-readiness JSON so final support signoff artifacts remain reproducible from the saved bundle.
- Added regression coverage for CSV and table evidence reports so validation commands stay visible in machine-readable exports and the default console missing-coverage view.
- Added first-class Next.js deployment controls, standalone/next-start layout validation, Windows/Linux standalone artifact package and validation helpers, live runtime layout checkers, automatic import-time Next.js package validation for standalone and next-start artifacts, artifact expected-path checks, Unix deployment archive link-entry hardening, automated standalone and next-start support smoke tests, macOS CI smoke coverage, and a dedicated Next.js deployment guide.
- Added mode-aware Windows and Unix package-helper support for full-app Next.js `next-start` artifacts, including helper-level validation that `package.json`, `.next/BUILD_ID`, and `node_modules/next/dist/bin/next` are present before release, plus Unix-side exclusion of `node_modules/.bin` symlink shims from deployable archives.
- Added validated Windows and Unix `next-start` example configs plus macOS `launchd` and BSD `bsdrc` example env files, and included those examples in release-package and LF line-ending gates.
- Hardened the main repository verifier so it runs ShellCheck when available and explicitly reports when local ShellCheck is skipped.
- Added Ansible mode-aware Next.js package expected-path defaults and early role validation for invalid Next.js framework/runtime/mode combinations.
- Hardened Next.js `next-start` service launches by validating the `next start` subcommand, hostname binding argument, and Next CLI start path across preflight, runtime layout checks, status, diagnostics, and Ansible defaults.
- Added opt-in Next.js multi-instance preflight gates for Server Actions encryption keys and deployment IDs, plus a Unix `status-node-app.sh` operational verdict for Linux, macOS, and BSD hosts.
- Added safe JSON status evidence output for Windows and Unix-like host checks so post-deploy and long-uptime verification can be archived without dumping environment values or raw logs.
- Added host evidence validation tooling and documentation for checking collected Windows, Linux, macOS, and BSD status JSON before making real support claims.
- Added structured Next.js runtime layout evidence to status JSON plus a `-RequireNextJs` host-evidence gate.
- Added structured reverse-proxy health evidence to status JSON plus a `-RequireReverseProxy` host-evidence gate.
- Added structured deployment identity evidence to status JSON plus a `-RequireDeploymentIdentity` host-evidence gate.
- Made `.next/BUILD_ID` a required Next.js package/runtime proof point so artifact imports and status evidence can identify the running build.
- Added package-import deployment manifests with package filename, SHA256, import timestamp, and Next.js build ID in safe status evidence.
- Hardened status JSON and host-evidence validation to reject raw host/config/runtime paths and raw machine identity fields.
- Added Windows IIS site/path/binding evidence plus preflight duplicate-binding conflict detection so wrong-folder and old-site deployments are caught before release signoff.
- Added Unix-like Nginx/Apache/HAProxy/Traefik config-file evidence and managed template markers so reverse-proxy support claims prove both traffic and managed proxy configuration.
- Added structured configured-port ownership evidence for Windows and Unix-like status JSON, and made host-evidence validation require that the app port is owned by the configured service.
- Added structured HTTP health evidence for Windows and Unix-like status JSON, and made host-evidence validation require a successful checked health probe.
- Added structured service uptime evidence for Windows and Unix-like status JSON, and made host-evidence validation require service process uptime plus the requested minimum uptime window when configured.
- Added structured recurring health-monitor evidence for Windows and Unix-like status JSON, and made host-evidence validation require recent successful monitor history with zero consecutive failures and zero recent monitor restarts.
- Added systemd healthcheck timer evidence to Unix-like status JSON, and made host-evidence validation require timer checked/exists/active/enabled proof when `scheduleType=systemd-timer`.
- Added a Unix healthcheck scheduler installer for launchd and cron-style hosts, wired `deploy.sh` to use it, and expanded status evidence/validation for `launchd-timer` and `cron` schedules.
- Hardened WinSW service environment defaults and Windows service account handling.
- Hardened IIS reverse proxy rendering with ARR proxy setup, forwarded headers, health proxy path, WebSocket checks, and timeout validation.
- Improved Windows status and diagnostics with host uptime, service uptime thresholds, port ownership proof, health latency, health-check freshness, and operational verdicts.
- Added Windows managed-backup listing and rollback helpers for WinSW files, IIS web.config, and scheduled health-check task exports.
- Added release package hygiene checks, sanitized release zip builder, deterministic Ansible syntax settings, CI Ansible tooling setup, and Ansible collection requirements.
- Added Windows and Linux preflight hardening warnings for public bind addresses, plaintext proxy paths, broad service accounts, user-profile runtime paths, and secret-like runtime key names.
- Added documentation consistency checks for local Markdown links, README anchors, and documented release entrypoints.
- Added Linux Apache reverse proxy installer and virtual host template.
- Added HAProxy and Traefik reverse proxy installers and templates.
- Added Apache Tomcat WAR deployment mode.
- Added Linux System V and OpenRC service templates.
- Added launchd and BSD rc service templates for macOS and BSD targets.
- Added Linux service manager selection for scripts and Ansible.
- Expanded Unix-like support notes for Oracle Linux, CentOS, CentOS Stream, Fedora, Linux Mint, FreeBSD, OpenBSD, NetBSD, and macOS.
- Hardened Linux health-check state handling with a root-owned state directory and non-executable state parsing.
- Made Linux diagnostics summary-only by default with explicit raw-detail opt-in.
- Added a Turkish companion README while keeping the English README as the default project entry point.
- Made Linux reverse proxy templates use explicit forwarded scheme/port variables for upstream TLS truthfulness.
- Added a safety opt-in before replacing an existing main HAProxy config.
- Centralized Linux config loading and aligned runtime environment key parsing across preflight and install flows.
- Added Traefik dynamic config validation through a temporary file-provider config.
- Expanded CI with a Windows verification job and optional ShellCheck step.
- Hardened Ansible sample config defaults by keeping SSH host key checking enabled.
- Clarified that Windows reverse proxy automation supports IIS or none, while Apache, HAProxy, and Traefik installers are Linux/Unix helpers.
- Added safe application package import before deployment: `.zip` on Windows and `.zip`, `.tar.gz`, `.tgz`, or `.tar` on Linux/Unix.
- Added automatic pinned WinSW download for Windows service deployments when `tools\winsw\winsw-x64.exe` is missing.
- Fixed Windows health-check scheduled task registration by avoiding Task Scheduler's invalid maximum repetition duration.
- Added a Windows latest-release deploy helper for RDP/VPN workflows that selects the newest timestamped release folder without moving the current live folder.

## v1.0.0

Initial GitHub-ready release.

- Windows WinSW service deployment.
- Windows IIS reverse proxy template.
- Windows scheduled health check.
- Linux systemd service deployment.
- Linux Nginx reverse proxy template.
- Linux systemd timer health check.
- Diagnostics and redaction scripts.
- Optional Ansible roles.
- MIT license.
