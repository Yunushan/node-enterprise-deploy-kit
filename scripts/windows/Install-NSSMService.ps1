<#
.SYNOPSIS
  Optional NSSM installer. WinSW remains the recommended Windows production default.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $NssmPath = "tools\nssm\nssm.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run as Administrator." }
}
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
function ConvertTo-NssmEnvironmentArguments($EnvironmentMap) {
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($name in $EnvironmentMap.Keys) {
        $entries.Add(("{0}={1}" -f $name, $EnvironmentMap[$name])) | Out-Null
    }
    return @($entries)
}
function Resolve-RepoPath([string]$Path, [string]$BasePath) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $BasePath $Path)
}
function Invoke-CheckedNativeCommand {
    param(
        [string]$FilePath,
        [object[]]$Arguments,
        [string]$Label
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}
Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.ServiceManager -ne "nssm") {
    throw "This installer supports ServiceManager='nssm'. For WinSW/PM2, use the dedicated scripts."
}
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $repoRoot "scripts\windows\PostDeployHealth.ps1")
$nssm = Resolve-RepoPath -Path $NssmPath -BasePath $repoRoot
if (-not (Test-Path $nssm)) { throw "NSSM not found at $nssm. Place nssm.exe there or pass -NssmPath." }

New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null

if ($PSCmdlet.ShouldProcess($config.AppName, "Install NSSM service")) {
    $existingService = Get-Service -Name $config.AppName -ErrorAction SilentlyContinue
    if ($existingService) {
        if ([string]$existingService.Status -ne "Stopped") {
            Stop-Service -Name $config.AppName -Force -ErrorAction Stop
            $existingService.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        }
        Invoke-CheckedNativeCommand $nssm @("remove", $config.AppName, "confirm") "NSSM remove"
    }

    Invoke-CheckedNativeCommand $nssm @("install", $config.AppName, [string]$config.NodeExe) "NSSM install"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppDirectory", [string]$config.AppDirectory) "NSSM AppDirectory"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppParameters", "$($config.StartCommand) $($config.NodeArguments)") "NSSM AppParameters"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "DisplayName", [string]$config.DisplayName) "NSSM DisplayName"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "Description", [string]$config.Description) "NSSM Description"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppStdout", (Join-Path $config.LogDirectory "stdout.log")) "NSSM stdout log"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppStderr", (Join-Path $config.LogDirectory "stderr.log")) "NSSM stderr log"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRotateFiles", "1") "NSSM log rotation"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRotateBytes", "10485760") "NSSM log rotation size"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRestartDelay", "60000") "NSSM restart delay"
    $environmentEntries = @(ConvertTo-NssmEnvironmentArguments (ConvertTo-ServiceEnvironmentMap $config))
    if ($environmentEntries.Count -gt 0) {
        Invoke-CheckedNativeCommand $nssm (@("set", $config.AppName, "AppEnvironmentExtra") + $environmentEntries) "NSSM environment"
    }
    Invoke-CheckedNativeCommand "sc.exe" @("config", $config.AppName, "start=", "auto") "Set NSSM startup mode"
    Invoke-CheckedNativeCommand "sc.exe" @("failure", $config.AppName, "reset=", "86400", "actions=", "restart/60000/restart/60000/restart/300000") "Set NSSM recovery actions"
    Invoke-CheckedNativeCommand "sc.exe" @("failureflag", $config.AppName, "1") "Enable NSSM recovery actions"
    Invoke-CheckedNativeCommand $nssm @("start", $config.AppName) "NSSM start"

    $service = Get-Service -Name $config.AppName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Test-PostDeployHealth -Config $config
    Write-Host "Installed NSSM service: $($config.AppName)" -ForegroundColor Green
}
