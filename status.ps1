<#
.SYNOPSIS
  Show safe Windows service, process, port, and health status.
.DESCRIPTION
  This script avoids printing environment variables, config Environment values,
  credentials, request bodies, or log contents. It reports only operational
  metadata needed to confirm whether the app is running.
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [int] $MinimumUptimeHours = 0,
    [int] $HealthTimeoutSeconds = 0,
    [switch] $FailOnCritical
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$serviceName = [string]$config.AppName
$escapedServiceName = $serviceName.Replace("'", "''")
$configuredPort = [int]$config.Port
$healthUrl = [string]$config.HealthUrl
$script:findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param(
        [ValidateSet("Critical", "Warning", "Info")] [string] $Severity,
        [string] $Message
    )
    $script:findings.Add([pscustomobject]@{
        Severity = $Severity
        Message = $Message
    }) | Out-Null
}

function Get-ChildProcessTree {
    param([int] $ParentProcessId)

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byParent = @{}
    foreach ($process in $all) {
        $parentId = [int]$process.ParentProcessId
        if (-not $byParent.ContainsKey($parentId)) {
            $byParent[$parentId] = New-Object System.Collections.Generic.List[object]
        }
        $byParent[$parentId].Add($process) | Out-Null
    }

    $result = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($ParentProcessId)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $byParent.ContainsKey($current)) { continue }
        foreach ($child in $byParent[$current]) {
            $result.Add($child) | Out-Null
            if ($child.ProcessId) { $queue.Enqueue([int]$child.ProcessId) }
        }
    }

    return @($result)
}

function Format-Uptime {
    param($StartTime)
    if (-not $StartTime) { return "" }
    try {
        $span = (Get-Date) - $StartTime
        return "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
    } catch {
        return ""
    }
}
function Format-OptionalUtc {
    param($Value)
    if (-not $Value) { return "" }
    try {
        return ([DateTime]::Parse([string]$Value).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return [string]$Value
    }
}
function Get-ConfigInt($Config, [string]$Name, [int]$Default) {
    if ($Config.PSObject.Properties[$Name] -and $Config.$Name) {
        try { return [int]$Config.$Name } catch {}
    }
    return $Default
}
function Get-WorstFindingSeverity {
    if (@($script:findings | Where-Object { $_.Severity -eq "Critical" }).Count -gt 0) { return "Critical" }
    if (@($script:findings | Where-Object { $_.Severity -eq "Warning" }).Count -gt 0) { return "Warning" }
    return "Healthy"
}
function Test-AllOwnersMatch {
    param(
        [int[]] $OwnerProcessIds,
        [int[]] $ExpectedProcessIds
    )
    if ($OwnerProcessIds.Count -eq 0 -or $ExpectedProcessIds.Count -eq 0) { return $false }
    $mismatches = @($OwnerProcessIds | Where-Object { $ExpectedProcessIds -notcontains $_ })
    return ($mismatches.Count -eq 0)
}
function Get-DateTimeFromStateValue($Value) {
    if (-not $Value) { return $null }
    try {
        return [DateTime]::Parse([string]$Value).ToLocalTime()
    } catch {
        return $null
    }
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return (Join-Path $Config.ServiceDirectory "backups")
    }
    return ""
}
function Get-HealthLogSummary([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $lines = @(Get-Content -Path $Path -Tail 2000 -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Path = $Path
        LastWriteTime = (Get-Item $Path).LastWriteTime
        LinesSampled = $lines.Count
        Ok = @($lines | Where-Object { $_ -match '\sOK\s' }).Count
        Failed = @($lines | Where-Object { $_ -match '\sFAILED|FAILED_THRESHOLD|EXCEPTION|BAD_STATUS|SERVICE_NOT_RUNNING' }).Count
        Restarted = @($lines | Where-Object { $_ -match 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' }).Count
        RestartSuppressed = @($lines | Where-Object { $_ -match 'RESTART_SUPPRESSED_COOLDOWN' }).Count
        RetentionRemoved = @($lines | Where-Object { $_ -match 'RETENTION_REMOVED' }).Count
    }
}

Write-Host "Status for: $serviceName" -ForegroundColor Cyan
Write-Host "Config: $ConfigPath"
Write-Host ""

$healthIntervalMinutes = Get-ConfigInt $config "HealthCheckIntervalMinutes" 1
$failureThreshold = Get-ConfigInt $config "HealthCheckFailureThreshold" 2
if ($HealthTimeoutSeconds -lt 1) {
    $HealthTimeoutSeconds = Get-ConfigInt $config "HealthCheckTimeoutSeconds" 10
}

Write-Host "Host uptime" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os -and $os.LastBootUpTime) {
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        LastBootUpTime = $os.LastBootUpTime
        Uptime = Format-Uptime $os.LastBootUpTime
    } | Format-Table -AutoSize
} else {
    Add-Finding -Severity Warning -Message "Could not read host boot time from Win32_OperatingSystem."
    Write-Warning "Could not read host boot time."
}

Write-Host "Service" -ForegroundColor Yellow
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    $service | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
    if ($service.Status -ne "Running") {
        Add-Finding -Severity Critical -Message "Service '$serviceName' is $($service.Status), not Running."
    }
    if ($service.StartType -ne "Automatic") {
        Add-Finding -Severity Warning -Message "Service '$serviceName' StartType is $($service.StartType), not Automatic."
    }
} else {
    Add-Finding -Severity Critical -Message "Service '$serviceName' was not found."
    Write-Warning "Service not found: $serviceName"
}

$serviceProcess = Get-CimInstance Win32_Service -Filter "Name='$escapedServiceName'" -ErrorAction SilentlyContinue
if ($serviceProcess) {
    $serviceProcess | Select-Object Name, State, StartMode, ProcessId | Format-Table -AutoSize
    if ($serviceProcess.StartMode -ne "Auto") {
        Add-Finding -Severity Warning -Message "Win32 service StartMode is $($serviceProcess.StartMode), not Auto."
    }
    if ($serviceProcess.State -eq "Running" -and (-not $serviceProcess.ProcessId -or $serviceProcess.ProcessId -lt 1)) {
        Add-Finding -Severity Critical -Message "Service reports Running but has no process ID."
    }
}

$serviceProcessIds = @()
if ($serviceProcess -and $serviceProcess.ProcessId -and $serviceProcess.ProcessId -gt 0) {
    $serviceProcessIds += [int]$serviceProcess.ProcessId
    $wrapper = Get-Process -Id $serviceProcess.ProcessId -ErrorAction SilentlyContinue
    if ($wrapper) {
        Write-Host ""
        Write-Host "Service wrapper uptime" -ForegroundColor Yellow
        $wrapper |
            Select-Object Id, StartTime, @{Name="Uptime";Expression={ Format-Uptime $_.StartTime }}, Path |
            Format-Table -AutoSize
        if ($MinimumUptimeHours -gt 0) {
            $uptimeHours = ((Get-Date) - $wrapper.StartTime).TotalHours
            if ($uptimeHours -lt $MinimumUptimeHours) {
                Add-Finding -Severity Warning -Message ("Service wrapper uptime is {0:N1} hours, below requested minimum of {1} hours." -f $uptimeHours, $MinimumUptimeHours)
            }
        }
    } else {
        Add-Finding -Severity Critical -Message "Service process ID $($serviceProcess.ProcessId) was reported by SCM but the process was not found."
    }

    $children = Get-ChildProcessTree -ParentProcessId ([int]$serviceProcess.ProcessId)
    if ($children.Count -gt 0) {
        $serviceProcessIds += @($children | Select-Object -ExpandProperty ProcessId)
        Write-Host ""
        Write-Host "Service process tree" -ForegroundColor Yellow
        $children |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath |
            Format-Table -AutoSize
    }
}

Write-Host ""
Write-Host "Node processes" -ForegroundColor Yellow
$nodeProcesses = Get-Process node -ErrorAction SilentlyContinue
if ($nodeProcesses) {
    $nodeProcesses |
        Select-Object Id, StartTime, @{Name="Uptime";Expression={ Format-Uptime $_.StartTime }}, Path |
        Format-Table -AutoSize
} else {
    Add-Finding -Severity Warning -Message "No node.exe process was found."
    Write-Warning "No node.exe process found."
}

$serviceProcessIds = @($serviceProcessIds | Where-Object { $_ } | Sort-Object -Unique)
if ($nodeProcesses -and $serviceProcessIds.Count -gt 0) {
    $ownedNodeProcesses = @($nodeProcesses | Where-Object { $serviceProcessIds -contains $_.Id })
    if ($ownedNodeProcesses.Count -eq 0) {
        Add-Finding -Severity Warning -Message "node.exe is running, but no node.exe process is in the configured service process tree."
    }
}

Write-Host ""
Write-Host "Configured port listener" -ForegroundColor Yellow
$portConnections = Get-NetTCPConnection -LocalPort $configuredPort -State Listen -ErrorAction SilentlyContinue
if ($portConnections) {
    $portConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    $configuredPortOwnerIds = @($portConnections | Select-Object -ExpandProperty OwningProcess -Unique)
    if (Test-AllOwnersMatch -OwnerProcessIds $configuredPortOwnerIds -ExpectedProcessIds $serviceProcessIds) {
        Write-Host "Configured port $configuredPort is owned by the configured service process tree." -ForegroundColor Green
    } else {
        Add-Finding -Severity Critical -Message "Configured port $configuredPort is listening, but owner process ID(s) $($configuredPortOwnerIds -join ', ') do not all belong to the configured service process tree."
    }
} else {
    Add-Finding -Severity Critical -Message "No listener was found on configured port $configuredPort."
    Write-Warning "No listener found on configured port $configuredPort."
}

Write-Host ""
Write-Host "Listeners owned by configured service" -ForegroundColor Yellow
if ($serviceProcessIds.Count -gt 0) {
    $ownedConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $serviceProcessIds -contains $_.OwningProcess }
    if ($ownedConnections) {
        $ownedConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    } else {
        Add-Finding -Severity Warning -Message "No listening sockets were found for configured service process IDs: $($serviceProcessIds -join ', ')."
        Write-Warning "No listening sockets found for configured service process IDs: $($serviceProcessIds -join ', ')."
    }
} else {
    Add-Finding -Severity Warning -Message "No configured service process IDs were available for listener ownership checks."
    Write-Warning "No configured service process IDs available for listener check."
}

Write-Host ""
Write-Host "HTTP health" -ForegroundColor Yellow
if ($healthUrl) {
    try {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec $HealthTimeoutSeconds
        $timer.Stop()
        $healthResult = [pscustomobject]@{
            StatusCode = $response.StatusCode
            StatusDescription = $response.StatusDescription
            ResponseMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
            TimeoutSeconds = $HealthTimeoutSeconds
        }
        $healthResult | Format-Table -AutoSize
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) {
            Add-Finding -Severity Critical -Message "Health probe returned HTTP $($response.StatusCode) for $healthUrl."
        }
    } catch {
        Add-Finding -Severity Critical -Message "Health probe failed for configured HealthUrl: $($_.Exception.Message)"
        Write-Warning "Health probe failed for configured HealthUrl. $($_.Exception.Message)"
    }
} else {
    Add-Finding -Severity Critical -Message "No HealthUrl is configured."
    Write-Warning "No HealthUrl configured."
}

Write-Host ""
Write-Host "Health check task" -ForegroundColor Yellow
$taskName = "$serviceName-HealthCheck"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskInfo) {
        $taskInfo |
            Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
            Format-Table -AutoSize
        $nonFailureTaskCodes = @(0, 267009, 267010, 267011, 267014)
        if ($nonFailureTaskCodes -notcontains [int]$taskInfo.LastTaskResult) {
            Add-Finding -Severity Warning -Message "Health check task last result is $($taskInfo.LastTaskResult), not a known success/running code."
        }
        if ($taskInfo.NumberOfMissedRuns -gt 0) {
            Add-Finding -Severity Warning -Message "Health check task has $($taskInfo.NumberOfMissedRuns) missed run(s)."
        }
    } else {
        $task | Select-Object TaskName, State | Format-Table -AutoSize
        Add-Finding -Severity Warning -Message "Health check scheduled task exists, but task run metadata could not be read."
    }
} else {
    Add-Finding -Severity Warning -Message "Health check scheduled task was not found: $taskName."
    Write-Warning "Health check scheduled task not found: $taskName"
}

Write-Host ""
Write-Host "Health history" -ForegroundColor Yellow
$statePath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.state.json" } else { "" }
if ($statePath -and (Test-Path $statePath)) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $lastSuccess = Get-DateTimeFromStateValue $state.LastSuccessUtc
        $lastCheck = Get-DateTimeFromStateValue $state.LastCheckUtc
        $lastRestart = Get-DateTimeFromStateValue $state.LastRestartUtc
        [pscustomobject]@{
            ConsecutiveFailures = $state.ConsecutiveFailures
            LastCheck = Format-OptionalUtc $state.LastCheckUtc
            LastSuccess = Format-OptionalUtc $state.LastSuccessUtc
            LastFailure = Format-OptionalUtc $state.LastFailureUtc
            LastRestart = Format-OptionalUtc $state.LastRestartUtc
        } | Format-Table -AutoSize
        if ([int]$state.ConsecutiveFailures -ge $failureThreshold) {
            Add-Finding -Severity Critical -Message "Health check state has $($state.ConsecutiveFailures) consecutive failure(s), meeting or exceeding threshold $failureThreshold."
        } elseif ([int]$state.ConsecutiveFailures -gt 0) {
            Add-Finding -Severity Warning -Message "Health check state has $($state.ConsecutiveFailures) consecutive failure(s)."
        }
        $staleAfter = [TimeSpan]::FromMinutes([Math]::Max(5, $healthIntervalMinutes * 3))
        if ($lastSuccess -and ((Get-Date) - $lastSuccess) -gt $staleAfter) {
            Add-Finding -Severity Warning -Message "Last successful health check is older than $([int]$staleAfter.TotalMinutes) minutes."
        }
        if (-not $lastSuccess) {
            Add-Finding -Severity Warning -Message "Health state has no recorded successful check yet."
        }
        if (-not $lastCheck) {
            Add-Finding -Severity Warning -Message "Health state has no recorded check time yet."
        }
        if ($lastRestart -and ((Get-Date) - $lastRestart).TotalMinutes -lt [Math]::Max(5, $healthIntervalMinutes * 3)) {
            Add-Finding -Severity Warning -Message "Health check restarted the service recently at $($lastRestart.ToString('yyyy-MM-dd HH:mm:ss'))."
        }
    } catch {
        Add-Finding -Severity Warning -Message "Could not read health state file: $statePath"
        Write-Warning "Could not read health state file: $statePath"
    }
} else {
    Add-Finding -Severity Warning -Message "Health state file was not found yet."
    Write-Warning "Health state file not found yet."
}

$healthLogPath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.log" } else { "" }
$healthLogSummary = if ($healthLogPath) { Get-HealthLogSummary $healthLogPath } else { $null }
if ($healthLogSummary) {
    $healthLogSummary | Format-Table -AutoSize
    if ($healthLogSummary.Restarted -gt 0) {
        Add-Finding -Severity Warning -Message "Recent sampled health log contains $($healthLogSummary.Restarted) restart event(s)."
    }
    if ($healthLogSummary.Failed -gt 0) {
        Add-Finding -Severity Warning -Message "Recent sampled health log contains $($healthLogSummary.Failed) failure event(s)."
    }
} else {
    Add-Finding -Severity Warning -Message "Health check log was not found yet."
    Write-Warning "Health check log not found yet."
}

Write-Host ""
Write-Host "Recent log files" -ForegroundColor Yellow
if ($config.LogDirectory -and (Test-Path $config.LogDirectory)) {
    Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
} else {
    Write-Warning "Log directory not found or not configured."
}

Write-Host ""
Write-Host "Retention and backups" -ForegroundColor Yellow
$backupDirectory = Get-BackupDirectory $config
[pscustomobject]@{
    LogRetentionDays = Get-ConfigInt $config "LogRetentionDays" 30
    BackupRetentionDays = Get-ConfigInt $config "BackupRetentionDays" 90
    DiagnosticRetentionDays = Get-ConfigInt $config "DiagnosticRetentionDays" 14
    BackupDirectory = $backupDirectory
} | Format-List
if ($backupDirectory -and (Test-Path $backupDirectory)) {
    Get-ChildItem $backupDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
} else {
    Write-Warning "Backup directory not found yet."
}

Write-Host ""
Write-Host "Operational verdict" -ForegroundColor Yellow
$verdict = Get-WorstFindingSeverity
$criticalCount = @($script:findings | Where-Object { $_.Severity -eq "Critical" }).Count
$warningCount = @($script:findings | Where-Object { $_.Severity -eq "Warning" }).Count
[pscustomobject]@{
    Verdict = $verdict
    Critical = $criticalCount
    Warnings = $warningCount
    MinimumUptimeHours = $MinimumUptimeHours
    HealthTimeoutSeconds = $HealthTimeoutSeconds
} | Format-List

if ($script:findings.Count -gt 0) {
    $script:findings |
        Sort-Object @{ Expression = { if ($_.Severity -eq "Critical") { 0 } elseif ($_.Severity -eq "Warning") { 1 } else { 2 } } }, Message |
        Format-Table Severity, Message -Wrap
} else {
    Write-Host "No critical or warning findings." -ForegroundColor Green
}

if ($FailOnCritical -and $criticalCount -gt 0) {
    exit 2
}
