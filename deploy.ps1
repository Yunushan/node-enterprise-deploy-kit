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
    [string] $PackagePath = "",
    [switch] $SkipPackageImport,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe",
    [string] $WinSWDownloadUrl = "",
    [string] $WinSWDownloadSha256 = "",
    [switch] $SkipWinSWDownload,
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
function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}
$deploymentMode = Normalize-Name ([string]$config.DeploymentMode)
$isStaticIis = ($deploymentMode -eq "static-iis")

$effectivePackagePath = $PackagePath
if ([string]::IsNullOrWhiteSpace($effectivePackagePath) -and $config.PSObject.Properties["PackagePath"]) {
    $effectivePackagePath = [string]$config.PackagePath
}

if (-not $SkipPreflight) {
    $preflightArgs = @{
        ConfigPath = $ConfigPath
        WinSWPath = $WinSWPath
    }
    if ($SkipReverseProxy) { $preflightArgs.SkipReverseProxy = $true }
    if ($SkipHealthCheck) { $preflightArgs.SkipHealthCheck = $true }
    if ($AllowPortInUse) { $preflightArgs.AllowPortInUse = $true }
    if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadUrl)) { $preflightArgs.WinSWDownloadUrl = $WinSWDownloadUrl }
    if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadSha256)) { $preflightArgs.WinSWDownloadSha256 = $WinSWDownloadSha256 }
    if (-not [string]::IsNullOrWhiteSpace($effectivePackagePath)) { $preflightArgs.PackagePath = $effectivePackagePath }
    if ($SkipPackageImport) { $preflightArgs.SkipPackageImport = $true }
    if ($SkipWinSWDownload) { $preflightArgs.SkipWinSWDownload = $true }
    & (Join-Path $repoRoot "scripts\windows\Test-DeploymentPreflight.ps1") @preflightArgs
}

if (-not $isStaticIis -and [string]$config.ServiceManager -eq "winsw") {
    $winswArgs = @{
        ConfigPath = $ConfigPath
        WinSWPath = $WinSWPath
    }
    if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadUrl)) { $winswArgs.DownloadUrl = $WinSWDownloadUrl }
    if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadSha256)) { $winswArgs.ExpectedSha256 = $WinSWDownloadSha256 }
    if ($SkipWinSWDownload) { $winswArgs.SkipDownload = $true }

    if ($WhatIfPreference) {
        & (Join-Path $repoRoot "scripts\windows\Ensure-WinSW.ps1") @winswArgs -WhatIf
    } else {
        & (Join-Path $repoRoot "scripts\windows\Ensure-WinSW.ps1") @winswArgs
    }
}

if (-not $SkipPackageImport -and -not [string]::IsNullOrWhiteSpace($effectivePackagePath)) {
    $packageArgs = @{
        ConfigPath = $ConfigPath
        PackagePath = $effectivePackagePath
    }
    if ($WhatIfPreference) {
        & (Join-Path $repoRoot "scripts\windows\Import-AppPackage.ps1") @packageArgs -WhatIf
    } else {
        & (Join-Path $repoRoot "scripts\windows\Import-AppPackage.ps1") @packageArgs
    }
}

if (-not $SkipAppPreparation) {
    $prepareArgs = @{
        ConfigPath = $ConfigPath
    }
    if ($SkipInstall) { $prepareArgs.SkipInstall = $true }
    if ($SkipBuild) { $prepareArgs.SkipBuild = $true }
    & (Join-Path $repoRoot "scripts\windows\Invoke-AppPreparation.ps1") @prepareArgs
}

if ($isStaticIis) {
    Write-Host "DeploymentMode=static_iis; skipping Node service installation."
} else {
    switch ($config.ServiceManager) {
        "winsw" {
            $serviceArgs = @{
                ConfigPath = $ConfigPath
                WinSWPath = $WinSWPath
            }
            if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadUrl)) { $serviceArgs.WinSWDownloadUrl = $WinSWDownloadUrl }
            if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadSha256)) { $serviceArgs.WinSWDownloadSha256 = $WinSWDownloadSha256 }
            if ($SkipWinSWDownload) { $serviceArgs.SkipWinSWDownload = $true }
            & (Join-Path $repoRoot "scripts\windows\Install-NodeService.ps1") @serviceArgs
        }
        "nssm"  { & (Join-Path $repoRoot "scripts\windows\Install-NSSMService.ps1") -ConfigPath $ConfigPath }
        "pm2"   { & (Join-Path $repoRoot "scripts\windows\Install-PM2Fallback.ps1") -ConfigPath $ConfigPath }
        default  { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
    }
}

if (-not $SkipReverseProxy) {
    if ($isStaticIis) {
        $staticIisArgs = @{
            ConfigPath = $ConfigPath
        }
        if ($WhatIfPreference) {
            & (Join-Path $repoRoot "scripts\windows\Install-IISStaticSite.ps1") @staticIisArgs -WhatIf
        } else {
            & (Join-Path $repoRoot "scripts\windows\Install-IISStaticSite.ps1") @staticIisArgs
        }
    } else {
        $reverseProxyArgs = @{
            ConfigPath = $ConfigPath
        }
        if ($WhatIfPreference) {
            & (Join-Path $repoRoot "scripts\windows\Install-ReverseProxy.ps1") @reverseProxyArgs -WhatIf
        } else {
            & (Join-Path $repoRoot "scripts\windows\Install-ReverseProxy.ps1") @reverseProxyArgs
        }
    }
}

if (-not $SkipHealthCheck -and -not $isStaticIis) {
    & (Join-Path $repoRoot "scripts\windows\Register-HealthCheckTask.ps1") -ConfigPath $ConfigPath
} elseif (-not $SkipHealthCheck -and $isStaticIis) {
    Write-Host "DeploymentMode=static_iis; skipping Node health-check task."
}

Write-Host "Deployment finished for $($config.AppName)." -ForegroundColor Green
