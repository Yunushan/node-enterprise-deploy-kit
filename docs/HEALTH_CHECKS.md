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
```

It reports scheduled task last run, next run, last result, consecutive failure
state, last successful check, last failed check, and summarized health log event
counts.

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
```

The Linux health check writes `healthcheck.state` and `healthcheck.log` under
`LOG_DIR`. Use diagnostics for a safe summary:

```bash
bash scripts/linux/diagnose-node-app.sh config/linux/app.env
```

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
