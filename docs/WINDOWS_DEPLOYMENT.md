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

4. Install service:

```powershell
.\scripts\windows\Install-NodeService.ps1 -ConfigPath .\config\windows\app.config.json
```

5. Install IIS reverse proxy config:

```powershell
.\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
```

6. Register health check:

```powershell
.\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath .\config\windows\app.config.json
```

7. Verify:

```powershell
Get-Service ExampleNodeApp
Get-Process node
Get-NetTCPConnection -LocalPort 3000 -State Listen
Invoke-WebRequest http://127.0.0.1:3000/health -UseBasicParsing
```

## Service Recovery

The installer configures Windows Service Control Manager recovery:

```text
1st failure -> restart after 60 sec
2nd failure -> restart after 60 sec
3rd failure -> restart after 5 min
reset failure counter after 1 day
```
