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

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
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

  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") `
    -SelfTest `
    -Format Json `
    -OutputPath $coverageJson | Out-Null

  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  $scriptArgs = @{
    EvidencePath = [string]$coverage.evidencePath
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
  if (-not (Test-Path -LiteralPath ([string]$result.bundleZip) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: bundle zip was not created."
  }
  if (-not (Test-Path -LiteralPath ([string]$result.coverageMarkdown) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: coverage Markdown was not created."
  }
  if (-not (Test-Path -LiteralPath ([string]$result.readinessJson) -PathType Leaf)) {
    throw "Support evidence release workflow self-test failed: readiness JSON was not created."
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
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
  throw "Evidence path not found after optional import: $EvidencePath"
}

$coverageJson = Join-Path $OutputDirectory "coverage-report.json"
$coverageMarkdown = Join-Path $OutputDirectory "coverage-report.md"
$coverage = $null
Invoke-Step "Support evidence coverage" {
  $script:coverage = Get-CoverageReport -Path $EvidencePath -JsonPath $coverageJson -MarkdownPath $coverageMarkdown
  Write-Host "Coverage expected: $($script:coverage.summary.expectedCount)"
  Write-Host "Coverage covered:  $($script:coverage.summary.coveredCount)"
  Write-Host "Coverage missing:  $($script:coverage.summary.missingCount)"
}

if ([int]$coverage.summary.missingCount -gt 0) {
  throw "Support evidence coverage is incomplete. Review the generated report: $coverageMarkdown"
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
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") @bundleArgs | Out-Null
}

$bundleZip = Join-Path $OutputDirectory "$BundleName.zip"
if (-not (Test-Path -LiteralPath $bundleZip -PathType Leaf)) {
  throw "Expected support evidence bundle was not created: $bundleZip"
}

Invoke-Step "Support evidence bundle verification" {
  & (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -BundlePath $bundleZip | Out-Null
}

$readinessJson = Join-Path $OutputDirectory "release-readiness.json"
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
  & (Join-Path $ScriptDir "Test-ReleaseSupportReadiness.ps1") @readinessArgs | Out-Null
}

$readiness = Get-Content -LiteralPath $readinessJson -Raw | ConvertFrom-Json
$result = [pscustomobject]@{
  ready = [bool]$readiness.ready
  evidencePath = $EvidencePath
  outputDirectory = $OutputDirectory
  coverageJson = $coverageJson
  coverageMarkdown = $coverageMarkdown
  bundleZip = $bundleZip
  readinessJson = $readinessJson
  expectedCoverage = [int]$coverage.summary.expectedCount
  coveredEvidence = [int]$coverage.summary.coveredCount
  missingEvidence = [int]$coverage.summary.missingCount
  targetId = @($TargetId)
  category = @($Category)
  productionRecommendedOnly = [bool]$ProductionRecommendedOnly
  requireProductionRecommendedRuntime = [bool]$RequireProductionRecommendedRuntime
  strictCiRelease = [bool]$StrictCiRelease
}

if ($PassThru) {
  $result
} else {
  Write-Host ""
  Write-Host "Release evidence workflow complete."
  Write-Host "Ready: $($result.ready)"
  Write-Host "Coverage report: $coverageMarkdown"
  Write-Host "Bundle: $bundleZip"
  Write-Host "Readiness: $readinessJson"
}
