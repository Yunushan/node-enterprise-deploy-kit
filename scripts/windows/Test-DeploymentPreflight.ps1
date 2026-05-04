<#
.SYNOPSIS
  Validate Windows deployment configuration before installing services.
.DESCRIPTION
  Performs safe local checks only. It does not print environment values from
  the config and does not create, stop, start, or modify services.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe",
    [switch] $SkipReverseProxy,
    [switch] $SkipHealthCheck,
    [switch] $AllowPortInUse
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) { $errors.Add($Message) | Out-Null }
function Add-Warning([string]$Message) { $warnings.Add($Message) | Out-Null }
function Test-RequiredString($Object, [string]$Name) {
    if (-not $Object.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        Add-Error "Missing required config value: $Name"
    }
}
function Resolve-ToolPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}
function Get-ServiceProcessTreeIds([string]$Name) {
    $ids = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrWhiteSpace($Name)) { return @() }
    $escaped = $Name.Replace("'", "''")
    $svc = Get-CimInstance Win32_Service -Filter "Name='$escaped'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.ProcessId -and $svc.ProcessId -gt 0) {
        $ids.Add([int]$svc.ProcessId) | Out-Null
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.ProcessId)" -ErrorAction SilentlyContinue
        foreach ($child in @($children)) {
            if ($child.ProcessId) { $ids.Add([int]$child.ProcessId) | Out-Null }
        }
    }
    return @($ids | Sort-Object -Unique)
}

@(
    "AppName",
    "DisplayName",
    "AppDirectory",
    "StartCommand",
    "NodeExe",
    "Port",
    "HealthUrl",
    "ServiceManager",
    "ReverseProxy",
    "ServiceDirectory",
    "LogDirectory"
) | ForEach-Object { Test-RequiredString $config $_ }

if ($config.AppName -and ([string]$config.AppName -notmatch '^[A-Za-z0-9_.-]+$')) {
    Add-Error "AppName should contain only letters, numbers, dot, underscore, or dash for service compatibility."
}

if ($config.NodeExe -and -not (Test-Path $config.NodeExe)) {
    Add-Error "NodeExe not found: $($config.NodeExe)"
}

if ($config.AppDirectory -and -not (Test-Path $config.AppDirectory)) {
    Add-Error "AppDirectory not found: $($config.AppDirectory)"
}

if ($config.AppDirectory -and $config.StartCommand -and (Test-Path $config.AppDirectory)) {
    $startCommand = [string]$config.StartCommand
    if (-not [System.IO.Path]::IsPathRooted($startCommand)) {
        $startCommandPath = Join-Path $config.AppDirectory $startCommand
        if ($startCommand -notmatch '\s' -and -not (Test-Path $startCommandPath)) {
            Add-Error "StartCommand file not found under AppDirectory: $startCommandPath"
        }
    } elseif (-not (Test-Path $startCommand)) {
        Add-Error "StartCommand file not found: $startCommand"
    }
}

$port = 0
if (-not [int]::TryParse([string]$config.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    Add-Error "Port must be an integer between 1 and 65535."
}

if ($config.Environment -and $config.Environment.PSObject.Properties["PORT"]) {
    $envPort = [string]$config.Environment.PORT
    if ($envPort -and $envPort -ne [string]$config.Port) {
        Add-Warning "Environment.PORT does not match Port. The service may listen on an unexpected port."
    }
}

try {
    $healthUri = [Uri][string]$config.HealthUrl
    if ($healthUri.Scheme -notin @("http", "https")) {
        Add-Error "HealthUrl must use http or https."
    }
    if ($healthUri.Port -gt 0 -and $port -gt 0 -and $healthUri.Port -ne $port) {
        Add-Warning "HealthUrl port ($($healthUri.Port)) does not match Port ($port)."
    }
} catch {
    Add-Error "HealthUrl is not a valid URI: $($config.HealthUrl)"
}

$serviceManager = ([string]$config.ServiceManager).ToLowerInvariant()
switch ($serviceManager) {
    "winsw" {
        $winswCandidate = Resolve-ToolPath $WinSWPath
        if (-not (Test-Path $winswCandidate)) {
            Add-Error "WinSW executable not found: $winswCandidate"
        }
    }
    "nssm" {
        $nssmCandidate = Resolve-ToolPath "tools\nssm\nssm.exe"
        if (-not (Test-Path $nssmCandidate)) {
            Add-Warning "NSSM selected, but default nssm.exe was not found: $nssmCandidate"
        }
    }
    "pm2" {
        if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
            Add-Error "PM2 selected, but pm2 was not found in PATH."
        }
    }
    default {
        Add-Error "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2."
    }
}

$reverseProxy = ([string]$config.ReverseProxy).ToLowerInvariant()
if (-not $SkipReverseProxy) {
    switch ($reverseProxy) {
        "iis" {
            Test-RequiredString $config "IisSitePath"
            if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
                Add-Warning "IIS WebAdministration module was not found. IIS site/app-pool automation may not be available."
            }
        }
        "none" {}
        "" {}
        default {
            Add-Error "Unsupported ReverseProxy: $($config.ReverseProxy). Use iis or none on Windows."
        }
    }
}

if (-not $SkipHealthCheck) {
    $interval = 0
    if (-not [int]::TryParse([string]$config.HealthCheckIntervalMinutes, [ref]$interval) -or $interval -lt 1) {
        Add-Warning "HealthCheckIntervalMinutes is missing or below 1. The installer will use 1 minute."
    }
}

if ($port -gt 0 -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listeners) {
        $ownerIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
        $owners = $ownerIds -join ", "
        $serviceProcessIds = Get-ServiceProcessTreeIds ([string]$config.AppName)
        $matchingOwnerCount = @($ownerIds | Where-Object { $serviceProcessIds -contains $_ }).Count
        $ownedByConfiguredService = ($serviceProcessIds.Count -gt 0) -and ($matchingOwnerCount -eq $ownerIds.Count)
        if ($AllowPortInUse) {
            Add-Warning "Port $port is already listening. Owning process ID(s): $owners"
        } elseif ($ownedByConfiguredService) {
            Add-Warning "Port $port is already listening by the configured service. This is normal for service updates."
        } else {
            Add-Error "Port $port is already listening. Owning process ID(s): $owners. Stop the conflicting service or pass -AllowPortInUse for updates."
        }
    }
}

Write-Host "Preflight checked: $($config.AppName)" -ForegroundColor Cyan
if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Warning $_ }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Errors" -ForegroundColor Red
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Preflight failed with $($errors.Count) error(s)."
}

Write-Host "Preflight passed." -ForegroundColor Green
