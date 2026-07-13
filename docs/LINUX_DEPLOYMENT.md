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

Current Next.js requires Node.js `20.9.0` or newer. The production-recommended
GNU/Linux rows assume the host meets the Node.js 20.x kernel/glibc runtime
floor. Alpine/musl and FreeBSD are tracked as Experimental Node runtime
targets, while OpenBSD and NetBSD require an OS package or locally maintained
Node runtime. All of those rows still require real-host evidence before they
can be claimed for a release.

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

2. Copy the closest safe example config:

```bash
cp config/linux/app.env.example config/linux/app.env
```

For macOS launchd hosts:

```bash
cp config/linux/app.env.macos.example config/linux/app.env
```

For FreeBSD, OpenBSD, or NetBSD hosts:

```bash
cp config/linux/app.env.bsd.example config/linux/app.env
```

3. Edit variables:

```bash
nano config/linux/app.env
```

4. Select service manager and reverse proxy:

```bash
SERVICE_MANAGER="systemd"   # systemd, systemv, openrc, launchd, or bsdrc
REVERSE_PROXY="nginx"       # nginx, apache, haproxy, traefik, or none
APP_RUNTIME="node"          # node or tomcat
```

For macOS use `SERVICE_MANAGER="launchd"`; the macOS example also uses
Homebrew-style paths and the built-in `_www` service account. For FreeBSD,
OpenBSD, or NetBSD use `SERVICE_MANAGER="bsdrc"`; the BSD example uses
`/usr/local` and `/var/db` paths that match common BSD package layouts.
If `SERVICE_MANAGER` is omitted, deploy, status, diagnostics, health checks,
and uninstall resolve the default from the host: launchd on macOS, BSD rc on
FreeBSD/OpenBSD/NetBSD, OpenRC when `rc-service` is present, otherwise systemd
or System V.

`TLS_ENABLED`, `PUBLIC_PORT`, `FORWARDED_PROTO`, and `FORWARDED_PORT` describe
the public edge seen by the application through forwarded headers. The Linux
Nginx, Apache, and HAProxy templates listen on `PROXY_LISTEN_PORT` and do not
create certificate bindings. If TLS terminates at an upstream load balancer,
keep `PROXY_LISTEN_PORT="80"` and set `FORWARDED_PROTO="https"`.

5. Optional dependency bootstrap:

```bash
sudo bash scripts/linux/install-dependencies.sh config/linux/app.env
```

Use root or `sudo` for Linux and BSD hosts. On macOS, run the dependency
bootstrap without `sudo`; it uses Homebrew and will fail clearly if `brew` is
not available. For locked-down servers, install the same packages through your
approved software channel and skip this optional step.

When npm uses a corporate TLS-inspection proxy or private registry, keep
certificate and token settings in a separate target-local file rather than in
`app.env` or the service environment. Set an absolute path in `app.env`:

```bash
PREPARATION_ENV_FILE="/etc/example-node-app/preparation.env"
```

The file accepts only literal `NAME=value` lines and is applied only to
`INSTALL_COMMAND` and `BUILD_COMMAND`. It is not copied into the managed Node
service environment or emitted in status evidence. For example, use an
approved CA bundle without disabling TLS validation:

```text
NODE_EXTRA_CA_CERTS=/etc/ssl/company/enterprise-ca.pem
```

Restrict that file to the deployment administrator and the service account as
required by your platform policy. Do not use `strict-ssl=false` or
`NODE_TLS_REJECT_UNAUTHORIZED=0`.

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
the service, applies the selected reverse proxy, and installs the matching
health-check scheduler: systemd timer, launchd job, or managed root crontab.
When health checks are enabled, preflight also verifies the matching scheduler
command before deployment changes are made: `systemctl` for systemd timers,
`launchctl` for macOS launchd jobs, and `crontab` for System V, OpenRC, or BSD
rc cron entries.
When a reverse proxy is selected, preflight also requires the matching proxy
binary to exist: `nginx`, `apache2ctl`/`httpd`, `haproxy`, or `traefik`.
Install dependencies first or set `REVERSE_PROXY="none"` for service-only
deployments.

To deploy a built archive before service setup, set `PACKAGE_PATH` in
`config/linux/app.env`:

```bash
PACKAGE_PATH="/opt/releases/example-node-app.tar.gz"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR="true"
bash deploy.sh config/linux/app.env
```

Linux package import supports `.tar.gz`, `.tgz`, `.tar`, and `.zip`. It
validates archive member paths before extraction, extracts to a temporary
directory, checks `PACKAGE_EXPECTED_FILES`, stops the existing service when
present, backs up `APP_DIR`, then imports the new contents.
`PACKAGE_EXPECTED_FILES` may name files or directories, so Next.js standalone
packages can require `server.js`, `.next/BUILD_ID`, and `.next/static`. `.rar` and `.7z` are
intentionally unsupported in this first implementation because they require
external tooling.
Tar packages with symlink or hardlink entries are rejected, and extracted
symlinks from any supported archive are rejected before the app directory is
replaced. Keep deployable artifacts as regular files and directories.

For React deployments, ship the Node entrypoint that serves the SPA plus the
static build root containing `index.html`. Create React App commonly uses
`REACT_DOCUMENT_ROOT="build"` and Vite commonly uses `"dist"`. Validate the
archive before deployment:

```bash
bash scripts/linux/validate-react-static-package.sh \
  --package-path /opt/releases/example-react-app.tar.gz \
  --react-document-root build \
  --strip-single-top-level
```

The Unix package import flow runs this validator automatically when
`APP_FRAMEWORK` is `react`, `reactjs`, or `react-js`.

For Next.js standalone deployments, build with `output: 'standalone'`, package
the contents of `.next/standalone`, and copy `.next/static` to
`.next/standalone/.next/static` before creating the archive. Copy `public` to
`.next/standalone/public` too when the app uses public files. Use:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
```

The package helper blocks obvious private files such as `.env`, private keys,
and certificates from the staged artifact before it creates the archive.
Configure the deployment with:

```bash
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz
```

For full-app `next-start` packages, add `--mode next-start` to the same helper:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz \
  --mode next-start
```

In that mode the helper stages `package.json`, `.next`, production
`node_modules`, optional `public`, and common Next.js config/lock files. It
omits `node_modules/.bin` command shims because package managers commonly put
symlinks there, while the managed `next-start` service uses
`node_modules/next/dist/bin/next` directly. The validator requires that exact
file so a package with only a partial `node_modules/next` tree fails before
service installation. Run the validator on any archive that did not come
directly from the helper. The Unix package import flow also runs this validator
automatically when
`APP_FRAMEWORK="nextjs"` and `NEXTJS_DEPLOYMENT_MODE` is `standalone` or
`next-start`.
For a complete `next-start` starting point, copy
`config/linux/app.env.next-start.example` to `config/linux/app.env`.

```bash
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="standalone"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="false"
NEXTJS_REQUIRE_DEPLOYMENT_ID="false"
NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
START_SCRIPT="server.js"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
```

The Unix-like preflight validates the selected Next.js mode and the deployed
runtime layout before replacing service/proxy configuration. See
[Next.js Deployment](NEXTJS_DEPLOYMENT.md) for build, packaging, and
multi-instance notes.

To check only the live Next.js folder structure after package import or manual
copy, run:

```bash
bash scripts/linux/test-nextjs-runtime-layout.sh config/linux/app.env
```

For CI/static validation of a macOS or BSD config on a non-target runner, pass
`--skip-service-manager-check` to skip only the local `systemctl`/`launchctl`/
`rc-service` command probe. Run the normal preflight without that flag on the
actual target host before deploying.

After deployment, `scripts/linux/diagnose-node-app.sh` includes a safe Next.js
runtime layout section when `APP_FRAMEWORK="nextjs"`. Use it to confirm the
live folder contains the expected standalone or `next-start` files on Linux,
macOS, or BSD without printing private environment values.

Use `scripts/linux/status-node-app.sh --json-output` for post-deploy evidence.
The JSON includes structured configured-port proof, including whether the port
is listening and whether ownership can be tied to the configured service
process. It also includes structured HTTP health proof so release evidence can
show the app responded successfully, not only that a process existed. Uptime
evidence records service process uptime and whether the requested
`--minimum-uptime-hours` window was satisfied.
It also includes `healthMonitor` proof from the root-owned health-check state
file and recent health-check log summary, so release evidence can show that the
recurring monitor has been succeeding over time instead of only proving a
single live HTTP response. On systemd hosts, the same evidence also proves the
`<app-name>-healthcheck.timer` unit exists, is active, and is enabled for boot.
On macOS it proves the launchd job, and on System V/OpenRC/BSD rc hosts it
proves the managed cron entry plus best-effort cron daemon activity.
When `REVERSE_PROXY` is `nginx`, `apache`, `haproxy`, or `traefik`, the JSON
evidence includes a safe `reverseProxy.config` section. It proves the expected
proxy config file exists and contains this kit's managed marker for the app
without writing full filesystem paths to the evidence file.

Managed file updates create timestamped backups in `BACKUP_DIR` before
replacing existing env files, service units/init scripts, reverse proxy configs,
or health-check files. If `BACKUP_DIR` is not set, the scripts use
`/var/backups/<APP_NAME>`.

Health checks record `healthcheck.log` under `LOG_DIR` and `healthcheck.state`
under the root-owned `HEALTHCHECK_STATE_DIR`, which must stay outside
app-writable log directories. They prune old managed logs, diagnostics, and
backups using `LOG_RETENTION_DAYS`, `DIAGNOSTIC_RETENTION_DAYS`, and
`BACKUP_RETENTION_DAYS`.

8. Manual service install:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

The service installer runs configured `INSTALL_COMMAND` and `BUILD_COMMAND`
inside `APP_DIR` as the configured service user. Set `SKIP_INSTALL="true"` or
`SKIP_BUILD="true"` for artifact-only releases.

9. Optional config-selected reverse proxy:

```bash
sudo bash scripts/linux/install-reverse-proxy.sh config/linux/app.env
```

Set `REVERSE_PROXY` to `nginx`, `apache`, `haproxy`, `traefik`, or `none`.
Use `--dry-run` to print the installer that would run without requiring root.
The direct installers remain available when you need to target one proxy
explicitly:

```bash
sudo bash scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-haproxy-reverse-proxy.sh config/linux/app.env
sudo bash scripts/linux/install-traefik-reverse-proxy.sh config/linux/app.env
```

On Debian-family hosts, the Apache installer enables `proxy`, `proxy_http`, `proxy_wstunnel`, `headers`, and `rewrite`.

The HAProxy installer renders a complete config to `HAPROXY_CONFIG_FILE`, backs
up any previous file, validates with `haproxy -c`, and reloads/restarts HAProxy.
It refuses to replace an existing `/etc/haproxy/haproxy.cfg` unless that file is
already managed by this kit or `HAPROXY_ALLOW_MAIN_CONFIG_REPLACE="true"` is
set. Use it on a dedicated HAProxy instance, explicitly opt in, or point
`HAPROXY_CONFIG_FILE` at an app-specific config path that your HAProxy service
includes.

The Traefik installer writes a dynamic file provider config under
`TRAEFIK_DYNAMIC_DIR`. Your static Traefik config must already watch that
directory. The installer validates the rendered dynamic file through a temporary
Traefik file-provider config before reloading the service.

10. Optional Tomcat WAR deployment:

```bash
APP_RUNTIME="tomcat"
TOMCAT_WAR_FILE="/opt/releases/example.war"
TOMCAT_WEBAPPS_DIR="/var/lib/tomcat/webapps"
TOMCAT_CONTEXT_PATH="/example-node-app"
sudo bash scripts/linux/install-tomcat-app.sh config/linux/app.env
```

Tomcat mode deploys the WAR and restarts the configured `TOMCAT_SERVICE`. The
Node service installer is skipped when `APP_RUNTIME="tomcat"`.

14. Optional health check scheduler:

```bash
sudo bash scripts/linux/install-healthcheck-scheduler.sh config/linux/app.env
```

The scheduler installer delegates to the existing systemd timer installer for
`SERVICE_MANAGER="systemd"`, installs a launchd job for macOS, and installs a
managed root crontab entry for `systemv`, `openrc`, and `bsdrc`.

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

To uninstall the managed Unix service without deleting app, log, backup, or
health-state directories:

```bash
sudo bash scripts/linux/uninstall-node-service.sh config/linux/app.env
```

The uninstaller removes the managed service, app-specific health-check
script/config files, and the matching managed scheduler artifact: systemd timer
units, the launchd healthcheck plist, or the marked root crontab block used by
System V, OpenRC, and BSD rc deployments.
