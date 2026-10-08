[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $NssmPath = "tools\nssm\nssm.exe",
    [switch] $RemoveHealthCheckTask
)
function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run as Administrator." }
}
function Resolve-RepoPath([string]$Path, [string]$BasePath) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $BasePath $Path)
}
function Get-HealthTaskDirectory($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw "Windows ProgramData directory could not be resolved." }
    $healthRoot = [IO.Path]::GetFullPath((Join-Path $programData "node-enterprise-deploy-kit\healthchecks"))
    $target = [IO.Path]::GetFullPath((Join-Path $healthRoot ([string]$Config.AppName)))
    $boundary = $healthRoot.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed health-task deletion target must be strictly below its private healthchecks root.' }
    return $target
}
function Remove-ManagedHealthTaskDirectory($Config) {
    $taskDirectory = Get-HealthTaskDirectory $Config
    Assert-WindowsServiceSecurityNoReparse -Path $taskDirectory
    if (-not (Test-Path -LiteralPath $taskDirectory)) { return }
    $item = Get-Item -LiteralPath $taskDirectory -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a managed health-task directory that is a reparse point: $taskDirectory"
    }
    if ($PSCmdlet.ShouldProcess($taskDirectory, "Remove protected managed health-task files")) {
        Remove-Item -LiteralPath $taskDirectory -Recurse -Force
    }
}
function Invoke-NativeCommand([string]$FilePath, [string[]]$Arguments, [string]$Label, [switch]$IgnoreExitCode) {
    & $FilePath @Arguments
    if (-not $IgnoreExitCode -and $LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}
function Uninstall-WinSWService($Config) {
    Remove-ManagedNativeWindowsService -Config $Config
}
function Uninstall-NssmService($Config, [string]$ResolvedNssmPath) {
    Remove-ManagedNativeWindowsService -Config $Config
}
function Get-UninstallNativeServiceIfPresent {
    param([string]$Name)
    try { return Get-Service -Name $Name -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) { return $null }
        throw
    }
}
function Get-UninstallScExecutablePath {
    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemDirectory) -or -not [IO.Path]::IsPathRooted($systemDirectory)) { throw 'Windows system directory could not be resolved for SCM removal.' }
    $scPath = Join-Path $systemDirectory 'sc.exe'
    if (-not (Test-Path -LiteralPath $scPath -PathType Leaf)) { throw 'The Windows system SCM executable is missing.' }
    return $scPath
}
function Remove-ManagedNativeWindowsService {
    param($Config)
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $definition = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop
    if (-not $definition) { return }
    Assert-ManagedServiceOwnership -Config $Config -Service $definition
    $scPath = Get-UninstallScExecutablePath
    Set-ManagedNativeServiceStartMode -Service $definition -StartMode 'Disabled'
    $service = Get-Service -Name $Config.AppName -ErrorAction Stop
    try {
        if ([string]$service.Status -ne 'Stopped') { Stop-Service -Name $Config.AppName -Force -ErrorAction Stop }
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    } finally { if ($service -is [IDisposable]) { $service.Dispose() } }
    # Delete through SCM rather than executing an untrusted or missing wrapper.
    # Ownership above accepts the protected per-app NSSM binary and the known
    # legacy repository binary; arbitrary -NssmPath values do not establish trust.
    Invoke-NativeCommand $scPath @('delete', [string]$Config.AppName) 'Delete managed service'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remaining = Get-UninstallNativeServiceIfPresent -Name $Config.AppName
        if (-not $remaining) { return }
        if ($remaining -is [IDisposable]) { $remaining.Dispose() }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Managed service registration survived uninstall; health task remains suspended.' }
        Start-Sleep -Milliseconds 200
    } while ($true)
}
function Suspend-UninstallHealthTask {
    param([string]$TaskName, $Task)
    if (-not $Task) { return }
    $enabled = if ($Task.PSObject.Properties['Settings'] -and $Task.Settings.PSObject.Properties['Enabled']) { [bool]$Task.Settings.Enabled } else { [string]$Task.State -ne 'Disabled' }
    if ($enabled) { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
    $current = Get-ManagedScheduledTaskIfPresent -TaskName $TaskName
    if ($current -and [string]$current.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $current = Get-ManagedScheduledTaskIfPresent -TaskName $TaskName
            if (-not $current -or [string]$current.State -ne 'Running') { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Health task did not drain before uninstall.' }
            Start-Sleep -Milliseconds 200
        } while ($true)
    }
}
function Uninstall-Pm2Process($Config) {
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    if ($PSCmdlet.ShouldProcess($Config.AppName, "Stop and remove PM2 fallback process")) {
        $pm2Context = Get-WindowsPm2RuntimeContext -Config $Config
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2Context.Home
        $previousHome = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
        try {
            $env:PM2_HOME = $pm2Context.Home
            $entries = @(Get-ManagedPm2Entries $pm2Context.CommandName $Config.AppName $pm2Context.Home)
            foreach ($entry in $entries) {
                Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2Context.Home
                Invoke-NativeCommand $pm2Context.CommandName @('delete', ([long]$entry.pm_id).ToString([Globalization.CultureInfo]::InvariantCulture)) 'pm2 delete'
            }
            Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2Context.Home
            Invoke-NativeCommand $pm2Context.CommandName @("save", "--force") "pm2 save"
            if (@(Get-ManagedPm2Entries $pm2Context.CommandName $Config.AppName $pm2Context.Home).Count -gt 0) { throw 'PM2 managed process survived uninstall.' }
        } finally { [Environment]::SetEnvironmentVariable('PM2_HOME', $previousHome, 'Process') }
        if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
            $ecosystemPath = Join-Path $Config.ServiceDirectory "$($Config.AppName).pm2.config.cjs"
            Assert-WindowsServiceSecurityNoReparse -Path $ecosystemPath
            if (Test-Path -LiteralPath $ecosystemPath) { Remove-Item -LiteralPath $ecosystemPath -Force -ErrorAction Stop }
        }
    }
}
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $PSScriptRoot 'WindowsServiceSecurity.ps1')
. (Join-Path $PSScriptRoot 'DeploymentTransaction.ps1')
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-WindowsDeploymentConfigIdentity -Config $config
$serviceManager = "winsw"
if ($config.PSObject.Properties["ServiceManager"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ServiceManager)) {
    $serviceManager = [string]$config.ServiceManager
}
$serviceManager = $serviceManager.ToLowerInvariant()
$config | Add-Member NoteProperty ServiceManager $serviceManager -Force
if ($serviceManager -eq 'pm2') {
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$config.AppName)
    if ($RemoveHealthCheckTask) { throw 'PM2 uninstall must run as its unelevated owner. Remove its protected health-check task separately as an administrator; omit -RemoveHealthCheckTask here.' }
    $pm2Preflight = Get-WindowsPm2RuntimeContext -Config $config
    Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2Preflight.Home
} else { Assert-Admin }
$resolvedNssmPath = Resolve-RepoPath -Path $NssmPath -BasePath $repoRoot
if ($serviceManager -notin @('winsw', 'nssm', 'pm2')) { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
if ($PSCmdlet.ShouldProcess($config.AppName, 'Quiesce managed monitor and uninstall runtime under the app deployment lock')) {
    $uninstallLock = Enter-DeploymentLock -Config $config
    $taskName = "$($config.AppName)-HealthCheck"
    $previousTask = $null; $taskWasEnabled = $false; $runtimeRemoved = $false; $previousNative = $null; $previousNativeStartMode = ''
    try {
        if ($serviceManager -ne 'pm2') {
            $previousNative = Get-CimInstance Win32_Service -Filter "Name='$($config.AppName)'" -ErrorAction Stop
            if ($previousNative) { $previousNativeStartMode = [string]$previousNative.StartMode }
            if ($previousNative) { Assert-ManagedServiceOwnership -Config $config -Service $previousNative }
        } else {
            # Validate the daemon identity under the app lock before changing
            # the Windows monitor that shares this deployment identity.
            @(Get-ManagedPm2Entries $pm2Preflight.CommandName $config.AppName $pm2Preflight.Home) | Out-Null
        }
        $previousTask = Get-ManagedScheduledTaskIfPresent -TaskName $taskName
        if ($previousTask) { $taskWasEnabled = if ($previousTask.PSObject.Properties['Settings'] -and $previousTask.Settings.PSObject.Properties['Enabled']) { [bool]$previousTask.Settings.Enabled } else { [string]$previousTask.State -ne 'Disabled' } }
        Suspend-UninstallHealthTask -TaskName $taskName -Task $previousTask
switch ($serviceManager) {
    "winsw" { Uninstall-WinSWService $config }
    "nssm"  { Uninstall-NssmService $config $resolvedNssmPath }
    "pm2"   { Uninstall-Pm2Process $config }
    default { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
}
        $runtimeRemoved = $true
if ($RemoveHealthCheckTask) {
    if ($PSCmdlet.ShouldProcess($taskName, "Remove scheduled task")) {
        if (Get-ManagedScheduledTaskIfPresent -TaskName $taskName) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
        if (Get-ManagedScheduledTaskIfPresent -TaskName $taskName) { throw 'Health task survived uninstall removal; private task files retained.' }
        Remove-ManagedHealthTaskDirectory $config
    }
}
    } catch {
        $uninstallFailure = $_
        if (-not $runtimeRemoved) {
            $runtimeStillExists = $false
            if ($previousNative) {
                $current = Get-CimInstance Win32_Service -Filter "Name='$($config.AppName)'" -ErrorAction Stop
                if ($current) { Assert-ManagedServiceOwnership -Config $config -Service $current; Set-ManagedNativeServiceStartMode -Service $current -StartMode $(if ($previousNativeStartMode -eq 'Auto') { 'Automatic' } else { $previousNativeStartMode }); $runtimeStillExists = $true }
            } elseif ($serviceManager -eq 'pm2' -and $taskWasEnabled) {
                $pm2RecoveryContext = Get-WindowsPm2RuntimeContext -Config $config
                $runtimeStillExists = @(Get-ManagedPm2Entries $pm2RecoveryContext.CommandName $config.AppName $pm2RecoveryContext.Home).Count -gt 0
            }
            if ($runtimeStillExists -and $taskWasEnabled -and (Get-ManagedScheduledTaskIfPresent -TaskName $taskName)) { Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null }
        }
        throw $uninstallFailure
    } finally { Exit-DeploymentLock -Lock $uninstallLock }
}
