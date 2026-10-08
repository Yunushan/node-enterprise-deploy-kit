<#
.SYNOPSIS
  Register a protected scheduled health check that restarts the app service when HTTP health fails.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $RenderMonitorConfigOnly,
    $ExistingDeploymentLock
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DeploymentLock.ps1")
. (Join-Path $PSScriptRoot "WindowsServiceSecurity.ps1")
. (Join-Path $PSScriptRoot "DeploymentTransaction.ps1")

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
Assert-WindowsDeploymentConfigIdentity -Config $Config
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw "Windows ProgramData directory could not be resolved." }
    return (Join-Path (Join-Path $programData "node-enterprise-deploy-kit\healthchecks") ([string]$Config.AppName))
}
function New-HealthMonitorConfig($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $isStatic = $Config.PSObject.Properties['DeploymentMode'] -and
        ([string]$Config.DeploymentMode).Trim().ToLowerInvariant().Replace('_', '-') -eq 'static-iis'
    $logDirectory = if ($isStatic -and (-not $Config.PSObject.Properties['LogDirectory'] -or -not $Config.LogDirectory)) { Get-HealthTaskDirectory $Config } else { [string]$Config.LogDirectory }
    $healthUrl = if ($isStatic) { 'http://127.0.0.1/' } else { [string]$Config.HealthUrl }
    if (-not [System.IO.Path]::IsPathRooted($logDirectory)) {
        throw "LogDirectory must be an absolute path for the SYSTEM health task."
    }
    try { $healthUri = [Uri]$healthUrl } catch { throw "HealthUrl must be a valid absolute HTTP(S) URI." }
    if ($healthUri.Scheme -notin @("http", "https") -or -not $healthUri.IsLoopback -or -not [string]::IsNullOrWhiteSpace($healthUri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($healthUri.Query) -or -not [string]::IsNullOrWhiteSpace($healthUri.Fragment)) {
        throw "HealthUrl must be a loopback HTTP(S) URL without credentials, query text, or a fragment for the SYSTEM health task."
    }
    $manager = if ($Config.PSObject.Properties['ServiceManager']) { ([string]$Config.ServiceManager).ToLowerInvariant() } else { 'winsw' }
    if ($isStatic) { $manager = 'static-iis' }
    $result = [ordered]@{
        Schema = "node-enterprise-deploy-kit/windows-health-monitor/v1"
        AppName = [string]$Config.AppName
        ServiceManager = $manager
        HealthUrl = $healthUrl
        LogDirectory = [System.IO.Path]::GetFullPath($logDirectory)
        BackupDirectory = Get-BackupDirectory $Config
        DeploymentLockPath = Join-Path (Get-DeploymentLockDirectory $Config) (([string]$Config.AppName -creplace '[^A-Za-z0-9_.-]', '_') + '.lock')
        HealthCheckFailureThreshold = Get-ConfigInt $Config "HealthCheckFailureThreshold" 2 1
        HealthCheckRestartCooldownMinutes = Get-ConfigInt $Config "HealthCheckRestartCooldownMinutes" 5 1
        HealthCheckTimeoutSeconds = Get-ConfigInt $Config "HealthCheckTimeoutSeconds" 10 1
        LogRetentionDays = Get-ConfigInt $Config "LogRetentionDays" 30 1
        BackupRetentionDays = Get-ConfigInt $Config "BackupRetentionDays" 90 1
        DiagnosticRetentionDays = Get-ConfigInt $Config "DiagnosticRetentionDays" 14 1
    }
    if ($isStatic) { $result.RetentionOnly = $true }
    if ($manager -eq 'pm2') {
        $context = Get-WindowsPm2RuntimeContext -Config $Config
        $result.PM2Home = $context.Home
        $result.PM2Command = $context.CommandName
        $result.PM2OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    return $result
}

function Assert-ExistingPm2MonitorIdentity {
    param($Config, [string]$MonitorConfigPath)
    if (-not $Config.PSObject.Properties['ServiceManager'] -or ([string]$Config.ServiceManager).Trim().ToLowerInvariant() -ne 'pm2') { return }
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    Assert-DeploymentPathNotReparsePoint $MonitorConfigPath
    if (-not (Test-Path -LiteralPath $MonitorConfigPath -PathType Leaf)) { return }
    # Permit an administrator to repair an unreadable/legacy monitor definition;
    # a known case-only identity collision requires an explicit migration.
    try { $previous = Get-Content -LiteralPath $MonitorConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if ($previous.PSObject.Properties['AppName'] -and
        ([string]$previous.AppName).Equals([string]$Config.AppName, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$previous.AppName -cne [string]$Config.AppName) {
        throw 'A differently cased PM2 app owns the existing monitor identity; migrate its name explicitly.'
    }
}

function Grant-Pm2HealthTaskAccess {
    param([string]$TaskDirectory, [string]$LockPath, [string]$OwnerSid)
    $sid = [Security.Principal.SecurityIdentifier]::new($OwnerSid)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $securitySections = [Security.AccessControl.AccessControlSections]::Access -bor
        [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    $acl = Get-Acl -LiteralPath $TaskDirectory
    $rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::CreateFiles
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, $rights, $allow))
    # Atomic state replacement and log rotation create new data files. Grant
    # their creator Modify through inheritance only; existing script/config
    # files have protected admin-owned ACLs and never inherit this rule.
    $creatorOwner = [Security.Principal.SecurityIdentifier]::new('S-1-3-0')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $creatorOwner, [Security.AccessControl.FileSystemRights]::Modify,
        [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::InheritOnly, $allow))
    Restore-WindowsPathSecurity -Path $TaskDirectory -Sddl $acl.GetSecurityDescriptorSddlForm($securitySections)
    foreach ($name in @('healthcheck.state.json', 'healthcheck.log')) {
        $path = Join-Path $TaskDirectory $name
        Assert-NotReparsePoint $path
        if (-not (Test-Path -LiteralPath $path)) {
            $initial = if ($name.EndsWith('.json')) { '{}' } else { '' }
            [IO.File]::WriteAllText($path, $initial)
        }
        Set-ProtectedFileAcl $path
        $acl = Get-Acl -LiteralPath $path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::Modify, $allow))
        Restore-WindowsPathSecurity -Path $path -Sddl $acl.GetSecurityDescriptorSddlForm($securitySections)
    }
    $acl = Get-Acl -LiteralPath (Split-Path -Parent $LockPath)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $allow))
    Restore-WindowsPathSecurity -Path (Split-Path -Parent $LockPath) -Sddl $acl.GetSecurityDescriptorSddlForm($securitySections)
    $acl = Get-Acl -LiteralPath $LockPath
    $rw = [Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, $rw, $allow))
    Restore-WindowsPathSecurity -Path $LockPath -Sddl $acl.GetSecurityDescriptorSddlForm($securitySections)
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
    $acl.SetOwner($administratorsSid)
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
    $acl.SetOwner($administratorsSid)
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
        Assert-DeploymentPathNotReparsePoint $directory
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
$sourcePolicyPath = Join-Path $repoRoot 'scripts\windows\WindowsPm2ExecutionPolicy.ps1'
if (-not (Test-Path -LiteralPath $sourcePolicyPath -PathType Leaf)) { throw "PM2 execution policy source not found: $sourcePolicyPath" }
$taskDirectory = Get-HealthTaskDirectory $config
$deployedScriptPath = Join-Path $taskDirectory "Invoke-NodeHealthCheck.ps1"
$deployedConfigPath = Join-Path $taskDirectory "health-monitor.config.json"
$deployedPolicyPath = Join-Path $taskDirectory 'WindowsPm2ExecutionPolicy.ps1'
$sourceIdentityPath = Join-Path $repoRoot 'scripts/windows/WindowsDeploymentIdentity.ps1'
$deployedIdentityPath = Join-Path $taskDirectory 'WindowsDeploymentIdentity.ps1'
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
$taskRunLevel = 'Highest'
$taskUser = ''
$taskPassword = ''
if ($monitorConfig.ServiceManager -eq 'pm2') {
    # PM2 commonly resolves through its owner's writable npm installation.
    # The monitor must never turn that user's daemon/code into a UAC bridge.
    $taskRunLevel = 'Limited'
    $taskUser = (Get-WindowsPm2RuntimeContext -Config $config).Account
    if ($config.PSObject.Properties['HealthCheckTaskUser'] -and $config.HealthCheckTaskUser) {
        $requestedSid = [Security.Principal.NTAccount]::new([string]$config.HealthCheckTaskUser).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($requestedSid -ne $monitorConfig.PM2OwnerSid) { throw 'PM2 health task must run as the PM2 deployment owner.' }
    }
    if ($monitorConfig.PM2OwnerSid -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')) {
        $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType ServiceAccount -RunLevel Limited
    } else {
        if (-not $config.PSObject.Properties['HealthCheckTaskPassword'] -or -not $config.HealthCheckTaskPassword) {
            throw 'An unattended PM2 health task requires HealthCheckTaskPassword for its deployment owner. The credential is excluded from the monitor config.'
        }
        $taskPassword = [string]$config.HealthCheckTaskPassword
    }
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

if ($PSCmdlet.ShouldProcess($taskName, "Install protected health-check files and register scheduled task")) {
    $registrationLock = $null
    $ownsRegistrationLock = $false
    try {
    if ($ExistingDeploymentLock) {
        Assert-ExistingDeploymentLock -Config $config -Lock $ExistingDeploymentLock
        $registrationLock = $ExistingDeploymentLock
    } else {
        $registrationLock = Enter-DeploymentLock -Config $config
        $ownsRegistrationLock = $true
    }
    Assert-ExistingPm2MonitorIdentity -Config $config -MonitorConfigPath $deployedConfigPath
    $previousTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $existingTaskXml = if ($previousTask) { [string](Export-ScheduledTask -TaskName $taskName) } else { '' }
    $rollbackTaskUser = ''
    $rollbackTaskPassword = ''
    if ($existingTaskXml) {
        $previousTaskDefinition = [xml]$existingTaskXml
        $previousPrincipal = $previousTaskDefinition.SelectSingleNode("/*[local-name()='Task']/*[local-name()='Principals']/*[local-name()='Principal']")
        $previousLogon = $previousPrincipal.SelectSingleNode("*[local-name()='LogonType']")
        if ($previousLogon -and $previousLogon.InnerText -eq 'Password') {
            $rollbackTaskUser = $previousPrincipal.SelectSingleNode("*[local-name()='UserId']").InnerText
            $rollbackTaskPassword = Get-ManagedTaskRollbackCredential -Config $config -PrincipalUser $rollbackTaskUser
        }
    }
    Initialize-ProtectedTaskDirectories $taskDirectory
    $lockDirectory = Split-Path -Parent $monitorConfig.DeploymentLockPath
    Assert-DeploymentPathNotReparsePoint $lockDirectory
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    Set-ProtectedDeploymentLockDirectoryAcl $lockDirectory
    if (-not (Test-Path -LiteralPath $monitorConfig.DeploymentLockPath)) {
        [IO.File]::WriteAllText($monitorConfig.DeploymentLockPath, '')
    }
    $transactionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("node-enterprise-health-task-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $transactionRoot | Out-Null
    Set-ProtectedDirectoryAcl $transactionRoot
    $stagedScript = Join-Path $transactionRoot "Invoke-NodeHealthCheck.ps1"
    $stagedConfig = Join-Path $transactionRoot "health-monitor.config.json"
    $stagedPolicy = Join-Path $transactionRoot 'WindowsPm2ExecutionPolicy.ps1'
    $stagedIdentity = Join-Path $transactionRoot 'WindowsDeploymentIdentity.ps1'
    $rollbackIdentity = Join-Path $transactionRoot 'rollback-identity'
    $identityExisted = Test-Path -LiteralPath $deployedIdentityPath -PathType Leaf
    $rollbackScript = Join-Path $transactionRoot "rollback-script"
    $rollbackConfig = Join-Path $transactionRoot "rollback-config"
    $rollbackPolicy = Join-Path $transactionRoot 'rollback-policy'
    $policyExisted = Test-Path -LiteralPath $deployedPolicyPath -PathType Leaf
    $scriptExisted = Test-Path -LiteralPath $deployedScriptPath -PathType Leaf
    $configExisted = Test-Path -LiteralPath $deployedConfigPath -PathType Leaf
    $taskExisted = $null -ne $previousTask
    $managedFilesChanged = $false
    $taskRegistrationAttempted = $false
    $preserveRecoveryFiles = $false
    try {
        if ($scriptExisted) { Copy-Item -LiteralPath $deployedScriptPath -Destination $rollbackScript -Force }
        if ($configExisted) { Copy-Item -LiteralPath $deployedConfigPath -Destination $rollbackConfig -Force }
        if ($policyExisted) { Copy-Item -LiteralPath $deployedPolicyPath -Destination $rollbackPolicy -Force }
        if ($identityExisted) { Copy-Item -LiteralPath $deployedIdentityPath -Destination $rollbackIdentity -Force }
        Copy-Item -LiteralPath $sourceIdentityPath -Destination $stagedIdentity -Force
        Copy-Item -LiteralPath $sourcePolicyPath -Destination $stagedPolicy -Force
        Copy-Item -LiteralPath $sourceScriptPath -Destination $stagedScript -Force
        [System.IO.File]::WriteAllText($stagedConfig, (($monitorConfig | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $existingTaskXml = Backup-ScheduledTaskIfExists -TaskName $taskName -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedScriptPath -Replacement $stagedScript -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedConfigPath -Replacement $stagedConfig -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedPolicyPath -Replacement $stagedPolicy -BackupDirectory $backupDirectory
        Backup-ManagedFileIfChanged -Destination $deployedIdentityPath -Replacement $stagedIdentity -BackupDirectory $backupDirectory
        $managedFilesChanged = $true
        Copy-Item -LiteralPath $stagedScript -Destination $deployedScriptPath -Force
        Copy-Item -LiteralPath $stagedConfig -Destination $deployedConfigPath -Force
        Copy-Item -LiteralPath $stagedPolicy -Destination $deployedPolicyPath -Force
        Set-ProtectedFileAcl $deployedPolicyPath
        Copy-Item -LiteralPath $stagedIdentity -Destination $deployedIdentityPath -Force
        Set-ProtectedFileAcl $deployedIdentityPath
        Set-ProtectedFileAcl $deployedScriptPath
        Set-ProtectedFileAcl $deployedConfigPath
        if ((Get-FileHash -LiteralPath $sourceScriptPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $deployedScriptPath -Algorithm SHA256).Hash) {
            throw "Managed health-check script verification failed after copy."
        }
        if ((Get-FileHash -LiteralPath $sourcePolicyPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $deployedPolicyPath -Algorithm SHA256).Hash) { throw 'Managed PM2 execution policy verification failed after copy.' }
        if ((Get-FileHash -LiteralPath $sourceIdentityPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $deployedIdentityPath -Algorithm SHA256).Hash) { throw 'Managed deployment identity verification failed after copy.' }
        $deployedMonitorConfig = Get-Content -LiteralPath $deployedConfigPath -Raw | ConvertFrom-Json
        if ($deployedMonitorConfig.PSObject.Properties["Environment"] -or $deployedMonitorConfig.PSObject.Properties["ServiceAccountPassword"]) {
            throw "Managed health monitor config contains a forbidden private-data property."
        }
        if ($monitorConfig.ServiceManager -eq 'pm2') {
            Grant-Pm2HealthTaskAccess -TaskDirectory $taskDirectory -LockPath $monitorConfig.DeploymentLockPath -OwnerSid $monitorConfig.PM2OwnerSid
        }
        $taskRegistrationAttempted = $true
        if ($taskPassword) {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User $taskUser -Password $taskPassword -RunLevel $taskRunLevel -Settings $settings -Force -ErrorAction Stop | Out-Null
        } else {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        }
        Write-Host "Registered protected health check task: $taskName" -ForegroundColor Green
    } catch {
        $registrationFailure = $_
        try {
        if ($managedFilesChanged) {
            Restore-ManagedFile -Destination $deployedScriptPath -RollbackPath $rollbackScript -Existed $scriptExisted
            Restore-ManagedFile -Destination $deployedConfigPath -RollbackPath $rollbackConfig -Existed $configExisted
            Restore-ManagedFile -Destination $deployedPolicyPath -RollbackPath $rollbackPolicy -Existed $policyExisted
            Restore-ManagedFile -Destination $deployedIdentityPath -RollbackPath $rollbackIdentity -Existed $identityExisted
        }
        if ($taskRegistrationAttempted -and $taskExisted -and -not [string]::IsNullOrWhiteSpace($existingTaskXml)) {
            $restoreArguments = @{ TaskName = $taskName; Xml = $existingTaskXml; Force = $true; ErrorAction = 'Stop' }
            if ($rollbackTaskPassword) {
                $restoreArguments.User = $rollbackTaskUser
                $restoreArguments.Password = $rollbackTaskPassword
            }
            Register-ScheduledTask @restoreArguments | Out-Null
        } elseif ($taskRegistrationAttempted -and -not $taskExisted) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        }
        } catch {
            $preserveRecoveryFiles = $true
            throw "Health-task registration failed and recovery could not complete. Recovery files remain at '$transactionRoot'. Recovery error: $($_.Exception.Message)"
        }
        throw $registrationFailure
    } finally {
        if (-not $preserveRecoveryFiles) { Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    } finally {
        if ($ownsRegistrationLock) { Exit-DeploymentLock -Lock $registrationLock }
    }
}
