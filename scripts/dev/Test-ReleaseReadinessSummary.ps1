param(
  [string]$InputPath = "release-readiness-summary.json",
  [string]$MatrixPath = "",
  [switch]$RequireFinalFullMatrixReleaseClaim,
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

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Normalize-ReverseProxy {
  param([string]$Value)
  $normalized = Normalize-Token $Value
  if ($normalized -eq "httpd") { return "apache" }
  return $normalized
}

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Test-ProductionRecommendedTarget {
  param([object]$Target)

  $nodeRuntimeSupport = Get-OptionalPropertyValue -Object $Target -Name "nodeRuntimeSupport"
  if ($null -eq $nodeRuntimeSupport) { return $false }
  $property = $nodeRuntimeSupport.PSObject.Properties["productionRecommended"]
  return ($property -and $property.Value -is [bool] -and [bool]$property.Value)
}

function Test-TargetWorkflowDispatchSupported {
  param([object]$Target)

  $localCommandOnlyProperty = $Target.PSObject.Properties["localCommandOnly"]
  if ($localCommandOnlyProperty -and $localCommandOnlyProperty.Value -eq $true) {
    return $false
  }

  $category = Normalize-Token ([string]$Target.category)
  return ($category -in @("windows-client", "windows-server", "linux", "macos"))
}

function Get-MatrixExpectedEvidenceSummary {
  param(
    [object[]]$Targets,
    [bool]$IncludeServiceOnly,
    [bool]$IncludeFallback
  )

  $expectedCount = 0
  $workflowCapableEvidenceCount = 0
  $localCommandOnlyEvidenceCount = 0
  $productionRecommendedRuntimeEvidenceCount = 0
  $nonProductionRecommendedRuntimeEvidenceCount = 0

  foreach ($target in @($Targets)) {
    $modes = @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $serviceManagers = @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $fallbackManagers = @(Get-ArrayValue (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers") | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $proxies = @(Get-ArrayValue $target.reverseProxies | ForEach-Object { Normalize-ReverseProxy ([string]$_) } | Where-Object { $_ })
    $concreteProxies = @($proxies | Where-Object { $_ -ne "none" })
    $serviceOnlyProxies = @($proxies | Where-Object { $_ -eq "none" })

    $targetCount = 0
    foreach ($mode in $modes) {
      foreach ($serviceManager in $serviceManagers) {
        $targetCount += $concreteProxies.Count
        if ($IncludeServiceOnly) {
          $targetCount += $serviceOnlyProxies.Count
        }
      }

      if ($IncludeFallback) {
        foreach ($fallbackManager in $fallbackManagers) {
          $targetCount += $concreteProxies.Count
          if ($IncludeServiceOnly) {
            $targetCount += $serviceOnlyProxies.Count
          }
        }
      }
    }

    $expectedCount += $targetCount
    if (Test-TargetWorkflowDispatchSupported -Target $target) {
      $workflowCapableEvidenceCount += $targetCount
    } else {
      $localCommandOnlyEvidenceCount += $targetCount
    }

    if (Test-ProductionRecommendedTarget -Target $target) {
      $productionRecommendedRuntimeEvidenceCount += $targetCount
    } else {
      $nonProductionRecommendedRuntimeEvidenceCount += $targetCount
    }
  }

  return [pscustomobject]@{
    expectedCount = $expectedCount
    workflowCapableEvidenceCount = $workflowCapableEvidenceCount
    localCommandOnlyEvidenceCount = $localCommandOnlyEvidenceCount
    productionRecommendedRuntimeEvidenceCount = $productionRecommendedRuntimeEvidenceCount
    nonProductionRecommendedRuntimeEvidenceCount = $nonProductionRecommendedRuntimeEvidenceCount
  }
}

function Add-Issue {
  param(
    [System.Collections.Generic.List[string]]$Issues,
    [string]$Message
  )
  $Issues.Add($Message) | Out-Null
}

function Test-BooleanRequirement {
  param(
    [System.Collections.Generic.List[string]]$Issues,
    $Requirements,
    [string]$Name
  )

  if ([bool](Get-OptionalPropertyValue -Object $Requirements -Name $Name -DefaultValue $false) -ne $true) {
    Add-Issue -Issues $Issues -Message "releaseClaim.requirements.$Name must be true."
  }
}

function Test-Sha256Text {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^[a-f0-9]{64}$')
}

function Test-GitShaText {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^[a-f0-9]{40}$')
}

function Test-CurrentOrPastTimestamp {
  param(
    $Value,
    [int]$FutureSkewMinutes = 5
  )

  if ($null -eq $Value) {
    return $false
  }

  try {
    if ($Value -is [DateTime]) {
      $timestamp = $Value.ToUniversalTime()
    } else {
      $text = [string]$Value
      if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
      }
      $timestamp = [DateTime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
  } catch {
    return $false
  }

  return ($timestamp -le (Get-Date).ToUniversalTime().AddMinutes($FutureSkewMinutes))
}

function Test-NumericText {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9]+$')
}

function Test-SafeCiWorkflowName {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -cmatch '^[A-Za-z0-9._/-]+$')
}

function Get-MatrixVerificationSummary {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Support matrix was not found: $Path"
  }

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $targets = @(Get-OptionalPropertyValue -Object $matrix -Name "targets" -DefaultValue @())
  $runtimeSupportTiers = New-Object System.Collections.Generic.HashSet[string]
  foreach ($target in $targets) {
    $nodeRuntimeSupport = Get-OptionalPropertyValue -Object $target -Name "nodeRuntimeSupport"
    $supportTier = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "supportTier")
    if (-not [string]::IsNullOrWhiteSpace($supportTier)) {
      [void]$runtimeSupportTiers.Add($supportTier)
    }
  }

  return [pscustomobject]@{
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    targetCount = $targets.Count
    targets = $targets
    requiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $matrix -Name "requiredMinimumUptimeHours" -DefaultValue 0)
    runtimeSupportTiers = @($runtimeSupportTiers | Sort-Object)
  }
}

function Test-ReleaseReadinessSummaryObject {
  param(
    [Parameter(Mandatory = $true)]$Summary,
    [Parameter(Mandatory = $true)][string]$SummaryText,
    [Parameter(Mandatory = $true)]$MatrixSummary,
    [bool]$RequireFinalClaim
  )

  $issues = New-Object System.Collections.Generic.List[string]
  if ([bool](Get-OptionalPropertyValue -Object $Summary -Name "ready" -DefaultValue $false) -ne $true) {
    Add-Issue -Issues $issues -Message "ready must be true."
  }

  $releaseClaim = Get-OptionalPropertyValue -Object $Summary -Name "releaseClaim"
  $requirements = Get-OptionalPropertyValue -Object $releaseClaim -Name "requirements"
  $supportScope = Get-OptionalPropertyValue -Object $Summary -Name "supportScope"
  $bundleSupportScope = Get-OptionalPropertyValue -Object $Summary -Name "bundleSupportScope"
  $supportMatrix = Get-OptionalPropertyValue -Object $Summary -Name "supportMatrix"
  $coverage = Get-OptionalPropertyValue -Object $Summary -Name "coverage"
  $collectionProvenance = Get-OptionalPropertyValue -Object $Summary -Name "collectionProvenance"
  $sourceControl = Get-OptionalPropertyValue -Object $Summary -Name "sourceControl"
  $bundleCi = Get-OptionalPropertyValue -Object $Summary -Name "bundleCi"

  if ($RequireFinalClaim) {
    if ([int](Get-OptionalPropertyValue -Object $Summary -Name "schemaVersion" -DefaultValue 0) -ne 1) {
      Add-Issue -Issues $issues -Message "schemaVersion must be 1."
    }
    if (-not (Test-CurrentOrPastTimestamp -Value (Get-OptionalPropertyValue -Object $Summary -Name "generatedAtUtc" -DefaultValue $null))) {
      Add-Issue -Issues $issues -Message "generatedAtUtc is required, must be valid, and must not be in the future."
    }
    if ([bool](Get-OptionalPropertyValue -Object $releaseClaim -Name "finalFullMatrixReleaseClaim" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "releaseClaim.finalFullMatrixReleaseClaim must be true."
    }
    if ([string](Get-OptionalPropertyValue -Object $releaseClaim -Name "kind" -DefaultValue "") -ne "strict-ci-full-matrix") {
      Add-Issue -Issues $issues -Message "releaseClaim.kind must be strict-ci-full-matrix."
    }
    if ([bool](Get-OptionalPropertyValue -Object $releaseClaim -Name "strictCiRelease" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "releaseClaim.strictCiRelease must be true."
    }
    if ([string](Get-OptionalPropertyValue -Object $releaseClaim -Name "scope" -DefaultValue "") -ne "full-matrix") {
      Add-Issue -Issues $issues -Message "releaseClaim.scope must be full-matrix."
    }
    if ([bool](Get-OptionalPropertyValue -Object $supportScope -Name "fullMatrix" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "supportScope.fullMatrix must be true."
    }
    if ([string](Get-OptionalPropertyValue -Object $supportScope -Name "kind" -DefaultValue "") -ne "full-matrix") {
      Add-Issue -Issues $issues -Message "supportScope.kind must be full-matrix."
    }
    if ([string](Get-OptionalPropertyValue -Object $supportScope -Name "proofLevel" -DefaultValue "") -ne "strict-ci-release") {
      Add-Issue -Issues $issues -Message "supportScope.proofLevel must be strict-ci-release for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $supportScope -Name "includeServiceOnly" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "supportScope.includeServiceOnly must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $supportScope -Name "includeFallback" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "supportScope.includeFallback must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $supportScope -Name "strictNextJsModeServiceProxyClaim" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "supportScope.strictNextJsModeServiceProxyClaim must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "fullMatrix" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "bundleSupportScope.fullMatrix must be true."
    }
    if ([string](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "kind" -DefaultValue "") -ne "full-matrix") {
      Add-Issue -Issues $issues -Message "bundleSupportScope.kind must be full-matrix."
    }
    if ([string](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "proofLevel" -DefaultValue "") -ne "hardened-real-host-evidence") {
      Add-Issue -Issues $issues -Message "bundleSupportScope.proofLevel must be hardened-real-host-evidence for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "includeServiceOnly" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "bundleSupportScope.includeServiceOnly must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "includeFallback" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "bundleSupportScope.includeFallback must be true for final full-matrix summary verification."
    }
    foreach ($bundleStrictFlagName in @(
        "supportClaimValidated",
        "requireBothNextJsModes",
        "requireDeclaredServiceManagers",
        "requireDeclaredReverseProxies"
      )) {
      if ([bool](Get-OptionalPropertyValue -Object $bundleSupportScope -Name $bundleStrictFlagName -DefaultValue $false) -ne $true) {
        Add-Issue -Issues $issues -Message "bundleSupportScope.$bundleStrictFlagName must be true for final full-matrix summary verification."
      }
    }
    if ([bool](Get-OptionalPropertyValue -Object $coverage -Name "includeServiceOnly" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "coverage.includeServiceOnly must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $coverage -Name "includeFallback" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "coverage.includeFallback must be true for final full-matrix summary verification."
    }
    if ([bool](Get-OptionalPropertyValue -Object $coverage -Name "failOnWarningsDuringCollection" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "coverage.failOnWarningsDuringCollection must be true for final full-matrix summary verification."
    }
    if ([int](Get-OptionalPropertyValue -Object $coverage -Name "requiredMinimumUptimeHours" -DefaultValue 0) -ne [int]$MatrixSummary.requiredMinimumUptimeHours) {
      Add-Issue -Issues $issues -Message "coverage.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours."
    }
    $maxEvidenceAgeDays = [int](Get-OptionalPropertyValue -Object $Summary -Name "maxEvidenceAgeDays" -DefaultValue 0)
    $maxEvidenceAgeDaysRequired = [int](Get-OptionalPropertyValue -Object $requirements -Name "maxEvidenceAgeDaysRequired" -DefaultValue 0)
    if ($maxEvidenceAgeDays -lt 1) {
      Add-Issue -Issues $issues -Message "maxEvidenceAgeDays must be positive for final full-matrix summary verification."
    }
    if ($maxEvidenceAgeDaysRequired -lt 1) {
      Add-Issue -Issues $issues -Message "releaseClaim.requirements.maxEvidenceAgeDaysRequired must be positive."
    }
    if ($maxEvidenceAgeDays -ne $maxEvidenceAgeDaysRequired) {
      Add-Issue -Issues $issues -Message "maxEvidenceAgeDays must match releaseClaim.requirements.maxEvidenceAgeDaysRequired."
    }

    foreach ($requirementName in @(
        "fullMatrixScope",
        "strictCiRelease",
        "warningClean",
        "coverageComplete",
        "nonSyntheticEvidenceRequired",
        "uniqueEvidencePayloadsRequired",
        "workflowApplicabilityKnown",
        "runtimeSupportMetadataKnown",
        "sourceCleanRequired",
        "currentCommitRequired",
        "ciProvenanceRequired",
        "collectionCiProvenanceRequired",
        "collectionSourceCommitRequired",
        "hostEvidenceWorkflowCollectionRequired",
        "runtimeVersionsRequired",
        "collectorSha256Required"
      )) {
      Test-BooleanRequirement -Issues $issues -Requirements $requirements -Name $requirementName
    }

    if ([int](Get-OptionalPropertyValue -Object $requirements -Name "minimumUptimeHoursRequired" -DefaultValue 0) -lt 1) {
      Add-Issue -Issues $issues -Message "releaseClaim.requirements.minimumUptimeHoursRequired must be positive."
    }
    if ([int](Get-OptionalPropertyValue -Object $requirements -Name "minimumUptimeHoursRequired" -DefaultValue 0) -ne [int]$MatrixSummary.requiredMinimumUptimeHours) {
      Add-Issue -Issues $issues -Message "releaseClaim.requirements.minimumUptimeHoursRequired must match support matrix requiredMinimumUptimeHours."
    }

    $supportMatrixSha256 = [string](Get-OptionalPropertyValue -Object $supportMatrix -Name "sha256" -DefaultValue "")
    if (-not (Test-Sha256Text -Value $supportMatrixSha256)) {
      Add-Issue -Issues $issues -Message "supportMatrix.sha256 is required and must be a lowercase SHA256 hash."
    }
    elseif ($supportMatrixSha256 -ne [string]$MatrixSummary.sha256) {
      Add-Issue -Issues $issues -Message "supportMatrix.sha256 must match the support matrix being used for review."
    }
    if ([int](Get-OptionalPropertyValue -Object $supportMatrix -Name "targetCount" -DefaultValue 0) -ne [int]$MatrixSummary.targetCount) {
      Add-Issue -Issues $issues -Message "supportMatrix.targetCount must match the current support matrix target count."
    }
    if ([int](Get-OptionalPropertyValue -Object $supportMatrix -Name "requiredMinimumUptimeHours" -DefaultValue 0) -ne [int]$MatrixSummary.requiredMinimumUptimeHours) {
      Add-Issue -Issues $issues -Message "supportMatrix.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours."
    }
  }

  $expectedCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "expectedCount" -DefaultValue 0)
  $coveredCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "coveredCount" -DefaultValue -1)
  $missingCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "missingCount" -DefaultValue -1)
  $uniqueEvidenceSha256Count = [int](Get-OptionalPropertyValue -Object $coverage -Name "uniqueEvidenceSha256Count" -DefaultValue -1)
  if ($expectedCount -lt 1) {
    Add-Issue -Issues $issues -Message "coverage.expectedCount must be positive."
  }
  if ($coveredCount -ne $expectedCount -or $missingCount -ne 0) {
    Add-Issue -Issues $issues -Message "coverage must be complete: coveredCount must equal expectedCount and missingCount must be 0."
  }
  if ($RequireFinalClaim -and $uniqueEvidenceSha256Count -ne $coveredCount) {
    Add-Issue -Issues $issues -Message "coverage.uniqueEvidenceSha256Count must equal coverage.coveredCount for final full-matrix summary verification."
  }

  $expectedEvidenceSummary = $null
  if ($RequireFinalClaim) {
    $expectedEvidenceSummary = Get-MatrixExpectedEvidenceSummary -Targets @($MatrixSummary.targets) -IncludeServiceOnly $true -IncludeFallback $true
    if ($expectedCount -ne [int]$expectedEvidenceSummary.expectedCount) {
      Add-Issue -Issues $issues -Message "coverage.expectedCount must match the support matrix evidence count for service-only and fallback-inclusive final verification."
    }
  }

  $workflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "workflowCapableEvidenceCount" -DefaultValue -1)
  $localCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue -1)
  if ($RequireFinalClaim) {
    if ($workflowCapableEvidenceCount -lt 0 -or $localCommandOnlyEvidenceCount -lt 0) {
      Add-Issue -Issues $issues -Message "supportScope workflowCapableEvidenceCount and localCommandOnlyEvidenceCount must be non-negative."
    } elseif (($workflowCapableEvidenceCount + $localCommandOnlyEvidenceCount) -ne $coveredCount) {
      Add-Issue -Issues $issues -Message "supportScope workflowCapableEvidenceCount plus localCommandOnlyEvidenceCount must equal coverage.coveredCount."
    }
    if ($null -ne $expectedEvidenceSummary) {
      if ($workflowCapableEvidenceCount -ne [int]$expectedEvidenceSummary.workflowCapableEvidenceCount) {
        Add-Issue -Issues $issues -Message "supportScope.workflowCapableEvidenceCount must match the support matrix workflow-capable evidence count."
      }
      if ($localCommandOnlyEvidenceCount -ne [int]$expectedEvidenceSummary.localCommandOnlyEvidenceCount) {
        Add-Issue -Issues $issues -Message "supportScope.localCommandOnlyEvidenceCount must match the support matrix local-command-only evidence count."
      }
    }

    $productionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "productionRecommendedRuntimeEvidenceCount" -DefaultValue -1)
    $nonProductionRecommendedRuntimeEvidenceCount = [int](Get-OptionalPropertyValue -Object $coverage -Name "nonProductionRecommendedRuntimeEvidenceCount" -DefaultValue -1)
    if ($productionRecommendedRuntimeEvidenceCount -lt 0 -or $nonProductionRecommendedRuntimeEvidenceCount -lt 0) {
      Add-Issue -Issues $issues -Message "coverage productionRecommendedRuntimeEvidenceCount and nonProductionRecommendedRuntimeEvidenceCount must be non-negative."
    } elseif (($productionRecommendedRuntimeEvidenceCount + $nonProductionRecommendedRuntimeEvidenceCount) -ne $coveredCount) {
      Add-Issue -Issues $issues -Message "coverage productionRecommendedRuntimeEvidenceCount plus nonProductionRecommendedRuntimeEvidenceCount must equal coverage.coveredCount."
    }
    if ($null -ne $expectedEvidenceSummary) {
      if ($productionRecommendedRuntimeEvidenceCount -ne [int]$expectedEvidenceSummary.productionRecommendedRuntimeEvidenceCount) {
        Add-Issue -Issues $issues -Message "coverage.productionRecommendedRuntimeEvidenceCount must match the support matrix production-recommended evidence count."
      }
      if ($nonProductionRecommendedRuntimeEvidenceCount -ne [int]$expectedEvidenceSummary.nonProductionRecommendedRuntimeEvidenceCount) {
        Add-Issue -Issues $issues -Message "coverage.nonProductionRecommendedRuntimeEvidenceCount must match the support matrix non-production-recommended evidence count."
      }
    }
  }

  $selectedTargetCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "selectedTargetCount" -DefaultValue 0)
  $matrixTargetCount = [int](Get-OptionalPropertyValue -Object $supportScope -Name "matrixTargetCount" -DefaultValue 0)
  if ($RequireFinalClaim -and ($selectedTargetCount -lt 1 -or $selectedTargetCount -ne $matrixTargetCount)) {
    Add-Issue -Issues $issues -Message "supportScope selectedTargetCount must equal matrixTargetCount for final full-matrix summary verification."
  }
  if ($RequireFinalClaim -and $matrixTargetCount -ne [int]$MatrixSummary.targetCount) {
    Add-Issue -Issues $issues -Message "supportScope.matrixTargetCount must match the current support matrix target count."
  }
  if ($RequireFinalClaim -and [int](Get-OptionalPropertyValue -Object $supportScope -Name "requiredMinimumUptimeHours" -DefaultValue 0) -ne [int]$MatrixSummary.requiredMinimumUptimeHours) {
    Add-Issue -Issues $issues -Message "supportScope.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours."
  }
  if ($RequireFinalClaim) {
    $bundleSelectedTargetCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "selectedTargetCount" -DefaultValue 0)
    $bundleMatrixTargetCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "matrixTargetCount" -DefaultValue 0)
    $bundleRequiredMinimumUptimeHours = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "requiredMinimumUptimeHours" -DefaultValue 0)
    $bundleWorkflowCapableEvidenceCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "workflowCapableEvidenceCount" -DefaultValue -1)
    $bundleLocalCommandOnlyEvidenceCount = [int](Get-OptionalPropertyValue -Object $bundleSupportScope -Name "localCommandOnlyEvidenceCount" -DefaultValue -1)
    if ($bundleSelectedTargetCount -lt 1 -or $bundleSelectedTargetCount -ne $bundleMatrixTargetCount) {
      Add-Issue -Issues $issues -Message "bundleSupportScope selectedTargetCount must equal matrixTargetCount for final full-matrix summary verification."
    }
    if ($bundleSelectedTargetCount -ne $selectedTargetCount -or $bundleMatrixTargetCount -ne $matrixTargetCount) {
      Add-Issue -Issues $issues -Message "bundleSupportScope target counts must match supportScope target counts."
    }
    if ($bundleMatrixTargetCount -ne [int]$MatrixSummary.targetCount) {
      Add-Issue -Issues $issues -Message "bundleSupportScope.matrixTargetCount must match the current support matrix target count."
    }
    if ($bundleRequiredMinimumUptimeHours -ne [int]$MatrixSummary.requiredMinimumUptimeHours) {
      Add-Issue -Issues $issues -Message "bundleSupportScope.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours."
    }
    if ($bundleWorkflowCapableEvidenceCount -lt 0 -or $bundleLocalCommandOnlyEvidenceCount -lt 0) {
      Add-Issue -Issues $issues -Message "bundleSupportScope workflowCapableEvidenceCount and localCommandOnlyEvidenceCount must be non-negative."
    } elseif (($bundleWorkflowCapableEvidenceCount + $bundleLocalCommandOnlyEvidenceCount) -ne $coveredCount) {
      Add-Issue -Issues $issues -Message "bundleSupportScope workflowCapableEvidenceCount plus localCommandOnlyEvidenceCount must equal coverage.coveredCount."
    }
    if ($bundleWorkflowCapableEvidenceCount -ne $workflowCapableEvidenceCount -or $bundleLocalCommandOnlyEvidenceCount -ne $localCommandOnlyEvidenceCount) {
      Add-Issue -Issues $issues -Message "bundleSupportScope workflow/local evidence counts must match supportScope workflow/local evidence counts."
    }
    if ($null -ne $expectedEvidenceSummary) {
      if ($bundleWorkflowCapableEvidenceCount -ne [int]$expectedEvidenceSummary.workflowCapableEvidenceCount) {
        Add-Issue -Issues $issues -Message "bundleSupportScope.workflowCapableEvidenceCount must match the support matrix workflow-capable evidence count."
      }
      if ($bundleLocalCommandOnlyEvidenceCount -ne [int]$expectedEvidenceSummary.localCommandOnlyEvidenceCount) {
        Add-Issue -Issues $issues -Message "bundleSupportScope.localCommandOnlyEvidenceCount must match the support matrix local-command-only evidence count."
      }
    }

    $collectionCiEvidenceCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiEvidenceCount" -DefaultValue -1)
    $collectionCiMissingCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiMissingCount" -DefaultValue -1)
    $collectionCiSourceMatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiSourceMatchCount" -DefaultValue -1)
    $collectionCiSourceMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionCiSourceMismatchCount" -DefaultValue -1)
    $hostEvidenceWorkflowCollectionCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "hostEvidenceWorkflowCollectionCount" -DefaultValue -1)
    $hostEvidenceWorkflowMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "hostEvidenceWorkflowMismatchCount" -DefaultValue -1)
    $collectionWorkflowDispatchMatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMatchCount" -DefaultValue -1)
    $collectionWorkflowDispatchMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMismatchCount" -DefaultValue -1)
    $collectionWorkflowDispatchMatrixMismatchCount = [int](Get-OptionalPropertyValue -Object $collectionProvenance -Name "collectionWorkflowDispatchMatrixMismatchCount" -DefaultValue -1)
    foreach ($collectionCount in @(
        $collectionCiEvidenceCount,
        $collectionCiMissingCount,
        $collectionCiSourceMatchCount,
        $collectionCiSourceMismatchCount,
        $hostEvidenceWorkflowCollectionCount,
        $hostEvidenceWorkflowMismatchCount,
        $collectionWorkflowDispatchMatchCount,
        $collectionWorkflowDispatchMismatchCount,
        $collectionWorkflowDispatchMatrixMismatchCount
      )) {
      if ($collectionCount -lt 0) {
        Add-Issue -Issues $issues -Message "collectionProvenance aggregate counts must be non-negative."
        break
      }
    }
    if ($collectionCiEvidenceCount -ne $workflowCapableEvidenceCount -or $collectionCiMissingCount -ne 0) {
      Add-Issue -Issues $issues -Message "collectionProvenance CI evidence counts must prove every workflow-capable evidence file was collected by CI."
    }
    if ($collectionCiSourceMatchCount -ne $workflowCapableEvidenceCount -or $collectionCiSourceMismatchCount -ne 0) {
      Add-Issue -Issues $issues -Message "collectionProvenance source commit counts must match every workflow-capable evidence file."
    }
    if ($hostEvidenceWorkflowCollectionCount -ne $workflowCapableEvidenceCount -or $hostEvidenceWorkflowMismatchCount -ne 0) {
      Add-Issue -Issues $issues -Message "collectionProvenance host-evidence workflow counts must match every workflow-capable evidence file."
    }
    if ($collectionWorkflowDispatchMatchCount -ne $workflowCapableEvidenceCount -or $collectionWorkflowDispatchMismatchCount -ne 0 -or $collectionWorkflowDispatchMatrixMismatchCount -ne 0) {
      Add-Issue -Issues $issues -Message "collectionProvenance workflow dispatch counts must match every workflow-capable evidence file and support matrix."
    }
  }

  $runtimeSupportTiers = @(Get-OptionalStringArray -Object $coverage -Name "runtimeSupportTiers")
  if ($RequireFinalClaim -and $runtimeSupportTiers.Count -lt 1) {
    Add-Issue -Issues $issues -Message "coverage.runtimeSupportTiers must contain at least one safe runtime support tier."
  }
  if ($RequireFinalClaim) {
    $expectedRuntimeSupportTiers = @($MatrixSummary.runtimeSupportTiers)
    $missingRuntimeSupportTiers = @($expectedRuntimeSupportTiers | Where-Object { $runtimeSupportTiers -notcontains $_ })
    $unexpectedRuntimeSupportTiers = @($runtimeSupportTiers | Where-Object { $expectedRuntimeSupportTiers -notcontains $_ })
    if ($missingRuntimeSupportTiers.Count -gt 0) {
      Add-Issue -Issues $issues -Message "coverage.runtimeSupportTiers is missing support matrix tier(s): $($missingRuntimeSupportTiers -join ', ')."
    }
    if ($unexpectedRuntimeSupportTiers.Count -gt 0) {
      Add-Issue -Issues $issues -Message "coverage.runtimeSupportTiers contains tier(s) not declared by the support matrix: $($unexpectedRuntimeSupportTiers -join ', ')."
    }
    $supportMatrixRuntimeSupportTiers = @(Get-OptionalStringArray -Object $supportMatrix -Name "runtimeSupportTiers")
    $missingSupportMatrixRuntimeSupportTiers = @($expectedRuntimeSupportTiers | Where-Object { $supportMatrixRuntimeSupportTiers -notcontains $_ })
    $unexpectedSupportMatrixRuntimeSupportTiers = @($supportMatrixRuntimeSupportTiers | Where-Object { $expectedRuntimeSupportTiers -notcontains $_ })
    if ($supportMatrixRuntimeSupportTiers.Count -lt 1) {
      Add-Issue -Issues $issues -Message "supportMatrix.runtimeSupportTiers must contain at least one safe runtime support tier."
    }
    if ($missingSupportMatrixRuntimeSupportTiers.Count -gt 0) {
      Add-Issue -Issues $issues -Message "supportMatrix.runtimeSupportTiers is missing support matrix tier(s): $($missingSupportMatrixRuntimeSupportTiers -join ', ')."
    }
    if ($unexpectedSupportMatrixRuntimeSupportTiers.Count -gt 0) {
      Add-Issue -Issues $issues -Message "supportMatrix.runtimeSupportTiers contains tier(s) not declared by the support matrix: $($unexpectedSupportMatrixRuntimeSupportTiers -join ', ')."
    }
  }

  if ($RequireFinalClaim) {
    if ([bool](Get-OptionalPropertyValue -Object $sourceControl -Name "isGitRepository" -DefaultValue $false) -ne $true) {
      Add-Issue -Issues $issues -Message "sourceControl.isGitRepository must be true."
    }
    $sourceCommitSha = [string](Get-OptionalPropertyValue -Object $sourceControl -Name "commitSha" -DefaultValue "")
    if (-not (Test-GitShaText -Value $sourceCommitSha)) {
      Add-Issue -Issues $issues -Message "sourceControl.commitSha must be a lowercase 40-character git SHA."
    }
    if ([bool](Get-OptionalPropertyValue -Object $sourceControl -Name "trackedDirty" -DefaultValue $true) -ne $false) {
      Add-Issue -Issues $issues -Message "sourceControl.trackedDirty must be false."
    }
    if ([string](Get-OptionalPropertyValue -Object $bundleCi -Name "provider" -DefaultValue "") -ne "github-actions") {
      Add-Issue -Issues $issues -Message "bundleCi.provider must be github-actions."
    }
    $bundleCiWorkflowName = [string](Get-OptionalPropertyValue -Object $bundleCi -Name "workflowName" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($bundleCiWorkflowName)) {
      Add-Issue -Issues $issues -Message "bundleCi.workflowName is required."
    } elseif (-not (Test-SafeCiWorkflowName -Value $bundleCiWorkflowName)) {
      Add-Issue -Issues $issues -Message "bundleCi.workflowName contains unsupported characters."
    } elseif ($bundleCiWorkflowName -ne "support-evidence-bundle") {
      Add-Issue -Issues $issues -Message "bundleCi.workflowName must be support-evidence-bundle."
    }
    if ([string](Get-OptionalPropertyValue -Object $bundleCi -Name "eventName" -DefaultValue "") -ne "workflow_dispatch") {
      Add-Issue -Issues $issues -Message "bundleCi.eventName must be workflow_dispatch."
    }
    if (-not (Test-NumericText -Value ([string](Get-OptionalPropertyValue -Object $bundleCi -Name "runId" -DefaultValue "")))) {
      Add-Issue -Issues $issues -Message "bundleCi.runId must be numeric."
    }
    if (-not (Test-NumericText -Value ([string](Get-OptionalPropertyValue -Object $bundleCi -Name "runAttempt" -DefaultValue "")))) {
      Add-Issue -Issues $issues -Message "bundleCi.runAttempt must be numeric."
    }
    $bundleCiSha = [string](Get-OptionalPropertyValue -Object $bundleCi -Name "sha" -DefaultValue "")
    if (-not (Test-GitShaText -Value $bundleCiSha) -or $bundleCiSha -ne $sourceCommitSha) {
      Add-Issue -Issues $issues -Message "bundleCi.sha must be a lowercase 40-character git SHA matching sourceControl.commitSha."
    }
  }

  foreach ($blocked in @(
      '"bundlePath"',
      '"matrixPath"',
      '"branchName"',
      '"covered"',
      '"missing"',
      '"collectionCommand"',
      '"workflowDispatchCommand"',
      '"evidenceFile"',
      'C:\\',
      '/home/',
      '/Users/'
    )) {
    if ($SummaryText.Contains($blocked)) {
      Add-Issue -Issues $issues -Message "redacted summary must not include private/raw evidence detail: $blocked"
    }
  }

  if ($issues.Count -gt 0) {
    Write-Host "Release readiness summary verification failures:"
    $issues | ForEach-Object { Write-Host "  $_" }
    throw "Release readiness summary verification failed with $($issues.Count) issue(s): $($issues -join '; ')"
  }
}

function Test-ReleaseReadinessSummaryFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$MatrixPath,
    [bool]$RequireFinalClaim
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Release readiness summary was not found: $Path"
  }

  $summaryText = Get-Content -LiteralPath $Path -Raw
  $summary = $summaryText | ConvertFrom-Json
  $matrixSummary = Get-MatrixVerificationSummary -Path $MatrixPath
  Test-ReleaseReadinessSummaryObject -Summary $summary -SummaryText $summaryText -MatrixSummary $matrixSummary -RequireFinalClaim $RequireFinalClaim
  Write-Host "Release readiness summary verification OK"
}

function Invoke-ExpectFailure {
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
      throw "Release readiness summary verifier self-test failed with unexpected error: $($_.Exception.Message)"
    }
  }

  if (-not $failed) {
    throw "Release readiness summary verifier self-test failed: expected failure containing '$ExpectedMessage'."
  }
}

function Invoke-SelfTest {
  Write-Host ""
  Write-Host "==> Release readiness summary verifier"

  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-readiness-summary-verifier-selftest-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null

  $validPath = Join-Path $selfTestRoot "release-readiness-summary.json"
  $matrixPath = Join-Path $selfTestRoot "support-matrix.json"
  $selfTestMatrix = [ordered]@{
    requiredMinimumUptimeHours = 72
    targets = @(
      [ordered]@{
        id = "windows-2022"
        category = "windows-server"
        serviceManagers = @("winsw", "nssm")
        reverseProxies = @("iis", "none")
        nextjsModes = @("standalone", "next-start")
        nodeRuntimeSupport = [ordered]@{
          supportTier = "tier-1"
          productionRecommended = $true
        }
      },
      [ordered]@{
        id = "windows-2012"
        category = "windows-server"
        serviceManagers = @("winsw", "nssm")
        reverseProxies = @("iis", "none")
        nextjsModes = @("standalone", "next-start")
        nodeRuntimeSupport = [ordered]@{
          supportTier = "experimental"
          productionRecommended = $false
        }
      },
      [ordered]@{
        id = "freebsd"
        category = "bsd"
        localCommandOnly = $true
        serviceManagers = @("bsdrc")
        reverseProxies = @("nginx", "apache", "haproxy", "traefik", "none")
        nextjsModes = @("standalone", "next-start")
        nodeRuntimeSupport = [ordered]@{
          supportTier = "community-package"
          productionRecommended = $false
        }
      }
    )
  }
  $selfTestMatrix | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $matrixPath -Encoding UTF8
  $matrixSha256 = (Get-FileHash -LiteralPath $matrixPath -Algorithm SHA256).Hash.ToLowerInvariant()

  $validSummary = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    maxEvidenceAgeDays = 30
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
    }
    supportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "strict-ci-release"
      fullMatrix = $true
      selectedTargetCount = 3
      matrixTargetCount = 3
      includeServiceOnly = $true
      includeFallback = $true
      strictNextJsModeServiceProxyClaim = $true
      workflowCapableEvidenceCount = 16
      localCommandOnlyEvidenceCount = 10
      requiredMinimumUptimeHours = 72
    }
    bundleSupportScope = [ordered]@{
      kind = "full-matrix"
      proofLevel = "hardened-real-host-evidence"
      fullMatrix = $true
      selectedTargetCount = 3
      matrixTargetCount = 3
      includeServiceOnly = $true
      includeFallback = $true
      supportClaimValidated = $true
      requireBothNextJsModes = $true
      requireDeclaredServiceManagers = $true
      requireDeclaredReverseProxies = $true
      workflowCapableEvidenceCount = 16
      localCommandOnlyEvidenceCount = 10
      requiredMinimumUptimeHours = 72
    }
    supportMatrix = [ordered]@{
      sha256 = $matrixSha256
      targetCount = 3
      requiredMinimumUptimeHours = 72
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
    }
    coverage = [ordered]@{
      expectedCount = 26
      coveredCount = 26
      missingCount = 0
      includeServiceOnly = $true
      includeFallback = $true
      failOnWarningsDuringCollection = $true
      requiredMinimumUptimeHours = 72
      coveragePercentDisplay = "100.00%"
      uniqueEvidenceSha256Count = 26
      productionRecommendedRuntimeEvidenceCount = 8
      nonProductionRecommendedRuntimeEvidenceCount = 18
      runtimeSupportTiers = @("community-package", "experimental", "tier-1")
    }
    collectionProvenance = [ordered]@{
      collectionCiEvidenceCount = 16
      collectionCiMissingCount = 0
      collectionCiSourceMatchCount = 16
      collectionCiSourceMismatchCount = 0
      hostEvidenceWorkflowCollectionCount = 16
      hostEvidenceWorkflowMismatchCount = 0
      collectionWorkflowDispatchMatchCount = 16
      collectionWorkflowDispatchMismatchCount = 0
      collectionWorkflowDispatchMatrixMismatchCount = 0
    }
    sourceControl = [ordered]@{
      isGitRepository = $true
      commitSha = "0123456789abcdef0123456789abcdef01234567"
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
  $validSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $validPath -Encoding UTF8
  Test-ReleaseReadinessSummaryFile -Path $validPath -MatrixPath $matrixPath -RequireFinalClaim $true

  $provisionalPath = Join-Path $selfTestRoot "provisional-summary.json"
  $provisionalSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $provisionalSummary.releaseClaim.finalFullMatrixReleaseClaim = $false
  $provisionalSummary.releaseClaim.kind = "provisional-full-matrix"
  $provisionalSummary.releaseClaim.strictCiRelease = $false
  $provisionalSummary.sourceControl.trackedDirty = $true
  $provisionalSummary.bundleCi.workflowName = ""
  $provisionalSummary.bundleCi.runId = ""
  $provisionalSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $provisionalPath -Encoding UTF8
  Test-ReleaseReadinessSummaryFile -Path $provisionalPath -MatrixPath $matrixPath -RequireFinalClaim $false

  $notFinalPath = Join-Path $selfTestRoot "not-final-summary.json"
  $notFinalSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $notFinalSummary.releaseClaim.finalFullMatrixReleaseClaim = $false
  $notFinalSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $notFinalPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "releaseClaim.finalFullMatrixReleaseClaim must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $notFinalPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $wrongSchemaPath = Join-Path $selfTestRoot "wrong-schema-summary.json"
  $wrongSchemaSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $wrongSchemaSummary.schemaVersion = 2
  $wrongSchemaSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wrongSchemaPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "schemaVersion must be 1" -Action {
    Test-ReleaseReadinessSummaryFile -Path $wrongSchemaPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingGeneratedAtPath = Join-Path $selfTestRoot "missing-generated-at-summary.json"
  $missingGeneratedAtSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingGeneratedAtSummary.PSObject.Properties.Remove("generatedAtUtc")
  $missingGeneratedAtSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingGeneratedAtPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "generatedAtUtc is required" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingGeneratedAtPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $futureGeneratedAtPath = Join-Path $selfTestRoot "future-generated-at-summary.json"
  $futureGeneratedAtSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $futureGeneratedAtSummary.generatedAtUtc = (Get-Date).ToUniversalTime().AddDays(1).ToString("o")
  $futureGeneratedAtSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $futureGeneratedAtPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "generatedAtUtc is required" -Action {
    Test-ReleaseReadinessSummaryFile -Path $futureGeneratedAtPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $wrongClaimKindPath = Join-Path $selfTestRoot "wrong-claim-kind-summary.json"
  $wrongClaimKindSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $wrongClaimKindSummary.releaseClaim.kind = "provisional-full-matrix"
  $wrongClaimKindSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wrongClaimKindPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "releaseClaim.kind must be strict-ci-full-matrix" -Action {
    Test-ReleaseReadinessSummaryFile -Path $wrongClaimKindPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $unsafeBundleWorkflowPath = Join-Path $selfTestRoot "unsafe-bundle-workflow-summary.json"
  $unsafeBundleWorkflowSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $unsafeBundleWorkflowSummary.bundleCi.workflowName = "release C:\private"
  $unsafeBundleWorkflowSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unsafeBundleWorkflowPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.workflowName contains unsupported characters" -Action {
    Test-ReleaseReadinessSummaryFile -Path $unsafeBundleWorkflowPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $wrongBundleWorkflowPath = Join-Path $selfTestRoot "wrong-bundle-workflow-summary.json"
  $wrongBundleWorkflowSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $wrongBundleWorkflowSummary.bundleCi.workflowName = "other-workflow"
  $wrongBundleWorkflowSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wrongBundleWorkflowPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.workflowName must be support-evidence-bundle" -Action {
    Test-ReleaseReadinessSummaryFile -Path $wrongBundleWorkflowPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $disabledFreshnessPath = Join-Path $selfTestRoot "disabled-freshness-summary.json"
  $disabledFreshnessSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $disabledFreshnessSummary.maxEvidenceAgeDays = 0
  $disabledFreshnessSummary.releaseClaim.requirements.maxEvidenceAgeDaysRequired = 0
  $disabledFreshnessSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $disabledFreshnessPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "maxEvidenceAgeDays must be positive" -Action {
    Test-ReleaseReadinessSummaryFile -Path $disabledFreshnessPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $notStrictCiPath = Join-Path $selfTestRoot "not-strict-ci-summary.json"
  $notStrictCiSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $notStrictCiSummary.releaseClaim.strictCiRelease = $false
  $notStrictCiSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $notStrictCiPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "releaseClaim.strictCiRelease must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $notStrictCiPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakProofLevelPath = Join-Path $selfTestRoot "weak-proof-level-summary.json"
  $weakProofLevelSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakProofLevelSummary.supportScope.proofLevel = "hardened-real-host-evidence"
  $weakProofLevelSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakProofLevelPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportScope.proofLevel must be strict-ci-release" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakProofLevelPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakBundleProofLevelPath = Join-Path $selfTestRoot "weak-bundle-proof-level-summary.json"
  $weakBundleProofLevelSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakBundleProofLevelSummary.bundleSupportScope.proofLevel = "basic-real-host-evidence"
  $weakBundleProofLevelSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakBundleProofLevelPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope.proofLevel must be hardened-real-host-evidence" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakBundleProofLevelPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakBundleUptimePath = Join-Path $selfTestRoot "weak-bundle-uptime-summary.json"
  $weakBundleUptimeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakBundleUptimeSummary.bundleSupportScope.requiredMinimumUptimeHours = 1
  $weakBundleUptimeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakBundleUptimePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakBundleUptimePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakBundleWorkflowCountPath = Join-Path $selfTestRoot "weak-bundle-workflow-count-summary.json"
  $weakBundleWorkflowCountSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakBundleWorkflowCountSummary.bundleSupportScope.workflowCapableEvidenceCount = 1
  $weakBundleWorkflowCountSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakBundleWorkflowCountPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope workflowCapableEvidenceCount plus localCommandOnlyEvidenceCount must equal coverage.coveredCount" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakBundleWorkflowCountPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakBundleStrictClaimPath = Join-Path $selfTestRoot "weak-bundle-strict-claim-summary.json"
  $weakBundleStrictClaimSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakBundleStrictClaimSummary.bundleSupportScope.requireDeclaredReverseProxies = $false
  $weakBundleStrictClaimSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakBundleStrictClaimPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope.requireDeclaredReverseProxies must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakBundleStrictClaimPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakCoverageWarningsPath = Join-Path $selfTestRoot "weak-coverage-warnings-summary.json"
  $weakCoverageWarningsSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakCoverageWarningsSummary.coverage.failOnWarningsDuringCollection = $false
  $weakCoverageWarningsSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakCoverageWarningsPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "coverage.failOnWarningsDuringCollection must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakCoverageWarningsPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakCoverageUptimePath = Join-Path $selfTestRoot "weak-coverage-uptime-summary.json"
  $weakCoverageUptimeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakCoverageUptimeSummary.coverage.requiredMinimumUptimeHours = 1
  $weakCoverageUptimeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakCoverageUptimePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "coverage.requiredMinimumUptimeHours must match support matrix requiredMinimumUptimeHours" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakCoverageUptimePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakCollectionCiPath = Join-Path $selfTestRoot "weak-collection-ci-summary.json"
  $weakCollectionCiSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakCollectionCiSummary.collectionProvenance.collectionCiMissingCount = 1
  $weakCollectionCiSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakCollectionCiPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "collectionProvenance CI evidence counts must prove every workflow-capable evidence file was collected by CI" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakCollectionCiPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakCollectionWorkflowPath = Join-Path $selfTestRoot "weak-collection-workflow-summary.json"
  $weakCollectionWorkflowSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakCollectionWorkflowSummary.collectionProvenance.hostEvidenceWorkflowMismatchCount = 1
  $weakCollectionWorkflowSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakCollectionWorkflowPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "collectionProvenance host-evidence workflow counts must match every workflow-capable evidence file" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakCollectionWorkflowPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $weakCollectionDispatchPath = Join-Path $selfTestRoot "weak-collection-dispatch-summary.json"
  $weakCollectionDispatchSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $weakCollectionDispatchSummary.collectionProvenance.collectionWorkflowDispatchMatrixMismatchCount = 1
  $weakCollectionDispatchSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $weakCollectionDispatchPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "collectionProvenance workflow dispatch counts must match every workflow-capable evidence file and support matrix" -Action {
    Test-ReleaseReadinessSummaryFile -Path $weakCollectionDispatchPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $badCommitShaPath = Join-Path $selfTestRoot "bad-commit-sha-summary.json"
  $badCommitShaSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $badCommitShaSummary.sourceControl.commitSha = "0123456789abcdef"
  $badCommitShaSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badCommitShaPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "sourceControl.commitSha must be a lowercase 40-character git SHA" -Action {
    Test-ReleaseReadinessSummaryFile -Path $badCommitShaPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $notGitRepositoryPath = Join-Path $selfTestRoot "not-git-repository-summary.json"
  $notGitRepositorySummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $notGitRepositorySummary.sourceControl.isGitRepository = $false
  $notGitRepositorySummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $notGitRepositoryPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "sourceControl.isGitRepository must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $notGitRepositoryPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $badBundleCiProviderPath = Join-Path $selfTestRoot "bad-bundle-ci-provider-summary.json"
  $badBundleCiProviderSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $badBundleCiProviderSummary.bundleCi.provider = "ci"
  $badBundleCiProviderSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badBundleCiProviderPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.provider must be github-actions" -Action {
    Test-ReleaseReadinessSummaryFile -Path $badBundleCiProviderPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $badBundleCiEventPath = Join-Path $selfTestRoot "bad-bundle-ci-event-summary.json"
  $badBundleCiEventSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $badBundleCiEventSummary.bundleCi.eventName = "push"
  $badBundleCiEventSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badBundleCiEventPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.eventName must be workflow_dispatch" -Action {
    Test-ReleaseReadinessSummaryFile -Path $badBundleCiEventPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $badBundleCiRunPath = Join-Path $selfTestRoot "bad-bundle-ci-run-summary.json"
  $badBundleCiRunSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $badBundleCiRunSummary.bundleCi.runId = "run-123"
  $badBundleCiRunSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badBundleCiRunPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.runId must be numeric" -Action {
    Test-ReleaseReadinessSummaryFile -Path $badBundleCiRunPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $badBundleCiShaPath = Join-Path $selfTestRoot "bad-bundle-ci-sha-summary.json"
  $badBundleCiShaSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $badBundleCiShaSummary.bundleCi.sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  $badBundleCiShaSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badBundleCiShaPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleCi.sha must be a lowercase 40-character git SHA matching sourceControl.commitSha" -Action {
    Test-ReleaseReadinessSummaryFile -Path $badBundleCiShaPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $privateLeakPath = Join-Path $selfTestRoot "private-leak-summary.json"
  $privateLeakSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  Add-Member -InputObject $privateLeakSummary -NotePropertyName "bundlePath" -NotePropertyValue "C:\private\release-evidence\support-evidence.zip"
  $privateLeakSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $privateLeakPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "redacted summary must not include private/raw evidence detail" -Action {
    Test-ReleaseReadinessSummaryFile -Path $privateLeakPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $incompleteCoveragePath = Join-Path $selfTestRoot "incomplete-coverage-summary.json"
  $incompleteCoverageSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $incompleteCoverageSummary.coverage.missingCount = 1
  $incompleteCoverageSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $incompleteCoveragePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "coverage must be complete" -Action {
    Test-ReleaseReadinessSummaryFile -Path $incompleteCoveragePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $undercountedCoveragePath = Join-Path $selfTestRoot "undercounted-coverage-summary.json"
  $undercountedCoverageSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $undercountedCoverageSummary.coverage.expectedCount = 1
  $undercountedCoverageSummary.coverage.coveredCount = 1
  $undercountedCoverageSummary.supportScope.workflowCapableEvidenceCount = 1
  $undercountedCoverageSummary.supportScope.localCommandOnlyEvidenceCount = 0
  $undercountedCoverageSummary.coverage.productionRecommendedRuntimeEvidenceCount = 1
  $undercountedCoverageSummary.coverage.nonProductionRecommendedRuntimeEvidenceCount = 0
  $undercountedCoverageSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $undercountedCoveragePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "coverage.expectedCount must match the support matrix evidence count" -Action {
    Test-ReleaseReadinessSummaryFile -Path $undercountedCoveragePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingServiceOnlyScopePath = Join-Path $selfTestRoot "missing-service-only-scope-summary.json"
  $missingServiceOnlyScopeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingServiceOnlyScopeSummary.supportScope.includeServiceOnly = $false
  $missingServiceOnlyScopeSummary.bundleSupportScope.includeServiceOnly = $false
  $missingServiceOnlyScopeSummary.coverage.includeServiceOnly = $false
  $missingServiceOnlyScopeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingServiceOnlyScopePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportScope.includeServiceOnly must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingServiceOnlyScopePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingFallbackScopePath = Join-Path $selfTestRoot "missing-fallback-scope-summary.json"
  $missingFallbackScopeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingFallbackScopeSummary.supportScope.includeFallback = $false
  $missingFallbackScopeSummary.bundleSupportScope.includeFallback = $false
  $missingFallbackScopeSummary.coverage.includeFallback = $false
  $missingFallbackScopeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingFallbackScopePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportScope.includeFallback must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingFallbackScopePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $mismatchedWorkflowCountsPath = Join-Path $selfTestRoot "mismatched-workflow-counts-summary.json"
  $mismatchedWorkflowCountsSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $mismatchedWorkflowCountsSummary.supportScope.workflowCapableEvidenceCount = 15
  $mismatchedWorkflowCountsSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mismatchedWorkflowCountsPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "workflowCapableEvidenceCount plus localCommandOnlyEvidenceCount must equal" -Action {
    Test-ReleaseReadinessSummaryFile -Path $mismatchedWorkflowCountsPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $mismatchedRuntimeCountsPath = Join-Path $selfTestRoot "mismatched-runtime-counts-summary.json"
  $mismatchedRuntimeCountsSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $mismatchedRuntimeCountsSummary.coverage.productionRecommendedRuntimeEvidenceCount = 7
  $mismatchedRuntimeCountsSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mismatchedRuntimeCountsPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "productionRecommendedRuntimeEvidenceCount plus nonProductionRecommendedRuntimeEvidenceCount must equal" -Action {
    Test-ReleaseReadinessSummaryFile -Path $mismatchedRuntimeCountsPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingRuntimeTierPath = Join-Path $selfTestRoot "missing-runtime-tier-summary.json"
  $missingRuntimeTierSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingRuntimeTierSummary.coverage.runtimeSupportTiers = @("experimental", "tier-1")
  $missingRuntimeTierSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingRuntimeTierPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "coverage.runtimeSupportTiers is missing support matrix tier" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingRuntimeTierPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingMatrixShaPath = Join-Path $selfTestRoot "missing-matrix-sha-summary.json"
  $missingMatrixShaSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingMatrixShaSummary.supportMatrix.PSObject.Properties.Remove("sha256")
  $missingMatrixShaSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingMatrixShaPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportMatrix.sha256 is required" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingMatrixShaPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $staleMatrixShaPath = Join-Path $selfTestRoot "stale-matrix-sha-summary.json"
  $staleMatrixShaSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $staleMatrixShaSummary.supportMatrix.sha256 = ("0" * 64)
  $staleMatrixShaSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleMatrixShaPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportMatrix.sha256 must match" -Action {
    Test-ReleaseReadinessSummaryFile -Path $staleMatrixShaPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $staleSupportMatrixTargetCountPath = Join-Path $selfTestRoot "stale-support-matrix-target-count-summary.json"
  $staleSupportMatrixTargetCountSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $staleSupportMatrixTargetCountSummary.supportMatrix.targetCount = 2
  $staleSupportMatrixTargetCountSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleSupportMatrixTargetCountPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportMatrix.targetCount must match" -Action {
    Test-ReleaseReadinessSummaryFile -Path $staleSupportMatrixTargetCountPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $staleSupportMatrixUptimePath = Join-Path $selfTestRoot "stale-support-matrix-uptime-summary.json"
  $staleSupportMatrixUptimeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $staleSupportMatrixUptimeSummary.supportMatrix.requiredMinimumUptimeHours = 1
  $staleSupportMatrixUptimeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleSupportMatrixUptimePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportMatrix.requiredMinimumUptimeHours must match" -Action {
    Test-ReleaseReadinessSummaryFile -Path $staleSupportMatrixUptimePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $missingSupportMatrixRuntimeTierPath = Join-Path $selfTestRoot "missing-support-matrix-runtime-tier-summary.json"
  $missingSupportMatrixRuntimeTierSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $missingSupportMatrixRuntimeTierSummary.supportMatrix.runtimeSupportTiers = @("experimental", "tier-1")
  $missingSupportMatrixRuntimeTierSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingSupportMatrixRuntimeTierPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportMatrix.runtimeSupportTiers is missing support matrix tier" -Action {
    Test-ReleaseReadinessSummaryFile -Path $missingSupportMatrixRuntimeTierPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $filteredBundleScopePath = Join-Path $selfTestRoot "filtered-bundle-scope-summary.json"
  $filteredBundleScopeSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $filteredBundleScopeSummary.bundleSupportScope.kind = "filtered"
  $filteredBundleScopeSummary.bundleSupportScope.fullMatrix = $false
  $filteredBundleScopeSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filteredBundleScopePath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope.fullMatrix must be true" -Action {
    Test-ReleaseReadinessSummaryFile -Path $filteredBundleScopePath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $staleBundleMatrixCountPath = Join-Path $selfTestRoot "stale-bundle-matrix-count-summary.json"
  $staleBundleMatrixCountSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $staleBundleMatrixCountSummary.bundleSupportScope.matrixTargetCount = 4
  $staleBundleMatrixCountSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleBundleMatrixCountPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "bundleSupportScope selectedTargetCount must equal matrixTargetCount" -Action {
    Test-ReleaseReadinessSummaryFile -Path $staleBundleMatrixCountPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  $staleMatrixCountPath = Join-Path $selfTestRoot "stale-matrix-count-summary.json"
  $staleMatrixCountSummary = $validSummary | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $staleMatrixCountSummary.supportScope.matrixTargetCount = 4
  $staleMatrixCountSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleMatrixCountPath -Encoding UTF8
  Invoke-ExpectFailure -ExpectedMessage "supportScope selectedTargetCount must equal matrixTargetCount" -Action {
    Test-ReleaseReadinessSummaryFile -Path $staleMatrixCountPath -MatrixPath $matrixPath -RequireFinalClaim $true
  }

  Write-Host "Release readiness summary verifier OK"
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Test-ReleaseReadinessSummaryFile -Path $InputPath -MatrixPath $MatrixPath -RequireFinalClaim ([bool]$RequireFinalFullMatrixReleaseClaim)
