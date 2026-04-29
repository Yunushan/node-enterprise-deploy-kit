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

$processIds = @()
if ($serviceProcess -and $serviceProcess.ProcessId -and $serviceProcess.ProcessId -gt 0) {
    $processIds += [int]$serviceProcess.ProcessId
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($serviceProcess.ProcessId)" -ErrorAction SilentlyContinue
    if ($children) {
        $processIds += @($children | Select-Object -ExpandProperty ProcessId)
        Write-Host ""
        Write-Host "Service child processes" -ForegroundColor Yellow
        $children | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath | Format-Table -AutoSize
    }
}

Write-Host ""
Write-Host "Node processes" -ForegroundColor Yellow
$nodeProcesses = Get-Process node -ErrorAction SilentlyContinue
if ($nodeProcesses) {
    $nodeProcesses | Select-Object Id, StartTime, Path | Format-Table -AutoSize
    $processIds += @($nodeProcesses | Select-Object -ExpandProperty Id)
} else {
    Write-Warning "No node.exe process found."
}

$processIds = @($processIds | Where-Object { $_ } | Sort-Object -Unique)

Write-Host ""
Write-Host "Configured port listener" -ForegroundColor Yellow
$portConnections = Get-NetTCPConnection -LocalPort $configuredPort -State Listen -ErrorAction SilentlyContinue
if ($portConnections) {
    $portConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
} else {
    Write-Warning "No listener found on configured port $configuredPort."
}

Write-Host ""
Write-Host "Listeners owned by service/node processes" -ForegroundColor Yellow
if ($processIds.Count -gt 0) {
    $ownedConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $processIds -contains $_.OwningProcess }
    if ($ownedConnections) {
        $ownedConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    } else {
        Write-Warning "No listening sockets found for service/node process IDs: $($processIds -join ', ')."
    }
} else {
    Write-Warning "No service/node process IDs available for listener check."
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
Write-Host "Recent log files" -ForegroundColor Yellow
if ($config.LogDirectory -and (Test-Path $config.LogDirectory)) {
    Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
} else {
    Write-Warning "Log directory not found or not configured."
}
