<#
.SYNOPSIS
  Optional NSSM installer. WinSW remains the recommended Windows production default.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $NssmPath = "tools\nssm\nssm.exe"
)

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
Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.ServiceManager -ne "nssm") {
    throw "This installer supports ServiceManager='nssm'. For WinSW/PM2, use the dedicated scripts."
}
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$nssm = Resolve-RepoPath -Path $NssmPath -BasePath $repoRoot
if (-not (Test-Path $nssm)) { throw "NSSM not found at $nssm. Place nssm.exe there or pass -NssmPath." }

New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null

if ($PSCmdlet.ShouldProcess($config.AppName, "Install NSSM service")) {
    & $nssm stop $config.AppName 2>$null
    & $nssm remove $config.AppName confirm 2>$null
    & $nssm install $config.AppName $config.NodeExe
    & $nssm set $config.AppName AppDirectory $config.AppDirectory
    & $nssm set $config.AppName AppParameters "$($config.StartCommand) $($config.NodeArguments)"
    & $nssm set $config.AppName DisplayName $config.DisplayName
    & $nssm set $config.AppName Description $config.Description
    & $nssm set $config.AppName AppStdout (Join-Path $config.LogDirectory "stdout.log")
    & $nssm set $config.AppName AppStderr (Join-Path $config.LogDirectory "stderr.log")
    & $nssm set $config.AppName AppRotateFiles 1
    & $nssm set $config.AppName AppRotateBytes 10485760
    & $nssm set $config.AppName AppRestartDelay 60000
    $environmentEntries = @(ConvertTo-NssmEnvironmentArguments (ConvertTo-ServiceEnvironmentMap $config))
    if ($environmentEntries.Count -gt 0) {
      & $nssm set $config.AppName AppEnvironmentExtra @environmentEntries
    }
    sc.exe config $config.AppName start= auto | Out-Null
    sc.exe failure $config.AppName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
    sc.exe failureflag $config.AppName 1 | Out-Null
    & $nssm start $config.AppName
}
Write-Host "Installed NSSM service: $($config.AppName)" -ForegroundColor Green
