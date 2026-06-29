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
  [switch]$RequireCoverageComplete,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
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

function Test-WorkflowDispatchSupported {
  param([string]$Category)
  return ($Category -in @("windows-client", "windows-server", "linux", "macos"))
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

function New-SelfTestEvidence {
  param([string]$Path)

  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $windowsCollectionEvidence = [ordered]@{
    Source = "node-enterprise-deploy-kit/status.ps1"
    Collector = "status.ps1"
    CollectorVersion = 1
    CollectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
      osPrettyName = "Ubuntu 24.04 LTS"
      kernelName = "Linux"
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

  $windows | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "windows-11-winsw-iis.json") -Encoding UTF8
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
  $EvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-$([Guid]::NewGuid().ToString('N'))\evidence"
  $OutputDirectory = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output"
  $BundleName = "selftest-support-evidence"
  $TargetId = @("windows-11", "ubuntu")
  $MaxEvidenceAgeDays = 30
  $NoZip = $false
  New-SelfTestEvidence -Path $EvidencePath
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  throw "EvidencePath is required unless -SelfTest is used."
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $EvidencePath"
}
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}
if ($BundleName -notmatch '^[A-Za-z0-9._-]+$') {
  throw "BundleName must contain only letters, numbers, dot, underscore, or dash."
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null

$hostEvidenceArgs = @{
  EvidencePath = $EvidencePath
  MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  RequireNextJs = $true
  RequireReverseProxy = $true
  RequireDeploymentIdentity = $true
}
if ($TargetId.Count -gt 0) { $hostEvidenceArgs.RequiredTargets = [string[]]$TargetId }
if (-not $AllowWarnings) { $hostEvidenceArgs.FailOnWarnings = $true }
if ($AllowReverseProxyNone -or $IncludeServiceOnly) { $hostEvidenceArgs.AllowReverseProxyNone = $true }
& (Join-Path $ScriptDir "Test-HostEvidence.ps1") @hostEvidenceArgs | Out-Null

if ($ValidateSupportClaim) {
  $claimArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  }
  if ($TargetId.Count -gt 0) { $claimArgs.TargetId = [string[]]$TargetId }
  if ($Category.Count -gt 0) { $claimArgs.Category = [string[]]$Category }
  if ($AllowWarnings) { $claimArgs.AllowWarnings = $true }
  if ($RequireBothNextJsModes) { $claimArgs.RequireBothNextJsModes = $true }
  if ($RequireDeclaredServiceManagers) { $claimArgs.RequireDeclaredServiceManagers = $true }
  if ($RequireDeclaredReverseProxies) { $claimArgs.RequireDeclaredReverseProxies = $true }
  if ($AllowReverseProxyNone -or $IncludeServiceOnly) { $claimArgs.AllowReverseProxyNone = $true }
  & (Join-Path $ScriptDir "Test-SupportClaim.ps1") @claimArgs | Out-Null
}

if ($RequireCoverageComplete) {
  $coverageArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  }
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
  throw "No JSON evidence files found in $EvidencePath"
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
  $workflowDispatchSupported = $null
  $localCommandOnly = $null
  $mode = ""
  $serviceManager = ""
  $reverseProxy = ""
  $nodeVersion = ""
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
  try {
    $evidence = Get-Content -LiteralPath $bundleFile -Raw | ConvertFrom-Json
    $target = Get-SupportTargetId -Evidence $evidence
    if ($target -and $matrixTargetsById.ContainsKey($target)) {
      $targetCategory = [string]$matrixTargetsById[$target].category
      $workflowDispatchSupported = Test-WorkflowDispatchSupported -Category $targetCategory
      $localCommandOnly = -not [bool]$workflowDispatchSupported
    }
    $mode = Get-NextJsMode -Evidence $evidence
    $serviceManager = Get-ServiceManager -Evidence $evidence
    $reverseProxy = Get-ReverseProxyMode -Evidence $evidence
    $nodeVersion = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersion", "nodeVersion")
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
  } catch {
    $parseError = $_.Exception.Message
  }

  $manifestFiles.Add([pscustomobject]@{
    path = "evidence/$relative"
    sha256 = $sha256
    bytes = (Get-Item -LiteralPath $bundleFile).Length
    supportTargetId = $target
    targetCategory = $targetCategory
    workflowDispatchSupported = $workflowDispatchSupported
    localCommandOnly = $localCommandOnly
    nextJsMode = $mode
    serviceManager = $serviceManager
    reverseProxy = $reverseProxy
    nodeVersion = $nodeVersion
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
    parseError = $parseError
  }) | Out-Null
}

$manifestRows = @($manifestFiles | ForEach-Object { $_ })
$summaryTargets = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "supportTargetId")
$summaryNextJsModes = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "nextJsMode")
$summaryServiceManagers = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "serviceManager")
$summaryReverseProxies = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "reverseProxy")
$summaryCollectors = @(Get-UniqueManifestValues -Rows $manifestRows -PropertyName "collector")

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
  coverageCompleteRequired = [bool]$RequireCoverageComplete
  targetIds = @($TargetId)
  categories = @($Category)
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

Write-Host "Support evidence manifest: $manifestPath"
if ($zipPath) {
  Write-Host "Support evidence bundle: $zipPath" -ForegroundColor Green
}

if ($SelfTest) {
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Support evidence bundle self-test did not create manifest."
  }
  if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Support evidence bundle self-test did not create zip."
  }
  $manifestCheck = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifestCheck.summary.evidenceFileCount -ne 2) {
    throw "Support evidence bundle self-test expected 2 evidence files."
  }
}
