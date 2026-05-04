# Linux Deployment

## Supported Linux Families

- Ubuntu
- Debian
- Linux Mint
- RHEL
- Oracle Linux
- CentOS / CentOS Stream
- Fedora
- AlmaLinux
- Rocky Linux
- Alpine/OpenRC-style hosts
- FreeBSD
- OpenBSD
- NetBSD
- Apple macOS

## Recommended Production Pattern

```text
Nginx / Apache / HAProxy / Traefik frontend -> 127.0.0.1:3000 -> service -> Node.js app
```

Supported Linux service managers:

- `systemd`
- `systemv`
- `openrc`
- `launchd` for macOS
- `bsdrc` for BSD hosts

Supported Linux reverse proxies:

- `nginx`
- `apache`
- `haproxy`
- `traefik`
- `none`

Supported app runtimes:

- `node` for Node.js/Next.js services
- `tomcat` for deploying a WAR into an existing Apache Tomcat installation

## Steps

1. Verify the repository before deploying:

```powershell
.\scripts\dev\Test-Repository.ps1
```

2. Copy config:

```bash
cp config/linux/app.env.example config/linux/app.env
```

3. Edit variables:

```bash
nano config/linux/app.env
```

4. Select service manager and reverse proxy:

```bash
SERVICE_MANAGER="systemd"   # systemd, systemv, or openrc
REVERSE_PROXY="nginx"       # nginx, apache, haproxy, traefik, or none
APP_RUNTIME="node"          # node or tomcat
```

5. Optional dependency bootstrap:

```bash
sudo bash scripts/linux/install-dependencies.sh config/linux/app.env
```

6. Run preflight checks:

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
```

If the configured port is already listening because the existing service is
running during an intentional update, set `ALLOW_PORT_IN_USE="true"` or pass
`--allow-port-in-use`.

7. Recommended one-command deployment:

```bash
bash deploy.sh config/linux/app.env
```

`deploy.sh` runs preflight unless `SKIP_PREFLIGHT="true"`, installs or updates
the service, applies the selected reverse proxy, and installs the systemd health
timer when `SERVICE_MANAGER="systemd"`.

Managed file updates create timestamped backups in `BACKUP_DIR` before
replacing existing env files, service units/init scripts, reverse proxy configs,
or health-check files. If `BACKUP_DIR` is not set, the scripts use
`/var/backups/<APP_NAME>`.

Health checks record `healthcheck.state` and `healthcheck.log` under `LOG_DIR`
and prune old managed logs, diagnostics, and backups using
`LOG_RETENTION_DAYS`, `DIAGNOSTIC_RETENTION_DAYS`, and
`BACKUP_RETENTION_DAYS`.

8. Manual service install:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

The service installer runs configured `INSTALL_COMMAND` and `BUILD_COMMAND`
inside `APP_DIR` as the configured service user. Set `SKIP_INSTALL="true"` or
`SKIP_BUILD="true"` for artifact-only releases.

9. Optional Nginx reverse proxy:

```bash
sudo bash scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
```

10. Optional Apache reverse proxy:

```bash
sudo bash scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
```

On Debian-family hosts, the Apache installer enables `proxy`, `proxy_http`, `proxy_wstunnel`, `headers`, and `rewrite`.

11. Optional HAProxy reverse proxy:

```bash
sudo bash scripts/linux/install-haproxy-reverse-proxy.sh config/linux/app.env
```

The HAProxy installer renders a complete config to `HAPROXY_CONFIG_FILE`, backs
up any previous file, validates with `haproxy -c`, and reloads/restarts HAProxy.
Use it on a dedicated HAProxy instance or point `HAPROXY_CONFIG_FILE` at your
managed app-specific config path.

12. Optional Traefik dynamic config:

```bash
sudo bash scripts/linux/install-traefik-reverse-proxy.sh config/linux/app.env
```

The Traefik installer writes a dynamic file provider config under
`TRAEFIK_DYNAMIC_DIR`. Your static Traefik config must already watch that
directory.

13. Optional Tomcat WAR deployment:

```bash
APP_RUNTIME="tomcat"
TOMCAT_WAR_FILE="/opt/releases/example.war"
TOMCAT_WEBAPPS_DIR="/var/lib/tomcat/webapps"
TOMCAT_CONTEXT_PATH="/example-node-app"
sudo bash scripts/linux/install-tomcat-app.sh config/linux/app.env
```

Tomcat mode deploys the WAR and restarts the configured `TOMCAT_SERVICE`. The
Node service installer is skipped when `APP_RUNTIME="tomcat"`.

14. Optional systemd health check timer:

```bash
sudo bash scripts/linux/install-healthcheck-timer.sh config/linux/app.env
```

For `systemv`, `openrc`, `launchd`, and `bsdrc`, use `scripts/linux/node-healthcheck.sh` from cron
or your external monitoring platform. The health check understands `systemd`,
`systemv`, `openrc`, `launchd`, and `bsdrc` service managers.

15. Verify:

```bash
ss -ltnp | grep :3000
curl -fsS http://127.0.0.1:3000/health
```

Service status examples:

```bash
systemctl status example-node-app
service example-node-app status
rc-service example-node-app status
```
