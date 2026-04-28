# Operations Runbook

## Normal Deployment

1. Pull or copy release artifact.
2. Install dependencies or unpack built artifact.
3. Run build command if needed.
4. Install/update service.
5. Restart service.
6. Verify health endpoint.
7. Verify reverse proxy response.
8. Confirm logs and monitoring.

## Windows Commands

```powershell
Get-Service <AppName>
Restart-Service <AppName>
Get-EventLog Application -Newest 50
```

## Linux Commands

```bash
systemctl status <app-name>
systemctl restart <app-name>
journalctl -u <app-name> -n 200 --no-pager
```

## Emergency Recovery

If the application is unresponsive:

1. Run diagnostics.
2. Restart service.
3. Check port and health URL.
4. Check reverse proxy logs.
5. Roll back to previous release if new deployment caused the issue.
