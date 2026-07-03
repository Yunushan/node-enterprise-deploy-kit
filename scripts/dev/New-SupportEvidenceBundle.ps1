param(
  [string]$EvidencePath = "",
  [string]$MatrixPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [string]$OutputDirectory = ".tmp/support-evidence-bundles",
  [string]$BundleName = "support-evidence",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$AllowWarnings,
  [switch]$ValidateSupportClaim,
  [switch]$RequireBothNextJsModes,
  [switch]$RequireDeclaredServiceManagers,
  [switch]$RequireDeclaredReverseProxies,
  [switch]$RequireCollectorSha256,
  [switch]$RequireHostEvidenceWorkflowCollection,
  [int]$RequireMinimumUptimeHours = 0,
  [switch]$RequireCoverageComplete,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$ProductionRecommendedOnly,
  [switch]$AllowReverseProxyNone,
  [switch]$NoZip,
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
if (-not [string]::IsNullOrWhiteSpace($EvidencePath) -and -not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
  $OutputDirectory = Join-Path $RepoRoot $OutputDirectory
}

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
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

function Normalize-ReverseProxy {
  param([string]$Value)
  $normalized = Normalize-Token $Value
  if ($normalized -eq "httpd") { return "apache" }
  return $normalized
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

function Test-WorkflowDispatchSupported {
  param([string]$Category)
  return ($Category -in @("windows-client", "windows-server", "linux", "macos"))
}

function Test-TargetWorkflowDispatchSupported {
  param([object]$Target)

  $localCommandOnlyProperty = $Target.PSObject.Properties["localCommandOnly"]
  if ($localCommandOnlyProperty -and $localCommandOnlyProperty.Value -eq $true) {
    return $false
  }
  return (Test-WorkflowDispatchSupported -Category ([string]$Target.category))
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

function Test-ProductionRecommendedTarget {
  param([object]$Target)

  $nodeRuntimeSupport = Get-PropertyValue -Object $Target -Names @("nodeRuntimeSupport")
  if ($null -eq $nodeRuntimeSupport) { return $false }
  $property = $nodeRuntimeSupport.PSObject.Properties["productionRecommended"]
  return ($property -and $property.Value -is [bool] -and [bool]$property.Value)
}

function Select-MatrixTargets {
  param(
    [string]$Path,
    [string[]]$TargetId,
    [string[]]$Category,
    [bool]$ProductionRecommendedOnly
  )

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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
    throw "No support matrix targets matched the requested bundle filters."
  }
  return $selected
}

function Get-SupportScopeKind {
  param(
    [string[]]$SelectedTargetIds,
    [string[]]$AllTargetIds,
    [string[]]$TargetId,
    [string[]]$Category,
    [bool]$ProductionRecommendedOnly,
    [bool]$RequireCoverageComplete
  )

  if ($ProductionRecommendedOnly) {
    return "production-recommended"
  }

  $hasTargetFilter = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0
  $hasCategoryFilter = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ }).Count -gt 0
  if ($hasTargetFilter -or $hasCategoryFilter) {
    return "filtered"
  }

  if (-not $RequireCoverageComplete) {
    return "unfiltered"
  }

  $missingFromSelection = @($AllTargetIds | Where-Object { $SelectedTargetIds -notcontains $_ })
  $extraInSelection = @($SelectedTargetIds | Where-Object { $AllTargetIds -notcontains $_ })
  if ($missingFromSelection.Count -eq 0 -and $extraInSelection.Count -eq 0) {
    return "full-matrix"
  }

  return "filtered"
}

function Get-BundleProofLevel {
  param(
    [bool]$RequireCollectorSha256,
    [bool]$RequireHostEvidenceWorkflowCollection,
    [int]$RequireMinimumUptimeHours
  )

  if ($RequireCollectorSha256 -or $RequireHostEvidenceWorkflowCollection -or $RequireMinimumUptimeHours -gt 0) {
    return "hardened-real-host-evidence"
  }

  return "basic-real-host-evidence"
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
  $workflowDispatch = Get-PropertyValue -Object $collection -Names @("WorkflowDispatch", "workflowDispatch")
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
    WorkflowDispatch = [pscustomobject]@{
      EvidenceName = Normalize-Token (Get-StringValue -Object $workflowDispatch -Names @("EvidenceName", "evidenceName"))
      ExpectedTargetId = Normalize-Token (Get-StringValue -Object $workflowDispatch -Names @("ExpectedTargetId", "expectedTargetId", "expected_target_id"))
      ExpectedNextJsMode = Normalize-Token (Get-StringValue -Object $workflowDispatch -Names @("ExpectedNextJsMode", "expectedNextJsMode", "expected_nextjs_mode"))
      ExpectedServiceManager = Normalize-Token (Get-StringValue -Object $workflowDispatch -Names @("ExpectedServiceManager", "expectedServiceManager", "expected_service_manager"))
      ExpectedReverseProxy = Normalize-ReverseProxy (Get-StringValue -Object $workflowDispatch -Names @("ExpectedReverseProxy", "expectedReverseProxy", "expected_reverse_proxy"))
      MinimumUptimeHours = Get-IntegerValue -Object $workflowDispatch -Names @("MinimumUptimeHours", "minimumUptimeHours", "minimum_uptime_hours")
    }
  }
}

function Test-WorkflowDispatchMatchesEvidence {
  param(
    [object]$Dispatch,
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours
  )

  $expectedEvidenceBaseName = "$TargetId-$Mode-$ServiceManager-$ReverseProxy"
  $allowedEvidenceNames = @($expectedEvidenceBaseName, "$expectedEvidenceBaseName-fallback")
  if ($allowedEvidenceNames -notcontains [string]$Dispatch.EvidenceName) { return $false }
  if ([string]$Dispatch.ExpectedTargetId -ne $TargetId) { return $false }
  if ([string]$Dispatch.ExpectedNextJsMode -ne $Mode) { return $false }
  if ([string]$Dispatch.ExpectedServiceManager -ne $ServiceManager) { return $false }
  if ([string]$Dispatch.ExpectedReverseProxy -ne $ReverseProxy) { return $false }
  if ($null -eq $Dispatch.MinimumUptimeHours) { return $false }
  if ($RequiredMinimumUptimeHours -gt 0 -and [int]$Dispatch.MinimumUptimeHours -lt $RequiredMinimumUptimeHours) { return $false }
  return $true
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

function Get-SourceControlProvenance {
  $repoName = Split-Path -Leaf ([System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/'))
  $insideGit = (Invoke-GitText -Arguments @("rev-parse", "--is-inside-work-tree")).Trim().ToLowerInvariant()
  $isGitRepository = ($insideGit -eq "true")
  $commitSha = ""
  $branchName = ""
  $trackedDirty = $false

  if ($isGitRepository) {
    $gitRoot = Invoke-GitText -Arguments @("rev-parse", "--show-toplevel")
    if (-not [string]::IsNullOrWhiteSpace($gitRoot)) {
      $repoName = Split-Path -Leaf ([System.IO.Path]::GetFullPath($gitRoot).TrimEnd('\', '/'))
    }

    $commitSha = Invoke-GitText -Arguments @("rev-parse", "--verify", "HEAD")
    $branchName = Invoke-GitText -Arguments @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($branchName)) {
      $branchName = Invoke-GitText -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
      if ($branchName -eq "HEAD") {
        $branchName = ""
      }
    }

    $dirtyOutput = Invoke-GitText -Arguments @("status", "--porcelain", "--untracked-files=no")
    $trackedDirty = -not [string]::IsNullOrWhiteSpace($dirtyOutput)
  }

  return [ordered]@{
    repositoryName = ($repoName -replace '[^A-Za-z0-9._-]', '-')
    isGitRepository = $isGitRepository
    commitSha = $commitSha.Trim().ToLowerInvariant()
    branchName = ($branchName.Trim() -replace '[^A-Za-z0-9._/-]', '-')
    trackedDirty = $trackedDirty
  }
}

function Get-SafeCiValue {
  param(
    [string]$Value,
    [string]$Pattern = '[^A-Za-z0-9._/-]'
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  return ($Value.Trim() -replace $Pattern, "-")
}

function Get-CiProvenance {
  $isGitHubActions = ([string]$env:GITHUB_ACTIONS).Trim().ToLowerInvariant() -eq "true"
  $isCi = $isGitHubActions -or (([string]$env:CI).Trim().ToLowerInvariant() -eq "true")
  $provider = if ($isGitHubActions) { "github-actions" } elseif ($isCi) { "ci" } else { "" }

  return [ordered]@{
    isCi = $isCi
    provider = $provider
    workflowName = Get-SafeCiValue -Value ([string]$env:GITHUB_WORKFLOW)
    runId = Get-SafeCiValue -Value ([string]$env:GITHUB_RUN_ID) -Pattern '[^0-9]'
    runAttempt = Get-SafeCiValue -Value ([string]$env:GITHUB_RUN_ATTEMPT) -Pattern '[^0-9]'
    eventName = Get-SafeCiValue -Value ([string]$env:GITHUB_EVENT_NAME) -Pattern '[^A-Za-z0-9._-]'
    refName = Get-SafeCiValue -Value ([string]$env:GITHUB_REF_NAME)
    sha = Get-SafeCiValue -Value ([string]$env:GITHUB_SHA) -Pattern '[^A-Fa-f0-9]'
  }
}

function Copy-EvidenceFile {
  param(
    [string]$SourcePath,
    [string]$EvidenceRoot,
    [string]$BundleEvidenceRoot
  )

  $relative = Get-RelativePath -BasePath $EvidenceRoot -Path $SourcePath
  $safeRelative = $relative -replace '(^|/)\.\.(/|$)', ''
  $destination = Join-Path $BundleEvidenceRoot ($safeRelative -replace '/', '\')
  $destinationDirectory = Split-Path -Parent $destination
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
  Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
  return $safeRelative
}

function Select-EvidenceFilesForBundle {
  param(
    [object[]]$Files,
    [string[]]$SelectedTargetIds,
    [bool]$HasTargetFilter
  )

  if (-not $HasTargetFilter) {
    return @($Files)
  }

  $selected = New-Object System.Collections.Generic.HashSet[string]
  foreach ($targetId in $SelectedTargetIds) {
    $normalized = Normalize-Token $targetId
    if ($normalized) {
      [void]$selected.Add($normalized)
    }
  }

  $filtered = New-Object System.Collections.Generic.List[object]
  foreach ($file in $Files) {
    $include = $true
    try {
      $evidence = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      $target = Get-SupportTargetId -Evidence $evidence
      if ($target) {
        $include = $selected.Contains($target)
      }
    } catch {
      $include = $true
    }

    if ($include) {
      $filtered.Add($file) | Out-Null
    }
  }

  return @($filtered | ForEach-Object { $_ })
}

function New-SelfTestEvidence {
  param([string]$Path)

  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $windowsCollectionEvidence = [ordered]@{
    Source = "node-enterprise-deploy-kit/status.ps1"
    Collector = "status.ps1"
    CollectorVersion = 1
    CollectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    WorkflowDispatch = [ordered]@{
      EvidenceName = "windows-11-standalone-winsw-iis"
      ExpectedTargetId = "windows-11"
      ExpectedNextJsMode = "standalone"
      ExpectedServiceManager = "winsw"
      ExpectedReverseProxy = "iis"
      MinimumUptimeHours = "72"
    }
    Ci = [ordered]@{
      IsCi = $true
      Provider = "github-actions"
      WorkflowName = "host-evidence"
      RunId = "123456789"
      RunAttempt = "1"
      EventName = "workflow_dispatch"
      RefName = "main"
      Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    LiveHost = $true
    Synthetic = $false
    Mock = $false
    Sample = $false
  }
  $unixCollectionEvidence = [ordered]@{
    source = "node-enterprise-deploy-kit/status-node-app.sh"
    collector = "scripts/linux/status-node-app.sh"
    collectorVersion = 1
    collectorSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    workflowDispatch = [ordered]@{
      evidenceName = "ubuntu-standalone-systemd-nginx"
      expectedTargetId = "ubuntu"
      expectedNextJsMode = "standalone"
      expectedServiceManager = "systemd"
      expectedReverseProxy = "nginx"
      minimumUptimeHours = "72"
    }
    ci = [ordered]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "123456790"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    liveHost = $true
    synthetic = $false
    mock = $false
    sample = $false
  }
  $windows = [ordered]@{
    EvidenceSchemaVersion = 1
    EvidenceCollection = $windowsCollectionEvidence
    SupportTargetId = "windows-11"
    GeneratedAtUtc = $now
    AppName = "example-next-app"
    Platform = [ordered]@{
      Family = "windows"
      SupportTargetId = "windows-11"
      OsCaption = "Microsoft Windows 11 Pro"
      OsVersion = "10.0.22631"
      OsBuildNumber = "22631"
      OsArchitecture = "64-bit"
      ServiceManager = "winsw"
      AppFramework = "nextjs"
      NextjsDeploymentMode = "standalone"
    }
    Service = [ordered]@{
      Installed = $true
      Status = "Running"
      StartType = "Automatic"
      ProcessId = 4321
    }
    ServiceDefinition = [ordered]@{
      Checked = $true
      Manager = "winsw"
      DefinitionSource = "winsw-xml"
      DefinitionExists = $true
      ServiceWrapperMatchesConfig = $true
      NodeExeMatchesConfig = $true
      WorkingDirectoryMatchesConfig = $true
      ArgumentsMatchConfig = $true
    }
    Port = [ordered]@{
      Checked = $true
      Port = 3000
      Listening = $true
      OwnerReadable = $true
      OwnerProcessCount = 1
      ServiceProcessIdsKnown = $true
      OwnedByService = $true
    }
    Health = [ordered]@{
      Checked = $true
      Url = "http://127.0.0.1:3000/health"
      Status = "ok"
      StatusCode = 200
      TimeoutSeconds = 10
    }
    Uptime = [ordered]@{
      HostUptimeSeconds = 345600
      ServiceUptimeSeconds = 259200
      MinimumUptimeHours = 72
      MinimumSatisfied = $true
      ServiceStartKnown = $true
    }
    HealthMonitor = [ordered]@{
      Status = "ok"
      Scheduled = $true
      ScheduleType = "windows-task"
      TaskExists = $true
      TaskActionChecked = $true
      TaskActionUsesHealthCheckScript = $true
      TaskActionUsesConfigPath = $true
      TaskLastResult = 0
      TaskMissedRuns = 0
      StateExists = $true
      ConsecutiveFailures = 0
      LastSuccessAgeSeconds = 60
      LastSuccessFresh = $true
      LogExists = $true
      LogFailureCount = 0
      LogRestartCount = 0
    }
    NextJsRuntime = [ordered]@{
      Applicable = $true
      Status = "ok"
      AppFramework = "nextjs"
      Mode = "standalone"
      NodeVersion = "v20.11.1"
      MinimumNodeVersion = "20.9.0"
      NodeVersionSatisfied = $true
      NextVersion = "14.2.3"
      RuntimeRootName = "example-next-app"
    }
    ReverseProxy = [ordered]@{
      Applicable = $true
      Mode = "iis"
      Status = "ok"
      ProbeUrl = "https://example.local/health"
      StatusCode = 200
      Iis = [ordered]@{
        Applicable = $true
        ModuleAvailable = $true
        SiteExists = $true
        SiteStarted = $true
        SitePathMatchesConfig = $true
        BindingMatchesConfig = $true
        DuplicateBindingConflict = $false
      }
    }
    DeploymentIdentity = [ordered]@{
      Status = "ok"
      AppDirectoryName = "example-next-app"
      DeploymentId = "example-deploy-001"
      NextBuildId = "example-build-windows"
      PackageSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    Verdict = "Healthy"
    Critical = 0
    Warnings = 0
    Findings = @()
  }
  $linux = [ordered]@{
    evidenceSchemaVersion = 1
    evidenceCollection = $unixCollectionEvidence
    supportTargetId = "ubuntu"
    generatedAtUtc = $now
    appName = "example-next-app"
    serviceName = "example-next-app"
    serviceManager = "systemd"
    serviceActiveStatus = "active"
    serviceEnabledStatus = "enabled"
    serviceDefinition = [ordered]@{
      checked = $true
      manager = "systemd"
      definitionSource = "systemd-unit"
      definitionExists = $true
      nodeExeMatchesConfig = $true
      workingDirectoryMatchesConfig = $true
      argumentsMatchConfig = $true
      runnerScriptMatchesConfig = $false
    }
    platform = [ordered]@{
      family = "linux"
      supportTargetId = "ubuntu"
      osId = "ubuntu"
      osIdLike = "debian ubuntu"
      osVersionId = "24.04"
      osPrettyName = "Ubuntu 24.04 LTS"
      kernelName = "Linux"
      kernelRelease = "6.8.0"
      machine = "x86_64"
      libcName = "glibc"
      libcVersion = "2.39"
      serviceManager = "systemd"
      appFramework = "nextjs"
      nextjsDeploymentMode = "standalone"
    }
    port = [ordered]@{
      checked = $true
      port = "3000"
      listening = $true
      ownerReadable = $true
      ownerProcessCount = 1
      servicePidKnown = $true
      ownedByService = $true
    }
    health = [ordered]@{
      checked = $true
      url = "http://127.0.0.1:3000/health"
      status = "ok"
      statusCode = 200
      responseSeconds = "0.012"
      timeoutSeconds = "10"
    }
    uptime = [ordered]@{
      hostUptimeSeconds = 345600
      serviceUptimeSeconds = 259200
      minimumUptimeHours = "72"
      minimumSatisfied = $true
      serviceStartKnown = $true
    }
    healthMonitor = [ordered]@{
      status = "ok"
      scheduled = $true
      scheduleType = "systemd-timer"
      schedulerChecked = $true
      schedulerExists = $true
      schedulerActive = $true
      schedulerEnabled = $true
      schedulerActiveStatus = "active"
      schedulerEnabledStatus = "enabled"
      stateExists = $true
      consecutiveFailures = 0
      lastSuccessAgeSeconds = 60
      lastSuccessFresh = $true
      logExists = $true
      logFailureCount = 0
      logRestartCount = 0
    }
    nextJsRuntime = [ordered]@{
      applicable = $true
      status = "ok"
      appFramework = "nextjs"
      mode = "standalone"
      nodeVersion = "v20.11.1"
      minimumNodeVersion = "20.9.0"
      nodeVersionSatisfied = $true
      nextVersion = "14.2.3"
      runtimeRootName = "example-next-app"
    }
    reverseProxy = [ordered]@{
      applicable = $true
      mode = "nginx"
      status = "ok"
      probeUrl = "https://example.local/health"
      statusCode = 200
      config = [ordered]@{
        applicable = $true
        pathName = "example-next-app.conf"
        directoryName = "conf.d"
        exists = $true
        managedMarkerFound = $true
        expectedPort = "80"
      }
    }
    deploymentIdentity = [ordered]@{
      status = "ok"
      appDirectoryName = "example-next-app"
      deploymentId = "example-deploy-001"
      nextBuildId = "example-build-linux"
      packageSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    verdict = "Healthy"
    critical = 0
    warnings = 0
    findings = @()
  }

  $legacyWindows = $windows | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $legacyWindows.SupportTargetId = "windows-server-2012"
  $legacyWindows.Platform.SupportTargetId = "windows-server-2012"
  $legacyWindows.Platform.OsCaption = "Microsoft Windows Server 2012 Datacenter"
  $legacyWindows.Platform.OsVersion = "6.2.9200"
  $legacyWindows.Platform.OsBuildNumber = "9200"

  $windows | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "windows-11-winsw-iis.json") -Encoding UTF8
  $legacyWindows | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "windows-server-2012-winsw-iis.json") -Encoding UTF8
  $linux | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "ubuntu-systemd-nginx.json") -Encoding UTF8
}

function Get-UniqueManifestValues {
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

Write-Host ""
Write-Host "==> Support evidence bundle"

if ($SelfTest) {
  $selfTestId = [Guid]::NewGuid().ToString('N')
  $EvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-$selfTestId\evidence"
  $defaultOutputDirectory = Join-Path $RepoRoot ".tmp\support-evidence-bundles"
  $resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
  $resolvedDefaultOutputDirectory = [System.IO.Path]::GetFullPath($defaultOutputDirectory).TrimEnd('\', '/')
  if ($resolvedOutputDirectory.Equals($resolvedDefaultOutputDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    $OutputDirectory = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output-$selfTestId"
  }
  $BundleName = "selftest-support-evidence"
  $TargetId = @("windows-11", "ubuntu")
  $MaxEvidenceAgeDays = 30
  $NoZip = $false
  New-SelfTestEvidence -Path $EvidencePath

  if (-not $ValidateSupportClaim -and -not $RequireBothNextJsModes -and -not $RequireDeclaredServiceManagers -and -not $RequireDeclaredReverseProxies -and -not $RequireHostEvidenceWorkflowCollection) {
    $failedMissingClaimGate = $false
    try {
      & $PSCommandPath -SelfTest -RequireHostEvidenceWorkflowCollection *> $null
    } catch {
      $failedMissingClaimGate = ($_.Exception.Message -match "require -ValidateSupportClaim")
    }
    if (-not $failedMissingClaimGate) {
      throw "Support evidence bundle self-test failed: claim-only strict switches should require -ValidateSupportClaim."
    }
  }
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  throw "EvidencePath is required unless -SelfTest is used."
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $(Get-DisplayPath -Path $EvidencePath)"
}
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $(Get-DisplayPath -Path $MatrixPath)"
}
if ($BundleName -notmatch '^[A-Za-z0-9._-]+$') {
  throw "BundleName must contain only letters, numbers, dot, underscore, or dash."
}

$claimOnlyRequirements = New-Object System.Collections.Generic.List[string]
if ($RequireBothNextJsModes) { $claimOnlyRequirements.Add("-RequireBothNextJsModes") | Out-Null }
if ($RequireDeclaredServiceManagers) { $claimOnlyRequirements.Add("-RequireDeclaredServiceManagers") | Out-Null }
if ($RequireDeclaredReverseProxies) { $claimOnlyRequirements.Add("-RequireDeclaredReverseProxies") | Out-Null }
if ($RequireHostEvidenceWorkflowCollection) { $claimOnlyRequirements.Add("-RequireHostEvidenceWorkflowCollection") | Out-Null }
if ($claimOnlyRequirements.Count -gt 0 -and -not $ValidateSupportClaim) {
  throw "$($claimOnlyRequirements -join ', ') require -ValidateSupportClaim because they are enforced by the target-aware support-claim gate."
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null

$allMatrixTargets = @(Select-MatrixTargets -Path $MatrixPath -TargetId @() -Category @() -ProductionRecommendedOnly $false)
$allMatrixTargetIds = @($allMatrixTargets | ForEach-Object { Normalize-Token ([string]$_.id) })
$selectedTargets = @(Select-MatrixTargets -Path $MatrixPath -TargetId $TargetId -Category $Category -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly))
$selectedTargetIds = @($selectedTargets | ForEach-Object { Normalize-Token ([string]$_.id) })
$hasTargetFilter = ($TargetId.Count -gt 0 -or $Category.Count -gt 0 -or [bool]$ProductionRecommendedOnly)
$supportScopeKind = Get-SupportScopeKind `
  -SelectedTargetIds $selectedTargetIds `
  -AllTargetIds $allMatrixTargetIds `
  -TargetId $TargetId `
  -Category $Category `
  -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly) `
  -RequireCoverageComplete ([bool]$RequireCoverageComplete)
$bundleProofLevel = Get-BundleProofLevel `
  -RequireCollectorSha256 ([bool]$RequireCollectorSha256) `
  -RequireHostEvidenceWorkflowCollection ([bool]$RequireHostEvidenceWorkflowCollection) `
  -RequireMinimumUptimeHours $RequireMinimumUptimeHours

$hostEvidenceArgs = @{
  EvidencePath = $EvidencePath
  MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  RequireNextJs = $true
  RequireReverseProxy = $true
  RequireDeploymentIdentity = $true
}
if ($hasTargetFilter) { $hostEvidenceArgs.RequiredTargets = [string[]]$selectedTargetIds }
if ($RequireCollectorSha256) { $hostEvidenceArgs.RequireCollectorSha256 = $true }
if ($RequireMinimumUptimeHours -gt 0) { $hostEvidenceArgs.RequireMinimumUptimeHours = $RequireMinimumUptimeHours }
if (-not $AllowWarnings) { $hostEvidenceArgs.FailOnWarnings = $true }
if ($AllowReverseProxyNone -or $IncludeServiceOnly) { $hostEvidenceArgs.AllowReverseProxyNone = $true }
& (Join-Path $ScriptDir "Test-HostEvidence.ps1") @hostEvidenceArgs | Out-Null

if ($ValidateSupportClaim) {
  $claimArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  }
  if ($hasTargetFilter) { $claimArgs.TargetId = [string[]]$selectedTargetIds }
  if ($AllowWarnings) { $claimArgs.AllowWarnings = $true }
  if ($RequireBothNextJsModes) { $claimArgs.RequireBothNextJsModes = $true }
  if ($RequireDeclaredServiceManagers) { $claimArgs.RequireDeclaredServiceManagers = $true }
  if ($RequireDeclaredReverseProxies) { $claimArgs.RequireDeclaredReverseProxies = $true }
  if ($IncludeServiceOnly) { $claimArgs.IncludeServiceOnly = $true }
  if ($IncludeFallback) { $claimArgs.IncludeFallback = $true }
  if ($RequireCollectorSha256) { $claimArgs.RequireCollectorSha256 = $true }
  if ($RequireHostEvidenceWorkflowCollection) { $claimArgs.RequireHostEvidenceWorkflowCollection = $true }
  if ($RequireMinimumUptimeHours -gt 0) { $claimArgs.RequireMinimumUptimeHours = $RequireMinimumUptimeHours }
  if ($AllowReverseProxyNone -or $IncludeServiceOnly) { $claimArgs.AllowReverseProxyNone = $true }
  & (Join-Path $ScriptDir "Test-SupportClaim.ps1") @claimArgs | Out-Null
}

if ($RequireCoverageComplete) {
  $coverageArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  }
  if ($hasTargetFilter) { $coverageArgs.TargetId = [string[]]$selectedTargetIds }
  if ($ProductionRecommendedOnly) { $coverageArgs.ProductionRecommendedOnly = $true }
  if ($AllowWarnings) { $coverageArgs.AllowWarnings = $true }
  if ($IncludeServiceOnly) { $coverageArgs.IncludeServiceOnly = $true }
  if ($IncludeFallback) { $coverageArgs.IncludeFallback = $true }
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") @coverageArgs | Out-Null
}

$safeName = $BundleName -replace '[^A-Za-z0-9._-]', '-'
$bundleRoot = Join-Path $OutputDirectory $safeName
$bundleEvidenceRoot = Join-Path $bundleRoot "evidence"
if (Test-Path -LiteralPath $bundleRoot) {
  Remove-Item -LiteralPath $bundleRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $bundleEvidenceRoot | Out-Null

$files = @(Get-ChildItem -Path $EvidencePath -Recurse -File -Filter "*.json" | Sort-Object FullName)
if ($files.Count -eq 0) {
  throw "No JSON evidence files found in $(Get-DisplayPath -Path $EvidencePath)"
}
$files = @(Select-EvidenceFilesForBundle -Files $files -SelectedTargetIds $selectedTargetIds -HasTargetFilter ([bool]$hasTargetFilter))
if ($files.Count -eq 0) {
  throw "No JSON evidence files matched the requested bundle target filters."
}

$manifestFiles = New-Object System.Collections.Generic.List[object]
$matrixTargetsById = Get-MatrixTargetsById -Path $MatrixPath
foreach ($file in $files) {
  $relative = Copy-EvidenceFile -SourcePath $file.FullName -EvidenceRoot $EvidencePath -BundleEvidenceRoot $bundleEvidenceRoot
  $bundleFile = Join-Path $bundleEvidenceRoot ($relative -replace '/', '\')
  $sha256 = (Get-FileHash -LiteralPath $bundleFile -Algorithm SHA256).Hash.ToLowerInvariant()
  $parseError = ""
  $target = ""
  $targetCategory = ""
  $nodeRuntimeMinimumNodeVersion = ""
  $nodeRuntimeSupportTier = ""
  $nodeRuntimeProductionRecommended = $null
  $nodeRuntimeRequirements = ""
  $workflowDispatchSupported = $null
  $localCommandOnly = $null
  $mode = ""
  $serviceManager = ""
  $reverseProxy = ""
  $nodeVersion = ""
  $minimumNodeVersion = ""
  $nodeVersionSatisfied = $null
  $nextVersion = ""
  $generatedAt = ""
  $verdict = ""
  $critical = $null
  $warnings = $null
  $deploymentId = ""
  $nextBuildId = ""
  $packageSha256 = ""
  $collectorSource = ""
  $collector = ""
  $collectorVersion = $null
  $collectorSha256 = ""
  $liveHost = $null
  $synthetic = $null
  $mock = $null
  $sample = $null
  $collectionCiIsCi = $null
  $collectionCiProvider = ""
  $collectionCiWorkflowName = ""
  $collectionCiRunId = ""
  $collectionCiRunAttempt = ""
  $collectionCiEventName = ""
  $collectionCiRefName = ""
  $collectionCiSha = ""
  $collectionWorkflowDispatchEvidenceName = ""
  $collectionWorkflowDispatchExpectedTargetId = ""
  $collectionWorkflowDispatchExpectedNextJsMode = ""
  $collectionWorkflowDispatchExpectedServiceManager = ""
  $collectionWorkflowDispatchExpectedReverseProxy = ""
  $collectionWorkflowDispatchMinimumUptimeHours = $null
  $collectionWorkflowDispatchMatchesDimensions = $null
  try {
    $evidence = Get-Content -LiteralPath $bundleFile -Raw | ConvertFrom-Json
    $target = Get-SupportTargetId -Evidence $evidence
    if ($target -and $matrixTargetsById.ContainsKey($target)) {
      $matrixTarget = $matrixTargetsById[$target]
      $targetCategory = [string]$matrixTarget.category
      $nodeRuntimeSupport = Get-PropertyValue -Object $matrixTarget -Names @("nodeRuntimeSupport")
      $nodeRuntimeMinimumNodeVersion = Get-StringValue -Object $nodeRuntimeSupport -Names @("minimumNodeVersion")
      $nodeRuntimeSupportTier = Get-StringValue -Object $nodeRuntimeSupport -Names @("supportTier")
      $nodeRuntimeProductionRecommended = Get-BooleanValue -Object $nodeRuntimeSupport -Names @("productionRecommended") -Default $null
      $nodeRuntimeRequirements = Get-StringValue -Object $nodeRuntimeSupport -Names @("requirements")
      $workflowDispatchSupported = Test-TargetWorkflowDispatchSupported -Target $matrixTarget
      $localCommandOnly = -not [bool]$workflowDispatchSupported
    }
    $mode = Get-NextJsMode -Evidence $evidence
    $serviceManager = Get-ServiceManager -Evidence $evidence
    $reverseProxy = Get-ReverseProxyMode -Evidence $evidence
    $nodeVersion = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersion", "nodeVersion")
    $minimumNodeVersion = Get-NextJsRuntimeValue -Evidence $evidence -Names @("MinimumNodeVersion", "minimumNodeVersion")
    $nodeVersionSatisfiedText = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersionSatisfied", "nodeVersionSatisfied")
    if (-not [string]::IsNullOrWhiteSpace($nodeVersionSatisfiedText)) {
      $nodeVersionSatisfied = ($nodeVersionSatisfiedText.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
    }
    $nextVersion = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NextVersion", "nextVersion")
    $generatedAt = Get-StringValue -Object $evidence -Names @("GeneratedAtUtc", "generatedAtUtc")
    $verdict = Get-StringValue -Object $evidence -Names @("Verdict", "verdict")
    $critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
    $warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
    $deploymentId = Get-DeploymentIdentityValue -Evidence $evidence -Names @("DeploymentId", "deploymentId")
    $nextBuildId = Get-DeploymentIdentityValue -Evidence $evidence -Names @("NextBuildId", "nextBuildId")
    $packageSha256 = Get-DeploymentIdentityValue -Evidence $evidence -Names @("PackageSha256", "packageSha256")
    $collection = Get-EvidenceCollectionEvidence -Evidence $evidence
    $collectorSource = $collection.Source
    $collector = $collection.Collector
    $collectorVersion = $collection.CollectorVersion
    $collectorSha256 = $collection.CollectorSha256
    $liveHost = $collection.LiveHost
    $synthetic = $collection.Synthetic
    $mock = $collection.Mock
    $sample = $collection.Sample
    $collectionCiIsCi = $collection.Ci.IsCi
    $collectionCiProvider = $collection.Ci.Provider
    $collectionCiWorkflowName = $collection.Ci.WorkflowName
    $collectionCiRunId = $collection.Ci.RunId
    $collectionCiRunAttempt = $collection.Ci.RunAttempt
    $collectionCiEventName = $collection.Ci.EventName
    $collectionCiRefName = $collection.Ci.RefName
    $collectionCiSha = $collection.Ci.Sha
    $collectionWorkflowDispatchEvidenceName = $collection.WorkflowDispatch.EvidenceName
    $collectionWorkflowDispatchExpectedTargetId = $collection.WorkflowDispatch.ExpectedTargetId
    $collectionWorkflowDispatchExpectedNextJsMode = $collection.WorkflowDispatch.ExpectedNextJsMode
    $collectionWorkflowDispatchExpectedServiceManager = $collection.WorkflowDispatch.ExpectedServiceManager
    $collectionWorkflowDispatchExpectedReverseProxy = $collection.WorkflowDispatch.ExpectedReverseProxy
    $collectionWorkflowDispatchMinimumUptimeHours = $collection.WorkflowDispatch.MinimumUptimeHours
    $collectionWorkflowDispatchMatchesDimensions = Test-WorkflowDispatchMatchesEvidence -Dispatch $collection.WorkflowDispatch -TargetId $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy -RequiredMinimumUptimeHours $RequireMinimumUptimeHours
  } catch {
    $parseError = $_.Exception.Message
  }

  $manifestFiles.Add([pscustomobject]@{
    path = "evidence/$relative"
    sha256 = $sha256
    bytes = (Get-Item -LiteralPath $bundleFile).Length
    supportTargetId = $target
    targetCategory = $targetCategory
    nodeRuntimeMinimumNodeVersion = $nodeRuntimeMinimumNodeVersion
    nodeRuntimeSupportTier = $nodeRuntimeSupportTier
    nodeRuntimeProductionRecommended = $nodeRuntimeProductionRecommended
    nodeRuntimeRequirements = $nodeRuntimeRequirements
    workflowDispatchSupported = $workflowDispatchSupported
    localCommandOnly = $localCommandOnly
    nextJsMode = $mode
    serviceManager = $serviceManager
    reverseProxy = $reverseProxy
    nodeVersion = $nodeVersion
    minimumNodeVersion = $minimumNodeVersion
    nodeVersionSatisfied = $nodeVersionSatisfied
    nextVersion = $nextVersion
    generatedAtUtc = $generatedAt
    verdict = $verdict
    critical = $critical
    warnings = $warnings
    deploymentId = $deploymentId
    nextBuildId = $nextBuildId
    packageSha256 = $packageSha256
    collectorSource = $collectorSource
    collector = $collector
    collectorVersion = $collectorVersion
    collectorSha256 = $collectorSha256
    liveHost = $liveHost
    synthetic = $synthetic
    mock = $mock
    sample = $sample
    collectionCiIsCi = $collectionCiIsCi
    collectionCiProvider = $collectionCiProvider
    collectionCiWorkflowName = $collectionCiWorkflowName
    collectionCiRunId = $collectionCiRunId
    collectionCiRunAttempt = $collectionCiRunAttempt
    collectionCiEventName = $collectionCiEventName
    collectionCiRefName = $collectionCiRefName
    collectionCiSha = $collectionCiSha
    collectionWorkflowDispatchEvidenceName = $collectionWorkflowDispatchEvidenceName
    collectionWorkflowDispatchExpectedTargetId = $collectionWorkflowDispatchExpectedTargetId
    collectionWorkflowDispatchExpectedNextJsMode = $collectionWorkflowDispatchExpectedNextJsMode
    collectionWorkflowDispatchExpectedServiceManager = $collectionWorkflowDispatchExpectedServiceManager
    collectionWorkflowDispatchExpectedReverseProxy = $collectionWorkflowDispatchExpectedReverseProxy
    collectionWorkflowDispatchMinimumUptimeHours = $collectionWorkflowDispatchMinimumUptimeHours
    collectionWorkflowDispatchMatchesDimensions = $collectionWorkflowDispatchMatchesDimensions
    parseError = $parseError
  }) | Out-Null
}

$manifestRows = @($manifestFiles | ForEach-Object { $_ })
$summaryTargets = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "supportTargetId")
$summaryNextJsModes = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "nextJsMode")
$summaryServiceManagers = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "serviceManager")
$summaryReverseProxies = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "reverseProxy")
$summaryCollectors = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "collector")
$workflowCapableEvidenceCount = @($manifestRows | Where-Object { $_.workflowDispatchSupported -eq $true }).Count
$localCommandOnlyEvidenceCount = @($manifestRows | Where-Object { $_.localCommandOnly -eq $true }).Count

$manifest = [ordered]@{
  schemaVersion = 1
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  bundleName = $safeName
  matrixPath = Get-RelativePath -BasePath $RepoRoot -Path $MatrixPath
  matrixSha256 = (Get-FileHash -LiteralPath $MatrixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  sourceControl = Get-SourceControlProvenance
  ci = Get-CiProvenance
  sourceEvidencePathName = [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($EvidencePath)).TrimEnd('\', '/'))
  maxEvidenceAgeDays = $MaxEvidenceAgeDays
  allowWarnings = [bool]$AllowWarnings
  supportClaimValidated = [bool]$ValidateSupportClaim
  requireCollectorSha256 = [bool]$RequireCollectorSha256
  requireHostEvidenceWorkflowCollection = [bool]$RequireHostEvidenceWorkflowCollection
  requireMinimumUptimeHours = $RequireMinimumUptimeHours
  coverageCompleteRequired = [bool]$RequireCoverageComplete
  targetIds = @($TargetId)
  categories = @($Category)
  productionRecommendedOnly = [bool]$ProductionRecommendedOnly
  selectedTargets = $selectedTargetIds
  supportScope = [ordered]@{
    kind = $supportScopeKind
    proofLevel = $bundleProofLevel
    fullMatrix = [bool]($supportScopeKind -eq "full-matrix")
    targetFiltersApplied = [bool]($TargetId.Count -gt 0 -or $Category.Count -gt 0)
    productionRecommendedOnly = [bool]$ProductionRecommendedOnly
    selectedTargetCount = $selectedTargetIds.Count
    matrixTargetCount = $allMatrixTargetIds.Count
    selectedTargets = $selectedTargetIds
    includeServiceOnly = [bool]$IncludeServiceOnly
    includeFallback = [bool]$IncludeFallback
    supportClaimValidated = [bool]$ValidateSupportClaim
    requireBothNextJsModes = [bool]$RequireBothNextJsModes
    requireDeclaredServiceManagers = [bool]$RequireDeclaredServiceManagers
    requireDeclaredReverseProxies = [bool]$RequireDeclaredReverseProxies
    workflowCapableEvidenceCount = $workflowCapableEvidenceCount
    localCommandOnlyEvidenceCount = $localCommandOnlyEvidenceCount
    requiredMinimumUptimeHours = $RequireMinimumUptimeHours
  }
  summary = [ordered]@{
    evidenceFileCount = $manifestFiles.Count
    targets = $summaryTargets
    nextJsModes = $summaryNextJsModes
    serviceManagers = $summaryServiceManagers
    reverseProxies = $summaryReverseProxies
    collectors = $summaryCollectors
  }
  files = $manifestRows
}

$manifestPath = Join-Path $bundleRoot "support-evidence-manifest.json"
($manifest | ConvertTo-Json -Depth 8) | Set-Content -Path $manifestPath -Encoding UTF8

$zipPath = ""
if (-not $NoZip) {
  $zipPath = Join-Path $OutputDirectory "$safeName.zip"
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $bundleRoot "*") -DestinationPath $zipPath -Force
}

$manifestDisplayPath = Get-DisplayPath -Path $manifestPath
$zipDisplayPath = Get-DisplayPath -Path $zipPath

Write-Host "Support evidence manifest: $manifestDisplayPath"
if ($zipPath) {
  Write-Host "Support evidence bundle: $zipDisplayPath" -ForegroundColor Green
}

if ($SelfTest) {
  foreach ($displayPath in @($manifestDisplayPath, $zipDisplayPath)) {
    if ([System.IO.Path]::IsPathRooted([string]$displayPath) -or ([string]$displayPath).Contains($RepoRoot)) {
      throw "Support evidence bundle self-test leaked an absolute display path."
    }
  }
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Support evidence bundle self-test did not create manifest."
  }
  if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Support evidence bundle self-test did not create zip."
  }
  $manifestCheck = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifestCheck.summary.evidenceFileCount -ne 2) {
    throw "Support evidence bundle self-test expected 2 selected evidence files."
  }
  $selfTestTargets = @($manifestCheck.summary.targets)
  if ($selfTestTargets -contains "windows-server-2012") {
    throw "Support evidence bundle self-test included a non-selected evidence target."
  }
  foreach ($expectedTarget in @("windows-11", "ubuntu")) {
    if ($selfTestTargets -notcontains $expectedTarget) {
      throw "Support evidence bundle self-test did not include selected target '$expectedTarget'."
    }
  }
  if (-not $manifestCheck.PSObject.Properties["supportScope"]) {
    throw "Support evidence bundle self-test manifest is missing supportScope metadata."
  }
  if ([string]$manifestCheck.supportScope.kind -ne "filtered") {
    throw "Support evidence bundle self-test supportScope.kind should be filtered."
  }
  if ([int]$manifestCheck.supportScope.selectedTargetCount -ne 2) {
    throw "Support evidence bundle self-test supportScope selectedTargetCount is incorrect."
  }
  if ([int]$manifestCheck.supportScope.matrixTargetCount -le [int]$manifestCheck.supportScope.selectedTargetCount) {
    throw "Support evidence bundle self-test supportScope did not preserve matrix target count."
  }
  if ([int]$manifestCheck.supportScope.workflowCapableEvidenceCount -ne 2) {
    throw "Support evidence bundle self-test supportScope workflowCapableEvidenceCount is incorrect."
  }
  if ([int]$manifestCheck.supportScope.localCommandOnlyEvidenceCount -ne 0) {
    throw "Support evidence bundle self-test supportScope localCommandOnlyEvidenceCount is incorrect."
  }
  foreach ($row in @($manifestCheck.files)) {
    foreach ($requiredWorkflowDispatchProperty in @(
        "collectionWorkflowDispatchEvidenceName",
        "collectionWorkflowDispatchExpectedTargetId",
        "collectionWorkflowDispatchExpectedNextJsMode",
        "collectionWorkflowDispatchExpectedServiceManager",
        "collectionWorkflowDispatchExpectedReverseProxy",
        "collectionWorkflowDispatchMinimumUptimeHours",
        "collectionWorkflowDispatchMatchesDimensions"
      )) {
      if (-not $row.PSObject.Properties[$requiredWorkflowDispatchProperty]) {
        throw "Support evidence bundle self-test manifest row is missing $requiredWorkflowDispatchProperty."
      }
    }
    if ($row.workflowDispatchSupported -eq $true -and $row.collectionWorkflowDispatchMatchesDimensions -ne $true) {
      throw "Support evidence bundle self-test manifest row did not preserve matching workflow dispatch metadata."
    }
  }
}
