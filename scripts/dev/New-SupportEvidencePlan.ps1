param(
  [string]$MatrixPath = "",
  [string]$OutputPath = "",
  [ValidateSet("Json", "Markdown", "Csv", "DispatchMarkdown", "DispatchPowerShell")]
  [string]$Format = "Markdown",
  [string]$WorkflowFile = "host-evidence.yml",
  [string]$WorkflowRef = "main",
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
    [string]$EvidenceFile
  )
  if ($Category -in @("windows-client", "windows-server")) {
    $windowsPath = $EvidenceFile.Replace("/", "\")
    return ".\status.ps1 -ConfigPath .\config\windows\app.config.json -JsonPath .\$windowsPath -FailOnCritical"
  }
  return "sudo bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./$EvidenceFile --fail-on-critical"
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
    [string]$Notes
  )

  $targetId = Normalize-Token ([string]$Target.id)
  $modeValue = Normalize-Token $Mode
  $serviceManagerValue = Normalize-Token $ServiceManager
  $reverseProxyValue = Normalize-Token $ReverseProxy
  $evidenceFile = Get-EvidenceFile -TargetId $targetId -Mode $modeValue -ServiceManager $serviceManagerValue -ReverseProxy $reverseProxyValue -Kind $Kind
  $category = [string]$Target.category
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
      minimum_uptime_hours = "72"
      require_reverse_proxy = "true"
      fail_on_warnings = "false"
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
    evidenceFile = $evidenceFile
    collectionCommand = Get-CollectionCommand -Category $category -EvidenceFile $evidenceFile
    workflowDispatchSupported = $workflowDispatchSupported
    workflowInputs = $workflowInputs
    workflowInputSummary = $workflowInputSummary
    workflowDispatchCommand = $workflowDispatchCommand
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
  $lines.Add("") | Out-Null
  $lines.Add('Strict entries are the combinations enforced by `Test-SupportClaim.ps1 -RequireBothNextJsModes -RequireDeclaredServiceManagers -RequireDeclaredReverseProxies`.') | Out-Null
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
    $lines.Add("| Target | Mode | Service | Proxy | Evidence file | Collection command | Workflow route |") | Out-Null
    $lines.Add("|---|---|---|---|---|---|---|") | Out-Null
    foreach ($item in $items) {
      $targetCell = ([string]$item.targetId).Replace("|", "\|")
      $modeCell = ([string]$item.nextJsMode).Replace("|", "\|")
      $serviceCell = ([string]$item.serviceManager).Replace("|", "\|")
      $proxyCell = ([string]$item.reverseProxy).Replace("|", "\|")
      $fileCell = ([string]$item.evidenceFile).Replace("|", "\|")
      $commandCell = ([string]$item.collectionCommand).Replace("|", "\|")
      $workflowCell = ([string]$item.workflowInputSummary).Replace("|", "\|")
      $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` |' -f $targetCell, $modeCell, $serviceCell, $proxyCell, $fileCell, $commandCell, $workflowCell)) | Out-Null
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
    $lines.Add("| Target | Mode | Service | Proxy | Collection command |") | Out-Null
    $lines.Add("|---|---|---|---|---|") | Out-Null
    foreach ($item in $localOnlyItems) {
      $targetCell = ([string]$item.targetId).Replace("|", "\|")
      $modeCell = ([string]$item.nextJsMode).Replace("|", "\|")
      $serviceCell = ([string]$item.serviceManager).Replace("|", "\|")
      $proxyCell = ([string]$item.reverseProxy).Replace("|", "\|")
      $commandCell = ([string]$item.collectionCommand).Replace("|", "\|")
      $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` |' -f $targetCell, $modeCell, $serviceCell, $proxyCell, $commandCell)) | Out-Null
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
  $lines.Add("    `$LocalOnly | Format-Table Kind, TargetId, NextJsMode, ServiceManager, ReverseProxy, CollectionCommand -AutoSize") | Out-Null
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
$targets = @(Get-ArrayValue $matrix.targets)
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
        $strictEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "strict" -Notes "Strict real-host evidence.")) | Out-Null
      }
      foreach ($proxy in $serviceOnlyMarkers) {
        $serviceOnlyEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "service-only" -Notes "Service-only or external load-balancer evidence.")) | Out-Null
      }
    }
    foreach ($fallbackManager in $fallbackManagers) {
      foreach ($proxy in $concreteProxies) {
        $fallbackEvidence.Add((New-PlanEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback" -Notes "Compatibility fallback evidence; not a strict service-manager claim.")) | Out-Null
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
  if ([int]$parsed.summary.strictEvidenceCount -ne @($parsed.strictEvidence).Count) {
    throw "Support evidence plan self-test failed: strictEvidenceCount does not match strictEvidence."
  }
  $firstStrict = @($parsed.strictEvidence)[0]
  if ($firstStrict.workflowDispatchSupported -ne $true) {
    throw "Support evidence plan self-test failed: first strict evidence entry should support workflow dispatch."
  }
  if (-not $firstStrict.PSObject.Properties["workflowInputs"]) {
    throw "Support evidence plan self-test failed: workflowInputs missing from strict evidence entry."
  }
  if ($firstStrict.workflowInputs.expected_target_id -ne $firstStrict.targetId) {
    throw "Support evidence plan self-test failed: expected_target_id does not match targetId."
  }
  if ($firstStrict.workflowInputs.expected_nextjs_mode -ne $firstStrict.nextJsMode) {
    throw "Support evidence plan self-test failed: expected_nextjs_mode does not match nextJsMode."
  }
  if ($firstStrict.workflowInputs.expected_service_manager -ne $firstStrict.serviceManager) {
    throw "Support evidence plan self-test failed: expected_service_manager does not match serviceManager."
  }
  if ($firstStrict.workflowInputs.expected_reverse_proxy -ne $firstStrict.reverseProxy) {
    throw "Support evidence plan self-test failed: expected_reverse_proxy does not match reverseProxy."
  }
  if (-not ([string]$firstStrict.workflowDispatchCommand).Contains("gh workflow run")) {
    throw "Support evidence plan self-test failed: workflowDispatchCommand is missing gh workflow run."
  }
  if (-not ([string]$firstStrict.workflowDispatchCommand).Contains("expected_target_id=$($firstStrict.targetId)")) {
    throw "Support evidence plan self-test failed: workflowDispatchCommand is missing expected_target_id."
  }
  $planMarkdown = ConvertTo-PlanMarkdown -Plan $plan
  if ($planMarkdown.Contains('$targetCell') -or $planMarkdown.Contains('$workflowCell')) {
    throw "Support evidence plan self-test failed: Markdown output contains unexpanded table placeholders."
  }
  if (-not $planMarkdown.Contains("Collection command")) {
    throw "Support evidence plan self-test failed: Markdown output is missing collection command guidance."
  }
  $localOnlyStrict = @($parsed.strictEvidence | Where-Object { $_.workflowDispatchSupported -ne $true })
  if ($localOnlyStrict.Count -lt 1) {
    throw "Support evidence plan self-test failed: expected at least one local-command-only strict evidence entry."
  }
  if (@($localOnlyStrict | Where-Object { $_.targetId -eq "freebsd" }).Count -lt 1) {
    throw "Support evidence plan self-test failed: FreeBSD should be a local-command-only evidence target."
  }
  $dispatchMarkdown = ConvertTo-DispatchMarkdown -Plan $plan
  if (-not $dispatchMarkdown.Contains("gh workflow run")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown is missing gh workflow run commands."
  }
  if (-not $dispatchMarkdown.Contains("Local-Command-Only Evidence")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown is missing local-command-only guidance."
  }
  if ($dispatchMarkdown.Contains("expected_target_id=freebsd")) {
    throw "Support evidence plan self-test failed: DispatchMarkdown should not emit GitHub workflow commands for FreeBSD."
  }
  $dispatchPowerShell = ConvertTo-DispatchPowerShell -Plan $plan -WorkflowFile $WorkflowFile -WorkflowRef $WorkflowRef
  if (-not $dispatchPowerShell.Contains("[switch]`$Run")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell is missing the Run safety switch."
  }
  if (-not $dispatchPowerShell.Contains("`$LocalOnly = @(")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell is missing local-command-only entries."
  }
  if ($dispatchPowerShell.Contains("expected_target_id=freebsd")) {
    throw "Support evidence plan self-test failed: DispatchPowerShell should not dispatch FreeBSD workflow evidence."
  }
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseInput($dispatchPowerShell, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join "; "
    throw "Support evidence plan self-test failed: DispatchPowerShell parse errors: $messages"
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
