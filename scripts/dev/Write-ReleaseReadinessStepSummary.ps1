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

function Get-OptionalPropertyValue {
  param(
    $Object,
    [Parameter(Mandatory = $true)][string]$Name,
    $DefaultValue = $null
  )

  if ($null -eq $Object) {
    return $DefaultValue
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $DefaultValue
  }

  return $property.Value
}

function Get-OptionalStringArray {
  param(
    $Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $value = Get-OptionalPropertyValue -Object $Object -Name $Name -DefaultValue @()
  if ($null -eq $value) {
    return @()
  }

  $items = @()
  foreach ($item in @($value)) {
    $text = [string]$item
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $items += $text
    }
  }

  return @($items | Sort-Object -Unique)
}

function Get-ReleaseClaimRequirements {
  param([Parameter(Mandatory = $true)]$ReleaseClaim)

  $requirements = Get-OptionalPropertyValue -Object $ReleaseClaim -Name "requirements"
  return [pscustomobject]@{
    fullMatrixScope = [bool](Get-OptionalPropertyValue -Object $requirements -Name "fullMatrixScope" -DefaultValue $false)
    strictCiRelease = [bool](Get-OptionalPropertyValue -Object $requirements -Name "strictCiRelease" -DefaultValue $false)
    warningClean = [bool](Get-OptionalPropertyValue -Object $requirements -Name "warningClean" -DefaultValue $false)
    coverageComplete = [bool](Get-OptionalPropertyValue -Object $requirements -Name "coverageComplete" -DefaultValue $false)
    workflowApplicabilityKnown = [bool](Get-OptionalPropertyValue -Object $requirements -Name "workflowApplicabilityKnown" -DefaultValue $false)
    runtimeSupportMetadataKnown = [bool](Get-OptionalPropertyValue -Object $requirements -Name "runtimeSupportMetadataKnown" -DefaultValue $false)
    sourceCleanRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "sourceCleanRequired" -DefaultValue $false)
    currentCommitRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "currentCommitRequired" -DefaultValue $false)
    ciProvenanceRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "ciProvenanceRequired" -DefaultValue $false)
    collectionCiProvenanceRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "collectionCiProvenanceRequired" -DefaultValue $false)
    collectionSourceCommitRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "collectionSourceCommitRequired" -DefaultValue $false)
    hostEvidenceWorkflowCollectionRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "hostEvidenceWorkflowCollectionRequired" -DefaultValue $false)
    runtimeVersionsRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "runtimeVersionsRequired" -DefaultValue $false)
    collectorSha256Required = [bool](Get-OptionalPropertyValue -Object $requirements -Name "collectorSha256Required" -DefaultValue $false)
    minimumUptimeHoursRequired = [int](Get-OptionalPropertyValue -Object $requirements -Name "minimumUptimeHoursRequired" -DefaultValue 0)
  }
}

function Get-SummaryLines {
  param([Parameter(Mandatory = $true)]$Summary)

  if (-not [bool]$Summary.ready) {
    throw "Release readiness summary is not ready."
  }
  if (-not [bool]$Summary.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Release readiness summary did not prove finalFullMatrixReleaseClaim."
  }

  $requirements = Get-ReleaseClaimRequirements -ReleaseClaim $Summary.releaseClaim
  $workflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $Summary.supportScope -Name "workflowCapableEvidenceCount" -DefaultValue 0)
  $localCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $Summary.supportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue 0)
  $productionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $Summary.coverage -Name "productionRecommendedRuntimeEvidenceCount" -DefaultValue 0)
  $nonProductionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $Summary.coverage -Name "nonProductionRecommendedRuntimeEvidenceCount" -DefaultValue 0)
  $runtimeSupportTiers = @(Get-OptionalStringArray -Object $Summary.coverage -Name "runtimeSupportTiers")
  $runtimeSupportTierDisplay = "none"
  if ($runtimeSupportTiers.Count -gt 0) {
    $runtimeSupportTierDisplay = $runtimeSupportTiers -join ", "
  }
  return @(
    "## Release Evidence Gate",
    "",
    "- Final full-matrix claim: $($Summary.releaseClaim.finalFullMatrixReleaseClaim)",
    "- Release claim: $($Summary.releaseClaim.kind)",
    "- Review scope: $($Summary.supportScope.kind)",
    "- Proof level: $($Summary.supportScope.proofLevel)",
    "- Claim requirements: fullMatrix=$($requirements.fullMatrixScope), strictCi=$($requirements.strictCiRelease), warningClean=$($requirements.warningClean), coverageComplete=$($requirements.coverageComplete), workflowApplicabilityKnown=$($requirements.workflowApplicabilityKnown), runtimeSupportMetadataKnown=$($requirements.runtimeSupportMetadataKnown), minimumUptimeHours=$($requirements.minimumUptimeHoursRequired)",
    "- Strict evidence requirements: sourceClean=$($requirements.sourceCleanRequired), currentCommit=$($requirements.currentCommitRequired), bundleCi=$($requirements.ciProvenanceRequired), collectionCi=$($requirements.collectionCiProvenanceRequired), collectionSourceCommit=$($requirements.collectionSourceCommitRequired), hostEvidenceWorkflow=$($requirements.hostEvidenceWorkflowCollectionRequired), runtimeVersions=$($requirements.runtimeVersionsRequired), collectorSha256=$($requirements.collectorSha256Required)",
    "- Source commit: $($Summary.sourceControl.commitSha)",
    "- Source tracked dirty: $($Summary.sourceControl.trackedDirty)",
    "- Bundle CI workflow: $($Summary.bundleCi.workflowName)",
    "- Bundle CI run: $($Summary.bundleCi.runId)",
    "- Coverage: $($Summary.coverage.coveragePercentDisplay)",
    "- Targets: $($Summary.supportScope.selectedTargetCount) of $($Summary.supportScope.matrixTargetCount)",
    "- Evidence collection paths: workflowCapable=$workflowCapableEvidenceCount, localCommandOnly=$localCommandOnlyEvidenceCount",
    "- Runtime evidence: productionRecommended=$productionRecommendedRuntimeEvidenceCount, nonProductionRecommended=$nonProductionRecommendedRuntimeEvidenceCount",
    "- Runtime support tiers: $runtimeSupportTierDisplay"
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
      requirements = [ordered]@{
        fullMatrixScope = $true
        strictCiRelease = $true
        warningClean = $true
        coverageComplete = $true
        workflowApplicabilityKnown = $true
        runtimeSupportMetadataKnown = $true
        sourceCleanRequired = $true
        currentCommitRequired = $true
        ciProvenanceRequired = $true
        collectionCiProvenanceRequired = $true
        collectionSourceCommitRequired = $true
        hostEvidenceWorkflowCollectionRequired = $true
        runtimeVersionsRequired = $true
        collectorSha256Required = $true
        minimumUptimeHoursRequired = 72
      }
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
      productionRecommendedRuntimeEvidenceCount = 224
      nonProductionRecommendedRuntimeEvidenceCount = 88
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
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

  $legacyInputJson = Join-Path $selfTestRoot "legacy-release-readiness-summary.json"
  $legacyOutputMarkdown = Join-Path $selfTestRoot "legacy-github-step-summary.md"
  $legacySummary = $summary | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $legacySummary.releaseClaim.PSObject.Properties.Remove("requirements")
  $legacySummary.coverage.PSObject.Properties.Remove("runtimeSupportTiers")
  $legacySummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyInputJson -Encoding UTF8
  Write-ReleaseReadinessStepSummary -SourcePath $legacyInputJson -DestinationPath $legacyOutputMarkdown
  $legacyOutput = Get-Content -LiteralPath $legacyOutputMarkdown -Raw
  if (-not $legacyOutput.Contains("- Claim requirements: fullMatrix=False, strictCi=False, warningClean=False, coverageComplete=False, workflowApplicabilityKnown=False, runtimeSupportMetadataKnown=False, minimumUptimeHours=0")) {
    throw "Release readiness step summary self-test failed: legacy missing requirements were not safely rendered."
  }
  if (-not $legacyOutput.Contains("- Runtime support tiers: none")) {
    throw "Release readiness step summary self-test failed: legacy missing runtime support tiers were not safely rendered."
  }

  $output = Get-Content -LiteralPath $outputMarkdown -Raw
  foreach ($expected in @(
      "## Release Evidence Gate",
      "- Final full-matrix claim: True",
      "- Release claim: strict-ci-full-matrix",
      "- Review scope: full-matrix",
      "- Proof level: hardened-real-host-evidence",
      "- Claim requirements: fullMatrix=True, strictCi=True, warningClean=True, coverageComplete=True, workflowApplicabilityKnown=True, runtimeSupportMetadataKnown=True, minimumUptimeHours=72",
      "- Strict evidence requirements: sourceClean=True, currentCommit=True, bundleCi=True, collectionCi=True, collectionSourceCommit=True, hostEvidenceWorkflow=True, runtimeVersions=True, collectorSha256=True",
      "- Source commit: 0123456789abcdef",
      "- Source tracked dirty: False",
      "- Bundle CI workflow: host-evidence",
      "- Bundle CI run: 123456789",
      "- Coverage: 100.00%",
      "- Targets: 23 of 23",
      "- Evidence collection paths: workflowCapable=272, localCommandOnly=40",
      "- Runtime evidence: productionRecommended=224, nonProductionRecommended=88",
      "- Runtime support tiers: community-package, experimental, tier-1"
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
