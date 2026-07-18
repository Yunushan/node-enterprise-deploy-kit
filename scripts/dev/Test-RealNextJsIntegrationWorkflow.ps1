param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\ci.yml"
$IntegrationScriptPath = Join-Path $ScriptDir "test-real-nextjs-integration.mjs"
$ResultValidatorPath = Join-Path $ScriptDir "Test-NextJsIntegrationResult.mjs"
$ResultSummaryPath = Join-Path $ScriptDir "New-NextJsIntegrationSummary.mjs"
$LinuxContainerScriptPath = Join-Path $ScriptDir "test-linux-container-smoke.sh"
$ResultActionPath = Join-Path $RepoRoot ".github\actions\upload-nextjs-integration-result\action.yml"

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Expected,
    [string]$Context
  )

  if (-not $Text.Contains($Expected)) {
    throw "$Context is missing expected text: $Expected"
  }
}

Write-Host ""
Write-Host "==> Real Next.js integration workflow"

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Missing CI workflow: .github/workflows/ci.yml"
}
if (-not (Test-Path -LiteralPath $IntegrationScriptPath -PathType Leaf)) {
  throw "Missing real Next.js integration script: scripts/dev/test-real-nextjs-integration.mjs"
}
if (-not (Test-Path -LiteralPath $ResultValidatorPath -PathType Leaf)) {
  throw "Missing Next.js integration result validator: scripts/dev/Test-NextJsIntegrationResult.mjs"
}
if (-not (Test-Path -LiteralPath $ResultSummaryPath -PathType Leaf)) {
  throw "Missing Next.js integration summary: scripts/dev/New-NextJsIntegrationSummary.mjs"
}
if (-not (Test-Path -LiteralPath $LinuxContainerScriptPath -PathType Leaf)) {
  throw "Missing Linux container smoke script: scripts/dev/test-linux-container-smoke.sh"
}
if (-not (Test-Path -LiteralPath $ResultActionPath -PathType Leaf)) {
  throw "Missing Next.js integration result upload action: .github/actions/upload-nextjs-integration-result/action.yml"
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$script = Get-Content -LiteralPath $IntegrationScriptPath -Raw
$resultValidator = Get-Content -LiteralPath $ResultValidatorPath -Raw
$resultSummary = Get-Content -LiteralPath $ResultSummaryPath -Raw
$containerScript = Get-Content -LiteralPath $LinuxContainerScriptPath -Raw
$resultAction = Get-Content -LiteralPath $ResultActionPath -Raw

foreach ($expected in @(
    "real-nextjs-integration:",
    "real-nextjs-integration (`${{ matrix.os }})",
    "ubuntu-latest",
    "windows-2022",
    "windows-2025",
    "macos-15",
    "Set up Node.js 22",
    "actions/setup-node@v6",
    "node-version: '22'",
    "node scripts/dev/test-real-nextjs-integration.mjs",
    "RUN_LAUNCHD_SERVICE_INTEGRATION:",
    "actions/checkout@v7",
    "real-windows-service-nextjs:",
    "real-windows-service-nextjs (`${{ matrix.os }})",
    "RUN_WINSW_SERVICE_INTEGRATION: `"true`"",
    "real-windows-service-iis-nextjs:",
    "real-windows-service-iis-nextjs (`${{ matrix.os }}, `${{ matrix.manager }})",
    "RUN_WINDOWS_IIS_INTEGRATION: `"true`"",
    "RUN_NSSM_SERVICE_INTEGRATION = 'true'",
    "choco install urlrewrite --version=2.1.20190828",
    "choco install iis-arr --version=3.0.20210521",
    "choco install nssm --version=2.24.101.20180116",
    "real-macos-service-nextjs:",
    "real-macos-service-nextjs (macos-15)",
    "RUN_LAUNCHD_SERVICE_INTEGRATION=true",
    "real-macos-service-nginx-nextjs:",
    "real-macos-service-nginx-nextjs (macos-15)",
    "brew install nginx",
    "RUN_NGINX_PROXY_INTEGRATION=true",
    "real-macos-service-proxy-nextjs:",
    "real-macos-service-proxy-nextjs (macos-15, `${{ matrix.proxy }})",
    "package: httpd",
    "package: haproxy",
    "package: traefik",
    "RUN_APACHE_PROXY_INTEGRATION=true",
    "RUN_HAPROXY_INTEGRATION=true",
    "RUN_TRAEFIK_PROXY_INTEGRATION=true",
    "linux-container-real-nextjs-systemv:",
    "linux-container-real-nextjs-systemv (ubuntu)",
    "--systemv-service-integration",
    "linux-container-real-nextjs-systemv-proxy:",
    "linux-container-real-nextjs-systemv-proxy (`${{ matrix.proxy }})",
    "haproxy) proxy_flag=--haproxy-integration",
    "*) proxy_flag=--`${{ matrix.proxy }}-proxy-integration",
    "linux-container-real-nextjs-openrc:",
    "linux-container-real-nextjs-openrc (alpine)",
    "--openrc-service-integration",
    "linux-container-real-nextjs-openrc-proxy:",
    "linux-container-real-nextjs-openrc-proxy (`${{ matrix.proxy }})",
    "bash scripts/dev/test-linux-container-smoke.sh --platform alpine --real-nextjs --openrc-service-integration `"`$proxy_flag`"",
    "linux-container-real-nextjs-apache:",
    "linux-container-real-nextjs-apache (ubuntu)",
    "--apache-proxy-integration",
    "linux-container-real-nextjs-nginx:",
    "linux-container-real-nextjs-nginx (ubuntu)",
    "--nginx-proxy-integration",
    "linux-container-real-nextjs-haproxy:",
    "linux-container-real-nextjs-haproxy (ubuntu)",
    "--haproxy-integration",
    "linux-container-real-nextjs-traefik:",
    "linux-container-real-nextjs-traefik (ubuntu)",
    "--traefik-proxy-integration",
    "real-linux-systemd-nextjs:",
    "real-linux-systemd-nextjs (ubuntu, nginx)",
    "RUN_SYSTEMD_SERVICE_INTEGRATION=true",
    "RUN_NGINX_PROXY_INTEGRATION=true",
    "NEXTJS_INTEGRATION_TEMP_ROOT=/srv/node-enterprise-deploy-kit-ci",
    "NEXTJS_INTEGRATION_RESULT_PATH",
    "NEXTJS_INTEGRATION_TARGET",
    'GITHUB_JOB="$GITHUB_JOB"',
    "Upload real Next.js integration result",
    "Upload Linux container Next.js integration result",
    "uses: ./.github/actions/upload-nextjs-integration-result",
    "if: always()",
    "nextjs-integration-summary:",
    "Next.js integration result summary",
    "actions/download-artifact@v8",
    "NEXTJS_INTEGRATION_NEEDS_JSON: `${{ toJSON(needs) }}",
    "New-NextJsIntegrationSummary.mjs",
    "Enforce hosted Next.js integration result coverage",
    "--validate-summary .tmp/nextjs-integration-summary/nextjs-integration-summary.json",
    "GITHUB_STEP_SUMMARY"
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context ".github/workflows/ci.yml"
}

foreach ($expected in @(
    "next@`${nextVersion}",
    "NEXTJS_INTEGRATION_RESULT_PATH",
    "writeIntegrationResult",
    "hosted-nextjs-integration",
    "schemaVersion: 1",
    "expectedModes: ['standalone', 'next-start']",
    "verifiedModes: verificationPassed ? ['standalone', 'next-start'] : []",
    "writeIntegrationResult(integrationStatus, installedVersion)",
    "NEXTJS_INTEGRATION_EXECUTION",
    "NEXTJS_INTEGRATION_TARGET",
    "NEXTJS_INTEGRATION_RUNNER_ENVIRONMENT",
    "GITHUB_JOB",
    "await verifyMode(standaloneProjectPath, 'standalone', installedVersion)",
    "await verifyMode(nextStartProjectPath, 'next-start', installedVersion)",
    "Real Next.js `${mode} package/import/runtime integration OK.",
    "New-NextJsStandalonePackage.ps1",
    "package-nextjs-standalone.sh",
    "Import-AppPackage.ps1",
    "NEXTJS_REQUIRE_PACKAGE_PROVENANCE",
    "verifyPackageProvenance",
    "verifyImportedPackageProvenance",
    "restoreTestDirectoryOwnership",
    "runAsRoot('chown', ['-R'",
    "expectedManifestProvenance",
    "buildArchitecture: expectedProvenance.buildArchitecture",
    "Object.keys(manifest.packageProvenance || {}).sort()",
    "package provenance marker must not remain",
    "node_modules', 'next', 'package.json",
    "launchd-runner.sh.tpl",
    "verifyUnixManagedRunner",
    "RUN_LAUNCHD_SERVICE_INTEGRATION",
    "verifyMacosLaunchdService",
    "afterServiceReady",
    "install-node-service.sh",
    "uninstall-node-service.sh",
    "getUnixPrimaryGroup",
    "launchctl', 'print'",
    "stderr.log",
    "RUN_WINSW_SERVICE_INTEGRATION",
    "verifyWindowsWinSwService",
    "RUN_NSSM_SERVICE_INTEGRATION",
    "verifyWindowsNssmService",
    "RUN_WINDOWS_IIS_INTEGRATION",
    "verifyWindowsIisProxy",
    "removeTemporaryWindowsIisSite",
    "nativeWindowsPowerShell",
    "Install-ReverseProxy.ps1",
    "Install-NSSMService.ps1",
    "Install-NodeService.ps1",
    "Uninstall-NodeService.ps1",
    "RUN_LAUNCHD_SERVICE_INTEGRATION",
    "verifyMacosLaunchdService",
    "install-node-service.sh",
    "uninstall-node-service.sh",
    "SERVICE_MANAGER=`"launchd`"",
    "RUN_SYSTEMV_SERVICE_INTEGRATION",
    "verifyLinuxSystemVService",
    "SERVICE_MANAGER: 'systemv'",
    "withLinuxProxyBackend",
    "verifySelectedLinuxReverseProxy",
    "hasLinuxProxyIntegration",
    "RUN_OPENRC_SERVICE_INTEGRATION",
    "verifyLinuxOpenRcService",
    "SERVICE_MANAGER: 'openrc'",
    "RUN_SYSTEMD_SERVICE_INTEGRATION",
    "verifyLinuxSystemdService",
    "SERVICE_MANAGER: 'systemd'",
    "RUN_APACHE_PROXY_INTEGRATION",
    "verifyLinuxApacheProxy",
    "resolveLinuxApacheInstallation",
    "getApacheBuiltInModules",
    "apacheLoadModuleDirective",
    "builtInModules",
    "verifyMacosApacheProxy",
    "resolveMacosHttpdInstallation",
    "mod_log_config.so",
    "mod_unixd.so",
    "User _www",
    "Group _www",
    "apache-vhost.conf.tpl",
    "apacheInstallation.command, ['-t', '-f'",
    "Apache diagnostics",
    "mimeTypesPath: '/etc/mime.types'",
    "RUN_NGINX_PROXY_INTEGRATION",
    "verifyLinuxNginxProxy",
    "resolveNginxMimeTypes",
    "nginx-site.conf.tpl",
    "RUN_HAPROXY_INTEGRATION",
    "verifyLinuxHaProxy",
    "haproxy.cfg.tpl",
    "RUN_TRAEFIK_PROXY_INTEGRATION",
    "verifyLinuxTraefikProxy",
    "traefik-dynamic.yml.tpl",
    "waitForPage",
    "response.body.slice(0, 500)",
    "waitForForwardedProxyHeaders",
    "waitForForwardedRuntimeHeaders",
    "proxy-evidence",
    "fs.rm(testRoot",
    "NEXTJS_INTEGRATION_TEMP_ROOT",
    "/srv/node-enterprise-deploy-kit-ci",
    "os.tmpdir()",
    "NEXT_TELEMETRY_DISABLED",
    "verifyNpmRegistryAccess",
    "npm_config_fetch_retries",
    "NEXTJS_INTEGRATION_COMMAND_TIMEOUT_MS",
    "NEXTJS_INTEGRATION_NPM_INSTALL_TIMEOUT_MS",
    "NEXTJS_INTEGRATION_NPM_BUILD_TIMEOUT_MS",
    "NEXTJS_INTEGRATION_NPM_REGISTRY_TIMEOUT_MS",
    "timed out after",
    "collectHostIdentity",
    "assertSelfHostedTargetIdentity",
    "/etc/os-release",
    "Self-hosted runner identity does not match target",
    "Cannot reach the configured npm registry with a trusted TLS certificate"
  )) {
  Assert-Contains -Text $script -Expected $expected -Context "scripts/dev/test-real-nextjs-integration.mjs"
}

foreach ($expected in @(
    "/run/openrc/softlevel",
    "service_integration_count",
    "proxy_integration_count",
    "RUN_TRAEFIK_PROXY_INTEGRATION",
    'NEXTJS_INTEGRATION_RESULT_PATH="$result_path"',
    'NEXTJS_INTEGRATION_EXECUTION="container"',
    'NEXTJS_INTEGRATION_TARGET="$PLATFORM_CASE"',
    "install_traefik",
    "TRAEFIK_VERSION",
    "e92bcfb03fa1e6a70c4e7ad4eb4f1604967e6fa3c21d8e7605aca5407a40162c",
    "github.com/traefik/traefik/releases/download"
  )) {
  Assert-Contains -Text $containerScript -Expected $expected -Context "scripts/dev/test-linux-container-smoke.sh"
}

foreach ($expected in @(
    "validateIntegrationResult",
    "hosted-nextjs-integration",
    "expectedModes",
    "verifiedModes",
    "runnerEnvironment",
    "platform.identity",
    "isMainModule",
    "pathToFileURL",
    "must match the overall result status.",
    "--self-test"
  )) {
  Assert-Contains -Text $resultValidator -Expected $expected -Context "scripts/dev/Test-NextJsIntegrationResult.mjs"
}

foreach ($expected in @(
    "buildSummary",
    "hosted-nextjs-integration-summary",
    "invalidArtifacts",
    "upstreamJobs",
    "This summarizes observed GitHub-hosted integration artifacts.",
    "Hosted integration summary only accepts GitHub Actions result artifacts.",
    "Hosted integration summary only accepts GitHub-hosted result artifacts.",
    "--self-test"
  )) {
  Assert-Contains -Text $resultSummary -Expected $expected -Context "scripts/dev/New-NextJsIntegrationSummary.mjs"
}

foreach ($expected in @(
    "Validate integration result when present",
    "Test-NextJsIntegrationResult.mjs",
    "actions/upload-artifact@v7",
    "if-no-files-found",
    "retention-days"
  )) {
  Assert-Contains -Text $resultAction -Expected $expected -Context ".github/actions/upload-nextjs-integration-result/action.yml"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  throw "node is required to validate the real Next.js integration script."
}
& $node.Source --check $IntegrationScriptPath
if ($LASTEXITCODE -ne 0) {
  throw "Real Next.js integration script syntax check failed."
}
& $node.Source $ResultValidatorPath --self-test
if ($LASTEXITCODE -ne 0) {
  throw "Next.js integration result validator self-test failed."
}
& $node.Source $ResultSummaryPath --self-test
if ($LASTEXITCODE -ne 0) {
  throw "Next.js integration summary self-test failed."
}

Write-Host "Real Next.js integration workflow OK"
