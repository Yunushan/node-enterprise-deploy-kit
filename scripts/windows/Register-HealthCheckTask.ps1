<#
.SYNOPSIS
  Register a protected scheduled health check that restarts the app service when HTTP health fails.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $RenderMonitorConfigOnly
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run this script as Administrator." }
}
function Resolve-ConfigPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
function Get-ConfigInt($Config, [string]$Name, [int]$Default, [int]$Minimum) {
    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        try { return [Math]::Max($Minimum, [int]$Config.$Name) } catch {}
    }
    return [Math]::Max($Minimum, $Default)
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        if (-not [System.IO.Path]::IsPathRooted([string]$Config.BackupDirectory)) { throw "BackupDirectory must be an absolute path for the SYSTEM health task." }
        return [System.IO.Path]::GetFullPath([string]$Config.BackupDirectory)
    }
    if (-not [System.IO.Path]::IsPathRooted([string]$Config.ServiceDirectory)) { throw "ServiceDirectory must be an absolute path for the SYSTEM health task." }
    return [System.IO.Path]::GetFullPath((Join-Path $Config.ServiceDirectory "backups"))
}
function Get-HealthTaskDirectory($Config) {
    if ([string]$Config.AppName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "AppName contains characters that are unsafe for the managed health-task directory."
    }
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw "Windows ProgramData directory could not be resolved." }
    return (Join-Path (Join-Path $programData "node-enterprise-deploy-kit\healthchecks") ([string]$Config.AppName))
}
function New-HealthMonitorConfig($Config) {
    if ([string]$Config.AppName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "AppName contains characters that are unsafe for the managed health-task directory."
    }
    if (-not [System.IO.Path]::IsPathRooted([string]$Config.LogDirectory)) {
        throw "LogDirectory must be an absolute path for the SYSTEM health task."
    }
    try { $healthUri = [Uri]$Config.HealthUrl } catch { throw "HealthUrl must be a valid absolute HTTP(S) URI." }
    if ($healthUri.Scheme -notin @("http", "https") -or -not $healthUri.IsLoopback -or -not [string]::IsNullOrWhiteSpace($healthUri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($healthUri.Query) -or -not [string]::IsNullOrWhiteSpace($healthUri.Fragment)) {
        throw "HealthUrl must be a loopback HTTP(S) URL without credentials, query text, or a fragment for the SYSTEM health task."
    }
    return [ordered]@{
        Schema = "node-enterprise-deploy-kit/windows-health-monitor/v1"
        AppName = [string]$Config.AppName
        HealthUrl = [string]$Config.HealthUrl
        LogDirectory = [System.IO.Path]::GetFullPath([string]$Config.LogDirectory)
        BackupDirectory = Get-BackupDirectory $Config
        HealthCheckFailureThreshold = Get-ConfigInt $Config "HealthCheckFailureThreshold" 2 1
        HealthCheckRestartCooldownMinutes = Get-ConfigInt $Config "HealthCheckRestartCooldownMinutes" 5 1
        HealthCheckTimeoutSeconds = Get-ConfigInt $Config "HealthCheckTimeoutSeconds" 10 1
        LogRetentionDays = Get-ConfigInt $Config "LogRetentionDays" 30 1
        BackupRetentionDays = Get-ConfigInt $Config "BackupRetentionDays" 90 1
        DiagnosticRetentionDays = Get-ConfigInt $Config "DiagnosticRetentionDays" 14 1
    }
}
function Assert-NotReparsePoint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Managed health-task paths must not be reparse points: $Path"
    }
}
function Set-ProtectedDirectoryAcl([string]$Path) {
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $usersSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-545")
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $rights, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($administratorsSid, $rights, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($usersSid, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-ProtectedFileAcl([string]$Path) {
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $usersSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-545")
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $acl = [System.Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $rights, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($administratorsSid, $rights, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($usersSid, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Initialize-ProtectedTaskDirectories([string]$TaskDirectory) {
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $kitRoot = Join-Path $programData "node-enterprise-deploy-kit"
    $healthRoot = Join-Path $kitRoot "healthchecks"
    foreach ($directory in @($kitRoot, $healthRoot, $TaskDirectory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Assert-NotReparsePoint $directory
        Set-ProtectedDirectoryAcl $directory
    }
}
function Backup-ManagedFileIfChanged([string]$Destination, [string]$Replacement, [string]$BackupDirectory) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { return }
    $currentHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    $replacementHash = (Get-FileHash -LiteralPath $Replacement -Algorithm SHA256).Hash
    if ($currentHash -eq $replacementHash) { return }
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $BackupDirectory ("{0}.{1}.{2}.bak" -f ([System.IO.Path]::GetFileName($Destination)), $timestamp, $PID)
    Copy-Item -LiteralPath $Destination -Destination $backupPath -Force
}
function Backup-ScheduledTaskIfExists([string]$TaskName, [string]$BackupDirectory) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) { return "" }
    $taskXml = Export-ScheduledTask -TaskName $TaskName
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $BackupDirectory ("{0}.{1}.{2}.xml.bak" -f $TaskName, $timestamp, $PID)
    $taskXml | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Host "Backed up scheduled task $TaskName to $backupPath"
    return [string]$taskXml
}
function Restore-ManagedFile([string]$Destination, [string]$RollbackPath, [bool]$Existed) {
    if ($Existed) {
        Copy-Item -LiteralPath $RollbackPath -Destination $Destination -Force
        Set-ProtectedFileAcl $Destination
    } else {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$ConfigPath = Resolve-ConfigPath $ConfigPath
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$monitorConfig = New-HealthMonitorConfig $config
if ($RenderMonitorConfigOnly) {
    $monitorConfig | ConvertTo-Json -Depth 5
    return
}

Assert-Admin
$sourceScriptPath = Join-Path $repoRoot "scripts\windows\Invoke-NodeHealthCheck.ps1"
if (-not (Test-Path -LiteralPath $sourceScriptPath -PathType Leaf)) {
    throw "Health-check source script not found: $sourceScriptPath"
}
$taskDirectory = Get-HealthTaskDirectory $config
$deployedScriptPath = Join-Path $taskDirectory "Invoke-NodeHealthCheck.ps1"
$deployedConfigPath = Join-Path $taskDirectory "health-monitor.config.json"
$taskName = "$($config.AppName)-HealthCheck"
$backupDirectory = Get-BackupDirectory $config
$interval = Get-ConfigInt $config "HealthCheckIntervalMinutes" 1 1
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    throw "System Windows PowerShell executable was not found."
}
$repetitionDuration = New-TimeSpan -Days 3650
$actionArguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$deployedScriptPath`" -ConfigPath `"$deployedConfigPath`""
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $actionArguments -WorkingDirectory $taskDirectory
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $interval) -RepetitionDuration $repetitionDuration
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

if ($PSCmdlet.ShouldProcess($taskName, "Install protected health-check files and register scheduled task")) {
    Initialize-ProtectedTaskDirectories $taskDirectory
    $transactionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("node-enterprise-health-task-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $transactionRoot | Out-Null
    $stagedScript = Join-Path $transactionRoot "Invoke-NodeHealthCheck.ps1"
    $stagedConfig = Join-Path $transactionRoot "health-monitor.config.json"
    $rollbackScript = Join-Path $transactionRoot "rollback-script"
    $rollbackConfig = Join-Path $transactionRoot "rollback-config"
    $scriptExisted = Test-Path -LiteralPath $deployedScriptPath -PathType Leaf
    $configExisted = Test-Path -LiteralPath $deployedConfigPath -PathType Leaf
    $taskExisted = $null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    $existingTaskXml = ""
    $managedFilesChanged = $false
    try {
        if ($scriptExisted) { Copy-Item -LiteralPath $deployedScriptPath -Destination $rollbackScript -Force }
        if ($configExisted) { Copy-Item -LiteralPath $deployedConfigPath -Destination $rollbackConfig -Force }
        Copy-Item -LiteralPath $sourceScriptPath -Destination $stagedScript -Force
        [System.IO.File]::WriteAllText($stagedConfig, (($monitorConfig | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $existingTaskXml = Backup-ScheduledTaskIfExists -TaskName $taskName -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedScriptPath -Replacement $stagedScript -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedConfigPath -Replacement $stagedConfig -BackupDirectory $backupDirectory
        $managedFilesChanged = $true
        Copy-Item -LiteralPath $stagedScript -Destination $deployedScriptPath -Force
        Copy-Item -LiteralPath $stagedConfig -Destination $deployedConfigPath -Force
        Set-ProtectedFileAcl $deployedScriptPath
        Set-ProtectedFileAcl $deployedConfigPath
        if ((Get-FileHash -LiteralPath $sourceScriptPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $deployedScriptPath -Algorithm SHA256).Hash) {
            throw "Managed health-check script verification failed after copy."
        }
        $deployedMonitorConfig = Get-Content -LiteralPath $deployedConfigPath -Raw | ConvertFrom-Json
        if ($deployedMonitorConfig.PSObject.Properties["Environment"] -or $deployedMonitorConfig.PSObject.Properties["ServiceAccountPassword"]) {
            throw "Managed health monitor config contains a forbidden private-data property."
        }
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Host "Registered protected health check task: $taskName" -ForegroundColor Green
    } catch {
        if ($managedFilesChanged) {
            Restore-ManagedFile -Destination $deployedScriptPath -RollbackPath $rollbackScript -Existed $scriptExisted
            Restore-ManagedFile -Destination $deployedConfigPath -RollbackPath $rollbackConfig -Existed $configExisted
        }
        if ($taskExisted -and -not [string]::IsNullOrWhiteSpace($existingTaskXml)) {
            Register-ScheduledTask -TaskName $taskName -Xml $existingTaskXml -Force -ErrorAction SilentlyContinue | Out-Null
        } elseif (-not $taskExisted) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
