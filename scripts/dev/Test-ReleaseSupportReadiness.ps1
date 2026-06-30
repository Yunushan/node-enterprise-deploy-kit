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
      throw "BundlePath file must be a .zip bundle: $fullPath"
    }
    $extractRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-bundle-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $fullPath -DestinationPath $extractRoot -Force
    return [pscustomobject]@{
      Root = $extractRoot
      Cleanup = $true
    }
  }
  throw "BundlePath not found: $fullPath"
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
  foreach ($row in @($manifest.files)) {
    $relative = ([string]$row.path).Replace("/", "\")
    $evidencePath = Join-Path $BundleRoot $relative
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $collection = Get-PropertyValue -Object $evidence -Names @("EvidenceCollection", "evidenceCollection")
    if ($null -eq $collection) {
      throw "Self-test evidence file is missing evidenceCollection: $evidencePath"
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
      throw "Self-test evidence file is missing evidenceCollection: $evidencePath"
    }
    foreach ($ciProperty in @("Ci", "ci")) {
      if ($collection.PSObject.Properties[$ciProperty]) {
        $collection.PSObject.Properties.Remove($ciProperty)
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
    [string]$WorkflowName = "host-evidence",
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
        workflowInputSummary = Get-StringValue -Object $row -Names @("workflowInputSummary")
        workflowDispatchCommand = Get-StringValue -Object $row -Names @("workflowDispatchCommand")
      }) | Out-Null
  }
  return @($converted | ForEach-Object { $_ })
}

if ($SelfTest) {
  Write-Step "Release support readiness self-test setup"
  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-selftest-$([Guid]::NewGuid().ToString('N'))"
  $coverageJson = Join-Path $selfTestRoot "coverage.json"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null

  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") -SelfTest -Format Json -OutputPath $coverageJson | Out-Null
  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  $evidencePath = [string]$coverage.evidencePath

  $bundleOutput = Join-Path $selfTestRoot "bundles"
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") `
    -EvidencePath $evidencePath `
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
  $MaxEvidenceAgeDays = 30
  $selfTestRequiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath

  $readinessJsonPath = Join-Path $selfTestRoot "readiness.json"
  & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -Format Json -OutputPath $readinessJsonPath | Out-Null
  $readinessJson = Get-Content -LiteralPath $readinessJsonPath -Raw | ConvertFrom-Json
  if ([int]$readinessJson.coverage.coveredCount -ne @($readinessJson.coverage.covered).Count) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve covered coverage rows."
  }
  if ([int]$readinessJson.coverage.missingCount -ne @($readinessJson.coverage.missing).Count) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve missing coverage rows."
  }
  if ($readinessJson.coverage.failOnWarningsDuringCollection -ne $true) {
    throw "Release support readiness self-test failed: readiness JSON did not preserve strict warning collection policy."
  }
  $firstCoveredRow = @($readinessJson.coverage.covered | Select-Object -First 1)[0]
  foreach ($requiredProperty in @("evidenceFile", "file", "collectionCommand", "validationCommand", "requiredMinimumUptimeHours", "workflowDispatchSupported", "workflowInputSummary", "workflowDispatchCommand")) {
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

  $matrixMismatchRoot = Join-Path $selfTestRoot "matrix-mismatch"
  New-Item -ItemType Directory -Force -Path $matrixMismatchRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $matrixMismatchRoot -Force
  $matrixMismatchManifestPath = Join-Path $matrixMismatchRoot "support-evidence-manifest.json"
  $matrixMismatchManifest = Get-Content -LiteralPath $matrixMismatchManifestPath -Raw | ConvertFrom-Json
  $matrixMismatchManifest.matrixSha256 = ("0" * 64)
  ($matrixMismatchManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $matrixMismatchManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle support matrix SHA256 does not match" -Action {
    & $PSCommandPath -BundlePath $matrixMismatchRoot -IncludeServiceOnly -IncludeFallback | Out-Null
  }

  $dirtySourceRoot = Join-Path $selfTestRoot "dirty-source"
  New-Item -ItemType Directory -Force -Path $dirtySourceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $dirtySourceRoot -Force
  $dirtySourceManifestPath = Join-Path $dirtySourceRoot "support-evidence-manifest.json"
  $dirtySourceManifest = Get-Content -LiteralPath $dirtySourceManifestPath -Raw | ConvertFrom-Json
  $dirtySourceManifest.sourceControl.trackedDirty = $true
  ($dirtySourceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $dirtySourceManifestPath -Encoding UTF8
  Invoke-ExpectReadinessFailure -ExpectedMessage "Bundle source-control provenance reports tracked dirty files" -Action {
    & $PSCommandPath -BundlePath $dirtySourceRoot -IncludeServiceOnly -IncludeFallback -RequireCleanSource | Out-Null
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
    & $PSCommandPath -BundlePath $commitMismatchRoot -IncludeServiceOnly -IncludeFallback -RequireCurrentCommit | Out-Null
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
    & $PSCommandPath -BundlePath $missingCiProvenanceRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance | Out-Null
  }

  $completeCiProvenanceRoot = Join-Path $selfTestRoot "complete-ci-provenance"
  New-Item -ItemType Directory -Force -Path $completeCiProvenanceRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $completeCiProvenanceRoot -Force
  $completeCiProvenanceManifestPath = Join-Path $completeCiProvenanceRoot "support-evidence-manifest.json"
  $completeCiProvenanceManifest = Get-Content -LiteralPath $completeCiProvenanceManifestPath -Raw | ConvertFrom-Json
  $completeCiProvenanceManifest.ci.isCi = $true
  $completeCiProvenanceManifest.ci.provider = "github-actions"
  $completeCiProvenanceManifest.ci.workflowName = "selftest"
  $completeCiProvenanceManifest.ci.runId = "123456"
  $completeCiProvenanceManifest.ci.runAttempt = "1"
  $completeCiProvenanceManifest.ci.eventName = "workflow_dispatch"
  $completeCiProvenanceManifest.ci.refName = "main"
  $completeCiProvenanceManifest.ci.sha = $completeCiProvenanceManifest.sourceControl.commitSha
  ($completeCiProvenanceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $completeCiProvenanceManifestPath -Encoding UTF8
  & $PSCommandPath -BundlePath $completeCiProvenanceRoot -IncludeServiceOnly -IncludeFallback -RequireCiProvenance | Out-Null

  $missingCollectionCiRoot = Join-Path $selfTestRoot "missing-collection-ci-provenance"
  New-Item -ItemType Directory -Force -Path $missingCollectionCiRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $missingCollectionCiRoot -Force
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection CI provenance is required" -Action {
    & $PSCommandPath -BundlePath $missingCollectionCiRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance | Out-Null
  }

  $completeCollectionCiRoot = Join-Path $selfTestRoot "complete-collection-ci-provenance"
  New-Item -ItemType Directory -Force -Path $completeCollectionCiRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $completeCollectionCiRoot -Force
  $completeCollectionCiManifestPath = Join-Path $completeCollectionCiRoot "support-evidence-manifest.json"
  $completeCollectionCiManifest = Get-Content -LiteralPath $completeCollectionCiManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $completeCollectionCiRoot -CommitSha $completeCollectionCiManifest.sourceControl.commitSha
  & $PSCommandPath -BundlePath $completeCollectionCiRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireCollectionSourceCommit -RequireHostEvidenceWorkflowCollection | Out-Null

  $mismatchCollectionCommitRoot = Join-Path $selfTestRoot "mismatch-collection-commit"
  New-Item -ItemType Directory -Force -Path $mismatchCollectionCommitRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $mismatchCollectionCommitRoot -Force
  Set-TestCollectionCiProvenance -BundleRoot $mismatchCollectionCommitRoot -CommitSha ("0" * 40)
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection CI commit SHA must match bundle source-control commit SHA" -Action {
    & $PSCommandPath -BundlePath $mismatchCollectionCommitRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireCollectionSourceCommit | Out-Null
  }

  $mismatchCollectionWorkflowRoot = Join-Path $selfTestRoot "mismatch-collection-workflow"
  New-Item -ItemType Directory -Force -Path $mismatchCollectionWorkflowRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $mismatchCollectionWorkflowRoot -Force
  $mismatchCollectionWorkflowManifestPath = Join-Path $mismatchCollectionWorkflowRoot "support-evidence-manifest.json"
  $mismatchCollectionWorkflowManifest = Get-Content -LiteralPath $mismatchCollectionWorkflowManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $mismatchCollectionWorkflowRoot -CommitSha $mismatchCollectionWorkflowManifest.sourceControl.commitSha -WorkflowName "other-workflow"
  Invoke-ExpectReadinessFailure -ExpectedMessage "Collection evidence must come from the host-evidence workflow" -Action {
    & $PSCommandPath -BundlePath $mismatchCollectionWorkflowRoot -IncludeServiceOnly -IncludeFallback -RequireCollectionCiProvenance -RequireHostEvidenceWorkflowCollection | Out-Null
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
    throw "Self-test evidence file is missing Next.js runtime evidence: $missingRuntimeVersionsEvidencePath"
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
    & $PSCommandPath -BundlePath $missingRuntimeVersionsRoot -IncludeServiceOnly -IncludeFallback -RequireRuntimeVersions | Out-Null
  }
  & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireRuntimeVersions | Out-Null

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
    throw "Self-test evidence file is missing evidence collection metadata: $missingCollectorDigestEvidencePath"
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
    & $PSCommandPath -BundlePath $missingCollectorDigestRoot -IncludeServiceOnly -IncludeFallback -RequireCollectorSha256 | Out-Null
  }
  & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireCollectorSha256 | Out-Null

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
    throw "Self-test evidence file is missing uptime metadata: $missingMinimumUptimeEvidencePath"
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
    & $PSCommandPath -BundlePath $missingMinimumUptimeRoot -IncludeServiceOnly -IncludeFallback -RequireMinimumUptimeHours $selfTestRequiredMinimumUptimeHours | Out-Null
  }
  & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireMinimumUptimeHours $selfTestRequiredMinimumUptimeHours | Out-Null
  & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -ProductionRecommendedOnly | Out-Null
  Invoke-ExpectReadinessFailure -ExpectedMessage "Production-recommended Node runtime targets are required" -Action {
    & $PSCommandPath -BundlePath $BundlePath -IncludeServiceOnly -IncludeFallback -RequireProductionRecommendedRuntime | Out-Null
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
    & $PSCommandPath -BundlePath $strictMissingCiRoot -IncludeServiceOnly -IncludeFallback -StrictCiRelease | Out-Null
  }

  $strictCompleteRoot = Join-Path $selfTestRoot "strict-complete"
  New-Item -ItemType Directory -Force -Path $strictCompleteRoot | Out-Null
  Expand-Archive -LiteralPath $BundlePath -DestinationPath $strictCompleteRoot -Force
  Set-TestBundleCiProvenance -BundleRoot $strictCompleteRoot
  $strictCompleteManifestPath = Join-Path $strictCompleteRoot "support-evidence-manifest.json"
  $strictCompleteManifest = Get-Content -LiteralPath $strictCompleteManifestPath -Raw | ConvertFrom-Json
  Set-TestCollectionCiProvenance -BundleRoot $strictCompleteRoot -CommitSha $strictCompleteManifest.sourceControl.commitSha
  Remove-TestCollectionCiProvenanceFromLocalOnlyRows -BundleRoot $strictCompleteRoot
  & $PSCommandPath -BundlePath $strictCompleteRoot -IncludeServiceOnly -IncludeFallback -StrictCiRelease | Out-Null
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
    throw "Bundle evidence directory not found: $evidencePath"
  }

  $selectedTargets = @(Select-MatrixTargets -MatrixPath $MatrixPath -TargetId $TargetId -Category $Category -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly))
  $selectedTargetIds = @($selectedTargets | ForEach-Object { Normalize-Token ([string]$_.id) })

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $currentMatrixSha256 = (Get-FileHash -LiteralPath $MatrixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $bundleMatrixSha256 = ([string]$manifest.matrixSha256).Trim().ToLowerInvariant()
  if ($bundleMatrixSha256 -ne $currentMatrixSha256) {
    throw "Bundle support matrix SHA256 does not match the current support matrix."
  }
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
    $bundleCiProvider = ([string]$manifest.ci.provider).Trim()
    if (-not $bundleIsCi -or [string]::IsNullOrWhiteSpace($bundleCiProvider)) {
      throw "Bundle CI provenance is required for -RequireCiProvenance."
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
    $collectionCiProvider = Get-StringValue -Object $row -Names @("collectionCiProvider")
    $collectionCiWorkflowName = Get-StringValue -Object $row -Names @("collectionCiWorkflowName")
    $collectionCiEventName = Get-StringValue -Object $row -Names @("collectionCiEventName")
    $collectionCiSha = (Get-StringValue -Object $row -Names @("collectionCiSha")).Trim().ToLowerInvariant()
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
      if ($collectionCiIsCi -eq $true -and -not [string]::IsNullOrWhiteSpace($collectionCiProvider)) {
        $collectionCiEvidenceCount += 1
      } else {
        $collectionCiMissingCount += 1
      }
      if ($collectionCiSha -and $bundleSourceCommitSha -and $collectionCiSha -eq $bundleSourceCommitSha) {
        $collectionCiSourceMatchCount += 1
      } else {
        $collectionCiSourceMismatchCount += 1
      }
      if ($collectionCiIsCi -eq $true -and $collectionCiProvider -eq "github-actions" -and $collectionCiWorkflowName -eq "host-evidence" -and $collectionCiEventName -eq "workflow_dispatch") {
        $hostEvidenceWorkflowCollectionCount += 1
      } else {
        $hostEvidenceWorkflowMismatchCount += 1
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
    throw "Collection CI provenance is required for workflow-capable evidence with -RequireCollectionCiProvenance. Missing or non-CI collection provenance on $collectionCiMissingCount workflow-capable evidence file(s)."
  }
  if ($RequireCollectionSourceCommit -and $collectionCiSourceMismatchCount -gt 0) {
    throw "Collection CI commit SHA must match bundle source-control commit SHA for workflow-capable evidence with -RequireCollectionSourceCommit. Mismatched or missing collection SHA on $collectionCiSourceMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireHostEvidenceWorkflowCollection -and $hostEvidenceWorkflowMismatchCount -gt 0) {
    throw "Collection evidence must come from the host-evidence workflow for workflow-capable evidence with -RequireHostEvidenceWorkflowCollection. Mismatched collection workflow provenance on $hostEvidenceWorkflowMismatchCount workflow-capable evidence file(s)."
  }
  if ($RequireRuntimeVersions -and ($runtimeVersionMissingCount -gt 0 -or $runtimeVersionUnsafeCount -gt 0)) {
    throw "Runtime version evidence is required for -RequireRuntimeVersions. Missing Node.js, minimum Node.js, compatible Node.js, or Next.js version evidence on $runtimeVersionMissingCount evidence file(s); unsafe runtime version text on $runtimeVersionUnsafeCount evidence file(s)."
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

  $result = [pscustomobject]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    bundlePath = Get-RelativePath -BasePath $RepoRoot -Path $BundlePath
    matrixPath = Get-RelativePath -BasePath $RepoRoot -Path $MatrixPath
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
    strictSupportClaim = [pscustomobject]@{
      requireBothNextJsModes = $true
      requireDeclaredServiceManagers = $true
      requireDeclaredReverseProxies = $true
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
      covered = @(ConvertTo-ReadinessCoverageRows -Rows @($coverage.covered))
      missing = @(ConvertTo-ReadinessCoverageRows -Rows @($coverage.missing))
    }
    bundle = [pscustomobject]@{
      evidenceFileCount = [int]$manifest.summary.evidenceFileCount
      collectionCiEvidenceCount = $collectionCiEvidenceCount
      collectionCiMissingCount = $collectionCiMissingCount
      collectionCiSourceMatchCount = $collectionCiSourceMatchCount
      collectionCiSourceMismatchCount = $collectionCiSourceMismatchCount
      hostEvidenceWorkflowCollectionCount = $hostEvidenceWorkflowCollectionCount
      hostEvidenceWorkflowMismatchCount = $hostEvidenceWorkflowMismatchCount
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
      Write-Host "Bundle evidence files: $($result.bundle.evidenceFileCount)"
      Write-Host "Coverage expected: $($result.coverage.expectedCount)"
      Write-Host "Coverage covered:  $($result.coverage.coveredCount)"
      Write-Host "Coverage missing:  $($result.coverage.missingCount)"
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
