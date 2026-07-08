param(
  [string]$RunnerLabels = $env:RUNNER_LABELS,
  [string]$EvidencePath = $env:EVIDENCE_PATH,
  [string]$ArtifactPath = $env:ARTIFACT_PATH,
  [string]$MatrixPath = $env:MATRIX_PATH,
  [string]$OutputDirectory = $env:OUTPUT_DIRECTORY,
  [string]$BundleName = $env:BUNDLE_NAME,
  [string]$BundleArtifactName = $env:BUNDLE_ARTIFACT_NAME,
  [string]$UploadPrivateBundle = $env:UPLOAD_PRIVATE_BUNDLE,
  [string]$IncludeServiceOnly = $env:INCLUDE_SERVICE_ONLY,
  [string]$IncludeFallback = $env:INCLUDE_FALLBACK,
  [string]$StrictCiRelease = $env:STRICT_CI_RELEASE,
  [string]$RequireFinalFullMatrixReleaseClaim = $env:REQUIRE_FINAL_FULL_MATRIX_RELEASE_CLAIM,
  [string]$AllowLocalCollection = $env:ALLOW_LOCAL_COLLECTION,
  [string]$Force = $env:FORCE,
  [string]$UploadRetentionDays = $env:UPLOAD_RETENTION_DAYS,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Assert-WorkflowBoolean {
  param(
    [string]$Value,
    [string]$DisplayName
  )

  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notin @("true", "false")) {
    throw "$DisplayName must be true or false."
  }
}

function Assert-SafeRelativePath {
  param(
    [string]$Value,
    [string]$DisplayName,
    [switch]$AllowEmpty
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    if ($AllowEmpty) { return }
    throw "$DisplayName is required and must be a relative path inside the repository workspace."
  }

  $pathText = $Value.Trim()
  if ($pathText.Length -gt 240) {
    throw "$DisplayName must be 240 characters or less."
  }
  if ($pathText -match '[\x00-\x1F\x7F:*?"<>|]') {
    throw "$DisplayName must not contain control characters, drive letters, wildcards, or shell metacharacters."
  }
  if ($pathText -match '^[A-Za-z]:[\\/]' -or $pathText -match '^[\\/]' -or $pathText -match '^\\\\' -or $pathText -match '^//') {
    throw "$DisplayName must be a relative path inside the repository workspace."
  }

  $normalizedPath = $pathText.Replace('\', '/')
  if ($normalizedPath -match '(^|/)\.\.(/|$)' -or $normalizedPath -match '/{2,}' -or $normalizedPath.EndsWith('/')) {
    throw "$DisplayName must not contain parent traversal, empty path segments, or a trailing slash."
  }
}

function Assert-SafeRelativeJsonPath {
  param(
    [string]$Value,
    [string]$DisplayName
  )

  Assert-SafeRelativePath -Value $Value -DisplayName $DisplayName
  $normalizedPath = $Value.Trim().Replace('\', '/')
  if ($normalizedPath -notmatch '\.json$') {
    throw "$DisplayName must be a relative .json path inside the repository workspace."
  }
}

function Assert-GitTrackedFile {
  param(
    [string]$Value,
    [string]$DisplayName
  )

  $normalizedPath = $Value.Trim().Replace('\', '/')
  $trackedPaths = @(& git -C $RepoRoot ls-files -- $normalizedPath)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify that $DisplayName is tracked by git."
  }

  $trackedMatch = @(
    $trackedPaths | Where-Object {
      [string]::Equals([string]$_, $normalizedPath, [StringComparison]::OrdinalIgnoreCase)
    }
  )
  if ($trackedMatch.Count -eq 0) {
    throw "$DisplayName must reference a tracked repository file."
  }
}

function Assert-SafeSimpleName {
  param(
    [string]$Value,
    [string]$DisplayName,
    [switch]$RejectZipExtension
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$DisplayName is required."
  }
  $name = $Value.Trim()
  if ($name.Length -gt 100) {
    throw "$DisplayName must be 100 characters or less."
  }
  if ($name -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$DisplayName must contain only letters, numbers, dot, underscore, or dash."
  }
  if ($name -in @(".", "..")) {
    throw "$DisplayName must not be '.' or '..'."
  }
  if ($RejectZipExtension -and $name.ToLowerInvariant().EndsWith(".zip")) {
    throw "$DisplayName must be a file stem without the .zip extension."
  }
}

function Assert-SelfHostedRunnerLabels {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "runner_labels is required."
  }
  $rawLabels = $Value.Trim()
  if (-not $rawLabels.StartsWith("[")) {
    throw "runner_labels must be a JSON array containing self-hosted."
  }

  try {
    $labels = @($rawLabels | ConvertFrom-Json)
  } catch {
    throw "runner_labels must be a valid JSON array containing self-hosted."
  }
  if ($labels.Count -eq 0) {
    throw "runner_labels must include self-hosted."
  }

  $normalizedLabels = @()
  foreach ($label in $labels) {
    $labelText = ([string]$label).Trim()
    if ($labelText -notmatch '^[A-Za-z0-9._-]+$') {
      throw "runner_labels values must contain only letters, numbers, dot, underscore, or dash."
    }
    $normalizedLabels += $labelText.ToLowerInvariant()
  }

  $hostedLabelPatterns = @(
    '^ubuntu-(latest|\d{2}\.\d{2}.*)$',
    '^windows-(latest|\d{4}.*)$',
    '^macos-(latest|\d+.*)$'
  )
  foreach ($label in $normalizedLabels) {
    foreach ($hostedLabelPattern in $hostedLabelPatterns) {
      if ($label -match $hostedLabelPattern) {
        throw "runner_labels must not use GitHub-hosted runner labels for private support evidence bundling."
      }
    }
  }

  if ($normalizedLabels -notcontains "self-hosted") {
    throw "runner_labels must include self-hosted for private support evidence bundling."
  }
}

function Invoke-SupportEvidenceBundleWorkflowInputValidation {
  param(
    [string]$RunnerLabels,
    [string]$EvidencePath,
    [string]$ArtifactPath,
    [string]$MatrixPath,
    [string]$OutputDirectory,
    [string]$BundleName,
    [string]$BundleArtifactName,
    [string]$UploadPrivateBundle,
    [string]$IncludeServiceOnly,
    [string]$IncludeFallback,
    [string]$StrictCiRelease,
    [string]$RequireFinalFullMatrixReleaseClaim,
    [string]$AllowLocalCollection,
    [string]$Force,
    [string]$UploadRetentionDays
  )

  Assert-SelfHostedRunnerLabels -Value $RunnerLabels
  Assert-SafeRelativePath -Value $EvidencePath -DisplayName "evidence_path"
  Assert-SafeRelativePath -Value $ArtifactPath -DisplayName "artifact_path" -AllowEmpty
  Assert-SafeRelativeJsonPath -Value $MatrixPath -DisplayName "matrix_path"
  Assert-GitTrackedFile -Value $MatrixPath -DisplayName "matrix_path"
  Assert-SafeRelativePath -Value $OutputDirectory -DisplayName "output_directory"
  Assert-SafeSimpleName -Value $BundleName -DisplayName "bundle_name" -RejectZipExtension
  Assert-SafeSimpleName -Value $BundleArtifactName -DisplayName "bundle_artifact_name"

  Assert-WorkflowBoolean -Value $UploadPrivateBundle -DisplayName "upload_private_bundle"
  Assert-WorkflowBoolean -Value $IncludeServiceOnly -DisplayName "include_service_only"
  Assert-WorkflowBoolean -Value $IncludeFallback -DisplayName "include_fallback"
  Assert-WorkflowBoolean -Value $StrictCiRelease -DisplayName "strict_ci_release"
  Assert-WorkflowBoolean -Value $RequireFinalFullMatrixReleaseClaim -DisplayName "require_final_full_matrix_release_claim"
  Assert-WorkflowBoolean -Value $AllowLocalCollection -DisplayName "allow_local_collection"
  Assert-WorkflowBoolean -Value $Force -DisplayName "force"

  if ($RequireFinalFullMatrixReleaseClaim -eq "true" -and $StrictCiRelease -ne "true") {
    throw "require_final_full_matrix_release_claim requires strict_ci_release=true."
  }
  if ($RequireFinalFullMatrixReleaseClaim -eq "true" -and ($IncludeServiceOnly -ne "true" -or $IncludeFallback -ne "true")) {
    throw "require_final_full_matrix_release_claim requires include_service_only=true and include_fallback=true."
  }

  if ($UploadRetentionDays -notmatch '^\d+$') {
    throw "upload_retention_days must be an integer from 1 to 90."
  }
  $retentionDays = [int]$UploadRetentionDays
  if ($retentionDays -lt 1 -or $retentionDays -gt 90) {
    throw "upload_retention_days must be an integer from 1 to 90."
  }
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
  } catch {
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
  Write-Host "==> Support evidence bundle workflow input validation"

  $base = @{
    RunnerLabels = '["self-hosted","release-evidence-builder"]'
    EvidencePath = "evidence"
    ArtifactPath = "evidence-downloads"
    MatrixPath = "config/support-matrix.example.json"
    OutputDirectory = "release-evidence"
    BundleName = "support-evidence"
    BundleArtifactName = "support-evidence"
    UploadPrivateBundle = "false"
    IncludeServiceOnly = "true"
    IncludeFallback = "true"
    StrictCiRelease = "true"
    RequireFinalFullMatrixReleaseClaim = "true"
    AllowLocalCollection = "false"
    Force = "false"
    UploadRetentionDays = "7"
  }
  Invoke-SupportEvidenceBundleWorkflowInputValidation @base

  $withoutArtifactPath = $base.Clone()
  $withoutArtifactPath.ArtifactPath = ""
  Invoke-SupportEvidenceBundleWorkflowInputValidation @withoutArtifactPath

  Invoke-ExpectValidationFailure -Name "hosted runner label" -ExpectedMessage "runner_labels must not use GitHub-hosted runner labels" -Action {
    $case = $base.Clone()
    $case.RunnerLabels = '["self-hosted","ubuntu-latest"]'
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "missing self hosted" -ExpectedMessage "runner_labels must include self-hosted" -Action {
    $case = $base.Clone()
    $case.RunnerLabels = '["release-evidence-builder"]'
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "missing evidence path" -ExpectedMessage "evidence_path is required and must be a relative path" -Action {
    $case = $base.Clone()
    $case.EvidencePath = ""
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "unsafe evidence path" -ExpectedMessage "evidence_path must not contain parent traversal" -Action {
    $case = $base.Clone()
    $case.EvidencePath = "../evidence"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "unsafe artifact path" -ExpectedMessage "artifact_path must not contain parent traversal" -Action {
    $case = $base.Clone()
    $case.ArtifactPath = "../evidence-downloads"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "missing matrix path" -ExpectedMessage "matrix_path is required and must be a relative path" -Action {
    $case = $base.Clone()
    $case.MatrixPath = ""
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "unsafe matrix path" -ExpectedMessage "matrix_path must not contain parent traversal" -Action {
    $case = $base.Clone()
    $case.MatrixPath = "../config/support-matrix.example.json"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "non-json matrix path" -ExpectedMessage "matrix_path must be a relative .json path" -Action {
    $case = $base.Clone()
    $case.MatrixPath = "config/support-matrix.example.txt"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "untracked matrix path" -ExpectedMessage "matrix_path must reference a tracked repository file" -Action {
    $case = $base.Clone()
    $case.MatrixPath = "config/not-tracked-support-matrix.json"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "absolute output directory" -ExpectedMessage "output_directory must not contain control characters" -Action {
    $case = $base.Clone()
    $case.OutputDirectory = "C:\release-evidence"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "bundle name with extension" -ExpectedMessage "bundle_name must be a file stem" -Action {
    $case = $base.Clone()
    $case.BundleName = "support-evidence.zip"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "bad artifact name" -ExpectedMessage "bundle_artifact_name must contain only" -Action {
    $case = $base.Clone()
    $case.BundleArtifactName = "support evidence"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "bad private upload boolean" -ExpectedMessage "upload_private_bundle must be true or false" -Action {
    $case = $base.Clone()
    $case.UploadPrivateBundle = "yes"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "bad boolean" -ExpectedMessage "include_fallback must be true or false" -Action {
    $case = $base.Clone()
    $case.IncludeFallback = "yes"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "final without strict" -ExpectedMessage "require_final_full_matrix_release_claim requires strict_ci_release=true" -Action {
    $case = $base.Clone()
    $case.StrictCiRelease = "false"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "final without service-only scope" -ExpectedMessage "require_final_full_matrix_release_claim requires include_service_only=true and include_fallback=true" -Action {
    $case = $base.Clone()
    $case.IncludeServiceOnly = "false"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "final without fallback scope" -ExpectedMessage "require_final_full_matrix_release_claim requires include_service_only=true and include_fallback=true" -Action {
    $case = $base.Clone()
    $case.IncludeFallback = "false"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "retention too high" -ExpectedMessage "upload_retention_days must be an integer from 1 to 90" -Action {
    $case = $base.Clone()
    $case.UploadRetentionDays = "120"
    Invoke-SupportEvidenceBundleWorkflowInputValidation @case
  }

  Write-Host "Support evidence bundle workflow input validation OK"
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Invoke-SupportEvidenceBundleWorkflowInputValidation `
  -RunnerLabels $RunnerLabels `
  -EvidencePath $EvidencePath `
  -ArtifactPath $ArtifactPath `
  -MatrixPath $MatrixPath `
  -OutputDirectory $OutputDirectory `
  -BundleName $BundleName `
  -BundleArtifactName $BundleArtifactName `
  -UploadPrivateBundle $UploadPrivateBundle `
  -IncludeServiceOnly $IncludeServiceOnly `
  -IncludeFallback $IncludeFallback `
  -StrictCiRelease $StrictCiRelease `
  -RequireFinalFullMatrixReleaseClaim $RequireFinalFullMatrixReleaseClaim `
  -AllowLocalCollection $AllowLocalCollection `
  -Force $Force `
  -UploadRetentionDays $UploadRetentionDays

if (-not $Quiet) {
  Write-Host "Support evidence bundle workflow inputs OK"
}
