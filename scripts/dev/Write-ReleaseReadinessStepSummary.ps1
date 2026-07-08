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

function Get-SummaryLines {
  param([Parameter(Mandatory = $true)]$Summary)

  if (-not [bool](Get-OptionalPropertyValue -Object $Summary -Name "ready" -DefaultValue $false)) {
    throw "Release readiness summary is not ready."
  }
  $releaseClaim = Get-OptionalPropertyValue -Object $Summary -Name "releaseClaim"
  if (-not [bool](Get-OptionalPropertyValue -Object $releaseClaim -Name "finalFullMatrixReleaseClaim" -DefaultValue $false)) {
    throw "Release readiness summary did not prove finalFullMatrixReleaseClaim."
  }

  $requirements = Get-ReleaseClaimRequirements -ReleaseClaim $releaseClaim
  $supportScope = Get-OptionalPropertyValue -Object $Summary -Name "supportScope"
  $bundleSupportScope = Get-OptionalPropertyValue -Object $Summary -Name "bundleSupportScope"
  $coverage = Get-OptionalPropertyValue -Object $Summary -Name "coverage"
  $sourceControl = Get-OptionalPropertyValue -Object $Summary -Name "sourceControl"
  $bundleCi = Get-OptionalPropertyValue -Object $Summary -Name "bundleCi"
  $generatedAtUtc = [string](Get-OptionalPropertyValue -Object $Summary -Name "generatedAtUtc" -DefaultValue "missing")
  $maxEvidenceAgeDays = [int](Get-OptionalPropertyValue -Object $Summary -Name "maxEvidenceAgeDays" -DefaultValue 0)
  $reviewScopeKind = [string](Get-OptionalPropertyValue -Object $supportScope -Name "kind" -DefaultValue "missing")
  $proofLevel = [string](Get-OptionalPropertyValue -Object $supportScope -Name "proofLevel" -DefaultValue "missing")
  $selectedTargetCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "selectedTargetCount" -DefaultValue 0)
  $matrixTargetCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "matrixTargetCount" -DefaultValue 0)
  $workflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "workflowCapableEvidenceCount" -DefaultValue 0)
  $localCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue 0)
  $bundleProofLevel = [string](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "proofLevel" -DefaultValue "missing")
  $bundleRequiredUptimeHours = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "requiredMinimumUptimeHours" -DefaultValue 0)
  $bundleWorkflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "workflowCapableEvidenceCount" -DefaultValue 0)
  $bundleLocalCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue 0)
  $bundleSupportClaimValidated = [bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "supportClaimValidated" -DefaultValue $false)
  $bundleRequireBothNextJsModes = [bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "requireBothNextJsModes" -DefaultValue $false)
  $bundleRequireDeclaredServiceManagers = [bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "requireDeclaredServiceManagers" -DefaultValue $false)
  $bundleRequireDeclaredReverseProxies = [bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "requireDeclaredReverseProxies" -DefaultValue $false)
  $coveragePercentDisplay = [string](Get-OptionalPropertyValue -Object $coverage -Name "coveragePercentDisplay" -DefaultValue "missing")
  $coverageFailOnWarnings = [bool](Get-OptionalPropertyValue -Object $coverage -Name "failOnWarningsDuringCollection" -DefaultValue $false)
  $coverageRequiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $coverage -Name "requiredMinimumUptimeHours" -DefaultValue 0)
  $uniqueEvidenceSha256Count = [int](Get-OptionalPropertyValue -Object $coverage -Name "uniqueEvidenceSha256Count" -DefaultValue 0)
  $productionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "productionRecommendedRuntimeEvidenceCount" -DefaultValue 0)
  $nonProductionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "nonProductionRecommendedRuntimeEvidenceCount" -DefaultValue 0)
  $supportMatrix = Get-OptionalPropertyValue -Object $Summary -Name "supportMatrix"
  $supportMatrixSha256 = [string](Get-OptionalPropertyValue -Object $supportMatrix -Name "sha256" -DefaultValue "missing")
  $supportMatrixTargetCount = [int](Get-OptionalPropertyValue -Object $supportMatrix -Name "targetCount" -DefaultValue 0)
  $supportMatrixRequiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $supportMatrix -Name "requiredMinimumUptimeHours" -DefaultValue 0)
  $supportMatrixRuntimeSupportTiers = @(Get-OptionalStringArray -Object $supportMatrix -Name "runtimeSupportTiers")
  $runtimeSupportTiers = @(Get-OptionalStringArray -Object $coverage -Name "runtimeSupportTiers")
  $collectionProvenance = Get-OptionalPropertyValue -Object $Summary -Name "collectionProvenance"
  $collectionCiEvidenceCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiEvidenceCount" -DefaultValue 0)
  $collectionCiMissingCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiMissingCount" -DefaultValue 0)
  $collectionCiSourceMatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiSourceMatchCount" -DefaultValue 0)
  $collectionCiSourceMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiSourceMismatchCount" -DefaultValue 0)
  $hostEvidenceWorkflowCollectionCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "hostEvidenceWorkflowCollectionCount" -DefaultValue 0)
  $hostEvidenceWorkflowMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "hostEvidenceWorkflowMismatchCount" -DefaultValue 0)
  $collectionWorkflowDispatchMatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMatchCount" -DefaultValue 0)
  $collectionWorkflowDispatchMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMismatchCount" -DefaultValue 0)
  $collectionWorkflowDispatchMatrixMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMatrixMismatchCount" -DefaultValue 0)
  $sourceIsGitRepository = [bool](Get-OptionalPropertyValue -Object $sourceControl -Name "isGitRepository" -DefaultValue $false)
  $sourceCommitSha = [string](Get-OptionalPropertyValue -Object $sourceControl -Name "commitSha" -DefaultValue "missing")
  $sourceTrackedDirty = [bool](Get-OptionalPropertyValue -Object $sourceControl -Name "trackedDirty" -DefaultValue $true)
  $bundleCiWorkflowName = [string](Get-OptionalPropertyValue -Object $bundleCi -Name "workflowName" -DefaultValue "missing")
  $bundleCiRunId = [string](Get-OptionalPropertyValue -Object $bundleCi -Name "runId" -DefaultValue "missing")
  $bundleCiSha = [string](Get-OptionalPropertyValue -Object $bundleCi -Name "sha" -DefaultValue "missing")
  $includeServiceOnly = [bool](Get-OptionalPropertyValue -Object $supportScope -Name "includeServiceOnly" -DefaultValue $false)
  $includeFallback = [bool](Get-OptionalPropertyValue -Object $supportScope -Name "includeFallback" -DefaultValue $false)
  $runtimeSupportTierDisplay = "none"
  if ($runtimeSupportTiers.Count -gt 0) {
    $runtimeSupportTierDisplay = $runtimeSupportTiers -join ", "
  }
  $supportMatrixRuntimeSupportTierDisplay = "none"
  if ($supportMatrixRuntimeSupportTiers.Count -gt 0) {
    $supportMatrixRuntimeSupportTierDisplay = $supportMatrixRuntimeSupportTiers -join ", "
  }
  return @(
    "## Release Evidence Gate",
    "",
    "- Summary generated at UTC: $generatedAtUtc",
    "- Final full-matrix claim: $((Get-OptionalPropertyValue -Object $releaseClaim -Name "finalFullMatrixReleaseClaim" -DefaultValue $false))",
    "- Release claim: $((Get-OptionalPropertyValue -Object $releaseClaim -Name "kind" -DefaultValue "missing"))",
    "- Review scope: $reviewScopeKind",
    "- Proof level: $proofLevel",
    "- Bundle proof level: $bundleProofLevel",
    "- Bundle required uptime hours: $bundleRequiredUptimeHours",
    "- Bundle evidence split: workflowCapable=$bundleWorkflowCapableEvidenceCount, localCommandOnly=$bundleLocalCommandOnlyEvidenceCount",
    "- Strict bundle support claim: validated=$bundleSupportClaimValidated, bothNextJsModes=$bundleRequireBothNextJsModes, declaredServiceManagers=$bundleRequireDeclaredServiceManagers, declaredReverseProxies=$bundleRequireDeclaredReverseProxies",
    "- Coverage collection: failOnWarnings=$coverageFailOnWarnings, requiredMinimumUptimeHours=$coverageRequiredMinimumUptimeHours",
    "- Support matrix SHA256: $supportMatrixSha256",
    "- Support matrix target count: $supportMatrixTargetCount",
    "- Support matrix required uptime hours: $supportMatrixRequiredMinimumUptimeHours",
    "- Support matrix runtime tiers: $supportMatrixRuntimeSupportTierDisplay",
    "- Claim requirements: fullMatrix=$($requirements.fullMatrixScope), strictCi=$($requirements.strictCiRelease), warningClean=$($requirements.warningClean), coverageComplete=$($requirements.coverageComplete), nonSyntheticEvidence=$($requirements.nonSyntheticEvidenceRequired), uniqueEvidencePayloads=$($requirements.uniqueEvidencePayloadsRequired), workflowApplicabilityKnown=$($requirements.workflowApplicabilityKnown), runtimeSupportMetadataKnown=$($requirements.runtimeSupportMetadataKnown), maxEvidenceAgeDays=$($requirements.maxEvidenceAgeDaysRequired), minimumUptimeHours=$($requirements.minimumUptimeHoursRequired)",
    "- Strict evidence requirements: sourceClean=$($requirements.sourceCleanRequired), currentCommit=$($requirements.currentCommitRequired), bundleCi=$($requirements.ciProvenanceRequired), collectionCi=$($requirements.collectionCiProvenanceRequired), collectionSourceCommit=$($requirements.collectionSourceCommitRequired), hostEvidenceWorkflow=$($requirements.hostEvidenceWorkflowCollectionRequired), runtimeVersions=$($requirements.runtimeVersionsRequired), collectorSha256=$($requirements.collectorSha256Required)",
    "- Source git repository: $sourceIsGitRepository",
    "- Source commit: $sourceCommitSha",
    "- Source tracked dirty: $sourceTrackedDirty",
    "- Bundle CI workflow: $bundleCiWorkflowName",
    "- Bundle CI run: $bundleCiRunId",
    "- Bundle CI SHA: $bundleCiSha",
    "- Coverage: $coveragePercentDisplay",
    "- Targets: $selectedTargetCount of $matrixTargetCount",
    "- Scope flags: includeServiceOnly=$includeServiceOnly, includeFallback=$includeFallback",
    "- Evidence freshness window: maxAgeDays=$maxEvidenceAgeDays",
    "- Evidence collection paths: workflowCapable=$workflowCapableEvidenceCount, localCommandOnly=$localCommandOnlyEvidenceCount",
    "- Collection provenance: ci=$collectionCiEvidenceCount, ciMissing=$collectionCiMissingCount, sourceMatch=$collectionCiSourceMatchCount, sourceMismatch=$collectionCiSourceMismatchCount, hostEvidenceWorkflow=$hostEvidenceWorkflowCollectionCount, hostEvidenceWorkflowMismatch=$hostEvidenceWorkflowMismatchCount, dispatchMatch=$collectionWorkflowDispatchMatchCount, dispatchMismatch=$collectionWorkflowDispatchMismatchCount, dispatchMatrixMismatch=$collectionWorkflowDispatchMatrixMismatchCount",
    "- Evidence payloads: uniqueSha256=$uniqueEvidenceSha256Count",
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
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    maxEvidenceAgeDays = 30
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
    supportMatrix = [ordered]@{
      sha256 = ("a" * 64)
      targetCount = 23
      requiredMinimumUptimeHours = 72
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
    }
    collectionProvenance = [ordered]@{
      collectionCiEvidenceCount = 282
      collectionCiMissingCount = 0
      collectionCiSourceMatchCount = 282
      collectionCiSourceMismatchCount = 0
      hostEvidenceWorkflowCollectionCount = 282
      hostEvidenceWorkflowMismatchCount = 0
      collectionWorkflowDispatchMatchCount = 282
      collectionWorkflowDispatchMismatchCount = 0
      collectionWorkflowDispatchMatrixMismatchCount = 0
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
      uniqueEvidenceSha256Count = 312
      productionRecommendedRuntimeEvidenceCount = 256
      nonProductionRecommendedRuntimeEvidenceCount = 56
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
      covered = @(
        [ordered]@{
          collectionCommand = "redacted collection command"
          workflowDispatchCommand = "gh workflow run host-evidence.yml --ref private"
        }
      )
    }
    sourceControl = [ordered]@{
      isGitRepository = $true
      commitSha = "0123456789abcdef0123456789abcdef01234567"
      trackedDirty = $false
      branchName = "private/customer-branch"
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

  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputJson -Encoding UTF8
  Write-ReleaseReadinessStepSummary -SourcePath $inputJson -DestinationPath $outputMarkdown

  $legacyInputJson = Join-Path $selfTestRoot "legacy-release-readiness-summary.json"
  $legacyOutputMarkdown = Join-Path $selfTestRoot "legacy-github-step-summary.md"
  $legacySummary = $summary | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $legacySummary.releaseClaim.PSObject.Properties.Remove("requirements")
  $legacySummary.PSObject.Properties.Remove("supportMatrix")
  $legacySummary.coverage.PSObject.Properties.Remove("runtimeSupportTiers")
  $legacySummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyInputJson -Encoding UTF8
  Write-ReleaseReadinessStepSummary -SourcePath $legacyInputJson -DestinationPath $legacyOutputMarkdown
  $legacyOutput = Get-Content -LiteralPath $legacyOutputMarkdown -Raw
  if (-not $legacyOutput.Contains("- Claim requirements: fullMatrix=False, strictCi=False, warningClean=False, coverageComplete=False, nonSyntheticEvidence=False, uniqueEvidencePayloads=False, workflowApplicabilityKnown=False, runtimeSupportMetadataKnown=False, maxEvidenceAgeDays=0, minimumUptimeHours=0")) {
    throw "Release readiness step summary self-test failed: legacy missing requirements were not safely rendered."
  }
  if (-not $legacyOutput.Contains("- Runtime support tiers: none")) {
    throw "Release readiness step summary self-test failed: legacy missing runtime support tiers were not safely rendered."
  }
  if (-not $legacyOutput.Contains("- Support matrix SHA256: missing")) {
    throw "Release readiness step summary self-test failed: legacy missing support matrix SHA256 was not safely rendered."
  }
  if (-not $legacyOutput.Contains("- Support matrix target count: 0") -or
    -not $legacyOutput.Contains("- Support matrix required uptime hours: 0") -or
    -not $legacyOutput.Contains("- Support matrix runtime tiers: none")) {
    throw "Release readiness step summary self-test failed: legacy missing support matrix contract fields were not safely rendered."
  }

  $output = Get-Content -LiteralPath $outputMarkdown -Raw
  foreach ($expected in @(
      "## Release Evidence Gate",
      "- Summary generated at UTC:",
      "- Final full-matrix claim: True",
      "- Release claim: strict-ci-full-matrix",
      "- Review scope: full-matrix",
      "- Proof level: strict-ci-release",
      "- Bundle proof level: hardened-real-host-evidence",
      "- Bundle required uptime hours: 72",
      "- Bundle evidence split: workflowCapable=282, localCommandOnly=30",
      "- Strict bundle support claim: validated=True, bothNextJsModes=True, declaredServiceManagers=True, declaredReverseProxies=True",
      "- Coverage collection: failOnWarnings=True, requiredMinimumUptimeHours=72",
      ("- Support matrix SHA256: {0}" -f ("a" * 64)),
      "- Support matrix target count: 23",
      "- Support matrix required uptime hours: 72",
      "- Support matrix runtime tiers: community-package, experimental, tier-1",
      "- Claim requirements: fullMatrix=True, strictCi=True, warningClean=True, coverageComplete=True, nonSyntheticEvidence=True, uniqueEvidencePayloads=True, workflowApplicabilityKnown=True, runtimeSupportMetadataKnown=True, maxEvidenceAgeDays=30, minimumUptimeHours=72",
      "- Strict evidence requirements: sourceClean=True, currentCommit=True, bundleCi=True, collectionCi=True, collectionSourceCommit=True, hostEvidenceWorkflow=True, runtimeVersions=True, collectorSha256=True",
      "- Source git repository: True",
      "- Source commit: 0123456789abcdef0123456789abcdef01234567",
      "- Source tracked dirty: False",
      "- Bundle CI workflow: support-evidence-bundle",
      "- Bundle CI run: 123456789",
      "- Bundle CI SHA: 0123456789abcdef0123456789abcdef01234567",
      "- Coverage: 100.00%",
      "- Targets: 23 of 23",
      "- Scope flags: includeServiceOnly=True, includeFallback=True",
      "- Evidence freshness window: maxAgeDays=30",
      "- Evidence collection paths: workflowCapable=282, localCommandOnly=30",
      "- Collection provenance: ci=282, ciMissing=0, sourceMatch=282, sourceMismatch=0, hostEvidenceWorkflow=282, hostEvidenceWorkflowMismatch=0, dispatchMatch=282, dispatchMismatch=0, dispatchMatrixMismatch=0",
      "- Evidence payloads: uniqueSha256=312",
      "- Runtime evidence: productionRecommended=256, nonProductionRecommended=56",
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
