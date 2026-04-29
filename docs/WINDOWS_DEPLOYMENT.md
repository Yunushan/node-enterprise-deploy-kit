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
deploy.ps1      -> service, reverse proxy, and health check installer
status.ps1      -> safe service/process/port/HTTP status check
restart.ps1     -> restart service and re-run status
uninstall.ps1   -> remove service and optional health check task
```

An `.exe` installer is usually unnecessary for server operations. Consider one
only when non-technical users need a signed wizard-style installer across many
machines.

## Steps

1. Copy config:

```powershell
Copy-Item config\windows\app.config.example.json config\windows\app.config.json
```

2. Edit config:

```powershell
notepad config\windows\app.config.json
```

3. Place WinSW executable:

```text
tools\winsw\winsw-x64.exe
```

No service wrapper binaries are bundled in this repository.

4. Install using the one-command Windows wrapper:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

For double-click use, right-click `install.bat` and choose **Run as
administrator**. The batch file only starts PowerShell and pauses so the
operator can read the result.

5. Optional lower-level commands:

```powershell
.\scripts\windows\Install-NodeService.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath .\config\windows\app.config.json
```

6. Verify:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
```

The status command reports service state, node processes, configured port
listeners, HTTP health, and recent log file metadata without printing
environment variables or log contents.

7. Restart or uninstall:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

## Service Recovery

The installer configures Windows Service Control Manager recovery:

```text
1st failure -> restart after 60 sec
2nd failure -> restart after 60 sec
3rd failure -> restart after 5 min
reset failure counter after 1 day
```
