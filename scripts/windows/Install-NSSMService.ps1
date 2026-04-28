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
Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$nssm = Join-Path $repoRoot $NssmPath
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
    foreach ($p in $config.Environment.PSObject.Properties) {
      & $nssm set $config.AppName AppEnvironmentExtra "$($p.Name)=$($p.Value)"
    }
    sc.exe failure $config.AppName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
    & $nssm start $config.AppName
}
Write-Host "Installed NSSM service: $($config.AppName)" -ForegroundColor Green
