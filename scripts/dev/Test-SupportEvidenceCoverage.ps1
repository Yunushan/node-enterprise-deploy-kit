param(
  [string]$EvidencePath = "",
  [string]$BundlePath = "",
  [string]$MatrixPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$ProductionRecommendedOnly,
  [switch]$AllowWarnings,
  [switch]$ReportOnly,
  [ValidateSet("Table", "Json", "Csv", "Markdown")]
  [string]$Format = "Table",
  [string]$WorkflowFile = "host-evidence.yml",
  [string]$WorkflowRef = "main",
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
if (-not [string]::IsNullOrWhiteSpace($EvidencePath) -and -not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($BundlePath) -and -not [System.IO.Path]::IsPathRooted($BundlePath)) {
  $BundlePath = Join-Path (Get-Location) $BundlePath
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

function Get-OptionalPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $null
}

function Get-MatrixRequiredMinimumUptimeHours {
  param([object]$Matrix)

  try {
    $value = [int]$Matrix.requiredMinimumUptimeHours
    if ($value -lt 1) {
      throw "requiredMinimumUptimeHours must be positive."
    }
    return $value
  } catch {
    throw "Support matrix requiredMinimumUptimeHours must be a positive integer."
  }
}

function Test-ProductionRecommendedTarget {
  param([object]$Target)

  $nodeRuntimeSupport = Get-OptionalPropertyValue -Object $Target -Name "nodeRuntimeSupport"
  if ($null -eq $nodeRuntimeSupport) { return $false }
  $property = $nodeRuntimeSupport.PSObject.Properties["productionRecommended"]
  return ($property -and $property.Value -is [bool] -and [bool]$property.Value)
}

function Select-MatrixTargets {
  param(
    [object[]]$Targets,
    [string[]]$TargetId,
    [string[]]$Category,
    [bool]$ProductionRecommendedOnly
  )

  $selected = @($Targets)
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
    throw "No support matrix targets matched the requested evidence coverage filters."
  }
  return $selected
}

function Get-EvidenceFile {
  param(
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind
  )
  $fileName = "$Mode-$ServiceManager-$ReverseProxy.json"
  if ($Kind -eq "fallback") {
    $fileName = "$Mode-$ServiceManager-$ReverseProxy-fallback.json"
  }
  return "evidence/$TargetId/$fileName"
}

function Get-CollectionCommand {
  param(
    [string]$Category,
    [string]$EvidenceFile,
    [int]$RequiredMinimumUptimeHours,
    [bool]$FailOnWarnings
  )
  if ($Category -in @("windows-client", "windows-server")) {
    $windowsPath = $EvidenceFile.Replace("/", "\")
    $strictFlag = if ($FailOnWarnings) { " -FailOnWarnings" } else { "" }
    return ".\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours $RequiredMinimumUptimeHours -JsonPath .\$windowsPath -FailOnCritical$strictFlag"
  }
  $strictOption = if ($FailOnWarnings) { " --fail-on-warnings" } else { "" }
  return "sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours $RequiredMinimumUptimeHours --json-output ./$EvidenceFile --fail-on-critical$strictOption"
}

function Get-ValidationCommand {
  param(
    [string]$EvidenceFile,
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours,
    [bool]$FailOnWarnings
  )

  $windowsPath = $EvidenceFile.Replace("/", "\")
  $args = New-Object System.Collections.Generic.List[string]
  foreach ($arg in @(
      ".\scripts\dev\Test-HostEvidence.ps1",
      "-EvidencePath",
      ".\$windowsPath",
      "-RequireNextJs",
      "-RequireDeploymentIdentity",
      "-RequireCollectorSha256",
      "-RequireMinimumUptimeHours",
      [string]$RequiredMinimumUptimeHours,
      "-MaxEvidenceAgeDays",
      "1",
      "-ExpectedTargetId",
      $TargetId,
      "-ExpectedNextJsMode",
      $Mode,
      "-ExpectedServiceManager",
      $ServiceManager,
      "-ExpectedReverseProxy",
      $ReverseProxy,
      "-RequireReverseProxy"
    )) {
    $args.Add($arg) | Out-Null
  }
  if ($ReverseProxy -eq "none") {
    $args.Add("-AllowReverseProxyNone") | Out-Null
  }
  if ($FailOnWarnings) {
    $args.Add("-FailOnWarnings") | Out-Null
  }
  return ($args -join " ")
}

function Get-WorkflowPlatform {
  param([string]$Category)
  if ($Category -in @("windows-client", "windows-server")) { return "windows" }
  return "unix"
}

function Test-WorkflowDispatchSupported {
  param([string]$Category)
  return ($Category -in @("windows-client", "windows-server", "linux", "macos"))
}

function Get-WorkflowConfigPath {
  param([string]$Category)
  if ($Category -in @("windows-client", "windows-server")) { return "config/windows/app.config.json" }
  return "config/linux/app.env"
}

function Get-WorkflowEvidenceName {
  param(
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind
  )
  $name = "$TargetId-$Mode-$ServiceManager-$ReverseProxy"
  if ($Kind -eq "fallback") {
    $name = "$name-fallback"
  }
  return $name
}

function Quote-PowerShellArgument {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Format-GhWorkflowRunCommand {
  param(
    [object]$Inputs,
    [string]$WorkflowFile,
    [string]$WorkflowRef
  )

  $args = New-Object System.Collections.Generic.List[string]
  foreach ($arg in @(
      "gh",
      "workflow",
      "run",
      (Quote-PowerShellArgument $WorkflowFile),
      "--ref",
      (Quote-PowerShellArgument $WorkflowRef)
    )) {
    $args.Add($arg) | Out-Null
  }

  foreach ($name in @(
      "runner_labels",
      "platform",
      "config_path",
      "evidence_name",
      "expected_target_id",
      "expected_nextjs_mode",
      "expected_service_manager",
      "expected_reverse_proxy",
      "minimum_uptime_hours",
      "require_reverse_proxy",
      "fail_on_warnings",
      "upload_retention_days"
    )) {
    $args.Add("-f") | Out-Null
    $args.Add((Quote-PowerShellArgument "$name=$($Inputs.$name)")) | Out-Null
  }

  return ($args -join " ")
}

function Add-PlatformTarget {
  param(
    [System.Collections.Generic.HashSet[string]]$Targets,
    [string]$Value
  )

  $normalized = Normalize-Token $Value
  if (-not $normalized) { return }

  [void]$Targets.Add($normalized)
  switch ($normalized) {
    "darwin" { [void]$Targets.Add("macos") }
    "mac-os" { [void]$Targets.Add("macos") }
    "linuxmint" { [void]$Targets.Add("linux-mint") }
    "ol" { [void]$Targets.Add("oracle-linux") }
    "redhat" { [void]$Targets.Add("rhel") }
    "red-hat" { [void]$Targets.Add("rhel") }
    "freebsd" { [void]$Targets.Add("bsd") }
    "openbsd" { [void]$Targets.Add("bsd") }
    "netbsd" { [void]$Targets.Add("bsd") }
  }
}

function Get-DeclaredEvidenceTarget {
  param([object]$Evidence)

  $explicit = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if ($explicit) { return (Normalize-Token $explicit) }
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  return (Normalize-Token (Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")))
}

function Get-PlatformEvidenceTargets {
  param([object]$Evidence)

  $targets = New-Object System.Collections.Generic.HashSet[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $family = Normalize-Token (Get-StringValue -Object $platform -Names @("Family", "family"))
  $osCaption = Get-StringValue -Object $platform -Names @("OsCaption", "osCaption")
  $osId = Normalize-Token (Get-StringValue -Object $platform -Names @("OsId", "osId"))
  $osIdLike = Get-StringValue -Object $platform -Names @("OsIdLike", "osIdLike")
  $kernelName = Normalize-Token (Get-StringValue -Object $platform -Names @("KernelName", "kernelName"))
  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")

  Add-PlatformTarget -Targets $targets -Value $family
  Add-PlatformTarget -Targets $targets -Value $osId
  Add-PlatformTarget -Targets $targets -Value $kernelName
  foreach ($part in @($osIdLike -split '\s+')) {
    Add-PlatformTarget -Targets $targets -Value $part
  }

  if ($osCaption -match 'Windows') {
    Add-PlatformTarget -Targets $targets -Value "windows"
  }
  if ($osCaption -match 'Windows Server') {
    Add-PlatformTarget -Targets $targets -Value "windows-server"
    if ($osCaption -match '2012\s+R2') {
      Add-PlatformTarget -Targets $targets -Value "windows-server-2012-r2"
    } else {
      foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
        if ($osCaption -match $year) {
          Add-PlatformTarget -Targets $targets -Value "windows-server-$year"
        }
      }
    }
  } else {
    if ($osCaption -match 'Windows\s+10') { Add-PlatformTarget -Targets $targets -Value "windows-10" }
    if ($osCaption -match 'Windows\s+11') { Add-PlatformTarget -Targets $targets -Value "windows-11" }
  }

  if ($prettyName -match 'CentOS Stream') { Add-PlatformTarget -Targets $targets -Value "centos-stream" }
  if ($prettyName -match 'Red Hat Enterprise Linux') { Add-PlatformTarget -Targets $targets -Value "rhel" }
  if ($prettyName -match 'Oracle Linux') { Add-PlatformTarget -Targets $targets -Value "oracle-linux" }
  if ($prettyName -match 'Rocky Linux') { Add-PlatformTarget -Targets $targets -Value "rocky" }
  if ($prettyName -match 'AlmaLinux') { Add-PlatformTarget -Targets $targets -Value "almalinux" }
  if ($prettyName -match 'Linux Mint') { Add-PlatformTarget -Targets $targets -Value "linux-mint" }

  if ($targets.Contains("ubuntu") -or $targets.Contains("debian") -or $targets.Contains("rhel") -or $targets.Contains("fedora") -or $targets.Contains("alpine") -or $targets.Contains("oracle-linux") -or $targets.Contains("centos") -or $targets.Contains("centos-stream") -or $targets.Contains("rocky") -or $targets.Contains("almalinux") -or $targets.Contains("linux-mint")) {
    [void]$targets.Add("linux")
  }
  if ($targets.Contains("windows-server")) {
    [void]$targets.Add("windows")
  }

  return @($targets | Sort-Object)
}

function Get-PrimaryEvidenceTarget {
  param([object]$Evidence)

  $declared = Get-DeclaredEvidenceTarget -Evidence $Evidence
  if ($declared) { return $declared }

  $platformTargets = @(Get-PlatformEvidenceTargets -Evidence $Evidence)
  foreach ($target in @("windows-server-2012-r2", "windows-server-2012", "windows-server-2016", "windows-server-2019", "windows-server-2022", "windows-server-2025", "windows-10", "windows-11", "ubuntu", "debian", "linux-mint", "rhel", "oracle-linux", "centos-stream", "centos", "rocky", "almalinux", "fedora", "alpine", "macos", "freebsd", "openbsd", "netbsd")) {
    if ($platformTargets -contains $target) { return $target }
  }
  return ""
}

function Get-VersionParts {
  param(
    [string]$Value,
    [int]$Count = 2
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $matches = [regex]::Matches($Value, '\d+')
  if ($matches.Count -lt $Count) { return $null }

  $parts = New-Object System.Collections.Generic.List[int]
  for ($index = 0; $index -lt $Count; $index += 1) {
    $parts.Add([int]$matches[$index].Value) | Out-Null
  }
  return @($parts)
}

function Test-VersionAtLeast {
  param(
    [string]$Actual,
    [string]$Minimum,
    [int]$Count = 2
  )

  $actualParts = Get-VersionParts -Value $Actual -Count $Count
  $minimumParts = Get-VersionParts -Value $Minimum -Count $Count
  if ($null -eq $actualParts -or $null -eq $minimumParts) { return $null }

  for ($index = 0; $index -lt $Count; $index += 1) {
    if ($actualParts[$index] -gt $minimumParts[$index]) { return $true }
    if ($actualParts[$index] -lt $minimumParts[$index]) { return $false }
  }
  return $true
}

function Test-NextJsPlatformRuntimeFloor {
  param(
    [object]$Evidence,
    [string]$SupportTargetId
  )

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $target = Normalize-Token $SupportTargetId
  $kernelRelease = Get-StringValue -Object $platform -Names @("KernelRelease", "kernelRelease")
  $machine = Normalize-Token (Get-StringValue -Object $platform -Names @("Machine", "machine", "OsArchitecture", "osArchitecture"))
  $osVersion = Get-StringValue -Object $platform -Names @("OsVersionId", "osVersionId", "OsVersion", "osVersion", "ProductVersion", "productVersion")
  $osBuild = Get-IntegerValue -Object $platform -Names @("OsBuildNumber", "osBuildNumber", "BuildNumber", "buildNumber")
  $libcName = Normalize-Token (Get-StringValue -Object $platform -Names @("LibcName", "libcName"))
  $libcVersion = Get-StringValue -Object $platform -Names @("LibcVersion", "libcVersion")

  $minimumWindowsBuilds = @{
    "windows-10" = 10240
    "windows-11" = 22000
    "windows-server-2012" = 9200
    "windows-server-2012-r2" = 9600
    "windows-server-2016" = 14393
    "windows-server-2019" = 17763
    "windows-server-2022" = 20348
    "windows-server-2025" = 26100
  }
  if ($minimumWindowsBuilds.ContainsKey($target)) {
    return ($null -ne $osBuild -and $osBuild -ge [int]$minimumWindowsBuilds[$target])
  }

  $glibcLinuxTargets = @("ubuntu", "debian", "linux-mint", "rhel", "oracle-linux", "centos", "centos-stream", "rocky", "almalinux", "fedora")
  if ($target -in $glibcLinuxTargets) {
    $kernelOk = Test-VersionAtLeast -Actual $kernelRelease -Minimum "4.18" -Count 2
    $glibcOk = Test-VersionAtLeast -Actual $libcVersion -Minimum "2.28" -Count 2
    return ($kernelOk -eq $true -and $libcName -in @("glibc", "gnu-libc", "gnu-c-library") -and $glibcOk -eq $true)
  }

  if ($target -eq "macos") {
    if ([string]::IsNullOrWhiteSpace($machine)) { return $false }
    $minimumMacosVersion = if ($machine -in @("arm64", "aarch64")) { "11.0" } else { "10.15" }
    return ((Test-VersionAtLeast -Actual $osVersion -Minimum $minimumMacosVersion -Count 2) -eq $true)
  }

  return $true
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
  return (Normalize-Token $mode)
}

function Get-ServiceManager {
  param([object]$Evidence)
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }
  return (Normalize-Token $serviceManager)
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
  return (Normalize-ReverseProxy $mode)
}

function Get-EvidenceGeneratedAt {
  param([object]$Evidence)
  return (Get-StringValue -Object $Evidence -Names @("GeneratedAtUtc", "generatedAtUtc"))
}

function Get-EvidenceCollectionEvidence {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  return [pscustomobject]@{
    source = Get-StringValue -Object $collection -Names @("Source", "source")
    collector = Get-StringValue -Object $collection -Names @("Collector", "collector")
    collectorVersion = Get-IntegerValue -Object $collection -Names @("CollectorVersion", "collectorVersion")
    collectorSha256 = (Get-StringValue -Object $collection -Names @("CollectorSha256", "collectorSha256")).Trim().ToLowerInvariant()
    liveHost = Get-BooleanValue -Object $collection -Names @("LiveHost", "liveHost", "CapturedFromLiveHost", "capturedFromLiveHost") -Default $null
    synthetic = Get-BooleanValue -Object $collection -Names @("Synthetic", "synthetic") -Default $null
    mock = Get-BooleanValue -Object $collection -Names @("Mock", "mock") -Default $null
    sample = Get-BooleanValue -Object $collection -Names @("Sample", "sample") -Default $null
    topLevelSynthetic = Get-BooleanValue -Object $Evidence -Names @("Synthetic", "synthetic") -Default $false
    topLevelMock = Get-BooleanValue -Object $Evidence -Names @("Mock", "mock") -Default $false
    topLevelSample = Get-BooleanValue -Object $Evidence -Names @("Sample", "sample") -Default $false
  }
}

function Test-SupportedEvidenceCollector {
  param([object]$Collection)

  $source = Normalize-Token $Collection.source
  $collector = Normalize-Token $Collection.collector
  $allowed = @(
    "node-enterprise-deploy-kit-status-ps1",
    "node-enterprise-deploy-kit-status-node-app-sh",
    "status-ps1",
    "scripts-linux-status-node-app-sh",
    "status-node-app-sh"
  )
  return (($source -in $allowed) -or ($collector -in $allowed))
}

function Test-LiveEvidenceCollection {
  param([object]$Collection)

  if (-not $Collection.source -and -not $Collection.collector) { return $false }
  if (-not (Test-SupportedEvidenceCollector -Collection $Collection)) { return $false }
  if ($null -eq $Collection.collectorVersion -or $Collection.collectorVersion -lt 1) { return $false }
  if ($Collection.liveHost -ne $true) { return $false }
  if ($Collection.synthetic -ne $false -or $Collection.mock -ne $false -or $Collection.sample -ne $false) { return $false }
  if ($Collection.topLevelSynthetic -eq $true -or $Collection.topLevelMock -eq $true -or $Collection.topLevelSample -eq $true) { return $false }
  return $true
}

function Get-DisplayPath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($RepoRoot.Length + 1)
  }
  return $fullPath
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
    $extractRoot = Join-Path $RepoRoot ".tmp\support-evidence-coverage-bundle-$([Guid]::NewGuid().ToString('N'))"
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

function Get-EvidenceRecords {
  param([string]$Path)

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.json")
  foreach ($file in $files) {
    try {
      $evidence = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      $collection = Get-EvidenceCollectionEvidence -Evidence $evidence
      $declaredTargetId = Get-DeclaredEvidenceTarget -Evidence $evidence
      $platformTargets = @(Get-PlatformEvidenceTargets -Evidence $evidence)
      $runtimePlatformSupported = $false
      if ($declaredTargetId) {
        $runtimePlatformSupported = Test-NextJsPlatformRuntimeFloor -Evidence $evidence -SupportTargetId $declaredTargetId
      }
      [pscustomobject]@{
        file = $file.FullName
        relativeFile = Get-DisplayPath -Path $file.FullName
        targetId = Get-PrimaryEvidenceTarget -Evidence $evidence
        declaredTargetId = $declaredTargetId
        platformTargets = @($platformTargets)
        targetCorroborated = ($declaredTargetId -and $platformTargets -contains $declaredTargetId)
        runtimePlatformSupported = $runtimePlatformSupported
        nextJsMode = Get-NextJsMode -Evidence $evidence
        serviceManager = Get-ServiceManager -Evidence $evidence
        reverseProxy = Get-ReverseProxyMode -Evidence $evidence
        generatedAtUtc = Get-EvidenceGeneratedAt -Evidence $evidence
        verdict = Get-StringValue -Object $evidence -Names @("Verdict", "verdict")
        critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
        warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
        liveEvidenceCollection = Test-LiveEvidenceCollection -Collection $collection
        parseError = ""
      }
    } catch {
      [pscustomobject]@{
        file = $file.FullName
        relativeFile = Get-DisplayPath -Path $file.FullName
        targetId = ""
        declaredTargetId = ""
        platformTargets = @()
        targetCorroborated = $false
        runtimePlatformSupported = $false
        nextJsMode = ""
        serviceManager = ""
        reverseProxy = ""
        generatedAtUtc = ""
        verdict = ""
        critical = $null
        warnings = $null
        liveEvidenceCollection = $false
        parseError = $_.Exception.Message
      }
    }
  }
}

function Test-RecordHealthy {
  param([object]$Record)

  if ($Record.parseError) { return $false }
  if (-not $Record.targetId) { return $false }
  if ($Record.targetCorroborated -ne $true) { return $false }
  if ($Record.runtimePlatformSupported -ne $true) { return $false }
  if ($Record.verdict -eq "Critical") { return $false }
  if ($null -eq $Record.critical -or $Record.critical -gt 0) { return $false }
  if (-not $AllowWarnings -and ($null -eq $Record.warnings -or $Record.warnings -gt 0)) { return $false }
  if ($Record.liveEvidenceCollection -ne $true) { return $false }
  if ($MaxEvidenceAgeDays -gt 0) {
    if (-not $Record.generatedAtUtc) { return $false }
    try {
      $generatedDate = [DateTime]::Parse([string]$Record.generatedAtUtc).ToUniversalTime()
      if (((Get-Date).ToUniversalTime() - $generatedDate).TotalDays -gt $MaxEvidenceAgeDays) {
        return $false
      }
    } catch {
      return $false
    }
  }
  return $true
}

function New-ExpectedEntry {
  param(
    [object]$Target,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind,
    [int]$RequiredMinimumUptimeHours,
    [bool]$FailOnWarnings
  )

  $targetId = Normalize-Token ([string]$Target.id)
  $modeValue = Normalize-Token $Mode
  $serviceManagerValue = Normalize-Token $ServiceManager
  $reverseProxyValue = Normalize-ReverseProxy $ReverseProxy
  $category = [string]$Target.category
  $evidenceFile = Get-EvidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -Kind $Kind
  $nodeRuntimeSupport = Get-OptionalPropertyValue -Object $Target -Name "nodeRuntimeSupport"
  $nodeRuntimeMinimumNodeVersion = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "minimumNodeVersion")
  $nodeRuntimeSupportTier = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "supportTier")
  $nodeRuntimeProductionRecommendedProperty = if ($nodeRuntimeSupport) { $nodeRuntimeSupport.PSObject.Properties["productionRecommended"] } else { $null }
  $nodeRuntimeProductionRecommended = if ($nodeRuntimeProductionRecommendedProperty -and $nodeRuntimeProductionRecommendedProperty.Value -is [bool]) { [bool]$nodeRuntimeProductionRecommendedProperty.Value } else { $null }
  $nodeRuntimeRequirements = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "requirements")
  $workflowDispatchSupported = Test-WorkflowDispatchSupported -Category $category
  $workflowInputs = $null
  $workflowInputSummary = "local command only; host-evidence workflow is not supported for target category '$category'"
  $workflowDispatchCommand = ""
  if ($workflowDispatchSupported) {
    $workflowInputs = [pscustomobject]@{
      runner_labels = '["self-hosted","' + $targetId + '"]'
      platform = Get-WorkflowPlatform -Category $category
      config_path = Get-WorkflowConfigPath -Category $category
      evidence_name = Get-WorkflowEvidenceName -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -Kind $Kind
      expected_target_id = $targetId
      expected_nextjs_mode = $modeValue
      expected_service_manager = $serviceManagerValue
      expected_reverse_proxy = $reverseProxyValue
      minimum_uptime_hours = [string]$RequiredMinimumUptimeHours
      require_reverse_proxy = "true"
      fail_on_warnings = if ($FailOnWarnings) { "true" } else { "false" }
      upload_retention_days = "30"
    }
    $workflowInputSummary = (@(
        "platform=$($workflowInputs.platform)",
        "evidence_name=$($workflowInputs.evidence_name)",
        "expected_target_id=$($workflowInputs.expected_target_id)",
        "expected_nextjs_mode=$($workflowInputs.expected_nextjs_mode)",
        "expected_service_manager=$($workflowInputs.expected_service_manager)",
        "expected_reverse_proxy=$($workflowInputs.expected_reverse_proxy)"
      ) -join "; ")
    $workflowDispatchCommand = Format-GhWorkflowRunCommand -Inputs $workflowInputs -WorkflowFile $WorkflowFile -WorkflowRef $WorkflowRef
  }

  [pscustomobject]@{
    kind = $Kind
    targetId = $targetId
    nextJsMode = $modeValue
    serviceManager = $serviceManagerValue
    reverseProxy = $reverseProxyValue
    nodeRuntimeMinimumNodeVersion = $nodeRuntimeMinimumNodeVersion
    nodeRuntimeSupportTier = $nodeRuntimeSupportTier
    nodeRuntimeProductionRecommended = $nodeRuntimeProductionRecommended
    nodeRuntimeRequirements = $nodeRuntimeRequirements
    requiredMinimumUptimeHours = $RequiredMinimumUptimeHours
    evidenceFile = $evidenceFile
    collectionCommand = Get-CollectionCommand -Category $category -EvidenceFile $evidenceFile -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings
    validationCommand = Get-ValidationCommand -EvidenceFile $evidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings
    workflowDispatchSupported = $workflowDispatchSupported
    workflowInputs = $workflowInputs
    workflowInputSummary = $workflowInputSummary
    workflowDispatchCommand = $workflowDispatchCommand
  }
}

function Assert-WorkflowInputsAccepted {
  param(
    [object[]]$Entries,
    [string]$MatrixPath
  )

  $workflowInputValidatorPath = Join-Path $ScriptDir "Test-HostEvidenceWorkflowInputs.ps1"
  if (-not (Test-Path -LiteralPath $workflowInputValidatorPath -PathType Leaf)) {
    throw "Support evidence coverage self-test failed: missing host evidence workflow input validator."
  }

  foreach ($entry in @($Entries | Where-Object { $_.workflowDispatchSupported -eq $true })) {
    $context = "$($entry.kind)/$($entry.targetId)/$($entry.nextJsMode)/$($entry.serviceManager)/$($entry.reverseProxy)"
    if (-not $entry.PSObject.Properties["workflowInputs"] -or $null -eq $entry.workflowInputs) {
      throw "Support evidence coverage self-test failed: workflowInputs missing from $context."
    }
    try {
      & $workflowInputValidatorPath `
        -MatrixPath $MatrixPath `
        -RunnerLabels ([string]$entry.workflowInputs.runner_labels) `
        -Platform ([string]$entry.workflowInputs.platform) `
        -ConfigPath ([string]$entry.workflowInputs.config_path) `
        -EvidenceName ([string]$entry.workflowInputs.evidence_name) `
        -ExpectedTargetId ([string]$entry.workflowInputs.expected_target_id) `
        -ExpectedNextJsMode ([string]$entry.workflowInputs.expected_nextjs_mode) `
        -ExpectedServiceManager ([string]$entry.workflowInputs.expected_service_manager) `
        -ExpectedReverseProxy ([string]$entry.workflowInputs.expected_reverse_proxy) `
        -MinimumUptimeHours ([string]$entry.workflowInputs.minimum_uptime_hours) `
        -UploadRetentionDays ([string]$entry.workflowInputs.upload_retention_days) `
        -Quiet
    } catch {
      throw "Support evidence coverage self-test failed: workflowInputs were rejected by host evidence workflow validator for $($context): $($_.Exception.Message)"
    }
  }
}

function Get-ExpectedEntries {
  param(
    [object[]]$Targets,
    [int]$RequiredMinimumUptimeHours,
    [bool]$FailOnWarnings
  )

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($target in $Targets) {
    $modes = @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $serviceManagers = @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $fallbackManagers = @(Get-ArrayValue (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers") | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $proxies = @(Get-ArrayValue $target.reverseProxies | ForEach-Object { Normalize-ReverseProxy ([string]$_) } | Where-Object { $_ })
    $concreteProxies = @($proxies | Where-Object { $_ -ne "none" })
    $serviceOnlyProxies = @($proxies | Where-Object { $_ -eq "none" })

    foreach ($mode in $modes) {
      foreach ($serviceManager in $serviceManagers) {
        foreach ($proxy in $concreteProxies) {
          $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "strict" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings)) | Out-Null
        }
        if ($IncludeServiceOnly) {
          foreach ($proxy in $serviceOnlyProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "service-only" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings)) | Out-Null
          }
        }
      }
      if ($IncludeFallback) {
        foreach ($fallbackManager in $fallbackManagers) {
          foreach ($proxy in $concreteProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings)) | Out-Null
          }
        }
      }
    }
  }
  return @($entries | ForEach-Object { $_ })
}

function ConvertTo-CoverageMarkdown {
  param([object]$Result)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Support Evidence Coverage Report") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("| Metric | Value |") | Out-Null
  $lines.Add("|---|---:|") | Out-Null
  $lines.Add("| Expected entries | $($Result.summary.expectedCount) |") | Out-Null
  $lines.Add("| Covered entries | $($Result.summary.coveredCount) |") | Out-Null
  $lines.Add("| Missing entries | $($Result.summary.missingCount) |") | Out-Null
  $lines.Add("| Parsed evidence files | $($Result.summary.parsedEvidenceFiles) |") | Out-Null
  $lines.Add("| Healthy evidence files | $($Result.summary.healthyEvidenceFiles) |") | Out-Null
  $lines.Add("| Required minimum uptime hours | $($Result.requiredMinimumUptimeHours) |") | Out-Null
  $lines.Add("| Allow warnings | $($Result.allowWarnings) |") | Out-Null
  $lines.Add("| Fail on warnings during collection | $($Result.failOnWarningsDuringCollection) |") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add(("Workflow file: ``{0}``" -f $Result.workflowFile)) | Out-Null
  $lines.Add(("Workflow ref: ``{0}``" -f $Result.workflowRef)) | Out-Null
  $lines.Add("") | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.bundlePath)) {
    $lines.Add(("Bundle: ``{0}``" -f $Result.bundlePath)) | Out-Null
    $lines.Add("") | Out-Null
  }
  $lines.Add(("Evidence path: ``{0}``" -f $Result.evidencePath)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Missing Entries") | Out-Null
  $lines.Add("") | Out-Null
  if ([int]$Result.summary.missingCount -eq 0) {
    $lines.Add("_No missing entries._") | Out-Null
    $lines.Add("") | Out-Null
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
  }

  $lines.Add("| Kind | Target | Next.js mode | Service manager | Reverse proxy | Node runtime | Evidence file | Workflow |") | Out-Null
  $lines.Add("|---|---|---|---|---|---|---|---|") | Out-Null
  foreach ($row in @($Result.missing)) {
    $workflow = if ([bool]$row.workflowDispatchSupported) { "supported" } else { "local only" }
    $runtimeSuffix = if ($row.nodeRuntimeProductionRecommended -eq $true) { "production" } else { "not production" }
    $runtimeCell = "{0}; {1}" -f $row.nodeRuntimeSupportTier, $runtimeSuffix
    $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | {7} |' -f $row.kind, $row.targetId, $row.nextJsMode, $row.serviceManager, $row.reverseProxy, $runtimeCell, $row.evidenceFile, $workflow)) | Out-Null
  }
  $lines.Add("") | Out-Null
  $lines.Add("## Next Collection Commands") | Out-Null
  $lines.Add("") | Out-Null
  foreach ($row in @($Result.missing)) {
    $lines.Add(('### `{0}` / `{1}` / `{2}` / `{3}` / `{4}`' -f $row.kind, $row.targetId, $row.nextJsMode, $row.serviceManager, $row.reverseProxy)) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add(('Evidence file: ``{0}``' -f $row.evidenceFile)) | Out-Null
    $lines.Add("") | Out-Null
    if ([bool]$row.workflowDispatchSupported) {
      $lines.Add("GitHub Actions workflow dispatch:") | Out-Null
      $lines.Add("") | Out-Null
      $lines.Add('```powershell') | Out-Null
      $lines.Add([string]$row.workflowDispatchCommand) | Out-Null
      $lines.Add('```') | Out-Null
      $lines.Add("") | Out-Null
    } else {
      $lines.Add(("Workflow dispatch: {0}" -f $row.workflowInputSummary)) | Out-Null
      $lines.Add("") | Out-Null
    }
    $lines.Add("Local collector command:") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add('```text') | Out-Null
    $lines.Add([string]$row.collectionCommand) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Validation command:") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add([string]$row.validationCommand) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add("") | Out-Null
  }
  $lines.Add("") | Out-Null
  return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-SelfTestEvidence {
  param(
    [string]$Path,
    [object[]]$ExpectedEntries,
    [int]$RequiredMinimumUptimeHours
  )
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $requiredMinimumUptimeSeconds = [int64]$RequiredMinimumUptimeHours * 3600
  foreach ($entry in $ExpectedEntries) {
    $fileName = "$($entry.kind)-$($entry.targetId)-$($entry.nextJsMode)-$($entry.serviceManager)-$($entry.reverseProxy).json"
    $targetId = [string]$entry.targetId
    $serviceManager = [string]$entry.serviceManager
    $reverseProxy = [string]$entry.reverseProxy
    $nextJsMode = [string]$entry.nextJsMode
    $targetIsWindows = $targetId -like "windows*"
    $collection = if (([string]$entry.targetId) -like "windows*") {
      [ordered]@{
        source = "node-enterprise-deploy-kit/status.ps1"
        collector = "status.ps1"
        collectorVersion = 1
        collectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        liveHost = $true
        synthetic = $false
        mock = $false
        sample = $false
      }
    } else {
      [ordered]@{
        source = "node-enterprise-deploy-kit/status-node-app.sh"
        collector = "scripts/linux/status-node-app.sh"
        collectorVersion = 1
        collectorSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        liveHost = $true
        synthetic = $false
        mock = $false
        sample = $false
      }
    }
    $scheduleType = if ($targetIsWindows) {
      "windows-task"
    } elseif ($serviceManager -eq "systemd") {
      "systemd-timer"
    } elseif ($serviceManager -eq "launchd") {
      "launchd-timer"
    } else {
      "cron"
    }
    $monitor = [ordered]@{
      status = "ok"
      scheduled = $true
      scheduleType = $scheduleType
      stateExists = $true
      consecutiveFailures = 0
      lastSuccessAgeSeconds = 60
      lastSuccessFresh = $true
      logExists = $true
      logFailureCount = 0
      logRestartCount = 0
    }
    if ($scheduleType -eq "windows-task") {
      $monitor["taskExists"] = $true
      $monitor["taskActionChecked"] = $true
      $monitor["taskActionUsesHealthCheckScript"] = $true
      $monitor["taskActionUsesConfigPath"] = $true
      $monitor["taskLastResult"] = 0
      $monitor["taskMissedRuns"] = 0
    } else {
      $monitor["schedulerChecked"] = $true
      $monitor["schedulerExists"] = $true
      $monitor["schedulerActive"] = $true
      $monitor["schedulerEnabled"] = $true
      $monitor["schedulerActiveStatus"] = "active"
      $monitor["schedulerEnabledStatus"] = if ($scheduleType -eq "cron") { "persistent-entry" } else { "enabled" }
    }
    $proxyEvidence = if ($reverseProxy -eq "none") {
      [ordered]@{
        applicable = $false
        mode = "none"
        status = "not-applicable"
      }
    } elseif ($reverseProxy -eq "iis") {
      [ordered]@{
        applicable = $true
        mode = "iis"
        status = "ok"
        probeUrl = "https://example.local/health"
        statusCode = 200
        iis = [ordered]@{
          applicable = $true
          moduleAvailable = $true
          siteExists = $true
          siteStarted = $true
          sitePathMatchesConfig = $true
          bindingMatchesConfig = $true
          duplicateBindingConflict = $false
        }
      }
    } else {
      [ordered]@{
        applicable = $true
        mode = $reverseProxy
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
    }
    $platformFamily = if ($targetIsWindows) {
      "windows"
    } elseif ($targetId -eq "macos") {
      "macos"
    } elseif ($targetId -in @("freebsd", "openbsd", "netbsd")) {
      $targetId
    } else {
      "linux"
    }
    $kernelName = switch ($platformFamily) {
      "windows" { "Windows" }
      "macos" { "Darwin" }
      "freebsd" { "FreeBSD" }
      "openbsd" { "OpenBSD" }
      "netbsd" { "NetBSD" }
      default { "Linux" }
    }
    $windowsCaption = switch ($targetId) {
      "windows-10" { "Microsoft Windows 10 Pro" }
      "windows-11" { "Microsoft Windows 11 Pro" }
      "windows-server-2012" { "Microsoft Windows Server 2012 Standard" }
      "windows-server-2012-r2" { "Microsoft Windows Server 2012 R2 Standard" }
      "windows-server-2016" { "Microsoft Windows Server 2016 Datacenter" }
      "windows-server-2019" { "Microsoft Windows Server 2019 Datacenter" }
      "windows-server-2022" { "Microsoft Windows Server 2022 Datacenter" }
      "windows-server-2025" { "Microsoft Windows Server 2025 Datacenter" }
      default { "" }
    }
    $windowsBuild = switch ($targetId) {
      "windows-10" { "19045" }
      "windows-11" { "22631" }
      "windows-server-2012" { "9200" }
      "windows-server-2012-r2" { "9600" }
      "windows-server-2016" { "14393" }
      "windows-server-2019" { "17763" }
      "windows-server-2022" { "20348" }
      "windows-server-2025" { "26100" }
      default { "" }
    }
    $kernelRelease = if ($targetId -eq "macos") {
      "24.0.0"
    } elseif ($targetId -in @("freebsd", "openbsd", "netbsd")) {
      "14.0"
    } else {
      "6.8.0"
    }
    $machine = if ($targetId -eq "macos") { "arm64" } else { "x86_64" }
    $osVersionId = switch ($targetId) {
      "ubuntu" { "24.04" }
      "debian" { "12" }
      "linux-mint" { "22" }
      "rhel" { "9" }
      "oracle-linux" { "9" }
      "centos" { "8" }
      "centos-stream" { "9" }
      "rocky" { "9" }
      "almalinux" { "9" }
      "fedora" { "40" }
      "alpine" { "3.20" }
      "macos" { "15.0" }
      default { "" }
    }
    $libcName = if ($targetId -eq "alpine") {
      "musl"
    } elseif ($platformFamily -eq "linux") {
      "glibc"
    } else {
      ""
    }
    $libcVersion = if ($libcName -eq "glibc") {
      "2.39"
    } elseif ($libcName -eq "musl") {
      "1.2.5"
    } else {
      ""
    }
    $data = [ordered]@{
      evidenceSchemaVersion = 1
      evidenceCollection = $collection
      supportTargetId = $targetId
      generatedAtUtc = $now
      appName = "example-next-app"
      serviceName = "example-next-app"
      serviceManager = $serviceManager
      serviceActiveStatus = "active"
      serviceEnabledStatus = "enabled"
      serviceDefinition = if ($targetIsWindows) {
        [ordered]@{
          checked = $true
          manager = $serviceManager
          definitionSource = switch ($serviceManager) {
            "nssm" { "nssm-registry" }
            "pm2" { "pm2-ecosystem" }
            default { "winsw-xml" }
          }
          definitionExists = $true
          serviceWrapperMatchesConfig = if ($serviceManager -eq "winsw") { $true } else { $null }
          nodeExeMatchesConfig = $true
          workingDirectoryMatchesConfig = $true
          argumentsMatchConfig = $true
        }
      } else {
        [ordered]@{
          checked = $true
          manager = $serviceManager
          definitionSource = switch ($serviceManager) {
            "launchd" { "launchd-plist" }
            "bsdrc" { "bsdrc-init" }
            "openrc" { "openrc-init" }
            "systemv" { "systemv-init" }
            default { "systemd-unit" }
          }
          definitionExists = $true
          nodeExeMatchesConfig = $true
          workingDirectoryMatchesConfig = $true
          argumentsMatchConfig = $true
          runnerScriptMatchesConfig = ($serviceManager -eq "launchd")
        }
      }
      platform = [ordered]@{
        family = $platformFamily
        supportTargetId = $targetId
        serviceManager = $serviceManager
        reverseProxy = $reverseProxy
        kernelName = $kernelName
        kernelRelease = $kernelRelease
        machine = $machine
        osCaption = $windowsCaption
        osVersion = if ($windowsBuild) { "10.0.$windowsBuild" } else { "" }
        osBuildNumber = $windowsBuild
        osId = $targetId
        osVersionId = $osVersionId
        osPrettyName = $targetId
        libcName = $libcName
        libcVersion = $libcVersion
        appFramework = "nextjs"
        nextjsDeploymentMode = $nextJsMode
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
        hostUptimeSeconds = $requiredMinimumUptimeSeconds + 86400
        serviceUptimeSeconds = $requiredMinimumUptimeSeconds
        minimumUptimeHours = [string]$RequiredMinimumUptimeHours
        minimumSatisfied = $true
        serviceStartKnown = $true
      }
      healthMonitor = $monitor
      nextJsRuntime = [ordered]@{
        applicable = $true
        status = "ok"
        appFramework = "nextjs"
        mode = $nextJsMode
        nodeVersion = "v20.11.1"
        minimumNodeVersion = "20.9.0"
        nodeVersionSatisfied = $true
        nextVersion = "14.2.3"
        nextStartScriptIsExpectedCli = if ($nextJsMode -eq "next-start") { $true } else { $null }
        runtimeRootName = "example-next-app"
      }
      reverseProxy = $proxyEvidence
      deploymentIdentity = [ordered]@{
        status = "ok"
        appDirectoryName = "example-next-app"
        deploymentId = "example-deploy-$targetId-$nextJsMode-$serviceManager-$reverseProxy"
        nextBuildId = "example-build-$nextJsMode"
        packageSha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
      verdict = "Healthy"
      critical = 0
      warnings = 0
      findings = @()
    }
    $data | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path $fileName) -Encoding UTF8
  }
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Matrix $matrix
$allTargets = @(Get-ArrayValue $matrix.targets)
$targets = @(Select-MatrixTargets -Targets $allTargets -TargetId $TargetId -Category $Category -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly))
$failOnWarningsDuringCollection = -not [bool]$AllowWarnings

if ($SelfTest) {
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  $EvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-selftest-$([Guid]::NewGuid().ToString('N'))"
  $expectedForSelfTest = @(Get-ExpectedEntries -Targets $targets -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings $failOnWarningsDuringCollection)
  New-SelfTestEvidence -Path $EvidencePath -ExpectedEntries $expectedForSelfTest -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
}

if (-not [string]::IsNullOrWhiteSpace($BundlePath)) {
  if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    throw "Use either EvidencePath or BundlePath, not both."
  }
  & (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -BundlePath $BundlePath | Out-Null
  $bundleRootInfo = Resolve-BundleRoot -Path $BundlePath
  $EvidencePath = Get-BundleManifestRoot -Root $bundleRootInfo.Root
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  throw "EvidencePath or BundlePath is required unless -SelfTest is used."
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $EvidencePath"
}

$expectedEntries = @(Get-ExpectedEntries -Targets $targets -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings $failOnWarningsDuringCollection)
Assert-WorkflowInputsAccepted -Entries $expectedEntries -MatrixPath $MatrixPath
$records = @(Get-EvidenceRecords -Path $EvidencePath)
$healthyRecords = @($records | Where-Object { Test-RecordHealthy -Record $_ })
$covered = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[object]

foreach ($entry in $expectedEntries) {
  $matches = @($healthyRecords | Where-Object {
    $_.targetId -eq $entry.targetId -and
    $_.nextJsMode -eq $entry.nextJsMode -and
    $_.serviceManager -eq $entry.serviceManager -and
    $_.reverseProxy -eq $entry.reverseProxy
  })

  if ($matches.Count -gt 0) {
    $covered.Add([pscustomobject]@{
      kind = $entry.kind
      targetId = $entry.targetId
      nextJsMode = $entry.nextJsMode
      serviceManager = $entry.serviceManager
      reverseProxy = $entry.reverseProxy
      nodeRuntimeMinimumNodeVersion = $entry.nodeRuntimeMinimumNodeVersion
      nodeRuntimeSupportTier = $entry.nodeRuntimeSupportTier
      nodeRuntimeProductionRecommended = $entry.nodeRuntimeProductionRecommended
      nodeRuntimeRequirements = $entry.nodeRuntimeRequirements
      requiredMinimumUptimeHours = $entry.requiredMinimumUptimeHours
      evidenceFile = $entry.evidenceFile
      collectionCommand = $entry.collectionCommand
      validationCommand = $entry.validationCommand
      workflowDispatchSupported = $entry.workflowDispatchSupported
      workflowInputSummary = $entry.workflowInputSummary
      workflowDispatchCommand = $entry.workflowDispatchCommand
      file = [string]$matches[0].relativeFile
      status = "covered"
    }) | Out-Null
  } else {
    $missing.Add([pscustomobject]@{
      kind = $entry.kind
      targetId = $entry.targetId
      nextJsMode = $entry.nextJsMode
      serviceManager = $entry.serviceManager
      reverseProxy = $entry.reverseProxy
      nodeRuntimeMinimumNodeVersion = $entry.nodeRuntimeMinimumNodeVersion
      nodeRuntimeSupportTier = $entry.nodeRuntimeSupportTier
      nodeRuntimeProductionRecommended = $entry.nodeRuntimeProductionRecommended
      nodeRuntimeRequirements = $entry.nodeRuntimeRequirements
      requiredMinimumUptimeHours = $entry.requiredMinimumUptimeHours
      evidenceFile = $entry.evidenceFile
      collectionCommand = $entry.collectionCommand
      validationCommand = $entry.validationCommand
      workflowDispatchSupported = $entry.workflowDispatchSupported
      workflowInputSummary = $entry.workflowInputSummary
      workflowDispatchCommand = $entry.workflowDispatchCommand
      file = ""
      status = "missing"
    }) | Out-Null
  }
}

$coveredRows = @($covered | ForEach-Object { $_ })
$missingRows = @($missing | ForEach-Object { $_ })

$result = [pscustomobject]@{
  schemaVersion = 1
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  evidencePath = $EvidencePath
  bundlePath = $BundlePath
  reportOnly = [bool]$ReportOnly
  workflowFile = $WorkflowFile
  workflowRef = $WorkflowRef
  targetId = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
  category = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
  productionRecommendedOnly = [bool]$ProductionRecommendedOnly
  allowWarnings = [bool]$AllowWarnings
  failOnWarningsDuringCollection = $failOnWarningsDuringCollection
  selectedTargets = @($targets | ForEach-Object { Normalize-Token ([string]$_.id) })
  requiredMinimumUptimeHours = $requiredMinimumUptimeHours
  summary = [pscustomobject]@{
    expectedCount = $expectedEntries.Count
    coveredCount = $coveredRows.Count
    missingCount = $missingRows.Count
    parsedEvidenceFiles = $records.Count
    healthyEvidenceFiles = $healthyRecords.Count
  }
  covered = $coveredRows
  missing = $missingRows
}

if ($SelfTest) {
  function Copy-SelfTestCoverageArgs {
    param([hashtable]$Source)

    $copy = @{}
    foreach ($key in $Source.Keys) {
      $copy[$key] = $Source[$key]
    }
    return $copy
  }

  $selfTestCoverageArgs = @{
    MatrixPath = $MatrixPath
    IncludeServiceOnly = $true
    IncludeFallback = $true
    ReportOnly = $true
  }
  if ($TargetId.Count -gt 0) {
    $selfTestCoverageArgs.TargetId = [string[]]$TargetId
  }
  if ($Category.Count -gt 0) {
    $selfTestCoverageArgs.Category = [string[]]$Category
  }
  if ($ProductionRecommendedOnly) {
    $selfTestCoverageArgs.ProductionRecommendedOnly = $true
  }

  $selfTestReportPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-selftest-report-$([Guid]::NewGuid().ToString('N')).md"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $EvidencePath -Format Markdown -OutputPath $selfTestReportPath | Out-Null
  $selfTestReport = Get-Content -LiteralPath $selfTestReportPath -Raw
  if (-not $selfTestReport.Contains("Support Evidence Coverage Report")) {
    throw "Support evidence coverage self-test failed: Markdown report missing title."
  }
  if (-not $selfTestReport.Contains("_No missing entries._")) {
    throw "Support evidence coverage self-test failed: Markdown report should show no missing entries."
  }

  $mismatchedTargetEvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-target-mismatch-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $mismatchedTargetEvidencePath -ExpectedEntries $expectedForSelfTest -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $mismatchedTargetFile = Join-Path $mismatchedTargetEvidencePath "strict-ubuntu-standalone-systemd-nginx.json"
  $mismatchedTargetEvidence = Get-Content -LiteralPath $mismatchedTargetFile -Raw | ConvertFrom-Json
  $mismatchedTargetEvidence.supportTargetId = "windows-server-2022"
  $mismatchedTargetEvidence.platform.supportTargetId = "windows-server-2022"
  $mismatchedTargetEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $mismatchedTargetFile -Encoding UTF8
  $mismatchedTargetJsonPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-target-mismatch-$([Guid]::NewGuid().ToString('N')).json"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $mismatchedTargetEvidencePath -Format Json -OutputPath $mismatchedTargetJsonPath | Out-Null
  $mismatchedTargetJson = Get-Content -LiteralPath $mismatchedTargetJsonPath -Raw | ConvertFrom-Json
  $missingMismatchedRow = @($mismatchedTargetJson.missing | Where-Object {
      $_.kind -eq "strict" -and
      $_.targetId -eq "ubuntu" -and
      $_.nextJsMode -eq "standalone" -and
      $_.serviceManager -eq "systemd" -and
      $_.reverseProxy -eq "nginx"
    })
  if ($missingMismatchedRow.Count -ne 1) {
    throw "Support evidence coverage self-test failed: target-mismatched evidence was counted as covering ubuntu."
  }
  if ([int]$mismatchedTargetJson.summary.healthyEvidenceFiles -ge [int]$mismatchedTargetJson.summary.parsedEvidenceFiles) {
    throw "Support evidence coverage self-test failed: target-mismatched evidence should not be treated as healthy coverage."
  }

  $runtimeFloorEvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-runtime-floor-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $runtimeFloorEvidencePath -ExpectedEntries $expectedForSelfTest -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $runtimeFloorFile = Join-Path $runtimeFloorEvidencePath "strict-ubuntu-standalone-systemd-nginx.json"
  $runtimeFloorEvidence = Get-Content -LiteralPath $runtimeFloorFile -Raw | ConvertFrom-Json
  $runtimeFloorEvidence.platform.kernelRelease = "4.17.0"
  $runtimeFloorEvidence.platform.libcVersion = "2.27"
  $runtimeFloorEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $runtimeFloorFile -Encoding UTF8
  $runtimeFloorJsonPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-runtime-floor-$([Guid]::NewGuid().ToString('N')).json"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $runtimeFloorEvidencePath -Format Json -OutputPath $runtimeFloorJsonPath | Out-Null
  $runtimeFloorJson = Get-Content -LiteralPath $runtimeFloorJsonPath -Raw | ConvertFrom-Json
  $missingRuntimeFloorRow = @($runtimeFloorJson.missing | Where-Object {
      $_.kind -eq "strict" -and
      $_.targetId -eq "ubuntu" -and
      $_.nextJsMode -eq "standalone" -and
      $_.serviceManager -eq "systemd" -and
      $_.reverseProxy -eq "nginx"
    })
  if ($missingRuntimeFloorRow.Count -ne 1) {
    throw "Support evidence coverage self-test failed: runtime-floor-invalid evidence was counted as covering ubuntu."
  }
  if ([int]$runtimeFloorJson.summary.healthyEvidenceFiles -ge [int]$runtimeFloorJson.summary.parsedEvidenceFiles) {
    throw "Support evidence coverage self-test failed: runtime-floor-invalid evidence should not be treated as healthy coverage."
  }

  $missingEvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-selftest-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $missingEvidencePath -Force | Out-Null
  $missingReportPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-report-$([Guid]::NewGuid().ToString('N')).md"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $missingEvidencePath -Format Markdown -OutputPath $missingReportPath | Out-Null
  $missingReport = Get-Content -LiteralPath $missingReportPath -Raw
  foreach ($expectedReportText in @(
      "Next Collection Commands",
      "GitHub Actions workflow dispatch:",
      "gh workflow run",
      "minimum_uptime_hours=$requiredMinimumUptimeHours",
      "fail_on_warnings=true",
      "-MinimumUptimeHours $requiredMinimumUptimeHours",
      "-FailOnWarnings",
      "--minimum-uptime-hours $requiredMinimumUptimeHours",
      "--fail-on-warnings",
      "Node runtime",
      "Validation command:",
      "Test-HostEvidence.ps1",
      "Fail on warnings during collection",
      "Local collector command:",
      "config/windows/app.config.json",
      "config/linux/app.env",
      "local command only; host-evidence workflow is not supported"
    )) {
    if (-not $missingReport.Contains($expectedReportText)) {
      throw "Support evidence coverage self-test failed: missing report did not include '$expectedReportText'."
    }
  }

  $missingJsonPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-report-$([Guid]::NewGuid().ToString('N')).json"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $missingEvidencePath -Format Json -OutputPath $missingJsonPath | Out-Null
  $missingJson = Get-Content -LiteralPath $missingJsonPath -Raw | ConvertFrom-Json
  if ([int]$missingJson.summary.missingCount -le 0) {
    throw "Support evidence coverage self-test failed: missing JSON report did not report missing entries."
  }
  if ($missingJson.failOnWarningsDuringCollection -ne $true) {
    throw "Support evidence coverage self-test failed: default missing report did not record strict warning collection."
  }
  $firstMissing = @($missingJson.missing | Select-Object -First 1)[0]
  foreach ($requiredProperty in @("evidenceFile", "collectionCommand", "validationCommand", "nodeRuntimeMinimumNodeVersion", "nodeRuntimeSupportTier", "nodeRuntimeProductionRecommended", "nodeRuntimeRequirements", "requiredMinimumUptimeHours", "workflowDispatchSupported", "workflowInputSummary", "workflowDispatchCommand")) {
    if (-not $firstMissing.PSObject.Properties[$requiredProperty]) {
      throw "Support evidence coverage self-test failed: missing JSON row did not include $requiredProperty."
    }
  }
  if ([int]$firstMissing.requiredMinimumUptimeHours -ne $requiredMinimumUptimeHours) {
    throw "Support evidence coverage self-test failed: missing JSON row did not carry requiredMinimumUptimeHours."
  }
  if ([string]::IsNullOrWhiteSpace([string]$firstMissing.nodeRuntimeMinimumNodeVersion) -or [string]::IsNullOrWhiteSpace([string]$firstMissing.nodeRuntimeSupportTier)) {
    throw "Support evidence coverage self-test failed: missing JSON row did not carry Node runtime support metadata."
  }
  $firstWindowsMissing = @($missingJson.missing | Where-Object { ([string]$_.targetId).StartsWith("windows-") } | Select-Object -First 1)[0]
  if ($null -eq $firstWindowsMissing -or -not ([string]$firstWindowsMissing.collectionCommand).Contains("-MinimumUptimeHours $requiredMinimumUptimeHours")) {
    throw "Support evidence coverage self-test failed: Windows collection command is missing minimum uptime guidance."
  }
  if (-not ([string]$firstWindowsMissing.validationCommand).Contains("-EvidencePath .\$(([string]$firstWindowsMissing.evidenceFile).Replace('/', '\'))")) {
    throw "Support evidence coverage self-test failed: Windows validation command is missing the exact evidence file path."
  }
  foreach ($expectedValidationFragment in @(
      "-ExpectedTargetId $($firstWindowsMissing.targetId)",
      "-ExpectedNextJsMode $($firstWindowsMissing.nextJsMode)",
      "-ExpectedServiceManager $($firstWindowsMissing.serviceManager)",
      "-ExpectedReverseProxy $($firstWindowsMissing.reverseProxy)",
      "-RequireMinimumUptimeHours $requiredMinimumUptimeHours"
    )) {
    if (-not ([string]$firstWindowsMissing.validationCommand).Contains($expectedValidationFragment)) {
      throw "Support evidence coverage self-test failed: Windows validation command is missing $expectedValidationFragment."
    }
  }
  if (-not ([string]$firstWindowsMissing.collectionCommand).Contains("-FailOnWarnings")) {
    throw "Support evidence coverage self-test failed: strict Windows collection command is missing -FailOnWarnings."
  }
  if (-not ([string]$firstWindowsMissing.validationCommand).Contains("-FailOnWarnings")) {
    throw "Support evidence coverage self-test failed: strict Windows validation command is missing -FailOnWarnings."
  }
  if (-not ([string]$firstWindowsMissing.workflowDispatchCommand).Contains("fail_on_warnings=true")) {
    throw "Support evidence coverage self-test failed: strict workflow dispatch command is missing fail_on_warnings=true."
  }
  $firstUnixMissing = @($missingJson.missing | Where-Object { ([string]$_.targetId) -eq "ubuntu" } | Select-Object -First 1)[0]
  if ($null -eq $firstUnixMissing -or -not ([string]$firstUnixMissing.collectionCommand).Contains("--minimum-uptime-hours $requiredMinimumUptimeHours")) {
    throw "Support evidence coverage self-test failed: Unix collection command is missing minimum uptime guidance."
  }
  if (-not ([string]$firstUnixMissing.collectionCommand).Contains("--fail-on-warnings")) {
    throw "Support evidence coverage self-test failed: strict Unix collection command is missing --fail-on-warnings."
  }
  if (-not ([string]$firstUnixMissing.validationCommand).Contains("-ExpectedTargetId ubuntu")) {
    throw "Support evidence coverage self-test failed: Unix validation command is missing target guidance."
  }

  $missingCsvPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-report-$([Guid]::NewGuid().ToString('N')).csv"
  & $PSCommandPath @selfTestCoverageArgs -EvidencePath $missingEvidencePath -Format Csv -OutputPath $missingCsvPath | Out-Null
  $missingCsvHeader = Get-Content -LiteralPath $missingCsvPath -First 1
  if (-not ([string]$missingCsvHeader).Contains("validationCommand")) {
    throw "Support evidence coverage self-test failed: CSV report is missing validationCommand."
  }
  $missingCsvText = Get-Content -LiteralPath $missingCsvPath -Raw
  if (-not $missingCsvText.Contains("Test-HostEvidence.ps1")) {
    throw "Support evidence coverage self-test failed: CSV report is missing validation command content."
  }

  $missingTableOutput = (& $PSCommandPath @selfTestCoverageArgs -EvidencePath $missingEvidencePath -Format Table 6>&1 | Out-String)
  foreach ($expectedTableText in @(
      "Next collection and validation commands:",
      "Collect:",
      "Validate:",
      "Test-HostEvidence.ps1"
    )) {
    if (-not $missingTableOutput.Contains($expectedTableText)) {
      throw "Support evidence coverage self-test failed: table report is missing '$expectedTableText'."
    }
  }

  $allowWarningsJsonPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-allow-warnings-report-$([Guid]::NewGuid().ToString('N')).json"
  $allowWarningsCoverageArgs = Copy-SelfTestCoverageArgs -Source $selfTestCoverageArgs
  $allowWarningsCoverageArgs.AllowWarnings = $true
  & $PSCommandPath @allowWarningsCoverageArgs -EvidencePath $missingEvidencePath -Format Json -OutputPath $allowWarningsJsonPath | Out-Null
  $allowWarningsJson = Get-Content -LiteralPath $allowWarningsJsonPath -Raw | ConvertFrom-Json
  if ($allowWarningsJson.failOnWarningsDuringCollection -ne $false) {
    throw "Support evidence coverage self-test failed: AllowWarnings report should not request strict warning collection."
  }
  $allowWarningsFirstWorkflow = @($allowWarningsJson.missing | Where-Object { $_.workflowDispatchSupported -eq $true } | Select-Object -First 1)[0]
  if ($null -eq $allowWarningsFirstWorkflow -or -not ([string]$allowWarningsFirstWorkflow.workflowDispatchCommand).Contains("fail_on_warnings=false")) {
    throw "Support evidence coverage self-test failed: AllowWarnings dispatch command should set fail_on_warnings=false."
  }
  if (([string]$allowWarningsFirstWorkflow.collectionCommand).Contains("-FailOnWarnings") -or ([string]$allowWarningsFirstWorkflow.collectionCommand).Contains("--fail-on-warnings")) {
    throw "Support evidence coverage self-test failed: AllowWarnings collection command should not include strict warning flags."
  }
  if (([string]$allowWarningsFirstWorkflow.validationCommand).Contains("-FailOnWarnings")) {
    throw "Support evidence coverage self-test failed: AllowWarnings validation command should not include -FailOnWarnings."
  }

  $productionOnlyJsonPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-production-only-$([Guid]::NewGuid().ToString('N')).json"
  $productionOnlyCoverageArgs = Copy-SelfTestCoverageArgs -Source $selfTestCoverageArgs
  $productionOnlyCoverageArgs.ProductionRecommendedOnly = $true
  & $PSCommandPath @productionOnlyCoverageArgs -EvidencePath $missingEvidencePath -Format Json -OutputPath $productionOnlyJsonPath | Out-Null
  $productionOnlyJson = Get-Content -LiteralPath $productionOnlyJsonPath -Raw | ConvertFrom-Json
  if ($productionOnlyJson.productionRecommendedOnly -ne $true) {
    throw "Support evidence coverage self-test failed: production-only report did not record productionRecommendedOnly."
  }
  if ([int]$productionOnlyJson.summary.expectedCount -le 0 -or [int]$productionOnlyJson.summary.expectedCount -ge [int]$missingJson.summary.expectedCount) {
    throw "Support evidence coverage self-test failed: production-only report should cover fewer entries than full-matrix coverage."
  }
  $nonProductionRows = @($productionOnlyJson.missing | Where-Object { $_.nodeRuntimeProductionRecommended -ne $true })
  if ($nonProductionRows.Count -gt 0) {
    throw "Support evidence coverage self-test failed: production-only report included non-production runtime rows."
  }

  $bundleOutput = Join-Path $RepoRoot ".tmp\support-evidence-coverage-bundle-selftest-$([Guid]::NewGuid().ToString('N'))"
  $bundleArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    OutputDirectory = $bundleOutput
    BundleName = "selftest-coverage-bundle"
    IncludeServiceOnly = $true
    IncludeFallback = $true
  }
  if ($TargetId.Count -gt 0) {
    $bundleArgs.TargetId = [string[]]$TargetId
  }
  if ($Category.Count -gt 0) {
    $bundleArgs.Category = [string[]]$Category
  }
  if ($ProductionRecommendedOnly) {
    $bundleArgs.ProductionRecommendedOnly = $true
  }
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") @bundleArgs | Out-Null
  $bundleZip = Join-Path $bundleOutput "selftest-coverage-bundle.zip"
  $bundleCoverageJson = Join-Path $bundleOutput "coverage-from-bundle.json"
  $bundleCoverageArgs = Copy-SelfTestCoverageArgs -Source $selfTestCoverageArgs
  $bundleCoverageArgs.Remove("ReportOnly")
  $bundleCoverageArgs.BundlePath = $bundleZip
  $bundleCoverageArgs.MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  & $PSCommandPath @bundleCoverageArgs -Format Json -OutputPath $bundleCoverageJson | Out-Null
  $bundleCoverage = Get-Content -LiteralPath $bundleCoverageJson -Raw | ConvertFrom-Json
  if ([int]$bundleCoverage.summary.missingCount -ne 0) {
    throw "Support evidence coverage self-test failed: BundlePath coverage reported missing entries."
  }
  if ([int]$bundleCoverage.summary.expectedCount -ne [int]$result.summary.expectedCount) {
    throw "Support evidence coverage self-test failed: BundlePath coverage expected count mismatch."
  }
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
  "Csv" {
    $rows = @($result.covered + $result.missing)
    if ($OutputPath) { $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 } else { $rows | ConvertTo-Csv -NoTypeInformation }
  }
  "Markdown" {
    $content = ConvertTo-CoverageMarkdown -Result $result
    if ($OutputPath) { $content | Set-Content -Path $OutputPath -Encoding UTF8 } else { $content }
  }
  "Table" {
    Write-Host ""
    Write-Host "==> Support evidence coverage"
    Write-Host "Expected: $($result.summary.expectedCount)"
    Write-Host "Covered:  $($result.summary.coveredCount)"
    Write-Host "Missing:  $($result.summary.missingCount)"
    if ($result.summary.missingCount -gt 0) {
      @($missing | Select-Object -First 50) | Format-Table kind, targetId, nextJsMode, serviceManager, reverseProxy, nodeRuntimeSupportTier, nodeRuntimeProductionRecommended -AutoSize
      Write-Host ""
      Write-Host "Next collection and validation commands:"
      @($missing | Select-Object -First 10) | ForEach-Object {
        Write-Host ""
        Write-Host ("{0} / {1} / {2} / {3} / {4}" -f $_.kind, $_.targetId, $_.nextJsMode, $_.serviceManager, $_.reverseProxy)
        Write-Host "Collect:"
        Write-Host ([string]$_.collectionCommand)
        Write-Host "Validate:"
        Write-Host ([string]$_.validationCommand)
      }
      if ($missing.Count -gt 50) {
        Write-Host "... $($missing.Count - 50) more missing entries."
      }
      if ($missing.Count -gt 10) {
        Write-Host "... $($missing.Count - 10) more command pair(s). Use -Format Markdown or -Format Json for the full list."
      }
    }
  }
}

if ($SelfTest -and $result.summary.missingCount -ne 0) {
  throw "Support evidence coverage self-test failed."
}
if (-not $SelfTest -and -not $ReportOnly -and $result.summary.missingCount -gt 0) {
  throw "Support evidence coverage has $($result.summary.missingCount) missing entr$(if ($result.summary.missingCount -eq 1) { 'y' } else { 'ies' })."
}
