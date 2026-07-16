param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\ci.yml"
$IntegrationScriptPath = Join-Path $ScriptDir "test-real-nextjs-integration.mjs"
$LinuxContainerScriptPath = Join-Path $ScriptDir "test-linux-container-smoke.sh"

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
if (-not (Test-Path -LiteralPath $LinuxContainerScriptPath -PathType Leaf)) {
  throw "Missing Linux container smoke script: scripts/dev/test-linux-container-smoke.sh"
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$script = Get-Content -LiteralPath $IntegrationScriptPath -Raw
$containerScript = Get-Content -LiteralPath $LinuxContainerScriptPath -Raw

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
    "NEXTJS_INTEGRATION_TEMP_ROOT=/srv/node-enterprise-deploy-kit-ci"
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context ".github/workflows/ci.yml"
}

foreach ($expected in @(
    "next@`${nextVersion}",
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
    "verifyMacosApacheProxy",
    "resolveMacosHttpdInstallation",
    "mod_log_config.so",
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
    "Cannot reach the configured npm registry with a trusted TLS certificate"
  )) {
  Assert-Contains -Text $script -Expected $expected -Context "scripts/dev/test-real-nextjs-integration.mjs"
}

foreach ($expected in @(
    "/run/openrc/softlevel",
    "service_integration_count",
    "proxy_integration_count",
    "RUN_TRAEFIK_PROXY_INTEGRATION",
    "install_traefik",
    "TRAEFIK_VERSION",
    "e92bcfb03fa1e6a70c4e7ad4eb4f1604967e6fa3c21d8e7605aca5407a40162c",
    "github.com/traefik/traefik/releases/download"
  )) {
  Assert-Contains -Text $containerScript -Expected $expected -Context "scripts/dev/test-linux-container-smoke.sh"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  throw "node is required to validate the real Next.js integration script."
}
& $node.Source --check $IntegrationScriptPath
if ($LASTEXITCODE -ne 0) {
  throw "Real Next.js integration script syntax check failed."
}

Write-Host "Real Next.js integration workflow OK"
