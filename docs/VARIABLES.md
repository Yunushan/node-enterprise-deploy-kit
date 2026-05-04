# Variables

## Core Variables

| Variable | Windows JSON | Linux env | Description |
|---|---|---|---|
| App name | `AppName` | `APP_NAME` | Short service-safe name |
| Display name | `DisplayName` | `APP_DISPLAY_NAME` | Human-friendly service name |
| App runtime | n/a | `APP_RUNTIME` | `node` for Node.js service mode, `tomcat` for WAR deployment mode |
| App directory | `AppDirectory` | `APP_DIR` | Application working directory |
| Start script | `StartCommand` | `START_SCRIPT` | JS entry point, usually `server.js` |
| Node binary | `NodeExe` | `NODE_BIN` | Node executable path |
| Port | `Port` | `APP_PORT` | Local Node.js port |
| Health URL | `HealthUrl` | `HEALTH_URL` | HTTP health probe URL |
| Log directory | `LogDirectory` | `LOG_DIR` | Production log directory |
| Backup directory | `BackupDirectory` | `BACKUP_DIR` | Timestamped backups of overwritten service/proxy/health files |
| Reverse proxy | `ReverseProxy` | `REVERSE_PROXY` | Windows: `iis` or `none`; Unix-like: `nginx`, `apache`, `haproxy`, `traefik`, or `none` |
| Service manager | `ServiceManager` | `SERVICE_MANAGER` | Windows: `winsw`, `nssm`, or `pm2`; Unix-like: `systemd`, `systemv`, `openrc`, `launchd`, or `bsdrc` |
| Install command | `InstallCommand` | `INSTALL_COMMAND` | Production dependency install command |
| Build command | `BuildCommand` | `BUILD_COMMAND` | Optional application build command |
| Skip install | script flag | `SKIP_INSTALL` | Skip dependency install during artifact-only deployments |
| Skip build | script flag | `SKIP_BUILD` | Skip build command during artifact-only deployments |
| Skip preflight | script flag | `SKIP_PREFLIGHT` | Skip local deployment validation when intentionally bypassing checks |
| Allow port in use | script flag | `ALLOW_PORT_IN_USE` | Permit updates while the configured port is already listening |
| Skip reverse proxy | script flag | `SKIP_REVERSE_PROXY` | Install/update the service but leave proxy configuration unchanged |
| Skip health check | script flag | `SKIP_HEALTH_CHECK` | Install/update the service but leave health-check scheduling unchanged |
| Runtime env keys | `Environment` | `RUNTIME_ENV_KEYS` | Extra Linux config variables to write into the private service env file |
| Health failures | `HealthCheckFailureThreshold` | `HEALTHCHECK_FAILURE_THRESHOLD` | Consecutive failures before restart |
| Restart cooldown | `HealthCheckRestartCooldownMinutes` | `HEALTHCHECK_RESTART_COOLDOWN` | Minimum time between health-check restarts |
| Health timeout | `HealthCheckTimeoutSeconds` | `HEALTHCHECK_TIMEOUT` | HTTP health probe timeout |
| Log retention | `LogRetentionDays` | `LOG_RETENTION_DAYS` | Days to retain managed log files |
| Backup retention | `BackupRetentionDays` | `BACKUP_RETENTION_DAYS` | Days to retain managed backup files |
| Diagnostic retention | `DiagnosticRetentionDays` | `DIAGNOSTIC_RETENTION_DAYS` | Days to retain generated diagnostic bundles |
| IIS site | `IisSiteName` | n/a | Windows IIS site name |
| IIS app pool | `IisAppPoolName` | n/a | Windows IIS app pool name |
| IIS certificate | `IisCertificateThumbprint` | n/a | Optional LocalMachine\My certificate thumbprint |
| Apache site name | n/a | `APACHE_SITE_NAME` | Linux Apache virtual host name |
| Nginx site name | n/a | `NGINX_SITE_NAME` | Linux Nginx config name |
| HAProxy config | n/a | `HAPROXY_CONFIG_FILE` | Dedicated HAProxy config file to render and validate |
| HAProxy bind | n/a | `HAPROXY_BIND` | HAProxy frontend bind value, for example `*:80` |
| Traefik dynamic file | n/a | `TRAEFIK_DYNAMIC_FILE` | Dynamic Traefik provider file for the app router/service |
| Traefik entrypoint | n/a | `TRAEFIK_ENTRYPOINT` | Existing Traefik entrypoint name, usually `web` or `websecure` |
| Tomcat WAR | n/a | `TOMCAT_WAR_FILE` | WAR file to deploy when `APP_RUNTIME=tomcat` |
| Tomcat webapps dir | n/a | `TOMCAT_WEBAPPS_DIR` | Tomcat deployment directory |
| Tomcat context path | n/a | `TOMCAT_CONTEXT_PATH` | Public context path for the deployed WAR |

## Recommended Defaults

| Area | Default |
|---|---|
| Node bind address | `127.0.0.1` |
| Health endpoint | `/health` |
| Windows service manager | WinSW |
| Unix-like service manager | systemd on mainstream Linux, launchd on macOS, bsdrc on BSD |
| Windows reverse proxy | IIS |
| Unix-like reverse proxy | Nginx, Apache, HAProxy, or Traefik |
| Restart policy | Always restart after service failure |
| Health check | Every 1 minute |

## Sensitive Values

Put sensitive runtime values into a private environment file or a secret manager. Do not commit them.

Examples:

```text
DATABASE_URL
JWT_SECRET
API_TOKEN
SMTP_PASSWORD
COOKIE_SECRET
```
