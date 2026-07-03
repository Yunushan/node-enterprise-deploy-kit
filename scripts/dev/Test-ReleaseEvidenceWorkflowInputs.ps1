param(
  [string]$SourceRunId = $env:SOURCE_RUN_ID,
  [string]$BundleArtifactName = $env:BUNDLE_ARTIFACT_NAME,
  [string]$BundleFile = $env:BUNDLE_FILE,
  [string]$IncludeServiceOnly = $env:INCLUDE_SERVICE_ONLY,
  [string]$IncludeFallback = $env:INCLUDE_FALLBACK,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-SafeSimpleName {
  param(
    [string]$Value,
    [string]$DisplayName,
    [int]$MaxLength = 128
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$DisplayName is required."
  }
  $name = $Value.Trim()
  if ($name.Length -gt $MaxLength) {
    throw "$DisplayName must be $MaxLength characters or less."
  }
  if ($name -in @(".", "..")) {
    throw "$DisplayName must not be '.' or '..'."
  }
  if ($name -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$DisplayName must contain only letters, numbers, dot, underscore, or dash."
  }
}

function Assert-WorkflowBoolean {
  param(
    [string]$Value,
    [string]$DisplayName
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$DisplayName is required and must be true or false."
  }
  if ($Value.Trim().ToLowerInvariant() -notin @("true", "false")) {
    throw "$DisplayName must be true or false."
  }
}

function Invoke-ReleaseEvidenceWorkflowInputValidation {
  param(
    [string]$SourceRunId,
    [string]$BundleArtifactName,
    [string]$BundleFile,
    [string]$IncludeServiceOnly,
    [string]$IncludeFallback
  )

  if ([string]::IsNullOrWhiteSpace($SourceRunId)) {
    throw "source_run_id is required."
  }
  $runId = $SourceRunId.Trim()
  if ($runId -notmatch '^[0-9]+$') {
    throw "source_run_id must be a GitHub Actions numeric run id."
  }
  if ($runId.Length -gt 20 -or [decimal]$runId -le 0) {
    throw "source_run_id must be a positive GitHub Actions numeric run id."
  }

  Assert-SafeSimpleName -Value $BundleArtifactName -DisplayName "bundle_artifact_name"

  if (-not [string]::IsNullOrWhiteSpace($BundleFile)) {
    Assert-SafeSimpleName -Value $BundleFile -DisplayName "bundle_file"
    if ($BundleFile.Trim() -notmatch '^[A-Za-z0-9._-]+\.zip$') {
      throw "bundle_file must be a simple .zip filename containing only letters, numbers, dot, underscore, or dash."
    }
  }

  Assert-WorkflowBoolean -Value $IncludeServiceOnly -DisplayName "include_service_only"
  Assert-WorkflowBoolean -Value $IncludeFallback -DisplayName "include_fallback"
}

function Invoke-ExpectValidationFailure {
  param(
    [string]$Name,
    [string]$ExpectedMessage,
    [scriptblock]$Action
  )

  $failed = $false
  try {
    & $Action
  }
  catch {
    $failed = $true
    if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
      throw "$Name failed with unexpected message: $($_.Exception.Message)"
    }
  }
  if (-not $failed) {
    throw "$Name succeeded unexpectedly."
  }
}

function Invoke-SelfTest {
  Write-Host ""
  Write-Host "==> Release evidence workflow input validation"

  $base = @{
    SourceRunId = "123456789"
    BundleArtifactName = "support-evidence"
    BundleFile = ""
    IncludeServiceOnly = "true"
    IncludeFallback = "true"
  }
  Invoke-ReleaseEvidenceWorkflowInputValidation @base

  $withBundleFile = $base.Clone()
  $withBundleFile.BundleFile = "node-enterprise-deploy-kit-1.0.0-evidence.zip"
  $withBundleFile.IncludeServiceOnly = "false"
  $withBundleFile.IncludeFallback = "false"
  Invoke-ReleaseEvidenceWorkflowInputValidation @withBundleFile

  Invoke-ExpectValidationFailure -Name "empty source run id" -ExpectedMessage "source_run_id is required" -Action {
    $case = $base.Clone()
    $case.SourceRunId = ""
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "non-numeric source run id" -ExpectedMessage "source_run_id must be a GitHub Actions numeric run id" -Action {
    $case = $base.Clone()
    $case.SourceRunId = "run-123"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "zero source run id" -ExpectedMessage "positive GitHub Actions numeric run id" -Action {
    $case = $base.Clone()
    $case.SourceRunId = "0"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "empty artifact name" -ExpectedMessage "bundle_artifact_name is required" -Action {
    $case = $base.Clone()
    $case.BundleArtifactName = ""
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "path artifact name" -ExpectedMessage "bundle_artifact_name must contain only letters" -Action {
    $case = $base.Clone()
    $case.BundleArtifactName = "../support-evidence"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "dot artifact name" -ExpectedMessage "bundle_artifact_name must not be '.' or '..'" -Action {
    $case = $base.Clone()
    $case.BundleArtifactName = "."
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "non-zip bundle file" -ExpectedMessage "bundle_file must be a simple .zip filename" -Action {
    $case = $base.Clone()
    $case.BundleFile = "support-evidence.7z"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "path bundle file" -ExpectedMessage "bundle_file must contain only letters" -Action {
    $case = $base.Clone()
    $case.BundleFile = "nested/support-evidence.zip"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "invalid include service only" -ExpectedMessage "include_service_only must be true or false" -Action {
    $case = $base.Clone()
    $case.IncludeServiceOnly = "yes"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "invalid include fallback" -ExpectedMessage "include_fallback must be true or false" -Action {
    $case = $base.Clone()
    $case.IncludeFallback = "1"
    Invoke-ReleaseEvidenceWorkflowInputValidation @case
  }

  if (-not $Quiet) {
    Write-Host "Release evidence workflow input validation OK"
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Invoke-ReleaseEvidenceWorkflowInputValidation `
  -SourceRunId $SourceRunId `
  -BundleArtifactName $BundleArtifactName `
  -BundleFile $BundleFile `
  -IncludeServiceOnly $IncludeServiceOnly `
  -IncludeFallback $IncludeFallback

if (-not $Quiet) {
  Write-Host "Release evidence workflow inputs OK"
}
