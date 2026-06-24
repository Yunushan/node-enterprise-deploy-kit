<p align="center">
  <img src="docs/assets/logo.svg" alt="Node Enterprise Deploy Kit logo" width="140" />
</p>

<h1 align="center">Node Enterprise Deploy Kit</h1>

<p align="center">
  <strong>Cross-platform, enterprise-style deployment kit for Node.js / Next.js applications on Windows and Unix-like hosts, with optional Tomcat WAR deployment, service management, reverse proxy templates, health checks, diagnostics, and Ansible automation.</strong>
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
  <a href="docs/ANSIBLE.md">Ansible</a> •
  <a href="docs/RUNBOOK.md">Runbook</a> •
  <a href="docs/HOST_VERIFICATION.md">Host Evidence</a> •
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
Node.js / Next.js app running as a real service, or a Tomcat WAR deployment
  |
  v
Rotated logs + health check + auto-restart + diagnostics
```

Recommended default:

```text
Windows: IIS + WinSW Windows Service + scheduled health check
Linux:   Nginx, Apache, HAProxy, or Traefik + systemd service + systemd timer health check
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
deployment files, example config shape, template rendering, release package
hygiene, docs consistency, Next.js standalone packaging plus
standalone/next-start preflight behavior, a local Node.js runtime smoke for
the managed `PORT`/`HOSTNAME` contract, obvious secret patterns, and `git diff
--check`. On Windows it needs Git Bash or another `bash` executable for the
shell syntax and Unix Next.js smoke-test steps.

To run only the Next.js support checks:

```powershell
.\scripts\dev\Test-NextJsSupport.ps1
```

On Unix-like hosts, including macOS CI runners, the Bash-only Next.js smoke
test checks the package helper, package validator, runtime layout checker, and
static launchd/bsdrc preflight paths:

```bash
bash scripts/dev/test-unix-nextjs-support.sh
```

To build a sanitized handoff package:

```powershell
.\scripts\dev\Test-ReleasePackage.ps1
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0
```

To validate real host evidence collected from deployed Windows, Linux, macOS,
or BSD machines:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 -EvidencePath .\evidence -RequiredTargets windows-server,linux,macos,freebsd,openbsd,netbsd -RequireNextJs -RequireReverseProxy -RequireDeploymentIdentity
```

See [Host Verification Evidence](docs/HOST_VERIFICATION.md) before claiming a
release is proven on a specific operating system family.

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
official WinSW GitHub release when the file is missing. Set
`AutoDownloadWinSW` to `false` when servers are offline or your organization
requires an internally approved artifact.

4. Install with the recommended Windows entrypoint:

Right-click `install.bat` and choose **Run as administrator**, or run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

This uses PowerShell for the real deployment logic and keeps the batch file as a small convenience wrapper. The installer can import a `.zip` package first, then runs a safe preflight check, configured `InstallCommand` and `BuildCommand`, and installs/updates the service, reverse proxy, and health check.

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
`--mode next-start` with the Unix validator. Package import runs the matching
Next.js validator automatically before replacing the live app directory.

After import or manual copy, validate the live runtime folder without touching
service state:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

Windows package import supports `.zip`. Linux package import supports `.zip`,
`.tar.gz`, `.tgz`, and `.tar`. `.rar` and `.7z` are intentionally not supported
by the built-in import flow because they require external tools.

For IIS deployments, install IIS URL Rewrite and Application Request Routing
first. The IIS installer can enable ARR proxy mode, allow the URL Rewrite
server variables needed for forwarded headers, render a dedicated health proxy
path, and warn when WebSocket support is missing.

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
or raw log contents. If the app was installed from a package import, the
evidence also includes the safe deployment manifest summary: package file name,
package SHA256, import timestamp, and Next.js build ID.

6. Restart or uninstall through the top-level wrappers when needed:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

### Linux quick start

1. Copy the example env file:

```bash
cp config/linux/app.env.example config/linux/app.env
nano config/linux/app.env
```

2. Select Linux service and proxy mode in `config/linux/app.env`:

```bash
APP_RUNTIME="node"          # node or tomcat
APP_FRAMEWORK="nextjs"      # node or nextjs
NEXTJS_DEPLOYMENT_MODE="standalone"
SERVICE_MANAGER="systemd"   # systemd, systemv, openrc, launchd, or bsdrc
REVERSE_PROXY="nginx"       # nginx, apache, haproxy, traefik, or none
```

Linux proxy templates listen on `PROXY_LISTEN_PORT` and set forwarded headers
from `FORWARDED_PROTO` and `FORWARDED_PORT`. For the common pattern where TLS
terminates upstream, keep the local proxy on port 80 and set forwarded headers
to the public HTTPS edge.

3. Optional dependency bootstrap:

```bash
sudo bash scripts/linux/install-dependencies.sh config/linux/app.env
```

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

5. Or run the pieces manually:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

6. Optional Nginx reverse proxy:

```bash
sudo bash scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
```

7. Optional Apache reverse proxy:

```bash
sudo bash scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
```

8. Optional HAProxy or Traefik reverse proxy:

```bash
sudo bash scripts/linux/install-haproxy-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-traefik-reverse-proxy.sh config/linux/app.env
```

9. Optional Tomcat WAR deployment:

```bash
APP_RUNTIME="tomcat"
TOMCAT_WAR_FILE="/opt/releases/example.war"
sudo bash scripts/linux/install-tomcat-app.sh config/linux/app.env
```

10. Optional health check scheduler:

```bash
sudo bash scripts/linux/install-healthcheck-scheduler.sh config/linux/app.env
```

---

## Supported Platforms

This project is a deployment kit, not a vendor support guarantee. Older operating systems such as Windows Server 2012 may require older PowerShell, TLS, .NET, Node.js, or package-management adjustments. Use current vendor-supported systems where possible.

### Windows targets

| Platform | Service mode | Reverse proxy | Notes |
|---|---|---|---|
| Windows 10 | WinSW / NSSM / PM2 fallback | IIS optional | Good for testing or workstation services |
| Windows 11 | WinSW / NSSM / PM2 fallback | IIS optional | Good for testing or workstation services |
| Windows Server 2012 / 2012 R2 | WinSW / NSSM | IIS | Legacy target; validate Node.js runtime compatibility |
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
  "NextjsRequireStaticAssets": true,
  "NextjsRequirePublicDirectory": false,
  "NextjsRequireServerActionsEncryptionKey": false,
  "NextjsRequireDeploymentId": false,
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
  "WinSWDownloadSha256": "",
  "ReverseProxy": "iis",
  "IisSitePath": "C:\\inetpub\\wwwroot\\ExampleNodeApp",
  "IisSiteName": "ExampleNodeApp",
  "IisAppPoolName": "ExampleNodeApp-AppPool",
  "PublicHostName": "app.example.local",
  "PublicPort": 443,
  "TlsEnabled": true,
  "IisCertificateThumbprint": "",
  "IisEnableArrProxy": true,
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
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="false"
NEXTJS_REQUIRE_DEPLOYMENT_ID="false"
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
