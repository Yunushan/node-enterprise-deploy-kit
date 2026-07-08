param(
  [string]$MatrixPath = "",
  [string]$OutputPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [ValidateSet("Json", "Markdown", "Csv", "DispatchMarkdown", "DispatchPowerShell")]
  [string]$Format = "Markdown",
  [string]$WorkflowFile = "host-evidence.yml",
  [string]$WorkflowRef = "main",
  [switch]$ProductionRecommendedOnly,
  [switch]$FailOnWarnings,
  [switch]$Quiet,
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

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
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
    $missing = @($wanted | Where-Object { $targetIdValue = $_; -not @($Targets | Where-Object { (Normalize-Token ([string]$_.id)) -eq $targetIdValue }) })
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
    throw "No support matrix targets matched the requested evidence plan filters."
  }
  return $selected
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

function Get-ConcreteReverseProxies {
  param([object]$Target)
  @(Get-ArrayValue $Target.reverseProxies |
    ForEach-Object { Normalize-Token ([string]$_) } |
    Where-Object { $_ -and $_ -ne "none" })
}

function Get-ServiceOnlyMarkers {
  param([object]$Target)
  @(Get-ArrayValue $Target.reverseProxies |
    ForEach-Object { Normalize-Token ([string]$_) } |
    Where-Object { $_ -eq "none" })
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
    [bool]$FailOnWarnings,
    [bool]$WorkflowDispatchSupported,
    [string]$ExpectedMatrixPath = "",
    [string]$ExpectedMatrixSha256 = ""
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
  if ($WorkflowDispatchSupported) {
    $args.Add("-RequireCiCollection") | Out-Null
    $args.Add("-RequireHostEvidenceWorkflowCollection") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMatrixPath)) {
      $args.Add("-ExpectedMatrixPath") | Out-Null
      $args.Add($ExpectedMatrixPath) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMatrixSha256)) {
      $args.Add("-ExpectedMatrixSha256") | Out-Null
      $args.Add($ExpectedMatrixSha256) | Out-Null
    }
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

function Test-TargetWorkflowDispatchSupported {
  param([object]$Target)

  $localCommandOnlyProperty = $Target.PSObject.Properties["localCommandOnly"]
  if ($localCommandOnlyProperty -and $localCommandOnlyProperty.Value -eq $true) {
    return $false
  }
  return (Test-WorkflowDispatchSupported -Category ([string]$Target.category))
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

function Get-RepoRelativePath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
  if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
  }
  return $Path.Replace("\", "/")
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
      "matrix_path",
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

function Format-WorkflowInputSummary {
  param([object]$Inputs)

  return (@(
      "platform=$($Inputs.platform)",
      "evidence_name=$($Inputs.evidence_name)",
      "expected_target_id=$($Inputs.expected_target_id)",
      "expected_nextjs_mode=$($Inputs.expected_nextjs_mode)",
      "expected_service_manager=$($Inputs.expected_service_manager)",
      "expected_reverse_proxy=$($Inputs.expected_reverse_proxy)"
    ) -join "; ")
}

function New-PlanEntry {
  param(
    [object]$Target,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind,
    [string]$Notes,
    [int]$RequiredMinimumUptimeHours,
    [bool]$FailOnWarnings
  )

  $targetId = Normalize-Token ([string]$Target.id)
  $modeValue = Normalize-Token $Mode
  $serviceManagerValue = Normalize-Token $ServiceManager
  $reverseProxyValue = Normalize-Token $ReverseProxy
  $evidenceFile = Get-EvidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -Kind $Kind
  $category = [string]$Target.category
  $nodeRuntimeSupport = Get-OptionalPropertyValue -Object $Target -Name "nodeRuntimeSupport"
  $nodeRuntimeMinimumNodeVersion = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "minimumNodeVersion")
  $nodeRuntimeSupportTier = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "supportTier")
  $nodeRuntimeProductionRecommendedProperty = if ($nodeRuntimeSupport) { $nodeRuntimeSupport.PSObject.Properties["productionRecommended"] } else { $null }
  $nodeRuntimeProductionRecommended = if ($nodeRuntimeProductionRecommendedProperty -and $nodeRuntimeProductionRecommendedProperty.Value -is [bool]) { [bool]$nodeRuntimeProductionRecommendedProperty.Value } else { $null }
  $nodeRuntimeRequirements = [string](Get-OptionalPropertyValue -Object $nodeRuntimeSupport -Name "requirements")
  $workflowDispatchSupported = Test-TargetWorkflowDispatchSupported -Target $Target
  $localCommandOnly = -not [bool]$workflowDispatchSupported
  $workflowInputs = $null
  $workflowInputSummary = "local command only; host-evidence workflow is not supported for target category '$category'"
  $workflowDispatchCommand = ""
  $workflowSupportMatrixPath = ""
  $workflowSupportMatrixSha256 = ""
  if ($workflowDispatchSupported) {
    $workflowSupportMatrixPath = Get-RepoRelativePath -Path $MatrixPath
    $workflowSupportMatrixSha256 = (Get-FileHash -LiteralPath $MatrixPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $workflowInputs = [pscustomobject]@{
      runner_labels = '["self-hosted","' + $targetId + '"]'
      platform = Get-WorkflowPlatform -Category $category
      config_path = Get-WorkflowConfigPath -Category $category
      matrix_path = $workflowSupportMatrixPath
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
    $workflowInputSummary = Format-WorkflowInputSummary -Inputs $workflowInputs
    $workflowDispatchCommand = Format-GhWorkflowRunCommand -Inputs $workflowInputs -WorkflowFile $WorkflowFile -WorkflowRef $WorkflowRef
  }

  [pscustomobject]@{
    kind = $Kind
    targetId = $targetId
    targetName = [string]$Target.name
    category = $category
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
    validationCommand = Get-ValidationCommand -EvidenceFile $evidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -FailOnWarnings $FailOnWarnings -WorkflowDispatchSupported $workflowDispatchSupported -ExpectedMatrixPath $workflowSupportMatrixPath -ExpectedMatrixSha256 $workflowSupportMatrixSha256
    workflowDispatchSupported = $workflowDispatchSupported
    localCommandOnly = $localCommandOnly
    workflowInputs = $workflowInputs
    workflowInputSummary = $workflowInputSummary
    workflowDispatchCommand = $workflowDispatchCommand
    workflowSupportMatrixPath = $workflowSupportMatrixPath
    workflowSupportMatrixSha256 = $workflowSupportMatrixSha256
    notes = $Notes
  }
}

function Get-PlanSections {
  param([object]$Plan)

  return @(
    @{ Title = "Strict Real-Host Evidence"; Property = "strictEvidence"; Items = @($Plan.strictEvidence) },
    @{ Title = "Service-Only Evidence"; Property = "serviceOnlyEvidence"; Items = @($Plan.serviceOnlyEvidence) },
    @{ Title = "Fallback Evidence"; Property = "fallbackEvidence"; Items = @($Plan.fallbackEvidence) }
  )
}

function ConvertTo-PlanMarkdown {
  param([object]$Plan)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Support Evidence Plan") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add('Generated from `config/support-matrix.example.json`.') | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("| Count | Value |") | Out-Null
  $lines.Add("|---|---:|") | Out-Null
  $lines.Add("| Targets | $($Plan.summary.targetCount) |") | Out-Null
  $lines.Add("| Strict real-host evidence entries | $($Plan.summary.strictEvidenceCount) |") | Out-Null
  $lines.Add("| Service-only evidence entries | $($Plan.summary.serviceOnlyEvidenceCount) |") | Out-Null
  $lines.Add("| Fallback evidence entries | $($Plan.summary.fallbackEvidenceCount) |") | Out-Null
  $lines.Add("| Required minimum uptime hours | $($Plan.requiredMinimumUptimeHours) |") | Out-Null
  $lines.Add("| Target filters | $(if (@($Plan.filters.targetId).Count -gt 0) { @($Plan.filters.targetId) -join ', ' } else { 'all' }) |") | Out-Null
  $lines.Add("| Category filters | $(if (@($Plan.filters.category).Count -gt 0) { @($Plan.filters.category) -join ', ' } else { 'all' }) |") | Out-Null
  $lines.Add("| Production recommended only | $($Plan.filters.productionRecommendedOnly) |") | Out-Null
  $lines.Add("| Fail on warnings during collection | $($Plan.filters.failOnWarnings) |") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add('Strict entries are the combinations enforced by `Test-SupportClaim.ps1 -RequireBothNextJsModes -RequireDeclaredServiceManagers -RequireDeclaredReverseProxies`, with optional collector, uptime, and workflow-provenance gates for final release signoff.') | Out-Null
  $lines.Add('Service-only entries cover `ReverseProxy=none` and are tracked separately because there is no concrete reverse-proxy implementation to probe.') | Out-Null
  $lines.Add("Fallback entries document compatibility paths such as PM2; they do not satisfy strict service-manager claims.") | Out-Null
  $lines.Add("") | Out-Null

  foreach ($section in Get-PlanSections -Plan $Plan) {
    $lines.Add("## $($section.Title)") | Out-Null
    $lines.Add("") | Out-Null
    $items = @($section.Items)
    if ($items.Count -eq 0) {
      $lines.Add("_No entries._") | Out-Null
      $lines.Add("") | Out-Null
      continue
    }
    $lines.Add("| Target | Mode | Service | Proxy | Node runtime | Evidence file | Collection route | Collection command | Validation command | Workflow route |") | Out-Null
    $lines.Add("|---|---|---|---|---|---|---|---|---|---|") | Out-Null
    foreach ($item in $items) {
      $targetCell = ([string]$item.targetId).Replace("|", "\|")
      $modeCell = ([string]$item.nextJsMode).Replace("|", "\|")
      $serviceCell = ([string]$item.serviceManager).Replace("|", "\|")
      $proxyCell = ([string]$item.reverseProxy).Replace("|", "\|")
      $fileCell = ([string]$item.evidenceFile).Replace("|", "\|")
      $runtimeSuffix = if ($item.nodeRuntimeProductionRecommended -eq $true) { "production" } else { "not production" }
      $runtimeCell = ("{0}; {1}" -f [string]$item.nodeRuntimeSupportTier, $runtimeSuffix).Replace("|", "\|")
      $commandCell = ([string]$item.collectionCommand).Replace("|", "\|")
      $validationCell = ([string]$item.validationCommand).Replace("|", "\|")
      $routeCell = if ($item.localCommandOnly -eq $true) { "local command only" } else { "host-evidence workflow" }
      $workflowCell = ([string]$item.workflowInputSummary).Replace("|", "\|")
      $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | {6} | `{7}` | `{8}` | `{9}` |' -f $targetCell, $modeCell, $serviceCell, $proxyCell, $runtimeCell, $fileCell, $routeCell, $commandCell, $validationCell, $workflowCell)) | Out-Null
    }
    $lines.Add("") | Out-Null
  }

  return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function ConvertTo-DispatchMarkdown {
  param([object]$Plan)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Host Evidence Workflow Dispatch Commands") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add('Generated from `config/support-matrix.example.json`. Review runner labels before dispatching against real hosts.') | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add('These commands invoke the manual `host-evidence` workflow with exact expected target, Next.js mode, service manager, and reverse-proxy inputs. Local-command-only targets are listed separately and are not emitted as workflow dispatch commands.') | Out-Null
  $lines.Add("") | Out-Null

  foreach ($section in Get-PlanSections -Plan $Plan) {
    $items = @($section.Items | Where-Object { $_.workflowDispatchSupported -eq $true })
    $lines.Add("## $($section.Title)") | Out-Null
    $lines.Add("") | Out-Null
    if ($items.Count -eq 0) {
      $lines.Add("_No workflow-dispatch entries._") | Out-Null
      $lines.Add("") | Out-Null
      continue
    }
    foreach ($item in $items) {
      $lines.Add("### $($item.targetId) / $($item.nextJsMode) / $($item.serviceManager) / $($item.reverseProxy)") | Out-Null
      $lines.Add("") | Out-Null
      $lines.Add('```powershell') | Out-Null
      $lines.Add([string]$item.workflowDispatchCommand) | Out-Null
      $lines.Add('```') | Out-Null
      $lines.Add("") | Out-Null
    }
  }

  $localOnlyItems = @(
    foreach ($section in Get-PlanSections -Plan $Plan) {
      @($section.Items | Where-Object { $_.workflowDispatchSupported -ne $true })
    }
  )
  if ($localOnlyItems.Count -gt 0) {
    $lines.Add("## Local-Command-Only Evidence") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("These targets are not dispatched through GitHub Actions. Collect them on the target host with the local command, then validate the resulting evidence folder.") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Target | Mode | Service | Proxy | Collection command | Validation command |") | Out-Null
    $lines.Add("|---|---|---|---|---|---|") | Out-Null
    foreach ($item in $localOnlyItems) {
      $targetCell = ([string]$item.targetId).Replace("|", "\|")
      $modeCell = ([string]$item.nextJsMode).Replace("|", "\|")
      $serviceCell = ([string]$item.serviceManager).Replace("|", "\|")
      $proxyCell = ([string]$item.reverseProxy).Replace("|", "\|")
      $commandCell = ([string]$item.collectionCommand).Replace("|", "\|")
      $validationCell = ([string]$item.validationCommand).Replace("|", "\|")
      $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` |' -f $targetCell, $modeCell, $serviceCell, $proxyCell, $commandCell, $validationCell)) | Out-Null
    }
    $lines.Add("") | Out-Null
  }

  return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function ConvertTo-DispatchPowerShell {
  param(
    [object]$Plan,
    [string]$WorkflowFile,
    [string]$WorkflowRef
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("param(") | Out-Null
  $lines.Add("  [switch]`$Run") | Out-Null
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("Set-StrictMode -Version Latest") | Out-Null
  $lines.Add("`$ErrorActionPreference = `"Stop`"") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$WorkflowFile = $(Quote-PowerShellArgument $WorkflowFile)") | Out-Null
  $lines.Add("`$WorkflowRef = $(Quote-PowerShellArgument $WorkflowRef)") | Out-Null
  $lines.Add("`$InputNames = @(") | Out-Null
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
    $lines.Add("  $(Quote-PowerShellArgument $name)") | Out-Null
  }
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$Dispatches = @(") | Out-Null

  foreach ($section in Get-PlanSections -Plan $Plan) {
    foreach ($item in @($section.Items | Where-Object { $_.workflowDispatchSupported -eq $true })) {
      $inputs = $item.workflowInputs
      $lines.Add("  [pscustomobject]@{") | Out-Null
      $lines.Add("    Kind = $(Quote-PowerShellArgument ([string]$item.kind))") | Out-Null
      $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$item.targetId))") | Out-Null
      $lines.Add("    NextJsMode = $(Quote-PowerShellArgument ([string]$item.nextJsMode))") | Out-Null
      $lines.Add("    ServiceManager = $(Quote-PowerShellArgument ([string]$item.serviceManager))") | Out-Null
      $lines.Add("    ReverseProxy = $(Quote-PowerShellArgument ([string]$item.reverseProxy))") | Out-Null
      $lines.Add("    Command = $(Quote-PowerShellArgument ([string]$item.workflowDispatchCommand))") | Out-Null
      $lines.Add("    Inputs = [ordered]@{") | Out-Null
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
        $lines.Add("      $name = $(Quote-PowerShellArgument ([string]$inputs.$name))") | Out-Null
      }
      $lines.Add("    }") | Out-Null
      $lines.Add("  }") | Out-Null
    }
  }

  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("`$LocalOnly = @(") | Out-Null
  foreach ($section in Get-PlanSections -Plan $Plan) {
    foreach ($item in @($section.Items | Where-Object { $_.workflowDispatchSupported -ne $true })) {
      $lines.Add("  [pscustomobject]@{") | Out-Null
      $lines.Add("    Kind = $(Quote-PowerShellArgument ([string]$item.kind))") | Out-Null
      $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$item.targetId))") | Out-Null
      $lines.Add("    NextJsMode = $(Quote-PowerShellArgument ([string]$item.nextJsMode))") | Out-Null
      $lines.Add("    ServiceManager = $(Quote-PowerShellArgument ([string]$item.serviceManager))") | Out-Null
      $lines.Add("    ReverseProxy = $(Quote-PowerShellArgument ([string]$item.reverseProxy))") | Out-Null
      $lines.Add("    CollectionCommand = $(Quote-PowerShellArgument ([string]$item.collectionCommand))") | Out-Null
      $lines.Add("    ValidationCommand = $(Quote-PowerShellArgument ([string]$item.validationCommand))") | Out-Null
      $lines.Add("  }") | Out-Null
    }
  }
  $lines.Add(")") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("foreach (`$dispatch in `$Dispatches) {") | Out-Null
  $lines.Add("  `$arguments = @(`"workflow`", `"run`", `$WorkflowFile, `"--ref`", `$WorkflowRef)") | Out-Null
  $lines.Add("  foreach (`$name in `$InputNames) {") | Out-Null
  $lines.Add("    `$arguments += @(`"-f`", `"`$name=`$(`$dispatch.Inputs[`$name])`")") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("  if (`$Run) {") | Out-Null
  $lines.Add("    & gh @arguments") | Out-Null
  $lines.Add("    if (`$LASTEXITCODE -ne 0) {") | Out-Null
  $lines.Add("      throw `"Failed to dispatch host evidence workflow for `$(`$dispatch.TargetId) / `$(`$dispatch.NextJsMode) / `$(`$dispatch.ServiceManager) / `$(`$dispatch.ReverseProxy).`"") | Out-Null
  $lines.Add("    }") | Out-Null
  $lines.Add("  } else {") | Out-Null
  $lines.Add("    `$dispatch.Command") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("if (-not `$Run) {") | Out-Null
  $lines.Add("  Write-Host `"`"") | Out-Null
  $lines.Add("  Write-Host `"Review runner labels, then rerun this script with -Run to dispatch workflows.`"") | Out-Null
  $lines.Add("  if (`$LocalOnly.Count -gt 0) {") | Out-Null
  $lines.Add("    Write-Host `"`"") | Out-Null
  $lines.Add("    Write-Host `"Local-command-only entries are not dispatched through GitHub Actions:`"") | Out-Null
  $lines.Add("    `$LocalOnly | Format-Table Kind, TargetId, NextJsMode, ServiceManager, ReverseProxy, CollectionCommand, ValidationCommand -AutoSize") | Out-Null
  $lines.Add("  }") | Out-Null
  $lines.Add("}") | Out-Null

  return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($SelfTest) {
  $Format = "Json"
  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepoRoot ".tmp\support-evidence-plan-$([Guid]::NewGuid().ToString('N')).json"
  }
  $Quiet = $true
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null

$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Matrix $matrix
$allTargets = @(Get-ArrayValue $matrix.targets)
$targets = @(Select-MatrixTargets -Targets $allTargets -TargetId $TargetId -Category $Category -ProductionRecommendedOnly ([bool]$ProductionRecommendedOnly))
$strictEvidence = New-Object System.Collections.Generic.List[object]
$serviceOnlyEvidence = New-Object System.Collections.Generic.List[object]
$fallbackEvidence = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
  $modes = @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $serviceManagers = @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $fallbackManagers = @(Get-ArrayValue (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers") | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $concreteProxies = @(Get-ConcreteReverseProxies -Target $target)
  $serviceOnlyMarkers = @(Get-ServiceOnlyMarkers -Target $target)

  foreach ($mode in $modes) {
    foreach ($serviceManager in $serviceManagers) {
      foreach ($proxy in $concreteProxies) {
        $strictEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "strict" -Notes "Strict real-host evidence." -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings ([bool]$FailOnWarnings))) | Out-Null
      }
      foreach ($proxy in $serviceOnlyMarkers) {
        $serviceOnlyEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "service-only" -Notes "Service-only or external load-balancer evidence." -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings ([bool]$FailOnWarnings))) | Out-Null
      }
    }
    foreach ($fallbackManager in $fallbackManagers) {
      foreach ($proxy in $concreteProxies) {
        $fallbackEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback" -Notes "Compatibility fallback evidence; not a strict service-manager claim." -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings ([bool]$FailOnWarnings))) | Out-Null
      }
      foreach ($proxy in $serviceOnlyMarkers) {
        $fallbackEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback" -Notes "Compatibility fallback service-only evidence; not a strict service-manager claim." -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -FailOnWarnings ([bool]$FailOnWarnings))) | Out-Null
      }
    }
  }
}

$strictEvidenceArray = @($strictEvidence | ForEach-Object { $_ })
$serviceOnlyEvidenceArray = @($serviceOnlyEvidence | ForEach-Object { $_ })
$fallbackEvidenceArray = @($fallbackEvidence | ForEach-Object { $_ })
$matrixFileName = [string](Split-Path -Path $MatrixPath -Leaf)

$plan = [pscustomobject]@{
  schemaVersion = 1
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  matrixFileName = $matrixFileName
  requiredMinimumUptimeHours = $requiredMinimumUptimeHours
  filters = [pscustomobject]@{
    targetId = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    category = @($Category | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    productionRecommendedOnly = [bool]$ProductionRecommendedOnly
    failOnWarnings = [bool]$FailOnWarnings
    selectedTargets = @($targets | ForEach-Object { Normalize-Token ([string]$_.id) })
  }
  summary = [pscustomobject]@{
    targetCount = [int]$targets.Count
    strictEvidenceCount = [int]$strictEvidenceArray.Count
    serviceOnlyEvidenceCount = [int]$serviceOnlyEvidenceArray.Count
    fallbackEvidenceCount = [int]$fallbackEvidenceArray.Count
  }
  strictEvidence = $strictEvidenceArray
  serviceOnlyEvidence = $serviceOnlyEvidenceArray
  fallbackEvidence = $fallbackEvidenceArray
}

if ($plan.summary.strictEvidenceCount -lt 1) {
  throw "Support evidence plan has no strict evidence entries."
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
    $content = $plan | ConvertTo-Json -Depth 8
    if ($OutputPath) {
      $content | Set-Content -Path $OutputPath -Encoding UTF8
    } else {
      $content
    }
  }
  "Csv" {
    $rows = @($plan.strictEvidence + $plan.serviceOnlyEvidence + $plan.fallbackEvidence)
    if ($OutputPath) {
      $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    } else {
      $rows | ConvertTo-Csv -NoTypeInformation
    }
  }
  "Markdown" {
    $content = ConvertTo-PlanMarkdown -Plan $plan
    if ($OutputPath) {
      $content | Set-Content -Path $OutputPath -Encoding UTF8
    } else {
      $content
    }
  }
  "DispatchMarkdown" {
    $content = ConvertTo-DispatchMarkdown -Plan $plan
    if ($OutputPath) {
      $content | Set-Content -Path $OutputPath -Encoding UTF8
    } else {
      $content
    }
  }
  "DispatchPowerShell" {
    $content = ConvertTo-DispatchPowerShell -Plan $plan -WorkflowFile $WorkflowFile -WorkflowRef $WorkflowRef
    if ($OutputPath) {
      $content | Set-Content -Path $OutputPath -Encoding UTF8
    } else {
      $content
    }
  }
}

if ($SelfTest) {
  $parsed = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
  $workflowInputValidatorPath = Join-Path $ScriptDir "Test-HostEvidenceWorkflowInputs.ps1"
  if (-not (Test-Path -LiteralPath $workflowInputValidatorPath -PathType Leaf)) {
    throw "Support evidence plan self-test failed: missing host evidence workflow input validator."
  }
  if ([int]$parsed.summary.strictEvidenceCount -ne @($parsed.strictEvidence).Count) {
    throw "Support evidence plan self-test failed: strictEvidenceCount does not match strictEvidence."
  }
  $firstStrict = @($parsed.strictEvidence)[0]
  if ($firstStrict.workflowDispatchSupported -ne $true) {
    throw "Support evidence plan self-test failed: first strict evidence entry should support workflow dispatch."
  }
  $allPlanEntries = @($parsed.strictEvidence) + @($parsed.serviceOnlyEvidence) + @($parsed.fallbackEvidence)
  foreach ($entry in $allPlanEntries) {
    $context = "$($entry.kind)/$($entry.targetId)/$($entry.nextJsMode)/$($entry.serviceManager)/$($entry.reverseProxy)"
    foreach ($requiredPlanProperty in @("validationCommand", "workflowDispatchSupported", "localCommandOnly", "workflowSupportMatrixPath", "workflowSupportMatrixSha256")) {
      if (-not $entry.PSObject.Properties[$requiredPlanProperty]) {
        throw "Support evidence plan self-test failed: $requiredPlanProperty missing from $context."
      }
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.validationCommand)) {
      throw "Support evidence plan self-test failed: validationCommand missing from $context."
    }
    if (($entry.workflowDispatchSupported -eq $true) -eq ($entry.localCommandOnly -eq $true)) {
      throw "Support evidence plan self-test failed: workflowDispatchSupported and localCommandOnly disagree for $context."
    }
  }
  $workflowSupportedEntries = @($allPlanEntries | Where-Object { $_.workflowDispatchSupported -eq $true })
  if ($workflowSupportedEntries.Count -lt 1) {
    throw "Support evidence plan self-test failed: expected at least one workflow-dispatch-supported evidence entry."
  }
  $fallbackServiceOnlyEntry = @($allPlanEntries | Where-Object {
      $_.kind -eq "fallback" -and
      $_.targetId -eq "windows-10" -and
      $_.serviceManager -eq "pm2" -and
      $_.reverseProxy -eq "none"
    } | Select-Object -First 1)
  if ($fallbackServiceOnlyEntry.Count -ne 1) {
    throw "Support evidence plan self-test failed: expected fallback service-only PM2 evidence entry."
  }
  if (-not ([string]$fallbackServiceOnlyEntry[0].evidenceFile).EndsWith("pm2-none-fallback.json")) {
    throw "Support evidence plan self-test failed: fallback service-only evidence file should use the fallback suffix."
  }
  foreach ($entry in $workflowSupportedEntries) {
    $context = "$($entry.kind)/$($entry.targetId)/$($entry.nextJsMode)/$($entry.serviceManager)/$($entry.reverseProxy)"
    if (-not $entry.PSObject.Properties["workflowInputs"]) {
      throw "Support evidence plan self-test failed: workflowInputs missing from $context."
    }
    foreach ($requiredInput in @(
        "runner_labels",
        "platform",
        "config_path",
        "matrix_path",
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
      if (-not $entry.workflowInputs.PSObject.Properties[$requiredInput]) {
        throw "Support evidence plan self-test failed: workflowInputs.$requiredInput missing from $context."
      }
    }
    foreach ($requiredRuntimeProperty in @(
        "nodeRuntimeMinimumNodeVersion",
        "nodeRuntimeSupportTier",
        "nodeRuntimeProductionRecommended",
        "nodeRuntimeRequirements",
        "validationCommand"
      )) {
      if (-not $entry.PSObject.Properties[$requiredRuntimeProperty]) {
        throw "Support evidence plan self-test failed: $requiredRuntimeProperty missing from $context."
      }
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.nodeRuntimeMinimumNodeVersion) -or [string]::IsNullOrWhiteSpace([string]$entry.nodeRuntimeSupportTier)) {
      throw "Support evidence plan self-test failed: Node runtime support metadata is incomplete for $context."
    }
    if ($entry.workflowInputs.expected_target_id -ne $entry.targetId) {
      throw "Support evidence plan self-test failed: expected_target_id does not match targetId for $context."
    }
    if ($entry.workflowInputs.expected_nextjs_mode -ne $entry.nextJsMode) {
      throw "Support evidence plan self-test failed: expected_nextjs_mode does not match nextJsMode for $context."
    }
    if ($entry.workflowInputs.expected_service_manager -ne $entry.serviceManager) {
      throw "Support evidence plan self-test failed: expected_service_manager does not match serviceManager for $context."
    }
    if ($entry.workflowInputs.expected_reverse_proxy -ne $entry.reverseProxy) {
      throw "Support evidence plan self-test failed: expected_reverse_proxy does not match reverseProxy for $context."
    }
    if ([int]$entry.workflowInputs.minimum_uptime_hours -ne [int]$entry.requiredMinimumUptimeHours) {
      throw "Support evidence plan self-test failed: minimum_uptime_hours does not match requiredMinimumUptimeHours for $context."
    }
    if ([string]$entry.workflowInputs.matrix_path -ne (Get-RepoRelativePath -Path $MatrixPath)) {
      throw "Support evidence plan self-test failed: matrix_path does not match MatrixPath for $context."
    }
    if ([string]$entry.workflowSupportMatrixPath -ne (Get-RepoRelativePath -Path $MatrixPath)) {
      throw "Support evidence plan self-test failed: workflowSupportMatrixPath does not match MatrixPath for $context."
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.workflowSupportMatrixSha256) -or [string]$entry.workflowSupportMatrixSha256 -notmatch '^[a-f0-9]{64}$') {
      throw "Support evidence plan self-test failed: workflowSupportMatrixSha256 is missing or invalid for $context."
    }
    $validationCommand = [string]$entry.validationCommand
    foreach ($expectedValidationFragment in @(
        "-EvidencePath .\$(([string]$entry.evidenceFile).Replace('/', '\'))",
        "-ExpectedTargetId $($entry.targetId)",
        "-ExpectedNextJsMode $($entry.nextJsMode)",
        "-ExpectedServiceManager $($entry.serviceManager)",
        "-ExpectedReverseProxy $($entry.reverseProxy)",
        "-RequireMinimumUptimeHours $($entry.requiredMinimumUptimeHours)",
        "-ExpectedMatrixPath $($entry.workflowSupportMatrixPath)",
        "-ExpectedMatrixSha256 $($entry.workflowSupportMatrixSha256)"
      )) {
      if (-not $validationCommand.Contains($expectedValidationFragment)) {
        throw "Support evidence plan self-test failed: validationCommand is missing $expectedValidationFragment for $context."
      }
    }
    if ($entry.reverseProxy -eq "none" -and -not $validationCommand.Contains("-AllowReverseProxyNone")) {
      throw "Support evidence plan self-test failed: service-only validationCommand is missing -AllowReverseProxyNone for $context."
    }
    try {
      & $workflowInputValidatorPath `
        -RunnerLabels ([string]$entry.workflowInputs.runner_labels) `
        -Platform ([string]$entry.workflowInputs.platform) `
        -ConfigPath ([string]$entry.workflowInputs.config_path) `
        -MatrixPath ([string]$entry.workflowInputs.matrix_path) `
        -EvidenceName ([string]$entry.workflowInputs.evidence_name) `
        -ExpectedTargetId ([string]$entry.workflowInputs.expected_target_id) `
        -ExpectedNextJsMode ([string]$entry.workflowInputs.expected_nextjs_mode) `
        -ExpectedServiceManager ([string]$entry.workflowInputs.expected_service_manager) `
        -ExpectedReverseProxy ([string]$entry.workflowInputs.expected_reverse_proxy) `
        -MinimumUptimeHours ([string]$entry.workflowInputs.minimum_uptime_hours) `
        -UploadRetentionDays ([string]$entry.workflowInputs.upload_retention_days) `
        -Quiet
    } catch {
      throw "Support evidence plan self-test failed: workflowInputs were rejected by host evidence workflow validator for $($context): $($_.Exception.Message)"
    }
    $command = [string]$entry.workflowDispatchCommand
    if (-not $command.Contains("gh workflow run")) {
      throw "Support evidence plan self-test failed: workflowDispatchCommand is missing gh workflow run for $context."
    }
    foreach ($expectedFragment in @(
        "matrix_path=$($entry.workflowInputs.matrix_path)",
        "expected_target_id=$($entry.targetId)",
        "expected_nextjs_mode=$($entry.nextJsMode)",
        "expected_service_manager=$($entry.serviceManager)",
        "expected_reverse_proxy=$($entry.reverseProxy)",
        "minimum_uptime_hours=$($entry.requiredMinimumUptimeHours)"
      )) {
      if (-not $command.Contains($expectedFragment)) {
        throw "Support evidence plan self-test failed: workflowDispatchCommand is missing $expectedFragment for $context."
      }
    }
  }
  $planMarkdown = ConvertTo-PlanMarkdown -Plan $plan
  if ($planMarkdown.Contains('$targetCell') -or $planMarkdown.Contains('$workflowCell')) {
    throw "Support evidence plan self-test failed: Markdown output contains unexpanded table placeholders."
  }
  if (-not $planMarkdown.Contains("Collection command")) {
    throw "Support evidence plan self-test failed: Markdown output is missing collection command guidance."
  }
  if (-not $planMarkdown.Contains("Validation command")) {
    throw "Support evidence plan self-test failed: Markdown output is missing validation command guidance."
  }
  $planCsvPath = Join-Path $RepoRoot ".tmp\support-evidence-plan-csv-$([Guid]::NewGuid().ToString('N')).csv"
  & $PSCommandPath `
    -Format Csv `
    -OutputPath $planCsvPath `
    -Quiet
  $planCsvHeader = (Get-Content -LiteralPath $planCsvPath -First 1)
  if (-not ([string]$planCsvHeader).Contains("validationCommand")) {
    throw "Support evidence plan self-test failed: CSV output is missing validationCommand."
  }
  if (-not ([string]$planCsvHeader).Contains("workflowSupportMatrixSha256")) {
    throw "Support evidence plan self-test failed: CSV output is missing workflowSupportMatrixSha256."
  }
  $planCsvText = Get-Content -LiteralPath $planCsvPath -Raw
  if (-not $planCsvText.Contains("Test-HostEvidence.ps1")) {
    throw "Support evidence plan self-test failed: CSV output is missing validation command content."
  }
  if (-not $planCsvText.Contains("-ExpectedMatrixSha256")) {
    throw "Support evidence plan self-test failed: CSV output is missing matrix SHA256 validation guidance."
  }
  if (-not $planMarkdown.Contains("Node runtime")) {
    throw "Support evidence plan self-test failed: Markdown output is missing Node runtime support guidance."
  }
  if (-not $planMarkdown.Contains("Required minimum uptime hours")) {
    throw "Support evidence plan self-test failed: Markdown output is missing required minimum uptime summary."
  }
  if (-not $planMarkdown.Contains("Fail on warnings during collection")) {
    throw "Support evidence plan self-test failed: Markdown output is missing strict warning collection summary."
  }
  if (-not $planMarkdown.Contains("-MinimumUptimeHours $requiredMinimumUptimeHours")) {
    throw "Support evidence plan self-test failed: Markdown output is missing Windows minimum uptime guidance."
  }
  if (-not $planMarkdown.Contains("--minimum-uptime-hours $requiredMinimumUptimeHours")) {
    throw "Support evidence plan self-test failed: Markdown output is missing Unix minimum uptime guidance."
  }
  $localOnlyStrict = @($parsed.strictEvidence | Where-Object { $_.workflowDispatchSupported -ne $true })
  if ($localOnlyStrict.Count -lt 1) {
    throw "Support evidence plan self-test failed: expected at least one local-command-only strict evidence entry."
  }
  if (@($localOnlyStrict | Where-Object { $_.targetId -eq "freebsd" }).Count -lt 1) {
    throw "Support evidence plan self-test failed: FreeBSD should be a local-command-only evidence target."
  }
  foreach ($workflowTargetExpectation in @(
      [pscustomobject]@{ TargetId = "windows-server-2022"; Platform = "windows"; ConfigPath = "config/windows/app.config.json" },
      [pscustomobject]@{ TargetId = "macos"; Platform = "unix"; ConfigPath = "config/linux/app.env" }
    )) {
    $targetEntries = @($parsed.strictEvidence | Where-Object { [string]$_.targetId -eq [string]$workflowTargetExpectation.TargetId })
    if ($targetEntries.Count -lt 1) {
      throw "Support evidence plan self-test failed: expected strict workflow-dispatch entries for $($workflowTargetExpectation.TargetId)."
    }
    foreach ($entry in $targetEntries) {
      $context = "$($entry.kind)/$($entry.targetId)/$($entry.nextJsMode)/$($entry.serviceManager)/$($entry.reverseProxy)"
      if ($entry.workflowDispatchSupported -ne $true) {
        throw "Support evidence plan self-test failed: $context should support host-evidence workflow dispatch."
      }
      if (-not ([string]$entry.validationCommand).Contains("-RequireHostEvidenceWorkflowCollection")) {
        throw "Support evidence plan self-test failed: $context validation command is missing workflow provenance enforcement."
      }
      if ($null -eq $entry.workflowInputs) {
        throw "Support evidence plan self-test failed: $context is missing workflow inputs."
      }
      if ([string]$entry.workflowInputs.platform -ne [string]$workflowTargetExpectation.Platform) {
        throw "Support evidence plan self-test failed: $context has unexpected workflow platform '$($entry.workflowInputs.platform)'."
      }
      if ([string]$entry.workflowInputs.config_path -ne [string]$workflowTargetExpectation.ConfigPath) {
        throw "Support evidence plan self-test failed: $context has unexpected workflow config path '$($entry.workflowInputs.config_path)'."
      }
      if (-not ([string]$entry.workflowInputs.runner_labels).Contains([string]$workflowTargetExpectation.TargetId)) {
        throw "Support evidence plan self-test failed: $context runner labels do not include $($workflowTargetExpectation.TargetId)."
      }
      if (-not ([string]$entry.workflowDispatchCommand).Contains("expected_target_id=$($workflowTargetExpectation.TargetId)")) {
        throw "Support evidence plan self-test failed: $context dispatch command is missing expected target id."
      }
    }
  }
  foreach ($bsdTargetId in @("freebsd", "openbsd", "netbsd")) {
    $bsdEntries = @($allPlanEntries | Where-Object { [string]$_.targetId -eq $bsdTargetId })
    if ($bsdEntries.Count -lt 1) {
      throw "Support evidence plan self-test failed: expected local-command-only entries for $bsdTargetId."
    }
    foreach ($entry in $bsdEntries) {
      $context = "$($entry.kind)/$($entry.targetId)/$($entry.nextJsMode)/$($entry.serviceManager)/$($entry.reverseProxy)"
      if ($entry.workflowDispatchSupported -eq $true) {
        throw "Support evidence plan self-test failed: $context should not support host-evidence workflow dispatch."
      }
      if ($entry.localCommandOnly -ne $true) {
        throw "Support evidence plan self-test failed: $context should be marked localCommandOnly."
      }
      if ($null -ne $entry.workflowInputs) {
        throw "Support evidence plan self-test failed: $context should not include workflow inputs."
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$entry.workflowDispatchCommand)) {
        throw "Support evidence plan self-test failed: $context should not include a workflow dispatch command."
      }
      if (([string]$entry.validationCommand).Contains("-RequireHostEvidenceWorkflowCollection")) {
        throw "Support evidence plan self-test failed: $context local-command-only validation command should not require workflow provenance."
      }
      if (-not ([string]$entry.workflowInputSummary).Contains("target category 'bsd'")) {
        throw "Support evidence plan self-test failed: $context is missing BSD local-command-only workflow guidance."
      }
    }
  }
  $dispatchMarkdown = ConvertTo-DispatchMarkdown -Plan $plan
  if (-not $dispatchMarkdown.Contains("gh workflow run")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown is missing gh workflow run commands."
  }
  if (-not $dispatchMarkdown.Contains("Local-Command-Only Evidence")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown is missing local-command-only guidance."
  }
  foreach ($bsdTargetId in @("freebsd", "openbsd", "netbsd")) {
    if ($dispatchMarkdown.Contains("expected_target_id=$bsdTargetId")) {
      throw "Support evidence plan self-test failed: DispatchMarkdown should not emit GitHub workflow commands for $bsdTargetId."
    }
  }
  if (-not $dispatchMarkdown.Contains("--minimum-uptime-hours $requiredMinimumUptimeHours")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown is missing local minimum uptime guidance."
  }
  $dispatchPowerShell = ConvertTo-DispatchPowerShell -Plan $plan -WorkflowFile $WorkflowFile -WorkflowRef $WorkflowRef
  if (-not $dispatchPowerShell.Contains("[switch]`$Run")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell is missing the Run safety switch."
  }
  if (-not $dispatchPowerShell.Contains("`$LocalOnly = @(")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell is missing local-command-only entries."
  }
  if (-not $dispatchPowerShell.Contains("ValidationCommand")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell is missing local validation commands."
  }
  foreach ($bsdTargetId in @("freebsd", "openbsd", "netbsd")) {
    if ($dispatchPowerShell.Contains("expected_target_id=$bsdTargetId")) {
      throw "Support evidence plan self-test failed: DispatchPowerShell should not dispatch $bsdTargetId workflow evidence."
    }
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseInput($dispatchPowerShell, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence plan self-test failed: DispatchPowerShell parse errors: $messages"
  }

  $filteredOutput = Join-Path $RepoRoot ".tmp\support-evidence-plan-filtered-$([Guid]::NewGuid().ToString('N')).json"
  & $PSCommandPath `
    -TargetId windows-11,ubuntu,windows-server-2012 `
    -ProductionRecommendedOnly `
    -FailOnWarnings `
    -Format Json `
    -OutputPath $filteredOutput `
    -Quiet
  $filtered = Get-Content -LiteralPath $filteredOutput -Raw | ConvertFrom-Json
  $filteredSelectedTargets = @($filtered.filters.selectedTargets)
  if ($filteredSelectedTargets.Count -ne 2 -or $filteredSelectedTargets -notcontains "windows-11" -or $filteredSelectedTargets -notcontains "ubuntu") {
    throw "Support evidence plan self-test failed: filtered production plan did not select exactly windows-11 and ubuntu."
  }
  if ($filteredSelectedTargets -contains "windows-server-2012") {
    throw "Support evidence plan self-test failed: production-only plan included experimental windows-server-2012."
  }
  if ($filtered.filters.failOnWarnings -ne $true) {
    throw "Support evidence plan self-test failed: filtered plan did not record failOnWarnings."
  }
  $filteredEntries = @($filtered.strictEvidence) + @($filtered.serviceOnlyEvidence) + @($filtered.fallbackEvidence)
  if ($filteredEntries.Count -lt 1) {
    throw "Support evidence plan self-test failed: filtered plan did not produce evidence entries."
  }
  foreach ($entry in $filteredEntries) {
    if (@("windows-11", "ubuntu") -notcontains [string]$entry.targetId) {
      throw "Support evidence plan self-test failed: filtered plan emitted unexpected target '$($entry.targetId)'."
    }
    $collectionCommand = [string]$entry.collectionCommand
    $validationCommand = [string]$entry.validationCommand
    if ([string]$entry.category -in @("windows-client", "windows-server")) {
      if (-not $collectionCommand.Contains("-FailOnWarnings")) {
        throw "Support evidence plan self-test failed: filtered Windows collection command is missing -FailOnWarnings."
      }
    } else {
      if (-not $collectionCommand.Contains("--fail-on-warnings")) {
        throw "Support evidence plan self-test failed: filtered Unix collection command is missing --fail-on-warnings."
      }
    }
    if (-not $validationCommand.Contains("-FailOnWarnings")) {
      throw "Support evidence plan self-test failed: filtered validation command is missing -FailOnWarnings."
    }
    if ($entry.workflowDispatchSupported -eq $true) {
      if ([string]$entry.workflowInputs.fail_on_warnings -ne "true") {
        throw "Support evidence plan self-test failed: filtered workflow input did not set fail_on_warnings=true."
      }
      if (-not ([string]$entry.workflowDispatchCommand).Contains("fail_on_warnings=true")) {
        throw "Support evidence plan self-test failed: filtered dispatch command is missing fail_on_warnings=true."
      }
    }
  }
}

if (-not $Quiet) {
  Write-Host ""
  Write-Host "==> Support evidence plan"
  Write-Host "Targets: $($plan.summary.targetCount)"
  Write-Host "Strict evidence entries: $($plan.summary.strictEvidenceCount)"
  Write-Host "Service-only evidence entries: $($plan.summary.serviceOnlyEvidenceCount)"
  Write-Host "Fallback evidence entries: $($plan.summary.fallbackEvidenceCount)"
  if ($OutputPath) {
    Write-Host "Wrote support evidence plan: $OutputPath"
  }
}
