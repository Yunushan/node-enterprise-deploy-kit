# Variables

## Core Variables

| Variable | Windows JSON | Linux env | Description |
|---|---|---|---|
| App name | `AppName` | `APP_NAME` | Short service-safe name |
| Display name | `DisplayName` | `APP_DISPLAY_NAME` | Human-friendly service name |
| App directory | `AppDirectory` | `APP_DIR` | Application working directory |
| Start script | `StartCommand` | `START_SCRIPT` | JS entry point, usually `server.js` |
| Node binary | `NodeExe` | `NODE_BIN` | Node executable path |
| Port | `Port` | `APP_PORT` | Local Node.js port |
| Health URL | `HealthUrl` | `HEALTH_URL` | HTTP health probe URL |
| Log directory | `LogDirectory` | `LOG_DIR` | Production log directory |
| Reverse proxy | `ReverseProxy` | `REVERSE_PROXY` | Windows: `iis` or `none`; Linux: `nginx`, `apache`, or `none` |
| Service manager | `ServiceManager` | `SERVICE_MANAGER` | Windows: `winsw`, `nssm`, or `pm2`; Linux: `systemd`, `systemv`, or `openrc` |
| Apache site name | n/a | `APACHE_SITE_NAME` | Linux Apache virtual host name |
| Nginx site name | n/a | `NGINX_SITE_NAME` | Linux Nginx config name |

## Recommended Defaults

| Area | Default |
|---|---|
| Node bind address | `127.0.0.1` |
| Health endpoint | `/health` |
| Windows service manager | WinSW |
| Linux service manager | systemd |
| Windows reverse proxy | IIS |
| Linux reverse proxy | Nginx or Apache |
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
