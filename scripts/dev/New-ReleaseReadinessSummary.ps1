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

function Get-ReleaseClaimRequirementsSummary {
  param([Parameter(Mandatory = $true)]$ReleaseClaim)

  $requirements = Get-OptionalPropertyValue -Object $ReleaseClaim -Name "requirements"
  return [ordered]@{
    fullMatrixScope = [bool](Get-OptionalPropertyValue -Object $requirements -Name "fullMatrixScope" -DefaultValue $false)
    strictCiRelease = [bool](Get-OptionalPropertyValue -Object $requirements -Name "strictCiRelease" -DefaultValue $false)
    warningClean = [bool](Get-OptionalPropertyValue -Object $requirements -Name "warningClean" -DefaultValue $false)
    coverageComplete = [bool](Get-OptionalPropertyValue -Object $requirements -Name "coverageComplete" -DefaultValue $false)
    nonSyntheticEvidenceRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "nonSyntheticEvidenceRequired" -DefaultValue $false)
    uniqueEvidencePayloadsRequired = [bool](Get-OptionalPropertyValue -Object $requirements -Name "uniqueEvidencePayloadsRequired" -DefaultValue $false)
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
    maxEvidenceAgeDaysRequired = [int](Get-OptionalPropertyValue -Object $requirements -Name "maxEvidenceAgeDaysRequired" -DefaultValue 0)
    minimumUptimeHoursRequired = [int](Get-OptionalPropertyValue -Object $requirements -Name "minimumUptimeHoursRequired" -DefaultValue 0)
  }
}

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
    generatedAtUtc = [string](Get-OptionalPropertyValue -Object $Readiness -Name "generatedAtUtc" -DefaultValue "")
    ready = [bool]$Readiness.ready
    maxEvidenceAgeDays = [int](Get-OptionalPropertyValue -Object $Readiness -Name "maxEvidenceAgeDays" -DefaultValue 0)
    releaseClaim = [ordered]@{
      finalFullMatrixReleaseClaim = [bool]$Readiness.releaseClaim.finalFullMatrixReleaseClaim
      kind = [string]$Readiness.releaseClaim.kind
      strictCiRelease = [bool]$Readiness.releaseClaim.strictCiRelease
      scope = [string]$Readiness.releaseClaim.scope
      requirements = Get-ReleaseClaimRequirementsSummary -ReleaseClaim $Readiness.releaseClaim
      note = [string]$Readiness.releaseClaim.note
    }
    supportScope = [ordered]@{
      kind = [string]$Readiness.supportScope.kind
      proofLevel = [string]$Readiness.supportScope.proofLevel
      fullMatrix = [bool]$Readiness.supportScope.fullMatrix
      selectedTargetCount = [int]$Readiness.supportScope.selectedTargetCount
      matrixTargetCount = [int]$Readiness.supportScope.matrixTargetCount
      includeServiceOnly = [bool](Get-OptionalPropertyValue -Object $Readiness.supportScope -Name "includeServiceOnly" -DefaultValue $false)
      includeFallback = [bool](Get-OptionalPropertyValue -Object $Readiness.supportScope -Name "includeFallback" -DefaultValue $false)
      strictNextJsModeServiceProxyClaim = [bool](Get-OptionalPropertyValue -Object $Readiness.supportScope -Name "strictNextJsModeServiceProxyClaim" -DefaultValue $false)
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
      includeServiceOnly = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "includeServiceOnly" -DefaultValue $false)
      includeFallback = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "includeFallback" -DefaultValue $false)
      supportClaimValidated = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "supportClaimValidated" -DefaultValue $false)
      requireBothNextJsModes = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "requireBothNextJsModes" -DefaultValue $false)
      requireDeclaredServiceManagers = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "requireDeclaredServiceManagers" -DefaultValue $false)
      requireDeclaredReverseProxies = [bool](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "requireDeclaredReverseProxies" -DefaultValue $false)
      workflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "workflowCapableEvidenceCount" -DefaultValue 0)
      localCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue 0)
      requiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $Readiness.bundleSupportScope -Name "requiredMinimumUptimeHours" -DefaultValue 0)
    }
    supportMatrix = [ordered]@{
      sha256 = [string](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "matrixSha256" -DefaultValue "")
      targetCount = [int](Get-OptionalPropertyValue -Object $Readiness.supportScope -Name "matrixTargetCount" -DefaultValue 0)
      requiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $Readiness.supportScope -Name "requiredMinimumUptimeHours" -DefaultValue 0)
      runtimeSupportTiers = [object[]]@(Get-OptionalStringArray -Object $Readiness.bundle -Name "runtimeSupportTiers")
    }
    coverage = [ordered]@{
      expectedCount = [int]$Readiness.coverage.expectedCount
      coveredCount = [int]$Readiness.coverage.coveredCount
      missingCount = [int]$Readiness.coverage.missingCount
      includeServiceOnly = [bool](Get-OptionalPropertyValue -Object $Readiness.coverage -Name "includeServiceOnly" -DefaultValue $false)
      includeFallback = [bool](Get-OptionalPropertyValue -Object $Readiness.coverage -Name "includeFallback" -DefaultValue $false)
      failOnWarningsDuringCollection = [bool](Get-OptionalPropertyValue -Object $Readiness.coverage -Name "failOnWarningsDuringCollection" -DefaultValue $false)
      requiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $Readiness.coverage -Name "requiredMinimumUptimeHours" -DefaultValue 0)
      coveragePercentDisplay = [string]$Readiness.coverage.coveragePercentDisplay
      uniqueEvidenceSha256Count = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "uniqueEvidenceSha256Count" -DefaultValue 0)
      productionRecommendedRuntimeEvidenceCount = [int]$Readiness.bundle.productionRecommendedRuntimeEvidenceCount
      nonProductionRecommendedRuntimeEvidenceCount = [int]$Readiness.bundle.nonProductionRecommendedRuntimeEvidenceCount
      runtimeSupportTiers = [object[]]@(Get-OptionalStringArray -Object $Readiness.bundle -Name "runtimeSupportTiers")
    }
    collectionProvenance = [ordered]@{
      collectionCiEvidenceCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionCiEvidenceCount" -DefaultValue 0)
      collectionCiMissingCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionCiMissingCount" -DefaultValue 0)
      collectionCiSourceMatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionCiSourceMatchCount" -DefaultValue 0)
      collectionCiSourceMismatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionCiSourceMismatchCount" -DefaultValue 0)
      hostEvidenceWorkflowCollectionCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "hostEvidenceWorkflowCollectionCount" -DefaultValue 0)
      hostEvidenceWorkflowMismatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "hostEvidenceWorkflowMismatchCount" -DefaultValue 0)
      collectionWorkflowDispatchMatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionWorkflowDispatchMatchCount" -DefaultValue 0)
      collectionWorkflowDispatchMismatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionWorkflowDispatchMismatchCount" -DefaultValue 0)
      collectionWorkflowDispatchMatrixMismatchCount = [int](Get-OptionalPropertyValue -Object $Readiness.bundle -Name "collectionWorkflowDispatchMatrixMismatchCount" -DefaultValue 0)
    }
    sourceControl = [ordered]@{
      isGitRepository = [bool](Get-OptionalPropertyValue -Object $Readiness.sourceControl -Name "isGitRepository" -DefaultValue $false)
      commitSha = [string]$Readiness.sourceControl.commitSha
      trackedDirty = [bool]$Readiness.sourceControl.trackedDirty
    }
    bundleCi = [ordered]@{
      provider = [string]$Readiness.bundleCi.provider
      workflowName = [string]$Readiness.bundleCi.workflowName
      eventName = [string]$Readiness.bundleCi.eventName
      runId = [string]$Readiness.bundleCi.runId
      runAttempt = [string]$Readiness.bundleCi.runAttempt
      sha = [string](Get-OptionalPropertyValue -Object $Readiness.bundleCi -Name "sha" -DefaultValue "")
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
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    maxEvidenceAgeDays = 30
    bundlePath = "C:\private\release-evidence\support-evidence.zip"
    matrixPath = "C:\private\support-matrix.example.json"
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
        nonSyntheticEvidenceRequired = $true
        uniqueEvidencePayloadsRequired = $true
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
        maxEvidenceAgeDaysRequired = 30
        minimumUptimeHoursRequired = 72
      }
      note = "Ready only for the stated strict CI release scope."
    }
    supportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "strict-ci-release"
      fullMatrix = $true
      selectedTargetCount = 23
      matrixTargetCount = 23
      includeServiceOnly = $true
      includeFallback = $true
      strictNextJsModeServiceProxyClaim = $true
      workflowCapableEvidenceCount = 282
      localCommandOnlyEvidenceCount = 30
      requiredMinimumUptimeHours = 72
    }
    bundleSupportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "hardened-real-host-evidence"
      fullMatrix = $true
      selectedTargetCount = 23
      matrixTargetCount = 23
      includeServiceOnly = $true
      includeFallback = $true
      supportClaimValidated = $true
      requireBothNextJsModes = $true
      requireDeclaredServiceManagers = $true
      requireDeclaredReverseProxies = $true
      workflowCapableEvidenceCount = 282
      localCommandOnlyEvidenceCount = 30
      requiredMinimumUptimeHours = 72
    }
    coverage = [ordered]@{
      expectedCount = 312
      coveredCount = 312
      missingCount = 0
      includeServiceOnly = $true
      includeFallback = $true
      failOnWarningsDuringCollection = $true
      requiredMinimumUptimeHours = 72
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
      matrixSha256 = ("a" * 64)
      uniqueEvidenceSha256Count = 312
      collectionCiEvidenceCount = 282
      collectionCiMissingCount = 0
      collectionCiSourceMatchCount = 282
      collectionCiSourceMismatchCount = 0
      hostEvidenceWorkflowCollectionCount = 282
      hostEvidenceWorkflowMismatchCount = 0
      collectionWorkflowDispatchMatchCount = 282
      collectionWorkflowDispatchMismatchCount = 0
      collectionWorkflowDispatchMatrixMismatchCount = 0
      productionRecommendedRuntimeEvidenceCount = 256
      nonProductionRecommendedRuntimeEvidenceCount = 56
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
    }
    sourceControl = [ordered]@{
      isGitRepository = $true
      commitSha = "0123456789abcdef0123456789abcdef01234567"
      branchName = "main"
      trackedDirty = $false
    }
    bundleCi = [ordered]@{
      provider = "github-actions"
      workflowName = "support-evidence-bundle"
      eventName = "workflow_dispatch"
      runId = "123456789"
      runAttempt = "1"
      sha = "0123456789abcdef0123456789abcdef01234567"
    }
  }

  $fullReadiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $inputJson -Encoding UTF8
  Write-ReleaseReadinessSummary -SourcePath $inputJson -DestinationPath $outputJson -RequireFinalClaim $true

  $summaryText = Get-Content -LiteralPath $outputJson -Raw
  $summary = $summaryText | ConvertFrom-Json
  if (-not $summary.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Release readiness summary self-test failed: final claim was not preserved."
  }
  if ([string]::IsNullOrWhiteSpace([string]$summary.generatedAtUtc)) {
    throw "Release readiness summary self-test failed: generatedAtUtc was not preserved."
  }
  if ($summary.releaseClaim.requirements.fullMatrixScope -ne $true -or $summary.releaseClaim.requirements.coverageComplete -ne $true -or $summary.releaseClaim.requirements.nonSyntheticEvidenceRequired -ne $true -or $summary.releaseClaim.requirements.uniqueEvidencePayloadsRequired -ne $true -or $summary.releaseClaim.requirements.workflowApplicabilityKnown -ne $true -or $summary.releaseClaim.requirements.runtimeSupportMetadataKnown -ne $true -or [int]$summary.releaseClaim.requirements.maxEvidenceAgeDaysRequired -ne 30 -or [int]$summary.releaseClaim.requirements.minimumUptimeHoursRequired -ne 72) {
    throw "Release readiness summary self-test failed: final claim requirements were not preserved."
  }
  if ([int]$summary.maxEvidenceAgeDays -ne 30) {
    throw "Release readiness summary self-test failed: max evidence age days was not preserved."
  }

  $legacyInputJson = Join-Path $selfTestRoot "legacy-release-readiness.json"
  $legacyOutputJson = Join-Path $selfTestRoot "legacy-release-readiness-summary.json"
  $legacyReadiness = $fullReadiness | ConvertTo-Json -Depth 12 | ConvertFrom-Json
  $legacyReadiness.releaseClaim.PSObject.Properties.Remove("requirements")
  $legacyReadiness.bundle.PSObject.Properties.Remove("matrixSha256")
  $legacyReadiness.bundle.PSObject.Properties.Remove("runtimeSupportTiers")
  $legacyReadiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $legacyInputJson -Encoding UTF8
  Write-ReleaseReadinessSummary -SourcePath $legacyInputJson -DestinationPath $legacyOutputJson -RequireFinalClaim $false
  $legacySummary = Get-Content -LiteralPath $legacyOutputJson -Raw | ConvertFrom-Json
  if ($legacySummary.releaseClaim.requirements.fullMatrixScope -ne $false -or
    $legacySummary.releaseClaim.requirements.coverageComplete -ne $false -or
    $legacySummary.releaseClaim.requirements.nonSyntheticEvidenceRequired -ne $false -or
    $legacySummary.releaseClaim.requirements.uniqueEvidencePayloadsRequired -ne $false -or
    $legacySummary.releaseClaim.requirements.workflowApplicabilityKnown -ne $false -or
    $legacySummary.releaseClaim.requirements.runtimeSupportMetadataKnown -ne $false -or
    [int]$legacySummary.releaseClaim.requirements.maxEvidenceAgeDaysRequired -ne 0 -or
    [int]$legacySummary.releaseClaim.requirements.minimumUptimeHoursRequired -ne 0) {
    throw "Release readiness summary self-test failed: legacy missing requirements were not safely defaulted."
  }
  $legacyRuntimeSupportTiers = @(Get-OptionalStringArray -Object $legacySummary.coverage -Name "runtimeSupportTiers")
  if ($legacyRuntimeSupportTiers.Count -ne 0) {
    throw "Release readiness summary self-test failed: legacy missing runtime support tiers were not safely defaulted."
  }
  if ([string]$legacySummary.supportMatrix.sha256 -ne "") {
    throw "Release readiness summary self-test failed: legacy missing support matrix SHA256 was not safely defaulted."
  }
  if ([int]$legacySummary.supportMatrix.targetCount -ne 23 -or [int]$legacySummary.supportMatrix.requiredMinimumUptimeHours -ne 72 -or @($legacySummary.supportMatrix.runtimeSupportTiers).Count -ne 0) {
    throw "Release readiness summary self-test failed: legacy support matrix contract fields were not preserved/defaulted safely."
  }

  if ([int]$summary.coverage.expectedCount -ne 312 -or [int]$summary.coverage.coveredCount -ne 312 -or [int]$summary.coverage.missingCount -ne 0) {
    throw "Release readiness summary self-test failed: aggregate coverage counts were not preserved."
  }
  if ([int]$summary.coverage.uniqueEvidenceSha256Count -ne 312) {
    throw "Release readiness summary self-test failed: unique evidence SHA256 count was not preserved."
  }
  if ([int]$summary.coverage.productionRecommendedRuntimeEvidenceCount -ne 256 -or [int]$summary.coverage.nonProductionRecommendedRuntimeEvidenceCount -ne 56) {
    throw "Release readiness summary self-test failed: runtime evidence counts were not preserved."
  }
  if ($summary.coverage.failOnWarningsDuringCollection -ne $true -or [int]$summary.coverage.requiredMinimumUptimeHours -ne 72) {
    throw "Release readiness summary self-test failed: coverage warning and uptime requirements were not preserved."
  }
  if ($summary.supportScope.includeServiceOnly -ne $true -or $summary.supportScope.includeFallback -ne $true -or $summary.bundleSupportScope.includeServiceOnly -ne $true -or $summary.bundleSupportScope.includeFallback -ne $true -or $summary.coverage.includeServiceOnly -ne $true -or $summary.coverage.includeFallback -ne $true) {
    throw "Release readiness summary self-test failed: service-only/fallback scope flags were not preserved."
  }
  if ([int]$summary.bundleSupportScope.requiredMinimumUptimeHours -ne 72) {
    throw "Release readiness summary self-test failed: bundle support scope required uptime was not preserved."
  }
  if ([int]$summary.bundleSupportScope.workflowCapableEvidenceCount -ne 282 -or [int]$summary.bundleSupportScope.localCommandOnlyEvidenceCount -ne 30) {
    throw "Release readiness summary self-test failed: bundle support scope workflow/local evidence counts were not preserved."
  }
  if ($summary.supportScope.strictNextJsModeServiceProxyClaim -ne $true -or
    $summary.bundleSupportScope.supportClaimValidated -ne $true -or
    $summary.bundleSupportScope.requireBothNextJsModes -ne $true -or
    $summary.bundleSupportScope.requireDeclaredServiceManagers -ne $true -or
    $summary.bundleSupportScope.requireDeclaredReverseProxies -ne $true) {
    throw "Release readiness summary self-test failed: strict support claim flags were not preserved."
  }
  if ([int]$summary.collectionProvenance.collectionCiEvidenceCount -ne 282 -or
    [int]$summary.collectionProvenance.collectionCiMissingCount -ne 0 -or
    [int]$summary.collectionProvenance.collectionCiSourceMatchCount -ne 282 -or
    [int]$summary.collectionProvenance.collectionCiSourceMismatchCount -ne 0 -or
    [int]$summary.collectionProvenance.hostEvidenceWorkflowCollectionCount -ne 282 -or
    [int]$summary.collectionProvenance.hostEvidenceWorkflowMismatchCount -ne 0 -or
    [int]$summary.collectionProvenance.collectionWorkflowDispatchMatchCount -ne 282 -or
    [int]$summary.collectionProvenance.collectionWorkflowDispatchMismatchCount -ne 0 -or
    [int]$summary.collectionProvenance.collectionWorkflowDispatchMatrixMismatchCount -ne 0) {
    throw "Release readiness summary self-test failed: collection provenance aggregate counts were not preserved."
  }
  if ([string]$summary.supportMatrix.sha256 -ne ("a" * 64)) {
    throw "Release readiness summary self-test failed: support matrix SHA256 was not preserved."
  }
  if ([int]$summary.supportMatrix.targetCount -ne 23 -or [int]$summary.supportMatrix.requiredMinimumUptimeHours -ne 72) {
    throw "Release readiness summary self-test failed: support matrix target count and uptime contract were not preserved."
  }
  if (@($summary.coverage.runtimeSupportTiers).Count -ne 3 -or
    -not (@($summary.coverage.runtimeSupportTiers) -contains "community-package") -or
    -not (@($summary.coverage.runtimeSupportTiers) -contains "experimental") -or
    -not (@($summary.coverage.runtimeSupportTiers) -contains "tier-1")) {
    throw "Release readiness summary self-test failed: runtime support tiers were not preserved."
  }
  if (@($summary.supportMatrix.runtimeSupportTiers).Count -ne 3 -or
    -not (@($summary.supportMatrix.runtimeSupportTiers) -contains "community-package") -or
    -not (@($summary.supportMatrix.runtimeSupportTiers) -contains "experimental") -or
    -not (@($summary.supportMatrix.runtimeSupportTiers) -contains "tier-1")) {
    throw "Release readiness summary self-test failed: support matrix runtime support tiers were not preserved."
  }
  if ($summary.sourceControl.isGitRepository -ne $true -or [string]$summary.sourceControl.commitSha -ne "0123456789abcdef0123456789abcdef01234567" -or [string]$summary.bundleCi.workflowName -ne "support-evidence-bundle" -or [string]$summary.bundleCi.sha -ne "0123456789abcdef0123456789abcdef01234567") {
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
