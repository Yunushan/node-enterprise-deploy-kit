<#
.SYNOPSIS
  Friendly Windows uninstall entrypoint.
.DESCRIPTION
  Removes the configured Windows service by delegating to the existing
  scripts/windows/Uninstall-NodeService.ps1 script. The script routes by
  ServiceManager and supports WinSW, NSSM, and PM2 fallback cleanup. It does
  not delete app files, logs, or private config files.
.EXAMPLE
  .\uninstall.ps1 -ConfigPath .\config\windows\app.config.json -RemoveHealthCheckTask
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [string] $NssmPath = "tools\nssm\nssm.exe",
    [switch] $RemoveHealthCheckTask
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$uninstallScript = Join-Path $repoRoot "scripts\windows\Uninstall-NodeService.ps1"

if (-not (Test-Path $uninstallScript)) {
    throw "Uninstall script not found: $uninstallScript"
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$uninstallArgs = @{
    ConfigPath = $ConfigPath
    NssmPath = $NssmPath
}
if ($RemoveHealthCheckTask) { $uninstallArgs.RemoveHealthCheckTask = $true }

if ($WhatIfPreference) {
    & $uninstallScript @uninstallArgs -WhatIf
} else {
    & $uninstallScript @uninstallArgs
}
