param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\support-evidence-bundle.yml"
$InputValidatorPath = Join-Path $ScriptDir "Test-SupportEvidenceBundleWorkflowInputs.ps1"

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

Write-Host ""
Write-Host "==> Support evidence bundle workflow"

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Missing support evidence bundle workflow: .github/workflows/support-evidence-bundle.yml"
}
if (-not (Test-Path -LiteralPath $InputValidatorPath -PathType Leaf)) {
  throw "Missing support evidence bundle workflow input validator: scripts/dev/Test-SupportEvidenceBundleWorkflowInputs.ps1"
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$inputValidator = Get-Content -LiteralPath $InputValidatorPath -Raw
$workflowAndInputValidator = "$workflow`n$inputValidator"

& $InputValidatorPath -SelfTest

foreach ($expected in @(
    "workflow_dispatch:",
    "runner_labels:",
    "evidence_path:",
    "artifact_path:",
    "default: ''",
    "output_directory:",
    "bundle_name:",
    "bundle_artifact_name:",
    "include_service_only:",
    "include_fallback:",
    "strict_ci_release:",
    "require_final_full_matrix_release_claim:",
    "allow_local_collection:",
    "upload_retention_days:",
    "validate-dispatch:",
    "Validate support evidence bundle inputs",
    "Test-SupportEvidenceBundleWorkflowInputs.ps1",
    "needs: validate-dispatch",
    "runs-on: `${{ fromJSON(inputs.runner_labels) }}",
    "Checkout repository without deleting private evidence workspace",
    "clean: false",
    "Invoke-SupportEvidenceReleaseWorkflow.ps1",
    "-StrictCiRelease",
    "-RequireFinalFullMatrixReleaseClaim",
    "Expected support evidence bundle was not created.",
    "Upload private support evidence bundle",
    "actions/upload-artifact@v7",
    'path: ${{ inputs.output_directory }}/${{ inputs.bundle_name }}.zip',
    "retention-days: `${{ inputs.upload_retention_days }}",
    "runner_labels must be a JSON array containing self-hosted.",
    "runner_labels must include self-hosted for private support evidence bundling.",
    "runner_labels must not use GitHub-hosted runner labels for private support evidence bundling.",
    "evidence_path is required and must be a relative path",
    "artifact_path must not contain parent traversal",
    "bundle_name must be a file stem",
    "bundle_artifact_name must contain only",
    "require_final_full_matrix_release_claim requires strict_ci_release=true.",
    "upload_retention_days must be an integer from 1 to 90."
  )) {
  Assert-Contains -Text $workflowAndInputValidator -Expected $expected -Context "support evidence bundle workflow and input validator"
}

foreach ($unexpected in @(
    "push:",
    "pull_request:",
    "schedule:",
    "path: release-readiness.json",
    "path: release-readiness-summary.json",
    "path: coverage-report",
    "release-evidence/*.zip"
  )) {
  Assert-DoesNotContain -Text $workflow -Unexpected $unexpected -Context ".github/workflows/support-evidence-bundle.yml"
}

Write-Host "Support evidence bundle workflow OK"
