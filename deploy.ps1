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
    [string] $PackageExpectedSha256 = "",
    [switch] $SkipPackageImport,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe",
    [string] $WinSWDownloadUrl = "",
    [string] $WinSWDownloadSha256 = "",
    [switch] $SkipWinSWDownload,
    [switch] $SkipAppPreparation,
    [switch] $SkipInstall,
    [switch] $SkipBuild,
    [object] $ExistingDeploymentLock,
    [object] $ExistingManagedDeploymentTransaction
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
. (Join-Path $repoRoot "scripts\windows\DeploymentLock.ps1")
Assert-WindowsDeploymentConfigIdentity -Config $config
. (Join-Path $repoRoot "scripts\windows\AppPackageLifecycle.ps1")
. (Join-Path $repoRoot "scripts\windows\DeploymentTransaction.ps1")
$deploymentLock = $null
$ownsDeploymentLock = $false
$packageTransactionStatePath = ""
$preservePackageTransactionState = $false
$managedTransaction = $null
$ownsManagedTransaction = $false
$preserveManagedTransaction = $false
if (-not $WhatIfPreference) {
    Assert-ManagedDeploymentManagerTransition -Config $config
    if ($ExistingDeploymentLock) {
        Assert-ExistingDeploymentLock -Config $config -Lock $ExistingDeploymentLock
        $deploymentLock = $ExistingDeploymentLock
    } else {
        $deploymentLock = Enter-DeploymentLock -Config $config
        $ownsDeploymentLock = $true
    }
}

try {

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
    if (-not [string]::IsNullOrWhiteSpace($PackageExpectedSha256)) { $preflightArgs.PackageExpectedSha256 = $PackageExpectedSha256 }
    if ($SkipPackageImport) { $preflightArgs.SkipPackageImport = $true }
    if ($SkipWinSWDownload) { $preflightArgs.SkipWinSWDownload = $true }
    & (Join-Path $repoRoot "scripts\windows\Test-DeploymentPreflight.ps1") @preflightArgs
}

if (-not $WhatIfPreference) {
    if ($ExistingManagedDeploymentTransaction) {
        Assert-ManagedDeploymentTransaction -Config $config -Transaction $ExistingManagedDeploymentTransaction
        $managedTransaction = $ExistingManagedDeploymentTransaction
    } else {
        $managedTransaction = Start-ManagedDeploymentTransaction -Config $config -Lock $deploymentLock
        $ownsManagedTransaction = $true
    }
    Suspend-ManagedDeploymentServiceState -Config $config -Transaction $managedTransaction
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
        ExistingDeploymentLock = $deploymentLock
        ExistingManagedDeploymentTransaction = $managedTransaction
    }
    $transactionRoot = if ($deploymentLock) { Split-Path -Parent $deploymentLock.Path } else { [System.IO.Path]::GetTempPath() }
    $safeAppName = ([string]$config.AppName) -creplace '[^A-Za-z0-9_.-]', '_'
    $packageTransactionStatePath = Join-Path $transactionRoot "$safeAppName.$PID.package-transaction.json"
    $packageArgs.TransactionStatePath = $packageTransactionStatePath
    if (-not [string]::IsNullOrWhiteSpace($PackageExpectedSha256)) { $packageArgs.PackageExpectedSha256 = $PackageExpectedSha256 }
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
                ExistingDeploymentLock = $deploymentLock
                ExistingManagedDeploymentTransaction = $managedTransaction
            }
            if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadUrl)) { $serviceArgs.WinSWDownloadUrl = $WinSWDownloadUrl }
            if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadSha256)) { $serviceArgs.WinSWDownloadSha256 = $WinSWDownloadSha256 }
            if ($SkipWinSWDownload) { $serviceArgs.SkipWinSWDownload = $true }
            & (Join-Path $repoRoot "scripts\windows\Install-NodeService.ps1") @serviceArgs
        }
        "nssm"  { & (Join-Path $repoRoot "scripts\windows\Install-NSSMService.ps1") -ConfigPath $ConfigPath -ExistingDeploymentLock $deploymentLock -ExistingManagedDeploymentTransaction $managedTransaction }
        "pm2"   { & (Join-Path $repoRoot "scripts\windows\Install-PM2Fallback.ps1") -ConfigPath $ConfigPath -ExistingDeploymentLock $deploymentLock -ExistingManagedDeploymentTransaction $managedTransaction }
        default  { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
    }
}

if (-not $SkipReverseProxy) {
    if ($isStaticIis) {
        $staticIisArgs = @{
            ConfigPath = $ConfigPath
            ExistingDeploymentLock = $deploymentLock
        }
        if ($managedTransaction -and $managedTransaction.PSObject.Properties['IisLockLeasePath'] -and $managedTransaction.IisLockLeasePath) {
            $staticIisArgs.IisDeploymentLockLeasePath = $managedTransaction.IisLockLeasePath
            $staticIisArgs.IisDeploymentLockToken = $managedTransaction.IisLockToken
        }
        if ($WhatIfPreference) {
            & (Join-Path $repoRoot "scripts\windows\Install-IISStaticSite.ps1") @staticIisArgs -WhatIf
        } else {
            & (Join-Path $repoRoot "scripts\windows\Install-IISStaticSite.ps1") @staticIisArgs
        }
    } else {
        $reverseProxyArgs = @{
            ConfigPath = $ConfigPath
            ExistingDeploymentLock = $deploymentLock
        }
        if ($managedTransaction -and $managedTransaction.PSObject.Properties['IisLockLeasePath'] -and $managedTransaction.IisLockLeasePath) {
            $reverseProxyArgs.IisDeploymentLockLeasePath = $managedTransaction.IisLockLeasePath
            $reverseProxyArgs.IisDeploymentLockToken = $managedTransaction.IisLockToken
        }
        if ($WhatIfPreference) {
            & (Join-Path $repoRoot "scripts\windows\Install-ReverseProxy.ps1") @reverseProxyArgs -WhatIf
        } else {
            & (Join-Path $repoRoot "scripts\windows\Install-ReverseProxy.ps1") @reverseProxyArgs
        }
    }
}

if (-not $SkipHealthCheck) {
    & (Join-Path $repoRoot "scripts\windows\Register-HealthCheckTask.ps1") -ConfigPath $ConfigPath -ExistingDeploymentLock $deploymentLock
}

Write-Host "Deployment finished for $($config.AppName)." -ForegroundColor Green
}
catch {
    $deploymentFailure = $_
    if (-not [string]::IsNullOrWhiteSpace($packageTransactionStatePath) -and
        (Test-Path -LiteralPath $packageTransactionStatePath -PathType Leaf)) {
        try {
            $transactionState = Get-Content -LiteralPath $packageTransactionStatePath -Raw | ConvertFrom-Json
            $recovery = if ($managedTransaction) {
                {
                    Restore-ManagedDeploymentTransaction -Config $config -Transaction $managedTransaction
                    if ($ownsManagedTransaction) { Resume-ManagedDeploymentServiceState -Config $config -Transaction $managedTransaction }
                }.GetNewClosure()
            } else { $null }
            Invoke-AppPackageDeploymentRollback -Config $config -TransactionState $transactionState -BeforeServiceRecovery $recovery
        }
        catch {
            $preservePackageTransactionState = $true
            $preserveManagedTransaction = $true
            throw "Deployment failed: $($deploymentFailure.Exception.Message) Rollback also failed: $($_.Exception.Message) Recovery state preserved at: $packageTransactionStatePath $($managedTransaction.Directory)"
        }
    } elseif ($managedTransaction -and $ownsManagedTransaction) {
        try {
            Restore-ManagedDeploymentTransaction -Config $config -Transaction $managedTransaction
            Resume-ManagedDeploymentServiceState -Config $config -Transaction $managedTransaction
        } catch {
            $preserveManagedTransaction = $true
            throw "Deployment failed: $($deploymentFailure.Exception.Message) Configuration rollback also failed: $($_.Exception.Message) Recovery state preserved at: $($managedTransaction.Directory)"
        }
    }
    throw $deploymentFailure
}
finally {
    if ($ownsManagedTransaction -and $managedTransaction -and -not $preserveManagedTransaction) {
        try { Complete-ManagedDeploymentTransaction -Config $config -Transaction $managedTransaction }
        catch { Write-Warning "Could not remove managed recovery journal: $($managedTransaction.Directory)" }
    }
    if (-not $preservePackageTransactionState -and
        -not [string]::IsNullOrWhiteSpace($packageTransactionStatePath) -and
        (Test-Path -LiteralPath $packageTransactionStatePath -PathType Leaf)) {
        try { Remove-Item -LiteralPath $packageTransactionStatePath -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove package transaction state: $packageTransactionStatePath" }
    }
    if ($managedTransaction -and $ownsManagedTransaction) { Release-ManagedIisDeploymentLock -Transaction $managedTransaction }
    if ($ownsDeploymentLock) { Exit-DeploymentLock -Lock $deploymentLock }
}
