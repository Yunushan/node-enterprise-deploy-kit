# Operations Runbook

## Normal Deployment

1. Pull or copy release artifact.
2. Run preflight checks.
3. Install dependencies or unpack built artifact.
4. Run build command if needed.
5. Install/update service.
6. Restart service.
7. Verify health endpoint.
8. Verify reverse proxy response.
9. Confirm logs and monitoring.

## Windows Commands

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
.\install.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json
Get-Service <AppName>
Restart-Service <AppName>
Get-EventLog Application -Newest 50
```

## Linux Commands

```bash
systemctl status <app-name>
systemctl restart <app-name>
journalctl -u <app-name> -n 200 --no-pager
service <app-name> restart
rc-service <app-name> restart
```

## Emergency Recovery

If the application is unresponsive:

1. Run diagnostics.
2. Restart service.
3. Check port and health URL.
4. Check reverse proxy logs.
5. Roll back to previous release if new deployment caused the issue.
