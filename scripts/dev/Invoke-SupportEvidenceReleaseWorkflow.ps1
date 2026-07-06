param(
  [string]$ArtifactPath = "",
  [string]$EvidencePath = ".\evidence",
  [string]$MatrixPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [string]$OutputDirectory = ".tmp/support-evidence-release",
  [string]$BundleName = "support-evidence",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$ProductionRecommendedOnly,
  [switch]$RequireProductionRecommendedRuntime,
  [switch]$AllowWarnings,
  [switch]$AllowLocalCollection,
  [switch]$Force,
  [switch]$StrictCiRelease,
  [switch]$RequireFinalFullMatrixReleaseClaim,
  [switch]$PassThru,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot "config\support-matrix.example.json"
}
if (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}
if (-not [string]::IsNullOrWhiteSpace($ArtifactPath) -and -not [System.IO.Path]::IsPathRooted($ArtifactPath)) {
  $ArtifactPath = Join-Path (Get-Location) $ArtifactPath
}
if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
  $OutputDirectory = Join-Path (Get-Location) $OutputDirectory
}

if ($StrictCiRelease -and $AllowWarnings) {
  throw "-StrictCiRelease cannot be combined with -AllowWarnings; final release evidence must be warning-clean."
}

if ($RequireFinalFullMatrixReleaseClaim -and -not $StrictCiRelease) {
  throw "-RequireFinalFullMatrixReleaseClaim requires -StrictCiRelease; final full-matrix signoff must use strict CI release checks."
}

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Format-CoveragePercent {
  param($Value)

  if ($null -eq $Value) { return "n/a" }
  return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.00}%", [double]$Value)
}

function Invoke-Step {
  param(
    [string]$Label,
    [scriptblock]$Action
  )

  Write-Step $Label
  & $Action
}

function New-OutputDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-DisplayPath {
  param(
    [string]$Path,
    [string]$OutsideRepositoryLabel = "outside-repository"
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if ($fullPath.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
  if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
  }

  return $OutsideRepositoryLabel
}

function Resolve-DisplayPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  $pathText = ([string]$Path).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  if ([System.IO.Path]::IsPathRooted($pathText)) {
    return [System.IO.Path]::GetFullPath($pathText)
  }
  if ($pathText -eq ".") {
    return $RepoRoot
  }
  if ($pathText.StartsWith("." + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
    $pathText = $pathText.Substring(2)
  }
  return Join-Path $RepoRoot $pathText
}

function Get-MatrixRequiredMinimumUptimeHours {
  param([string]$Path)

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  try {
    $value = [int]$matrix.requiredMinimumUptimeHours
    if ($value -lt 1) {
      throw "requiredMinimumUptimeHours must be positive."
    }
    return $value
  } catch {
    throw "Support matrix requiredMinimumUptimeHours must be a positive integer."
  }
}

function Add-CommonCoverageSwitches {
  param([hashtable]$Arguments)
  if ($IncludeServiceOnly) { $Arguments["IncludeServiceOnly"] = $true }
  if ($IncludeFallback) { $Arguments["IncludeFallback"] = $true }
  if ($AllowWarnings) { $Arguments["AllowWarnings"] = $true }
}

function Get-CoverageReport {
  param(
    [string]$Path,
    [string]$JsonPath,
    [string]$MarkdownPath
  )

  $coverageArgs = @{
    EvidencePath = $Path
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    ReportOnly = $true
    Format = "Json"
    OutputPath = $JsonPath
  }
  if ($TargetId.Count -gt 0) { $coverageArgs.TargetId = [string[]]$TargetId }
  if ($Category.Count -gt 0) { $coverageArgs.Category = [string[]]$Category }
  if ($ProductionRecommendedOnly) { $coverageArgs.ProductionRecommendedOnly = $true }
  Add-CommonCoverageSwitches -Arguments $coverageArgs
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") @coverageArgs | Out-Null

  $markdownArgs = $coverageArgs.Clone()
  $markdownArgs.Format = "Markdown"
  $markdownArgs.OutputPath = $MarkdownPath
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") @markdownArgs | Out-Null

  return (Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json)
}

function Invoke-SelfTest {
  $selfTestRoot = Join-Path $RepoRoot ".tmp\support-evidence-release-workflow-selftest-$([Guid]::NewGuid().ToString('N'))"
  New-OutputDirectory -Path $selfTestRoot
  $coverageJson = Join-Path $selfTestRoot "generated-coverage.json"

  if ((Format-CoveragePercent 100) -ne "100.00%" -or (Format-CoveragePercent 0) -ne "0.00%" -or (Format-CoveragePercent $null) -ne "n/a") {
    throw "Support evidence release workflow self-test failed: coverage percentage formatter returned unexpected output."
  }

  function Invoke-ExpectStrictReleaseFailure {
    param([scriptblock]$Action)

    $strictFailureSignals = @(
      "Bundle source-control provenance reports tracked dirty files",
      "Bundle source-control commit SHA does not match current repository HEAD",
      "Bundle CI provenance is required",
      "Collection CI provenance is required",
      "Collection CI commit SHA must match",
      "Collection evidence must come from the host-evidence workflow",
      "Runtime version evidence is required",
      "Collector SHA256 evidence is required",
      "Support claim workflow provenance validation failed",
      "does not prove required minimum uptime evidence"
    )

    $failed = $false
    try {
      & $Action *> $null
    } catch {
      $failed = $true
      $message = $_.Exception.Message
      $matchedStrictFailure = @($strictFailureSignals | Where-Object { $message.Contains($_) })
      if ($matchedStrictFailure.Count -eq 0) {
        throw "Support evidence release workflow self-test failed with an unexpected strict CI release error: $message"
      }
    }

    if (-not $failed) {
      throw "Support evidence release workflow self-test failed: -StrictCiRelease unexpectedly passed without strict provenance."
    }
  }

  function Invoke-ExpectReleaseWorkflowFailure {
    param(
      [string]$ExpectedMessage,
      [scriptblock]$Action
    )

    $failed = $false
    try {
      & $Action *> $null
    } catch {
      $failed = $true
      if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
        throw "Support evidence release workflow self-test failed with an unexpected error: $($_.Exception.Message)"
      }
    }

    if (-not $failed) {
      throw "Support evidence release workflow self-test failed: expected failure containing '$ExpectedMessage'."
    }
  }

  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") `
    -SelfTest `
    -Format Json `
    -OutputPath $coverageJson | Out-Null

  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  $scriptArgs = @{
    EvidencePath = Resolve-DisplayPath -Path ([string]$coverage.evidencePath)
    MatrixPath = $MatrixPath
    OutputDirectory = (Join-Path $selfTestRoot "release-output")
    BundleName = "selftest-release-evidence"
    IncludeServiceOnly = $true
    IncludeFallback = $true
    PassThru = $true
  }
  $result = & $PSCommandPath @scriptArgs
  if (-not $result.ready) {
    throw "Support evidence release workflow self-test failed: release workflow was not ready."
  }
  if (-not (Test-Path -LiteralPath (Resolve-DisplayPath -Path ([string]$result.bundleZip)) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: bundle zip was not created."
  }
  if (-not (Test-Path -LiteralPath (Resolve-DisplayPath -Path ([string]$result.coverageMarkdown)) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: coverage Markdown was not created."
  }
  if (-not (Test-Path -LiteralPath (Resolve-DisplayPath -Path ([string]$result.readinessJson)) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: readiness JSON was not created."
  }
  if (-not (Test-Path -LiteralPath (Resolve-DisplayPath -Path ([string]$result.readinessSummaryJson)) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: redacted readiness summary JSON was not created."
  }
  $readiness = Get-Content -LiteralPath (Resolve-DisplayPath -Path ([string]$result.readinessJson)) -Raw | ConvertFrom-Json
  $summaryText = Get-Content -LiteralPath (Resolve-DisplayPath -Path ([string]$result.readinessSummaryJson)) -Raw
  $summary = $summaryText | ConvertFrom-Json
  if ([string]$summary.releaseClaim.kind -ne [string]$readiness.releaseClaim.kind) {
    throw "Support evidence release workflow self-test failed: redacted readiness summary did not preserve the release claim kind."
  }
  foreach ($blockedSummaryText in @("collectionCommand", "workflowDispatchCommand", '"covered"', '"missing"', "bundlePath")) {
    if ($summaryText.Contains($blockedSummaryText)) {
      throw "Support evidence release workflow self-test failed: redacted readiness summary leaked '$blockedSummaryText'."
    }
  }
  $firstReadinessCoverageRow = @($readiness.coverage.covered | Select-Object -First 1)[0]
  if ($null -eq $firstReadinessCoverageRow -or -not ([string]$firstReadinessCoverageRow.validationCommand).Contains("Test-HostEvidence.ps1")) {
    throw "Support evidence release workflow self-test failed: readiness JSON did not preserve row validation commands."
  }
  if (-not ([string]$firstReadinessCoverageRow.collectionCommand)) {
    throw "Support evidence release workflow self-test failed: readiness JSON did not preserve row collection commands."
  }
  if ([string]$result.coveragePercentDisplay -ne "100.00%") {
    throw "Support evidence release workflow self-test failed: release result did not include formatted coverage percent."
  }
  if (-not $result.PSObject.Properties["supportScope"] -or [string]$result.supportScope.kind -ne "full-matrix") {
    throw "Support evidence release workflow self-test failed: release result did not preserve readiness supportScope."
  }
  if (-not $result.PSObject.Properties["bundleSupportScope"] -or [string]$result.bundleSupportScope.kind -ne "full-matrix") {
    throw "Support evidence release workflow self-test failed: release result did not preserve bundleSupportScope."
  }
  if ([string]$result.supportScope.proofLevel -ne "basic-real-host-evidence") {
    throw "Support evidence release workflow self-test failed: release result did not preserve readiness proof level."
  }
  if (-not $result.PSObject.Properties["releaseClaim"] -or [string]$result.releaseClaim.kind -ne "provisional-full-matrix") {
    throw "Support evidence release workflow self-test failed: release result did not preserve readiness releaseClaim metadata."
  }
  if ($result.releaseClaim.finalFullMatrixReleaseClaim -ne $false) {
    throw "Support evidence release workflow self-test failed: provisional release workflow must not report a final full-matrix release claim."
  }

  $filteredArgs = $scriptArgs.Clone()
  $filteredArgs.OutputDirectory = Join-Path $selfTestRoot "filtered-release-output"
  $filteredArgs.BundleName = "selftest-filtered-release-evidence"
  $filteredArgs.TargetId = [string[]]@("ubuntu")
  $filteredResult = & $PSCommandPath @filteredArgs
  if (-not $filteredResult.ready) {
    throw "Support evidence release workflow self-test failed: filtered release workflow was not ready."
  }
  if ([int]$filteredResult.expectedCoverage -le 0 -or [int]$filteredResult.expectedCoverage -ge [int]$result.expectedCoverage) {
    throw "Support evidence release workflow self-test failed: filtered release workflow did not narrow expected coverage."
  }
  $filteredCoverage = Get-Content -LiteralPath (Resolve-DisplayPath -Path ([string]$filteredResult.coverageJson)) -Raw | ConvertFrom-Json
  $filteredCoverageTargets = @($filteredCoverage.selectedTargets)
  if ($filteredCoverageTargets.Count -ne 1 -or [string]$filteredCoverageTargets[0] -ne "ubuntu") {
    throw "Support evidence release workflow self-test failed: filtered coverage report did not stay scoped to ubuntu."
  }
  $filteredReadiness = Get-Content -LiteralPath (Resolve-DisplayPath -Path ([string]$filteredResult.readinessJson)) -Raw | ConvertFrom-Json
  $filteredReadinessTargets = @($filteredReadiness.supportScope.selectedTargets)
  if ($filteredReadinessTargets.Count -ne 1 -or [string]$filteredReadinessTargets[0] -ne "ubuntu") {
    throw "Support evidence release workflow self-test failed: filtered readiness report did not stay scoped to ubuntu."
  }
  $filteredResultTargets = @($filteredResult.supportScope.selectedTargets)
  if ($filteredResultTargets.Count -ne 1 -or [string]$filteredResultTargets[0] -ne "ubuntu") {
    throw "Support evidence release workflow self-test failed: filtered release result did not preserve scoped readiness targets."
  }
  if ([string]$filteredResult.bundleSupportScope.kind -ne "filtered") {
    throw "Support evidence release workflow self-test failed: filtered release result did not preserve the saved bundle scope."
  }
  if ([string]$filteredResult.releaseClaim.kind -ne "provisional-filtered") {
    throw "Support evidence release workflow self-test failed: filtered release result did not preserve the release claim scope."
  }

  $strictAllowWarningsArgs = $scriptArgs.Clone()
  $strictAllowWarningsArgs.OutputDirectory = Join-Path $selfTestRoot "strict-allow-warnings-output"
  $strictAllowWarningsArgs.BundleName = "selftest-strict-allow-warnings-evidence"
  $strictAllowWarningsArgs.TargetId = [string[]]@("ubuntu")
  $strictAllowWarningsArgs.StrictCiRelease = $true
  $strictAllowWarningsArgs.AllowWarnings = $true
  Invoke-ExpectReleaseWorkflowFailure -ExpectedMessage "-StrictCiRelease cannot be combined with -AllowWarnings" -Action {
    & $PSCommandPath @strictAllowWarningsArgs | Out-Null
  }

  $requireFinalArgs = $scriptArgs.Clone()
  $requireFinalArgs.OutputDirectory = Join-Path $selfTestRoot "require-final-output"
  $requireFinalArgs.BundleName = "selftest-require-final-evidence"
  $requireFinalArgs.RequireFinalFullMatrixReleaseClaim = $true
  Invoke-ExpectReleaseWorkflowFailure -ExpectedMessage "-RequireFinalFullMatrixReleaseClaim requires -StrictCiRelease" -Action {
    & $PSCommandPath @requireFinalArgs | Out-Null
  }

  $strictFailureArgs = $scriptArgs.Clone()
  $strictFailureArgs.OutputDirectory = Join-Path $selfTestRoot "strict-release-output"
  $strictFailureArgs.BundleName = "selftest-strict-release-evidence"
  $strictFailureArgs.TargetId = [string[]]@("ubuntu")
  $strictFailureArgs.StrictCiRelease = $true
  Invoke-ExpectStrictReleaseFailure -Action {
    & $PSCommandPath @strictFailureArgs | Out-Null
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $(Get-DisplayPath -Path $MatrixPath)"
}

New-OutputDirectory -Path $OutputDirectory

Invoke-Step "Support matrix" {
  & (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
  Invoke-Step "Import host evidence artifacts" {
    $importArgs = @{
      ArtifactPath = $ArtifactPath
      EvidencePath = $EvidencePath
      MatrixPath = $MatrixPath
      MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    }
    if ($AllowWarnings) { $importArgs.AllowWarnings = $true }
    if ($AllowLocalCollection) { $importArgs.AllowLocalCollection = $true }
    if ($Force) { $importArgs.Force = $true }
    & (Join-Path $ScriptDir "Import-HostEvidenceArtifacts.ps1") @importArgs | Out-Null
  }
}

if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found after optional import: $(Get-DisplayPath -Path $EvidencePath)"
}

$coverageJson = Join-Path $OutputDirectory "coverage-report.json"
$coverageMarkdown = Join-Path $OutputDirectory "coverage-report.md"
$coverage = $null
Invoke-Step "Support evidence coverage" {
  $script:coverage = Get-CoverageReport -Path $EvidencePath -JsonPath $coverageJson -MarkdownPath $coverageMarkdown
  Write-Host "Coverage expected: $($script:coverage.summary.expectedCount)"
  Write-Host "Coverage covered:  $($script:coverage.summary.coveredCount)"
  Write-Host "Coverage missing:  $($script:coverage.summary.missingCount)"
  Write-Host "Coverage percent:  $(Format-CoveragePercent $script:coverage.summary.coveragePercent)"
}

if ([int]$coverage.summary.missingCount -gt 0) {
  throw "Support evidence coverage is incomplete. Review the generated report: $(Get-DisplayPath -Path $coverageMarkdown)"
}

Invoke-Step "Support evidence bundle" {
  $bundleArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    OutputDirectory = $OutputDirectory
    BundleName = $BundleName
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    ValidateSupportClaim = $true
    RequireBothNextJsModes = $true
    RequireDeclaredServiceManagers = $true
    RequireDeclaredReverseProxies = $true
    RequireCoverageComplete = $true
  }
  if ($TargetId.Count -gt 0) { $bundleArgs.TargetId = [string[]]$TargetId }
  if ($Category.Count -gt 0) { $bundleArgs.Category = [string[]]$Category }
  if ($ProductionRecommendedOnly) { $bundleArgs.ProductionRecommendedOnly = $true }
  if ($IncludeServiceOnly) { $bundleArgs.IncludeServiceOnly = $true }
  if ($IncludeFallback) { $bundleArgs.IncludeFallback = $true }
  if ($AllowWarnings) { $bundleArgs.AllowWarnings = $true }
  if ($StrictCiRelease) {
    $bundleArgs.RequireCollectorSha256 = $true
    $bundleArgs.RequireHostEvidenceWorkflowCollection = $true
    $bundleArgs.RequireMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath
  }
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") @bundleArgs | Out-Null
}

$bundleZip = Join-Path $OutputDirectory "$BundleName.zip"
if (-not (Test-Path -LiteralPath $bundleZip -PathType Leaf)) {
  throw "Expected support evidence bundle was not created: $(Get-DisplayPath -Path $bundleZip)"
}

Invoke-Step "Support evidence bundle verification" {
  & (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -BundlePath $bundleZip | Out-Null
}

$readinessJson = Join-Path $OutputDirectory "release-readiness.json"
$readinessSummaryJson = Join-Path $OutputDirectory "release-readiness-summary.json"
Invoke-Step "Release support readiness" {
  $readinessArgs = @{
    BundlePath = $bundleZip
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    Format = "Json"
    OutputPath = $readinessJson
  }
  if ($TargetId.Count -gt 0) { $readinessArgs.TargetId = [string[]]$TargetId }
  if ($Category.Count -gt 0) { $readinessArgs.Category = [string[]]$Category }
  if ($ProductionRecommendedOnly) { $readinessArgs.ProductionRecommendedOnly = $true }
  if ($RequireProductionRecommendedRuntime) { $readinessArgs.RequireProductionRecommendedRuntime = $true }
  if ($IncludeServiceOnly) { $readinessArgs.IncludeServiceOnly = $true }
  if ($IncludeFallback) { $readinessArgs.IncludeFallback = $true }
  if ($AllowWarnings) { $readinessArgs.AllowWarnings = $true }
  if ($StrictCiRelease) { $readinessArgs.StrictCiRelease = $true }
  if ($RequireFinalFullMatrixReleaseClaim) { $readinessArgs.RequireFinalFullMatrixReleaseClaim = $true }
  & (Join-Path $ScriptDir "Test-ReleaseSupportReadiness.ps1") @readinessArgs | Out-Null
}

Invoke-Step "Release readiness summary" {
  $summaryArgs = @{
    InputPath = $readinessJson
    OutputPath = $readinessSummaryJson
  }
  if ($RequireFinalFullMatrixReleaseClaim) { $summaryArgs.RequireFinalFullMatrixReleaseClaim = $true }
  & (Join-Path $ScriptDir "New-ReleaseReadinessSummary.ps1") @summaryArgs | Out-Null
}

$readiness = Get-Content -LiteralPath $readinessJson -Raw | ConvertFrom-Json
$result = [pscustomobject]@{
  ready = [bool]$readiness.ready
  evidencePath = Get-DisplayPath -Path $EvidencePath
  outputDirectory = Get-DisplayPath -Path $OutputDirectory
  coverageJson = Get-DisplayPath -Path $coverageJson
  coverageMarkdown = Get-DisplayPath -Path $coverageMarkdown
  bundleZip = Get-DisplayPath -Path $bundleZip
  readinessJson = Get-DisplayPath -Path $readinessJson
  readinessSummaryJson = Get-DisplayPath -Path $readinessSummaryJson
  expectedCoverage = [int]$coverage.summary.expectedCount
  coveredEvidence = [int]$coverage.summary.coveredCount
  missingEvidence = [int]$coverage.summary.missingCount
  coveragePercent = $coverage.summary.coveragePercent
  coveragePercentDisplay = Format-CoveragePercent $coverage.summary.coveragePercent
  targetId = @($TargetId)
  category = @($Category)
  productionRecommendedOnly = [bool]$ProductionRecommendedOnly
  requireProductionRecommendedRuntime = [bool]$RequireProductionRecommendedRuntime
  strictCiRelease = [bool]$StrictCiRelease
  requireFinalFullMatrixReleaseClaim = [bool]$RequireFinalFullMatrixReleaseClaim
  releaseClaim = $readiness.releaseClaim
  supportScope = $readiness.supportScope
  bundleSupportScope = $readiness.bundleSupportScope
}

if ($PassThru) {
  $result
} else {
  Write-Host ""
  Write-Host "Release evidence workflow complete."
  Write-Host "Ready: $($result.ready)"
  Write-Host "Coverage percent: $($result.coveragePercentDisplay)"
  Write-Host "Release claim: $($result.releaseClaim.kind)"
  Write-Host "Review scope: $($result.supportScope.kind)"
  Write-Host "Review proof level: $($result.supportScope.proofLevel)"
  Write-Host "Review selected targets: $($result.supportScope.selectedTargetCount) of $($result.supportScope.matrixTargetCount)"
  Write-Host "Bundle scope: $($result.bundleSupportScope.kind)"
  Write-Host "Bundle proof level: $($result.bundleSupportScope.proofLevel)"
  Write-Host "Coverage report: $($result.coverageMarkdown)"
  Write-Host "Bundle: $($result.bundleZip)"
  Write-Host "Readiness: $($result.readinessJson)"
  Write-Host "Readiness summary: $($result.readinessSummaryJson)"
}
