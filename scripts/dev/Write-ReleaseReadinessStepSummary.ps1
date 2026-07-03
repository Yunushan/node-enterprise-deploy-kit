param(
  [string]$InputPath = "release-readiness-summary.json",
  [string]$OutputPath = $env:GITHUB_STEP_SUMMARY,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Get-SummaryLines {
  param([Parameter(Mandatory = $true)]$Summary)

  if (-not [bool]$Summary.ready) {
    throw "Release readiness summary is not ready."
  }
  if (-not [bool]$Summary.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Release readiness summary did not prove finalFullMatrixReleaseClaim."
  }

  return @(
    "## Release Evidence Gate",
    "",
    "- Final full-matrix claim: $($Summary.releaseClaim.finalFullMatrixReleaseClaim)",
    "- Release claim: $($Summary.releaseClaim.kind)",
    "- Review scope: $($Summary.supportScope.kind)",
    "- Proof level: $($Summary.supportScope.proofLevel)",
    "- Source commit: $($Summary.sourceControl.commitSha)",
    "- Source tracked dirty: $($Summary.sourceControl.trackedDirty)",
    "- Bundle CI workflow: $($Summary.bundleCi.workflowName)",
    "- Bundle CI run: $($Summary.bundleCi.runId)",
    "- Coverage: $($Summary.coverage.coveragePercentDisplay)",
    "- Targets: $($Summary.supportScope.selectedTargetCount) of $($Summary.supportScope.matrixTargetCount)"
  )
}

function Write-ReleaseReadinessStepSummary {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [string]$DestinationPath,
    [switch]$SuppressMissingDestinationMessage
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Release readiness summary input was not found: $SourcePath"
  }

  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    if (-not $Quiet -and -not $SuppressMissingDestinationMessage) {
      Write-Host "GITHUB_STEP_SUMMARY is not set; release readiness step summary was not written."
    }
    return
  }

  $summary = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json
  $lines = Get-SummaryLines -Summary $summary
  $lines | Add-Content -LiteralPath $DestinationPath -Encoding UTF8
}

function Invoke-SelfTest {
  Write-Host ""
  Write-Host "==> Release readiness step summary"

  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-readiness-step-summary-selftest-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null

  $inputJson = Join-Path $selfTestRoot "release-readiness-summary.json"
  $outputMarkdown = Join-Path $selfTestRoot "github-step-summary.md"
  $summary = [ordered]@{
    schemaVersion = 1
    ready = $true
    bundlePath = "C:\private\release-evidence\support-evidence.zip"
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
    coverage = [ordered]@{
      expectedCount = 312
      coveredCount = 312
      missingCount = 0
      coveragePercentDisplay = "100.00%"
      covered = @(
        [ordered]@{
          collectionCommand = "redacted collection command"
          workflowDispatchCommand = "gh workflow run host-evidence.yml --ref private"
        }
      )
    }
    sourceControl = [ordered]@{
      commitSha = "0123456789abcdef"
      trackedDirty = $false
      branchName = "private/customer-branch"
    }
    bundleCi = [ordered]@{
      provider = "github-actions"
      workflowName = "host-evidence"
      eventName = "workflow_dispatch"
      runId = "123456789"
      runAttempt = "1"
    }
  }

  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputJson -Encoding UTF8
  Write-ReleaseReadinessStepSummary -SourcePath $inputJson -DestinationPath $outputMarkdown

  $output = Get-Content -LiteralPath $outputMarkdown -Raw
  foreach ($expected in @(
      "## Release Evidence Gate",
      "- Final full-matrix claim: True",
      "- Release claim: strict-ci-full-matrix",
      "- Review scope: full-matrix",
      "- Proof level: hardened-real-host-evidence",
      "- Source commit: 0123456789abcdef",
      "- Source tracked dirty: False",
      "- Bundle CI workflow: host-evidence",
      "- Bundle CI run: 123456789",
      "- Coverage: 100.00%",
      "- Targets: 23 of 23"
    )) {
    if (-not $output.Contains($expected)) {
      throw "Release readiness step summary self-test failed: missing '$expected'."
    }
  }

  foreach ($blocked in @(
      "bundlePath",
      "collectionCommand",
      "workflowDispatchCommand",
      "redacted collection command",
      "gh workflow run host-evidence.yml",
      "private/customer-branch",
      "C:\private"
    )) {
    if ($output.Contains($blocked)) {
      throw "Release readiness step summary self-test failed: summary leaked '$blocked'."
    }
  }

  $notFinalJson = Join-Path $selfTestRoot "not-final-summary.json"
  $summary.releaseClaim.finalFullMatrixReleaseClaim = $false
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $notFinalJson -Encoding UTF8
  try {
    Write-ReleaseReadinessStepSummary -SourcePath $notFinalJson -DestinationPath (Join-Path $selfTestRoot "not-final.md")
    throw "Release readiness step summary self-test failed: non-final summary unexpectedly passed."
  }
  catch {
    if (-not $_.Exception.Message.Contains("finalFullMatrixReleaseClaim")) {
      throw
    }
  }

  Write-ReleaseReadinessStepSummary -SourcePath $inputJson -DestinationPath "" -SuppressMissingDestinationMessage

  Write-Host "Release readiness step summary OK"
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Write-ReleaseReadinessStepSummary -SourcePath $InputPath -DestinationPath $OutputPath
