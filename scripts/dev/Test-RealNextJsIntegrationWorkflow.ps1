param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\ci.yml"
$IntegrationScriptPath = Join-Path $ScriptDir "test-real-nextjs-integration.mjs"

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

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$script = Get-Content -LiteralPath $IntegrationScriptPath -Raw

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
    "real-macos-service-nextjs:",
    "real-macos-service-nextjs (macos-15)",
    "RUN_LAUNCHD_SERVICE_INTEGRATION=true",
    "linux-container-real-nextjs-systemv:",
    "linux-container-real-nextjs-systemv (ubuntu)",
    "--systemv-service-integration",
    "linux-container-real-nextjs-openrc:",
    "linux-container-real-nextjs-openrc (alpine)",
    "--openrc-service-integration",
    "real-linux-systemd-nextjs:",
    "real-linux-systemd-nextjs (ubuntu)",
    "RUN_SYSTEMD_SERVICE_INTEGRATION=true",
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
    "install-node-service.sh",
    "uninstall-node-service.sh",
    "getUnixPrimaryGroup",
    "launchctl', 'print'",
    "stderr.log",
    "RUN_WINSW_SERVICE_INTEGRATION",
    "verifyWindowsWinSwService",
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
    "RUN_OPENRC_SERVICE_INTEGRATION",
    "verifyLinuxOpenRcService",
    "SERVICE_MANAGER: 'openrc'",
    "RUN_SYSTEMD_SERVICE_INTEGRATION",
    "verifyLinuxSystemdService",
    "SERVICE_MANAGER: 'systemd'",
    "waitForPage",
    "fs.rm(testRoot",
    "NEXTJS_INTEGRATION_TEMP_ROOT",
    "os.tmpdir()",
    "NEXT_TELEMETRY_DISABLED",
    "verifyNpmRegistryAccess",
    "npm_config_fetch_retries",
    "Cannot reach the configured npm registry with a trusted TLS certificate"
  )) {
  Assert-Contains -Text $script -Expected $expected -Context "scripts/dev/test-real-nextjs-integration.mjs"
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
