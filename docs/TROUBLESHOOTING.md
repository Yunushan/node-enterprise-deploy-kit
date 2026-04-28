# Troubleshooting

## App is down on Windows

Run:

```powershell
Get-Service <AppName>
Get-Process node -ErrorAction SilentlyContinue | Select Id, CPU, PM, WS, StartTime, Path
Get-NetTCPConnection -LocalPort 3000 -State Listen
Invoke-WebRequest http://127.0.0.1:3000/health -UseBasicParsing
.\scripts\windows\Diagnose-NodeApp.ps1 -ConfigPath .\config\windows\app.config.json
```

Check logs:

```text
C:\logs\<AppName>\
```

## App is down on Linux

Run:

```bash
systemctl status <app-name>
journalctl -u <app-name> -n 200 --no-pager
service <app-name> status
rc-service <app-name> status
ss -ltnp | grep :3000
curl -i http://127.0.0.1:3000/health
./scripts/linux/diagnose-node-app.sh config/linux/app.env
```

## Common Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `npm.cmd Unexpected token ':'` | Node tried to execute `npm.cmd` as JavaScript | Run `node server.js`, or run npm via shell/cmd, not via Node interpreter |
| Port not listening | App did not start or crashed | Check stderr logs and service status |
| 502 from IIS/Nginx/Apache | Reverse proxy alive but Node backend down | Restart service and check Node logs |
| Works until user logs out | App was started manually | Install as service |
| Dies after 1–2 days | Memory leak, crash, idle recycle, or service not managed | Use health checks, service recovery, and analyze logs |
| PM2 list is empty | PM2 is not managing the app | Use WinSW or a native Linux service manager, or fix PM2 process definition |
