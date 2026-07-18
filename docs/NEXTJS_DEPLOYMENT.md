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
- https://github.com/nodejs/node/blob/v20.x/BUILDING.md#platform-list

Current Next.js releases require Node.js `20.9.0` or newer. The example
configs therefore set `NextjsMinimumNodeVersion` /
`NEXTJS_MINIMUM_NODE_VERSION` to `20.9.0`, and preflight/status evidence fails
when the configured Node runtime cannot prove it meets that minimum.

The Node.js runtime floor is also platform-specific. For the Node.js 20.x
minimum used by current Next.js, production-recommended rows are Windows 10 /
Windows Server 2016 or newer, GNU/Linux hosts that meet the documented
kernel/glibc floor, and macOS hosts that meet the documented architecture and
version floor. Windows Server 2012 / 2012 R2, Alpine/musl, and FreeBSD are
tracked as Experimental Node runtime targets; OpenBSD and NetBSD require an OS
package or locally maintained Node runtime. The support matrix records this in
`nodeRuntimeSupport` so release claims can distinguish production targets from
legacy, experimental, or community-runtime targets.
When `Test-HostEvidence.ps1` runs with `-RequireNextJs`, it enforces those
runtime floors from collected platform evidence where they apply: Windows build
number, Linux kernel plus glibc version, and macOS product version plus
architecture.

## Supported Modes

| Mode | Config value | What gets deployed | Recommended use |
|---|---|---|---|
| Standalone | `standalone` | Contents of `.next/standalone`, plus copied static assets | Recommended production service mode |
| Next start | `next-start` | Full app with `package.json`, `.next`, `node_modules/next/package.json`, and `node_modules/next/dist/bin/next` | Compatibility mode when standalone is not possible |

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

For full-app `next-start` packaging, add `-Mode next-start`:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip `
  -Mode next-start
```

Linux/macOS/BSD packaging helper:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
```

For full-app `next-start` packaging, add `--mode next-start`:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz \
  --mode next-start
```

In `standalone` mode, both helpers copy `.next/standalone`, add
`.next/static`, copy `.next/BUILD_ID`, copy `public` when it exists, block
obvious private files such as `.env`, private keys, and certificates from the
staged package, then verify that the archive contains `server.js`,
`.next/BUILD_ID`, `.next/static`, and `node_modules/next/package.json`. In
`next-start` mode, they stage
`package.json`, `.next`, production `node_modules`, optional `public`, and
common Next.js config/lock files, then verify that the archive contains
`package.json`, `.next/BUILD_ID`, `node_modules/next/package.json`, and
`node_modules/next/dist/bin/next`. The helpers also run the package validator
on the produced archive before reporting success. The `node_modules/next`
package metadata is required so post-deploy evidence can prove the installed
Next.js package version from the active runtime folder.

Unix tar deployment archives are also rejected when they contain symlink or
hardlink entries. The Unix `next-start` package helper therefore removes
`node_modules/.bin` command shims after staging `node_modules`, because npm,
pnpm, and yarn often create symlinks there. The managed service starts Next
directly from `node_modules/next/dist/bin/next`, so those shims are not needed
at runtime. Keep production artifacts as real files and directories so package
import cannot preserve links that point outside the deployed runtime tree.

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
`package.json`, built `.next` output, and
`node_modules/next/dist/bin/next`.

## Build Target Compatibility

Native runtime dependencies such as Next.js SWC, image-processing libraries,
or database clients can make a package built on one operating system or CPU
architecture unsuitable for another. The kit packaging helpers therefore add a
safe `.node-enterprise-package.json` marker to every Next.js package. It stores
only the package mode, build OS family, CPU architecture, Linux libc family
when applicable, Node native-module ABI, Next.js version, and Next.js build ID. It does not contain
paths, hostnames, environment variables, credentials, or application data.

Set `NextjsRequirePackageProvenance: true` on Windows or
`NEXTJS_REQUIRE_PACKAGE_PROVENANCE="true"` on Unix-like targets to require the
marker. The importer verifies the mode and target compatibility before it stops
the service or replaces the active application directory. Importers also compare
the Node native-module ABI, and Linux targets compare `glibc` and `musl`. The marker is removed from the extracted release
before the application is made live; the safe verified values are retained in
`.node-enterprise-deploy.json` for deployment evidence.

Build the package on the same operating-system family and CPU architecture as
the target. In particular, do not package a Linux runtime on Windows or macOS,
and do not use a glibc-built artifact on an Alpine/musl target. Likewise, rebuild
an artifact with the same Node major version used by the target when it includes
native dependencies. The current marker schema is v2; with strict provenance
enabled, rebuild older v1 packages so Node ABI compatibility can be verified.

`status.ps1` and `scripts/linux/status-node-app.sh --json-output` expose the
verified package provenance from the active deployment manifest, allowing a
host-evidence bundle to show the package build target without disclosing any
runtime configuration.

After a successful package import, the importer writes
`.node-enterprise-deploy.json` into the deployed app directory. The manifest is
safe to include in status evidence because it stores only the app name, import
timestamp, package file name, package SHA256, framework/mode, deployment ID when
configured, and the Next.js build ID. It does not store the source package path,
app directory path, host name, or environment values.

Package import intentionally rejects archive symlinks, NTFS reparse points, and
special-file entries. Keep deployment artifacts as regular files and
directories so Windows and Unix-like targets import the same runtime tree.

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
  "NextjsMinimumNodeVersion": "20.9.0",
  "StartCommand": "server.js",
  "BindAddress": "127.0.0.1",
  "PackageExpectedFiles": [
    "server.js",
    ".next/BUILD_ID",
    ".next/static",
    "node_modules/next/package.json"
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
    "node_modules/next/package.json",
    "node_modules/next/dist/bin/next"
  ]
}
```

You can also start from the committed Windows example:
`config/windows/next-start.app.config.example.json`.

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

The helper uses `TlsEnabled` to check/take over the matching IIS `http` or
`https` binding and restores the previous IIS site path, app pool, and
started/stopped state if deployment fails. Its generated runtime config is kept
under `<ServiceDirectory>\config` by default so the scheduled health-check task
continues to use the same release-specific config after the deploy command
exits.

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
NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
START_SCRIPT="server.js"
APP_PORT="3000"
BIND_ADDRESS="127.0.0.1"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static node_modules/next/package.json"
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
PACKAGE_EXPECTED_FILES="package.json .next/BUILD_ID .next node_modules/next/package.json node_modules/next/dist/bin/next"
```

You can also start from the committed Unix-like example:
`config/linux/app.env.next-start.example`.

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

When `SERVICE_MANAGER` is omitted, deploy, status, diagnostics, health checks,
and uninstall resolve the default from the current host using the same mapping.

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

For representative Linux userland coverage on a Docker-capable CI host:

```bash
bash scripts/dev/test-linux-container-smoke.sh --platform ubuntu
```

Use `--real-nextjs` to download a checksum-verified Node.js runtime in glibc
containers (or use Alpine's signed `apk` Node.js package), build `next@latest`,
package both `standalone` and `next-start`, extract the artifacts, and verify
each one serves HTTP:

```bash
bash scripts/dev/test-linux-container-smoke.sh --platform ubuntu --real-nextjs
```

To check the wrapper logic without Docker/network access:

```bash
bash scripts/dev/test-linux-container-smoke.sh --self-test
```

CI runs both container modes for Ubuntu, Debian, Linux Mint, RHEL/UBI, Oracle
Linux, CentOS/CentOS Stream, Rocky Linux, AlmaLinux, Fedora, and Alpine.
On the hosted native runners, it also deploys both modes through temporary
systemd services on Ubuntu, System V services in an Ubuntu container, OpenRC
services in an Alpine container, WinSW services on Windows Server 2022/2025,
and launchd services on macOS 15. A Windows Server matrix also verifies WinSW
and NSSM behind a temporary IIS URL Rewrite plus ARR reverse proxy. Each check
verifies direct and proxied loopback HTTP output, including forwarded headers,
then removes its service and IIS site afterwards. macOS additionally runs a
launchd service behind temporary Homebrew Nginx, Apache, HAProxy, and Traefik
reverse proxies. Alpine OpenRC coverage also runs each supported proxy against
the managed Next.js service.
Managed-runtime checks also confirm that the packaged Next.js application
receives forwarded HTTPS protocol and port headers.
The systemd integration uses a service-visible `/srv` temporary root because
the production unit isolates `/tmp` with `PrivateTmp=true`.
The Ubuntu container suite also renders the Apache vhost, Nginx site, HAProxy,
and Traefik templates, verifying that each proxy serves a real response from
every packaged Next.js mode and passes its forwarded protocol and port headers.
Its System V matrix runs every proxy against the installed temporary service,
and the native Ubuntu systemd job covers the composed service-plus-Nginx path.
The Traefik verification downloads a pinned upstream Linux binary and validates
its published SHA-256 rather than relying on an unavailable Ubuntu package.
Its HTTP entrypoint reports the standard forwarded port `80`, which the live
integration assertion verifies explicitly.
Real-host release claims still require collected status evidence from the exact
platform rows in the support matrix.

Each native hosted real-runtime job also uploads a 14-day
`nextjs-integration-result.json` artifact. It records the runner platform,
Node.js and installed Next.js versions, both package modes, selected service
manager/reverse proxy, forwarded-header check, and GitHub Actions run
provenance including the exact target label, job ID, and runner environment.
This is hosted CI verification metadata, not deployment status
evidence: it cannot satisfy the self-hosted uptime and exact-host requirements
for a release support claim.
The Linux distribution-container jobs upload the same safe result, labeled with
the tested target distribution and `container` execution mode, for every real
Next.js package/runtime check and managed System V/OpenRC proxy check.
After those jobs complete, CI writes a single `nextjs-integration-summary`
artifact and GitHub Actions summary with observed passed, failed, invalid, and
missing-result context plus upstream job outcomes. A successful upstream job
without a valid result artifact fails the summary job, while the diagnostic
summary is still uploaded. It remains hosted CI review metadata, not a release
support claim.

The real integration runner bounds external work so a registry, package, or
build stall fails with a command-specific diagnostic rather than waiting
indefinitely. Its defaults are 30 seconds for `npm ping`, six minutes each for
the temporary `npm install` and `npm run build`, and ten minutes for other
helper commands. On a slower but trusted self-hosted runner, set the applicable
millisecond environment variable before dispatching:
`NEXTJS_INTEGRATION_NPM_REGISTRY_TIMEOUT_MS`,
`NEXTJS_INTEGRATION_NPM_INSTALL_TIMEOUT_MS`,
`NEXTJS_INTEGRATION_NPM_BUILD_TIMEOUT_MS`, or
`NEXTJS_INTEGRATION_COMMAND_TIMEOUT_MS`. Values must be whole milliseconds
between 1,000 and 3,600,000.

## Self-Hosted Native Integration

Use `.github/workflows/nextjs-host-integration.yml` when an exact Windows,
Linux, or macOS target host is available as a self-hosted runner. The manual
workflow builds a temporary real Next.js application, packages both
`standalone` and `next-start` modes, installs the selected primary service
manager, optionally configures the selected reverse proxy, checks loopback and
forwarded headers, removes the temporary resources, and uploads one safe JSON
result. Its `execution.runnerEnvironment` field is always `self-hosted`; the
target-specific validator rejects a result that reports GitHub-hosted or local
execution.

Because this workflow runs privileged service and proxy operations, it accepts
dispatches only from the repository's protected default branch. Merge the
candidate commit there before collecting native self-hosted evidence; GitHub-
hosted validation still catches pull-request regressions without exposing a
self-hosted runner to branch-controlled workflow code.

The result also records safe platform identity metadata: Windows product name
and build, Linux `/etc/os-release` ID/version/variant, or the macOS family and
kernel release. Before installing or starting a temporary service, the runner
checks that this observed identity matches the requested target label. A runner
labeled `ubuntu`, for example, cannot submit self-hosted evidence when its
observed Linux ID is Fedora; Windows client, Windows Server, and CentOS Stream
labels are likewise distinguished. This metadata contains no hostname, user,
path, environment, or application configuration.

The dispatched `runner_labels` must contain `self-hosted`, the exact support
matrix target ID, `nextjs-manager-<manager>`, and `nextjs-proxy-<proxy>`. For
example, an Ubuntu systemd/Nginx worker uses
`self-hosted`, `ubuntu`, `nextjs-manager-systemd`, and `nextjs-proxy-nginx`.
This prevents a target-matched runner without the selected service-manager or
proxy prerequisite from receiving the job. The workflow rejects GitHub-hosted
runner labels, conflicting target labels, local-command-only BSD targets,
fallback managers, and manager/proxy combinations absent from the support
matrix. Its artifact name must be `target-nextjs-manager-proxy`, such as
`windows-server-2022-nextjs-winsw-iis` or `ubuntu-nextjs-systemd-nginx`.
Dispatches for the same target, service manager, and proxy are serialized and
an in-progress verification is never canceled. This prevents overlapping manual
runs from mutating the same temporary service or proxy state on a shared host.

Windows runners must run as Administrator; the prerequisite command verifies the
current Windows process token before any package build or service mutation. Unix
runners must provide passwordless `sudo`; systemd hosts use `/srv/node-enterprise-deploy-kit-nextjs-host-integration`
because the production unit isolates `/tmp` with `PrivateTmp=true`. Install the
selected service manager and proxy prerequisites before dispatching the
workflow. For IIS, this includes URL Rewrite and ARR; for Unix proxies, it
includes the matching proxy executable and its required modules.

When a runner is behind corporate HTTPS inspection, repair the operating-system
trust store and configure its Node.js process with `NODE_OPTIONS=--use-system-ca`.
Do not disable certificate verification with `npm config set strict-ssl false` or
`NODE_TLS_REJECT_UNAUTHORIZED=0`; the real Next.js integration intentionally
fails closed when it cannot verify the npm registry certificate chain.

Before any temporary package, service, or proxy is created, the workflow checks
the Node.js 20.9.0 floor, the selected service-manager command, and the selected
proxy executable. It also checks Windows Service Control Manager, NSSM when
selected, IIS WebAdministration plus URL Rewrite and ARR for IIS dispatches,
and the Unix passwordless `sudo` path. A host that is not ready therefore
fails with a specific prerequisite error before it can change service state.

This workflow proves the native deployment-kit package, service, and proxy path
on the selected machine. It does not replace the 72-hour status evidence from a
deployed application that is required for a final release support claim.

Generate a matrix-derived review plan rather than manually reconstructing every
target combination:

```powershell
.\scripts\dev\New-NextJsHostIntegrationPlan.ps1 `
  -ProductionRecommendedOnly `
  -Format Markdown `
  -OutputPath .\evidence\nextjs-host-integration-dispatch.md
```

The plan emits one dispatch per declared primary manager/proxy combination and
covers both Next.js modes in each dispatch. It excludes fallback managers and
BSD local-command-only targets. It fails rather than silently omitting a target
whose category is not workflow-capable, or a manager/proxy not implemented by
the self-hosted workflow. To prepare a review-first PowerShell dispatcher:

```powershell
.\scripts\dev\New-NextJsHostIntegrationPlan.ps1 `
  -ProductionRecommendedOnly `
  -Format DispatchPowerShell `
  -OutputPath .\evidence\nextjs-host-integration-dispatch.ps1
```

Run the generated script without parameters to review the target list. With
`-Run`, it first queries the repository runner inventory for every planned
target/manager/proxy combination and refuses to dispatch unless each one has an
online, idle runner carrying all required capability labels. Run it from the repository root, or pass
`-RepositoryRoot` explicitly. It also requires a clean worktree on the
protected workflow branch and verifies that `origin` contains the exact local
commit, so a native host never validates stale workflow code.
Use `-Run` only after the corresponding self-hosted runners, Administrator or
passwordless `sudo` access, and service/proxy prerequisites are ready.

Before dispatching, inspect the repository runner inventory. It reports only
target-level configured, online, and idle counts; it does not print runner names
or host details. A target is ready only when an online, non-busy runner has both
the `self-hosted` and exact target labels:

```powershell
.\scripts\dev\Get-NextJsHostIntegrationRunnerInventory.ps1 `
  -Repository Yunushan/node-enterprise-deploy-kit `
  -Format Markdown
```

Use `-FailOnMissing` only when every workflow-capable target is expected to be
registered. It exits nonzero for missing target labels, which is useful as a
release-readiness gate but should not be used while provisioning a partial fleet.

To create review-first onboarding instructions for a compatible validation host,
generate a profile for the exact target, manager, and proxy. The output includes
the four required runner labels and the prerequisite check, but never obtains or
prints a GitHub runner registration token:

```powershell
.\scripts\dev\New-NextJsHostIntegrationRunnerOnboarding.ps1 `
  -TargetId windows-server-2022 `
  -ServiceManager winsw `
  -ReverseProxy iis `
  -OutputPath .\evidence\windows-server-2022-runner-onboarding.md
```

Register the dedicated verification host through the repository's GitHub Actions
runner settings using those labels. The generated onboarding document contains
the platform-specific runner `config` and service commands; replace only its
`<issued-token>` placeholder with the short-lived token from GitHub, then run
the generated prerequisite command after checkout. Do not place these validation labels on an unrelated production
workload host because native integration creates and removes temporary services
and proxy configuration.

After downloading the result artifacts from the completed workflow runs, compare
them with the same plan. The collector reports missing, duplicate, malformed,
or unplanned results and refuses to validate an incomplete matrix:

```powershell
.\scripts\dev\New-NextJsHostIntegrationPlan.ps1 `
  -ProductionRecommendedOnly `
  -Format Json `
  -OutputPath .\evidence\nextjs-host-integration-plan.json

node .\scripts\dev\New-NextJsHostIntegrationCoverage.mjs `
  --plan .\evidence\nextjs-host-integration-plan.json `
  --input .\evidence\nextjs-host-integration-artifacts `
  --sha (git rev-parse HEAD) `
  --run-ids '["123456789","123456790"]' `
  --output .\evidence\nextjs-host-integration-coverage

node .\scripts\dev\New-NextJsHostIntegrationCoverage.mjs `
  --validate-summary .\evidence\nextjs-host-integration-coverage\nextjs-host-integration-coverage.json `
  --sha (git rev-parse HEAD)
```

Coverage verifies only the deployment-kit synthetic integration path. It binds
every accepted artifact and summary to the supplied 40-character commit SHA,
and rejects artifacts from another commit, workflow, job, run ID, or run
attempt. The generated report retains the accepted source run ID and attempt
for each target combination. Keep
the separate host status evidence for the deployed application and required
uptime.

For normal collection, use the manual `Next.js Self-Hosted Integration
Coverage` workflow on the protected default branch instead of downloading
artifacts by hand. Supply the JSON array of completed native evidence run IDs;
the workflow uses the GitHub Actions token only to download those artifacts,
requires every result to match the current default-branch commit, and uploads
the generated coverage report. It cannot accept a result from an unlisted run,
another workflow, another job, or another commit.

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
prove `systemctl`. Final host status evidence also checks that the managed
service definition still matches `NODE_BIN`, `APP_DIR`, `START_SCRIPT`, and
`NODE_ARGUMENTS`, so an old systemd unit, launchd plist/runner, OpenRC script,
System V script, or BSD rc script cannot silently count as current deployment
proof.

The CI workflow also creates a temporary real `next@latest` application on
Ubuntu, Windows Server 2022, Windows Server 2025, and macOS 15. It builds the application, packages
both deployment modes with the platform helper, extracts the package, and
checks that the resulting runtime serves HTTP. Unix runs use the rendered
launchd runner, exercising the managed `PORT`, `HOST`, and `HOSTNAME`
environment contract. Windows Server 2022 and 2025 runners also start the
same packages through a temporary checksum-verified WinSW service and remove
it after the HTTP check. This complements the layout and
service-template checks, but it does not replace self-hosted host evidence for
release signoff.

For `standalone`, the preflight validates:

- `AppFramework` / `APP_FRAMEWORK` is `nextjs`.
- `NextjsDeploymentMode` / `NEXTJS_DEPLOYMENT_MODE` is valid.
- `NodeExe` / `NODE_BIN` reports a Node.js version at or above
  `NextjsMinimumNodeVersion` / `NEXTJS_MINIMUM_NODE_VERSION`.
- `StartCommand` / `START_SCRIPT` points to a safe `server.js` path.
- The runtime root has `.next`.
- The runtime root has `.next/BUILD_ID`.
- The runtime root has `.next/static` when static assets are required.
- The runtime root has `public` when public directory validation is required.
- The runtime root has `node_modules/next/package.json` so evidence can prove
  the installed Next.js package version.

For `next-start`, the preflight validates:

- `NodeArguments` / `NODE_ARGUMENTS` starts with `start`.
- `NodeArguments` / `NODE_ARGUMENTS` includes `-H <BindAddress>` or
  `--hostname <BindAddress>`.
- `package.json` exists.
- `.next` exists.
- `node_modules/next` exists.
- `node_modules/next/package.json` exists so evidence can prove the installed
  Next.js package version.
- `node_modules/next/dist/bin/next` exists.
- `StartCommand` / `START_SCRIPT` points exactly to
  `node_modules/next/dist/bin/next` under the app directory.

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
`.next/static`, `node_modules/next`, `node_modules/next/dist/bin/next`, or
compatible Node.js runtime evidence are missing for the selected mode. The
JSON evidence must also include the installed Next.js package version from the
active runtime folder, so a release claim cannot pass with only a guessed or
undocumented framework version. To collect the same layout information in a
machine-readable release evidence file, run:

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
environment values. Its JSON evidence includes `nodeVersion`,
`minimumNodeVersion`, `nodeVersionSatisfied`, and
`nextVersion`, plus `nextStartScriptIsExpectedCli` for `next-start` services.
Use `--json-output` for release evidence on Linux, macOS, and BSD hosts. Unix
diagnostics include a safe Next.js runtime layout section for Linux, macOS, and
BSD service-manager modes:

Unix preflight blocks selected reverse-proxy deployments when the matching
proxy executable is missing, so an `nginx`, Apache/httpd, HAProxy, or Traefik
configuration is not written on a host that cannot validate or reload it.

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
