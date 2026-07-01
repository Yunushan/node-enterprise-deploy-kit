# Windows Deployment

## Supported Windows Targets

- Windows 10
- Windows 11
- Windows Server 2012 / 2012 R2
- Windows Server 2016
- Windows Server 2019
- Windows Server 2022
- Windows Server 2025

Current Next.js requires Node.js `20.9.0` or newer. For Node.js 20.x, Windows
10 and Windows Server 2016 or newer are the production-recommended Windows
runtime targets in this kit. Windows Server 2012 / 2012 R2 remains in the
matrix for legacy migration evidence, but it is marked as an Experimental
Node.js runtime target and is not production-recommended for current Next.js
deployments.

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
deploy.ps1      -> preflight, optional package import, app preparation, service, proxy, health check
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

4. Let the installer fetch WinSW automatically, or place your internal copy:

```text
tools\winsw\winsw-x64.exe
```

No service wrapper binaries are bundled in this repository. By default,
`AutoDownloadWinSW` downloads the pinned stable WinSW executable from
`WinSWDownloadUrl` if the local file is missing, and
`RequireWinSWDownloadSha256` requires `WinSWDownloadSha256` to verify the
downloaded or existing executable. The sample config pins the official WinSW
v2.12.0 x64 digest. Set `AutoDownloadWinSW` to `false` when the server is
offline or your organization requires a trusted internal artifact source; set
`RequireWinSWDownloadSha256` to `false` only when that internal source verifies
WinSW outside this kit.

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
preflight -> optional package import -> InstallCommand -> BuildCommand -> service install/update -> IIS config -> health task
```

To deploy a built `.zip` artifact, set `PackagePath` in config or pass
`-PackagePath` to the wrapper:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json `
  -PackagePath C:\deploy\example-node-app.zip `
  -SkipInstall -SkipBuild
```

Windows package import supports `.zip` with built-in .NET extraction. It
validates archive paths before extraction, extracts to a temporary directory,
rejects symlink, reparse-point, and special-file entries, checks
`PackageExpectedFiles`, stops the service if it exists, backs up the current
`AppDirectory`, then imports the new package contents.
`PackageExpectedFiles` may name files or directories, so Next.js standalone
packages can require `server.js`, `.next/BUILD_ID`, and `.next/static`. `.rar` and `.7z` are
intentionally unsupported because they require external tooling and a larger
security surface.

For React deployments, ship the Node entrypoint that serves the SPA plus the
static build root containing `index.html`. Create React App commonly uses
`ReactDocumentRoot: "build"` and Vite commonly uses `"dist"`. Validate the zip
before deployment:

```powershell
.\scripts\windows\Test-ReactStaticPackage.ps1 `
  -PackagePath C:\deploy\example-react-app.zip `
  -ReactDocumentRoot build `
  -StripSingleTopLevelDirectory
```

The Windows package import flow runs this validator automatically when
`AppFramework` is `react`, `reactjs`, or `react-js`.

For TanStack Start or Vite apps that build to a static SPA, use
`DeploymentMode: "static_iis"` instead of a Node service. This mode runs the
configured npm commands, validates `StaticOutputDirectory`, accepts
`SpaShellFile: "_shell.html"` as the browser entry file, copies only the static
output contents to the IIS physical path, configures an IIS app pool with
No Managed Code, and restarts the IIS site/app pool. It does not require a
Node service, URL Rewrite, or ARR.

Use the placeholder example config as the starting point:

```powershell
Copy-Item config\windows\static-iis.app.config.example.json config\windows\app.config.json
```

The important static IIS values are:

```json
{
  "AppName": "ExampleStaticSpa",
  "DeploymentMode": "static_iis",
  "AppFramework": "tanstack-start",
  "StaticOutputDirectory": "dist/client",
  "SpaShellFile": "_shell.html",
  "InstallCommand": "npm ci --include=dev",
  "BuildCommand": "npm run build",
  "ServiceManager": "none",
  "ReverseProxy": "iis",
  "IisSiteName": "ExampleStaticSpa",
  "IisSitePath": "C:\\inetpub\\ExampleStaticSpa",
  "PublicHostName": "app.example.local",
  "IisRequireUrlRewrite": false,
  "IisRequireArrProxy": false,
  "IisStaticAllowUrlRewrite": false
}
```

For Vite-only SPAs, set `AppFramework` to `vite-spa`. If you import a zip, the
static package validator accepts `_shell.html`, `assets`, and a plain IIS
`web.config` under `dist/client` without requiring `server.js`:

```powershell
.\scripts\windows\Test-StaticIisPackage.ps1 `
  -PackagePath C:\deploy\example-static-spa.zip `
  -StaticOutputDirectory dist/client `
  -SpaShellFile _shell.html `
  -StripSingleTopLevelDirectory
```

If `dist\client\web.config` is present, `static_iis` validates it as XML and
rejects `<rewrite>` unless `IisStaticAllowUrlRewrite` is explicitly enabled for
a separate rewrite mode. If no `web.config` is present in the built output, the
IIS static installer generates this plain IIS config:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <remove fileExtension=".json" />
      <remove fileExtension=".webmanifest" />
      <remove fileExtension=".mjs" />
      <remove fileExtension=".wasm" />
      <remove fileExtension=".svg" />
      <remove fileExtension=".woff2" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
      <mimeMap fileExtension=".webmanifest" mimeType="application/manifest+json" />
      <mimeMap fileExtension=".mjs" mimeType="text/javascript" />
      <mimeMap fileExtension=".wasm" mimeType="application/wasm" />
      <mimeMap fileExtension=".svg" mimeType="image/svg+xml" />
      <mimeMap fileExtension=".woff2" mimeType="font/woff2" />
    </staticContent>

    <defaultDocument enabled="true">
      <files>
        <clear />
        <add value="_shell.html" />
        <add value="index.html" />
      </files>
    </defaultDocument>

    <httpErrors errorMode="Custom" existingResponse="Replace">
      <remove statusCode="404" subStatusCode="-1" />
      <error statusCode="404" path="/_shell.html" responseMode="ExecuteURL" />
    </httpErrors>
  </system.webServer>
</configuration>
```

Static IIS preflight checks that IIS and the Static Content feature are
installed, the deploy path exists or can be created, the deploy user can write
there, any existing `web.config` is valid plain IIS XML, the deployed folder
contains the configured SPA shell when it already has content, and unsupported
`<rewrite>` sections are absent. During deployment, the previous static folder
contents are backed up under `BackupDirectory` before replacement so rollback
can restore the earlier files.

For Next.js standalone deployments, build with `output: 'standalone'`, package
the contents of `.next\standalone`, and copy `.next\static` to
`.next\standalone\.next\static` before creating the zip. Copy `public` to
`.next\standalone\public` too when the app uses public files. Use:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip
```

The package helper blocks obvious private files such as `.env`, private keys,
and certificates from the staged artifact before it creates the zip. Configure
the deployment with:

```powershell
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip
```

For full-app `next-start` packages, add `-Mode next-start` to the same helper:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip `
  -Mode next-start
```

In that mode the helper stages `package.json`, `.next`, production
`node_modules`, optional `public`, and common Next.js config/lock files. Run
the validator on any zip that did not come directly from the helper. The
Windows package import flow also runs this validator automatically when
`AppFramework` is `nextjs` and `NextjsDeploymentMode` is `standalone` or
`next-start`.

```json
{
  "AppFramework": "nextjs",
  "NextjsDeploymentMode": "standalone",
  "NextjsRequireStaticAssets": true,
  "NextjsRequirePublicDirectory": false,
  "NextjsRequireServerActionsEncryptionKey": false,
  "NextjsRequireDeploymentId": false,
  "NextjsMinimumNodeVersion": "20.9.0",
  "StartCommand": "server.js",
  "PackageExpectedFiles": [
    "server.js",
    ".next/BUILD_ID",
    ".next/static"
  ]
}
```

For full-app `next-start` services, start from
`config/windows/next-start.app.config.example.json` or set:

```json
{
  "NextjsDeploymentMode": "next-start",
  "StartCommand": "node_modules\\next\\dist\\bin\\next",
  "NodeArguments": "start -H 127.0.0.1",
  "PackageExpectedFiles": ["package.json", ".next", ".next/BUILD_ID", "node_modules/next/dist/bin/next"]
}
```

The Windows preflight validates the selected Next.js mode and the deployed
runtime layout before replacing service/proxy configuration. See
[Next.js Deployment](NEXTJS_DEPLOYMENT.md) for build, packaging, and
multi-instance notes.

To check only the live Next.js folder structure after package import or manual
copy, run:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

After deployment, `status.ps1` and `scripts/windows/Diagnose-NodeApp.ps1`
include a safe Next.js runtime layout section when `AppFramework=nextjs`.
Use it to confirm the live folder still contains the expected standalone or
`next-start` files without printing private environment values.
The status JSON also includes `HealthMonitor` evidence from the scheduled
health-check task, state file, and recent health-check log summary. It also
includes `ServiceDefinition` evidence proving that WinSW, NSSM, or the PM2
ecosystem file still matches the current `NodeExe`, `AppDirectory`,
`StartCommand`, and `NodeArguments`. The task action must run this kit's
health-check script with the current deployment config path, so stale services
or health-check tasks from older releases are not accepted as production proof.
For a fully proven production host, collect evidence after the monitor has
completed successfully and after the requested uptime window, not immediately
after the first service start.

For live RDP/VPN operations where each release is already extracted to a new
timestamped folder, use the latest-release helper instead of moving the current
live folder:

```powershell
.\scripts\windows\Deploy-LatestRelease.ps1 `
  -ConfigPath .\config\windows\app.config.json `
  -ReleaseRoot C:\inetpub\wwwroot `
  -ReleasePattern "example-node-app-IIS-deploy-*" `
  -HealthPath "/" `
  -TakeOverPublicPortBinding `
  -SkipWinSWDownload
```

This creates a generated runtime config that points `AppDirectory` and
`IisSitePath` to the newest matching release folder, runs the normal Windows
deployment flow with package import/install/build disabled, registers health
checks, and runs `status.ps1`. The previous live folder is left in place. If
another IIS site already owns the configured public binding, the helper fails by
default; `-TakeOverPublicPortBinding` removes the conflicting binding only when
you intentionally want the configured site to take over that port. The helper
uses `TlsEnabled` to inspect `http` or `https`, defaults the public port to `80`
or `443` when `PublicPort` is unset, and rollback restores the previous IIS
physical path, app pool, and started/stopped site state. The generated runtime
config is retained under `<ServiceDirectory>\config` by default because the
Windows scheduled health-check task reads that exact config path after
deployment.

The Windows service installers write safe runtime environment defaults when
they are not already set in `Environment`: `NODE_ENV`, `PORT`, `APP_PORT`,
`APP_NAME`, `BIND_ADDRESS`, `HOST`, and `HOSTNAME`. WinSW writes them into the
service XML, NSSM writes them to `AppEnvironmentExtra`, and the PM2 fallback
writes a generated ecosystem config under `ServiceDirectory`. This keeps the
service aligned with `Port` and `BindAddress` and helps Node/Next.js apps bind
to localhost behind IIS instead of opening a public listener. WinSW remains the
recommended Windows production service manager; NSSM and PM2 are compatibility
fallbacks.

The Windows service-manager contract is checked locally by:

```powershell
.\scripts\dev\Test-WindowsServiceManagers.ps1
```

This is a static verifier. Release support still requires real-host evidence
from `status.ps1` on each claimed Windows and Windows Server target.

`ServiceAccount` controls the Windows service logon account. Supported
values are `NetworkService`, `LocalService`, `LocalSystem`, a dedicated
local/domain account, or a group managed service account such as
`DOMAIN\ExampleNodeApp$`. Prefer `NetworkService` or a gMSA over `LocalSystem`
for production. Ordinary domain/local users require `ServiceAccountPassword`,
but a gMSA is preferred so no password has to be stored in deployment config.

When `ReverseProxy` is `iis`, `scripts\windows\Install-ReverseProxy.ps1`
dispatches to the IIS installer, which writes `web.config`, configures an
always-running app pool, creates or updates the IIS site, adds the configured
HTTP/HTTPS binding, and starts the site when it is stopped. If `TlsEnabled` is true and
`IisCertificateThumbprint` is empty or unavailable, certificate binding remains
an explicit manual step and the script prints a warning.

Windows automation in this kit supports `ReverseProxy` values `iis` and `none`.
Apache, HAProxy, and Traefik helper installers are Linux/Unix scripts here. If
you run those proxies on Windows, manage their configuration separately and keep
`ReverseProxy` set to `none` for this Windows deployment flow.

For production IIS reverse proxy deployments, install IIS URL Rewrite and
Application Request Routing before running the installer. By default,
`IisRequireUrlRewrite` and `IisRequireArrProxy` make preflight and direct IIS
install fail if those required modules are missing. Set them to `false` only
when IIS prerequisites are managed and verified separately. `IisEnableArrProxy`
enables ARR proxy mode, preserves the original `Host` header, disables response
host rewrites, and applies `IisProxyTimeoutSeconds`.
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
.\install.ps1 -ConfigPath .\config\windows\app.config.json -PackagePath C:\deploy\app.zip -SkipInstall -SkipBuild
.\install.ps1 -ConfigPath .\config\windows\app.config.json -AllowPortInUse
.\install.ps1 -ConfigPath .\config\windows\app.config.json -SkipReverseProxy -SkipHealthCheck
.\install.ps1 -ConfigPath .\config\windows\app.config.json -SkipWinSWDownload
```

Preflight treats the configured service's own existing listener as a warning,
so normal service updates should not need `-AllowPortInUse`.

6. Optional lower-level commands:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Invoke-AppPreparation.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-NodeService.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-ReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json -DryRun
.\scripts\windows\Install-ReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Install-IISStaticSite.ps1 -ConfigPath .\config\windows\app.config.json
.\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath .\config\windows\app.config.json
```

7. Verify:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
```

The status command reports host uptime, service state, service wrapper uptime,
node processes, configured port listeners, whether the configured service owns
the listener, HTTP health latency, scheduled health-check freshness, health
history, service-definition alignment, scheduled-task action/config alignment,
and recent log file metadata without printing environment variables or log
contents. `-MinimumUptimeHours` is useful after a reboot or several days of
runtime because it warns when the service has restarted more recently than the
period you expected. `-JsonPath` writes the same safe verdict and findings to a
machine-readable evidence file for release reviews. Add `-FailOnWarnings` when
strict release evidence must fail on warning-only status results.

For IIS reverse-proxy deployments, the status JSON also includes safe IIS
evidence: whether the WebAdministration module was available, whether the
configured site exists and is started, whether the site physical path matches
the configured deployment path, whether the configured site owns the expected
public binding, and whether another IIS site also has that binding. Full
filesystem paths are not written to evidence; only safe path basenames are
emitted.

The status JSON also includes a safe configured-port proof section. It records
whether the app port was checked, is listening, has readable owner process
metadata, and is owned by the configured Windows service process tree.
It also includes structured HTTP health proof with a sanitized URL, status,
status code, response time, and timeout.
Uptime evidence records host uptime when available, service process uptime, and
whether the requested `-MinimumUptimeHours` window was satisfied.

Managed file updates create timestamped backups in `BackupDirectory` before
replacing existing WinSW XML/exe files, IIS `web.config`, or the scheduled
health-check task definition. If `BackupDirectory` is not set, the scripts use
`<ServiceDirectory>\backups`.

When `scripts\windows\Register-HealthCheckTask.ps1` is run directly, it
resolves `-ConfigPath` to an absolute path before saving the task action. This
prevents a relative config path from breaking later when Task Scheduler runs the
health check as `SYSTEM`.

8. Restart or uninstall:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

The Windows uninstaller routes by `ServiceManager`: WinSW uses the service
wrapper executable, NSSM uses `nssm remove` when available and falls back to
`sc.exe stop/delete`, and PM2 removes the named process plus the generated PM2
ecosystem file. It does not delete app files, logs, backups, or private config
files.

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
