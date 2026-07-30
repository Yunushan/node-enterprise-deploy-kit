<#
.SYNOPSIS
  Optional PM2 fallback installer. WinSW is recommended for Windows production.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)

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

    & $CommandName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.ServiceManager -ne "pm2") {
    throw "This installer supports ServiceManager='pm2'. For WinSW/NSSM, use the dedicated scripts."
}
New-Item -ItemType Directory -Force -Path $config.ServiceDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $repoRoot "scripts\windows\AppPackageLifecycle.ps1")
. (Join-Path $repoRoot "scripts\windows\PostDeployHealth.ps1")
$pm2Command = Get-Command pm2 -ErrorAction Stop
$pm2CommandName = if ([string]::IsNullOrWhiteSpace([string]$pm2Command.Source)) { $pm2Command.Name } else { $pm2Command.Source }
Set-Location $config.AppDirectory
Write-Warning "PM2 fallback selected. For Windows enterprise production, WinSW is recommended."
if ($PSCmdlet.ShouldProcess($config.AppName, "Start PM2 process")) {
    $ecosystemPath = Join-Path $config.ServiceDirectory "$($config.AppName).pm2.config.cjs"
    $ecosystemContent = New-Pm2EcosystemConfig -Config $config -EnvironmentMap (ConvertTo-ServiceEnvironmentMap $config)
    [System.IO.File]::WriteAllText($ecosystemPath, $ecosystemContent, [System.Text.UTF8Encoding]::new($false))

    $existingState = Get-AppPackagePm2State -Name $config.AppName -CommandName $pm2CommandName
    if ($existingState.Exists) {
        Invoke-CheckedPm2Command $pm2CommandName @("delete", $config.AppName) "PM2 delete"
    }
    Invoke-CheckedPm2Command $pm2CommandName @("start", $ecosystemPath, "--only", $config.AppName, "--update-env") "PM2 start"
    Invoke-CheckedPm2Command $pm2CommandName @("save") "PM2 save"
    $runningState = Get-AppPackagePm2State -Name $config.AppName -CommandName $pm2CommandName
    if (-not $runningState.Exists -or -not $runningState.WasRunning) {
        throw "PM2 did not report '$($config.AppName)' in a running state after start."
    }
    Test-PostDeployHealth -Config $config
    Write-Host "PM2 ecosystem file: $ecosystemPath"
}
