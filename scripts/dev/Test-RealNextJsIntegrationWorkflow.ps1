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
    "macos-15",
    "node scripts/dev/test-real-nextjs-integration.mjs",
    "actions/checkout@v7"
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context ".github/workflows/ci.yml"
}

foreach ($expected in @(
    "next@`${nextVersion}",
    "await verifyMode(projectPath, 'standalone')",
    "await verifyMode(projectPath, 'next-start')",
    "Real Next.js `${mode} package/runtime integration OK.",
    "New-NextJsStandalonePackage.ps1",
    "package-nextjs-standalone.sh",
    "node_modules', 'next', 'package.json",
    "waitForPage",
    "fs.rm(testRoot",
    "NEXT_TELEMETRY_DISABLED"
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
