param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\nextjs-host-integration-coverage.yml'
$DownloaderPath = Join-Path $ScriptDir 'Invoke-NextJsHostIntegrationArtifactDownload.mjs'
$CoveragePath = Join-Path $ScriptDir 'New-NextJsHostIntegrationCoverage.mjs'

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Context)
  if (-not $Text.Contains($Expected)) { throw "$Context is missing expected text: $Expected" }
}

Write-Host ''
Write-Host '==> Next.js self-hosted integration coverage workflow'
foreach ($path in @($WorkflowPath, $DownloaderPath, $CoveragePath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Next.js coverage workflow artifact: $path" }
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
foreach ($expected in @(
    'workflow_dispatch:',
    'run_ids:',
    'actions: read',
    'contents: read',
    'Require the protected default branch',
    'Next.js self-hosted coverage can run only from the protected default branch',
    'actions/checkout@v7',
    'actions/setup-node@v6',
    "node-version: '22'",
    'Invoke-NextJsHostIntegrationArtifactDownload.mjs',
    '--validate',
    'GH_TOKEN: ${{ github.token }}',
    'New-NextJsHostIntegrationPlan.ps1',
    'New-NextJsHostIntegrationCoverage.mjs',
    '--run-ids "$RUN_IDS"',
    '--sha "$GITHUB_SHA"',
    'actions/upload-artifact@v7',
    'nextjs-self-hosted-integration-coverage'
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context '.github/workflows/nextjs-host-integration-coverage.yml'
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node is required to validate Next.js coverage workflow.' }
& $node.Source --check $DownloaderPath
if ($LASTEXITCODE -ne 0) { throw 'Next.js artifact downloader syntax check failed.' }
& $node.Source $DownloaderPath --self-test
if ($LASTEXITCODE -ne 0) { throw 'Next.js artifact downloader self-test failed.' }

Write-Host 'Next.js self-hosted integration coverage workflow OK'
