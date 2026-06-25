param(
  [string]$EvidencePath = "",
  [string]$BundlePath = "",
  [string]$MatrixPath = "",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
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
    [int]$RequiredMinimumUptimeHours
  )
  if ($Category -in @("windows-client", "windows-server")) {
    $windowsPath = $EvidenceFile.Replace("/", "\")
    return ".\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours $RequiredMinimumUptimeHours -JsonPath .\$windowsPath -FailOnCritical"
  }
  return "sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours $RequiredMinimumUptimeHours --json-output ./$EvidenceFile --fail-on-critical"
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

function Get-PrimaryEvidenceTarget {
  param([object]$Evidence)

  $explicit = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if ($explicit) { return (Normalize-Token $explicit) }

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $family = Normalize-Token (Get-StringValue -Object $platform -Names @("Family", "family"))
  $osCaption = Get-StringValue -Object $platform -Names @("OsCaption", "osCaption")
  $osId = Normalize-Token (Get-StringValue -Object $platform -Names @("OsId", "osId"))
  $kernelName = Normalize-Token (Get-StringValue -Object $platform -Names @("KernelName", "kernelName"))
  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")

  if ($osCaption -match 'Windows Server') {
    if ($osCaption -match '2012\s+R2') { return "windows-server-2012-r2" }
    foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
      if ($osCaption -match $year) { return "windows-server-$year" }
    }
    return "windows-server"
  }
  if ($osCaption -match 'Windows\s+10' -and $osCaption -notmatch 'Windows Server') { return "windows-10" }
  if ($osCaption -match 'Windows\s+11' -and $osCaption -notmatch 'Windows Server') { return "windows-11" }
  if ($prettyName -match 'CentOS Stream') { return "centos-stream" }
  if ($prettyName -match 'Oracle Linux') { return "oracle-linux" }
  if ($prettyName -match 'Linux Mint') { return "linux-mint" }

  switch ($osId) {
    "linuxmint" { return "linux-mint" }
    "ol" { return "oracle-linux" }
    "redhat" { return "rhel" }
    "red-hat" { return "rhel" }
    "mac-os" { return "macos" }
  }

  if ($osId -in @("ubuntu", "debian", "rhel", "centos", "rocky", "almalinux", "fedora", "alpine", "macos", "freebsd", "openbsd", "netbsd")) {
    return $osId
  }
  if ($family -in @("macos", "freebsd", "openbsd", "netbsd")) { return $family }
  if ($kernelName -eq "darwin") { return "macos" }
  return ""
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
      [pscustomobject]@{
        file = $file.FullName
        relativeFile = Get-DisplayPath -Path $file.FullName
        targetId = Get-PrimaryEvidenceTarget -Evidence $evidence
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
    [int]$RequiredMinimumUptimeHours
  )

  $targetId = Normalize-Token ([string]$Target.id)
  $modeValue = Normalize-Token $Mode
  $serviceManagerValue = Normalize-Token $ServiceManager
  $reverseProxyValue = Normalize-ReverseProxy $ReverseProxy
  $category = [string]$Target.category
  $evidenceFile = Get-EvidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -Kind $Kind
  $workflowDispatchSupported = Test-WorkflowDispatchSupported -Category $category
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
      fail_on_warnings = "false"
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
    requiredMinimumUptimeHours = $RequiredMinimumUptimeHours
    evidenceFile = $evidenceFile
    collectionCommand = Get-CollectionCommand -Category $category -EvidenceFile $evidenceFile -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours
    workflowDispatchSupported = $workflowDispatchSupported
    workflowInputSummary = $workflowInputSummary
    workflowDispatchCommand = $workflowDispatchCommand
  }
}

function Get-ExpectedEntries {
  param(
    [object[]]$Targets,
    [int]$RequiredMinimumUptimeHours
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
          $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "strict" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours)) | Out-Null
        }
        if ($IncludeServiceOnly) {
          foreach ($proxy in $serviceOnlyProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "service-only" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours)) | Out-Null
          }
        }
      }
      if ($IncludeFallback) {
        foreach ($fallbackManager in $fallbackManagers) {
          foreach ($proxy in $concreteProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback" -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours)) | Out-Null
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

  $lines.Add("| Kind | Target | Next.js mode | Service manager | Reverse proxy | Evidence file | Workflow |") | Out-Null
  $lines.Add("|---|---|---|---|---|---|---|") | Out-Null
  foreach ($row in @($Result.missing)) {
    $workflow = if ([bool]$row.workflowDispatchSupported) { "supported" } else { "local only" }
    $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | {6} |' -f $row.kind, $row.targetId, $row.nextJsMode, $row.serviceManager, $row.reverseProxy, $row.evidenceFile, $workflow)) | Out-Null
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
      platform = [ordered]@{
        family = $platformFamily
        supportTargetId = $targetId
        serviceManager = $serviceManager
        reverseProxy = $reverseProxy
        kernelName = $kernelName
        osId = $targetId
        osPrettyName = $targetId
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
        nextVersion = "14.2.3"
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
$targets = @(Get-ArrayValue $matrix.targets)

if ($SelfTest) {
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  $EvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-selftest-$([Guid]::NewGuid().ToString('N'))"
  $expectedForSelfTest = @(Get-ExpectedEntries -Targets $targets -RequiredMinimumUptimeHours $requiredMinimumUptimeHours)
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

$expectedEntries = @(Get-ExpectedEntries -Targets $targets -RequiredMinimumUptimeHours $requiredMinimumUptimeHours)
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
      requiredMinimumUptimeHours = $entry.requiredMinimumUptimeHours
      evidenceFile = $entry.evidenceFile
      collectionCommand = $entry.collectionCommand
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
      requiredMinimumUptimeHours = $entry.requiredMinimumUptimeHours
      evidenceFile = $entry.evidenceFile
      collectionCommand = $entry.collectionCommand
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
  $selfTestReportPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-selftest-report-$([Guid]::NewGuid().ToString('N')).md"
  & $PSCommandPath -EvidencePath $EvidencePath -MatrixPath $MatrixPath -IncludeServiceOnly -IncludeFallback -ReportOnly -Format Markdown -OutputPath $selfTestReportPath | Out-Null
  $selfTestReport = Get-Content -LiteralPath $selfTestReportPath -Raw
  if (-not $selfTestReport.Contains("Support Evidence Coverage Report")) {
    throw "Support evidence coverage self-test failed: Markdown report missing title."
  }
  if (-not $selfTestReport.Contains("_No missing entries._")) {
    throw "Support evidence coverage self-test failed: Markdown report should show no missing entries."
  }

  $missingEvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-selftest-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $missingEvidencePath -Force | Out-Null
  $missingReportPath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-missing-report-$([Guid]::NewGuid().ToString('N')).md"
  & $PSCommandPath -EvidencePath $missingEvidencePath -MatrixPath $MatrixPath -IncludeServiceOnly -IncludeFallback -ReportOnly -Format Markdown -OutputPath $missingReportPath | Out-Null
  $missingReport = Get-Content -LiteralPath $missingReportPath -Raw
  foreach ($expectedReportText in @(
      "Next Collection Commands",
      "GitHub Actions workflow dispatch:",
      "gh workflow run",
      "minimum_uptime_hours=$requiredMinimumUptimeHours",
      "-MinimumUptimeHours $requiredMinimumUptimeHours",
      "--minimum-uptime-hours $requiredMinimumUptimeHours",
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
  & $PSCommandPath -EvidencePath $missingEvidencePath -MatrixPath $MatrixPath -IncludeServiceOnly -IncludeFallback -ReportOnly -Format Json -OutputPath $missingJsonPath | Out-Null
  $missingJson = Get-Content -LiteralPath $missingJsonPath -Raw | ConvertFrom-Json
  if ([int]$missingJson.summary.missingCount -le 0) {
    throw "Support evidence coverage self-test failed: missing JSON report did not report missing entries."
  }
  $firstMissing = @($missingJson.missing | Select-Object -First 1)[0]
  foreach ($requiredProperty in @("evidenceFile", "collectionCommand", "requiredMinimumUptimeHours", "workflowDispatchSupported", "workflowInputSummary", "workflowDispatchCommand")) {
    if (-not $firstMissing.PSObject.Properties[$requiredProperty]) {
      throw "Support evidence coverage self-test failed: missing JSON row did not include $requiredProperty."
    }
  }
  if ([int]$firstMissing.requiredMinimumUptimeHours -ne $requiredMinimumUptimeHours) {
    throw "Support evidence coverage self-test failed: missing JSON row did not carry requiredMinimumUptimeHours."
  }
  $firstWindowsMissing = @($missingJson.missing | Where-Object { ([string]$_.targetId).StartsWith("windows-") } | Select-Object -First 1)[0]
  if ($null -eq $firstWindowsMissing -or -not ([string]$firstWindowsMissing.collectionCommand).Contains("-MinimumUptimeHours $requiredMinimumUptimeHours")) {
    throw "Support evidence coverage self-test failed: Windows collection command is missing minimum uptime guidance."
  }
  $firstUnixMissing = @($missingJson.missing | Where-Object { ([string]$_.targetId) -eq "ubuntu" } | Select-Object -First 1)[0]
  if ($null -eq $firstUnixMissing -or -not ([string]$firstUnixMissing.collectionCommand).Contains("--minimum-uptime-hours $requiredMinimumUptimeHours")) {
    throw "Support evidence coverage self-test failed: Unix collection command is missing minimum uptime guidance."
  }

  $bundleOutput = Join-Path $RepoRoot ".tmp\support-evidence-coverage-bundle-selftest-$([Guid]::NewGuid().ToString('N'))"
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") -EvidencePath $EvidencePath -MatrixPath $MatrixPath -OutputDirectory $bundleOutput -BundleName "selftest-coverage-bundle" -IncludeServiceOnly -IncludeFallback | Out-Null
  $bundleZip = Join-Path $bundleOutput "selftest-coverage-bundle.zip"
  $bundleCoverageJson = Join-Path $bundleOutput "coverage-from-bundle.json"
  & $PSCommandPath -BundlePath $bundleZip -MatrixPath $MatrixPath -MaxEvidenceAgeDays $MaxEvidenceAgeDays -IncludeServiceOnly -IncludeFallback -Format Json -OutputPath $bundleCoverageJson | Out-Null
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
      @($missing | Select-Object -First 50) | Format-Table kind, targetId, nextJsMode, serviceManager, reverseProxy -AutoSize
      if ($missing.Count -gt 50) {
        Write-Host "... $($missing.Count - 50) more missing entries."
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
