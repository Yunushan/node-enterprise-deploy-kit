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
| Reverse proxy | `ReverseProxy` | `REVERSE_PROXY` | `iis`, `nginx`, or `none` |
| Service manager | `ServiceManager` | `SERVICE_MANAGER` | `winsw`, `nssm`, `pm2`, `systemd` |

## Recommended Defaults

| Area | Default |
|---|---|
| Node bind address | `127.0.0.1` |
| Health endpoint | `/health` |
| Windows service manager | WinSW |
| Linux service manager | systemd |
| Windows reverse proxy | IIS |
| Linux reverse proxy | Nginx |
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
