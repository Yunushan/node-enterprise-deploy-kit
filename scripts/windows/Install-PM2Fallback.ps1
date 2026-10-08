<#
.SYNOPSIS
  Optional PM2 fallback installer. WinSW is recommended for Windows production.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [object] $ExistingDeploymentLock,
    [object] $ExistingManagedDeploymentTransaction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}
function ConvertTo-ServiceEnvironmentMap($Config) {
    $map = [ordered]@{}
    $bindAddress = Get-ConfigString $Config "BindAddress" "127.0.0.1"

    $map["NODE_ENV"] = "production"
    $map["PORT"] = [string]$Config.Port
    $map["APP_PORT"] = [string]$Config.Port
    $map["APP_NAME"] = [string]$Config.AppName
    $map["BIND_ADDRESS"] = $bindAddress
    $map["HOST"] = $bindAddress
    $map["HOSTNAME"] = $bindAddress

    if ($Config.Environment) {
        $Config.Environment.PSObject.Properties | ForEach-Object {
            $map[$_.Name] = [string]$_.Value
        }
    }

    return $map
}
function New-Pm2EcosystemConfig($Config, $EnvironmentMap) {
    $env = [ordered]@{}
    foreach ($name in $EnvironmentMap.Keys) {
        $env[$name] = [string]$EnvironmentMap[$name]
    }

    $app = [ordered]@{
        name = [string]$Config.AppName
        cwd = [string]$Config.AppDirectory
        script = [string]$Config.StartCommand
        interpreter = [string]$Config.NodeExe
        args = Get-ConfigString $Config "NodeArguments" ""
        time = $true
        merge_logs = $true
        out_file = (Join-Path $Config.LogDirectory "pm2-out.log")
        error_file = (Join-Path $Config.LogDirectory "pm2-error.log")
        max_memory_restart = "1024M"
        env = $env
    }

    $ecosystem = [ordered]@{
        apps = @($app)
    }

    return "module.exports = " + ($ecosystem | ConvertTo-Json -Depth 20) + ";`r`n"
}
function Invoke-CheckedPm2Command {
    param(
        [string]$CommandName,
        [object[]]$Arguments,
        [string]$Label
    )

    Assert-WindowsPm2DeploymentAppName -AppName ([string]$config.AppName)
    Assert-WindowsPm2ExecutionAllowed
    & $CommandName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}
function Set-Pm2PrivateFilesystemSecurity {
    param($Config, [string]$Account, [string]$Pm2Home)
    $paths = Assert-WindowsServiceSecurityPaths -Config $Config
    $pm2ResolvedHome = Get-WindowsServiceSecurityFullPath -Path $Pm2Home
    Assert-WindowsServiceSecurityNoReparse -Path $pm2ResolvedHome
    foreach ($path in @($paths.App, $paths.Service, $paths.Logs, $paths.Backup, $paths.Lock)) {
        if ((Test-WindowsServiceSecurityPathWithin $pm2ResolvedHome $path) -or (Test-WindowsServiceSecurityPathWithin $path $pm2ResolvedHome)) { throw 'PM2_HOME must be separate from application, service, backup, log and deployment-lock directories.' }
    }
    # PM2 and its application use the invoking identity. These ACLs exclude
    # other users; they cannot separate the application from its own owner.
    foreach ($path in @($paths.Service, $paths.Backup, $pm2ResolvedHome)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-WindowsProtectedPathSecurity -Path $path -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $Account -Recurse -ExcludePaths @($paths.Lock)
    }
    New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null
}
function Write-Pm2PrivateEcosystemFile {
    param([string]$Path, [string]$Content, [string]$BackupDirectory, [string]$Account)
    if (Test-Path -LiteralPath $Path) {
        Assert-WindowsServiceSecurityNoReparse -Path $Path
        $backup = Join-Path $BackupDirectory (([IO.Path]::GetFileName($Path)) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
        [IO.File]::WriteAllBytes($backup, [byte[]]@())
        Set-WindowsProtectedPathSecurity -Path $backup -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $Account
        [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($Path))
    } else { [IO.File]::WriteAllBytes($Path, [byte[]]@()) }
    Set-WindowsProtectedPathSecurity -Path $Path -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $Account
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.ServiceManager -ne "pm2") {
    throw "This installer supports ServiceManager='pm2'. For WinSW/NSSM, use the dedicated scripts."
}
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $repoRoot "scripts\windows\AppPackageLifecycle.ps1")
. (Join-Path $repoRoot "scripts\windows\PostDeployHealth.ps1")
. (Join-Path $repoRoot "scripts\windows\WindowsServiceSecurity.ps1")
Assert-WindowsPm2DeploymentAppName -AppName ([string]$config.AppName)
. (Join-Path $repoRoot "scripts\windows\DeploymentTransaction.ps1")
[void](Assert-WindowsServiceSecurityPaths -Config $config)
$pm2Context = Get-WindowsPm2RuntimeContext -Config $config
$pm2Account = $pm2Context.Account
$pm2Home = $pm2Context.Home
$pm2CommandName = $pm2Context.CommandName
Write-Warning "PM2 fallback selected. For Windows enterprise production, WinSW is recommended."
if ($PSCmdlet.ShouldProcess($config.AppName, "Start PM2 process")) {
    Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2Home
    $installerState = Start-ManagedServiceInstallerTransaction -Config $config -ExistingDeploymentLock $ExistingDeploymentLock -ExistingManagedDeploymentTransaction $ExistingManagedDeploymentTransaction
    $installerFailure = $null
    $previousPm2Home = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
    $locationPushed = $false
    try {
    Push-Location $config.AppDirectory
    $locationPushed = $true
    $env:PM2_HOME = $pm2Home
    Set-Pm2PrivateFilesystemSecurity -Config $config -Account $pm2Account -Pm2Home $pm2Home
    $ecosystemPath = Join-Path $config.ServiceDirectory "$($config.AppName).pm2.config.cjs"
    $ecosystemContent = New-Pm2EcosystemConfig -Config $config -EnvironmentMap (ConvertTo-ServiceEnvironmentMap $config)
    $backupDirectory = Get-WindowsServiceSecurityConfigString $config 'BackupDirectory' (Join-Path $config.ServiceDirectory 'backups')
    Write-Pm2PrivateEcosystemFile -Path $ecosystemPath -Content $ecosystemContent -BackupDirectory $backupDirectory -Account $pm2Account

    $existingState = Get-AppPackagePm2State -Name $config.AppName -CommandName $pm2CommandName
    if ($existingState.Exists) {
        foreach ($pm2Id in @($existingState.ProcessIds)) { Invoke-CheckedPm2Command $pm2CommandName @('delete', [string]$pm2Id) 'PM2 delete exact process' }
    }
    Invoke-CheckedPm2Command $pm2CommandName @("start", $ecosystemPath, "--only", $config.AppName, "--update-env") "PM2 start"
    Invoke-CheckedPm2Command $pm2CommandName @("save") "PM2 save"
    foreach ($dumpName in @('dump.pm2', 'dump.pm2.bak')) {
        $dump = Join-Path $pm2Home $dumpName
        if (Test-Path -LiteralPath $dump) { Set-WindowsProtectedPathSecurity -Path $dump -Account $pm2Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $pm2Account }
    }
    $runningState = Get-AppPackagePm2State -Name $config.AppName -CommandName $pm2CommandName
    if (-not $runningState.Exists -or -not $runningState.WasRunning) {
        throw "PM2 did not report '$($config.AppName)' in a running state after start."
    }
    Test-PostDeployHealth -Config $config
    Write-Host "PM2 ecosystem file: $ecosystemPath"
    } catch {
        $installerFailure = $_
        throw
    } finally {
        [Environment]::SetEnvironmentVariable('PM2_HOME', $previousPm2Home, 'Process')
        if ($locationPushed) { Pop-Location }
        Complete-ManagedServiceInstallerTransaction -Config $config -State $installerState -Failure $installerFailure
    }
}
