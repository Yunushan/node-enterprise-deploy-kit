Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot "scripts\windows\DeploymentLock.ps1")
. (Join-Path $repoRoot "scripts\windows\DeploymentTransaction.ps1")
. (Join-Path $repoRoot "scripts\windows\AppPackageLifecycle.ps1")
$root = Join-Path $repoRoot (".tmp\managed-transaction-" + [Guid]::NewGuid().ToString("N"))
$lock = $null
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $packageApp = Join-Path $root 'package-app'
    $packageSource = Join-Path $root 'package-source'
    $packageBackups = Join-Path $root 'package-backups'
    New-Item -ItemType Directory -Path $packageApp, $packageSource -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $packageApp 'version.txt'), 'v1')
    [IO.File]::WriteAllText((Join-Path $packageSource 'version.txt'), 'v2')
    function Get-Date { return [DateTime]::Parse('2026-10-07T08:00:00Z').ToUniversalTime() }
    try {
        $firstBackup = Invoke-AppPackageDirectoryReplacement -SourceRoot $packageSource -AppDirectory $packageApp -BackupDirectory $packageBackups -WriteManifest {}
        [IO.File]::WriteAllText((Join-Path $packageSource 'version.txt'), 'v3')
        $secondBackup = Invoke-AppPackageDirectoryReplacement -SourceRoot $packageSource -AppDirectory $packageApp -BackupDirectory $packageBackups -WriteManifest {}
    } finally { Remove-Item -LiteralPath Function:Get-Date }
    if ($firstBackup -eq $secondBackup -or [IO.File]::ReadAllText((Join-Path $firstBackup 'version.txt')) -ne 'v1' -or
        [IO.File]::ReadAllText((Join-Path $secondBackup 'version.txt')) -ne 'v2' -or [IO.File]::ReadAllText((Join-Path $packageApp 'version.txt')) -ne 'v3') {
        throw 'Two imports in the same process and second overwrote an earlier backup.'
    }
    $walConfig = [pscustomobject]@{ AppName = 'package-wal'; DeploymentMode = 'static_iis'; ServiceManager = 'winsw'; AppDirectory = $packageApp }
    $preparedState = [pscustomobject]@{
        schema = 'node-enterprise-deploy-kit/package-transaction/v1'; phase = 'prepared'; appName = 'package-wal'; appDirectory = $packageApp
        backupPath = Join-Path $packageBackups 'planned.bak'; previousAppExisted = $true
        serviceKind = 'none'; serviceName = 'package-wal'; serviceCommandName = ''; serviceExisted = $false; serviceWasRunning = $false
    }
    $recordedBackup = ''
    $walWriter = {
        param($PlannedBackup)
        if ([IO.File]::ReadAllText((Join-Path $packageApp 'version.txt')) -ne 'v3' -or (Test-Path -LiteralPath $PlannedBackup)) {
            throw 'Windows write-ahead callback ran after moving the previous app.'
        }
        $script:plannedWalBackup = $PlannedBackup
        $preparedState.backupPath = $PlannedBackup
    }
    $recordedBackup = Invoke-AppPackageDirectoryReplacement -SourceRoot $packageSource -AppDirectory $packageApp -BackupDirectory $packageBackups -WriteManifest {} -WritePreparedState $walWriter
    if ($recordedBackup -ne $script:plannedWalBackup) { throw 'Windows WAL recorded a different backup path.' }
    Invoke-AppPackageDeploymentRollback -Config $walConfig -TransactionState $preparedState
    if ([IO.File]::ReadAllText((Join-Path $packageApp 'version.txt')) -ne 'v3') { throw 'Prepared rollback failed after the move.' }
    # Repeating recovery after the importer already consumed its backup must
    # preserve the original app instead of deleting it.
    Invoke-AppPackageDeploymentRollback -Config $walConfig -TransactionState $preparedState
    if ([IO.File]::ReadAllText((Join-Path $packageApp 'version.txt')) -ne 'v3') { throw 'Prepared recovery deleted the restored original app.' }
    $stateRejected = $false
    try { Invoke-AppPackageDirectoryReplacement -SourceRoot $packageSource -AppDirectory $packageApp -BackupDirectory $packageBackups -WriteManifest {} -WritePreparedState { throw 'Injected WAL persistence failure' } | Out-Null }
    catch { $stateRejected = $_.Exception.Message -match 'Injected WAL persistence failure' }
    if (-not $stateRejected -or [IO.File]::ReadAllText((Join-Path $packageApp 'version.txt')) -ne 'v3') { throw 'Failed WAL persistence changed the original app.' }
    $config = [pscustomobject]@{
        AppName = "transaction-test"; ServiceDirectory = Join-Path $root "service"
        AppDirectory = Join-Path $root "app"; IisSitePath = Join-Path $root "site"
        DeploymentLockDirectory = Join-Path $root "locks"; ServiceManager = "winsw"
    }
    New-Item -ItemType Directory -Path $config.ServiceDirectory, $config.IisSitePath -Force | Out-Null
    $serviceXml = Join-Path $config.ServiceDirectory "$($config.AppName).xml"
    $proxyConfig = Join-Path $config.IisSitePath "web.config"
    $ecosystem = Join-Path $config.ServiceDirectory "$($config.AppName).pm2.config.cjs"
    [IO.File]::WriteAllText($serviceXml, "previous runtime")
    [IO.File]::WriteAllText($proxyConfig, "previous proxy")
    $lock = Enter-DeploymentLock -Config $config -SkipAclHardening
    $transaction = Start-ManagedDeploymentTransaction -Config $config -Lock $lock -SkipHostState -SkipAclHardening
    [IO.File]::WriteAllText($serviceXml, "new runtime")
    [IO.File]::WriteAllText($proxyConfig, "new proxy")
    [IO.File]::WriteAllText($ecosystem, "new definition")
    Restore-ManagedDeploymentTransaction -Config $config -Transaction $transaction
    if ([IO.File]::ReadAllText($serviceXml) -ne "previous runtime" -or [IO.File]::ReadAllText($proxyConfig) -ne "previous proxy") {
        throw "Managed configuration rollback did not restore previous bytes."
    }
    if (Test-Path -LiteralPath $ecosystem) { throw "New runtime definition survived rollback." }
    Complete-ManagedDeploymentTransaction -Config $config -Transaction $transaction
    if (Test-Path -LiteralPath $transaction.Directory) { throw "Completed journal was retained." }
    $transaction = Start-ManagedDeploymentTransaction -Config $config -Lock $lock -SkipHostState -SkipAclHardening
    [IO.File]::WriteAllText($serviceXml, "failed runtime")
    $snapshot = @($transaction.Files | Where-Object { $_.Path -eq $serviceXml })[0].Snapshot
    Remove-Item -LiteralPath $snapshot -Force
    $failedClosed = $false
    try { Restore-ManagedDeploymentTransaction -Config $config -Transaction $transaction }
    catch { $failedClosed = $_.Exception.Message -match "snapshot is missing" }
    if (-not $failedClosed -or -not (Test-Path -LiteralPath $transaction.Directory)) {
        throw "Missing recovery snapshot did not fail closed and retain journal."
    }
    Write-Host "Managed deployment file recovery and missing-snapshot safety OK"
} finally {
    if ($lock) { Exit-DeploymentLock $lock }
    $resolved = [IO.Path]::GetFullPath($root)
    $allowed = [IO.Path]::GetFullPath((Join-Path $repoRoot ".tmp")).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
