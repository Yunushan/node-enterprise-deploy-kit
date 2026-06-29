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

For Next.js App Router, create `app/health/route.ts`:

```ts
export function GET() {
  return Response.json({ status: 'ok' });
}
```

For Next.js Pages Router, create `pages/api/health.ts`:

```ts
export default function handler(_req, res) {
  res.status(200).json({ status: 'ok' });
}
```

Point `HealthUrl` or `HEALTH_URL` at the route that actually exists in the
deployed app. For example, use `/health` for the App Router example or
`/api/health` for the Pages Router example.

## Health Check Layers

| Layer | Purpose |
|---|---|
| Service status | Confirms service manager sees the app as running |
| Boot enablement | Confirms service manager is configured to start the app after reboot |
| Port check | Confirms process listens on expected port |
| HTTP check | Confirms app can actually respond |

## Windows

Scheduled task runs `scripts/windows/Invoke-NodeHealthCheck.ps1`.
When the task is registered, `Register-HealthCheckTask.ps1` resolves
`-ConfigPath` to an absolute path before writing the scheduled task action.
That keeps manually registered tasks working when Windows later runs them as
`SYSTEM` from a different working directory.

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
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
```

It reports scheduled task last run, next run, last result, consecutive failure
state, last successful check, last failed check, summarized health log event
counts, service startup mode, and a final operational verdict. It also verifies
that the Windows service definition still matches the current `NodeExe`,
`AppDirectory`, `StartCommand`, and `NodeArguments`, and that the scheduled task
action points at this kit's health-check script and the current deployment
config path. The configured port must be owned by the configured service process
tree, which helps distinguish a proper service deployment from a manually
started `node.exe`.

Use `-JsonPath` when you need auditable post-deploy evidence. The JSON output
contains the verdict, counts, safe health URL, port ownership proof,
structured HTTP health proof, uptime proof, recurring health monitor proof,
deployment/build identity, and findings only; it does not include environment
values or raw log contents.
It also avoids raw host identity and full filesystem paths by using file or
directory basenames in machine-readable evidence.
For IIS reverse-proxy deployments, status evidence also probes the configured
health proxy path. Set `ProxyHealthUrl` when the default local probe is not the
right endpoint for your topology. IIS evidence additionally records whether the
configured site exists and is started, points at the configured deployment path,
owns the expected public binding, and has no duplicate binding conflict.
Status evidence emits the configured deployment ID, private runtime deployment
ID, or Next.js `.next/BUILD_ID` when one is available.
Validate collected evidence with
[`Test-HostEvidence.ps1`](../scripts/dev/Test-HostEvidence.ps1) as described in
[Host Verification Evidence](HOST_VERIFICATION.md).

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

On systemd hosts, the systemd timer runs
`/usr/local/sbin/<app-name>-healthcheck.sh`. On macOS, a launchd job runs the
same script. On System V, OpenRC, or BSD rc hosts, a managed root crontab entry
runs the same script.

The deploy flow installs the right scheduler automatically unless
`SKIP_HEALTH_CHECK="true"`. Unix preflight fails before deployment changes are
made if the selected scheduler command is missing: `systemctl` for systemd,
`launchctl` for macOS launchd, or `crontab` for System V, OpenRC, and BSD rc
hosts. If `SERVICE_MANAGER` is omitted, the installed health-check script uses
the same host-aware default as deploy/status/diagnostics so recovery calls the
right service manager. You can also install only the scheduler:

```bash
sudo bash scripts/linux/install-healthcheck-scheduler.sh config/linux/app.env
```

`scripts/linux/uninstall-node-service.sh` removes the managed health-check
scheduler for the selected service manager too: systemd timer units, the macOS
launchd healthcheck plist, or the marked root crontab block used by System V,
OpenRC, and BSD rc. It also removes the app-specific copied healthcheck script
and config, but leaves logs, backups, and health-state history for audit.

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
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --json-output ./evidence/unix-status.json --fail-on-critical
sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env
```

The status command prints an operational verdict and can fail automation when
critical findings exist. It checks service status, configured port listener,
boot enablement, HTTP health, health-check state, health-check log summary, and
framework-specific runtime layout where available. It also emits
`serviceDefinition` proof that the managed systemd, System V, OpenRC, launchd,
or BSD rc definition still matches the current `NODE_BIN`, `APP_DIR`,
`START_SCRIPT`, and `NODE_ARGUMENTS`.

Use `--json-output` to write safe machine-readable evidence for Linux, macOS,
and BSD hosts. The file is suitable for release records and support reviews
because it captures the operational verdict without dumping secrets, raw logs,
raw host identity, full filesystem paths, or HTTP response bodies.
It also includes structured configured-port evidence: checked/listening state,
whether owner PIDs were readable, and whether the listener is owned by the
configured service process.
It includes structured HTTP health evidence too: checked state, sanitized URL,
status, status code, response time, and timeout.
It also records service process uptime and whether the requested
`-MinimumUptimeHours` window was satisfied.
The JSON also includes `healthMonitor` evidence. For a fully proven host this
should show `status=ok`, a recent successful monitor run, zero consecutive
failures, an existing recent log summary, and zero recent monitor failures or
service restarts. On systemd hosts it records whether the
`<app-name>-healthcheck.timer` scheduler was checked, exists, is active, and is
enabled for boot. On macOS it records the launchd healthcheck job. On
cron-based hosts it records the managed crontab entry and best-effort cron
daemon activity.
For reverse-proxy deployments, status evidence probes `PROXY_HEALTH_URL` when
configured, otherwise it probes `http://127.0.0.1:<PROXY_LISTEN_PORT>/<HEALTHCHECK_PATH>`.
For Nginx, Apache, HAProxy, and Traefik, JSON evidence also records whether the
expected managed proxy config file exists and contains this kit's marker for
the app, using only safe file and directory basenames.
Validate collected evidence with
[`Test-HostEvidence.ps1`](../scripts/dev/Test-HostEvidence.ps1) as described in
[Host Verification Evidence](HOST_VERIFICATION.md).

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
