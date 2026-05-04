<#
.SYNOPSIS
  Show safe Windows service, process, port, and health status.
.DESCRIPTION
  This script avoids printing environment variables, config Environment values,
  credentials, request bodies, or log contents. It reports only operational
  metadata needed to confirm whether the app is running.
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json"
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

Write-Host "Service" -ForegroundColor Yellow
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    $service | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
} else {
    Write-Warning "Service not found: $serviceName"
}

$serviceProcess = Get-CimInstance Win32_Service -Filter "Name='$escapedServiceName'" -ErrorAction SilentlyContinue
if ($serviceProcess) {
    $serviceProcess | Select-Object Name, State, StartMode, ProcessId | Format-Table -AutoSize
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
    Write-Warning "No node.exe process found."
}

$serviceProcessIds = @($serviceProcessIds | Where-Object { $_ } | Sort-Object -Unique)

Write-Host ""
Write-Host "Configured port listener" -ForegroundColor Yellow
$portConnections = Get-NetTCPConnection -LocalPort $configuredPort -State Listen -ErrorAction SilentlyContinue
if ($portConnections) {
    $portConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
} else {
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
        Write-Warning "No listening sockets found for configured service process IDs: $($serviceProcessIds -join ', ')."
    }
} else {
    Write-Warning "No configured service process IDs available for listener check."
}

Write-Host ""
Write-Host "HTTP health" -ForegroundColor Yellow
if ($healthUrl) {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10
        $response | Select-Object StatusCode, StatusDescription | Format-Table -AutoSize
    } catch {
        Write-Warning "Health probe failed for configured HealthUrl. $($_.Exception.Message)"
    }
} else {
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
    } else {
        $task | Select-Object TaskName, State | Format-Table -AutoSize
    }
} else {
    Write-Warning "Health check scheduled task not found: $taskName"
}

Write-Host ""
Write-Host "Health history" -ForegroundColor Yellow
$statePath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.state.json" } else { "" }
if ($statePath -and (Test-Path $statePath)) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        [pscustomobject]@{
            ConsecutiveFailures = $state.ConsecutiveFailures
            LastCheck = Format-OptionalUtc $state.LastCheckUtc
            LastSuccess = Format-OptionalUtc $state.LastSuccessUtc
            LastFailure = Format-OptionalUtc $state.LastFailureUtc
            LastRestart = Format-OptionalUtc $state.LastRestartUtc
        } | Format-Table -AutoSize
    } catch {
        Write-Warning "Could not read health state file: $statePath"
    }
} else {
    Write-Warning "Health state file not found yet."
}

$healthLogPath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.log" } else { "" }
$healthLogSummary = if ($healthLogPath) { Get-HealthLogSummary $healthLogPath } else { $null }
if ($healthLogSummary) {
    $healthLogSummary | Format-Table -AutoSize
} else {
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
