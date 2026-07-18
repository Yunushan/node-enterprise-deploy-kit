param(
  [string]$Repository = '',
  [string]$MatrixPath = '',
  [string]$RunnerJsonPath = '',
  [string]$OutputPath = '',
  [string[]]$TargetId = @(),
  [string]$DispatchJson = '',
  [ValidateSet('Json', 'Markdown')]
  [string]$Format = 'Markdown',
  [switch]$FailOnMissing,
  [switch]$FailOnNotReady,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

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

function Get-WorkflowPlatform {
  param([string]$Category)
  if ($Category -in @('windows-client', 'windows-server')) { return 'windows' }
  if ($Category -in @('linux', 'macos')) { return 'unix' }
  return ''
}

function Get-RequestedTargetIds {
  param([string[]]$Values)
  @($Values | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-DefaultRepository {
  $remote = @(& git -C $RepoRoot remote get-url origin 2>$null)
  if ($LASTEXITCODE -ne 0 -or $remote.Count -ne 1) {
    throw 'Repository is required when the origin remote cannot be resolved.'
  }
  $value = [string]$remote[0]
  if ($value -match 'github\.com[/:]([^/]+)/([^/.]+)(?:\.git)?$') {
    return "$($Matches[1])/$($Matches[2])"
  }
  throw 'Repository is required when the origin remote is not a GitHub repository URL.'
}

function Assert-RepositoryName {
  param([string]$Value)
  if ($Value -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Repository must use owner/name format.'
  }
}

function Get-RunnerApiRecords {
  param([string]$Repository)
  $raw = & gh api --paginate --slurp "repos/$Repository/actions/runners?per_page=100"
  if ($LASTEXITCODE -ne 0) { throw 'Unable to query GitHub Actions self-hosted runner inventory.' }
  @($raw | ConvertFrom-Json)
}

function Get-RunnerRecordsFromJson {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Runner JSON fixture was not found: $Path"
  }
  $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ($value -is [System.Array]) { return @($value) }
  return @($value)
}

function Get-RedactedRunnerRecords {
  param([object[]]$ApiPages)
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($page in @(Get-ArrayValue $ApiPages)) {
    foreach ($runner in @(Get-ArrayValue $page.runners)) {
      $labels = @($runner.labels | ForEach-Object { Normalize-Token ([string]$_.name) } | Where-Object { $_ } | Sort-Object -Unique)
      if ($labels.Count -eq 0) { continue }
      $records.Add([pscustomobject]@{
          status = Normalize-Token ([string]$runner.status)
          busy = [bool]$runner.busy
          labels = $labels
        }) | Out-Null
    }
  }
  $records.ToArray()
}

function New-TargetInventory {
  param([object]$Matrix, [object[]]$Runners, [string[]]$RequestedTargetIds = @())
  $targets = New-Object System.Collections.Generic.List[object]
  $availableRunners = @($Runners | Where-Object { $null -ne $_ })
  $targetFilter = @($RequestedTargetIds | Where-Object { $_ })
  foreach ($target in @($Matrix.targets)) {
    $targetId = Normalize-Token ([string]$target.id)
    if ($targetFilter.Count -gt 0 -and $targetFilter -notcontains $targetId) {
      continue
    }
    $platform = Get-WorkflowPlatform ([string]$target.category)
    if (-not $platform -or ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true)) {
      continue
    }
    $matching = @($availableRunners | Where-Object { $_.labels -contains 'self-hosted' -and $_.labels -contains $targetId })
    $online = @($matching | Where-Object { $_.status -eq 'online' })
    $idle = @($online | Where-Object { -not $_.busy })
    $targets.Add([pscustomobject]@{
        targetId = $targetId
        platform = $platform
        configuredRunnerCount = $matching.Count
        onlineRunnerCount = $online.Count
        idleRunnerCount = $idle.Count
        readyForDispatch = $idle.Count -gt 0
      }) | Out-Null
  }
  @($targets | Sort-Object targetId)
}

function Get-DispatchRequestsFromJson {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  try {
    $parsed = $Value | ConvertFrom-Json
  } catch {
    throw 'DispatchJson must be a JSON array of targetId, serviceManager, and reverseProxy records.'
  }
  $records = @($parsed)
  if ($records.Count -eq 0) {
    throw 'DispatchJson must contain at least one dispatch record when provided.'
  }
  $normalized = New-Object System.Collections.Generic.List[object]
  foreach ($record in $records) {
    $targetId = Normalize-Token ([string]$record.targetId)
    $manager = Normalize-Token ([string]$record.serviceManager)
    $proxy = Normalize-Token ([string]$record.reverseProxy)
    if (-not $targetId -or -not $manager -or -not $proxy) {
      throw 'DispatchJson records must contain targetId, serviceManager, and reverseProxy.'
    }
    $normalized.Add([pscustomobject]@{ targetId = $targetId; serviceManager = $manager; reverseProxy = $proxy }) | Out-Null
  }
  @($normalized | Sort-Object targetId, serviceManager, reverseProxy -Unique)
}

function New-DispatchInventory {
  param([object]$Matrix, [object[]]$Runners, [object[]]$Dispatches)
  $records = New-Object System.Collections.Generic.List[object]
  $availableRunners = @($Runners | Where-Object { $null -ne $_ })
  foreach ($dispatch in @($Dispatches)) {
    $target = @($Matrix.targets | Where-Object { (Normalize-Token ([string]$_.id)) -eq $dispatch.targetId })
    if ($target.Count -ne 1) { throw "Dispatch target '$($dispatch.targetId)' is not declared in the support matrix." }
    $target = $target[0]
    if (-not (Get-WorkflowPlatform ([string]$target.category)) -or ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true)) {
      throw "Dispatch target '$($dispatch.targetId)' is not workflow-capable."
    }
    if (@($target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) }) -notcontains $dispatch.serviceManager) {
      throw "Dispatch manager '$($dispatch.serviceManager)' is not declared for target '$($dispatch.targetId)'."
    }
    if (@($target.reverseProxies | ForEach-Object { Normalize-Token ([string]$_) }) -notcontains $dispatch.reverseProxy) {
      throw "Dispatch proxy '$($dispatch.reverseProxy)' is not declared for target '$($dispatch.targetId)'."
    }
    $requiredLabels = @('self-hosted', $dispatch.targetId, "nextjs-manager-$($dispatch.serviceManager)", "nextjs-proxy-$($dispatch.reverseProxy)")
    $matching = @($availableRunners | Where-Object { $runner = $_; @($requiredLabels | Where-Object { $runner.labels -notcontains $_ }).Count -eq 0 })
    $online = @($matching | Where-Object { $_.status -eq 'online' })
    $idle = @($online | Where-Object { -not $_.busy })
    $records.Add([pscustomobject]@{
        targetId = $dispatch.targetId
        serviceManager = $dispatch.serviceManager
        reverseProxy = $dispatch.reverseProxy
        requiredLabels = $requiredLabels
        configuredRunnerCount = $matching.Count
        onlineRunnerCount = $online.Count
        idleRunnerCount = $idle.Count
        readyForDispatch = $idle.Count -gt 0
      }) | Out-Null
  }
  @($records | Sort-Object targetId, serviceManager, reverseProxy)
}

function New-InventoryReport {
  param([object]$Matrix, [object[]]$Runners, [string]$Repository, [string[]]$RequestedTargetIds = @(), [object[]]$Dispatches = @())
  $targets = @(New-TargetInventory -Matrix $Matrix -Runners $Runners -RequestedTargetIds $RequestedTargetIds)
  $dispatchRecords = @(New-DispatchInventory -Matrix $Matrix -Runners $Runners -Dispatches $Dispatches)
  [pscustomobject]@{
    schemaVersion = 1
    kind = 'nextjs-self-hosted-runner-inventory'
    repository = $Repository
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    summary = [pscustomobject]@{
      workflowTargetCount = $targets.Count
      configuredTargetCount = @($targets | Where-Object { $_.configuredRunnerCount -gt 0 }).Count
      onlineTargetCount = @($targets | Where-Object { $_.onlineRunnerCount -gt 0 }).Count
      readyTargetCount = @($targets | Where-Object { $_.readyForDispatch }).Count
      missingTargetCount = @($targets | Where-Object { $_.configuredRunnerCount -eq 0 }).Count
      dispatchCount = $dispatchRecords.Count
      configuredDispatchCount = @($dispatchRecords | Where-Object { $_.configuredRunnerCount -gt 0 }).Count
      onlineDispatchCount = @($dispatchRecords | Where-Object { $_.onlineRunnerCount -gt 0 }).Count
      readyDispatchCount = @($dispatchRecords | Where-Object { $_.readyForDispatch }).Count
      missingDispatchCount = @($dispatchRecords | Where-Object { $_.configuredRunnerCount -eq 0 }).Count
    }
    targets = $targets
    dispatches = $dispatchRecords
  }
}

function ConvertTo-InventoryMarkdown {
  param([object]$Report)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Next.js Self-Hosted Runner Inventory') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add("Repository: $($Report.repository)") | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add("- Workflow-capable targets: $($Report.summary.workflowTargetCount)") | Out-Null
  $lines.Add("- Targets with configured runners: $($Report.summary.configuredTargetCount)") | Out-Null
  $lines.Add("- Targets with online runners: $($Report.summary.onlineTargetCount)") | Out-Null
  $lines.Add("- Targets ready for dispatch: $($Report.summary.readyTargetCount)") | Out-Null
  $lines.Add("- Targets without a configured runner: $($Report.summary.missingTargetCount)") | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('| Target | Platform | Configured | Online | Idle | Dispatch readiness |') | Out-Null
  $lines.Add('|---|---|---:|---:|---:|---|') | Out-Null
  foreach ($target in @($Report.targets)) {
    $state = if ($target.readyForDispatch) { 'ready' } elseif ($target.onlineRunnerCount -gt 0) { 'busy' } elseif ($target.configuredRunnerCount -gt 0) { 'offline' } else { 'missing' }
    $lines.Add("| $($target.targetId) | $($target.platform) | $($target.configuredRunnerCount) | $($target.onlineRunnerCount) | $($target.idleRunnerCount) | $state |") | Out-Null
  }
  if (@($Report.dispatches).Count -gt 0) {
    $lines.Add('') | Out-Null
    $lines.Add('| Target | Service | Proxy | Configured | Online | Idle | Dispatch readiness |') | Out-Null
    $lines.Add('|---|---|---|---:|---:|---:|---|') | Out-Null
    foreach ($dispatch in @($Report.dispatches)) {
      $state = if ($dispatch.readyForDispatch) { 'ready' } elseif ($dispatch.onlineRunnerCount -gt 0) { 'busy' } elseif ($dispatch.configuredRunnerCount -gt 0) { 'offline' } else { 'missing' }
      $lines.Add("| $($dispatch.targetId) | $($dispatch.serviceManager) | $($dispatch.reverseProxy) | $($dispatch.configuredRunnerCount) | $($dispatch.onlineRunnerCount) | $($dispatch.idleRunnerCount) | $state |") | Out-Null
    }
  }
  ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Invoke-SelfTest {
  $matrix = [pscustomobject]@{
    targets = @(
      [pscustomobject]@{ id = 'ubuntu'; category = 'linux'; localCommandOnly = $false; serviceManagers = @('systemd'); reverseProxies = @('nginx') },
      [pscustomobject]@{ id = 'windows-server-2022'; category = 'windows-server'; localCommandOnly = $false; serviceManagers = @('winsw'); reverseProxies = @('iis') },
      [pscustomobject]@{ id = 'macos'; category = 'macos'; localCommandOnly = $false; serviceManagers = @('launchd'); reverseProxies = @('apache') },
      [pscustomobject]@{ id = 'freebsd'; category = 'freebsd'; localCommandOnly = $true; serviceManagers = @('bsdrc'); reverseProxies = @('nginx') }
    )
  }
  $pages = @([pscustomobject]@{
      runners = @(
        [pscustomobject]@{ name = 'sensitive-host-name'; status = 'online'; busy = $false; labels = @([pscustomobject]@{ name = 'self-hosted' }, [pscustomobject]@{ name = 'ubuntu' }, [pscustomobject]@{ name = 'nextjs-manager-systemd' }, [pscustomobject]@{ name = 'nextjs-proxy-nginx' }) },
        [pscustomobject]@{ name = 'another-sensitive-name'; status = 'online'; busy = $true; labels = @([pscustomobject]@{ name = 'self-hosted' }, [pscustomobject]@{ name = 'windows-server-2022' }, [pscustomobject]@{ name = 'nextjs-manager-winsw' }, [pscustomobject]@{ name = 'nextjs-proxy-iis' }) }
      )
    })
  $report = New-InventoryReport -Matrix $matrix -Runners (Get-RedactedRunnerRecords -ApiPages $pages) -Repository 'owner/repository'
  if ($report.summary.workflowTargetCount -ne 3 -or $report.summary.readyTargetCount -ne 1 -or $report.summary.missingTargetCount -ne 1) {
    throw 'Runner inventory self-test produced an unexpected target summary.'
  }
  $markdown = ConvertTo-InventoryMarkdown -Report $report
  if ($markdown.Contains('sensitive-host-name') -or $markdown.Contains('another-sensitive-name')) {
    throw 'Runner inventory self-test leaked a runner name.'
  }
  if (-not $markdown.Contains('| ubuntu | unix | 1 | 1 | 1 | ready |')) {
    throw 'Runner inventory self-test did not mark the idle Ubuntu runner as ready.'
  }
  if (-not $markdown.Contains('| windows-server-2022 | windows | 1 | 1 | 0 | busy |')) {
    throw 'Runner inventory self-test did not mark the busy Windows runner as busy.'
  }
  $emptyReport = New-InventoryReport -Matrix $matrix -Runners @() -Repository 'owner/repository'
  if ($emptyReport.summary.configuredTargetCount -ne 0 -or $emptyReport.summary.missingTargetCount -ne 3) {
    throw 'Runner inventory self-test did not handle an empty runner inventory.'
  }
  $filteredReport = New-InventoryReport -Matrix $matrix -Runners (Get-RedactedRunnerRecords -ApiPages $pages) -Repository 'owner/repository' -RequestedTargetIds @('ubuntu')
  if ($filteredReport.summary.workflowTargetCount -ne 1 -or $filteredReport.targets[0].targetId -ne 'ubuntu') {
    throw 'Runner inventory self-test did not apply the target filter.'
  }
  $nullFilterReport = New-InventoryReport -Matrix $matrix -Runners (Get-RedactedRunnerRecords -ApiPages $pages) -Repository 'owner/repository' -RequestedTargetIds $null
  if ($nullFilterReport.summary.workflowTargetCount -ne 3) {
    throw 'Runner inventory self-test did not handle an omitted target filter.'
  }
  $dispatches = @(
    [pscustomobject]@{ targetId = 'ubuntu'; serviceManager = 'systemd'; reverseProxy = 'nginx' },
    [pscustomobject]@{ targetId = 'windows-server-2022'; serviceManager = 'winsw'; reverseProxy = 'iis' }
  )
  $dispatchReport = New-InventoryReport -Matrix $matrix -Runners (Get-RedactedRunnerRecords -ApiPages $pages) -Repository 'owner/repository' -Dispatches $dispatches
  if ($dispatchReport.summary.dispatchCount -ne 2 -or $dispatchReport.summary.readyDispatchCount -ne 1 -or $dispatchReport.summary.missingDispatchCount -ne 0 -or $dispatchReport.dispatches[1].readyForDispatch -ne $false) {
    throw 'Runner inventory self-test did not evaluate dispatch capability labels.'
  }
  Write-Host 'Next.js self-hosted runner inventory self-test OK'
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot 'config\support-matrix.example.json'
} elseif (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix was not found: $MatrixPath"
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
  $Repository = Get-DefaultRepository
}
Assert-RepositoryName -Value $Repository

$pages = if ([string]::IsNullOrWhiteSpace($RunnerJsonPath)) {
  Get-RunnerApiRecords -Repository $Repository
} else {
  Get-RunnerRecordsFromJson -Path $RunnerJsonPath
}
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requestedTargetIds = @(Get-RequestedTargetIds -Values $TargetId)
$knownTargetIds = @($matrix.targets | ForEach-Object { Normalize-Token ([string]$_.id) } | Where-Object { $_ } | Sort-Object -Unique)
$unknownTargetIds = @($requestedTargetIds | Where-Object { $_ -notin $knownTargetIds })
if ($unknownTargetIds.Count -gt 0) {
  throw "Unknown support matrix target id(s): $($unknownTargetIds -join ', ')"
}
$dispatches = @(Get-DispatchRequestsFromJson -Value $DispatchJson)
if ($requestedTargetIds.Count -gt 0 -and $dispatches.Count -gt 0) {
  throw 'TargetId and DispatchJson cannot be combined in one runner inventory request.'
}
$report = New-InventoryReport -Matrix $matrix -Runners (Get-RedactedRunnerRecords -ApiPages $pages) -Repository $Repository -RequestedTargetIds $requestedTargetIds -Dispatches $dispatches
$output = if ($Format -eq 'Json') { $report | ConvertTo-Json -Depth 8 } else { ConvertTo-InventoryMarkdown -Report $report }
if ($OutputPath) {
  $resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $RepoRoot $OutputPath }
  $parent = Split-Path -Parent $resolvedOutputPath
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Set-Content -LiteralPath $resolvedOutputPath -Value $output -NoNewline
  if (-not $Quiet) { Write-Host "Next.js self-hosted runner inventory written: $resolvedOutputPath" }
} elseif (-not $Quiet) {
  Write-Output $output
}
if ($FailOnMissing) {
  if ($report.summary.dispatchCount -gt 0 -and $report.summary.missingDispatchCount -gt 0) {
    $missing = @($report.dispatches | Where-Object { $_.configuredRunnerCount -eq 0 } | ForEach-Object { "$($_.targetId)/$($_.serviceManager)/$($_.reverseProxy)" })
    throw "Self-hosted runner inventory is missing runner capability label(s) for dispatch(es): $($missing -join ', ')."
  }
  if ($report.summary.dispatchCount -eq 0 -and $report.summary.missingTargetCount -gt 0) {
    throw "Self-hosted runner inventory is missing $($report.summary.missingTargetCount) workflow-capable target label(s)."
  }
}
if ($FailOnNotReady) {
  if ($report.summary.dispatchCount -gt 0 -and $report.summary.readyDispatchCount -lt $report.summary.dispatchCount) {
    $notReady = @($report.dispatches | Where-Object { -not $_.readyForDispatch } | ForEach-Object { "$($_.targetId)/$($_.serviceManager)/$($_.reverseProxy)" })
    throw "Self-hosted runner inventory has no online, idle compatible runner for dispatch(es): $($notReady -join ', ')."
  }
  if ($report.summary.dispatchCount -eq 0 -and $report.summary.readyTargetCount -lt $report.summary.workflowTargetCount) {
    $notReady = @($report.targets | Where-Object { -not $_.readyForDispatch } | ForEach-Object { $_.targetId })
    throw "Self-hosted runner inventory has no online, idle runner for target label(s): $($notReady -join ', ')."
  }
}
