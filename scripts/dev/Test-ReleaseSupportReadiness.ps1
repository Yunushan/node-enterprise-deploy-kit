param(
  [string]$BundlePath = "",
  [string]$MatrixPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$AllowWarnings,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$ProductionRecommendedOnly,
  [switch]$RequireProductionRecommendedRuntime,
  [switch]$RequireCleanSource,
  [switch]$RequireCurrentCommit,
  [switch]$RequireCiProvenance,
  [switch]$RequireCollectionCiProvenance,
  [switch]$RequireCollectionSourceCommit,
  [switch]$RequireHostEvidenceWorkflowCollection,
  [switch]$RequireRuntimeVersions,
  [switch]$RequireCollectorSha256,
  [int]$RequireMinimumUptimeHours = 0,
  [switch]$StrictCiRelease,
  [switch]$RequireFinalFullMatrixReleaseClaim,
  [ValidateSet("Table", "Json")]
  [string]$Format = "Table",
  [string]$OutputPath = "",
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

if ($StrictCiRelease -and $AllowWarnings) {
  throw "-StrictCiRelease cannot be combined with -AllowWarnings; final release evidence must be warning-clean."
}

if ($RequireFinalFullMatrixReleaseClaim -and -not $StrictCiRelease) {
  throw "-RequireFinalFullMatrixReleaseClaim requires -StrictCiRelease; final full-matrix signoff must use strict CI release checks."
}

if ($RequireFinalFullMatrixReleaseClaim -and (-not $IncludeServiceOnly -or -not $IncludeFallback)) {
  throw "-RequireFinalFullMatrixReleaseClaim requires -IncludeServiceOnly and -IncludeFallback; final full-matrix signoff must cover service-only and fallback rows."
}

if ($StrictCiRelease) {
  $RequireCleanSource = $true
  $RequireCurrentCommit = $true
  $RequireCiProvenance = $true
  $RequireCollectionCiProvenance = $true
  $RequireCollectionSourceCommit = $true
  $RequireHostEvidenceWorkflowCollection = $true
  $RequireRuntimeVersions = $true
  $RequireCollectorSha256 = $true
  if ($RequireMinimumUptimeHours -le 0) {
    $RequireMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath
  }
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

function Get-RelativePath {
  param(
    [string]$BasePath,
    [string]$Path
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  if ($pathFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
    return $pathFull.Substring($baseFull.Length).TrimStart('\', '/').Replace("\", "/")
  }
  return $pathFull
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

function Resolve-BundleRoot {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath -PathType Container) {
    return [pscustomobject]@{
      Root = $fullPath
      Cleanup = $false
    }
  }
  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne ".zip") {
      throw "BundlePath file must be a .zip bundle: $(Get-DisplayPath -Path $fullPath)"
    }
    $extractRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-bundle-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $fullPath -DestinationPath $extractRoot -Force
    return [pscustomobject]@{
      Root = $extractRoot
      Cleanup = $true
    }
  }
  throw "BundlePath not found: $(Get-DisplayPath -Path $fullPath)"
}

function Get-BundleManifestRoot {
  param([string]$Root)

  $manifestPath = Join-Path $Root "support-evidence-manifest.json"
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    return $Root
  }

  $nested = @(Get-ChildItem -Path $Root -Recurse -File -Filter "support-evidence-manifest.json")
  if ($nested.Count -eq 1) {
    return (Split-Path -Parent $nested[0].FullName)
  }

  throw "support-evidence-manifest.json was not found at the bundle root."
}

function Invoke-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git -C $RepoRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return (($output | Out-String).Trim())
  } catch {
    return ""
  }
}

function Get-CurrentGitCommitSha {
  $insideGit = (Invoke-GitText -Arguments @("rev-parse", "--is-inside-work-tree")).Trim().ToLowerInvariant()
  if ($insideGit -ne "true") { return "" }

  $commitSha = (Invoke-GitText -Arguments @("rev-parse", "--verify", "HEAD")).Trim().ToLowerInvariant()
  if ($commitSha -notmatch '^[a-f0-9]{40}$') { return "" }
  return $commitSha
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    foreach ($property in $Object.PSObject.Properties) {
      if ($property.Name -ieq $name) {
        return $property.Value
      }
    }
  }
  return $null
}

function Get-StringValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Get-IntegerValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
  try {
    return [int]$value
  } catch {
    return $null
  }
}

function Get-BooleanValue {
  param(
    [object]$Object,
    [string[]]$Names,
    $Default = $null
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value) { return $Default }
  if ($value -is [bool]) { return [bool]$value }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if ($text -in @("true", "1", "yes")) { return $true }
  if ($text -in @("false", "0", "no")) { return $false }
  return $Default
}

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Test-ProductionRecommendedTarget {
  param([object]$Target)

  $nodeRuntimeSupport = Get-PropertyValue -Object $Target -Names @("nodeRuntimeSupport")
  if ($null -eq $nodeRuntimeSupport) { return $false }
  $property = $nodeRuntimeSupport.PSObject.Properties["productionRecommended"]
  return ($property -and $property.Value -is [bool] -and [bool]$property.Value)
}

function Select-MatrixTargets {
  param(
    [string]$MatrixPath,
    [string[]]$TargetId,
    [string[]]$Category,
    [bool]$ProductionRecommendedOnly
  )

  $matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
  $selected = @(Get-ArrayValue $matrix.targets)
  if ($TargetId.Count -gt 0) {
    $wanted = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    $selected = @($selected | Where-Object { $wanted -contains (Normalize-Token ([string]$_.id)) })
    $missing = @($wanted | Where-Object { $targetIdValue = $_; -not @($selected | Where-Object { (Normalize-Token ([string]$_.id)) -eq $targetIdValue }) })
    if ($missing.Count -gt 0) {
      throw "Unknown support matrix target id(s): $($missing -join ', ')"
    }
  }
  if ($Category.Count -gt 0) {
    $wantedCategories = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    $selected = @($selected | Where-Object { $wantedCategories -contains (Normalize-Token ([string]$_.category)) })
  }
  if ($ProductionRecommendedOnly) {
    $selected = @($selected | Where-Object { Test-ProductionRecommendedTarget -Target $_ })
  }
  if ($selected.Count -eq 0) {
    throw "No support matrix targets matched the requested release readiness filters."
  }
  return $selected
}

function Get-SupportScopeKind {
  param(
    [string[]]$SelectedTargetIds,
    [string[]]$AllTargetIds,
    [string[]]$TargetId,
    [string[]]$Category,
    [bool]$ProductionRecommendedOnly
  )

  if ($ProductionRecommendedOnly) {
    return "production-recommended"
  }

  $hasTargetFilter = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0
  $hasCategoryFilter = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0
  if ($hasTargetFilter -or $hasCategoryFilter) {
    return "filtered"
  }

  $missingFromSelection = @($AllTargetIds | Where-Object { $SelectedTargetIds -notcontains $_ })
  $extraInSelection = @($SelectedTargetIds | Where-Object { $AllTargetIds -notcontains $_ })
  if ($missingFromSelection.Count -eq 0 -and $extraInSelection.Count -eq 0) {
    return "full-matrix"
  }

  return "filtered"
}

function Get-ProofLevel {
  param(
    [bool]$StrictCiRelease,
    [bool]$RequireCleanSource,
    [bool]$RequireCurrentCommit,
    [bool]$RequireCiProvenance,
    [bool]$RequireCollectionCiProvenance,
    [bool]$RequireCollectionSourceCommit,
    [bool]$RequireHostEvidenceWorkflowCollection,
    [bool]$RequireRuntimeVersions,
    [bool]$RequireCollectorSha256,
    [int]$RequireMinimumUptimeHours
  )

  if ($StrictCiRelease) {
    return "strict-ci-release"
  }

  if ($RequireCleanSource -or $RequireCurrentCommit -or $RequireCiProvenance -or
    $RequireCollectionCiProvenance -or $RequireCollectionSourceCommit -or
    $RequireHostEvidenceWorkflowCollection -or $RequireRuntimeVersions -or
    $RequireCollectorSha256 -or $RequireMinimumUptimeHours -gt 0) {
    return "hardened-real-host-evidence"
  }

  return "basic-real-host-evidence"
}

function Get-ReleaseClaimKind {
  param(
    [string]$ScopeKind,
    [bool]$StrictCiRelease
  )

  $prefix = if ($StrictCiRelease) { "strict-ci" } else { "provisional" }
  switch ($ScopeKind) {
    "full-matrix" { return "$prefix-full-matrix" }
    "production-recommended" { return "$prefix-production-runtime" }
    "filtered" { return "$prefix-filtered" }
    default { return "$prefix-$ScopeKind" }
  }
}

function Test-SafeRuntimeVersionValue {
  param([string]$Value)

  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $false }
  if ($text.Length -gt 80) { return $false }
  return ($text -match '^[A-Za-z0-9._+:-]+$')
}

function Test-SafeSha256Value {
  param([string]$Value)
  return (([string]$Value).Trim().ToLowerInvariant() -match '^[a-f0-9]{64}$')
}

function Test-SafeGitShaValue {
  param([string]$Value)
  return (([string]$Value).Trim().ToLowerInvariant() -match '^[a-f0-9]{40}$')
}

function Test-NumericText {
  param([string]$Value)
  return (([string]$Value).Trim() -match '^[0-9]+$')
}

function Test-SafeCiRefName {
  param([string]$Value)
  $text = ([string]$Value).Trim()
  return (-not [string]::IsNullOrWhiteSpace($text) -and $text -cmatch '^[A-Za-z0-9._/-]+$')
}

function Add-OrSetNoteProperty {
  param(
    [object]$Object,
    [string]$Name,
    $Value
  )

  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Set-TestCollectionCiProvenance {
  param(
    [string]$BundleRoot,
    [string]$CommitSha,
    [string]$WorkflowName = "host-evidence",
    [string]$EventName = "workflow_dispatch"
  )

  $manifestPath = Join-Path $BundleRoot "support-evidence-manifest.json"
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $manifestMatrixPath = ([string]$manifest.matrixPath).Trim().Replace("\", "/")
  $manifestMatrixSha256 = ([string]$manifest.matrixSha256).Trim().ToLowerInvariant()
  foreach ($row in @($manifest.files)) {
    $relative = ([string]$row.path).Replace("/", "\")
    $evidencePath = Join-Path $BundleRoot $relative
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $collection = Get-PropertyValue -Object $evidence -Names @("EvidenceCollection", "evidenceCollection")
    if ($null -eq $collection) {
      throw "Self-test evidence file is missing evidenceCollection: $(Get-DisplayPath -Path $evidencePath)"
    }
    Add-OrSetNoteProperty -Object $collection -Name "ci" -Value ([pscustomobject]@{
        isCi = $true
        provider = "github-actions"
        workflowName = $WorkflowName
        runId = "123456"
        runAttempt = "1"
        eventName = $EventName
        refName = "main"
        sha = $CommitSha
      })
    $targetId = [string]$row.supportTargetId
    $nextJsMode = [string]$row.nextJsMode
    $serviceManager = [string]$row.serviceManager
    $reverseProxy = [string]$row.reverseProxy
    $evidenceBaseName = "$targetId-$nextJsMode-$serviceManager-$reverseProxy"
    $evidenceName = if ([System.IO.Path]::GetFileNameWithoutExtension($relative).EndsWith("-fallback")) { "$evidenceBaseName-fallback" } else { $evidenceBaseName }
    $minimumUptimeHoursValue = Get-PropertyValue -Object $row -Names @("requiredMinimumUptimeHours")
    $minimumUptimeHours = if ($null -ne $minimumUptimeHoursValue -and -not [string]::IsNullOrWhiteSpace([string]$minimumUptimeHoursValue)) {
      [string]$minimumUptimeHoursValue
    } else {
      [string](Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath)
    }
    Add-OrSetNoteProperty -Object $collection -Name "workflowDispatch" -Value ([pscustomobject]@{
        evidenceName = $evidenceName
        expectedTargetId = $targetId
        expectedNextJsMode = $nextJsMode
        expectedServiceManager = $serviceManager
        expectedReverseProxy = $reverseProxy
        minimumUptimeHours = $minimumUptimeHours
        supportMatrixPath = $manifestMatrixPath
        supportMatrixSha256 = $manifestMatrixSha256
      })
    ($evidence | ConvertTo-Json -Depth 12) | Set-Content -Path $evidencePath -Encoding UTF8

    $row.sha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $row.bytes = (Get-Item -LiteralPath $evidencePath).Length
    Add-OrSetNoteProperty -Object $row -Name "collectionCiIsCi" -Value $true
    Add-OrSetNoteProperty -Object $row -Name "collectionCiProvider" -Value "github-actions"
    Add-OrSetNoteProperty -Object $row -Name "collectionCiWorkflowName" -Value $WorkflowName
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRunId" -Value "123456"
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRunAttempt" -Value "1"
    Add-OrSetNoteProperty -Object $row -Name "collectionCiEventName" -Value $EventName
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRefName" -Value "main"
    Add-OrSetNoteProperty -Object $row -Name "collectionCiSha" -Value $CommitSha
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchEvidenceName" -Value $evidenceName
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedTargetId" -Value $targetId
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedNextJsMode" -Value $nextJsMode
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedServiceManager" -Value $serviceManager
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedReverseProxy" -Value $reverseProxy
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchMinimumUptimeHours" -Value $minimumUptimeHours
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchSupportMatrixPath" -Value $manifestMatrixPath
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchSupportMatrixSha256" -Value $manifestMatrixSha256
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchMatchesDimensions" -Value $true
  }
  ($manifest | ConvertTo-Json -Depth 12) | Set-Content -Path $manifestPath -Encoding UTF8
}

function Remove-TestCollectionCiProvenanceFromLocalOnlyRows {
  param([string]$BundleRoot)

  $manifestPath = Join-Path $BundleRoot "support-evidence-manifest.json"
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $updatedCount = 0
  foreach ($row in @($manifest.files)) {
    $localCommandOnly = Get-BooleanValue -Object $row -Names @("localCommandOnly") -Default $false
    if ($localCommandOnly -ne $true) {
      continue
    }

    $relative = ([string]$row.path).Replace("/", "\")
    $evidencePath = Join-Path $BundleRoot $relative
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $collection = Get-PropertyValue -Object $evidence -Names @("EvidenceCollection", "evidenceCollection")
    if ($null -eq $collection) {
      throw "Self-test evidence file is missing evidenceCollection: $(Get-DisplayPath -Path $evidencePath)"
    }
    foreach ($ciProperty in @("Ci", "ci")) {
      if ($collection.PSObject.Properties[$ciProperty]) {
        $collection.PSObject.Properties.Remove($ciProperty)
      }
    }
    foreach ($dispatchProperty in @("WorkflowDispatch", "workflowDispatch")) {
      if ($collection.PSObject.Properties[$dispatchProperty]) {
        $collection.PSObject.Properties.Remove($dispatchProperty)
      }
    }
    ($evidence | ConvertTo-Json -Depth 12) | Set-Content -Path $evidencePath -Encoding UTF8

    $row.sha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $row.bytes = (Get-Item -LiteralPath $evidencePath).Length
    Add-OrSetNoteProperty -Object $row -Name "collectionCiIsCi" -Value $null
    Add-OrSetNoteProperty -Object $row -Name "collectionCiProvider" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiWorkflowName" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRunId" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRunAttempt" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiEventName" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiRefName" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionCiSha" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchEvidenceName" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedTargetId" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedNextJsMode" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedServiceManager" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchExpectedReverseProxy" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchMinimumUptimeHours" -Value $null
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchSupportMatrixPath" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchSupportMatrixSha256" -Value ""
    Add-OrSetNoteProperty -Object $row -Name "collectionWorkflowDispatchMatchesDimensions" -Value $null
    $updatedCount += 1
  }
  if ($updatedCount -lt 1) {
    throw "Self-test did not find local-command-only rows to clear."
  }
  ($manifest | ConvertTo-Json -Depth 12) | Set-Content -Path $manifestPath -Encoding UTF8
}

function Set-TestBundleCiProvenance {
  param(
    [string]$BundleRoot,
    [string]$WorkflowName = "support-evidence-bundle",
    [string]$EventName = "workflow_dispatch"
  )

  $manifestPath = Join-Path $BundleRoot "support-evidence-manifest.json"
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $sourceCommitSha = ([string]$manifest.sourceControl.commitSha).Trim().ToLowerInvariant()
  if ($sourceCommitSha -notmatch '^[a-f0-9]{40}$') {
    throw "Self-test bundle source-control commit SHA is invalid."
  }
  $manifest.sourceControl.trackedDirty = $false
  $manifest.ci.isCi = $true
  $manifest.ci.provider = "github-actions"
  $manifest.ci.workflowName = $WorkflowName
  $manifest.ci.runId = "123456"
  $manifest.ci.runAttempt = "1"
  $manifest.ci.eventName = $EventName
  $manifest.ci.refName = "main"
  $manifest.ci.sha = $sourceCommitSha
  ($manifest | ConvertTo-Json -Depth 12) | Set-Content -Path $manifestPath -Encoding UTF8
}

function Invoke-ExpectReadinessFailure {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )

  $failed = $false
  try {
    & $Action
  } catch {
    $failed = $true
    if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
      throw "Expected release readiness failure containing '$ExpectedMessage', got: $($_.Exception.Message)"
    }
  }

  if (-not $failed) {
    throw "Expected release readiness failure containing '$ExpectedMessage', but validation succeeded."
  }
}

function ConvertTo-ReadinessCoverageRows {
  param([object[]]$Rows)

  $converted = New-Object System.Collections.Generic.List[object]
  foreach ($row in @($Rows)) {
    $requiredMinimumUptimeHoursValue = Get-PropertyValue -Object $row -Names @("requiredMinimumUptimeHours")
    $requiredMinimumUptimeHours = 0
    if ($null -ne $requiredMinimumUptimeHoursValue -and -not [string]::IsNullOrWhiteSpace([string]$requiredMinimumUptimeHoursValue)) {
      $requiredMinimumUptimeHours = [int]$requiredMinimumUptimeHoursValue
    }

    $nodeRuntimeRequirements = @(Get-ArrayValue (Get-PropertyValue -Object $row -Names @("nodeRuntimeRequirements")))
    $converted.Add([pscustomobject]@{
        status = Get-StringValue -Object $row -Names @("status")
        kind = Get-StringValue -Object $row -Names @("kind")
        targetId = Get-StringValue -Object $row -Names @("targetId")
        nextJsMode = Get-StringValue -Object $row -Names @("nextJsMode")
        serviceManager = Get-StringValue -Object $row -Names @("serviceManager")
        reverseProxy = Get-StringValue -Object $row -Names @("reverseProxy")
        nodeRuntimeMinimumNodeVersion = Get-StringValue -Object $row -Names @("nodeRuntimeMinimumNodeVersion")
        nodeRuntimeSupportTier = Get-StringValue -Object $row -Names @("nodeRuntimeSupportTier")
        nodeRuntimeProductionRecommended = Get-BooleanValue -Object $row -Names @("nodeRuntimeProductionRecommended") -Default $null
        nodeRuntimeRequirements = $nodeRuntimeRequirements
        requiredMinimumUptimeHours = $requiredMinimumUptimeHours
        evidenceFile = Get-StringValue -Object $row -Names @("evidenceFile")
        file = Get-StringValue -Object $row -Names @("file")
        collectionCommand = Get-StringValue -Object $row -Names @("collectionCommand")
        validationCommand = Get-StringValue -Object $row -Names @("validationCommand")
        workflowDispatchSupported = Get-BooleanValue -Object $row -Names @("workflowDispatchSupported") -Default $null
        localCommandOnly = Get-BooleanValue -Object $row -Names @("localCommandOnly") -Default $null
        workflowInputSummary = Get-StringValue -Object $row -Names @("workflowInputSummary")
        workflowDispatchCommand = Get-StringValue -Object $row -Names @("workflowDispatchCommand")
      }) | Out-Null
  }
  return @($converted | ForEach-Object { $_ })
}

if ($SelfTest) {
  Write-Step "Release support readiness self-test setup"
  if ((Format-CoveragePercent 100) -ne "100.00%" -or (Format-CoveragePercent 0) -ne "0.00%" -or (Format-CoveragePercent $null) -ne "n/a") {
    throw "Release support readiness self-test failed: coverage percentage formatter returned unexpected output."
  }
  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-selftest-$([Guid]::NewGuid().ToString('N'))"
  $coverageJson = Join-Path $selfTestRoot "coverage.json"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null
  $selfTestTargetIds = @("windows-10", "windows-server-2022", "ubuntu", "macos", "freebsd")

  function Invoke-SelfTestReadiness {
    param(
      [string]$BundlePath,
      [switch]$IncludeServiceOnly,
      [switch]$IncludeFallback,
      [ValidateSet("Table", "Json")]
      [string]$Format = "Table",
      [string]$OutputPath = "",
      [switch]$ProductionRecommendedOnly,
      [switch]$RequireProductionRecommendedRuntime,
      [switch]$RequireCleanSource,
      [switch]$RequireCurrentCommit,
      [switch]$RequireCiProvenance,
      [switch]$RequireCollectionCiProvenance,
      [switch]$RequireCollectionSourceCommit,
      [switch]$RequireHostEvidenceWorkflowCollection,
      [switch]$RequireRuntimeVersions,
      [switch]$RequireCollectorSha256,
      [int]$RequireMinimumUptimeHours = 0,
      [switch]$StrictCiRelease,
      [switch]$RequireFinalFullMatrixReleaseClaim,
      [switch]$AllowWarnings
    )

    $readinessArgs = @{
      MatrixPath = $MatrixPath
      TargetId = [string[]]$selfTestTargetIds
      BundlePath = $BundlePath
    }
    if ($IncludeServiceOnly) { $readinessArgs.IncludeServiceOnly = $true }
    if ($IncludeFallback) { $readinessArgs.IncludeFallback = $true }
    if ($Format -ne "Table") { $readinessArgs.Format = $Format }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $readinessArgs.OutputPath = $OutputPath }
    if ($ProductionRecommendedOnly) { $readinessArgs.ProductionRecommendedOnly = $true }
    if ($RequireProductionRecommendedRuntime) { $readinessArgs.RequireProductionRecommendedRuntime = $true }
    if ($RequireCleanSource) { $readinessArgs.RequireCleanSource = $true }
    if ($RequireCurrentCommit) { $readinessArgs.RequireCurrentCommit = $true }
    if ($RequireCiProvenance) { $readinessArgs.RequireCiProvenance = $true }
    if ($RequireCollectionCiProvenance) { $readinessArgs.RequireCollectionCiProvenance = $true }
    if ($RequireCollectionSourceCommit) { $readinessArgs.RequireCollectionSourceCommit = $true }
    if ($RequireHostEvidenceWorkflowCollection) { $readinessArgs.RequireHostEvidenceWorkflowCollection = $true }
    if ($RequireRuntimeVersions) { $readinessArgs.RequireRuntimeVersions = $true }
    if ($RequireCollectorSha256) { $readinessArgs.RequireCollectorSha256 = $true }
    if ($RequireMinimumUptimeHours -gt 0) { $readinessArgs.RequireMinimumUptimeHours = $RequireMinimumUptimeHours }
    if ($StrictCiRelease) { $readinessArgs.StrictCiRelease = $true }
    if ($RequireFinalFullMatrixReleaseClaim) { $readinessArgs.RequireFinalFullMatrixReleaseClaim = $true }
    if ($AllowWarnings) { $readinessArgs.AllowWarnings = $true }

    & $PSCommandPath @readinessArgs | Out-Null
  }

  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") -SelfTest -MatrixPath $MatrixPath -TargetId $selfTestTargetIds -Format Json -OutputPath $coverageJson | Out-Null
  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  $evidencePath = Resolve-DisplayPath -Path ([string]$coverage.evidencePath)

  $bundleOutput = Join-Path $selfTestRoot "bundles"
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") `
    -EvidencePath $evidencePath `
    -MatrixPath $MatrixPath `
    -TargetId $selfTestTargetIds `
    -OutputDirectory $bundleOutput `
    -BundleName "selftest-release-support-readiness" `
    -ValidateSupportClaim `
    -RequireBothNextJsModes `
    -RequireDeclaredServiceManagers `
    -RequireDeclaredReverseProxies `
    -RequireCoverageComplete `
    -IncludeServiceOnly `
    -IncludeFallback `
    -AllowReverseProxyNone | Out-Null

  $BundlePath = Join-Path $bundleOutput "selftest-release-support-readiness.zip"
  $strictOnlyEvidencePath = Join-Path $selfTestRoot "strict-only-evidence"
  New-Item -ItemType Directory -Force -Path $strictOnlyEvidencePath | Out-Null
  Get-ChildItem -LiteralPath $evidencePath -Filter "*.json" -File |
    Where-Object { $_.Name -notlike "service-only-*" -and $_.Name -notlike "fallback-*" } |
    Copy-Item -Destination $strictOnlyEvidencePath
  $strictOnlyBundleOutput = Join-Path $selfTestRoot "strict-only-bundles"
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") `
    -EvidencePath $strictOnlyEvidencePath `
    -MatrixPath $MatrixPath `
    -TargetId $selfTestTargetIds `
    -OutputDirectory $strictOnlyBundleOutput `
    -BundleName "selftest-release-support-readiness-strict-only" `
    -ValidateSupportClaim `
    -RequireBothNextJsModes `
    -RequireDeclaredServiceManagers `
    -RequireDeclaredReverseProxies `
    -RequireCoverageComplete | Out-Null
  $strictOnlyBundlePath = Join-Path $strictOnlyBundleOutput "selftest-release-support-readiness-strict-only.zip"
  $MaxEvidenceAgeDays = 30
  $selfTestRequiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath

  $readinessJsonPath = Join-Path $selfTestRoot "readiness.json"
  Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -Format Json -OutputPath $readinessJsonPath
  $readinessJson = Get-Content -LiteralPath $readinessJsonPath -Raw | ConvertFrom-Json
  if ([System.IO.Path]::IsPathRooted([string]$readinessJson.bundlePath) -or ([string]$readinessJson.bundlePath).Contains($RepoRoot)) {
    throw "Release support readiness self-test failed: readiness JSON leaked an absolute bundlePath."
  }
  if ([int]$readinessJson.coverage.coveredCount -ne @($readinessJson.coverage.covered).Count) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve covered coverage rows."
  }
  if ([int]$readinessJson.coverage.missingCount -ne @($readinessJson.coverage.missing).Count) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve missing coverage rows."
  }
  if ([string]$readinessJson.coverage.coveragePercentDisplay -ne "100.00%") {
    throw "Release support readiness self-test failed: readiness JSON did not include formatted coverage percent."
  }
  if ($readinessJson.coverage.failOnWarningsDuringCollection -ne $true) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve strict warning collection policy."
  }
  $firstCoveredRow = @($readinessJson.coverage.covered | Select-Object -First 1)[0]
  foreach ($requiredProperty in @("evidenceFile", "file", "collectionCommand", "validationCommand", "requiredMinimumUptimeHours", "workflowDispatchSupported", "localCommandOnly", "workflowInputSummary", "workflowDispatchCommand")) {
    if (-not $firstCoveredRow.PSObject.Properties[$requiredProperty]) {
      throw "Release support readiness self-test failed: readiness coverage row is missing $requiredProperty."
    }
  }
  if (-not ([string]$firstCoveredRow.validationCommand).Contains("Test-HostEvidence.ps1")) {
    throw "Release support readiness self-test failed: readiness coverage row is missing the host evidence validation command."
  }
  if (-not ([string]$firstCoveredRow.validationCommand).Contains("-EvidencePath .\$(([string]$firstCoveredRow.evidenceFile).Replace('/', '\'))")) {
    throw "Release support readiness self-test failed: readiness coverage row validation command is not tied to its evidence file."
  }
  $firstWorkflowCoveredRow = @($readinessJson.coverage.covered | Where-Object { $_.workflowDispatchSupported -eq $true } | Select-Object -First 1)[0]
  if ($null -eq $firstWorkflowCoveredRow -or -not ([string]$firstWorkflowCoveredRow.workflowDispatchCommand).Contains("gh workflow run")) {
    throw "Release support readiness self-test failed: readiness coverage rows did not preserve workflow dispatch commands."
  }
  $firstLocalOnlyCoveredRow = @($readinessJson.coverage.covered | Where-Object { $_.localCommandOnly -eq $true } | Select-Object -First 1)[0]
  if ($null -eq $firstLocalOnlyCoveredRow -or $firstLocalOnlyCoveredRow.workflowDispatchSupported -eq $true) {
    throw "Release support readiness self-test failed: readiness coverage rows did not preserve local-command-only metadata."
  }
  if (-not $readinessJson.PSObject.Properties["supportScope"]) {
    throw "Release support readiness self-test failed: readiness JSON is missing supportScope metadata."
  }
  if ([string]$readinessJson.supportScope.kind -ne "filtered") {
    throw "Release support readiness self-test failed: self-test readiness scope should be filtered."
  }
  if ([string]$readinessJson.supportScope.proofLevel -ne "basic-real-host-evidence") {
    throw "Release support readiness self-test failed: readiness JSON did not preserve the proof level."
  }
  if ([int]$readinessJson.supportScope.selectedTargetCount -ne @($selfTestTargetIds).Count) {
    throw "Release support readiness self-test failed: readiness JSON selected target count is incorrect."
  }
  if ([int]$readinessJson.supportScope.matrixTargetCount -le [int]$readinessJson.supportScope.selectedTargetCount) {
    throw "Release support readiness self-test failed: readiness JSON did not distinguish filtered scope from full matrix scope."
  }
  if ([int]$readinessJson.supportScope.localCommandOnlyEvidenceCount -le 0) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve local-command-only evidence counts."
  }
  if (-not $readinessJson.PSObject.Properties["releaseClaim"]) {
    throw "Release support readiness self-test failed: readiness JSON is missing releaseClaim metadata."
  }
  if ([string]$readinessJson.releaseClaim.kind -ne "provisional-filtered") {
    throw "Release support readiness self-test failed: provisional release claim kind is incorrect."
  }
  if ($readinessJson.releaseClaim.finalFullMatrixReleaseClaim -ne $false) {
    throw "Release support readiness self-test failed: filtered provisional evidence must not be a final full-matrix release claim."
  }
  if (-not $readinessJson.releaseClaim.PSObject.Properties["requirements"]) {
    throw "Release support readiness self-test failed: releaseClaim requirements are missing."
  }
  if ($readinessJson.releaseClaim.requirements.coverageComplete -ne $true -or $readinessJson.releaseClaim.requirements.fullMatrixScope -ne $false) {
    throw "Release support readiness self-test failed: releaseClaim requirements do not explain filtered readiness."
  }
  if ($readinessJson.releaseClaim.requirements.nonSyntheticEvidenceRequired -ne $true) {
    throw "Release support readiness self-test failed: releaseClaim requirements did not record non-synthetic evidence enforcement."
  }
  if ($readinessJson.releaseClaim.requirements.uniqueEvidencePayloadsRequired -ne $true) {
    throw "Release support readiness self-test failed: releaseClaim requirements did not record unique evidence payload enforcement."
  }
  if ($readinessJson.releaseClaim.requirements.workflowApplicabilityKnown -ne $true) {
    throw "Release support readiness self-test failed: releaseClaim requirements did not record workflow applicability."
  }
  if ($readinessJson.releaseClaim.requirements.runtimeSupportMetadataKnown -ne $true) {
    throw "Release support readiness self-test failed: releaseClaim requirements did not record runtime support metadata."
  }
  if ([int]$readinessJson.releaseClaim.requirements.maxEvidenceAgeDaysRequired -ne 30) {
    throw "Release support readiness self-test failed: releaseClaim requirements did not record max evidence age."
  }
  if (-not $readinessJson.PSObject.Properties["sourceControl"] -or -not ([string]$readinessJson.sourceControl.commitSha)) {
    throw "Release support readiness self-test failed: readiness JSON is missing sourceControl provenance."
  }
  if (-not $readinessJson.PSObject.Properties["bundleCi"]) {
    throw "Release support readiness self-test failed: readiness JSON is missing bundleCi provenance."
  }
  if (-not $readinessJson.PSObject.Properties["bundleSupportScope"]) {
    throw "Release support readiness self-test failed: readiness JSON is missing bundleSupportScope metadata."
  }
  if ([string]$readinessJson.bundleSupportScope.kind -ne "filtered") {
    throw "Release support readiness self-test failed: bundleSupportScope.kind should preserve the saved bundle scope."
  }
  if ([string]$readinessJson.bundleSupportScope.proofLevel -ne "basic-real-host-evidence") {
    throw "Release support readiness self-test failed: bundleSupportScope.proofLevel should preserve the saved bundle proof level."
  }
  if ([int]$readinessJson.bundleSupportScope.selectedTargetCount -ne @($selfTestTargetIds).Count) {
    throw "Release support readiness self-test failed: bundleSupportScope selected target count is incorrect."
  }
  if ([int]$readinessJson.bundle.collectionWorkflowDispatchMatchCount -le 0 -or [int]$readinessJson.bundle.collectionWorkflowDispatchMismatchCount -ne 0) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve matching workflow dispatch manifest metadata."
  }
  Invoke-ExpectReadinessFailure -ExpectedMessage "Support evidence coverage" -Action {
    Invoke-SelfTestReadiness -BundlePath $strictOnlyBundlePath -IncludeServiceOnly -IncludeFallback
  }

  $matrixMismatchRoot = Join-Path $selfTestRoot "matrix-mismatch"
  New-Item -ItemType Directory -Force -Path $matrixMismatchRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $matrixMismatchRoot -Force
  $matrixMismatchManifestPath = Join-Path $matrixMismatchRoot "support-evidence-manifest.json"
  $matrixMismatchManifest = Get-Content -LiteralPath $matrixMismatchManifestPath -Raw | ConvertFrom-Json
  $matrixMismatchManifest.matrixSha256 = ("0" * 64)
  ($matrixMismatchManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $matrixMismatchManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "matrixSha256 must match" -Action {
    Invoke-SelfTestReadiness -BundlePath $matrixMismatchRoot -IncludeServiceOnly -IncludeFallback
  }

  $dirtySourceRoot = Join-Path $selfTestRoot "dirty-source"
  New-Item -ItemType Directory -Force -Path $dirtySourceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $dirtySourceRoot -Force
  $dirtySourceManifestPath = Join-Path $dirtySourceRoot "support-evidence-manifest.json"
  $dirtySourceManifest = Get-Content -LiteralPath $dirtySourceManifestPath -Raw | ConvertFrom-Json
  $dirtySourceManifest.sourceControl.trackedDirty = $true
  ($dirtySourceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $dirtySourceManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle source-control provenance reports tracked dirty files" -Action {
    Invoke-SelfTestReadiness -BundlePath $dirtySourceRoot -IncludeServiceOnly -IncludeFallback -RequireCleanSource
  }

  $nonGitSourceRoot = Join-Path $selfTestRoot "non-git-source"
  New-Item -ItemType Directory -Force -Path $nonGitSourceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $nonGitSourceRoot -Force
  $nonGitSourceManifestPath = Join-Path $nonGitSourceRoot "support-evidence-manifest.json"
  $nonGitSourceManifest = Get-Content -LiteralPath $nonGitSourceManifestPath -Raw | ConvertFrom-Json
  $nonGitSourceManifest.sourceControl.isGitRepository = $false
  ($nonGitSourceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $nonGitSourceManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "source-control provenance must report isGitRepository=true" -Action {
    Invoke-SelfTestReadiness -BundlePath $nonGitSourceRoot -IncludeServiceOnly -IncludeFallback -RequireCurrentCommit
  }

  $commitMismatchRoot = Join-Path $selfTestRoot "commit-mismatch"
  New-Item -ItemType Directory -Force -Path $commitMismatchRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $commitMismatchRoot -Force
  $commitMismatchManifestPath = Join-Path $commitMismatchRoot "support-evidence-manifest.json"
  $commitMismatchManifest = Get-Content -LiteralPath $commitMismatchManifestPath -Raw | ConvertFrom-Json
  $mismatchedCommitSha = ("0" * 40)
  $commitMismatchManifest.sourceControl.commitSha = $mismatchedCommitSha
  if ($commitMismatchManifest.PSObject.Properties["ci"] -and $commitMismatchManifest.ci -and $commitMismatchManifest.ci.PSObject.Properties["sha"]) {
    $commitMismatchManifest.ci.sha = $mismatchedCommitSha
  }
  ($commitMismatchManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $commitMismatchManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle source-control commit SHA does not match current repository HEAD" -Action {
    Invoke-SelfTestReadiness -BundlePath $commitMismatchRoot -IncludeServiceOnly -IncludeFallback -RequireCurrentCommit
  }

  $missingCiProvenanceRoot = Join-Path $selfTestRoot "missing-ci-provenance"
  New-Item -ItemType Directory -Force -Path $missingCiProvenanceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingCiProvenanceRoot -Force
  $missingCiProvenanceManifestPath = Join-Path $missingCiProvenanceRoot "support-evidence-manifest.json"
  $missingCiProvenanceManifest = Get-Content -LiteralPath $missingCiProvenanceManifestPath -Raw | ConvertFrom-Json
  $missingCiProvenanceManifest.ci.isCi = $false
  $missingCiProvenanceManifest.ci.provider = ""
  ($missingCiProvenanceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingCiProvenanceManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle CI provenance is required" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingCiProvenanceRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance
  }

  $completeCiProvenanceRoot = Join-Path $selfTestRoot "complete-ci-provenance"
  New-Item -ItemType Directory -Force -Path $completeCiProvenanceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $completeCiProvenanceRoot -Force
  $completeCiProvenanceManifestPath = Join-Path $completeCiProvenanceRoot "support-evidence-manifest.json"
  $completeCiProvenanceManifest = Get-Content -LiteralPath $completeCiProvenanceManifestPath -Raw | ConvertFrom-Json
  $completeCiProvenanceManifest.ci.isCi = $true
  $completeCiProvenanceManifest.ci.provider = "github-actions"
  $completeCiProvenanceManifest.ci.workflowName = "support-evidence-bundle"
  $completeCiProvenanceManifest.ci.runId = "123456"
  $completeCiProvenanceManifest.ci.runAttempt = "1"
  $completeCiProvenanceManifest.ci.eventName = "workflow_dispatch"
  $completeCiProvenanceManifest.ci.refName = "main"
  $completeCiProvenanceManifest.ci.sha = $completeCiProvenanceManifest.sourceControl.commitSha
  ($completeCiProvenanceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $completeCiProvenanceManifestPath -Encoding UTF8
  Invoke-SelfTestReadiness -BundlePath $completeCiProvenanceRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance

  $badCiWorkflowRoot = Join-Path $selfTestRoot "bad-ci-workflow"
  New-Item -ItemType Directory -Force -Path $badCiWorkflowRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $badCiWorkflowRoot -Force
  $badCiWorkflowManifestPath = Join-Path $badCiWorkflowRoot "support-evidence-manifest.json"
  $badCiWorkflowManifest = Get-Content -LiteralPath $badCiWorkflowManifestPath -Raw | ConvertFrom-Json
  $badCiWorkflowManifest.ci.isCi = $true
  $badCiWorkflowManifest.ci.provider = "github-actions"
  $badCiWorkflowManifest.ci.workflowName = "other-workflow"
  $badCiWorkflowManifest.ci.runId = "123456"
  $badCiWorkflowManifest.ci.runAttempt = "1"
  $badCiWorkflowManifest.ci.eventName = "workflow_dispatch"
  $badCiWorkflowManifest.ci.refName = "main"
  $badCiWorkflowManifest.ci.sha = $badCiWorkflowManifest.sourceControl.commitSha
  ($badCiWorkflowManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $badCiWorkflowManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle CI workflowName must be support-evidence-bundle" -Action {
    Invoke-SelfTestReadiness -BundlePath $badCiWorkflowRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance
  }

  $badCiEventRoot = Join-Path $selfTestRoot "bad-ci-event"
  New-Item -ItemType Directory -Force -Path $badCiEventRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $badCiEventRoot -Force
  $badCiEventManifestPath = Join-Path $badCiEventRoot "support-evidence-manifest.json"
  $badCiEventManifest = Get-Content -LiteralPath $badCiEventManifestPath -Raw | ConvertFrom-Json
  $badCiEventManifest.ci.isCi = $true
  $badCiEventManifest.ci.provider = "github-actions"
  $badCiEventManifest.ci.workflowName = "support-evidence-bundle"
  $badCiEventManifest.ci.runId = "123456"
  $badCiEventManifest.ci.runAttempt = "1"
  $badCiEventManifest.ci.eventName = "push"
  $badCiEventManifest.ci.refName = "main"
  $badCiEventManifest.ci.sha = $badCiEventManifest.sourceControl.commitSha
  ($badCiEventManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $badCiEventManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle CI eventName must be workflow_dispatch" -Action {
    Invoke-SelfTestReadiness -BundlePath $badCiEventRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance
  }

  $missingCollectionCiRoot = Join-Path $selfTestRoot "missing-collection-ci-provenance"
  New-Item -ItemType Directory -Force -Path $missingCollectionCiRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingCollectionCiRoot -Force
  $missingCollectionCiManifestPath = Join-Path $missingCollectionCiRoot "support-evidence-manifest.json"
  $missingCollectionCiManifest = Get-Content -LiteralPath $missingCollectionCiManifestPath -Raw | ConvertFrom-Json
  $missingCollectionCiRow = @($missingCollectionCiManifest.files | Where-Object { $_.workflowDispatchSupported -eq $true } | Select-Object -First 1)[0]
  $missingCollectionCiRelative = ([string]$missingCollectionCiRow.path).Replace("/", "\")
  $missingCollectionCiEvidencePath = Join-Path $missingCollectionCiRoot $missingCollectionCiRelative
  $missingCollectionCiEvidence = Get-Content -LiteralPath $missingCollectionCiEvidencePath -Raw | ConvertFrom-Json
  $missingCollectionCiEvidenceCollection = Get-PropertyValue -Object $missingCollectionCiEvidence -Names @("EvidenceCollection", "evidenceCollection")
  foreach ($ciProperty in @("Ci", "ci")) {
    if ($missingCollectionCiEvidenceCollection.PSObject.Properties[$ciProperty]) {
      $missingCollectionCiEvidenceCollection.PSObject.Properties.Remove($ciProperty)
    }
  }
  ($missingCollectionCiEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $missingCollectionCiEvidencePath -Encoding UTF8
  $missingCollectionCiRow.sha256 = (Get-FileHash -LiteralPath $missingCollectionCiEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $missingCollectionCiRow.bytes = (Get-Item -LiteralPath $missingCollectionCiEvidencePath).Length
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiIsCi" -Value $null
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiProvider" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiWorkflowName" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiRunId" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiRunAttempt" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiEventName" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiRefName" -Value ""
  Add-OrSetNoteProperty -Object $missingCollectionCiRow -Name "collectionCiSha" -Value ""
  ($missingCollectionCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $missingCollectionCiManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection CI provenance is required" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingCollectionCiRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance
  }

  $completeCollectionCiRoot = Join-Path $selfTestRoot "complete-collection-ci-provenance"
  New-Item -ItemType Directory -Force -Path $completeCollectionCiRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $completeCollectionCiRoot -Force
  $completeCollectionCiManifestPath = Join-Path $completeCollectionCiRoot "support-evidence-manifest.json"
  $completeCollectionCiManifest = Get-Content -LiteralPath $completeCollectionCiManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $completeCollectionCiRoot -CommitSha $completeCollectionCiManifest.sourceControl.commitSha
  Invoke-SelfTestReadiness -BundlePath $completeCollectionCiRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireCollectionSourceCommit -RequireHostEvidenceWorkflowCollection

  $unsafeCollectionRefRoot = Join-Path $selfTestRoot "unsafe-collection-ref"
  New-Item -ItemType Directory -Force -Path $unsafeCollectionRefRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $unsafeCollectionRefRoot -Force
  $unsafeCollectionRefManifestPath = Join-Path $unsafeCollectionRefRoot "support-evidence-manifest.json"
  $unsafeCollectionRefManifest = Get-Content -LiteralPath $unsafeCollectionRefManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $unsafeCollectionRefRoot -CommitSha $unsafeCollectionRefManifest.sourceControl.commitSha
  $unsafeCollectionRefManifest = Get-Content -LiteralPath $unsafeCollectionRefManifestPath -Raw | ConvertFrom-Json
  $unsafeCollectionRefRow = @($unsafeCollectionRefManifest.files | Where-Object { $_.workflowDispatchSupported -eq $true } | Select-Object -First 1)[0]
  $unsafeCollectionRefRelative = ([string]$unsafeCollectionRefRow.path).Replace("/", "\")
  $unsafeCollectionRefEvidencePath = Join-Path $unsafeCollectionRefRoot $unsafeCollectionRefRelative
  $unsafeCollectionRefEvidence = Get-Content -LiteralPath $unsafeCollectionRefEvidencePath -Raw | ConvertFrom-Json
  $unsafeCollectionRefCollection = Get-PropertyValue -Object $unsafeCollectionRefEvidence -Names @("EvidenceCollection", "evidenceCollection")
  $unsafeCollectionRefCi = Get-PropertyValue -Object $unsafeCollectionRefCollection -Names @("Ci", "ci")
  Add-OrSetNoteProperty -Object $unsafeCollectionRefCi -Name "refName" -Value ""
  ($unsafeCollectionRefEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $unsafeCollectionRefEvidencePath -Encoding UTF8
  $unsafeCollectionRefRow.sha256 = (Get-FileHash -LiteralPath $unsafeCollectionRefEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $unsafeCollectionRefRow.bytes = (Get-Item -LiteralPath $unsafeCollectionRefEvidencePath).Length
  Add-OrSetNoteProperty -Object $unsafeCollectionRefRow -Name "collectionCiRefName" -Value ""
  ($unsafeCollectionRefManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $unsafeCollectionRefManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "collection ci.refName" -Action {
    Invoke-SelfTestReadiness -BundlePath $unsafeCollectionRefRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance
  }

  $mismatchCollectionCommitRoot = Join-Path $selfTestRoot "mismatch-collection-commit"
  New-Item -ItemType Directory -Force -Path $mismatchCollectionCommitRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $mismatchCollectionCommitRoot -Force
  Set-TestCollectionCiProvenance -BundleRoot $mismatchCollectionCommitRoot -CommitSha ("0" * 40)
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection CI commit SHA must match bundle source-control commit SHA" -Action {
    Invoke-SelfTestReadiness -BundlePath $mismatchCollectionCommitRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireCollectionSourceCommit
  }

  $mismatchCollectionWorkflowRoot = Join-Path $selfTestRoot "mismatch-collection-workflow"
  New-Item -ItemType Directory -Force -Path $mismatchCollectionWorkflowRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $mismatchCollectionWorkflowRoot -Force
  $mismatchCollectionWorkflowManifestPath = Join-Path $mismatchCollectionWorkflowRoot "support-evidence-manifest.json"
  $mismatchCollectionWorkflowManifest = Get-Content -LiteralPath $mismatchCollectionWorkflowManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $mismatchCollectionWorkflowRoot -CommitSha $mismatchCollectionWorkflowManifest.sourceControl.commitSha -WorkflowName "other-workflow"
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection evidence must come from the host-evidence workflow" -Action {
    Invoke-SelfTestReadiness -BundlePath $mismatchCollectionWorkflowRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireHostEvidenceWorkflowCollection
  }

  $mismatchWorkflowDispatchRoot = Join-Path $selfTestRoot "mismatch-workflow-dispatch"
  New-Item -ItemType Directory -Force -Path $mismatchWorkflowDispatchRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $mismatchWorkflowDispatchRoot -Force
  $mismatchWorkflowDispatchManifestPath = Join-Path $mismatchWorkflowDispatchRoot "support-evidence-manifest.json"
  $mismatchWorkflowDispatchManifest = Get-Content -LiteralPath $mismatchWorkflowDispatchManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $mismatchWorkflowDispatchRoot -CommitSha $mismatchWorkflowDispatchManifest.sourceControl.commitSha
  $mismatchWorkflowDispatchManifest = Get-Content -LiteralPath $mismatchWorkflowDispatchManifestPath -Raw | ConvertFrom-Json
  $firstWorkflowManifestRow = @($mismatchWorkflowDispatchManifest.files | Where-Object { $_.workflowDispatchSupported -eq $true } | Select-Object -First 1)[0]
  Add-OrSetNoteProperty -Object $firstWorkflowManifestRow -Name "collectionWorkflowDispatchMatchesDimensions" -Value $false
  ($mismatchWorkflowDispatchManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $mismatchWorkflowDispatchManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection workflow dispatch metadata must match the exact support row" -Action {
    Invoke-SelfTestReadiness -BundlePath $mismatchWorkflowDispatchRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireHostEvidenceWorkflowCollection
  }

  $missingRuntimeVersionsRoot = Join-Path $selfTestRoot "missing-runtime-versions"
  New-Item -ItemType Directory -Force -Path $missingRuntimeVersionsRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingRuntimeVersionsRoot -Force
  $missingRuntimeVersionsManifestPath = Join-Path $missingRuntimeVersionsRoot "support-evidence-manifest.json"
  $missingRuntimeVersionsManifest = Get-Content -LiteralPath $missingRuntimeVersionsManifestPath -Raw | ConvertFrom-Json
  $missingRuntimeVersionsRow = @($missingRuntimeVersionsManifest.files | Select-Object -First 1)[0]
  $missingRuntimeVersionsRelative = ([string]$missingRuntimeVersionsRow.path).Replace("/", "\")
  $missingRuntimeVersionsEvidencePath = Join-Path $missingRuntimeVersionsRoot $missingRuntimeVersionsRelative
  $missingRuntimeVersionsEvidence = Get-Content -LiteralPath $missingRuntimeVersionsEvidencePath -Raw | ConvertFrom-Json
  $missingRuntimeVersionsNextJs = Get-PropertyValue -Object $missingRuntimeVersionsEvidence -Names @("NextJsRuntime", "nextJsRuntime")
  if ($null -eq $missingRuntimeVersionsNextJs) {
    throw "Self-test evidence file is missing Next.js runtime evidence: $(Get-DisplayPath -Path $missingRuntimeVersionsEvidencePath)"
  }
  foreach ($runtimeVersionProperty in @("NodeVersion", "nodeVersion", "NextVersion", "nextVersion")) {
    if ($missingRuntimeVersionsNextJs.PSObject.Properties[$runtimeVersionProperty]) {
      $missingRuntimeVersionsNextJs.PSObject.Properties.Remove($runtimeVersionProperty)
    }
  }
  ($missingRuntimeVersionsEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $missingRuntimeVersionsEvidencePath -Encoding UTF8
  Add-OrSetNoteProperty -Object $missingRuntimeVersionsRow -Name "nodeVersion" -Value ""
  Add-OrSetNoteProperty -Object $missingRuntimeVersionsRow -Name "nextVersion" -Value ""
  $missingRuntimeVersionsRow.sha256 = (Get-FileHash -LiteralPath $missingRuntimeVersionsEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $missingRuntimeVersionsRow.bytes = (Get-Item -LiteralPath $missingRuntimeVersionsEvidencePath).Length
  ($missingRuntimeVersionsManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $missingRuntimeVersionsManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Runtime version evidence is required" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingRuntimeVersionsRoot -IncludeServiceOnly -IncludeFallback -RequireRuntimeVersions
  }
  Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireRuntimeVersions

  $missingRuntimeSupportMetadataRoot = Join-Path $selfTestRoot "missing-runtime-support-metadata"
  New-Item -ItemType Directory -Force -Path $missingRuntimeSupportMetadataRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingRuntimeSupportMetadataRoot -Force
  $missingRuntimeSupportMetadataManifestPath = Join-Path $missingRuntimeSupportMetadataRoot "support-evidence-manifest.json"
  $missingRuntimeSupportMetadataManifest = Get-Content -LiteralPath $missingRuntimeSupportMetadataManifestPath -Raw | ConvertFrom-Json
  $missingRuntimeSupportMetadataRow = @($missingRuntimeSupportMetadataManifest.files | Select-Object -First 1)[0]
  Add-OrSetNoteProperty -Object $missingRuntimeSupportMetadataRow -Name "nodeRuntimeSupportTier" -Value ""
  Add-OrSetNoteProperty -Object $missingRuntimeSupportMetadataRow -Name "nodeRuntimeProductionRecommended" -Value $null
  ($missingRuntimeSupportMetadataManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $missingRuntimeSupportMetadataManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "nodeRuntimeSupportTier manifest mismatch" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingRuntimeSupportMetadataRoot -IncludeServiceOnly -IncludeFallback -StrictCiRelease
  }

  $missingCollectorDigestRoot = Join-Path $selfTestRoot "missing-collector-digest"
  New-Item -ItemType Directory -Force -Path $missingCollectorDigestRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingCollectorDigestRoot -Force
  $missingCollectorDigestManifestPath = Join-Path $missingCollectorDigestRoot "support-evidence-manifest.json"
  $missingCollectorDigestManifest = Get-Content -LiteralPath $missingCollectorDigestManifestPath -Raw | ConvertFrom-Json
  $missingCollectorDigestRow = @($missingCollectorDigestManifest.files | Select-Object -First 1)[0]
  $missingCollectorDigestRelative = ([string]$missingCollectorDigestRow.path).Replace("/", "\")
  $missingCollectorDigestEvidencePath = Join-Path $missingCollectorDigestRoot $missingCollectorDigestRelative
  $missingCollectorDigestEvidence = Get-Content -LiteralPath $missingCollectorDigestEvidencePath -Raw | ConvertFrom-Json
  $missingCollectorDigestCollection = Get-PropertyValue -Object $missingCollectorDigestEvidence -Names @("EvidenceCollection", "evidenceCollection")
  if ($null -eq $missingCollectorDigestCollection) {
    throw "Self-test evidence file is missing evidence collection metadata: $(Get-DisplayPath -Path $missingCollectorDigestEvidencePath)"
  }
  foreach ($collectorDigestProperty in @("CollectorSha256", "collectorSha256")) {
    if ($missingCollectorDigestCollection.PSObject.Properties[$collectorDigestProperty]) {
      $missingCollectorDigestCollection.PSObject.Properties.Remove($collectorDigestProperty)
    }
  }
  ($missingCollectorDigestEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $missingCollectorDigestEvidencePath -Encoding UTF8
  Add-OrSetNoteProperty -Object $missingCollectorDigestRow -Name "collectorSha256" -Value ""
  $missingCollectorDigestRow.sha256 = (Get-FileHash -LiteralPath $missingCollectorDigestEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $missingCollectorDigestRow.bytes = (Get-Item -LiteralPath $missingCollectorDigestEvidencePath).Length
  ($missingCollectorDigestManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $missingCollectorDigestManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collector SHA256 evidence is required" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingCollectorDigestRoot -IncludeServiceOnly -IncludeFallback -RequireCollectorSha256
  }
  Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireCollectorSha256

  $missingMinimumUptimeRoot = Join-Path $selfTestRoot "missing-minimum-uptime"
  New-Item -ItemType Directory -Force -Path $missingMinimumUptimeRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingMinimumUptimeRoot -Force
  $missingMinimumUptimeManifestPath = Join-Path $missingMinimumUptimeRoot "support-evidence-manifest.json"
  $missingMinimumUptimeManifest = Get-Content -LiteralPath $missingMinimumUptimeManifestPath -Raw | ConvertFrom-Json
  $missingMinimumUptimeRow = @($missingMinimumUptimeManifest.files | Select-Object -First 1)[0]
  $missingMinimumUptimeRelative = ([string]$missingMinimumUptimeRow.path).Replace("/", "\")
  $missingMinimumUptimeEvidencePath = Join-Path $missingMinimumUptimeRoot $missingMinimumUptimeRelative
  $missingMinimumUptimeEvidence = Get-Content -LiteralPath $missingMinimumUptimeEvidencePath -Raw | ConvertFrom-Json
  $missingMinimumUptime = Get-PropertyValue -Object $missingMinimumUptimeEvidence -Names @("Uptime", "uptime")
  if ($null -eq $missingMinimumUptime) {
    throw "Self-test evidence file is missing uptime metadata: $(Get-DisplayPath -Path $missingMinimumUptimeEvidencePath)"
  }
  foreach ($uptimeProperty in @("MinimumUptimeHours", "minimumUptimeHours", "MinimumSatisfied", "minimumSatisfied")) {
    if ($missingMinimumUptime.PSObject.Properties[$uptimeProperty]) {
      $missingMinimumUptime.PSObject.Properties.Remove($uptimeProperty)
    }
  }
  ($missingMinimumUptimeEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $missingMinimumUptimeEvidencePath -Encoding UTF8
  $missingMinimumUptimeRow.sha256 = (Get-FileHash -LiteralPath $missingMinimumUptimeEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $missingMinimumUptimeRow.bytes = (Get-Item -LiteralPath $missingMinimumUptimeEvidencePath).Length
  ($missingMinimumUptimeManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $missingMinimumUptimeManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "does not prove required minimum uptime evidence" -Action {
    Invoke-SelfTestReadiness -BundlePath $missingMinimumUptimeRoot -IncludeServiceOnly -IncludeFallback -RequireMinimumUptimeHours $selfTestRequiredMinimumUptimeHours
  }
  Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireMinimumUptimeHours $selfTestRequiredMinimumUptimeHours
  Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -ProductionRecommendedOnly
  Invoke-ExpectReadinessFailure -ExpectedMessage "Production-recommended Node runtime targets are required" -Action {
    Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireProductionRecommendedRuntime
  }

  Invoke-ExpectReadinessFailure -ExpectedMessage "-StrictCiRelease cannot be combined with -AllowWarnings" -Action {
    Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -StrictCiRelease -AllowWarnings
  }
  Invoke-ExpectReadinessFailure -ExpectedMessage "-RequireFinalFullMatrixReleaseClaim requires -StrictCiRelease" -Action {
    Invoke-SelfTestReadiness -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireFinalFullMatrixReleaseClaim
  }
  Invoke-ExpectReadinessFailure -ExpectedMessage "-RequireFinalFullMatrixReleaseClaim requires -IncludeServiceOnly and -IncludeFallback" -Action {
    Invoke-SelfTestReadiness -BundlePath $BundlePath -StrictCiRelease -RequireFinalFullMatrixReleaseClaim
  }

  $strictMissingCiRoot = Join-Path $selfTestRoot "strict-missing-ci"
  New-Item -ItemType Directory -Force -Path $strictMissingCiRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $strictMissingCiRoot -Force
  $strictMissingCiManifestPath = Join-Path $strictMissingCiRoot "support-evidence-manifest.json"
  $strictMissingCiManifest = Get-Content -LiteralPath $strictMissingCiManifestPath -Raw | ConvertFrom-Json
  $strictMissingCiManifest.sourceControl.trackedDirty = $false
  $strictMissingCiManifest.ci.isCi = $false
  $strictMissingCiManifest.ci.provider = ""
  $strictMissingCiManifest.ci.workflowName = ""
  $strictMissingCiManifest.ci.runId = ""
  $strictMissingCiManifest.ci.runAttempt = ""
  $strictMissingCiManifest.ci.eventName = ""
  $strictMissingCiManifest.ci.refName = ""
  $strictMissingCiManifest.ci.sha = ""
  ($strictMissingCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $strictMissingCiManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle CI provenance is required" -Action {
    Invoke-SelfTestReadiness -BundlePath $strictMissingCiRoot -IncludeServiceOnly -IncludeFallback -StrictCiRelease
  }

  $strictCompleteRoot = Join-Path $selfTestRoot "strict-complete"
  New-Item -ItemType Directory -Force -Path $strictCompleteRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $strictCompleteRoot -Force
  Set-TestBundleCiProvenance -BundleRoot $strictCompleteRoot
  $strictCompleteManifestPath = Join-Path $strictCompleteRoot "support-evidence-manifest.json"
  $strictCompleteManifest = Get-Content -LiteralPath $strictCompleteManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $strictCompleteRoot -CommitSha $strictCompleteManifest.sourceControl.commitSha
  Remove-TestCollectionCiProvenanceFromLocalOnlyRows -BundleRoot $strictCompleteRoot
  $strictCompleteReadinessJsonPath = Join-Path $selfTestRoot "strict-complete-readiness.json"
  Invoke-ExpectReadinessFailure -ExpectedMessage "Final full-matrix release claim was required" -Action {
    Invoke-SelfTestReadiness -BundlePath $strictCompleteRoot -IncludeServiceOnly -IncludeFallback -StrictCiRelease -RequireFinalFullMatrixReleaseClaim
  }
  & $PSCommandPath `
    -MatrixPath $MatrixPath `
    -TargetId $selfTestTargetIds `
    -BundlePath $strictCompleteRoot `
    -IncludeServiceOnly `
    -IncludeFallback `
    -StrictCiRelease `
    -Format Json `
    -OutputPath $strictCompleteReadinessJsonPath | Out-Null
  $strictCompleteReadiness = Get-Content -LiteralPath $strictCompleteReadinessJsonPath -Raw | ConvertFrom-Json
  if ([string]$strictCompleteReadiness.releaseClaim.kind -ne "strict-ci-filtered") {
    throw "Release support readiness self-test failed: strict release claim kind is incorrect."
  }
  if ($strictCompleteReadiness.releaseClaim.finalFullMatrixReleaseClaim -ne $false) {
    throw "Release support readiness self-test failed: filtered strict evidence must not be a final full-matrix release claim."
  }
  if ($strictCompleteReadiness.releaseClaim.requirements.fullMatrixScope -ne $false -or
    $strictCompleteReadiness.releaseClaim.requirements.strictCiRelease -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.warningClean -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.coverageComplete -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.nonSyntheticEvidenceRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.uniqueEvidencePayloadsRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.workflowApplicabilityKnown -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.runtimeSupportMetadataKnown -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.sourceCleanRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.currentCommitRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.ciProvenanceRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.collectionCiProvenanceRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.collectionSourceCommitRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.hostEvidenceWorkflowCollectionRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.runtimeVersionsRequired -ne $true -or
    $strictCompleteReadiness.releaseClaim.requirements.collectorSha256Required -ne $true -or
    [int]$strictCompleteReadiness.releaseClaim.requirements.maxEvidenceAgeDaysRequired -ne 30 -or
    [int]$strictCompleteReadiness.releaseClaim.requirements.minimumUptimeHoursRequired -lt $selfTestRequiredMinimumUptimeHours) {
    throw "Release support readiness self-test failed: strict filtered readiness did not preserve the expected releaseClaim requirements."
  }
  Write-Host "Release support readiness self-test OK"
  return
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  throw "BundlePath is required unless -SelfTest is used."
}
if (-not [System.IO.Path]::IsPathRooted($BundlePath)) {
  $BundlePath = Join-Path (Get-Location) $BundlePath
}

Write-Step "Release support readiness"

& (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -BundlePath $BundlePath | Out-Null

$resolved = Resolve-BundleRoot -Path $BundlePath
try {
  $bundleRoot = Get-BundleManifestRoot -Root $resolved.Root
  $manifestPath = Join-Path $bundleRoot "support-evidence-manifest.json"
  $evidencePath = Join-Path $bundleRoot "evidence"
  if (-not (Test-Path -LiteralPath $evidencePath -PathType Container)) {
    throw "Bundle evidence directory not found: $(Get-DisplayPath -Path $evidencePath)"
  }

  $allMatrixTargets = @(Select-MatrixTargets -MatrixPath $MatrixPath -TargetId @() -Category @() -ProductionRecommendedOnly $false)
  $allMatrixTargetIds = @($allMatrixTargets | ForEach-Object { Normalize-Token ([string]$_.id) })
  $selectedTargets = @(Select-MatrixTargets -MatrixPath $MatrixPath -TargetId $TargetId -Category $Category -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly))
  $selectedTargetIds = @($selectedTargets | ForEach-Object { Normalize-Token ([string]$_.id) })
  $supportScopeKind = Get-SupportScopeKind `
    -SelectedTargetIds $selectedTargetIds `
    -AllTargetIds $allMatrixTargetIds `
    -TargetId $TargetId `
    -Category $Category `
    -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly)
  $proofLevel = Get-ProofLevel `
    -StrictCiRelease ([bool]$StrictCiRelease) `
    -RequireCleanSource ([bool]$RequireCleanSource) `
    -RequireCurrentCommit ([bool]$RequireCurrentCommit) `
    -RequireCiProvenance ([bool]$RequireCiProvenance) `
    -RequireCollectionCiProvenance ([bool]$RequireCollectionCiProvenance) `
    -RequireCollectionSourceCommit ([bool]$RequireCollectionSourceCommit) `
    -RequireHostEvidenceWorkflowCollection ([bool]$RequireHostEvidenceWorkflowCollection) `
    -RequireRuntimeVersions ([bool]$RequireRuntimeVersions) `
    -RequireCollectorSha256 ([bool]$RequireCollectorSha256) `
    -RequireMinimumUptimeHours $RequireMinimumUptimeHours

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $currentMatrixSha256 = (Get-FileHash -LiteralPath $MatrixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $bundleMatrixPath = (Get-StringValue -Object $manifest -Names @("matrixPath")).Trim().Replace("\", "/")
  $bundleMatrixSha256 = ([string]$manifest.matrixSha256).Trim().ToLowerInvariant()
  if ($bundleMatrixSha256 -ne $currentMatrixSha256) {
    throw "Bundle support matrix SHA256 does not match the current support matrix."
  }
  $sourceIsGitRepository = Get-BooleanValue -Object $manifest.sourceControl -Names @("isGitRepository") -Default $null
  if ($RequireCleanSource) {
    $trackedDirty = [bool]$manifest.sourceControl.trackedDirty
    if ($trackedDirty) {
      throw "Bundle source-control provenance reports tracked dirty files. Rebuild the evidence bundle from a clean committed revision or omit -RequireCleanSource for an explicitly provisional review."
    }
  }
  $currentCommitSha = ""
  if ($RequireCurrentCommit) {
    $currentCommitSha = Get-CurrentGitCommitSha
    if (-not $currentCommitSha) {
      throw "Current repository HEAD commit could not be determined for -RequireCurrentCommit."
    }
    if ($sourceIsGitRepository -ne $true) {
      throw "Bundle source-control provenance must report isGitRepository=true for -RequireCurrentCommit."
    }
    $bundleCommitSha = ([string]$manifest.sourceControl.commitSha).Trim().ToLowerInvariant()
    if (-not $bundleCommitSha) {
      throw "Bundle source-control provenance does not include a commit SHA."
    }
    if ($bundleCommitSha -ne $currentCommitSha) {
      throw "Bundle source-control commit SHA does not match current repository HEAD."
    }
  }
  if ($RequireCiProvenance) {
    $bundleIsCi = [bool]$manifest.ci.isCi
    $bundleCiProvider = ([string]$manifest.ci.provider).Trim().ToLowerInvariant()
    $bundleCiWorkflowName = ([string]$manifest.ci.workflowName).Trim()
    $bundleCiRunId = ([string]$manifest.ci.runId).Trim()
    $bundleCiRunAttempt = ([string]$manifest.ci.runAttempt).Trim()
    $bundleCiEventName = ([string]$manifest.ci.eventName).Trim().ToLowerInvariant()
    $bundleCiSha = ([string]$manifest.ci.sha).Trim().ToLowerInvariant()
    $bundleSourceCommitForCi = ([string]$manifest.sourceControl.commitSha).Trim().ToLowerInvariant()
    if (-not $bundleIsCi -or $bundleCiProvider -ne "github-actions") {
      throw "Bundle CI provenance is required for -RequireCiProvenance and must come from github-actions."
    }
    if ($bundleCiWorkflowName -ne "support-evidence-bundle") {
      throw "Bundle CI workflowName must be support-evidence-bundle for -RequireCiProvenance."
    }
    if (-not (Test-NumericText -Value $bundleCiRunId)) {
      throw "Bundle CI runId must be numeric for -RequireCiProvenance."
    }
    if (-not (Test-NumericText -Value $bundleCiRunAttempt)) {
      throw "Bundle CI runAttempt must be numeric for -RequireCiProvenance."
    }
    if ($bundleCiEventName -ne "workflow_dispatch") {
      throw "Bundle CI eventName must be workflow_dispatch for -RequireCiProvenance."
    }
    if (-not (Test-SafeGitShaValue -Value $bundleCiSha) -or $bundleCiSha -ne $bundleSourceCommitForCi) {
      throw "Bundle CI sha must be a 40-character git SHA matching sourceControl.commitSha for -RequireCiProvenance."
    }
  }
  $bundleSourceCommitSha = ([string]$manifest.sourceControl.commitSha).Trim().ToLowerInvariant()
  if ($RequireCollectionSourceCommit -and $bundleSourceCommitSha -notmatch '^[a-f0-9]{40}$') {
    throw "Bundle source-control commit SHA is required for -RequireCollectionSourceCommit."
  }
  $collectionCiEvidenceCount = 0
  $collectionCiMissingCount = 0
  $collectionCiSourceMatchCount = 0
  $collectionCiSourceMismatchCount = 0
  $hostEvidenceWorkflowCollectionCount = 0
  $hostEvidenceWorkflowMismatchCount = 0
  $collectionWorkflowDispatchMatchCount = 0
  $collectionWorkflowDispatchMismatchCount = 0
  $collectionWorkflowDispatchMatrixMismatchCount = 0
  $runtimeVersionEvidenceCount = 0
  $runtimeVersionMissingCount = 0
  $runtimeVersionUnsafeCount = 0
  $collectorSha256EvidenceCount = 0
  $collectorSha256MissingCount = 0
  $collectorSha256UnsafeCount = 0
  $workflowCapableEvidenceCount = 0
  $localCommandOnlyEvidenceCount = 0
  $workflowApplicabilityMissingCount = 0
  $productionRecommendedRuntimeEvidenceCount = 0
  $nonProductionRecommendedRuntimeEvidenceCount = 0
  $runtimeSupportMetadataMissingCount = 0
  $runtimeSupportTiers = New-Object System.Collections.Generic.HashSet[string]
  foreach ($row in @($manifest.files)) {
    $workflowDispatchSupported = Get-BooleanValue -Object $row -Names @("workflowDispatchSupported") -Default $null
    $localCommandOnly = Get-BooleanValue -Object $row -Names @("localCommandOnly") -Default $null
    $collectionRequirementsApply = $true
    if ($workflowDispatchSupported -eq $false -and $localCommandOnly -eq $true) {
      $localCommandOnlyEvidenceCount += 1
      $collectionRequirementsApply = $false
    } elseif ($workflowDispatchSupported -eq $true -and $localCommandOnly -eq $false) {
      $workflowCapableEvidenceCount += 1
      $collectionRequirementsApply = $true
    } else {
      $workflowApplicabilityMissingCount += 1
      $collectionRequirementsApply = $true
    }

    $collectionCiIsCi = Get-BooleanValue -Object $row -Names @("collectionCiIsCi") -Default $null
    $collectionCiProvider = (Get-StringValue -Object $row -Names @("collectionCiProvider")).Trim().ToLowerInvariant()
    $collectionCiWorkflowName = (Get-StringValue -Object $row -Names @("collectionCiWorkflowName")).Trim()
    $collectionCiRunId = (Get-StringValue -Object $row -Names @("collectionCiRunId")).Trim()
    $collectionCiRunAttempt = (Get-StringValue -Object $row -Names @("collectionCiRunAttempt")).Trim()
    $collectionCiEventName = (Get-StringValue -Object $row -Names @("collectionCiEventName")).Trim().ToLowerInvariant()
    $collectionCiRefName = (Get-StringValue -Object $row -Names @("collectionCiRefName")).Trim()
    $collectionCiSha = (Get-StringValue -Object $row -Names @("collectionCiSha")).Trim().ToLowerInvariant()
    $collectionWorkflowDispatchMatchesDimensions = Get-BooleanValue -Object $row -Names @("collectionWorkflowDispatchMatchesDimensions") -Default $null
    $collectionWorkflowDispatchMinimumUptimeHours = Get-IntegerValue -Object $row -Names @("collectionWorkflowDispatchMinimumUptimeHours")
    $collectionWorkflowDispatchSupportMatrixPath = (Get-StringValue -Object $row -Names @("collectionWorkflowDispatchSupportMatrixPath")).Trim().Replace("\", "/")
    $collectionWorkflowDispatchSupportMatrixSha256 = (Get-StringValue -Object $row -Names @("collectionWorkflowDispatchSupportMatrixSha256")).Trim().ToLowerInvariant()
    $nodeVersion = Get-StringValue -Object $row -Names @("nodeVersion")
    $minimumNodeVersion = Get-StringValue -Object $row -Names @("minimumNodeVersion")
    $nodeVersionSatisfied = Get-BooleanValue -Object $row -Names @("nodeVersionSatisfied") -Default $null
    $nextVersion = Get-StringValue -Object $row -Names @("nextVersion")
    $nodeRuntimeSupportTier = Get-StringValue -Object $row -Names @("nodeRuntimeSupportTier")
    $nodeRuntimeProductionRecommended = Get-BooleanValue -Object $row -Names @("nodeRuntimeProductionRecommended") -Default $null
    $collectorSha256 = (Get-StringValue -Object $row -Names @("collectorSha256")).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($nodeRuntimeSupportTier) -or $null -eq $nodeRuntimeProductionRecommended) {
      $runtimeSupportMetadataMissingCount += 1
    } else {
      [void]$runtimeSupportTiers.Add($nodeRuntimeSupportTier)
      if ($nodeRuntimeProductionRecommended -eq $true) {
        $productionRecommendedRuntimeEvidenceCount += 1
      } else {
        $nonProductionRecommendedRuntimeEvidenceCount += 1
      }
    }
    if ($collectionRequirementsApply) {
      $collectionCiShapeValid = (
        $collectionCiIsCi -eq $true -and
        $collectionCiProvider -eq "github-actions" -and
        (Test-SafeCiRefName -Value $collectionCiWorkflowName) -and
        (Test-NumericText -Value $collectionCiRunId) -and
        (Test-NumericText -Value $collectionCiRunAttempt) -and
        $collectionCiEventName -eq "workflow_dispatch" -and
        (Test-SafeCiRefName -Value $collectionCiRefName) -and
        (Test-SafeGitShaValue -Value $collectionCiSha)
      )
      if ($collectionCiShapeValid) {
        $collectionCiEvidenceCount += 1
      } else {
        $collectionCiMissingCount += 1
      }
      if ($collectionCiSha -and $bundleSourceCommitSha -and $collectionCiSha -eq $bundleSourceCommitSha) {
        $collectionCiSourceMatchCount += 1
      } else {
        $collectionCiSourceMismatchCount += 1
      }
      if ($collectionCiShapeValid -and $collectionCiWorkflowName -eq "host-evidence") {
        $hostEvidenceWorkflowCollectionCount += 1
      } else {
        $hostEvidenceWorkflowMismatchCount += 1
      }
      if ($collectionWorkflowDispatchMatchesDimensions -eq $true -and $null -ne $collectionWorkflowDispatchMinimumUptimeHours -and ($RequireMinimumUptimeHours -le 0 -or [int]$collectionWorkflowDispatchMinimumUptimeHours -ge $RequireMinimumUptimeHours)) {
        $collectionWorkflowDispatchMatchCount += 1
      } else {
        $collectionWorkflowDispatchMismatchCount += 1
      }
      if ($collectionWorkflowDispatchSupportMatrixPath -ne $bundleMatrixPath -or $collectionWorkflowDispatchSupportMatrixSha256 -ne $bundleMatrixSha256) {
        $collectionWorkflowDispatchMatrixMismatchCount += 1
      }
    }
    if ([string]::IsNullOrWhiteSpace($nodeVersion) -or [string]::IsNullOrWhiteSpace($minimumNodeVersion) -or [string]::IsNullOrWhiteSpace($nextVersion) -or $nodeVersionSatisfied -ne $true) {
      $runtimeVersionMissingCount += 1
    } elseif ((Test-SafeRuntimeVersionValue -Value $nodeVersion) -and (Test-SafeRuntimeVersionValue -Value $minimumNodeVersion) -and (Test-SafeRuntimeVersionValue -Value $nextVersion)) {
      $runtimeVersionEvidenceCount += 1
    } else {
      $runtimeVersionUnsafeCount += 1
    }
    if ([string]::IsNullOrWhiteSpace($collectorSha256)) {
      $collectorSha256MissingCount += 1
    } elseif (Test-SafeSha256Value -Value $collectorSha256) {
      $collectorSha256EvidenceCount += 1
    } else {
      $collectorSha256UnsafeCount += 1
    }
  }
  if (($RequireCollectionCiProvenance -or $RequireCollectionSourceCommit -or $RequireHostEvidenceWorkflowCollection) -and $workflowApplicabilityMissingCount -gt 0) {
    throw "Workflow collection applicability metadata is required for release readiness. Missing or inconsistent workflow/local-only metadata on $workflowApplicabilityMissingCount evidence file(s)."
  }
  if ($RequireCollectionCiProvenance -and $collectionCiMissingCount -gt 0) {
    throw "Collection CI provenance is required for workflow-capable evidence with -RequireCollectionCiProvenance. Missing, unsafe, or incomplete CI collection provenance on $collectionCiMissingCount workflow-capable evidence file(s)."
  }
  if ($RequireCollectionSourceCommit -and $collectionCiSourceMismatchCount -gt 0) {
    throw "Collection CI commit SHA must match bundle source-control commit SHA for workflow-capable evidence with -RequireCollectionSourceCommit. Mismatched or missing collection SHA on $collectionCiSourceMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireHostEvidenceWorkflowCollection -and $hostEvidenceWorkflowMismatchCount -gt 0) {
    throw "Collection evidence must come from the host-evidence workflow for workflow-capable evidence with -RequireHostEvidenceWorkflowCollection. Mismatched collection workflow provenance on $hostEvidenceWorkflowMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireHostEvidenceWorkflowCollection -and $collectionWorkflowDispatchMismatchCount -gt 0) {
    throw "Collection workflow dispatch metadata must match the exact support row for workflow-capable evidence with -RequireHostEvidenceWorkflowCollection. Mismatched or missing workflow dispatch dimensions on $collectionWorkflowDispatchMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireHostEvidenceWorkflowCollection -and $collectionWorkflowDispatchMatrixMismatchCount -gt 0) {
    throw "Collection workflow dispatch metadata must match the bundle support matrix path and SHA256 for workflow-capable evidence with -RequireHostEvidenceWorkflowCollection. Mismatched or missing support matrix provenance on $collectionWorkflowDispatchMatrixMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireRuntimeVersions -and ($runtimeVersionMissingCount -gt 0 -or $runtimeVersionUnsafeCount -gt 0)) {
    throw "Runtime version evidence is required for -RequireRuntimeVersions. Missing Node.js, minimum Node.js, compatible Node.js, or Next.js version evidence on $runtimeVersionMissingCount evidence file(s); unsafe runtime version text on $runtimeVersionUnsafeCount evidence file(s)."
  }
  if ($StrictCiRelease -and $runtimeSupportMetadataMissingCount -gt 0) {
    throw "Runtime support metadata is required for -StrictCiRelease. Missing runtime support metadata on $runtimeSupportMetadataMissingCount evidence file(s)."
  }
  if ($RequireCollectorSha256 -and ($collectorSha256MissingCount -gt 0 -or $collectorSha256UnsafeCount -gt 0)) {
    throw "Collector SHA256 evidence is required for -RequireCollectorSha256. Missing collector SHA256 on $collectorSha256MissingCount evidence file(s); unsafe collector SHA256 on $collectorSha256UnsafeCount evidence file(s)."
  }
  if ($RequireProductionRecommendedRuntime -and ($nonProductionRecommendedRuntimeEvidenceCount -gt 0 -or $runtimeSupportMetadataMissingCount -gt 0)) {
    throw "Production-recommended Node runtime targets are required for -RequireProductionRecommendedRuntime. Non-production runtime evidence file(s): $nonProductionRecommendedRuntimeEvidenceCount; missing runtime support metadata: $runtimeSupportMetadataMissingCount."
  }

  $claimArgs = @{
    EvidencePath = $evidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    TargetId = [string[]]$selectedTargetIds
    RequireBothNextJsModes = $true
    RequireDeclaredServiceManagers = $true
    RequireDeclaredReverseProxies = $true
  }
  if ($RequireCollectorSha256) {
    $claimArgs.RequireCollectorSha256 = $true
  }
  if ($RequireMinimumUptimeHours -gt 0) {
    $claimArgs.RequireMinimumUptimeHours = $RequireMinimumUptimeHours
  }
  if ($AllowWarnings) {
    $claimArgs.AllowWarnings = $true
  }
  if ($IncludeServiceOnly) {
    $claimArgs.AllowReverseProxyNone = $true
  }
  & (Join-Path $ScriptDir "Test-SupportClaim.ps1") @claimArgs | Out-Null

  $coverageJson = Join-Path $RepoRoot ".tmp\release-support-readiness-coverage-$([Guid]::NewGuid().ToString('N')).json"
  $coverageArgs = @{
    EvidencePath = $evidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    TargetId = [string[]]$selectedTargetIds
    ProductionRecommendedOnly = [bool]$ProductionRecommendedOnly
    Format = "Json"
    OutputPath = $coverageJson
  }
  if ($AllowWarnings) {
    $coverageArgs.AllowWarnings = $true
  }
  if ($IncludeServiceOnly) {
    $coverageArgs.IncludeServiceOnly = $true
  }
  if ($IncludeFallback) {
    $coverageArgs.IncludeFallback = $true
  }
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") @coverageArgs | Out-Null
  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  Remove-Item -LiteralPath $coverageJson -Force -ErrorAction SilentlyContinue
  if ([int]$coverage.summary.missingCount -gt 0) {
    throw "Support evidence coverage is incomplete for release readiness. Missing evidence rows: $($coverage.summary.missingCount). Review coverage before using this bundle for a release claim."
  }
  $releaseClaimKind = Get-ReleaseClaimKind -ScopeKind $supportScopeKind -StrictCiRelease ([bool]$StrictCiRelease)
  $releaseClaimRequirements = [pscustomobject]@{
    fullMatrixScope = [bool]($supportScopeKind -eq "full-matrix")
    strictCiRelease = [bool]$StrictCiRelease
    warningClean = [bool](-not $AllowWarnings)
    coverageComplete = [bool]([int]$coverage.summary.missingCount -eq 0)
    nonSyntheticEvidenceRequired = $true
    uniqueEvidencePayloadsRequired = $true
    workflowApplicabilityKnown = [bool]($workflowApplicabilityMissingCount -eq 0)
    runtimeSupportMetadataKnown = [bool]($runtimeSupportMetadataMissingCount -eq 0)
    sourceCleanRequired = [bool]$RequireCleanSource
    currentCommitRequired = [bool]$RequireCurrentCommit
    ciProvenanceRequired = [bool]$RequireCiProvenance
    collectionCiProvenanceRequired = [bool]$RequireCollectionCiProvenance
    collectionSourceCommitRequired = [bool]$RequireCollectionSourceCommit
    hostEvidenceWorkflowCollectionRequired = [bool]$RequireHostEvidenceWorkflowCollection
    runtimeVersionsRequired = [bool]$RequireRuntimeVersions
    collectorSha256Required = [bool]$RequireCollectorSha256
    maxEvidenceAgeDaysRequired = [int]$MaxEvidenceAgeDays
    minimumUptimeHoursRequired = [int]$RequireMinimumUptimeHours
  }
  $finalFullMatrixReleaseClaim = [bool](
    $releaseClaimRequirements.fullMatrixScope -and
    $releaseClaimRequirements.strictCiRelease -and
    $releaseClaimRequirements.warningClean -and
    $releaseClaimRequirements.coverageComplete -and
    $releaseClaimRequirements.nonSyntheticEvidenceRequired -and
    $releaseClaimRequirements.uniqueEvidencePayloadsRequired -and
    $releaseClaimRequirements.workflowApplicabilityKnown -and
    $releaseClaimRequirements.runtimeSupportMetadataKnown -and
    $releaseClaimRequirements.sourceCleanRequired -and
    $releaseClaimRequirements.currentCommitRequired -and
    $releaseClaimRequirements.ciProvenanceRequired -and
    $releaseClaimRequirements.collectionCiProvenanceRequired -and
    $releaseClaimRequirements.collectionSourceCommitRequired -and
    $releaseClaimRequirements.hostEvidenceWorkflowCollectionRequired -and
    $releaseClaimRequirements.runtimeVersionsRequired -and
    $releaseClaimRequirements.collectorSha256Required -and
    ([int]$releaseClaimRequirements.maxEvidenceAgeDaysRequired -gt 0) -and
    ([int]$releaseClaimRequirements.minimumUptimeHoursRequired -gt 0)
  )

  $result = [pscustomobject]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    bundlePath = Get-DisplayPath -Path $BundlePath
    matrixPath = Get-DisplayPath -Path $MatrixPath
    maxEvidenceAgeDays = $MaxEvidenceAgeDays
    allowWarnings = [bool]$AllowWarnings
    targetId = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    category = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    productionRecommendedOnly = [bool]$ProductionRecommendedOnly
    selectedTargets = $selectedTargetIds
    strictCiRelease = [bool]$StrictCiRelease
    requireProductionRecommendedRuntime = [bool]$RequireProductionRecommendedRuntime
    requireCleanSource = [bool]$RequireCleanSource
    requireCurrentCommit = [bool]$RequireCurrentCommit
    requireCiProvenance = [bool]$RequireCiProvenance
    requireCollectionCiProvenance = [bool]$RequireCollectionCiProvenance
    requireCollectionSourceCommit = [bool]$RequireCollectionSourceCommit
    requireHostEvidenceWorkflowCollection = [bool]$RequireHostEvidenceWorkflowCollection
    requireRuntimeVersions = [bool]$RequireRuntimeVersions
    requireCollectorSha256 = [bool]$RequireCollectorSha256
    requireMinimumUptimeHours = $RequireMinimumUptimeHours
    requireFinalFullMatrixReleaseClaim = [bool]$RequireFinalFullMatrixReleaseClaim
    strictSupportClaim = [pscustomobject]@{
      requireBothNextJsModes = $true
      requireDeclaredServiceManagers = $true
      requireDeclaredReverseProxies = $true
    }
    bundleCi = $manifest.ci
    releaseClaim = [pscustomobject]@{
      kind = $releaseClaimKind
      finalFullMatrixReleaseClaim = $finalFullMatrixReleaseClaim
      strictCiRelease = [bool]$StrictCiRelease
      scope = $supportScopeKind
      proofLevel = $proofLevel
      warningCleanRequired = [bool](-not $AllowWarnings)
      requirements = $releaseClaimRequirements
      note = if ($StrictCiRelease) { "Ready only for the stated strict CI release scope." } else { "Provisional review; rerun with -StrictCiRelease for final release signoff." }
    }
    bundleSupportScope = $manifest.supportScope
    supportScope = [pscustomobject]@{
      kind = $supportScopeKind
      proofLevel = $proofLevel
      fullMatrix = [bool]($supportScopeKind -eq "full-matrix")
      targetFiltersApplied = [bool](@($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0 -or @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0)
      productionRecommendedOnly = [bool]$ProductionRecommendedOnly
      selectedTargetCount = $selectedTargetIds.Count
      matrixTargetCount = $allMatrixTargetIds.Count
      selectedTargets = $selectedTargetIds
      includeServiceOnly = [bool]$IncludeServiceOnly
      includeFallback = [bool]$IncludeFallback
      strictNextJsModeServiceProxyClaim = $true
      workflowCapableEvidenceCount = $workflowCapableEvidenceCount
      localCommandOnlyEvidenceCount = $localCommandOnlyEvidenceCount
      requiredMinimumUptimeHours = $RequireMinimumUptimeHours
    }
    coverage = [pscustomobject]@{
      includeServiceOnly = [bool]$IncludeServiceOnly
      includeFallback = [bool]$IncludeFallback
      failOnWarningsDuringCollection = [bool]$coverage.failOnWarningsDuringCollection
      requiredMinimumUptimeHours = [int]$coverage.requiredMinimumUptimeHours
      workflowFile = [string]$coverage.workflowFile
      workflowRef = [string]$coverage.workflowRef
      expectedCount = [int]$coverage.summary.expectedCount
      coveredCount = [int]$coverage.summary.coveredCount
      missingCount = [int]$coverage.summary.missingCount
      coveragePercent = $coverage.summary.coveragePercent
      coveragePercentDisplay = Format-CoveragePercent $coverage.summary.coveragePercent
      covered = @(ConvertTo-ReadinessCoverageRows -Rows @($coverage.covered))
      missing = @(ConvertTo-ReadinessCoverageRows -Rows @($coverage.missing))
    }
    bundle = [pscustomobject]@{
      evidenceFileCount = [int]$manifest.summary.evidenceFileCount
      uniqueEvidenceSha256Count = [int]$manifest.summary.uniqueEvidenceSha256Count
      collectionCiEvidenceCount = $collectionCiEvidenceCount
      collectionCiMissingCount = $collectionCiMissingCount
      collectionCiSourceMatchCount = $collectionCiSourceMatchCount
      collectionCiSourceMismatchCount = $collectionCiSourceMismatchCount
      hostEvidenceWorkflowCollectionCount = $hostEvidenceWorkflowCollectionCount
      hostEvidenceWorkflowMismatchCount = $hostEvidenceWorkflowMismatchCount
      collectionWorkflowDispatchMatchCount = $collectionWorkflowDispatchMatchCount
      collectionWorkflowDispatchMismatchCount = $collectionWorkflowDispatchMismatchCount
      collectionWorkflowDispatchMatrixMismatchCount = $collectionWorkflowDispatchMatrixMismatchCount
      runtimeVersionEvidenceCount = $runtimeVersionEvidenceCount
      runtimeVersionMissingCount = $runtimeVersionMissingCount
      runtimeVersionUnsafeCount = $runtimeVersionUnsafeCount
      collectorSha256EvidenceCount = $collectorSha256EvidenceCount
      collectorSha256MissingCount = $collectorSha256MissingCount
      collectorSha256UnsafeCount = $collectorSha256UnsafeCount
      workflowCapableEvidenceCount = $workflowCapableEvidenceCount
      localCommandOnlyEvidenceCount = $localCommandOnlyEvidenceCount
      workflowApplicabilityMissingCount = $workflowApplicabilityMissingCount
      productionRecommendedRuntimeEvidenceCount = $productionRecommendedRuntimeEvidenceCount
      nonProductionRecommendedRuntimeEvidenceCount = $nonProductionRecommendedRuntimeEvidenceCount
      runtimeSupportMetadataMissingCount = $runtimeSupportMetadataMissingCount
      runtimeSupportTiers = @($runtimeSupportTiers | Sort-Object)
      targets = @($manifest.summary.targets)
      nextJsModes = @($manifest.summary.nextJsModes)
      serviceManagers = @($manifest.summary.serviceManagers)
      reverseProxies = @($manifest.summary.reverseProxies)
      collectors = @($manifest.summary.collectors)
    }
    sourceControl = $manifest.sourceControl
    ci = $manifest.ci
    matrixSha256 = $bundleMatrixSha256
    currentCommitSha = $currentCommitSha
  }

  if ($RequireFinalFullMatrixReleaseClaim -and -not $result.releaseClaim.finalFullMatrixReleaseClaim) {
    throw "Final full-matrix release claim was required, but readiness produced '$($result.releaseClaim.kind)' with supportScope '$($result.supportScope.kind)'. Rerun without filters, without -AllowWarnings, and with -StrictCiRelease after collecting complete real-host evidence."
  }

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
      $OutputPath = Join-Path (Get-Location) $OutputPath
    }
    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory) {
      New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
  }

  switch ($Format) {
    "Json" {
      $content = $result | ConvertTo-Json -Depth 8
      if ($OutputPath) { $content | Set-Content -Path $OutputPath -Encoding UTF8 } else { $content }
    }
    "Table" {
      if ($OutputPath) {
        ($result | ConvertTo-Json -Depth 8) | Set-Content -Path $OutputPath -Encoding UTF8
      }
      Write-Host "Ready: $($result.ready)"
      Write-Host "Release claim: $($result.releaseClaim.kind)"
      Write-Host "Review scope: $($result.supportScope.kind)"
      Write-Host "Review proof level: $($result.supportScope.proofLevel)"
      Write-Host "Review selected targets: $($result.supportScope.selectedTargetCount) of $($result.supportScope.matrixTargetCount)"
      Write-Host "Bundle scope: $($result.bundleSupportScope.kind)"
      Write-Host "Bundle proof level: $($result.bundleSupportScope.proofLevel)"
      Write-Host "Bundle evidence files: $($result.bundle.evidenceFileCount)"
      Write-Host "Coverage expected: $($result.coverage.expectedCount)"
      Write-Host "Coverage covered:  $($result.coverage.coveredCount)"
      Write-Host "Coverage missing:  $($result.coverage.missingCount)"
      Write-Host "Coverage percent:  $($result.coverage.coveragePercentDisplay)"
      Write-Host "Production runtime evidence:     $($result.bundle.productionRecommendedRuntimeEvidenceCount)"
      Write-Host "Non-production runtime evidence: $($result.bundle.nonProductionRecommendedRuntimeEvidenceCount)"
      Write-Host "Targets: $(@($result.bundle.targets) -join ', ')"
    }
  }
}
finally {
  if ($resolved.Cleanup -and (Test-Path -LiteralPath $resolved.Root)) {
    Remove-Item -LiteralPath $resolved.Root -Recurse -Force -ErrorAction SilentlyContinue
  }
}
