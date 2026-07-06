param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\release-evidence.yml"
$InputValidatorPath = Join-Path $ScriptDir "Test-ReleaseEvidenceWorkflowInputs.ps1"
$BundleResolverPath = Join-Path $ScriptDir "Resolve-ReleaseEvidenceBundle.ps1"
$StepSummaryPath = Join-Path $ScriptDir "Write-ReleaseReadinessStepSummary.ps1"

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

function Assert-DoesNotContain {
  param(
    [string]$Text,
    [string]$Unexpected,
    [string]$Context
  )

  if ($Text.Contains($Unexpected)) {
    throw "$Context contains unexpected text: $Unexpected"
  }
}

function Assert-DoesNotMatch {
  param(
    [string]$Text,
    [string]$Pattern,
    [string]$Context
  )

  if ($Text -match $Pattern) {
    throw "$Context contains unexpected pattern: $Pattern"
  }
}

Write-Host ""
Write-Host "==> Release evidence workflow"

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Missing release evidence workflow: .github/workflows/release-evidence.yml"
}
if (-not (Test-Path -LiteralPath $InputValidatorPath -PathType Leaf)) {
  throw "Missing release evidence workflow input validator: scripts/dev/Test-ReleaseEvidenceWorkflowInputs.ps1"
}
if (-not (Test-Path -LiteralPath $BundleResolverPath -PathType Leaf)) {
  throw "Missing release evidence bundle resolver: scripts/dev/Resolve-ReleaseEvidenceBundle.ps1"
}
if (-not (Test-Path -LiteralPath $StepSummaryPath -PathType Leaf)) {
  throw "Missing release readiness step summary writer: scripts/dev/Write-ReleaseReadinessStepSummary.ps1"
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$inputValidator = Get-Content -LiteralPath $InputValidatorPath -Raw
$bundleResolver = Get-Content -LiteralPath $BundleResolverPath -Raw
$stepSummary = Get-Content -LiteralPath $StepSummaryPath -Raw
$workflowSupportScripts = "$workflow`n$inputValidator`n$bundleResolver`n$stepSummary"

& $InputValidatorPath -SelfTest
& $BundleResolverPath -SelfTest
& $StepSummaryPath -SelfTest

foreach ($expected in @(
    "workflow_dispatch:",
    "source_run_id:",
    "bundle_artifact_name:",
    "bundle_file:",
    "include_service_only:",
    "include_fallback:",
    "actions: read",
    "contents: read",
    "final-full-matrix-release-gate:",
    "Validate release evidence inputs",
    "Test-ReleaseEvidenceWorkflowInputs.ps1",
    "run: ./scripts/dev/Test-ReleaseEvidenceWorkflowInputs.ps1",
    "INCLUDE_FALLBACK: `${{ inputs.include_fallback }}",
    "INCLUDE_SERVICE_ONLY: `${{ inputs.include_service_only }}",
    "Assert-SafeSimpleName",
    "source_run_id is required.",
    "source_run_id must be a GitHub Actions numeric run id.",
    "source_run_id must be a positive GitHub Actions numeric run id.",
    '$DisplayName is required.',
    '$DisplayName must contain only letters, numbers, dot, underscore, or dash.',
    '$DisplayName must not be ''.'' or ''..''.',
    "bundle_file must be a simple .zip filename",
    "Assert-WorkflowBoolean",
    '$DisplayName must be true or false.',
    "actions/download-artifact@v8",
    "run-id: `${{ inputs.source_run_id }}",
    "github-token: `${{ github.token }}",
    "Validate final full-matrix release evidence",
    "Resolve-ReleaseEvidenceBundle.ps1",
    "-ArtifactRoot `$artifactRoot",
    "-BundleFile `$env:BUNDLE_FILE",
    "-Quiet",
    "Release evidence bundle resolver did not return a bundle path.",
    "Expected exactly one release evidence .zip bundle in the downloaded artifact",
    "Requested bundle_file was not found in the downloaded artifact.",
    "Test-ReleaseSupportReadiness.ps1",
    "-StrictCiRelease",
    "-RequireFinalFullMatrixReleaseClaim",
    "-IncludeServiceOnly",
    "-IncludeFallback",
    "releaseClaim.finalFullMatrixReleaseClaim",
    "New-ReleaseReadinessSummary.ps1",
    '-InputPath "release-readiness.json"',
    '-OutputPath "release-readiness-summary.json"',
    "-RequireFinalFullMatrixReleaseClaim",
    "Write-ReleaseReadinessStepSummary.ps1",
    '-InputPath "release-readiness-summary.json"',
    "-OutputPath `$env:GITHUB_STEP_SUMMARY",
    "release-readiness-summary.json",
    "GITHUB_STEP_SUMMARY",
    "Release Evidence Gate",
    "Final full-matrix claim:",
    "Release claim:",
    "Review scope:",
    "Proof level:",
    "Source commit:",
    "Source tracked dirty:",
    "Bundle CI workflow:",
    "Bundle CI run:",
    "Coverage:",
    "Targets:",
    "actions/upload-artifact@v7",
    "Upload release readiness summary",
    "path: release-readiness-summary.json"
  )) {
  Assert-Contains -Text $workflowSupportScripts -Expected $expected -Context "release evidence workflow support scripts"
}

foreach ($unexpected in @(
    "push:",
    "pull_request:",
    "schedule:",
    "release-evidence/*.zip",
    "path: release-readiness.json",
    '$safeReadiness = [ordered]@',
    "ConvertTo-Json -Depth 8",
    '$readiness.bundlePath',
    "collectionCommand",
    "workflowDispatchCommand",
    "Source branch:",
    "branchName",
    'Get-Content -LiteralPath $bundlePath',
    'Get-Content -LiteralPath "release-readiness.json" -Raw | ConvertFrom-Json',
    'Release readiness did not prove finalFullMatrixReleaseClaim.',
    'Get-ChildItem -LiteralPath $artifactRoot -Recurse -File -Filter "*.zip"',
    'Join-Path $artifactRoot $env:BUNDLE_FILE',
    'Add-Content -Path $env:GITHUB_STEP_SUMMARY',
    '- Final full-matrix claim: $($readiness.releaseClaim.finalFullMatrixReleaseClaim)'
  )) {
  Assert-DoesNotContain -Text $workflow -Unexpected $unexpected -Context ".github/workflows/release-evidence.yml"
}

foreach ($unexpectedPattern in @(
    '\$readiness\.coverage\.covered(?!Count)',
    '\$readiness\.coverage\.missing(?!Count)'
  )) {
  Assert-DoesNotMatch -Text $workflow -Pattern $unexpectedPattern -Context ".github/workflows/release-evidence.yml"
}

$uploadArtifactBlocks = @([regex]::Matches($workflow, '(?ms)uses:\s+actions/upload-artifact@v7.*?(?=\r?\n\s+- name:|\z)'))
if ($uploadArtifactBlocks.Count -ne 1) {
  throw ".github/workflows/release-evidence.yml must have exactly one upload-artifact block for the redacted readiness summary."
}
$releaseReadinessUploadBlock = $uploadArtifactBlocks[0].Value
Assert-Contains -Text $releaseReadinessUploadBlock -Expected "path: release-readiness-summary.json" -Context ".github/workflows/release-evidence.yml upload-artifact block"
foreach ($unexpectedUploadText in @(
    ".zip",
    "release-evidence-input",
    "release-readiness.json"
  )) {
  Assert-DoesNotContain -Text $releaseReadinessUploadBlock -Unexpected $unexpectedUploadText -Context ".github/workflows/release-evidence.yml upload-artifact block"
}

Write-Host "Release evidence workflow OK"
