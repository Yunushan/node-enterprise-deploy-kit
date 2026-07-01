<p align="center">
  <img src="docs/assets/logo.svg" alt="Node Enterprise Deploy Kit logo" width="140" />
</p>

<h1 align="center">Node Enterprise Deploy Kit</h1>

<p align="center">
  <strong>Cross-platform, enterprise-style deployment kit for Node.js / Next.js / React applications on Windows and Unix-like hosts, with optional Tomcat WAR deployment, service management, reverse proxy templates, health checks, diagnostics, and Ansible automation.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="windows" src="https://img.shields.io/badge/windows-10%20%7C%2011%20%7C%20Server%202012--2025-0078D4.svg">
  <img alt="linux" src="https://img.shields.io/badge/linux-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Fedora%20%7C%20Alpine-success.svg">
  <img alt="unix" src="https://img.shields.io/badge/unix-BSD%20%7C%20macOS-lightgrey.svg">
  <img alt="service managers" src="https://img.shields.io/badge/service-WinSW%20%7C%20systemd%20%7C%20System%20V%20%7C%20OpenRC%20%7C%20launchd%20%7C%20bsdrc-orange.svg">
  <img alt="reverse proxy" src="https://img.shields.io/badge/proxy-IIS%20%7C%20Nginx%20%7C%20Apache%20%7C%20HAProxy%20%7C%20Traefik-6f42c1.svg">
</p>

<p align="center">
  <strong>English</strong> | <a href="README.tr.md">Türkçe</a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#what-this-solves">What this solves</a> •
  <a href="#supported-platforms">Supported Platforms</a> •
  <a href="#deployment-modes">Deployment Modes</a> •
  <a href="docs/NEXTJS_DEPLOYMENT.md">Next.js</a> •
  <a href="docs/REACT_DEPLOYMENT.md">React</a> •
  <a href="docs/ANSIBLE.md">Ansible</a> •
  <a href="docs/RUNBOOK.md">Runbook</a> •
  <a href="docs/HOST_VERIFICATION.md">Host Evidence</a> •
  <a href="docs/SUPPORT_MATRIX.md">Support Matrix</a> •
  <a href="docs/VARIABLES.md">Variables</a> •
  <a href="docs/BACKUP_RESTORE.md">Backup</a> •
  <a href="docs/RELEASE.md">Release</a> •
  <a href="docs/TROUBLESHOOTING.md">Troubleshooting</a> •
  <a href="docs/HARDENING.md">Hardening</a>
</p>

---

## What this solves

Many production Node.js deployments become fragile because the app is started manually, tied to a logged-in user session, controlled by a broken PM2 configuration, or exposed directly without a stable reverse proxy and health checks.

This project provides a clean, repeatable deployment pattern:

```text
Client
  |
  v
IIS / Nginx / Apache / HAProxy / Traefik / existing load balancer
  |
  v
127.0.0.1:<APP_PORT>
  |
  v
Node.js / Next.js / React app running as a real service, or a Tomcat WAR deployment
  |
  v
Rotated logs + health check + auto-restart + diagnostics
```

Recommended default:

```text
Windows: IIS + WinSW Windows Service + scheduled health check
Unix:    Nginx, Apache, HAProxy, or Traefik + managed service + health-check scheduler
```

This repository contains no private hostnames, secrets, credentials, IP addresses, or customer data. All sensitive values are variables.

---

## Verify Before Deploy

Run the repository verification check before handing the kit to a server or
opening a pull request:

```powershell
.\scripts\dev\Test-Repository.ps1
```

It checks PowerShell syntax, Linux shell syntax, Unix shell portability
patterns, platform-family mapping for Linux/macOS/BSD targets, LF-only
deployment files, example config shape, service and reverse-proxy template
rendering, release package hygiene, docs consistency, Next.js standalone packaging plus
standalone/next-start preflight behavior, a local Node.js runtime smoke for
both Next.js modes and the managed `PORT`/`HOSTNAME` contract, React static package validation,
obvious secret patterns, and `git diff --check`. On Windows it needs Git Bash
or another `bash` executable for the shell syntax and Unix smoke-test steps.
CI runs the Windows static verifier on pinned hosted Windows Server images
(`windows-2022` and `windows-2025`) instead of the moving `windows-latest`
alias.

To run only the Next.js support checks:

```powershell
.\scripts\dev\Test-NextJsSupport.ps1
```

To run only the React support checks:

```powershell
.\scripts\dev\Test-ReactSupport.ps1
```

On Unix-like hosts, including macOS CI runners, the Bash-only Next.js smoke
test checks the package helper, package validator, runtime layout checker,
rendered Nginx/Apache/HAProxy/Traefik reverse-proxy templates, and static
systemd, System V, OpenRC, launchd, and BSD rc preflight/status evidence paths:

```bash
bash scripts/dev/test-unix-nextjs-support.sh
```

GitHub Actions also runs that Unix/Next.js smoke suite inside target or
target-family Linux containers for Ubuntu, Debian, Linux Mint, RHEL/UBI,
Oracle Linux, CentOS/CentOS Stream, Rocky Linux, AlmaLinux, Fedora, and Alpine:

```bash
bash scripts/dev/test-linux-container-smoke.sh --platform ubuntu
```

To validate the container smoke wrapper locally without Docker pulls:

```bash
bash scripts/dev/test-linux-container-smoke.sh --self-test
```

GitHub Actions also installs ShellCheck and runs the same Bash lint gate that
you can run locally after installing ShellCheck:

```bash
bash scripts/dev/lint-shellcheck.sh
```

To build a sanitized handoff package:

```powershell
.\scripts\dev\Test-ReleasePackage.ps1
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0
```

To validate real host evidence collected from deployed Windows, Linux, macOS,
or BSD machines:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 -EvidencePath .\evidence -RequiredTargets windows-server,linux,macos,freebsd,openbsd,netbsd -RequireNextJs -RequireReverseProxy -RequireDeploymentIdentity -RequireCollectorSha256 -RequireMinimumUptimeHours 72
```

Status JSON includes a normalized `supportTargetId` / `SupportTargetId` such
as `windows-server-2022`, `ubuntu`, `macos`, or `freebsd` so support claims can
match the exact matrix target instead of relying only on OS-family inference.
For strict Next.js evidence, the validator also checks platform runtime floors:
Windows build, Linux kernel plus glibc version, and macOS product version plus
architecture where those floors apply.

A manual GitHub Actions workflow, `.github/workflows/host-evidence.yml`, can
collect and validate safe status evidence from a self-hosted Windows, Linux, or
macOS runner where the release is already deployed. It is intentionally
`workflow_dispatch` only, so normal push/PR CI does not create support claims.
The workflow validates `runner_labels` before collection and requires a JSON
array containing `self-hosted` plus the expected target label; GitHub-hosted
labels such as `ubuntu-latest`, `ubuntu-24.04`, `windows-latest`,
`windows-2022`, `windows-2025`, `macos-latest`, and `macos-15` are rejected
for real evidence collection.
The workflow also requires expected target, Next.js mode, service manager, and
reverse proxy inputs from the generated support evidence plan so collected
artifacts are rejected when they do not match the matrix combination being
claimed. The workflow choices are limited to declared matrix vocabulary for
Next.js modes, service managers, and reverse-proxy modes, then validated
against the exact target row in `config/support-matrix.example.json`. The
`evidence_name` input must match the generated
`target-mode-service-proxy` artifact name, with `-fallback` for fallback
service managers. Use a
safe relative `config_path` inside the runner workspace, such as
`config/windows/app.config.json` or `config/linux/app.env`. Those local config
files are ignored by git; the collection checkout preserves them with
`clean: false` and fails early if the selected config is missing. Do not put
absolute server paths, hostnames, customer names, or secrets in workflow inputs.
Set `upload_retention_days` between 1 and 90 days.

The support matrix is machine-readable and checked by CI:

```powershell
.\scripts\dev\Test-SupportMatrix.ps1
```

Linux rows in the matrix must keep both the broad platform-family static job
and the `linux-container-smoke` job. The container job proves the Unix scripts
execute in public target or target-family Linux userlands; final release
support still requires real-host evidence for the exact targets being claimed.

Windows service-manager routing and runtime environment parity are checked by:

```powershell
.\scripts\dev\Test-WindowsServiceManagers.ps1
```

To generate the real-host evidence checklist for a release:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\support-evidence-plan.md `
  -Format Markdown
```

The plan includes the local collection command and exact single-row validation
command for each required target/mode/service/proxy row. Windows, Linux, and macOS rows also include
manual `host-evidence` workflow inputs; BSD rows are local-command-only unless
you operate a compatible runner environment. Use `-TargetId`, `-Category`, or
`-ProductionRecommendedOnly` to generate a scoped collection plan, and add
`-FailOnWarnings` when the collection commands and workflow dispatch inputs
should reject warning-only status evidence.

To generate reviewable GitHub CLI dispatch commands from the same matrix for
workflow-capable targets:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\host-evidence-dispatch.md `
  -Format DispatchMarkdown
```

To generate a guarded PowerShell dispatcher, review its print-only output first
and run it with `-Run` only after the runner labels match your real hosts:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\Invoke-HostEvidenceDispatch.ps1 `
  -Format DispatchPowerShell
.\evidence\Invoke-HostEvidenceDispatch.ps1
```

After downloading `host-evidence` workflow artifacts into a local folder,
validate and import them into the canonical evidence tree. `ArtifactPath` can
be an extracted artifact folder, a single `.zip` artifact, or a folder
containing downloaded `.zip` artifacts:

```powershell
.\scripts\dev\Import-HostEvidenceArtifacts.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence
```

The importer validates each downloaded `status.json` against the support matrix
and `Test-HostEvidence.ps1`, requires controlled `host-evidence` /
`workflow_dispatch` provenance by default, derives the target/mode/service/proxy
key, requires the declared target to be corroborated by platform metadata,
writes the canonical evidence filename, and refuses changed overwrites unless
`-Force` is supplied. Use `-AllowLocalCollection` only for explicitly
local-command evidence.

To report which declared matrix combinations are still missing collected
evidence:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -EvidencePath .\evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

To create a review-friendly missing-coverage report without failing the
command, or to audit a saved bundle directly:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -ReportOnly `
  -Format Markdown `
  -OutputPath .\release-evidence\coverage-report.md
```

Missing rows in Markdown, JSON, and CSV output include the expected evidence
file plus the local collector command, the exact single-row validation command,
and, where supported, the exact manual
`gh workflow run host-evidence.yml` command to collect that evidence. These
commands fail on warning-only status evidence by default; add `-AllowWarnings`
when the missing-coverage report should generate warning-tolerant collection
commands instead. Coverage counts only evidence whose declared
`supportTargetId` is corroborated by collected OS/platform metadata and, for
Next.js rows, still proves the required runtime platform floor.
The default table output prints the first missing collect/validate command
pairs; use Markdown, JSON, or CSV for the complete command list.

For the final operator handoff, run the combined release workflow. It can
optionally import downloaded workflow artifacts, writes JSON and Markdown
coverage reports, fails if matrix evidence is incomplete, creates the evidence
bundle, verifies the bundle, and writes release readiness JSON. The generated
`release-readiness.json` preserves the covered and missing coverage rows with
their local collection, workflow dispatch, and single-row validation commands
so the final handoff can reproduce every claimed support tuple:

```powershell
.\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

Add `-StrictCiRelease` only for final CI-controlled signoff from a clean,
committed revision with workflow-collected evidence.

To create a private release evidence bundle with per-file SHA256 hashes:

```powershell
.\scripts\dev\New-SupportEvidenceBundle.ps1 `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -ValidateSupportClaim `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies `
  -RequireCoverageComplete `
  -IncludeServiceOnly `
  -IncludeFallback
```

The bundle manifest records safe Node.js runtime and Next.js package version
strings when available, the matrix Node runtime support tier for each target,
the collector SHA256 digest, the support matrix SHA256, and safe source-control
provenance, plus safe CI run provenance when built in CI.
The bundle verifier rejects internally inconsistent CI/source commit SHAs and
evidence whose declared `supportTargetId` is not corroborated by collected
OS/platform metadata, even when the manifest hashes match. It also rejects
saved Next.js evidence that no longer proves the required runtime platform
floor.
When individual evidence files contain safe collection CI provenance, the
manifest records and verifies it per file so workflow-collected status evidence
keeps its collection run identity after bundling.
`Test-ReleaseSupportReadiness.ps1` rejects a bundle if it was built against a
different support matrix than the current repository. Use `-StrictCiRelease`
for final CI-controlled signoff. It requires a clean source revision, current
commit match, bundle CI provenance, collection CI provenance, collection SHA
matching the bundle source commit, and collection through the controlled
`host-evidence` workflow dispatch for workflow-capable evidence rows. Targets
marked local-command-only, such as the BSD rows in the example matrix, are
accepted without workflow collection only when the bundle manifest explicitly
marks them local-only; they must still prove live Node.js and Next.js runtime
versions, collector SHA256, and the matrix-required minimum uptime window. The
example matrix sets that window to 72 hours with
`requiredMinimumUptimeHours`.

To verify a saved evidence bundle later:

```powershell
.\scripts\dev\Test-SupportEvidenceBundle.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip
```

To decide whether a saved full-matrix evidence bundle is ready for a release
support claim:

```powershell
.\scripts\dev\Test-ReleaseSupportReadiness.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -StrictCiRelease
```

For a production-runtime-only support decision, add `-ProductionRecommendedOnly`
to scope coverage and support-claim checks to matrix rows whose Node runtime is
production-recommended. Add `-RequireProductionRecommendedRuntime` when the
bundle itself must not contain experimental or community-package runtime rows.
When bundle creation is run with target, category, or production filters, only
matching evidence files are archived in the bundle.

The support-claim gate also has a self-test:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 -SelfTest
```

To validate a strict real release claim against collected target evidence:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 `
  -EvidencePath .\evidence `
  -TargetId windows-11,windows-server-2022,ubuntu,macos `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies
```

See [Host Verification Evidence](docs/HOST_VERIFICATION.md) and
[Support Matrix](docs/SUPPORT_MATRIX.md) before claiming a release is proven on
a specific operating system family.

---

## Quick Start

### Windows quick start

1. Copy the example config:

```powershell
Copy-Item .\config\windows\app.config.example.json .\config\windows\app.config.json
notepad .\config\windows\app.config.json
```

2. Edit the variables:

```json
{
  "AppName": "ExampleNodeApp",
  "AppFramework": "nextjs",
  "NextjsDeploymentMode": "standalone",
  "ReactDocumentRoot": "build",
  "AppDirectory": "C:\\apps\\ExampleNodeApp",
  "StartCommand": "server.js",
  "NodeExe": "C:\\Program Files\\nodejs\\node.exe",
  "Port": 3000,
  "HealthUrl": "http://127.0.0.1:3000/health",
  "ServiceManager": "winsw",
  "AutoDownloadWinSW": true,
  "ReverseProxy": "iis"
}
```

3. Let the installer fetch WinSW automatically, or place your internal copy:

```text
tools\winsw\winsw-x64.exe
```

No service wrapper binaries are bundled in this repository. By default,
`AutoDownloadWinSW` downloads the pinned stable WinSW executable from the
official WinSW GitHub release when the file is missing, and
`RequireWinSWDownloadSha256` requires `WinSWDownloadSha256` to verify the
downloaded or existing executable. The sample config pins the official WinSW
v2.12.0 x64 digest. Set `AutoDownloadWinSW` to `false` when servers are offline
or your organization requires an internally approved artifact; set
`RequireWinSWDownloadSha256` to `false` only when that internal source verifies
WinSW outside this kit.

4. Install with the recommended Windows entrypoint:

Right-click `install.bat` and choose **Run as administrator**, or run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

This uses PowerShell for the real deployment logic and keeps the batch file as a small convenience wrapper. The installer runs safe preflight checks first, then imports a `.zip` package when configured, runs `InstallCommand` and `BuildCommand`, and installs/updates the service, reverse proxy, and health check.

For built artifacts, import a package before service setup:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json `
  -PackagePath C:\deploy\example-node-app.zip `
  -SkipInstall -SkipBuild
```

For Next.js standalone deployments, package the contents of
`.next\standalone` after copying `.next\static` into
`.next\standalone\.next\static`, and copy `public` too when the app uses it.
See [Next.js Deployment](docs/NEXTJS_DEPLOYMENT.md) for the full artifact
layout and verification flow.

You can create that zip with the built-in packaging helper:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip
```

For full-app `next-start` packages, pass `-Mode next-start` on Windows or
`--mode next-start` on Unix to the same package helpers. The helpers stage
`package.json`, `.next`, production `node_modules`, optional `public`, and
common Next.js config/lock files, then run the matching validator before
reporting success. Package import repeats that validation before replacing the
live app directory. On Unix-like hosts, the `next-start` package helper omits
`node_modules/.bin` command shims because package-manager shims are commonly
symlinks; the service starts Next directly from `node_modules/next/dist/bin/next`,
and deploy archives intentionally reject symlink and hardlink entries.

For React deployments, ship the configured Node entrypoint plus the static
build root containing `index.html`. Create React App usually uses
`ReactDocumentRoot: "build"`; Vite usually uses `"dist"`. See
[React Deployment](docs/REACT_DEPLOYMENT.md).

```powershell
.\scripts\windows\Test-ReactStaticPackage.ps1 `
  -PackagePath C:\deploy\example-react-app.zip `
  -ReactDocumentRoot build `
  -StripSingleTopLevelDirectory
```

For TanStack Start or Vite SPAs that deploy as static files only on Windows
Server + IIS, use `config/windows/static-iis.app.config.example.json` with
`DeploymentMode: "static_iis"`, `StaticOutputDirectory: "dist/client"`, and
`SpaShellFile: "_shell.html"`. This mode runs `npm ci --include=dev` and
`npm run build`, copies only the static output contents to the IIS physical
path, uses a No Managed Code app pool, and does not require URL Rewrite, ARR,
or a Node service. See [Windows Deployment](docs/WINDOWS_DEPLOYMENT.md).

After import or manual copy, validate the live runtime folder without touching
service state:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

Windows package import supports `.zip`. Linux package import supports `.zip`,
`.tar.gz`, `.tgz`, and `.tar`. `.rar` and `.7z` are intentionally not supported
by the built-in import flow because they require external tools. Package import
rejects symlinks, NTFS reparse points, and special-file entries; ship regular
files and directories in deployment artifacts.

For IIS reverse-proxy deployments, install IIS URL Rewrite and Application
Request Routing first. The IIS reverse-proxy installer can enable ARR proxy
mode, allow the URL Rewrite server variables needed for forwarded headers,
render a dedicated health proxy path, start the configured IIS site after
updating it, and warn when WebSocket support is missing.
`IisRequireUrlRewrite` and `IisRequireArrProxy` default to `true`, so preflight
and direct IIS reverse-proxy install stop instead of writing a broken proxy
config when required IIS modules are missing.

For artifact-only deployments where dependencies are already installed and the app is already built:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json -SkipInstall -SkipBuild
```

For live servers where every release is extracted to a new timestamped folder,
use the latest-release helper so the current live folder is not moved:

```powershell
.\scripts\windows\Deploy-LatestRelease.ps1 `
  -ConfigPath .\config\windows\app.config.json `
  -ReleaseRoot C:\inetpub\wwwroot `
  -ReleasePattern "example-node-app-IIS-deploy-*" `
  -HealthPath "/" `
  -SkipWinSWDownload
```

For IIS sites, the helper checks the configured public binding before changing
the live site. It uses `TlsEnabled` to choose `http` or `https` and defaults the
public port to `80` or `443` when `PublicPort` is not set. If deployment fails,
rollback restores the previous IIS physical path, app pool, and started/stopped
site state. The generated runtime config is retained under
`<ServiceDirectory>\config` by default because the Windows scheduled health
check task reads that exact config path after deployment.

If preflight reports a known, intentional listener on the configured port that is not the current service, use:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json -AllowPortInUse
```

5. Check status without printing private environment values:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
```

The status command reports host uptime, service uptime, configured port
ownership, HTTP health latency, scheduled health-check freshness, recent health
history, and an operational verdict. Use `-MinimumUptimeHours` when you want to
prove the service has stayed up for a required period. Use `-JsonPath` when you
want a safe machine-readable release evidence file without environment values
or raw log contents. Add `-FailOnWarnings` when strict release evidence must
fail on warning-only status results. If the app was installed from a package import, the
evidence also includes the safe deployment manifest summary: package file name,
package SHA256, import timestamp, Next.js build ID, and live status collector
metadata for release evidence validation. For Next.js apps, status evidence also
records safe Node.js runtime and Next.js package version strings when available.

6. Restart or uninstall through the top-level wrappers when needed:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

Windows uninstall follows `ServiceManager`: WinSW removes through the wrapper,
NSSM removes through `nssm` with an `sc.exe` fallback, and PM2 removes the named
process plus the generated ecosystem file. App files, logs, backups, and
private config files are left in place.

### Linux quick start

1. Copy the closest safe example env file:

```bash
cp config/linux/app.env.example config/linux/app.env
nano config/linux/app.env
```

For macOS launchd hosts, start from the macOS paths and service defaults:

```bash
cp config/linux/app.env.macos.example config/linux/app.env
```

For FreeBSD, OpenBSD, or NetBSD hosts, start from the BSD rc example:

```bash
cp config/linux/app.env.bsd.example config/linux/app.env
```

2. Select Unix-like service and proxy mode in `config/linux/app.env`:

```bash
APP_RUNTIME="node"          # node or tomcat
APP_FRAMEWORK="nextjs"      # node, nextjs, or reactjs
NEXTJS_DEPLOYMENT_MODE="standalone"
REACT_DOCUMENT_ROOT="build"
SERVICE_MANAGER="systemd"   # systemd, systemv, openrc, launchd, or bsdrc
REVERSE_PROXY="nginx"       # nginx, apache, haproxy, traefik, or none
```

If `SERVICE_MANAGER` is omitted, Unix deploy, status, diagnostics, health
checks, and uninstall resolve the host-aware default: launchd on macOS, BSD rc
on FreeBSD/OpenBSD/NetBSD, OpenRC when available, otherwise systemd or System V.
The committed examples use only placeholder hostnames and service-owned paths;
keep private target values in your ignored local `config/linux/app.env`.

Linux proxy templates listen on `PROXY_LISTEN_PORT` and set forwarded headers
from `FORWARDED_PROTO` and `FORWARDED_PORT`. For the common pattern where TLS
terminates upstream, keep the local proxy on port 80 and set forwarded headers
to the public HTTPS edge.

3. Optional dependency bootstrap:

```bash
sudo bash scripts/linux/install-dependencies.sh config/linux/app.env
```

Use `sudo` or root for Linux and BSD hosts. On macOS, run the same script
without `sudo` so Homebrew can manage packages safely. The bootstrap fails
when the required package manager is missing instead of reporting a successful
deployment with unknown dependencies.

4. Run the recommended Linux entrypoint:

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
bash deploy.sh config/linux/app.env
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./evidence/unix-status.json --fail-on-critical
```

For Next.js standalone deployments, create a deployable archive with:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz
```

For full-app `next-start`, use `config/windows/next-start.app.config.example.json`
on Windows or `config/linux/app.env.next-start.example` on Unix-like hosts,
then create and validate the package with `-Mode next-start` /
`--mode next-start`.

For React deployments, validate the static build archive before import:

```bash
bash scripts/linux/validate-react-static-package.sh \
  --package-path /opt/releases/example-react-app.tar.gz \
  --react-document-root build \
  --strip-single-top-level
```

After import or manual copy, validate the live runtime folder:

```bash
bash scripts/linux/test-nextjs-runtime-layout.sh config/linux/app.env
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./evidence/unix-nextjs-status.json --fail-on-critical
```

`deploy.sh` runs the same preflight automatically before it installs or updates
the service, reverse proxy, and health check. If the configured port is already
owned by the current service during an intentional update, set
`ALLOW_PORT_IN_USE="true"` in `config/linux/app.env`.
When health checks are enabled, Unix preflight also checks the selected
scheduler command before deployment changes are made: `systemctl` for systemd,
`launchctl` for macOS, and `crontab` for System V, OpenRC, or BSD rc.
If a reverse proxy is selected, Unix preflight requires the matching proxy
command (`nginx`, `apache2ctl`/`httpd`, `haproxy`, or `traefik`) before it
renders or applies proxy configuration.

5. Or run the pieces manually:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

6. Optional config-selected reverse proxy:

```bash
sudo bash scripts/linux/install-reverse-proxy.sh config/linux/app.env
```

Set `REVERSE_PROXY` to `nginx`, `apache`, `haproxy`, `traefik`, or `none`.
Use `--dry-run` to print the installer that would run. The direct installers
remain available when you need to target one proxy explicitly:

```bash
sudo bash scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-haproxy-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-traefik-reverse-proxy.sh config/linux/app.env
```

7. Optional Tomcat WAR deployment:

```bash
APP_RUNTIME="tomcat"
TOMCAT_WAR_FILE="/opt/releases/example.war"
sudo bash scripts/linux/install-tomcat-app.sh config/linux/app.env
```

10. Optional health check scheduler:

```bash
sudo bash scripts/linux/install-healthcheck-scheduler.sh config/linux/app.env
```

To uninstall the managed Unix service and its managed health-check scheduler
without deleting app/log/backup/state directories:

```bash
sudo bash scripts/linux/uninstall-node-service.sh config/linux/app.env
```

---

## Supported Platforms

This project is a deployment kit, not a vendor support guarantee. Current Next.js requires Node.js `20.9.0` or newer, and Node runtime support is platform-specific. Use current vendor-supported systems where possible; the machine-readable support matrix marks legacy or non-official Node runtime targets separately from production-recommended rows.

### Windows targets

| Platform | Service mode | Reverse proxy | Notes |
|---|---|---|---|
| Windows 10 | WinSW / NSSM; PM2 fallback | IIS optional | Good for testing or workstation services; strict support claims use OS service evidence |
| Windows 11 | WinSW / NSSM; PM2 fallback | IIS optional | Good for testing or workstation services; strict support claims use OS service evidence |
| Windows Server 2012 / 2012 R2 | WinSW / NSSM | IIS | Legacy target; Node.js 20.x runtime support is Experimental, not production-recommended |
| Windows Server 2016 | WinSW / NSSM | IIS | Supported deployment target |
| Windows Server 2019 | WinSW / NSSM | IIS | Recommended minimum for many production environments |
| Windows Server 2022 | WinSW / NSSM | IIS | Recommended production target |
| Windows Server 2025 | WinSW / NSSM | IIS | Recommended newest Windows Server target |

### Linux targets

| Family | Distro examples | Service mode | Reverse proxy |
|---|---|---|---|
| Debian family | Ubuntu, Debian, Linux Mint | systemd / System V | Nginx / Apache / HAProxy / Traefik |
| RHEL family | RHEL, Oracle Linux, CentOS, CentOS Stream, Rocky Linux, AlmaLinux | systemd / System V | Nginx / Apache / HAProxy / Traefik |
| Fedora family | Fedora | systemd | Nginx / Apache / HAProxy / Traefik |
| OpenRC family | Alpine, Gentoo-style hosts | OpenRC | Nginx / Apache / HAProxy / Traefik |
| BSD family | FreeBSD, OpenBSD, NetBSD | bsdrc | Nginx / Apache / HAProxy / Traefik |
| macOS | Apple macOS | launchd | Nginx / Apache / HAProxy / Traefik |

For production Next.js targets, prefer Windows Server 2016 or newer, GNU/Linux
hosts that meet Node.js 20.x kernel/glibc floors, or supported macOS versions.
Alpine/musl, FreeBSD, OpenBSD, and NetBSD remain real-host evidence targets, but
the example matrix marks them experimental or community-package Node runtime
targets instead of production-recommended rows.

---

## Deployment Modes

Configure deployment style by editing variables.

| Mode | Windows | Linux | Best for |
|---|---|---|---|
| `standalone` | WinSW service + IIS optional | Unix service + Nginx/Apache/HAProxy/Traefik optional | Single app host |
| `reverse_proxy` | IIS -> Node localhost | Nginx/Apache/HAProxy/Traefik -> app localhost | Normal production deployment |
| `service_only` | WinSW/NSSM only | systemd/System V/OpenRC only | Existing external load balancer |
| `pm2_fallback` | PM2 as fallback only | PM2 optional | Migration from existing PM2 setups |
| `ansible` | WinRM automation | SSH automation | Multi-server repeatable deployment |

Recommended production selection:

```yaml
deployment_mode: reverse_proxy
windows_service_manager: winsw
linux_service_manager: systemd
windows_reverse_proxy: iis
linux_reverse_proxy: nginx
app_runtime: node
healthcheck_enabled: true
monitoring_export_enabled: true
```

On Windows, WinSW is the recommended production service manager. NSSM and PM2
are compatibility fallbacks; all three receive the same managed runtime
environment defaults (`NODE_ENV`, `PORT`, `APP_PORT`, `APP_NAME`,
`BIND_ADDRESS`, `HOST`, and `HOSTNAME`) so Node.js and Next.js bind to the
configured localhost address behind IIS.

---

## Repository Layout

```text
node-enterprise-deploy-kit/
├── ansible/                         # Optional Ansible automation
├── config/                          # Changeable variables and examples
├── docs/                            # Architecture, hardening, troubleshooting
├── scripts/
│   ├── linux/                       # Unix-like services, reverse proxies, Tomcat, health checks
│   └── windows/                     # WinSW, IIS, scheduled tasks, diagnostics
├── scripts/dev/                     # CI, repository safety checks, release packaging
├── scripts/linux/status-node-app.sh  # Unix service/port/health/Next.js status verdict
├── templates/                       # WinSW, init/launchd, IIS, proxy templates
├── tools/                           # Place external wrappers here; no binaries included
├── install.bat                      # Windows double-click wrapper
├── install.ps1                      # Windows install entrypoint
├── deploy.ps1                       # Windows deployment orchestrator
├── status.ps1                       # Windows service/port/health status
├── restart.ps1                      # Windows service restart helper
├── rollback.ps1                     # Windows managed-backup rollback helper
├── uninstall.ps1                    # Windows service uninstall wrapper
├── .github/workflows/               # Basic CI checks
├── LICENSE
└── README.md
```

---

## Recommended Health Checks

This kit supports three health check layers:

```text
1. Process/service check
   Windows Service or Linux service manager is running.

2. Port check
   Node.js listens on localhost:<APP_PORT>.

3. HTTP check
   GET http://127.0.0.1:<APP_PORT>/health returns 200.
```

Recommended application endpoint:

```js
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok', service: process.env.APP_NAME || 'node-app' });
});
```

If your app does not expose `/health`, set `HealthUrl` to `/` or another safe endpoint.

---

## Enterprise-Grade Defaults

| Area | Recommended setting |
|---|---|
| Service user | Dedicated non-admin account, `NetworkService`, or gMSA |
| App bind address | `127.0.0.1` |
| Public access | IIS/Nginx/Apache only |
| Logs | Dedicated directory with rotation |
| Secrets | Environment file or external secret manager, never committed |
| Restart | Service-level restart policy |
| Hung app recovery | HTTP health check restarts service |
| Monitoring | Export diagnostics to Wazuh/Graylog/Prometheus-compatible tooling |
| Deployment | PowerShell install/deploy scripts with optional `.bat` wrapper |
| Rollback | Keep previous release directory or backup archive |

---

## Example Windows Config

```json
{
  "AppName": "ExampleNodeApp",
  "DisplayName": "Example Node App",
  "AppFramework": "nextjs",
  "NextjsDeploymentMode": "standalone",
  "ReactDocumentRoot": "build",
  "NextjsRequireStaticAssets": true,
  "NextjsRequirePublicDirectory": false,
  "NextjsRequireServerActionsEncryptionKey": false,
  "NextjsRequireDeploymentId": false,
  "NextjsMinimumNodeVersion": "20.9.0",
  "AppDirectory": "C:\\apps\\ExampleNodeApp",
  "PackageExpectedFiles": [
    "server.js",
    ".next/BUILD_ID",
    ".next/static"
  ],
  "StartCommand": "server.js",
  "NodeExe": "C:\\Program Files\\nodejs\\node.exe",
  "NodeArguments": "",
  "Port": 3000,
  "BindAddress": "127.0.0.1",
  "HealthUrl": "http://127.0.0.1:3000/health",
  "ServiceManager": "winsw",
  "AutoDownloadWinSW": true,
  "WinSWDownloadUrl": "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe",
  "RequireWinSWDownloadSha256": true,
  "WinSWDownloadSha256": "05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA",
  "ReverseProxy": "iis",
  "IisSitePath": "C:\\inetpub\\wwwroot\\ExampleNodeApp",
  "IisSiteName": "ExampleNodeApp",
  "IisAppPoolName": "ExampleNodeApp-AppPool",
  "PublicHostName": "app.example.local",
  "PublicPort": 443,
  "TlsEnabled": true,
  "IisCertificateThumbprint": "",
  "IisEnableArrProxy": true,
  "IisRequireUrlRewrite": true,
  "IisRequireArrProxy": true,
  "IisSetForwardedHeaders": true,
  "IisHealthProxyPath": "health",
  "IisWebSocketSupport": true,
  "IisProxyTimeoutSeconds": 300,
  "ServiceAccount": "NetworkService",
  "ServiceAccountPassword": "",
  "LogDirectory": "C:\\logs\\ExampleNodeApp",
  "ServiceDirectory": "C:\\services\\ExampleNodeApp",
  "BackupDirectory": "C:\\services\\ExampleNodeApp\\backups",
  "HealthCheckFailureThreshold": 2,
  "HealthCheckRestartCooldownMinutes": 5,
  "HealthCheckTimeoutSeconds": 10,
  "LogRetentionDays": 30,
  "BackupRetentionDays": 90,
  "DiagnosticRetentionDays": 14,
  "Environment": {
    "NODE_ENV": "production",
    "PORT": "3000",
    "APP_PORT": "3000",
    "APP_NAME": "ExampleNodeApp",
    "BIND_ADDRESS": "127.0.0.1",
    "HOST": "127.0.0.1",
    "HOSTNAME": "127.0.0.1"
  }
}
```

## Example Linux Config

```bash
APP_NAME="example-node-app"
APP_DISPLAY_NAME="Example Node App"
APP_DIR="/opt/example-node-app"
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="standalone"
REACT_DOCUMENT_ROOT="build"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="false"
NEXTJS_REQUIRE_DEPLOYMENT_ID="false"
NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
SERVICE_MANAGER="systemd"
PACKAGE_PATH=""
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR="true"
NODE_BIN="/usr/bin/node"
START_SCRIPT="server.js"
APP_PORT="3000"
BIND_ADDRESS="127.0.0.1"
HEALTH_URL="http://127.0.0.1:3000/health"
RUNTIME_ENV_KEYS=""
SERVICE_USER="nodeapp"
LOG_DIR="/var/log/example-node-app"
BACKUP_DIR="/var/backups/example-node-app"
HEALTHCHECK_STATE_DIR="/var/lib/node-enterprise-deploy-kit/example-node-app"
REVERSE_PROXY="nginx"
HEALTHCHECK_PATH="/health"
HAPROXY_CONFIG_FILE="/etc/haproxy/haproxy.cfg"
HAPROXY_ALLOW_MAIN_CONFIG_REPLACE="false"
TRAEFIK_DYNAMIC_FILE="/etc/traefik/dynamic/example-node-app.yml"
PUBLIC_HOSTNAME="app.example.local"
PUBLIC_PORT="443"
TLS_ENABLED="true"
PROXY_LISTEN_PORT="80"
FORWARDED_PROTO="https"
FORWARDED_PORT="443"
HEALTHCHECK_FAILURE_THRESHOLD="2"
HEALTHCHECK_RESTART_COOLDOWN="300"
HEALTHCHECK_TIMEOUT="10"
LOG_RETENTION_DAYS="30"
BACKUP_RETENTION_DAYS="90"
DIAGNOSTIC_RETENTION_DAYS="14"
```

For Unix-like Next.js services, the installer derives the managed runtime
`PORT`, `APP_PORT`, `HOST`, and `HOSTNAME` values from `APP_PORT` and
`BIND_ADDRESS`, so the generated standalone server binds to the same local
address that the reverse proxy targets.

For Windows Next.js services, the WinSW, NSSM, and PM2 installers derive the
same managed runtime defaults from `Port`, `AppName`, and `BindAddress`. PM2
is still fallback-only; prefer WinSW for live Windows Server deployments.

Set `SERVICE_MANAGER` to `systemv` for legacy init hosts, `openrc` for OpenRC hosts, `launchd` for macOS, or `bsdrc` for BSD. Set `REVERSE_PROXY` to `apache`, `haproxy`, or `traefik` to use those installers instead of Nginx. Set `APP_RUNTIME` to `tomcat` when deploying a WAR with `TOMCAT_WAR_FILE`. HAProxy refuses to replace an existing main config unless `HAPROXY_ALLOW_MAIN_CONFIG_REPLACE="true"` is set.

---

## Security Notes

Do not commit real values for:

```text
.env.production
.env.local
app.config.json
passwords
API keys
database connection strings
JWT secrets
private hostnames or IP addresses
customer names
```

Use the example files, then create local/private copies during deployment.

---

## When to Use This Project

Use this kit when you need to deploy:

- Node.js API services
- Next.js apps with `server.js`
- Express/Koa/Fastify apps
- Internal admin panels
- IIS-to-Node reverse proxy apps
- Nginx-to-Node reverse proxy apps
- Apache-to-Node reverse proxy apps
- HAProxy-to-app reverse proxy apps
- Traefik dynamic-file reverse proxy apps
- Apache Tomcat WAR deployments
- Windows Server hosted Node apps
- Linux hosted Node apps

---

## License

MIT. See [LICENSE](LICENSE).
