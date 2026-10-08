# Windows Deployment

## Supported Windows Targets

- Windows 10
- Windows 11
- Windows Server 2012 / 2012 R2
- Windows Server 2016
- Windows Server 2019
- Windows Server 2022
- Windows Server 2025

Production preflight requires a maintained Node.js release in the 22, 24 or 26
line; Node.js 24 LTS is recommended. End-of-life and unknown release lines are
rejected. Next.js's historical `20.9.0` framework floor does not establish
maintained production support for Node.js 20. Windows 10 and Windows Server
2016 or newer are the production runtime targets in this kit, subject to the
chosen maintained Node release's OS support. Windows Server 2012 / 2012 R2 remains in the
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

When the server reaches npm through a corporate TLS-inspection proxy or a
private registry, keep CA configuration target-local and apply it only during
the install/build phase. `PreparationEnvironment` is intentionally not copied
into the running service environment:

```json
{
  "PreparationEnvironment": {
    "NODE_OPTIONS": "--use-system-ca"
  }
}
```

Use `NODE_EXTRA_CA_CERTS` with an approved local PEM path on Node.js versions
that do not support `--use-system-ca`. Do not disable npm or Node TLS
verification. See [Troubleshooting](TROUBLESHOOTING.md#npm-certificate-validation-on-enterprise-networks).

To deploy a built `.zip` artifact, set `PackagePath` in config or pass
`-PackagePath` to the wrapper:

```powershell
$package = "C:\deploy\example-node-app.zip"
$packageSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
.\install.ps1 -ConfigPath .\config\windows\app.config.json `
  -PackagePath $package `
  -PackageExpectedSha256 $packageSha256 `
  -SkipInstall -SkipBuild
```

Windows package import supports `.zip` with built-in .NET extraction. It
copies the artifact into a unique temporary work directory, verifies its
SHA-256 digest, validates archive paths before extraction, rejects duplicate or
case-colliding entries, extracts it there, rejects symlink, reparse-point, and
special-file entries, checks
`PackageExpectedFiles`, stops the service if it exists, backs up the current
`AppDirectory`, then imports the new package contents.
`RequirePackageSha256` defaults to `true`; a missing, malformed, or mismatched
`PackageExpectedSha256` fails before the service is stopped or the active app
directory is changed. Keep the digest blank in committed examples and calculate
it from each release artifact on the trusted build/deployment workstation.
The importer and preflight also enforce `PackageMaxArchiveSizeMB` (default
`2048`), `PackageMaxExtractedSizeMB` (`8192`), `PackageMaxEntryCount`
(`200000`), `PackageMaxCompressionRatio` (`200`), and
`PackageMinimumFreeSpaceMB` (`1024`). Source and staged archives are inspected,
the extracted tree is remeasured, and projected temporary, application, and
backup work must leave the configured reserve. All failures occur before the
service is stopped or the active application directory is replaced.

After those checks pass, the importer records whether the WinSW service or PM2
process is running and verifies that it stops before replacing files. The
existing `AppDirectory` is moved to a timestamped backup. If replacement or
deployment-manifest creation fails, the importer removes the partial release,
restores the previous directory, and restarts the process only when it was
running before import. If directory restoration fails, the process is
intentionally left stopped and the command reports a critical recovery error;
do not start it until the application directory has been repaired. Static IIS
imports use the same directory rollback but have no Node service to stop or
restart.

When package import is invoked through `install.ps1` or `deploy.ps1`, the
transaction remains active through app preparation, service installation, IIS
configuration, and health-task registration. Any downstream failure restores
the previous `AppDirectory` and its prior running/stopped state. If this was the
first deployment, rollback removes a newly registered Windows service or PM2
entry. The transaction JSON is written beside the protected deployment lock,
contains no environment values, and is removed after success or successful
rollback. If automatic rollback fails, the command reports and preserves that
file; keep the service stopped, inspect the referenced backup, and complete
recovery manually. Static IIS installation also restores its prior content,
site, app-pool, binding, and TLS state. WinSW/NSSM/PM2 and reverse-proxy config
files retain timestamped backups for any additional managed-config restoration.

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
`StartCommand`, and `NodeArguments`. The task action must use the protected
managed script and minimal config, and their source hash/config/ACL checks must
pass, so stale or writable health-check tasks are not accepted as production
proof.
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
default; `-TakeOverPublicPortBinding` removes only a binding with the configured
protocol, wildcard IP address, public port, and host header. Other host headers,
IP-specific bindings, and protocols on that port remain available. The helper
uses `TlsEnabled` to inspect `http` or `https`, defaults the public port to `80`
or `443` when `PublicPort` is unset, and rollback restores the previous IIS
physical path, app pool, and started/stopped site state, plus removed bindings
with their SNI flags and certificate associations. Takeover and deployment run
under the same per-app deployment lock, and partial takeover failures also
restore bindings already removed. The generated runtime
config is removed after the deployment/status transaction by default. Pass
`-KeepGeneratedConfig` only when an operator needs that file for an audited
follow-up; protect a retained file as private deployment configuration. The
scheduled health task uses its own allowlisted config under `%ProgramData%`, so
it never needs the full generated runtime config. The default generated file is
under the protected deployment-lock directory; an administrator/SYSTEM-only ACL
is applied to the empty file before secrets are written. Default temporary names
are unique per invocation, and an explicit `-GeneratedConfigPath` is rejected when
it already exists or aliases the source deployment config.

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
.\scripts\dev\Test-WindowsProductionSafety.ps1
```

The service-manager verifier checks the repository contract. The production
safety verifier executes deployment and rollback behavior with temporary files
and mocked IIS/service commands, including failed backups, partial binding
takeovers, scoped IIS/ARR restoration, SCM recovery settings, PM2 definitions,
privilege-preserving NSSM updates, private configuration writes, and required
proxy configuration failures. Both run under Windows PowerShell 5.1 and
PowerShell 7. Release support still requires real-host evidence
from `status.ps1` on each claimed Windows and Windows Server target.

`ServiceAccount` controls the Windows service logon account. Supported
values are `NetworkService`, `LocalService`, `LocalSystem`, a dedicated
local/domain account, or a group managed service account such as
`DOMAIN\ExampleNodeApp$`. Prefer `NetworkService` or a gMSA over `LocalSystem`
for production. Ordinary domain/local users require `ServiceAccountPassword`,
but a gMSA is preferred so no password has to be stored in deployment config.
NSSM applies this account explicitly on new installations and updates existing
compatible NSSM services in place. A new NSSM service defaults to
`NetworkService`; an existing account is preserved when `ServiceAccount` is
omitted. An unchanged dedicated account can keep its stored SCM credential
without supplying its password again. A new or changed ordinary account still
requires a password. The installer refuses to repurpose a same-name service
that points to another executable.

The NSSM executable is copied to the protected
`ServiceDirectory\<AppName>.nssm.exe` before it becomes the service's runtime
wrapper. Compatible legacy services using `tools\nssm\nssm.exe` migrate in
place, preserving their identity and stored credential. The transaction
snapshots the prior executable and SCM path so failure recovery can restore
both; the runtime no longer depends on traversal through the repository's
download location.

NSSM protects its `Parameters` registry key, including `AppEnvironmentExtra`,
with SYSTEM/Administrators full control and the actual runtime identity read
access. Password changes use the SCM API so credentials do not appear in NSSM
command-line arguments. Environment values are written directly through the
registry API, keeping environment secrets out of process arguments as well.
New or changed custom identities receive the service
logon right through the Windows LSA API.

WinSW follows the same identity rules: a new service defaults to
`NetworkService`, updates preserve an existing identity when `ServiceAccount`
is omitted, and an unchanged custom account keeps its stored SCM credential
when no replacement password is supplied. Explicit password changes use the
Windows service management API rather than native command-line arguments.

WinSW and NSSM apply protected filesystem ACLs before writing generated
configuration. SYSTEM and Administrators retain full access; the actual service
identity receives read/execute access to application code and service files.
Only `LogDirectory` and dedicated runtime cache directories grant that identity
Modify access. XML containing environment values is readable only by those
administrative identities and the service identity. Backups and deployment
control directories remain administrative. ACL failures stop deployment.

For Next.js, the default writable directory is `.next/cache`. Override
`RuntimeWritableDirectories` with an array of paths relative to `AppDirectory`
when the application uses a dedicated filesystem cache handler, for example
`["runtime-cache"]`. Paths cannot refer to the app root, escape the app,
overlap service/control directories, or traverse reparse points. Next.js ISR
can write generated route data outside `.next/cache`; configure a dedicated
cache handler/storage location and list its directory explicitly. Granting
Modify access to `.next/server` also makes compiled server code writable, so
it does not provide the same code protection. Exercise ISR/image-cache behavior
on the real host before claiming those features supported.

PM2 uses the identity invoking deployment and its own writable daemon state.
Its ecosystem file, backups and PM2 home exclude other ordinary users through
protected ACLs, while retaining SYSTEM, Administrators and the deployment
owner. Because its application and control process share that owner, PM2 cannot
enforce the separate immutable control/code boundary provided by WinSW/NSSM.
`PM2Home` overrides `PM2_HOME` and the owner's default `.pm2` directory;
`PM2Command` can pin the external executable or `.cmd` path. The installer and
health task resolve the same owner, command and home.
The PM2 health task uses the Limited run level so a writable PM2 command or
module cannot become an elevation path through the scheduled task. Use a
dedicated owner and an unelevated PM2 daemon. If an existing elevated
daemon rejects the limited task's IPC connection, migrate that daemon/owner
before registering monitoring; granting the task Highest is not a recovery
option. WinSW/NSSM health tasks continue to use SYSTEM at Highest.

Static IIS deployment backs up the existing live folder, stops an existing site
before replacing its files, configures the app pool/site/binding, and verifies
the final IIS state. A failure at any point restores both the prior content and
the prior IIS physical path, app-pool association, binding, and started/stopped
state. If a backup fails before replacement starts, the original live content
is preserved; a missing recorded backup also fails before rollback deletes
replacement content. `StaticOutputDirectory`, `IisSitePath`, and `BackupDirectory` are checked
for destructive overlap before deployment.

When `ReverseProxy` is `iis`, `scripts\windows\Install-ReverseProxy.ps1`
dispatches to the IIS installer, which writes `web.config`, configures an
always-running app pool, creates or updates the IIS site, adds the configured
HTTP/HTTPS binding, and starts the site when it is stopped. If `TlsEnabled` is
true, `IisCertificateThumbprint` must identify an available certificate in
`Cert:\LocalMachine\My`; preflight and installation fail closed when it is
missing or conflicts with an existing SSL binding. Use `TlsEnabled=false` when
TLS terminates at a documented upstream load balancer.
Required ARR property and forwarded-header permission failures stop deployment
instead of leaving an apparently successful but unusable proxy. HTTPS host
bindings explicitly enable SNI. Direct PowerShell 7 invocation relaunches the
IIS reverse-proxy installer in Windows PowerShell while retaining `-WhatIf` and
confirmation preferences.

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
.\install.ps1 -ConfigPath .\config\windows\app.config.json -PackagePath C:\deploy\app.zip -PackageExpectedSha256 $packageSha256 -SkipInstall -SkipBuild
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
history, service-definition alignment, and recent log file metadata without
printing environment variables or log contents. Scheduled-task evidence also
proves the manager's required principal and run level (`SYSTEM`/Highest for
WinSW/NSSM, the PM2 owner/Limited for PM2), explicit System32 PowerShell action,
protected working directory, script hash, minimal config alignment, and ACL
trust boundary. `-MinimumUptimeHours` is useful after a reboot or several days of
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
replacing existing WinSW XML/exe files, IIS `web.config`, the scheduled
health-check task definition, or its managed script/config files. If
`BackupDirectory` is not set, the scripts use `<ServiceDirectory>\backups`.

`scripts\windows\Register-HealthCheckTask.ps1` resolves the operator config,
copies only an allowlisted operational subset into
`%ProgramData%\node-enterprise-deploy-kit\healthchecks\<AppName>`, protects the
directory and files against untrusted writes, and points Task Scheduler at that
managed copy. The full deployment config is never placed in a `SYSTEM` task
action. Registration restores the previous files and task definition when an
update fails.

8. Restart or uninstall:

```powershell
.\restart.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
```

The Windows uninstaller takes the same app deployment lock and refuses retained
recovery journals. It disables and drains the managed health task before
removing the runtime. WinSW and NSSM registrations must reference the configured
managed wrapper (or the known legacy NSSM repository path); removal disables
SCM startup/recovery, stops the service, checks `sc.exe delete`, and verifies
registration absence. PM2 removal uses the configured unelevated owner, PM2
home, and executable. It selects exact case-sensitive app entries from the
daemon's process list, deletes their verified numeric IDs (including cluster
workers), and verifies those entries are gone before deleting
its generated ecosystem file. An administrator must disable/remove a protected
PM2 health task separately before running the owner's PM2 uninstall.

Caught failures before runtime removal restore the prior service startup mode
and previously enabled task. A successful runtime removal leaves a retained
task disabled. `-RemoveHealthCheckTask` deletes private managed task files only
after task removal succeeds and absence is verified; it requires administrator
execution for native managers. Uninstall does not restore a deleted runtime on
later cleanup failure and does not delete app files, application logs, backups,
or private deployment config files.

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
It records health state and its capped monitor log in the protected task
directory under `%ProgramData%`. It prunes old application logs, diagnostics,
and backups using `LogRetentionDays`, `DiagnosticRetentionDays`, and
`BackupRetentionDays`. Log and diagnostic cleanup examines direct files only and refuses a cleanup
directory that is a reparse point. It also prunes expired kit-named `app` and
`static-site` backup directories using their timestamped names, after checking
containment and rejecting reparse points anywhere in the backup tree. Pending
recovery journals suppress backup pruning. The `static_iis` scheduled task runs
retention only; it does not probe HTTP or operate a Node service.

The normal deploy and latest-release wrappers hold a per-app lock and snapshot
control files, service registration, NSSM parameters and their ACL, SCM failure
actions/flags/delayed startup/description, PM2 process configuration, and the
health task before host mutation. Existing services are temporarily disabled
before stopping, which prevents an already queued SCM recovery restart during
package preparation. Existing health tasks are disabled and any active action
is stopped. PM2 definitions are removed during preparation so watches and
automatic restarts cannot launch against changing files. Failure recovery
restores the control state while the application stays stopped, then restores
its previous running/stopped state after directory and proxy recovery.

After resuming a previously running runtime, recovery verifies HTTP health
before deleting its protected journal. It uses the prior monitor's loopback
`HealthUrl` and timeout policy, so a changed port or endpoint cannot accidentally
validate the replacement runtime. If no prior monitor exists, the deployment's
health policy is used. Set `PreviousHealthUrl` when the prior endpoint cannot be
inferred or needs an explicit override. Previously stopped services and static
IIS deployments skip runtime HTTP verification. Failed recovery health keeps
the journal for diagnosis and retry.

IIS snapshot, update and restore share a global configuration lock, including
native Windows PowerShell child processes. Rollback restores the configured
site, bindings/certificates, managed app-pool properties, the ARR properties and
forwarded-variable entries changed by the installer. Unrelated global settings
are preserved. Direct IIS installers use the same lock and a private recovery
journal. Core relaunches preserve `WhatIf`, `Confirm`, and the parent lock lease.
Direct static and reverse-proxy IIS installers acquire the app mutex before the
global IIS mutex. The app mutex protects static source copying and app
`web.config` changes against package imports and preparation. A Core parent
holds both leases through native Windows PowerShell execution; the child
validates the protected lease's app path, nonce, parent process start time,
and live exclusive streams before borrowing them.
Any retained direct IIS installer journal blocks subsequent IIS installers,
including a journal interrupted before its snapshot completed. Inspect and
recover that protected journal using the runbook before archiving it; deleting
the mutex file does not clear the recovery guard.

Changing an existing ordinary service account or its password requires
`PreviousServiceAccountPassword` before deployment can proceed. An existing
Password-logon health task similarly needs `PreviousHealthCheckTaskPassword`,
or `HealthCheckTaskPassword` when its old principal is the current deployment
owner. These credentials are excluded from the minimal monitor config. If
control-state recovery fails, the protected journal is retained and the previous
service is not resumed. A failure of the final HTTP verification also retains
the journal after resume; resolve the reported recovery error before deploying
again.
The PM2 transaction supports one existing managed process definition and
rejects multiple definitions before mutation.
PM2 commands refuse differently cased aliases and malformed/duplicate process
IDs. They also refuse numeric IDs shadowed by another process name, namespace,
or executable path, because PM2 resolves those selectors before numeric IDs.
Resolve the reported identity collision explicitly before retrying.

Runtime installers invoked directly (`Install-NodeService.ps1`,
`Install-NSSMService.ps1`, and `Install-PM2Fallback.ps1`) acquire the same app
lock and managed recovery journal as deployment. When deployment calls an
installer, it borrows those objects so the previous runtime resumes only after
the parent restores package content. A successful direct installer restores the
previous health task's enabled state. Automatic transitions between PM2,
native service managers, and static hosting are rejected before stopping a
runtime. Complete the explicit migration described in the error, including
removing the previous health task, or use a distinct `AppName`.
The default app-name lock uses the common ProgramData deployment-lock directory
for every manager. If you override `DeploymentLockDirectory`, keep the same
absolute path for that `AppName` across imports, installers, deployment, and
monitoring, including an explicit manager migration.

Before a runtime installer changes permissions, its journal records the exact
DACL, owner, group, and inheritance protection of existing application, cache,
log, service, and backup objects. A caught failure restores these permissions
before resuming the old identity, including deployments with package import
skipped. Reparse points are rejected. New application and log objects inherit
the restored parent permissions; newly introduced private control files and
backups retain their administrative protection.

Automatic rollback handles caught errors. Killing PowerShell or losing the
host interrupts recovery; the persistent journal requires the manual recovery
procedure in [the runbook](RUNBOOK.md). An unresolved journal prevents further
deployment and suppresses health-monitor actions until that recovery is
completed. It does not automatically replay interrupted host mutations.

Standalone `Import-AppPackage.ps1` holds the same app lock and records a
persistent package marker before replacing content. It supports fresh or
file-only imports; if a native service or PM2 runtime already exists, use the
full deploy wrapper so its managed transaction disables recovery and watchers
first. A borrowed importer leaves journal cleanup and runtime recovery to that
wrapper. Failed standalone recovery retains its marker and backup. Static
`AppDirectory` and live `IisSitePath` must be separate, nonoverlapping trees.
An unprivileged file-only import can use a caller-owned explicit lock directory;
its ACL grants only the current owner, SYSTEM, and Administrators access.

## Service Recovery

The installer configures Windows Service Control Manager recovery:

```text
1st failure -> restart after 60 sec
2nd failure -> restart after 60 sec
3rd failure -> restart after 5 min
reset failure counter after 1 day
```
