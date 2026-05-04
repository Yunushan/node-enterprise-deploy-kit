# Windows Deployment

## Supported Windows Targets

- Windows 10
- Windows 11
- Windows Server 2012 / 2012 R2
- Windows Server 2016
- Windows Server 2019
- Windows Server 2022
- Windows Server 2025

Legacy systems may require compatibility testing for the chosen Node.js version.

## Recommended Production Pattern

```text
IIS HTTPS frontend -> 127.0.0.1:3000 -> WinSW Windows Service -> Node.js app
```

## Recommended Script Pattern

Use PowerShell for the real deployment logic and a small batch file only as
the double-click entrypoint:

```text
install.bat     -> convenience wrapper for elevated/manual use
install.ps1     -> install entrypoint; delegates to deploy.ps1
deploy.ps1      -> preflight, app preparation, service, proxy, health check
status.ps1      -> safe service/process/port/HTTP status check
restart.ps1     -> restart service and re-run status
uninstall.ps1   -> remove service and optional health check task
```

An `.exe` installer is usually unnecessary for server operations. Consider one
only when non-technical users need a signed wizard-style installer across many
machines.

## Steps

1. Verify the repository before deploying:

```powershell
.\scripts\dev\Test-Repository.ps1
```

2. Copy config:

```powershell
Copy-Item config\windows\app.config.example.json config\windows\app.config.json
```

3. Edit config:

```powershell
notepad config\windows\app.config.json
```

4. Place WinSW executable:

```text
tools\winsw\winsw-x64.exe
```

No service wrapper binaries are bundled in this repository.

5. Install using the one-command Windows wrapper:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

For double-click use, right-click `install.bat` and choose **Run as
administrator**. The batch file only starts PowerShell and pauses so the
operator can read the result.

The default install flow is:

```text
preflight -> InstallCommand -> BuildCommand -> service install/update -> IIS config -> health task
```

The WinSW installer writes safe runtime environment defaults into the service
XML when they are not already set in `Environment`: `NODE_ENV`, `PORT`,
`APP_PORT`, `APP_NAME`, `BIND_ADDRESS`, `HOST`, and `HOSTNAME`. This keeps the
service aligned with `Port` and `BindAddress` and helps Node/Next.js apps bind
to localhost behind IIS instead of opening a public listener.

`ServiceAccount` controls the Windows service logon account. Supported
values are `NetworkService`, `LocalService`, `LocalSystem`, a dedicated
local/domain account, or a group managed service account such as
`DOMAIN\ExampleNodeApp$`. Prefer `NetworkService` or a gMSA over `LocalSystem`
for production. Ordinary domain/local users require `ServiceAccountPassword`,
but a gMSA is preferred so no password has to be stored in deployment config.

When `ReverseProxy` is `iis`, the IIS installer writes `web.config`, configures
an always-running app pool, creates or updates the IIS site, and adds the
configured HTTP/HTTPS binding. If `TlsEnabled` is true and
`IisCertificateThumbprint` is empty or unavailable, certificate binding remains
an explicit manual step and the script prints a warning.

For production IIS reverse proxy deployments, install IIS URL Rewrite and
Application Request Routing before running the installer. By default,
`IisEnableArrProxy` enables ARR proxy mode, preserves the original `Host`
header, disables response host rewrites, and applies `IisProxyTimeoutSeconds`.
`IisSetForwardedHeaders` writes `X-Forwarded-Host`,
`X-Forwarded-Proto`, `X-Forwarded-Port`, and `X-Forwarded-For` from IIS URL
Rewrite so frameworks such as Next.js and Express can understand the public
request URL while Node.js remains bound to `127.0.0.1`. The installer also
adds a dedicated IIS health proxy path, controlled by `IisHealthProxyPath`,
which forwards to `HealthUrl`.

If the app uses WebSockets, install the IIS WebSocket Protocol feature and keep
`IisWebSocketSupport` enabled so preflight warns when the server is missing the
module. The script does not silently install Windows features; it checks and
configures the IIS pieces that are safe to manage after the prerequisite
modules exist.

Use these switches when needed:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json -SkipInstall -SkipBuild
.\install.ps1 -ConfigPath .\config\windows\app.config.json -AllowPortInUse
.\install.ps1 -ConfigPath .\config\windows\app.config.json -SkipReverseProxy -SkipHealthCheck
```

Preflight treats the configured service's own existing listener as a warning,
so normal service updates should not need `-AllowPortInUse`.

6. Optional lower-level commands:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Invoke-AppPreparation.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-NodeService.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath .\config\windows\app.config.json
```

7. Verify:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
```

The status command reports host uptime, service state, service wrapper uptime,
node processes, configured port listeners, whether the configured service owns
the listener, HTTP health latency, scheduled health-check freshness, health
history, and recent log file metadata without printing environment variables or
log contents. `-MinimumUptimeHours` is useful after a reboot or several days of
runtime because it warns when the service has restarted more recently than the
period you expected.

Managed file updates create timestamped backups in `BackupDirectory` before
replacing existing WinSW XML/exe files, IIS `web.config`, or the scheduled
health-check task definition. If `BackupDirectory` is not set, the scripts use
`<ServiceDirectory>\backups`.

8. Restart or uninstall:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

For managed config rollback, list available backups first, then restore a
specific target:

```powershell
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest -RecycleIisAppPool
.\status.ps1 -ConfigPath .\config\windows\app.config.json -FailOnCritical
```

Rollback restores only managed files created by this kit, such as WinSW XML,
WinSW executable backups, IIS `web.config`, and scheduled task exports. Restore
the previous application release or database separately when those changed.

The WinSW template and installer set the service startup mode to `Automatic`,
so the app is expected to start again after a Windows reboot as long as the
service installation succeeds and the configured app path is still valid.

The scheduled health check uses `HealthCheckFailureThreshold` and
`HealthCheckRestartCooldownMinutes` to avoid restart loops during short outages.
It also records state under `LogDirectory` and prunes old managed logs,
diagnostics, and backups using `LogRetentionDays`, `DiagnosticRetentionDays`,
and `BackupRetentionDays`.

## Service Recovery

The installer configures Windows Service Control Manager recovery:

```text
1st failure -> restart after 60 sec
2nd failure -> restart after 60 sec
3rd failure -> restart after 5 min
reset failure counter after 1 day
```
