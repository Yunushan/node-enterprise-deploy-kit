<#
.SYNOPSIS
  Collect safe diagnostics for a Node app without exposing environment secret values.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $OutputDirectory = ""
)
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $config.LogDirectory "diagnostics" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $OutputDirectory "diagnostics-$stamp.txt"
function Add-Section([string]$Title) { "`r`n===== $Title =====" | Out-File $out -Append -Encoding UTF8 }
function Format-OptionalUtc($Value) {
    if (-not $Value) { return "" }
    try { return ([DateTime]::Parse([string]$Value).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss") } catch { return [string]$Value }
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
function Add-HealthLogSummary([string]$Path) {
    if (-not (Test-Path $Path)) {
        "No healthcheck.log found." | Out-File $out -Append -Encoding UTF8
        return
    }
    $lines = @(Get-Content -Path $Path -Tail 2000 -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Path = $Path
        LastWriteTime = (Get-Item $Path).LastWriteTime
        LinesSampled = $lines.Count
        Ok = @($lines | Where-Object { $_ -match '\sOK\s' }).Count
        Failed = @($lines | Where-Object { $_ -match '\sFAILED|FAILED_THRESHOLD|EXCEPTION|BAD_STATUS|SERVICE_NOT_RUNNING' }).Count
        Restarted = @($lines | Where-Object { $_ -match 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' }).Count
        RestartSuppressed = @($lines | Where-Object { $_ -match 'RESTART_SUPPRESSED_COOLDOWN' }).Count
    } | Format-List | Out-File $out -Append -Encoding UTF8
}
"Diagnostics generated $(Get-Date -Format o)" | Out-File $out -Encoding UTF8
"AppName=$($config.AppName)" | Out-File $out -Append -Encoding UTF8
"AppDirectory=$($config.AppDirectory)" | Out-File $out -Append -Encoding UTF8
"Port=$($config.Port)" | Out-File $out -Append -Encoding UTF8
"HealthUrl=$($config.HealthUrl)" | Out-File $out -Append -Encoding UTF8
Add-Section "Service"
Get-Service -Name $config.AppName -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append -Encoding UTF8
Add-Section "Node Processes"
Get-Process node -ErrorAction SilentlyContinue | Select-Object Id, CPU, PM, WS, StartTime, Path | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Port Check"
Get-NetTCPConnection -LocalPort $config.Port -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
Add-Section "HTTP Health"
try { Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec 10 | Select-Object StatusCode, StatusDescription | Format-List | Out-File $out -Append -Encoding UTF8 } catch { "HTTP probe failed: $($_.Exception.Message)" | Out-File $out -Append -Encoding UTF8 }
Add-Section "Health Check History"
$taskName = "$($config.AppName)-HealthCheck"
Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue |
Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
Format-List | Out-File $out -Append -Encoding UTF8
$statePath = Join-Path $config.LogDirectory "healthcheck.state.json"
if (Test-Path $statePath) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        [pscustomobject]@{
            ConsecutiveFailures = $state.ConsecutiveFailures
            LastCheck = Format-OptionalUtc $state.LastCheckUtc
            LastSuccess = Format-OptionalUtc $state.LastSuccessUtc
            LastFailure = Format-OptionalUtc $state.LastFailureUtc
            LastRestart = Format-OptionalUtc $state.LastRestartUtc
        } | Format-List | Out-File $out -Append -Encoding UTF8
    } catch {
        "Could not read health state file." | Out-File $out -Append -Encoding UTF8
    }
} else {
    "No health state file found." | Out-File $out -Append -Encoding UTF8
}
Add-HealthLogSummary (Join-Path $config.LogDirectory "healthcheck.log")
Add-Section "Recent Application Events"
Get-WinEvent -LogName Application -MaxEvents 80 -ErrorAction SilentlyContinue |
Where-Object { $_.Message -like "*node*" -or $_.Message -like "*$($config.AppName)*" -or $_.Message -like "*iis*" -or $_.Message -like "*w3wp*" } |
Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Recent Reboot Events"
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005,6006,6008,1074} -MaxEvents 30 -ErrorAction SilentlyContinue |
Select-Object TimeCreated, Id, ProviderName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Logs Tail"
Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName, Length, LastWriteTime | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
Add-Section "Retention And Backups"
$backupDirectory = Get-BackupDirectory $config
[pscustomobject]@{
    LogRetentionDays = if ($config.PSObject.Properties["LogRetentionDays"]) { $config.LogRetentionDays } else { 30 }
    BackupRetentionDays = if ($config.PSObject.Properties["BackupRetentionDays"]) { $config.BackupRetentionDays } else { 90 }
    DiagnosticRetentionDays = if ($config.PSObject.Properties["DiagnosticRetentionDays"]) { $config.DiagnosticRetentionDays } else { 14 }
    BackupDirectory = $backupDirectory
} | Format-List | Out-File $out -Append -Encoding UTF8
if ($backupDirectory -and (Test-Path $backupDirectory)) {
    Get-ChildItem $backupDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, Length, LastWriteTime |
        Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
}
Write-Host "Diagnostics written to: $out" -ForegroundColor Green
