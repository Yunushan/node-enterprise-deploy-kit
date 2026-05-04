<#
.SYNOPSIS
  Register a scheduled health check task that restarts the app service if HTTP health fails.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run this script as Administrator." }
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    return (Join-Path $Config.ServiceDirectory "backups")
}
function Backup-ScheduledTaskIfExists([string]$TaskName, [string]$BackupDirectory) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $BackupDirectory ("{0}.{1}.{2}.xml.bak" -f $TaskName, $timestamp, $PID)
    Export-ScheduledTask -TaskName $TaskName | Set-Content -Path $backupPath -Encoding UTF8
    Write-Host "Backed up scheduled task $TaskName to $backupPath"
}

Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$scriptPath = Join-Path $repoRoot "scripts\windows\Invoke-NodeHealthCheck.ps1"
$taskName = "$($config.AppName)-HealthCheck"
$backupDirectory = Get-BackupDirectory $config
$interval = [int]$config.HealthCheckIntervalMinutes
if ($interval -lt 1) { $interval = 1 }
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $interval) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
if ($PSCmdlet.ShouldProcess($taskName, "Register health check scheduled task")) {
    Backup-ScheduledTaskIfExists -TaskName $taskName -BackupDirectory $backupDirectory
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
Write-Host "Registered health check task: $taskName" -ForegroundColor Green
