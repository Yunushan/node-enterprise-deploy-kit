# Health Checks

## Recommended Endpoint

Create a lightweight endpoint in your application:

```js
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    uptime: process.uptime(),
    timestamp: new Date().toISOString()
  });
});
```

For Next.js API route:

```js
export default function handler(req, res) {
  res.status(200).json({ status: 'ok' });
}
```

## Health Check Layers

| Layer | Purpose |
|---|---|
| Service status | Confirms service manager sees the app as running |
| Port check | Confirms process listens on expected port |
| HTTP check | Confirms app can actually respond |

## Windows

Scheduled task runs `scripts/windows/Invoke-NodeHealthCheck.ps1`.

Recommended controls:

```json
{
  "HealthCheckFailureThreshold": 2,
  "HealthCheckRestartCooldownMinutes": 5,
  "HealthCheckTimeoutSeconds": 10
}
```

The service is restarted only after the configured number of consecutive HTTP
failures and only when the restart cooldown has elapsed.

The status command shows whether health checks have been passing over time
without printing health-check log contents:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
```

It reports scheduled task last run, next run, last result, consecutive failure
state, last successful check, last failed check, summarized health log event
counts, and a final operational verdict. It also verifies that the configured
port is owned by the configured service process tree, which helps distinguish a
proper service deployment from a manually started `node.exe`.

For long-running confidence after days of uptime, check these signals together:

| Signal | Healthy expectation |
|---|---|
| Service | `Running` and automatic startup |
| Service uptime | Meets your expected runtime window, for example 72 hours |
| Port ownership | Configured port is owned by the service process tree |
| HTTP health | 2xx/3xx response inside the configured timeout |
| Scheduled task | Recent successful run and no missed runs |
| Health state | Recent `LastSuccess`, zero consecutive failures |
| Health log summary | No recent restart loops or repeated failures |

## Linux

On systemd hosts, the systemd timer runs `/usr/local/sbin/<app-name>-healthcheck.sh`.

On System V, OpenRC, launchd, or BSD rc hosts, use
`scripts/linux/node-healthcheck.sh` from cron or your external monitoring
platform.

Recommended controls:

```bash
HEALTHCHECK_FAILURE_THRESHOLD="2"
HEALTHCHECK_RESTART_COOLDOWN="300"
HEALTHCHECK_TIMEOUT="10"
HEALTHCHECK_STATE_DIR="/var/lib/node-enterprise-deploy-kit/example-node-app"
```

The Linux health check writes `healthcheck.log` under `LOG_DIR` and writes
`healthcheck.state` under the root-owned `HEALTHCHECK_STATE_DIR`. Keep
`HEALTHCHECK_STATE_DIR` outside `LOG_DIR` so app-writable logs cannot influence
root-run health-check control state. Use diagnostics for a safe summary:

```bash
sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env
```

Linux diagnostics omit raw service logs, process command lines, and HTTP
response bodies by default. Use `--include-raw-details` only when the output can
be handled as sensitive incident data.

When `APP_RUNTIME="tomcat"`, the health check restarts `TOMCAT_SERVICE` instead
of the Node app service.

## Retention

Health checks also prune old managed files using these defaults:

| Area | Windows | Linux | Default |
|---|---|---|---|
| Logs | `LogRetentionDays` | `LOG_RETENTION_DAYS` | 30 days |
| Backups | `BackupRetentionDays` | `BACKUP_RETENTION_DAYS` | 90 days |
| Diagnostics | `DiagnosticRetentionDays` | `DIAGNOSTIC_RETENTION_DAYS` | 14 days |

Retention cleanup is intentionally age-based and only targets managed log,
diagnostic, and backup file patterns.
