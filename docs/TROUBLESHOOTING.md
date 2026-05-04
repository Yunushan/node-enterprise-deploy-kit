# Troubleshooting

## App is down on Windows

Run:

```powershell
Get-Service <AppName>
Get-Process node -ErrorAction SilentlyContinue | Select Id, CPU, PM, WS, StartTime, Path
Get-NetTCPConnection -LocalPort 3000 -State Listen
Invoke-WebRequest http://127.0.0.1:3000/health -UseBasicParsing
.\scripts\windows\Diagnose-NodeApp.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json
```

Before reinstalling, run:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json -AllowPortInUse
```

Check logs:

```text
C:\logs\<AppName>\
```

## App is down on Linux

Run:

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env --allow-port-in-use
systemctl status <app-name>
journalctl -u <app-name> -n 200 --no-pager
service <app-name> status
rc-service <app-name> status
launchctl print system/<app-name>
rcctl check <app-name>
ss -ltnp | grep :3000
curl -i http://127.0.0.1:3000/health
bash scripts/linux/diagnose-node-app.sh config/linux/app.env
cat /var/log/<app-name>/healthcheck.state
```

## Common Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `npm.cmd Unexpected token ':'` | Node tried to execute `npm.cmd` as JavaScript | Run `node server.js`, or run npm via shell/cmd, not via Node interpreter |
| Port not listening | App did not start or crashed | Check stderr logs and service status |
| 502 from IIS/Nginx/Apache/HAProxy/Traefik | Reverse proxy alive but backend down | Restart service and check app logs |
| Tomcat deploy fails | `TOMCAT_WAR_FILE` missing or wrong `TOMCAT_WEBAPPS_DIR` | Set the WAR path and Tomcat webapps directory for the target OS |
| Works until user logs out | App was started manually | Install as service |
| Dies after 1–2 days | Memory leak, crash, idle recycle, or service not managed | Use health checks, service recovery, and analyze logs |
| PM2 list is empty | PM2 is not managing the app | Use WinSW or a native Linux service manager, or fix PM2 process definition |
