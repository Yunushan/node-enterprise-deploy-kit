<#
.SYNOPSIS
  Friendly Windows install entrypoint.
.DESCRIPTION
  Keeps the one-click entrypoint small and delegates the real deployment work
  to deploy.ps1. Values are loaded from the local config file and are not
  printed except for safe operational labels.
.EXAMPLE
  .\install.ps1 -ConfigPath .\config\windows\app.config.json
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [switch] $SkipReverseProxy,
    [switch] $SkipHealthCheck,
    [switch] $SkipPreflight,
    [switch] $AllowPortInUse,
    [switch] $SkipAppPreparation,
    [switch] $SkipInstall,
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$deployScript = Join-Path $repoRoot "deploy.ps1"

if (-not (Test-Path $deployScript)) {
    throw "Deployment script not found: $deployScript"
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy config\windows\app.config.example.json to config\windows\app.config.json first."
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Write-Host "Installing Windows deployment for: $($config.AppName)" -ForegroundColor Cyan
Write-Host "Using local config: $ConfigPath"
Write-Host "Private config values stay local and are not exported by this wrapper."

$deployArgs = @{
    ConfigPath = $ConfigPath
}
if ($SkipReverseProxy) { $deployArgs.SkipReverseProxy = $true }
if ($SkipHealthCheck) { $deployArgs.SkipHealthCheck = $true }
if ($SkipPreflight) { $deployArgs.SkipPreflight = $true }
if ($AllowPortInUse) { $deployArgs.AllowPortInUse = $true }
if ($SkipAppPreparation) { $deployArgs.SkipAppPreparation = $true }
if ($SkipInstall) { $deployArgs.SkipInstall = $true }
if ($SkipBuild) { $deployArgs.SkipBuild = $true }

if ($WhatIfPreference) {
    & $deployScript @deployArgs -WhatIf
} else {
    & $deployScript @deployArgs
}
