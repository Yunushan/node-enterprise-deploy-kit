# Next.js Deployment

This kit supports Next.js as a managed Node.js service behind a reverse proxy.
The recommended production shape is:

```text
IIS / Nginx / Apache / HAProxy / Traefik
  -> http://127.0.0.1:<APP_PORT>
  -> Next.js server running as WinSW/systemd/System V/OpenRC/launchd/bsdrc service
```

The default Next.js mode is `standalone`, because it deploys the traced runtime
output instead of requiring the full source tree and development dependencies on
the server.

Official Next.js references:

- https://nextjs.org/docs/app/api-reference/config/next-config-js/output
- https://nextjs.org/docs/app/guides/self-hosting

## Supported Modes

| Mode | Config value | What gets deployed | Recommended use |
|---|---|---|---|
| Standalone | `standalone` | Contents of `.next/standalone`, plus copied static assets | Recommended production service mode |
| Next start | `next-start` | Full app with `package.json`, `.next`, and `node_modules/next` | Compatibility mode when standalone is not possible |

Static export-only sites are not the primary target of this kit. Serve those as
static files through IIS/Nginx/Apache or a CDN instead of installing a Node.js
service.

## Build a Standalone Artifact

Add this to the app's `next.config.js`:

```js
module.exports = {
  output: 'standalone',
};
```

Build on a CI agent or build host:

```bash
npm ci
npm run build
```

Next.js creates `.next/standalone/server.js`. The generated standalone folder
does not include `public` or `.next/static` by default. Copy `.next/static` into
the standalone tree when the app service should serve its own static assets.
Copy `public` too if the app uses files from that directory.

Windows packaging helper:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip
```

Linux/macOS/BSD packaging helper:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
```

Both helpers copy `.next/standalone`, add `.next/static`, copy `.next/BUILD_ID`,
copy `public` when it exists, block obvious private files such as `.env`,
private keys, and certificates from the staged package, then verify that the
archive contains `server.js`, `.next/BUILD_ID`, and `.next/static`. The helpers
also run the package validator on the produced archive before reporting
success.

Unix tar deployment archives are also rejected when they contain symlink or
hardlink entries. Keep production artifacts as real files and directories so
package import cannot preserve links that point outside the deployed runtime
tree.

Validate an existing package before deploying it:

```powershell
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip
```

For full-app `next-start` packages, pass the mode explicitly:

```powershell
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip `
  -Mode next-start
```

```bash
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz
```

```bash
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz \
  --mode next-start
```

The normal Windows and Unix package import flows run these validators
automatically for Next.js `standalone` and `next-start` deployments before
replacing the current application directory. A `next-start` package must contain
`package.json`, built `.next` output, and `node_modules/next`.

After a successful package import, the importer writes
`.node-enterprise-deploy.json` into the deployed app directory. The manifest is
safe to include in status evidence because it stores only the app name, import
timestamp, package file name, package SHA256, framework/mode, deployment ID when
configured, and the Next.js build ID. It does not store the source package path,
app directory path, host name, or environment values.

Manual Linux/macOS packaging equivalent:

```bash
rm -rf release
mkdir -p release
mkdir -p .next/standalone/.next
cp -R .next/static .next/standalone/.next/
if [ -d public ]; then cp -R public .next/standalone/; fi
tar -C .next/standalone -czf release/example-node-app.tar.gz .
```

Manual Windows packaging equivalent:

```powershell
Remove-Item -Recurse -Force .\release -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path .\release | Out-Null
New-Item -ItemType Directory -Force -Path .\.next\standalone\.next | Out-Null
Copy-Item .\.next\static .\.next\standalone\.next\static -Recurse -Force
if (Test-Path .\public) {
  Copy-Item .\public .\.next\standalone\public -Recurse -Force
}
Compress-Archive -Path .\.next\standalone\* -DestinationPath .\release\example-node-app.zip -Force
```

The archive root should contain `server.js`. A healthy standalone archive
usually contains:

```text
server.js
.next/
.next/static/
node_modules/
package.json
public/              optional
```

## Windows Server Config

Use the normal Windows deployment flow with these Next.js-specific fields:

```json
{
  "AppFramework": "nextjs",
  "NextjsDeploymentMode": "standalone",
  "NextjsRequireStaticAssets": true,
  "NextjsRequirePublicDirectory": false,
  "NextjsRequireServerActionsEncryptionKey": false,
  "NextjsRequireDeploymentId": false,
  "StartCommand": "server.js",
  "BindAddress": "127.0.0.1",
  "PackageExpectedFiles": [
    "server.js",
    ".next/BUILD_ID",
    ".next/static"
  ],
  "Environment": {
    "NODE_ENV": "production",
    "PORT": "3000",
    "APP_PORT": "3000",
    "HOSTNAME": "127.0.0.1"
  }
}
```

WinSW is the recommended Windows production service manager. NSSM and PM2 are
supported fallback paths for compatibility, and the deployment scripts pass the
same managed `NODE_ENV`, `PORT`, `APP_PORT`, `APP_NAME`, `BIND_ADDRESS`, `HOST`,
and `HOSTNAME` defaults to all three managers. The PM2 fallback writes a local
ecosystem file under `ServiceDirectory` so the Node interpreter, app directory,
arguments, logs, and runtime environment are kept together.

For full-app `next-start`, use the Next CLI path and pass the production
subcommand plus hostname:

```json
{
  "NextjsDeploymentMode": "next-start",
  "StartCommand": "node_modules/next/dist/bin/next",
  "NodeArguments": "start -H 127.0.0.1",
  "BindAddress": "127.0.0.1",
  "PackageExpectedFiles": [
    "package.json",
    ".next/BUILD_ID",
    ".next",
    "node_modules/next"
  ]
}
```

Deploy a built artifact:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json `
  -PackagePath C:\deploy\example-node-app.zip `
  -SkipInstall -SkipBuild
```

For timestamped folders already extracted under a release root, use:

```powershell
.\scripts\windows\Deploy-LatestRelease.ps1 `
  -ConfigPath .\config\windows\app.config.json `
  -ReleaseRoot C:\inetpub\wwwroot `
  -ReleasePattern "example-node-app-IIS-deploy-*" `
  -HealthPath "/" `
  -TakeOverPublicPortBinding
```

## Linux, BSD, and macOS Config

Use these fields in `config/linux/app.env`:

```bash
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="standalone"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="false"
NEXTJS_REQUIRE_DEPLOYMENT_ID="false"
START_SCRIPT="server.js"
APP_PORT="3000"
BIND_ADDRESS="127.0.0.1"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
```

The Unix-like service installer writes the protected runtime env file with
`PORT`, `APP_PORT`, `BIND_ADDRESS`, `HOST`, and `HOSTNAME`. For Next.js
standalone, `HOST` and `HOSTNAME` are derived from `BIND_ADDRESS`, so the
generated `server.js` binds to the same local address that the reverse proxy
targets. The env file is written with POSIX shell-compatible quoting so System
V, OpenRC, launchd runner scripts, and BSD rc scripts can source the same file.

For full-app `next-start`, use:

```bash
NEXTJS_DEPLOYMENT_MODE="next-start"
START_SCRIPT="node_modules/next/dist/bin/next"
NODE_ARGUMENTS="start -H 127.0.0.1"
BIND_ADDRESS="127.0.0.1"
PACKAGE_EXPECTED_FILES="package.json .next/BUILD_ID .next node_modules/next"
```

The `start` argument runs `next start` in production mode. The `-H`/`--hostname`
argument keeps the Next.js process bound to the configured local address instead
of the CLI default.

Deploy a built artifact:

```bash
PACKAGE_PATH="/opt/releases/example-node-app.tar.gz" \
SKIP_INSTALL="true" \
SKIP_BUILD="true" \
bash deploy.sh config/linux/app.env
```

Choose the service manager by host type:

| Host type | Recommended `SERVICE_MANAGER` |
|---|---|
| Modern Linux | `systemd` |
| Legacy Linux | `systemv` |
| Alpine/OpenRC | `openrc` |
| macOS | `launchd` |
| FreeBSD/OpenBSD/NetBSD | `bsdrc` |

Choose `REVERSE_PROXY` from `nginx`, `apache`, `haproxy`, `traefik`, or `none`.

## Health Endpoint

Use a real application health route instead of relying only on `/`.

App Router example:

```ts
export function GET() {
  return Response.json({ status: 'ok' });
}
```

Place it at:

```text
app/health/route.ts
```

Pages Router example:

```ts
export default function handler(_req, res) {
  res.status(200).json({ status: 'ok' });
}
```

Place it at:

```text
pages/api/health.ts
```

Then set `HealthUrl` or `HEALTH_URL` to the route you actually created.

## Preflight Validation

Before deploying a real application, run the repository-level Next.js support
checks. They create temporary standalone and `next-start` layouts, verify that
Windows and Unix-like preflight checks accept valid artifacts, reject invalid
layouts, and verify that the standalone package helpers produce the expected
archive structure:

```powershell
.\scripts\dev\Test-NextJsSupport.ps1
```

On Unix-like hosts, including macOS CI runners, run the Bash-only smoke test:

```bash
bash scripts/dev/test-unix-nextjs-support.sh
```

The repository verifier also starts a tiny local standalone-style Node.js
server and probes `/health` to prove that the managed `PORT`, `APP_PORT`,
`HOST`, and `HOSTNAME` values produce an actual loopback HTTP listener. Set
`NODE_EXE` when Node.js is installed outside `PATH`.

Windows preflight checks:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
```

To validate only the live Next.js runtime folder without touching service,
port, IIS, or health-check state:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

Linux/Unix preflight checks:

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
```

To validate only the live Next.js runtime folder on Linux, macOS, or BSD:

```bash
bash scripts/linux/test-nextjs-runtime-layout.sh config/linux/app.env
```

For CI or cross-platform static checks where the target service manager is not
available on the runner, add `--skip-service-manager-check`. Do not use that
flag as the final preflight on the real host; macOS should still prove
`launchctl`, OpenRC should prove `rc-service`/`rc-update`, and systemd should
prove `systemctl`.

For `standalone`, the preflight validates:

- `AppFramework` / `APP_FRAMEWORK` is `nextjs`.
- `NextjsDeploymentMode` / `NEXTJS_DEPLOYMENT_MODE` is valid.
- `StartCommand` / `START_SCRIPT` points to a safe `server.js` path.
- The runtime root has `.next`.
- The runtime root has `.next/BUILD_ID`.
- The runtime root has `.next/static` when static assets are required.
- The runtime root has `public` when public directory validation is required.
- The runtime root has `node_modules`, with a warning if missing.

For `next-start`, the preflight validates:

- `NodeArguments` / `NODE_ARGUMENTS` starts with `start`.
- `NodeArguments` / `NODE_ARGUMENTS` includes `-H <BindAddress>` or
  `--hostname <BindAddress>`.
- `package.json` exists.
- `.next` exists.
- `node_modules/next` exists.

## Post-Deploy Verification

Windows:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json -FailOnCritical
Get-Service ExampleNodeApp
Get-NetTCPConnection -State Listen |
  Where-Object LocalPort -eq 3000 |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

For `AppFramework=nextjs`, `status.ps1` also prints a safe Next.js runtime
layout section and raises findings when `server.js`, `.next`, `.next/BUILD_ID`,
`.next/static`, or `node_modules/next` are missing for the selected mode. To
collect the same layout information in a machine-readable release evidence file, run:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json -JsonPath .\evidence\windows-nextjs-status.json -FailOnCritical
```

The `DeploymentIdentity` section includes manifest fields when the app was
installed from a package: `ManifestExists`, `PackageName`, `PackageSha256`,
`PackageImportedAtUtc`, and `ManifestNextBuildId`. Use those fields to confirm
that the running service matches the release package you intended to deploy.

To collect deeper diagnostics in a support bundle without environment values,
run:

```powershell
.\scripts\windows\Diagnose-NodeApp.ps1 -ConfigPath .\config\windows\app.config.json
```

Linux:

```bash
bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./evidence/unix-nextjs-status.json --fail-on-critical
systemctl status example-node-app
ss -ltnp | grep ':3000'
curl -fsS http://127.0.0.1:3000/health
```

The Unix status command checks service state, configured port, HTTP health,
health-check history, and the Next.js runtime layout without printing raw
environment values. Use `--json-output` for release evidence on Linux, macOS,
and BSD hosts. Unix diagnostics include a safe Next.js runtime layout section
for Linux, macOS, and BSD service-manager modes:

```bash
bash scripts/linux/diagnose-node-app.sh config/linux/app.env
```

The Unix JSON `deploymentIdentity` section includes the same package manifest
proof as Windows: `manifestExists`, `packageName`, `packageSha256`,
`packageImportedAtUtc`, and `manifestNextBuildId`.

macOS launchd:

```bash
sudo launchctl print system/example-node-app
curl -fsS http://127.0.0.1:3000/health
```

BSD rc:

```bash
rcctl check example-node-app
curl -fsS http://127.0.0.1:3000/health
```

## Multi-Instance Notes

For more than one app instance behind a load balancer:

- Build once and deploy the same artifact to every node.
- Use a consistent Next.js build ID when rebuilding separately per stage.
- Set a stable deployment ID for rolling deployments when needed.
- Use the same `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` across instances when
  Server Functions / Server Actions require it.
- Use shared cache/storage when application behavior depends on cache
  consistency across nodes.
- Ensure the reverse proxy path supports streaming when the app uses App Router
  streaming, Suspense, or Partial Prerendering.

To make those multi-server requirements fail fast during deployment, enable the
opt-in preflight gates:

Windows private config:

```json
{
  "NextjsRequireServerActionsEncryptionKey": true,
  "NextjsRequireDeploymentId": true,
  "Environment": {
    "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY": "<base64-aes-key-from-secret-store>",
    "NEXT_DEPLOYMENT_ID": "<release-id>"
  }
}
```

Linux/macOS/BSD private config:

```bash
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="true"
NEXTJS_REQUIRE_DEPLOYMENT_ID="true"
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="<base64-aes-key-from-secret-store>"
NEXT_DEPLOYMENT_ID="<release-id>"
RUNTIME_ENV_KEYS="NEXT_SERVER_ACTIONS_ENCRYPTION_KEY NEXT_DEPLOYMENT_ID"
```

Keep those values target-local or secret-manager supplied. The checks only
verify presence and shape; they do not print the secret value.

## Common Failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `404` on `/health` | App has no matching health route | Add a health route or point health config to a real endpoint |
| Missing CSS/JS | `.next/static` was not copied into standalone artifact | Copy `.next/static` to `.next/standalone/.next/static` before packaging |
| Public images missing | `public` was not copied | Copy `public` to `.next/standalone/public` and set public validation when required |
| `npm ci` fails | No lockfile in source tree | Commit a lockfile or use artifact-only deployment with `-SkipInstall -SkipBuild` |
| IIS 502.3 | Node service is not listening or IIS proxies to wrong port/path | Check service state, port owner, `HealthUrl`, IIS binding, and generated `web.config` |
| Static assets mismatch after rolling deploy | Instances run different builds | Deploy the same artifact or configure consistent build/deployment identifiers |
