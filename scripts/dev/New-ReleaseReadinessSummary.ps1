param(
  [string]$InputPath,
  [string]$OutputPath = "release-readiness-summary.json",
  [switch]$RequireFinalFullMatrixReleaseClaim,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function ConvertTo-ReleaseReadinessSummary {
  param(
    [Parameter(Mandatory = $true)]$Readiness,
    [bool]$RequireFinalClaim
  )

  if (-not [bool]$Readiness.ready) {
    throw "Release readiness input is not ready."
  }
  if ($RequireFinalClaim -and -not [bool]$Readiness.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Release readiness input did not prove finalFullMatrixReleaseClaim."
  }

  return [ordered]@{
    schemaVersion = 1
    ready = [bool]$Readiness.ready
    releaseClaim = [ordered]@{
      finalFullMatrixReleaseClaim = [bool]$Readiness.releaseClaim.finalFullMatrixReleaseClaim
      kind = [string]$Readiness.releaseClaim.kind
      strictCiRelease = [bool]$Readiness.releaseClaim.strictCiRelease
      scope = [string]$Readiness.releaseClaim.scope
      note = [string]$Readiness.releaseClaim.note
    }
    supportScope = [ordered]@{
      kind = [string]$Readiness.supportScope.kind
      proofLevel = [string]$Readiness.supportScope.proofLevel
      fullMatrix = [bool]$Readiness.supportScope.fullMatrix
      selectedTargetCount = [int]$Readiness.supportScope.selectedTargetCount
      matrixTargetCount = [int]$Readiness.supportScope.matrixTargetCount
      workflowCapableEvidenceCount = [int]$Readiness.supportScope.workflowCapableEvidenceCount
      localCommandOnlyEvidenceCount = [int]$Readiness.supportScope.localCommandOnlyEvidenceCount
      requiredMinimumUptimeHours = [int]$Readiness.supportScope.requiredMinimumUptimeHours
    }
    bundleSupportScope = [ordered]@{
      kind = [string]$Readiness.bundleSupportScope.kind
      proofLevel = [string]$Readiness.bundleSupportScope.proofLevel
      fullMatrix = [bool]$Readiness.bundleSupportScope.fullMatrix
      selectedTargetCount = [int]$Readiness.bundleSupportScope.selectedTargetCount
      matrixTargetCount = [int]$Readiness.bundleSupportScope.matrixTargetCount
    }
    coverage = [ordered]@{
      expectedCount = [int]$Readiness.coverage.expectedCount
      coveredCount = [int]$Readiness.coverage.coveredCount
      missingCount = [int]$Readiness.coverage.missingCount
      coveragePercentDisplay = [string]$Readiness.coverage.coveragePercentDisplay
      productionRecommendedRuntimeEvidenceCount = [int]$Readiness.bundle.productionRecommendedRuntimeEvidenceCount
      nonProductionRecommendedRuntimeEvidenceCount = [int]$Readiness.bundle.nonProductionRecommendedRuntimeEvidenceCount
    }
    sourceControl = [ordered]@{
      commitSha = [string]$Readiness.sourceControl.commitSha
      trackedDirty = [bool]$Readiness.sourceControl.trackedDirty
    }
    bundleCi = [ordered]@{
      provider = [string]$Readiness.bundleCi.provider
      workflowName = [string]$Readiness.bundleCi.workflowName
      eventName = [string]$Readiness.bundleCi.eventName
      runId = [string]$Readiness.bundleCi.runId
      runAttempt = [string]$Readiness.bundleCi.runAttempt
    }
  }
}

function Write-ReleaseReadinessSummary {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [bool]$RequireFinalClaim
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Release readiness input was not found: $SourcePath"
  }

  $readiness = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
  $summary = ConvertTo-ReleaseReadinessSummary -Readiness $readiness -RequireFinalClaim $RequireFinalClaim
  $summary |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $DestinationPath -Encoding UTF8
}

function Invoke-SelfTest {
  Write-Host ""
  Write-Host "==> Release readiness summary"

  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-readiness-summary-selftest-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null

  $inputJson = Join-Path $selfTestRoot "release-readiness.json"
  $outputJson = Join-Path $selfTestRoot "release-readiness-summary.json"
  $fullReadiness = [ordered]@{
    schemaVersion = 1
    ready = $true
    bundlePath = "C:\private\release-evidence\support-evidence.zip"
    matrixPath = "C:\private\support-matrix.example.json"
    releaseClaim = [ordered]@{
      finalFullMatrixReleaseClaim = $true
      kind = "strict-ci-full-matrix"
      strictCiRelease = $true
      scope = "full-matrix"
      note = "Ready only for the stated strict CI release scope."
    }
    supportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "hardened-real-host-evidence"
      fullMatrix = $true
      selectedTargetCount = 23
      matrixTargetCount = 23
      workflowCapableEvidenceCount = 272
      localCommandOnlyEvidenceCount = 40
      requiredMinimumUptimeHours = 72
    }
    bundleSupportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "hardened-real-host-evidence"
      fullMatrix = $true
      selectedTargetCount = 23
      matrixTargetCount = 23
    }
    coverage = [ordered]@{
      expectedCount = 312
      coveredCount = 312
      missingCount = 0
      coveragePercentDisplay = "100.00%"
      covered = @(
        [ordered]@{
          evidenceFile = "private-host.json"
          collectionCommand = "redacted collection command"
          workflowDispatchCommand = "gh workflow run host-evidence.yml --ref private"
        }
      )
      missing = @(
        [ordered]@{
          evidenceFile = "missing-private-host.json"
          collectionCommand = "missing redacted command"
          workflowDispatchCommand = "missing gh workflow run"
        }
      )
    }
    bundle = [ordered]@{
      productionRecommendedRuntimeEvidenceCount = 224
      nonProductionRecommendedRuntimeEvidenceCount = 88
    }
    sourceControl = [ordered]@{
      commitSha = "0123456789abcdef"
      branchName = "main"
      trackedDirty = $false
    }
    bundleCi = [ordered]@{
      provider = "github-actions"
      workflowName = "host-evidence"
      eventName = "workflow_dispatch"
      runId = "123456789"
      runAttempt = "1"
    }
  }

  $fullReadiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $inputJson -Encoding UTF8
  Write-ReleaseReadinessSummary -SourcePath $inputJson -DestinationPath $outputJson -RequireFinalClaim $true

  $summaryText = Get-Content -LiteralPath $outputJson -Raw
  $summary = $summaryText | ConvertFrom-Json
  if (-not $summary.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Release readiness summary self-test failed: final claim was not preserved."
  }
  if ([int]$summary.coverage.expectedCount -ne 312 -or [int]$summary.coverage.coveredCount -ne 312 -or [int]$summary.coverage.missingCount -ne 0) {
    throw "Release readiness summary self-test failed: aggregate coverage counts were not preserved."
  }
  if ([int]$summary.coverage.productionRecommendedRuntimeEvidenceCount -ne 224 -or [int]$summary.coverage.nonProductionRecommendedRuntimeEvidenceCount -ne 88) {
    throw "Release readiness summary self-test failed: runtime evidence counts were not preserved."
  }
  if ([string]$summary.sourceControl.commitSha -ne "0123456789abcdef" -or [string]$summary.bundleCi.workflowName -ne "host-evidence") {
    throw "Release readiness summary self-test failed: safe provenance was not preserved."
  }
  if ($summary.sourceControl.PSObject.Properties["branchName"]) {
    throw "Release readiness summary self-test failed: branchName should not be included in the redacted summary."
  }

  foreach ($blocked in @(
      '"bundlePath"',
      '"matrixPath"',
      '"branchName"',
      '"collectionCommand"',
      '"workflowDispatchCommand"',
      '"covered"',
      '"missing"',
      'C:\\private',
      'redacted collection command',
      'gh workflow run host-evidence.yml'
    )) {
    if ($summaryText.Contains($blocked)) {
      throw "Release readiness summary self-test failed: redacted summary leaked '$blocked'."
    }
  }

  $notFinalJson = Join-Path $selfTestRoot "not-final-readiness.json"
  $notFinalOutput = Join-Path $selfTestRoot "not-final-summary.json"
  $fullReadiness.releaseClaim.finalFullMatrixReleaseClaim = $false
  $fullReadiness.releaseClaim.kind = "strict-ci-filtered"
  $fullReadiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $notFinalJson -Encoding UTF8

  try {
    Write-ReleaseReadinessSummary -SourcePath $notFinalJson -DestinationPath $notFinalOutput -RequireFinalClaim $true
    throw "Release readiness summary self-test failed: non-final readiness unexpectedly passed -RequireFinalFullMatrixReleaseClaim."
  }
  catch {
    if (-not $_.Exception.Message.Contains("finalFullMatrixReleaseClaim")) {
      throw
    }
  }

  Write-Host "Release readiness summary OK"
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
  throw "-InputPath is required unless -SelfTest is used."
}

Write-ReleaseReadinessSummary `
  -SourcePath $InputPath `
  -DestinationPath $OutputPath `
  -RequireFinalClaim ([bool]$RequireFinalFullMatrixReleaseClaim)

Write-Host "Release readiness summary written: $OutputPath"
