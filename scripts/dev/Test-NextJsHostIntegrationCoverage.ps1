param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$CoveragePath = Join-Path $ScriptDir 'New-NextJsHostIntegrationCoverage.mjs'
$PlanPath = Join-Path $ScriptDir 'New-NextJsHostIntegrationPlan.ps1'
$HostResultValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationResult.mjs'

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Context)
  if (-not $Text.Contains($Expected)) { throw "$Context is missing expected text: $Expected" }
}

Write-Host ''
Write-Host '==> Next.js self-hosted integration coverage'
foreach ($path in @($CoveragePath, $PlanPath, $HostResultValidatorPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Next.js integration coverage artifact: $path" }
}

$coverage = Get-Content -LiteralPath $CoveragePath -Raw
foreach ($expected in @(
    'nextjs-self-hosted-integration-coverage',
    'nextjs-self-hosted-integration-plan',
    'validateHostIntegrationResult',
    "const hostIntegrationWorkflow = 'Next.js Self-Hosted Integration';",
    "const hostIntegrationJob = 'collect';",
    'workflow: hostIntegrationWorkflow',
    'job: hostIntegrationJob',
    'Source Run',
    'runId: result.ci.runId',
    'runAttempt: result.ci.runAttempt',
    'runnerEnvironment',
    'Missing',
    'Duplicate Artifacts',
    'Unexpected Artifacts',
    'expectedSha',
    'Expected commit SHA',
    'Source run IDs',
    'sourceRunIds',
    'Result run ID',
    'Coverage summary sourceWorkflow is invalid.',
    'Coverage summary passed record runId is not selected as a source run.',
    'Coverage summary passedCount does not match passed records.',
    'Coverage summary expectedCount does not equal passed plus missing dispatches.',
    'Coverage summary complete flag does not match its recorded coverage state.',
    'Coverage summary passed record runId is invalid.',
    'Coverage summary contains duplicate passed dispatch:',
    '--sha',
    '--run-ids',
    '--validate-summary',
    'Self-hosted Next.js integration coverage is incomplete.',
    '--self-test'
  )) {
  Assert-Contains -Text $coverage -Expected $expected -Context 'New-NextJsHostIntegrationCoverage.mjs'
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node is required to validate Next.js self-hosted integration coverage.' }
& $node.Source --check $CoveragePath
if ($LASTEXITCODE -ne 0) { throw 'Next.js self-hosted integration coverage syntax check failed.' }
& $node.Source $CoveragePath --self-test
if ($LASTEXITCODE -ne 0) { throw 'Next.js self-hosted integration coverage self-test failed.' }

$root = Join-Path $RepoRoot ".tmp\nextjs-host-integration-coverage-$([Guid]::NewGuid().ToString('N'))"
$planFile = Join-Path $root 'plan.json'
$output = Join-Path $root 'output'
New-Item -ItemType Directory -Force -Path $root | Out-Null
& $PlanPath -TargetId ubuntu -Format Json -OutputPath $planFile -Quiet
$expectedSha = 'a' * 40
& $node.Source $CoveragePath --plan $planFile --input (Join-Path $root 'missing-artifacts') --output $output --sha $expectedSha --run-ids '["123"]'
$summary = Get-Content -LiteralPath (Join-Path $output 'nextjs-host-integration-coverage.json') -Raw | ConvertFrom-Json
if ($summary.complete -ne $false -or [int]$summary.missingCount -lt 1) {
  throw 'Empty artifact coverage must report missing planned dispatches without claiming completion.'
}

Write-Host 'Next.js self-hosted integration coverage OK'
