param(
  [string]$MatrixPath = "",
  [string]$OutputPath = "",
  [string[]]$TargetId = @(),
  [ValidateSet('Json', 'Markdown', 'DispatchPowerShell')]
  [string]$Format = 'Markdown',
  [string]$WorkflowFile = 'nextjs-host-integration.yml',
  [string]$WorkflowRef = 'main',
  [switch]$ProductionRecommendedOnly,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot 'config\support-matrix.example.json'
}
if (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  (($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  @($Value)
}

function Quote-PowerShellArgument {
  param([string]$Value)
  "'" + ($Value -replace "'", "''") + "'"
}

function Get-RepoRelativePath {
  param([string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoPath = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  $prefix = $repoPath + [System.IO.Path]::DirectorySeparatorChar
  if ($fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($prefix.Length).Replace('\', '/')
  }
  $Path.Replace('\', '/')
}

function Test-ProductionRecommendedTarget {
  param([object]$Target)
  $runtime = $Target.PSObject.Properties['nodeRuntimeSupport']
  if (-not $runtime -or $null -eq $runtime.Value) { return $false }
  $recommended = $runtime.Value.PSObject.Properties['productionRecommended']
  return ($recommended -and $recommended.Value -eq $true)
}

function Get-WorkflowPlatform {
  param([string]$Category)
  if ($Category -in @('windows-client', 'windows-server')) { return 'windows' }
  if ($Category -in @('linux', 'macos')) { return 'unix' }
  return ''
}

function New-DispatchEntry {
  param(
    [object]$Target,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$MatrixRelativePath
  )

  $targetIdValue = Normalize-Token ([string]$Target.id)
  $manager = Normalize-Token $ServiceManager
  $proxy = Normalize-Token $ReverseProxy
  $platform = Get-WorkflowPlatform -Category ([string]$Target.category)
  $inputs = [ordered]@{
    runner_labels = '["self-hosted","' + $targetIdValue + '","nextjs-manager-' + $manager + '","nextjs-proxy-' + $proxy + '"]'
    platform = $platform
    expected_target_id = $targetIdValue
    expected_service_manager = $manager
    expected_reverse_proxy = $proxy
    evidence_name = "$targetIdValue-nextjs-$manager-$proxy"
    matrix_path = $MatrixRelativePath
    upload_retention_days = '14'
  }
  $command = @('gh', 'workflow', 'run', (Quote-PowerShellArgument $WorkflowFile), '--ref', (Quote-PowerShellArgument $WorkflowRef))
  foreach ($name in $inputs.Keys) {
    $command += @('-f', (Quote-PowerShellArgument "$name=$($inputs[$name])"))
  }
  [pscustomobject]@{
    targetId = $targetIdValue
    targetName = [string]$Target.name
    category = [string]$Target.category
    requiredModes = @('standalone', 'next-start')
    serviceManager = $manager
    reverseProxy = $proxy
    nodeRuntimeMinimumNodeVersion = [string]$Target.nodeRuntimeSupport.minimumNodeVersion
    nodeRuntimeSupportTier = [string]$Target.nodeRuntimeSupport.supportTier
    nodeRuntimeProductionRecommended = [bool]$Target.nodeRuntimeSupport.productionRecommended
    workflowInputs = [pscustomobject]$inputs
    workflowDispatchCommand = ($command -join ' ')
  }
}

function ConvertTo-PlanMarkdown {
  param([object]$Plan)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Next.js Self-Hosted Integration Dispatch Plan') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Each dispatch builds a real temporary Next.js application, verifies both standalone and next-start package modes, and exercises one declared primary service-manager and reverse-proxy combination on the exact self-hosted target.') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add("- Target count: $($Plan.summary.targetCount)") | Out-Null
  $lines.Add("- Workflow-capable targets: $($Plan.summary.workflowTargetCount)") | Out-Null
  $lines.Add("- Native integration dispatches: $($Plan.summary.dispatchCount)") | Out-Null
  $lines.Add("- Skipped local-command-only targets: $($Plan.summary.localCommandOnlyTargetCount)") | Out-Null
  $lines.Add('') | Out-Null
  foreach ($entry in @($Plan.dispatches)) {
    $lines.Add("## $($entry.targetId) / $($entry.serviceManager) / $($entry.reverseProxy)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("Both modes: ``standalone``, ``next-start``. Node floor: ``$($entry.nodeRuntimeMinimumNodeVersion)``; tier: ``$($entry.nodeRuntimeSupportTier)``.") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add([string]$entry.workflowDispatchCommand) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add('') | Out-Null
  }
  if (@($Plan.localCommandOnlyTargets).Count -gt 0) {
    $lines.Add('## Local-Command-Only Targets') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add((@($Plan.localCommandOnlyTargets) -join ', ') + '. These targets are intentionally not dispatched through this Windows/Linux/macOS workflow.') | Out-Null
    $lines.Add('') | Out-Null
  }
  ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function ConvertTo-DispatchPowerShell {
  param([object]$Plan)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('param(') | Out-Null
  $lines.Add('  [switch]$Run,') | Out-Null
  $lines.Add('  [string]$RepositoryRoot = (Get-Location).Path') | Out-Null
  $lines.Add(')') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Set-StrictMode -Version Latest') | Out-Null
  $lines.Add('$ErrorActionPreference = ''Stop''') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add("`$WorkflowFile = $(Quote-PowerShellArgument $WorkflowFile)") | Out-Null
  $lines.Add("`$WorkflowRef = $(Quote-PowerShellArgument $WorkflowRef)") | Out-Null
  $lines.Add("`$MatrixPath = $(Quote-PowerShellArgument ([string]$Plan.matrixPath))") | Out-Null
  $lines.Add('$Dispatches = @(') | Out-Null
  foreach ($entry in @($Plan.dispatches)) {
    $lines.Add('  [pscustomobject]@{') | Out-Null
    $lines.Add("    TargetId = $(Quote-PowerShellArgument ([string]$entry.targetId))") | Out-Null
    $lines.Add('    Inputs = [ordered]@{') | Out-Null
    foreach ($name in @('runner_labels', 'platform', 'expected_target_id', 'expected_service_manager', 'expected_reverse_proxy', 'evidence_name', 'matrix_path', 'upload_retention_days')) {
      $lines.Add("      $name = $(Quote-PowerShellArgument ([string]$entry.workflowInputs.$name))") | Out-Null
    }
    $lines.Add('    }') | Out-Null
    $lines.Add('  }') | Out-Null
  }
  $lines.Add(')') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('function Assert-WorkflowSourceReadiness {') | Out-Null
  $lines.Add('  param([string]$RepositoryRoot, [string]$WorkflowRef)') | Out-Null
  $lines.Add('  $changes = @(& git -C $RepositoryRoot status --porcelain)') | Out-Null
  $lines.Add('  if ($LASTEXITCODE -ne 0) { throw ''Unable to inspect the repository worktree before dispatch.'' }') | Out-Null
  $lines.Add('  if ($changes.Count -gt 0) { throw ''Refusing native dispatch from a dirty worktree. Commit the verified workflow changes first.'' }') | Out-Null
  $lines.Add('  $branch = [string](& git -C $RepositoryRoot branch --show-current)') | Out-Null
  $lines.Add('  if ($LASTEXITCODE -ne 0 -or $branch.Trim() -ne $WorkflowRef) { throw "Native dispatch must run from the protected branch $WorkflowRef." }') | Out-Null
  $lines.Add('  $localSha = [string](& git -C $RepositoryRoot rev-parse HEAD)') | Out-Null
  $lines.Add('  if ($LASTEXITCODE -ne 0 -or $localSha.Trim() -notmatch ''^[0-9a-f]{40}$'') { throw ''Unable to resolve the local source commit before dispatch.'' }') | Out-Null
  $lines.Add('  $remoteRef = [string](& git -C $RepositoryRoot ls-remote --heads origin "refs/heads/$WorkflowRef")') | Out-Null
  $lines.Add('  if ($LASTEXITCODE -ne 0 -or $remoteRef -notmatch ''^([0-9a-f]{40})\s+'') { throw "Unable to resolve origin/$WorkflowRef before native dispatch." }') | Out-Null
  $lines.Add('  if ($Matches[1].ToLowerInvariant() -ne $localSha.Trim().ToLowerInvariant()) { throw "origin/$WorkflowRef does not contain the local verified commit. Push it before native dispatch." }') | Out-Null
  $lines.Add('}') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('if ($Run) {') | Out-Null
  $lines.Add('  Assert-WorkflowSourceReadiness -RepositoryRoot $RepositoryRoot -WorkflowRef $WorkflowRef') | Out-Null
  $lines.Add('  $inventoryScript = Join-Path $RepositoryRoot ''scripts\dev\Get-NextJsHostIntegrationRunnerInventory.ps1''') | Out-Null
  $lines.Add('  if (-not (Test-Path -LiteralPath $inventoryScript -PathType Leaf)) { throw "Runner inventory checker was not found: $inventoryScript" }') | Out-Null
  $lines.Add('  $dispatchJson = @($Dispatches | ForEach-Object { [pscustomobject]@{ targetId = $_.TargetId; serviceManager = $_.Inputs.expected_service_manager; reverseProxy = $_.Inputs.expected_reverse_proxy } }) | ConvertTo-Json -Compress') | Out-Null
  $lines.Add('  & $inventoryScript -MatrixPath $MatrixPath -DispatchJson $dispatchJson -FailOnNotReady -Quiet') | Out-Null
  $lines.Add('  if ($LASTEXITCODE -ne 0) { throw ''Self-hosted runner readiness check failed.'' }') | Out-Null
  $lines.Add('}') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('foreach ($dispatch in $Dispatches) {') | Out-Null
  $lines.Add('  if ($Run) {') | Out-Null
  $lines.Add('    $arguments = @(''workflow'', ''run'', $WorkflowFile, ''--ref'', $WorkflowRef)') | Out-Null
  $lines.Add('    foreach ($name in $dispatch.Inputs.Keys) { $arguments += @(''-f'', "$name=$($dispatch.Inputs[$name])") }') | Out-Null
  $lines.Add('    & gh @arguments') | Out-Null
  $lines.Add('    if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch Next.js self-hosted integration workflow." }') | Out-Null
  $lines.Add('  } else {') | Out-Null
  $lines.Add('    $dispatch.TargetId') | Out-Null
  $lines.Add('  }') | Out-Null
  $lines.Add('}') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('if (-not $Run) { Write-Host ''Review runner labels, then rerun with -Run from the repository root to verify runner readiness and dispatch workflows.'' }') | Out-Null
  ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) { throw "Support matrix not found: $MatrixPath" }
& (Join-Path $ScriptDir 'Test-SupportMatrix.ps1') -MatrixPath $MatrixPath | Out-Null
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requestedIds = @($TargetId | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
$allTargets = @(Get-ArrayValue $matrix.targets)
if ($requestedIds.Count -gt 0) {
  $unknown = @($requestedIds | Where-Object { $id = $_; -not @($allTargets | Where-Object { (Normalize-Token ([string]$_.id)) -eq $id }) })
  if ($unknown.Count -gt 0) { throw "Unknown support matrix target id(s): $($unknown -join ', ')" }
}
$selectedTargets = @($allTargets | Where-Object {
    $id = Normalize-Token ([string]$_.id)
    ($requestedIds.Count -eq 0 -or $requestedIds -contains $id) -and
    (-not $ProductionRecommendedOnly -or (Test-ProductionRecommendedTarget -Target $_))
  })
if ($selectedTargets.Count -eq 0) { throw 'No support matrix targets matched the requested integration plan filters.' }

$matrixRelativePath = Get-RepoRelativePath -Path $MatrixPath
$dispatches = New-Object System.Collections.Generic.List[object]
$localCommandOnlyTargets = New-Object System.Collections.Generic.List[string]
$workflowTargetCount = 0
$workflowServiceManagers = @('winsw', 'nssm', 'systemd', 'systemv', 'openrc', 'launchd')
$workflowReverseProxies = @('iis', 'nginx', 'apache', 'haproxy', 'traefik', 'none')
foreach ($target in $selectedTargets) {
  $category = [string]$target.category
  if (-not (Get-WorkflowPlatform -Category $category)) {
    if (-not ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true)) {
      throw "Target '$($target.id)' has unsupported workflow category '$category' but is not marked localCommandOnly."
    }
    $localCommandOnlyTargets.Add((Normalize-Token ([string]$target.id))) | Out-Null
    continue
  }
  if ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true) {
    throw "Target '$($target.id)' is marked localCommandOnly but has workflow-capable category '$category'."
  }
  $workflowTargetCount += 1
  $modes = @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) })
  if (@('standalone', 'next-start') | Where-Object { $modes -notcontains $_ }) {
    throw "Target '$($target.id)' does not declare both required Next.js modes."
  }
  $managers = @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $proxies = @(Get-ArrayValue $target.reverseProxies | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  if ($managers.Count -eq 0 -or $proxies.Count -eq 0) {
    throw "Target '$($target.id)' must declare at least one primary service manager and reverse proxy."
  }
  $unsupportedManagers = @($managers | Where-Object { $_ -notin $workflowServiceManagers })
  if ($unsupportedManagers.Count -gt 0) {
    throw "Target '$($target.id)' declares service managers unavailable to the self-hosted workflow: $($unsupportedManagers -join ', ')."
  }
  $unsupportedProxies = @($proxies | Where-Object { $_ -notin $workflowReverseProxies })
  if ($unsupportedProxies.Count -gt 0) {
    throw "Target '$($target.id)' declares reverse proxies unavailable to the self-hosted workflow: $($unsupportedProxies -join ', ')."
  }
  foreach ($manager in $managers) {
    foreach ($proxy in $proxies) {
      $dispatches.Add((New-DispatchEntry -Target $target -ServiceManager $manager -ReverseProxy $proxy -MatrixRelativePath $matrixRelativePath)) | Out-Null
    }
  }
}
$dispatchArray = @($dispatches | Sort-Object targetId, serviceManager, reverseProxy)
if ($dispatchArray.Count -eq 0) { throw 'Next.js host integration plan has no workflow-dispatch entries.' }

$plan = [pscustomobject]@{
  schemaVersion = 1
  kind = 'nextjs-self-hosted-integration-plan'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  matrixPath = $matrixRelativePath
  filters = [pscustomobject]@{
    targetId = $requestedIds
    productionRecommendedOnly = [bool]$ProductionRecommendedOnly
  }
  summary = [pscustomobject]@{
    targetCount = [int]$selectedTargets.Count
    workflowTargetCount = [int]$workflowTargetCount
    dispatchCount = [int]$dispatchArray.Count
    localCommandOnlyTargetCount = [int]$localCommandOnlyTargets.Count
  }
  dispatches = $dispatchArray
  localCommandOnlyTargets = @($localCommandOnlyTargets | Sort-Object -Unique)
}

if ($SelfTest) {
  $inputValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationWorkflowInputs.ps1'
  foreach ($entry in @($plan.dispatches)) {
    & $inputValidatorPath `
      -MatrixPath $plan.matrixPath `
      -RunnerLabels ([string]$entry.workflowInputs.runner_labels) `
      -Platform ([string]$entry.workflowInputs.platform) `
      -EvidenceName ([string]$entry.workflowInputs.evidence_name) `
      -ExpectedTargetId ([string]$entry.workflowInputs.expected_target_id) `
      -ExpectedServiceManager ([string]$entry.workflowInputs.expected_service_manager) `
      -ExpectedReverseProxy ([string]$entry.workflowInputs.expected_reverse_proxy) `
      -UploadRetentionDays ([string]$entry.workflowInputs.upload_retention_days) `
      -Quiet
  }
  if (@($plan.dispatches | Where-Object { $_.serviceManager -eq 'pm2' }).Count -gt 0) { throw 'Next.js host integration plan self-test failed: fallback manager was emitted.' }
  if (@($plan.dispatches | Where-Object { $_.targetId -in @('freebsd', 'openbsd', 'netbsd') }).Count -gt 0) { throw 'Next.js host integration plan self-test failed: BSD dispatch was emitted.' }
  if ($plan.summary.workflowTargetCount + $plan.summary.localCommandOnlyTargetCount -ne $plan.summary.targetCount) { throw 'Next.js host integration plan self-test failed: target accounting is incomplete.' }
  if (-not (ConvertTo-PlanMarkdown -Plan $plan).Contains('gh workflow run')) { throw 'Next.js host integration plan self-test failed: Markdown output has no dispatch command.' }
  if (-not (ConvertTo-DispatchPowerShell -Plan $plan).Contains('[switch]$Run')) { throw 'Next.js host integration plan self-test failed: PowerShell output has no Run safety switch.' }
}

switch ($Format) {
  'Json' { $content = $plan | ConvertTo-Json -Depth 8 }
  'Markdown' { $content = ConvertTo-PlanMarkdown -Plan $plan }
  'DispatchPowerShell' { $content = ConvertTo-DispatchPowerShell -Plan $plan }
}
if ($OutputPath) {
  $directory = Split-Path -Parent $OutputPath
  if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $content | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} elseif (-not $Quiet) {
  $content
}
if ($SelfTest -and -not $Quiet) { Write-Host 'Next.js host integration plan self-test OK' }
