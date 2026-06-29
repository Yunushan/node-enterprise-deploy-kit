param(
  [string]$BundlePath = "",
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

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
  if ($value -is [DateTime]) { return $value.ToUniversalTime().ToString("o") }
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

function Get-MatrixTargetsById {
  param([string]$Path)

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $targetsById = @{}
  foreach ($target in @(Get-ArrayValue $matrix.targets)) {
    $targetId = Normalize-Token ([string]$target.id)
    if ($targetId) {
      $targetsById[$targetId] = $target
    }
  }
  return $targetsById
}

function Get-SupportTargetId {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $target = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $target) {
    $target = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }
  return Normalize-Token $target
}

function Get-NextJsMode {
  param([object]$Evidence)

  $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $mode = Get-StringValue -Object $nextJs -Names @("Mode", "mode")
  if (-not $mode) {
    $mode = Get-StringValue -Object $platform -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }
  if (-not $mode) {
    $mode = Get-StringValue -Object $Evidence -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }
  return Normalize-Token $mode
}

function Get-NextJsRuntimeValue {
  param(
    [object]$Evidence,
    [string[]]$Names
  )

  $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
  return Get-StringValue -Object $nextJs -Names $Names
}

function Get-ServiceManager {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }
  return Normalize-Token $serviceManager
}

function Get-ReverseProxyMode {
  param([object]$Evidence)

  $reverseProxy = Get-PropertyValue -Object $Evidence -Names @("ReverseProxy", "reverseProxy")
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $mode = Get-StringValue -Object $reverseProxy -Names @("Mode", "mode")
  if (-not $mode) {
    $mode = Get-StringValue -Object $platform -Names @("ReverseProxy", "reverseProxy")
  }
  if (-not $mode) {
    $mode = Get-StringValue -Object $Evidence -Names @("ReverseProxy", "reverseProxy")
  }
  return Normalize-ReverseProxy $mode
}

function Get-DeploymentIdentityValue {
  param(
    [object]$Evidence,
    [string[]]$Names
  )

  $identity = Get-PropertyValue -Object $Evidence -Names @("DeploymentIdentity", "deploymentIdentity")
  return Get-StringValue -Object $identity -Names $Names
}

function Get-EvidenceCollectionEvidence {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  $ci = Get-PropertyValue -Object $collection -Names @("Ci", "ci")
  return [pscustomobject]@{
    Source = Get-StringValue -Object $collection -Names @("Source", "source")
    Collector = Get-StringValue -Object $collection -Names @("Collector", "collector")
    CollectorVersion = Get-IntegerValue -Object $collection -Names @("CollectorVersion", "collectorVersion")
    CollectorSha256 = (Get-StringValue -Object $collection -Names @("CollectorSha256", "collectorSha256")).Trim().ToLowerInvariant()
    LiveHost = Get-BooleanValue -Object $collection -Names @("LiveHost", "liveHost", "CapturedFromLiveHost", "capturedFromLiveHost") -Default $null
    Synthetic = Get-BooleanValue -Object $collection -Names @("Synthetic", "synthetic") -Default $null
    Mock = Get-BooleanValue -Object $collection -Names @("Mock", "mock") -Default $null
    Sample = Get-BooleanValue -Object $collection -Names @("Sample", "sample") -Default $null
    Ci = [pscustomobject]@{
      IsCi = Get-BooleanValue -Object $ci -Names @("IsCi", "isCi") -Default $null
      Provider = Get-StringValue -Object $ci -Names @("Provider", "provider")
      WorkflowName = Get-StringValue -Object $ci -Names @("WorkflowName", "workflowName")
      RunId = Get-StringValue -Object $ci -Names @("RunId", "runId")
      RunAttempt = Get-StringValue -Object $ci -Names @("RunAttempt", "runAttempt")
      EventName = Get-StringValue -Object $ci -Names @("EventName", "eventName")
      RefName = Get-StringValue -Object $ci -Names @("RefName", "refName")
      Sha = Get-StringValue -Object $ci -Names @("Sha", "sha")
    }
  }
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
  return [System.IO.Path]::GetFileName($Path)
}

function Test-RelativeBundlePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
  $normalized = $Path.Replace("\", "/")
  if ($normalized -match '(^|/)\.\.(/|$)') { return $false }
  if (-not $normalized.StartsWith("evidence/")) { return $false }
  return $true
}

function Get-UniqueValues {
  param(
    [object[]]$Rows,
    [string]$PropertyName
  )

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($row in $Rows) {
    $value = [string]$row.$PropertyName
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $values.Add($value) | Out-Null
    }
  }
  return @($values | Sort-Object -Unique)
}

function Assert-ArrayEqual {
  param(
    [string[]]$Actual,
    [string[]]$Expected,
    [string]$Name
  )

  $actualJoined = @($Actual | Sort-Object) -join ","
  $expectedJoined = @($Expected | Sort-Object) -join ","
  if ($actualJoined -ne $expectedJoined) {
    throw "$Name summary mismatch. Expected '$expectedJoined', got '$actualJoined'."
  }
}

function Invoke-ExpectBundleFailure {
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
      throw "Expected bundle verification failure containing '$ExpectedMessage', got: $($_.Exception.Message)"
    }
  }

  if (-not $failed) {
    throw "Expected bundle verification failure containing '$ExpectedMessage', but verification succeeded."
  }
}

function Copy-BundleDirectory {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function ConvertTo-UtcDateValue {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }
  if ($Value -is [DateTime]) {
    return $Value.ToUniversalTime()
  }
  try {
    return ([DateTime]::Parse([string]$Value).ToUniversalTime())
  } catch {
    return $null
  }
}

function Test-DateValueEqual {
  param(
    [object]$Actual,
    [object]$Expected
  )

  $actualDate = ConvertTo-UtcDateValue $Actual
  $expectedDate = ConvertTo-UtcDateValue $Expected
  if ($null -eq $actualDate -or $null -eq $expectedDate) {
    return ([string]$Actual -eq [string]$Expected)
  }
  return ($actualDate -eq $expectedDate)
}

function Test-Sha256Text {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Fa-f0-9]{64}$')
}

function Assert-CollectionCiProvenance {
  param(
    [object]$Ci,
    [string]$Context
  )

  if ($null -eq $Ci -or $null -eq $Ci.IsCi) { return }

  if ($Ci.Provider -and $Ci.Provider -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$Context collection ci.provider contains unsupported characters."
  }
  if ($Ci.WorkflowName -and $Ci.WorkflowName -notmatch '^[A-Za-z0-9._/-]+$') {
    throw "$Context collection ci.workflowName contains unsupported characters."
  }
  if ($Ci.RunId -and $Ci.RunId -notmatch '^[0-9]+$') {
    throw "$Context collection ci.runId must be numeric when present."
  }
  if ($Ci.RunAttempt -and $Ci.RunAttempt -notmatch '^[0-9]+$') {
    throw "$Context collection ci.runAttempt must be numeric when present."
  }
  if ($Ci.EventName -and $Ci.EventName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$Context collection ci.eventName contains unsupported characters."
  }
  if ($Ci.RefName -and $Ci.RefName -notmatch '^[A-Za-z0-9._/-]+$') {
    throw "$Context collection ci.refName contains unsupported characters."
  }
  if ($Ci.Sha -and $Ci.Sha -notmatch '^[A-Fa-f0-9]{40}$') {
    throw "$Context collection ci.sha must be a 40-character git SHA when present."
  }
  if ($Ci.IsCi -and -not $Ci.Provider) {
    throw "$Context collection ci.provider is required when ci.isCi is true."
  }
  if ($Ci.Provider -eq "github-actions") {
    if (-not $Ci.WorkflowName) {
      throw "$Context collection ci.workflowName is required for github-actions provenance."
    }
    if (-not $Ci.RunId) {
      throw "$Context collection ci.runId is required for github-actions provenance."
    }
    if (-not $Ci.RunAttempt) {
      throw "$Context collection ci.runAttempt is required for github-actions provenance."
    }
    if (-not $Ci.EventName) {
      throw "$Context collection ci.eventName is required for github-actions provenance."
    }
    if (-not $Ci.RefName) {
      throw "$Context collection ci.refName is required for github-actions provenance."
    }
    if (-not $Ci.Sha) {
      throw "$Context collection ci.sha is required for github-actions provenance."
    }
  }
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
    $extractRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-verify-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $fullPath -DestinationPath $extractRoot -Force
    return [pscustomobject]@{
      Root = $extractRoot
      Cleanup = $true
    }
  }
  throw "BundlePath not found: $fullPath"
}

function Test-Bundle {
  param([string]$Path)

  $resolved = Resolve-BundleRoot -Path $Path
  try {
    $bundleRoot = $resolved.Root
    $manifestPath = Join-Path $bundleRoot "support-evidence-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      $nestedManifests = @(Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "support-evidence-manifest.json")
      if ($nestedManifests.Count -eq 1) {
        $bundleRoot = Split-Path -Parent $nestedManifests[0].FullName
        $manifestPath = $nestedManifests[0].FullName
      } else {
        throw "support-evidence-manifest.json was not found at the bundle root."
      }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) {
      throw "support-evidence-manifest.json schemaVersion must be 1."
    }
    $matrixSha256 = Get-StringValue -Object $manifest -Names @("matrixSha256")
    if (-not (Test-Sha256Text -Value $matrixSha256)) {
      throw "support-evidence-manifest.json matrixSha256 is required and must be a SHA256 hash."
    }
    $sourceControl = Get-PropertyValue -Object $manifest -Names @("sourceControl")
    if ($null -eq $sourceControl) {
      throw "support-evidence-manifest.json sourceControl is required."
    }
    $repositoryName = Get-StringValue -Object $sourceControl -Names @("repositoryName")
    if ($repositoryName -notmatch '^[A-Za-z0-9._-]+$') {
      throw "sourceControl.repositoryName must contain only letters, numbers, dot, underscore, or dash."
    }
    $isGitRepository = Get-BooleanValue -Object $sourceControl -Names @("isGitRepository") -Default $null
    if ($null -eq $isGitRepository) {
      throw "sourceControl.isGitRepository must be true or false."
    }
    $trackedDirty = Get-BooleanValue -Object $sourceControl -Names @("trackedDirty") -Default $null
    if ($null -eq $trackedDirty) {
      throw "sourceControl.trackedDirty must be true or false."
    }
    $commitSha = Get-StringValue -Object $sourceControl -Names @("commitSha")
    if ($commitSha -and $commitSha -notmatch '^[A-Fa-f0-9]{40}$') {
      throw "sourceControl.commitSha must be a 40-character git SHA when present."
    }
    if ($isGitRepository -and -not $commitSha) {
      throw "sourceControl.commitSha is required for git repository bundles."
    }
    $branchName = Get-StringValue -Object $sourceControl -Names @("branchName")
    if ($branchName -and $branchName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "sourceControl.branchName contains unsupported characters."
    }
    $ci = Get-PropertyValue -Object $manifest -Names @("ci")
    if ($null -eq $ci) {
      throw "support-evidence-manifest.json ci provenance is required."
    }
    $isCi = Get-BooleanValue -Object $ci -Names @("isCi") -Default $null
    if ($null -eq $isCi) {
      throw "ci.isCi must be true or false."
    }
    $ciProvider = Get-StringValue -Object $ci -Names @("provider")
    if ($ciProvider -and $ciProvider -notmatch '^[A-Za-z0-9._-]+$') {
      throw "ci.provider contains unsupported characters."
    }
    $ciWorkflowName = Get-StringValue -Object $ci -Names @("workflowName")
    if ($ciWorkflowName -and $ciWorkflowName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "ci.workflowName contains unsupported characters."
    }
    $ciRunId = Get-StringValue -Object $ci -Names @("runId")
    if ($ciRunId -and $ciRunId -notmatch '^[0-9]+$') {
      throw "ci.runId must be numeric when present."
    }
    $ciRunAttempt = Get-StringValue -Object $ci -Names @("runAttempt")
    if ($ciRunAttempt -and $ciRunAttempt -notmatch '^[0-9]+$') {
      throw "ci.runAttempt must be numeric when present."
    }
    $ciEventName = Get-StringValue -Object $ci -Names @("eventName")
    if ($ciEventName -and $ciEventName -notmatch '^[A-Za-z0-9._-]+$') {
      throw "ci.eventName contains unsupported characters."
    }
    $ciRefName = Get-StringValue -Object $ci -Names @("refName")
    if ($ciRefName -and $ciRefName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "ci.refName contains unsupported characters."
    }
    $ciSha = Get-StringValue -Object $ci -Names @("sha")
    if ($ciSha -and $ciSha -notmatch '^[A-Fa-f0-9]{40}$') {
      throw "ci.sha must be a 40-character git SHA when present."
    }
    if ($ciSha -and $commitSha -and $ciSha.ToLowerInvariant() -ne $commitSha.ToLowerInvariant()) {
      throw "ci.sha must match sourceControl.commitSha when both are present."
    }
    if ($isCi -and -not $ciProvider) {
      throw "ci.provider is required when ci.isCi is true."
    }
    if ($ciProvider -eq "github-actions") {
      if (-not $ciWorkflowName) {
        throw "ci.workflowName is required for github-actions provenance."
      }
      if (-not $ciRunId) {
        throw "ci.runId is required for github-actions provenance."
      }
      if (-not $ciRunAttempt) {
        throw "ci.runAttempt is required for github-actions provenance."
      }
      if (-not $ciEventName) {
        throw "ci.eventName is required for github-actions provenance."
      }
      if (-not $ciRefName) {
        throw "ci.refName is required for github-actions provenance."
      }
      if (-not $ciSha) {
        throw "ci.sha is required for github-actions provenance."
      }
    }

    $manifestRows = @($manifest.files)
    if ($manifestRows.Count -eq 0) {
      throw "support-evidence-manifest.json must list at least one evidence file."
    }
    if ([int]$manifest.summary.evidenceFileCount -ne $manifestRows.Count) {
      throw "Manifest summary evidenceFileCount does not match files count."
    }

    $matrixPath = Join-Path $RepoRoot "config\support-matrix.example.json"
    if (-not (Test-Path -LiteralPath $matrixPath -PathType Leaf)) {
      throw "Support matrix not found: $matrixPath"
    }
    $matrixTargetsById = Get-MatrixTargetsById -Path $matrixPath

    $listedPaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($row in $manifestRows) {
      $relative = ([string]$row.path).Replace("\", "/")
      if (-not (Test-RelativeBundlePath -Path $relative)) {
        throw "Manifest contains unsafe or invalid evidence path: $relative"
      }
      if (-not $listedPaths.Add($relative)) {
        throw "Manifest contains duplicate evidence path: $relative"
      }

      $filePath = Join-Path $bundleRoot ($relative -replace '/', '\')
      if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Manifest evidence file is missing: $relative"
      }

      $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -ne ([string]$row.sha256).ToLowerInvariant()) {
        throw "SHA256 mismatch for $relative."
      }
      $actualBytes = (Get-Item -LiteralPath $filePath).Length
      if ([int64]$row.bytes -ne $actualBytes) {
        throw "Byte size mismatch for $relative."
      }

      $evidence = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
      if ([string]$row.parseError) {
        throw "Manifest parseError must be empty for validated evidence: $relative"
      }
      if ([string]$row.supportTargetId -ne (Get-SupportTargetId -Evidence $evidence)) {
        throw "supportTargetId manifest mismatch for $relative."
      }
      $rowTargetId = Normalize-Token ([string]$row.supportTargetId)
      if (-not $matrixTargetsById.ContainsKey($rowTargetId)) {
        throw "supportTargetId '$rowTargetId' was not found in the support matrix for $relative."
      }
      $matrixTarget = $matrixTargetsById[$rowTargetId]
      $targetCategory = ([string]$row.targetCategory).Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($targetCategory)) {
        throw "targetCategory manifest value is required for $relative."
      }
      $nodeRuntimeSupport = Get-PropertyValue -Object $matrixTarget -Names @("nodeRuntimeSupport")
      if ([string]$row.nodeRuntimeMinimumNodeVersion -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("minimumNodeVersion"))) {
        throw "nodeRuntimeMinimumNodeVersion manifest mismatch for $relative."
      }
      if ([string]$row.nodeRuntimeSupportTier -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("supportTier"))) {
        throw "nodeRuntimeSupportTier manifest mismatch for $relative."
      }
      $rowNodeRuntimeProductionRecommended = Get-BooleanValue -Object $row -Names @("nodeRuntimeProductionRecommended") -Default $null
      $matrixNodeRuntimeProductionRecommended = Get-BooleanValue -Object $nodeRuntimeSupport -Names @("productionRecommended") -Default $null
      if ($rowNodeRuntimeProductionRecommended -ne $matrixNodeRuntimeProductionRecommended) {
        throw "nodeRuntimeProductionRecommended manifest mismatch for $relative."
      }
      if ([string]$row.nodeRuntimeRequirements -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("requirements"))) {
        throw "nodeRuntimeRequirements manifest mismatch for $relative."
      }
      $workflowDispatchSupported = Get-BooleanValue -Object $row -Names @("workflowDispatchSupported") -Default $null
      $localCommandOnly = Get-BooleanValue -Object $row -Names @("localCommandOnly") -Default $null
      if ($null -eq $workflowDispatchSupported -or $null -eq $localCommandOnly) {
        throw "workflowDispatchSupported and localCommandOnly manifest values are required for $relative."
      }
      if ($workflowDispatchSupported -eq $localCommandOnly) {
        throw "workflowDispatchSupported and localCommandOnly manifest values disagree for $relative."
      }
      if ($targetCategory -eq "bsd" -and ($workflowDispatchSupported -ne $false -or $localCommandOnly -ne $true)) {
        throw "BSD evidence must be marked local-command-only in the manifest for $relative."
      }
      if ($targetCategory -in @("windows-client", "windows-server", "linux", "macos") -and ($workflowDispatchSupported -ne $true -or $localCommandOnly -ne $false)) {
        throw "Workflow-capable evidence is not marked correctly in the manifest for $relative."
      }
      if ([string]$row.nextJsMode -ne (Get-NextJsMode -Evidence $evidence)) {
        throw "nextJsMode manifest mismatch for $relative."
      }
      if ([string]$row.serviceManager -ne (Get-ServiceManager -Evidence $evidence)) {
        throw "serviceManager manifest mismatch for $relative."
      }
      if ([string]$row.reverseProxy -ne (Get-ReverseProxyMode -Evidence $evidence)) {
        throw "reverseProxy manifest mismatch for $relative."
      }
      if ([string]$row.nodeVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersion", "nodeVersion"))) {
        throw "nodeVersion manifest mismatch for $relative."
      }
      if ([string]$row.minimumNodeVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("MinimumNodeVersion", "minimumNodeVersion"))) {
        throw "minimumNodeVersion manifest mismatch for $relative."
      }
      $rowNodeVersionSatisfied = Get-BooleanValue -Object $row -Names @("nodeVersionSatisfied") -Default $null
      $evidenceNodeVersionSatisfiedText = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersionSatisfied", "nodeVersionSatisfied")
      $evidenceNodeVersionSatisfied = $null
      if (-not [string]::IsNullOrWhiteSpace($evidenceNodeVersionSatisfiedText)) {
        $evidenceNodeVersionSatisfied = ($evidenceNodeVersionSatisfiedText.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
      }
      if ($rowNodeVersionSatisfied -ne $evidenceNodeVersionSatisfied) {
        throw "nodeVersionSatisfied manifest mismatch for $relative."
      }
      if ([string]$row.nextVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("NextVersion", "nextVersion"))) {
        throw "nextVersion manifest mismatch for $relative."
      }
      $evidenceGeneratedAt = Get-StringValue -Object $evidence -Names @("GeneratedAtUtc", "generatedAtUtc")
      if (-not (Test-DateValueEqual -Actual $row.generatedAtUtc -Expected $evidenceGeneratedAt)) {
        throw "generatedAtUtc manifest mismatch for $relative."
      }
      if ([string]$row.verdict -ne (Get-StringValue -Object $evidence -Names @("Verdict", "verdict"))) {
        throw "verdict manifest mismatch for $relative."
      }
      $critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
      $warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
      if ($null -ne $critical -and [int]$row.critical -ne $critical) {
        throw "critical manifest mismatch for $relative."
      }
      if ($null -ne $warnings -and [int]$row.warnings -ne $warnings) {
        throw "warnings manifest mismatch for $relative."
      }
      if ([string]$row.deploymentId -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("DeploymentId", "deploymentId"))) {
        throw "deploymentId manifest mismatch for $relative."
      }
      if ([string]$row.nextBuildId -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("NextBuildId", "nextBuildId"))) {
        throw "nextBuildId manifest mismatch for $relative."
      }
      if ([string]$row.packageSha256 -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("PackageSha256", "packageSha256"))) {
        throw "packageSha256 manifest mismatch for $relative."
      }
      $collection = Get-EvidenceCollectionEvidence -Evidence $evidence
      if ([string]$row.collectorSource -ne $collection.Source) {
        throw "collectorSource manifest mismatch for $relative."
      }
      if ([string]$row.collector -ne $collection.Collector) {
        throw "collector manifest mismatch for $relative."
      }
      $collectorVersion = Get-IntegerValue -Object $row -Names @("collectorVersion")
      if ($null -eq $collectorVersion -or $collectorVersion -ne $collection.CollectorVersion) {
        throw "collectorVersion manifest mismatch for $relative."
      }
      if ([string]$row.collectorSha256 -ne $collection.CollectorSha256) {
        throw "collectorSha256 manifest mismatch for $relative."
      }
      $liveHost = Get-BooleanValue -Object $row -Names @("liveHost") -Default $null
      if ($liveHost -ne $collection.LiveHost) {
        throw "liveHost manifest mismatch for $relative."
      }
      if ($liveHost -ne $true) {
        throw "Bundle evidence does not prove live-host collection for $relative."
      }
      $synthetic = Get-BooleanValue -Object $row -Names @("synthetic") -Default $null
      if ($synthetic -ne $collection.Synthetic) {
        throw "synthetic manifest mismatch for $relative."
      }
      if ($synthetic -ne $false) {
        throw "Bundle evidence declares synthetic collection for $relative."
      }
      $mock = Get-BooleanValue -Object $row -Names @("mock") -Default $null
      if ($mock -ne $collection.Mock) {
        throw "mock manifest mismatch for $relative."
      }
      if ($mock -ne $false) {
        throw "Bundle evidence declares mock collection for $relative."
      }
      $sample = Get-BooleanValue -Object $row -Names @("sample") -Default $null
      if ($sample -ne $collection.Sample) {
        throw "sample manifest mismatch for $relative."
      }
      if ($sample -ne $false) {
        throw "Bundle evidence declares sample collection for $relative."
      }
      $rowCollectionCiIsCi = Get-BooleanValue -Object $row -Names @("collectionCiIsCi") -Default $null
      $rowCollectionCiProvider = Get-StringValue -Object $row -Names @("collectionCiProvider")
      $rowCollectionCiWorkflowName = Get-StringValue -Object $row -Names @("collectionCiWorkflowName")
      $rowCollectionCiRunId = Get-StringValue -Object $row -Names @("collectionCiRunId")
      $rowCollectionCiRunAttempt = Get-StringValue -Object $row -Names @("collectionCiRunAttempt")
      $rowCollectionCiEventName = Get-StringValue -Object $row -Names @("collectionCiEventName")
      $rowCollectionCiRefName = Get-StringValue -Object $row -Names @("collectionCiRefName")
      $rowCollectionCiSha = Get-StringValue -Object $row -Names @("collectionCiSha")
      $rowHasCollectionCi = (
        $null -ne $rowCollectionCiIsCi -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiProvider) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiWorkflowName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRunId) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRunAttempt) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiEventName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRefName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiSha)
      )
      $evidenceHasCollectionCi = (
        $null -ne $collection.Ci.IsCi -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.Provider) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.WorkflowName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RunId) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RunAttempt) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.EventName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RefName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.Sha)
      )
      if ($rowHasCollectionCi -or $evidenceHasCollectionCi) {
        if ($rowCollectionCiIsCi -ne $collection.Ci.IsCi) {
          throw "collectionCiIsCi manifest mismatch for $relative."
        }
        if ($rowCollectionCiProvider -ne $collection.Ci.Provider) {
          throw "collectionCiProvider manifest mismatch for $relative."
        }
        if ($rowCollectionCiWorkflowName -ne $collection.Ci.WorkflowName) {
          throw "collectionCiWorkflowName manifest mismatch for $relative."
        }
        if ($rowCollectionCiRunId -ne $collection.Ci.RunId) {
          throw "collectionCiRunId manifest mismatch for $relative."
        }
        if ($rowCollectionCiRunAttempt -ne $collection.Ci.RunAttempt) {
          throw "collectionCiRunAttempt manifest mismatch for $relative."
        }
        if ($rowCollectionCiEventName -ne $collection.Ci.EventName) {
          throw "collectionCiEventName manifest mismatch for $relative."
        }
        if ($rowCollectionCiRefName -ne $collection.Ci.RefName) {
          throw "collectionCiRefName manifest mismatch for $relative."
        }
        if ($rowCollectionCiSha -ne $collection.Ci.Sha) {
          throw "collectionCiSha manifest mismatch for $relative."
        }
        Assert-CollectionCiProvenance -Ci $collection.Ci -Context $relative
      }
    }

    $actualEvidenceFiles = @(Get-ChildItem -Path (Join-Path $bundleRoot "evidence") -Recurse -File -Filter "*.json" | ForEach-Object {
        Get-RelativePath -BasePath $bundleRoot -Path $_.FullName
      })
    $unlistedFiles = @($actualEvidenceFiles | Where-Object { -not $listedPaths.Contains($_) })
    if ($unlistedFiles.Count -gt 0) {
      throw "Bundle contains evidence files not listed in manifest: $($unlistedFiles -join ', ')"
    }

    Assert-ArrayEqual -Actual @($manifest.summary.targets) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "supportTargetId") -Name "targets"
    Assert-ArrayEqual -Actual @($manifest.summary.nextJsModes) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "nextJsMode") -Name "nextJsModes"
    Assert-ArrayEqual -Actual @($manifest.summary.serviceManagers) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "serviceManager") -Name "serviceManagers"
    Assert-ArrayEqual -Actual @($manifest.summary.reverseProxies) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "reverseProxy") -Name "reverseProxies"
    Assert-ArrayEqual -Actual @($manifest.summary.collectors) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "collector") -Name "collectors"
  }
  finally {
    if ($resolved.Cleanup -and (Test-Path -LiteralPath $resolved.Root)) {
      Remove-Item -LiteralPath $resolved.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ""
Write-Host "==> Support evidence bundle verification"

if ($SelfTest) {
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") -SelfTest | Out-Null
  $selfTestRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output\selftest-support-evidence"
  $selfTestZip = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output\selftest-support-evidence.zip"
  Test-Bundle -Path $selfTestRoot
  Test-Bundle -Path $selfTestZip

  $hashTamperRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-hash-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $hashTamperRoot
  Add-Content -LiteralPath (Join-Path $hashTamperRoot "evidence\ubuntu-systemd-nginx.json") -Value " "
  Invoke-ExpectBundleFailure -ExpectedMessage "SHA256 mismatch" -Action {
    Test-Bundle -Path $hashTamperRoot
  }

  $unlistedRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-unlisted-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $unlistedRoot
  Copy-Item -LiteralPath (Join-Path $unlistedRoot "evidence\ubuntu-systemd-nginx.json") -Destination (Join-Path $unlistedRoot "evidence\unlisted-copy.json") -Force
  Invoke-ExpectBundleFailure -ExpectedMessage "not listed in manifest" -Action {
    Test-Bundle -Path $unlistedRoot
  }

  $missingMatrixRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-matrix-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingMatrixRoot
  $missingMatrixManifestPath = Join-Path $missingMatrixRoot "support-evidence-manifest.json"
  $missingMatrixManifest = Get-Content -LiteralPath $missingMatrixManifestPath -Raw | ConvertFrom-Json
  $missingMatrixManifest.PSObject.Properties.Remove("matrixSha256")
  ($missingMatrixManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingMatrixManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "matrixSha256 is required" -Action {
    Test-Bundle -Path $missingMatrixRoot
  }

  $missingSourceRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-source-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingSourceRoot
  $missingSourceManifestPath = Join-Path $missingSourceRoot "support-evidence-manifest.json"
  $missingSourceManifest = Get-Content -LiteralPath $missingSourceManifestPath -Raw | ConvertFrom-Json
  $missingSourceManifest.PSObject.Properties.Remove("sourceControl")
  ($missingSourceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingSourceManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "sourceControl is required" -Action {
    Test-Bundle -Path $missingSourceRoot
  }

  $missingCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingCiRoot
  $missingCiManifestPath = Join-Path $missingCiRoot "support-evidence-manifest.json"
  $missingCiManifest = Get-Content -LiteralPath $missingCiManifestPath -Raw | ConvertFrom-Json
  $missingCiManifest.PSObject.Properties.Remove("ci")
  ($missingCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci provenance is required" -Action {
    Test-Bundle -Path $missingCiRoot
  }

  $badCiShaRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-sha-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $badCiShaRoot
  $badCiShaManifestPath = Join-Path $badCiShaRoot "support-evidence-manifest.json"
  $badCiShaManifest = Get-Content -LiteralPath $badCiShaManifestPath -Raw | ConvertFrom-Json
  $badCiShaManifest.ci.sha = "not-a-sha"
  ($badCiShaManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $badCiShaManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.sha must be a 40-character git SHA" -Action {
    Test-Bundle -Path $badCiShaRoot
  }

  $mismatchCiShaRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-source-sha-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $mismatchCiShaRoot
  $mismatchCiShaManifestPath = Join-Path $mismatchCiShaRoot "support-evidence-manifest.json"
  $mismatchCiShaManifest = Get-Content -LiteralPath $mismatchCiShaManifestPath -Raw | ConvertFrom-Json
  $mismatchCiShaManifest.ci.sha = ("0" * 40)
  ($mismatchCiShaManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $mismatchCiShaManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.sha must match sourceControl.commitSha" -Action {
    Test-Bundle -Path $mismatchCiShaRoot
  }

  $completeGithubCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-complete-github-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $completeGithubCiRoot
  $completeGithubCiManifestPath = Join-Path $completeGithubCiRoot "support-evidence-manifest.json"
  $completeGithubCiManifest = Get-Content -LiteralPath $completeGithubCiManifestPath -Raw | ConvertFrom-Json
  $completeGithubCiManifest.ci.isCi = $true
  $completeGithubCiManifest.ci.provider = "github-actions"
  $completeGithubCiManifest.ci.workflowName = "selftest"
  $completeGithubCiManifest.ci.runId = "123456"
  $completeGithubCiManifest.ci.runAttempt = "1"
  $completeGithubCiManifest.ci.eventName = "workflow_dispatch"
  $completeGithubCiManifest.ci.refName = "main"
  $completeGithubCiManifest.ci.sha = $completeGithubCiManifest.sourceControl.commitSha
  ($completeGithubCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $completeGithubCiManifestPath -Encoding UTF8
  Test-Bundle -Path $completeGithubCiRoot

  $collectionCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-collection-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $collectionCiRoot
  $collectionCiFile = Join-Path $collectionCiRoot "evidence\ubuntu-systemd-nginx.json"
  $collectionCiEvidence = Get-Content -LiteralPath $collectionCiFile -Raw | ConvertFrom-Json
  $collectionCiEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "123456"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = $completeGithubCiManifest.sourceControl.commitSha
    }) -Force
  ($collectionCiEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $collectionCiFile -Encoding UTF8
  $collectionCiManifestPath = Join-Path $collectionCiRoot "support-evidence-manifest.json"
  $collectionCiManifest = Get-Content -LiteralPath $collectionCiManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($collectionCiManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $collectionCiFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $collectionCiFile).Length
      $row.collectionCiIsCi = $true
      $row.collectionCiProvider = "github-actions"
      $row.collectionCiWorkflowName = "host-evidence"
      $row.collectionCiRunId = "123456"
      $row.collectionCiRunAttempt = "1"
      $row.collectionCiEventName = "workflow_dispatch"
      $row.collectionCiRefName = "main"
      $row.collectionCiSha = $completeGithubCiManifest.sourceControl.commitSha
    }
  }
  ($collectionCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $collectionCiManifestPath -Encoding UTF8
  Test-Bundle -Path $collectionCiRoot

  $badCollectionCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-collection-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $collectionCiRoot -Destination $badCollectionCiRoot
  $badCollectionCiFile = Join-Path $badCollectionCiRoot "evidence\ubuntu-systemd-nginx.json"
  $badCollectionCiEvidence = Get-Content -LiteralPath $badCollectionCiFile -Raw | ConvertFrom-Json
  $badCollectionCiEvidence.evidenceCollection.ci.runId = ""
  ($badCollectionCiEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiFile -Encoding UTF8
  $badCollectionCiManifestPath = Join-Path $badCollectionCiRoot "support-evidence-manifest.json"
  $badCollectionCiManifest = Get-Content -LiteralPath $badCollectionCiManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($badCollectionCiManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $badCollectionCiFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $badCollectionCiFile).Length
      $row.collectionCiRunId = ""
    }
  }
  ($badCollectionCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "collection ci.runId is required for github-actions provenance" -Action {
    Test-Bundle -Path $badCollectionCiRoot
  }

  $incompleteGithubCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-github-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $incompleteGithubCiRoot
  $incompleteGithubCiManifestPath = Join-Path $incompleteGithubCiRoot "support-evidence-manifest.json"
  $incompleteGithubCiManifest = Get-Content -LiteralPath $incompleteGithubCiManifestPath -Raw | ConvertFrom-Json
  $incompleteGithubCiManifest.ci.isCi = $true
  $incompleteGithubCiManifest.ci.provider = "github-actions"
  $incompleteGithubCiManifest.ci.workflowName = "selftest"
  $incompleteGithubCiManifest.ci.runId = ""
  $incompleteGithubCiManifest.ci.runAttempt = "1"
  $incompleteGithubCiManifest.ci.eventName = "workflow_dispatch"
  $incompleteGithubCiManifest.ci.refName = "main"
  $incompleteGithubCiManifest.ci.sha = $incompleteGithubCiManifest.sourceControl.commitSha
  ($incompleteGithubCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $incompleteGithubCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.runId is required for github-actions provenance" -Action {
    Test-Bundle -Path $incompleteGithubCiRoot
  }

  Write-Host "Support evidence bundle verification OK"
  return
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  throw "BundlePath is required unless -SelfTest is used."
}
Test-Bundle -Path $BundlePath
Write-Host "Support evidence bundle verification OK"
