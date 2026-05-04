<#
.SYNOPSIS
  Friendly Windows managed-backup rollback entrypoint.
.DESCRIPTION
  Lists or restores backups created by this kit for WinSW files, IIS
  web.config, and the scheduled health-check task. It does not restore
  databases or application release artifacts.
.EXAMPLE
  .\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.EXAMPLE
  .\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest -RecycleIisAppPool
.EXAMPLE
  .\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [ValidateSet("All", "ServiceExe", "ServiceXml", "IisWebConfig", "HealthCheckTask")] [string] $Target = "All",
    [switch] $List,
    [switch] $Latest,
    [string] $BackupPath = "",
    [switch] $RestartService,
    [switch] $RecycleIisAppPool
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$restoreScript = Join-Path $repoRoot "scripts\windows\Restore-ManagedBackup.ps1"

if (-not (Test-Path $restoreScript)) {
    throw "Restore script not found: $restoreScript"
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$restoreArgs = @{
    ConfigPath = $ConfigPath
    Target = $Target
}
if ($List) { $restoreArgs.List = $true }
if ($Latest) { $restoreArgs.Latest = $true }
if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $restoreArgs.BackupPath = $BackupPath }
if ($RestartService) { $restoreArgs.RestartService = $true }
if ($RecycleIisAppPool) { $restoreArgs.RecycleIisAppPool = $true }

if ($WhatIfPreference) {
    & $restoreScript @restoreArgs -WhatIf
} else {
    & $restoreScript @restoreArgs
}
