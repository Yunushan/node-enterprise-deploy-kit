<p align="center">
  <img src="docs/assets/logo.svg" alt="Node Enterprise Deploy Kit logo" width="140" />
</p>

<h1 align="center">Node Enterprise Deploy Kit</h1>

<p align="center">
  <strong>Cross-platform, enterprise-style deployment kit for Node.js / Next.js applications on Windows and Linux with service management, reverse proxy templates, health checks, diagnostics, and Ansible automation.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="windows" src="https://img.shields.io/badge/windows-10%20%7C%2011%20%7C%20Server%202012--2025-0078D4.svg">
  <img alt="linux" src="https://img.shields.io/badge/linux-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Fedora%20%7C%20Alpine-success.svg">
  <img alt="service managers" src="https://img.shields.io/badge/service-WinSW%20%7C%20systemd%20%7C%20System%20V%20%7C%20OpenRC-orange.svg">
  <img alt="reverse proxy" src="https://img.shields.io/badge/proxy-IIS%20%7C%20Nginx%20%7C%20Apache%20%7C%20none-6f42c1.svg">
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#what-this-solves">What this solves</a> •
  <a href="#supported-platforms">Supported Platforms</a> •
  <a href="#deployment-modes">Deployment Modes</a> •
  <a href="docs/VARIABLES.md">Variables</a> •
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
IIS / Nginx / Apache / existing load balancer
  |
  v
127.0.0.1:<APP_PORT>
  |
  v
Node.js / Next.js app running as a real service
  |
  v
Rotated logs + health check + auto-restart + diagnostics
```

Recommended default:

```text
Windows: IIS + WinSW Windows Service + scheduled health check
Linux:   Nginx or Apache + systemd service + systemd timer health check
```

This repository contains no private hostnames, secrets, credentials, IP addresses, or customer data. All sensitive values are variables.

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
  "AppDirectory": "C:\\apps\\ExampleNodeApp",
  "StartCommand": "server.js",
  "NodeExe": "C:\\Program Files\\nodejs\\node.exe",
  "Port": 3000,
  "HealthUrl": "http://127.0.0.1:3000/health",
  "ServiceManager": "winsw",
  "ReverseProxy": "iis"
}
```

3. Install as a Windows Service using WinSW:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\scripts\windows\Install-NodeService.ps1 -ConfigPath .\config\windows\app.config.json
```

4. Optional IIS reverse proxy template install:

```powershell
.\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
```

5. Install health check scheduled task:

```powershell
.\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath .\config\windows\app.config.json
```

### Linux quick start

1. Copy the example env file:

```bash
cp config/linux/app.env.example config/linux/app.env
nano config/linux/app.env
```

2. Select Linux service and proxy mode in `config/linux/app.env`:

```bash
SERVICE_MANAGER="systemd"   # systemd, systemv, or openrc
REVERSE_PROXY="nginx"       # nginx, apache, or none
```

3. Install service:

```bash
sudo ./scripts/linux/install-node-service.sh config/linux/app.env
```

4. Optional Nginx reverse proxy:

```bash
sudo ./scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
```

5. Optional Apache reverse proxy:

```bash
sudo ./scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
```

6. Optional systemd health check timer:

```bash
sudo ./scripts/linux/install-healthcheck-timer.sh config/linux/app.env
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
| Debian family | Ubuntu, Debian | systemd / System V | Nginx / Apache |
| RHEL family | RHEL, Rocky Linux, AlmaLinux | systemd / System V | Nginx / Apache |
| Fedora family | Fedora | systemd | Nginx / Apache |
| OpenRC family | Alpine, Gentoo-style hosts | OpenRC | Nginx / Apache |

---

## Deployment Modes

Configure deployment style by editing variables.

| Mode | Windows | Linux | Best for |
|---|---|---|---|
| `standalone` | WinSW service + IIS optional | Linux service + Nginx/Apache optional | Single app host |
| `reverse_proxy` | IIS -> Node localhost | Nginx/Apache -> Node localhost | Normal production deployment |
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
healthcheck_enabled: true
monitoring_export_enabled: true
```

---

## Repository Layout

```text
node-enterprise-deploy-kit/
├── ansible/                         # Optional Ansible automation
├── config/                          # Changeable variables and examples
├── docs/                            # Architecture, hardening, troubleshooting
├── scripts/
│   ├── linux/                       # systemd/System V/OpenRC, Nginx/Apache, health checks
│   └── windows/                     # WinSW, IIS, scheduled tasks, diagnostics
├── templates/                       # WinSW, Linux init, IIS, Nginx, Apache templates
├── tools/                           # Place external wrappers here; no binaries included
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
| Service user | Dedicated non-admin service account |
| App bind address | `127.0.0.1` |
| Public access | IIS/Nginx/Apache only |
| Logs | Dedicated directory with rotation |
| Secrets | Environment file or external secret manager, never committed |
| Restart | Service-level restart policy |
| Hung app recovery | HTTP health check restarts service |
| Monitoring | Export diagnostics to Wazuh/Graylog/Prometheus-compatible tooling |
| Deployment | Git checkout or artifact release + scripted service install |
| Rollback | Keep previous release directory or backup archive |

---

## Example Windows Config

```json
{
  "AppName": "ExampleNodeApp",
  "DisplayName": "Example Node App",
  "AppDirectory": "C:\\apps\\ExampleNodeApp",
  "StartCommand": "server.js",
  "NodeExe": "C:\\Program Files\\nodejs\\node.exe",
  "NodeArguments": "",
  "Port": 3000,
  "BindAddress": "127.0.0.1",
  "HealthUrl": "http://127.0.0.1:3000/health",
  "ServiceManager": "winsw",
  "ReverseProxy": "iis",
  "IisSitePath": "C:\\inetpub\\wwwroot\\ExampleNodeApp",
  "PublicHostName": "app.example.local",
  "LogDirectory": "C:\\logs\\ExampleNodeApp",
  "ServiceDirectory": "C:\\services\\ExampleNodeApp",
  "Environment": {
    "NODE_ENV": "production",
    "PORT": "3000"
  }
}
```

## Example Linux Config

```bash
APP_NAME="example-node-app"
APP_DISPLAY_NAME="Example Node App"
APP_DIR="/opt/example-node-app"
SERVICE_MANAGER="systemd"
NODE_BIN="/usr/bin/node"
START_SCRIPT="server.js"
APP_PORT="3000"
BIND_ADDRESS="127.0.0.1"
HEALTH_URL="http://127.0.0.1:3000/health"
SERVICE_USER="nodeapp"
LOG_DIR="/var/log/example-node-app"
REVERSE_PROXY="nginx"
PUBLIC_HOSTNAME="app.example.local"
```

Set `SERVICE_MANAGER` to `systemv` for legacy init hosts or `openrc` for OpenRC hosts. Set `REVERSE_PROXY` to `apache` to install the Apache virtual host template instead of Nginx.

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
- Windows Server hosted Node apps
- Linux hosted Node apps

---

## License

MIT. See [LICENSE](LICENSE).
