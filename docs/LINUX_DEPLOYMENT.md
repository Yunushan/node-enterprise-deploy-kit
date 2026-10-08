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

The framework minimum remains Node.js `20.9.0`, while production deployment
requires a maintained release line. The reviewed policy permits Node.js 22, 24,
and 26 during their support windows and recommends 24. Node.js 20 reached its
policy end date on 2026-04-30. Preflight reads `config/node-runtime-policy.json`
and rejects expired, future, and unreviewed release lines, including generic
Node applications and the Node validator used by Tomcat with Traefik. It also
checks the selected Node line's macOS minimum when running on macOS.
GNU/Linux rows require the selected line's kernel/glibc runtime floor.
Alpine/musl and FreeBSD are tracked as Experimental Node runtime
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

Node and Tomcat installers do not report success until `HEALTH_URL` returns an
HTTP `2xx` response. The default gate uses 12 attempts, a five-second delay, and
the configured `HEALTHCHECK_TIMEOUT`. Keep
`REQUIRE_POST_DEPLOY_HEALTH_CHECK=true`; an explicit false value is reserved for
deployments with another audited health gate.

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
REQUIRE_PACKAGE_SHA256="true"
PACKAGE_EXPECTED_SHA256="<64-character SHA-256 digest>"
PACKAGE_MAX_ARCHIVE_SIZE_MB="2048"
PACKAGE_MAX_EXTRACTED_SIZE_MB="8192"
PACKAGE_MAX_ENTRY_COUNT="200000"
PACKAGE_MAX_COMPRESSION_RATIO="200"
PACKAGE_MINIMUM_FREE_SPACE_MB="1024"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR="true"
bash deploy.sh config/linux/app.env
```

For an artifact selected at deployment time, pass the path and digest as the
second and third wrapper arguments instead of editing the config:

```bash
package="/opt/releases/example-node-app.tar.gz"
package_sha256="$(sha256sum "$package" | awk '{print $1}')"
bash deploy.sh config/linux/app.env "$package" "$package_sha256"
```

Linux package import supports `.tar.gz`, `.tgz`, `.tar`, and `.zip`. It
copies the selected artifact to a unique temporary work directory, verifies the
caller-supplied SHA-256, validates archive member paths, rejects duplicate or
case-colliding paths and link/special-file entries before extraction, and
extracts to a temporary directory, checks `PACKAGE_EXPECTED_FILES`, backs up
`APP_DIR`, then imports the new contents within the wrapper's quiesced transaction.
Direct standalone import is limited to staging without a registered service or
installed monitor; use `deploy.sh` to update an existing deployment.
`REQUIRE_PACKAGE_SHA256` defaults to `true`; a missing, malformed, or mismatched
digest fails before the service is stopped or `APP_DIR` is replaced.
Preflight and import also cap archive bytes, extracted logical bytes, entry
count, and compression ratio. They calculate projected free-space needs for
the temporary work area, `APP_DIR`, and `BACKUP_DIR`, combining workloads that
share a filesystem and preserving `PACKAGE_MINIMUM_FREE_SPACE_MB` afterward.
The staged archive and extracted tree are rechecked before service interruption
or live-directory replacement. See [Variables](VARIABLES.md) for defaults.

After validation, import records whether the configured systemd, SysV,
OpenRC, launchd, or BSD rc service is running and verifies that it stops before
replacing files. The persistent package record names the planned backup before
the existing `APP_DIR` moves, and distinguishes a prepared replacement from a
completed copy. This preserves recovery information if import is interrupted
before its manifest is written. If
copying the release or writing its deployment manifest fails, import removes
the partial directory, restores the previous one, and restarts the service only
when it was running before import. If directory restoration fails, the service
is intentionally left stopped and import emits a critical recovery message;
repair `APP_DIR` before starting it manually.

When import runs through `deploy.sh`, its transaction remains active through
service installation, reverse-proxy configuration, and health-scheduler setup.
A downstream failure restores the previous `APP_DIR` and running/stopped state;
on a failed first deployment it also removes the newly created native service.
The wrapper also journals managed environment files, native units, proxy files,
Apache module/site links, scheduler files, and application boot registration.
Recovery restores previous service and scheduler running intent and enablement,
then validates the previous HTTP endpoint. Shared crontab and BSD rc settings
are restored only for this application so unrelated entries are preserved.
Installers called directly use the same protected journal for their changes.
Before application mutation the wrapper stops existing native health timers,
workers, or launchd jobs and removes this application's marked cron block.
Already running privileged cron invokers must exit within
`HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS` (default 30, range 0–300); otherwise the
deployment fails before changing application files. This also protects upgrades
from older monitor scripts that did not understand the deployment lock.
Standalone installers and deployments that skip health installation resume the
previous scheduler after success.

The package transaction record contains operational paths and booleans. The
managed configuration journal also contains previous private configuration and
file contents and is protected by a root-owned mode `0700` directory. Journals
are removed after success or successful recovery. A recovery failure preserves
the journal under `DEPLOYMENT_TRANSACTION_ROOT` (default
`/var/lib/node-enterprise-deploy-kit/deployment-transactions`) and prints its
path. This protected directory persists across reboot; keep any override on
persistent storage. Leave the application stopped when directory recovery was unsafe; inspect
the recorded backup and journal before attempting manual recovery.
New deployments and standalone installers refuse retained managed journals or
package transaction state for the application. The health monitor also defers
HTTP probing, restarts, rotation, and retention while that recovery evidence is
present, even if an abandoned mutex was removed. Recovery is explicit; retained
journals are never automatically replayed or discarded by a later deployment.
The guard checks both the persistent directory and legacy journals beside the
volatile app lock, so removing or losing `/var/run` does not remove recovery
evidence from a new deployment.

Mutations hold both the application lock and a shared native-service/proxy lock.
The shared lock serializes repository operations across application names,
including Apache registration and proxy reloads. It waits up to 60 seconds by
default (`SHARED_CONTROL_LOCK_TIMEOUT_SECONDS`, range 0–3600), uses
`SHARED_CONTROL_LOCK_ROOT` (default `/var/run/node-enterprise-deploy-kit`, or
`/var/lib/node-enterprise-deploy-kit/locks` on macOS), and
never steals an apparently stale lock. Children inherit a protected ownership
token and cannot release their parent's lock. An operator must inspect an
abandoned lock's owner before removing it after confirming no operation remains.

macOS uses the same protected default for `DEPLOYMENT_LOCK_ROOT` because its
native `/var/run` may be group-writable. Existing explicit lock overrides are
preserved and must have trusted ancestors. When migrating a lock location, stop
the app's health monitor and finish every deployment using the old location,
then update all operations and the monitor together before restarting them.

Updates preserve the service manager, Node/Tomcat runtime, proxy type, and
Tomcat service identity recorded in the previous protected monitor config.
Changing those selections requires an explicit migration: use the previous
configuration to stop and unregister its service and monitoring, remove its old
proxy routes, then deploy the new selection. The update wrapper rejects a known
identity change before stopping either service or modifying application files.

Service installation is fail closed. Required ownership changes must succeed,
the native service must be registered for boot, and the manager must report it
running before installation returns success. Health-check setup also verifies
its systemd timer, launchd job, or managed root crontab entry. An ownership,
enablement, or active-state error is a failed deployment, not an informational
warning.

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

Health checks record `healthcheck.log` under `HEALTHCHECK_LOG_DIR` (default
`HEALTHCHECK_STATE_DIR/logs`) and `healthcheck.state` under the root-owned
`HEALTHCHECK_STATE_DIR`. Diagnostics default to `HEALTHCHECK_STATE_DIR/diagnostics`.
These directories must stay outside app-writable paths. Monitor and application
logs rotate at 10 MiB with seven generations by default; application logs rotate
as the service user and keep the active inode. Age cleanup targets rotated
monitor logs, diagnostics, configuration backups, and timestamped application
backup directories. See [Health Checks](HEALTH_CHECKS.md) for rotation settings.

8. Manual service install:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

The service installer runs configured `INSTALL_COMMAND` and `BUILD_COMMAND`
inside `APP_DIR` as the configured service user. Set `SKIP_INSTALL="true"` or
`SKIP_BUILD="true"` for artifact-only releases.

System V and BSD services keep root-owned PID and process-identity files. When
upgrading from a legacy service-owned PID directory, stop the old service and
remove its old `/var/run/<APP_NAME>` PID directory before installation. The new
scripts refuse to signal processes based on untrusted or mismatched PID data.
Identity uses the service UID and process start time (kernel start ticks on
Linux), so legitimate changes to Node's `process.title` remain supported.
BSD scripts use native `rc.subr`; OpenBSD requires `APP_NAME` to be a shell
identifier, such as `example_next_bsd`. Native reboot and lifecycle evidence is
still required for each supported BSD platform.

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
directory. The installer starts a disposable actual Traefik instance using
loopback and ephemeral ports, then verifies that its API reports the managed
router and service as enabled before reloading the installed service. This
validation requires the approved `NODE_BIN`, including Tomcat deployments that
choose Traefik. The application entrypoint name cannot be `traefik`, which the
validator reserves for its loopback API. A production proxy health probe and
native provider-watch configuration remain part of host verification.

The default status proxy probe connects over HTTP to the loopback proxy port,
preserves `HEALTHCHECK_PATH` (including `/`), and sends `PUBLIC_HOSTNAME` as the
Host header for virtual-host routing. If the proxy itself terminates TLS, set
`PROXY_HEALTH_URL` to the actual HTTPS endpoint and configure trusted certificate
and hostname resolution for the collector. Status evidence requires HTTP 2xx
and does not follow redirects, matching deployment checks and the health monitor.

The generated route contains no credentials and is installed root-owned with
mode `0644`, so a non-root Traefik process can read it. New provider directories
use mode `0755`; permissions on existing directories are preserved. Ensure the
proxy account can traverse those directories and read its separate TLS
configuration and certificates. Keep certificate private keys restricted to
the proxy account and administrators. The disposable validator runs as the
installer's privileged user, so its success does not prove that the installed
proxy account can read the provider files; verify the actual HTTPS route.

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
