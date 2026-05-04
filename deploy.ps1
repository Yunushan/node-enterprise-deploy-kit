<#
.SYNOPSIS
  Windows one-command deployment wrapper.
.EXAMPLE
  .\deploy.ps1 -ConfigPath .\config\windows\app.config.json
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

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy config/windows/app.config.example.json first."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $SkipPreflight) {
    $preflightArgs = @{
        ConfigPath = $ConfigPath
    }
    if ($SkipReverseProxy) { $preflightArgs.SkipReverseProxy = $true }
    if ($SkipHealthCheck) { $preflightArgs.SkipHealthCheck = $true }
    if ($AllowPortInUse) { $preflightArgs.AllowPortInUse = $true }
    & (Join-Path $repoRoot "scripts\windows\Test-DeploymentPreflight.ps1") @preflightArgs
}

if (-not $SkipAppPreparation) {
    $prepareArgs = @{
        ConfigPath = $ConfigPath
    }
    if ($SkipInstall) { $prepareArgs.SkipInstall = $true }
    if ($SkipBuild) { $prepareArgs.SkipBuild = $true }
    & (Join-Path $repoRoot "scripts\windows\Invoke-AppPreparation.ps1") @prepareArgs
}

switch ($config.ServiceManager) {
    "winsw" { & (Join-Path $repoRoot "scripts\windows\Install-NodeService.ps1") -ConfigPath $ConfigPath }
    "nssm"  { & (Join-Path $repoRoot "scripts\windows\Install-NSSMService.ps1") -ConfigPath $ConfigPath }
    "pm2"   { & (Join-Path $repoRoot "scripts\windows\Install-PM2Fallback.ps1") -ConfigPath $ConfigPath }
    default  { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
}

if (-not $SkipReverseProxy -and $config.ReverseProxy -eq "iis") {
    & (Join-Path $repoRoot "scripts\windows\Install-IISReverseProxy.ps1") -ConfigPath $ConfigPath
}

if (-not $SkipHealthCheck) {
    & (Join-Path $repoRoot "scripts\windows\Register-HealthCheckTask.ps1") -ConfigPath $ConfigPath
}

Write-Host "Deployment finished for $($config.AppName)." -ForegroundColor Green
