# Operations Runbook

## Normal Deployment

1. Run repository verification before release.
2. Pull or copy release artifact.
3. Run target preflight checks.
4. Install dependencies or unpack built artifact.
5. Run build command if needed.
6. Install/update service.
7. Restart service.
8. Verify health endpoint.
9. Verify reverse proxy response.
10. Confirm logs and monitoring.

Repository verification:

```powershell
.\scripts\dev\Test-Repository.ps1
```

## Windows Commands

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
.\install.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.\scripts\windows\Diagnose-NodeApp.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
Get-ScheduledTaskInfo -TaskName <AppName>-HealthCheck
Get-Service <AppName>
Restart-Service <AppName>
Get-EventLog Application -Newest 50
```

## Linux Commands

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
bash deploy.sh config/linux/app.env
bash scripts/linux/diagnose-node-app.sh config/linux/app.env
systemctl status <app-name>
systemctl restart <app-name>
journalctl -u <app-name> -n 200 --no-pager
service <app-name> restart
rc-service <app-name> restart
launchctl print system/<app-name>
sudo launchctl kickstart -k system/<app-name>
rcctl check <app-name>
rcctl restart <app-name>
```

Reverse proxy checks:

```bash
nginx -t
apache2ctl configtest || httpd -t
haproxy -c -f /etc/haproxy/haproxy.cfg
traefik check --configFile=/etc/traefik/traefik.yml
```

## Emergency Recovery

If the application is unresponsive:

1. Run diagnostics.
2. Restart service.
3. Check port and health URL.
4. Check reverse proxy logs.
5. Roll back to previous release if new deployment caused the issue.

Rollback helpers:

```powershell
Get-ChildItem C:\services\<AppName>\backups | Sort-Object LastWriteTime -Descending | Select-Object -First 10
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest -RecycleIisAppPool
.\status.ps1 -ConfigPath .\config\windows\app.config.json -FailOnCritical
```

```bash
sudo find /var/backups/<app-name> -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' | sort -r | head
```

Long-running health checks:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
```

For Windows, treat the deployment as healthy only when the operational verdict
has no critical findings, the service is running with automatic startup, the
configured port is owned by the configured service process tree, the HTTP health
probe succeeds, and the scheduled health check has a recent successful run.

```bash
sudo cat /var/log/<app-name>/healthcheck.state
sudo grep -Ec ' OK |FAILED|RESTARTING_SERVICE|RESTART_SUPPRESSED' /var/log/<app-name>/healthcheck.log
```
