. (Join-Path $PSScriptRoot 'WindowsPm2ExecutionPolicy.ps1')
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')
if (-not (Get-Variable -Name AppPackageDirectoryRecoverySucceeded -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AppPackageDirectoryRecoverySucceeded = $true
}

function Get-AppPackagePm2State {
    param(
        [string]$Name,
        [string]$CommandName = "",
        [string]$Pm2HomePath = ""
    )
    Assert-WindowsPm2DeploymentAppName -AppName $Name

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
        if (-not $pm2) { throw "PM2 is required to manage the running app during package import." }
        $CommandName = if ([string]::IsNullOrWhiteSpace([string]$pm2.Source)) { $pm2.Name } else { $pm2.Source }
    }

    $previousHome = $env:PM2_HOME
    try {
        if ($Pm2HomePath) { $env:PM2_HOME = $Pm2HomePath }
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $Pm2HomePath
        $output = @(& $CommandName jlist 2>&1)
    } finally { $env:PM2_HOME = $previousHome }
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query PM2 state before package import."
    }
    try {
        $entries = @(ConvertFrom-WindowsPm2ProcessJson -Json ($output -join "`n"))
    }
    catch {
        throw "PM2 returned invalid process state JSON before package import."
    }
    $entry = @($entries | Where-Object {
        if ($null -eq $_) { return $false }
        $nameProperty = $_.PSObject.Properties["name"]
        $null -ne $nameProperty -and [string]$nameProperty.Value -ceq $Name
    })
    $processIds = @(Get-WindowsPm2ExactProcessIds -Entries $entries -AppName $Name)
    $status = ""
    if ($entry.Count -gt 0) {
        $pm2EnvironmentProperty = $entry[0].PSObject.Properties["pm2_env"]
        if ($null -ne $pm2EnvironmentProperty -and $null -ne $pm2EnvironmentProperty.Value) {
            $statusProperty = $pm2EnvironmentProperty.Value.PSObject.Properties["status"]
            if ($null -ne $statusProperty) {
                $status = ([string]$statusProperty.Value).ToLowerInvariant()
            }
        }
    }
    $runningStatuses = @("online", "launching", "stopping", "waiting restart", "one-launch-status")
    return [pscustomobject]@{
        Kind = "pm2"
        Name = $Name
        CommandName = $CommandName
        Home = $Pm2HomePath
        Exists = ($entry.Count -gt 0)
        WasRunning = (@($entry | Where-Object { [string]$_.pm2_env.status -in $runningStatuses }).Count -gt 0)
        Status = $status
        ProcessIds = @($processIds)
    }
}

function Get-AppPackageServiceState {
    param($Config)
    Assert-WindowsDeploymentConfigIdentity -Config $Config

    $name = [string]$Config.AppName
    $manager = ([string]$Config.ServiceManager).ToLowerInvariant()
    if ($manager -eq "pm2") {
        if ($Config.PSObject.Properties['PM2Home'] -or $Config.PSObject.Properties['PM2Command']) {
            if (-not (Get-Command Get-WindowsPm2RuntimeContext -ErrorAction SilentlyContinue)) {
                . (Join-Path $PSScriptRoot "WindowsServiceSecurity.ps1")
            }
            $context = Get-WindowsPm2RuntimeContext -Config $Config
            return Get-AppPackagePm2State -Name $name -CommandName $context.CommandName -Pm2HomePath $context.Home
        }
        return Get-AppPackagePm2State -Name $name
    }
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Kind = "windows-service"
            Name = $name
            CommandName = ""
            Exists = $false
            WasRunning = $false
            Status = "unavailable"
        }
    }

    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    $status = if ($service) { [string]$service.Status } else { "" }
    return [pscustomobject]@{
        Kind = "windows-service"
        Name = $name
        CommandName = ""
        Exists = ($null -ne $service)
        WasRunning = ($null -ne $service -and $status -ne "Stopped")
        Status = $status
    }
}

function Wait-AppPackageWindowsServiceState {
    param(
        [string]$Name,
        [string]$DesiredStatus,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and [string]$service.Status -eq $DesiredStatus) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Service '$Name' did not reach state '$DesiredStatus' within $TimeoutSeconds seconds."
}

function Stop-AppPackageService {
    param($State)

    if (-not $State.WasRunning) { return }
    Write-Host "Stopping service before package import: $($State.Name)"
    if ($State.Kind -eq "pm2") {
        Assert-WindowsPm2DeploymentAppName -AppName ([string]$State.Name)
        $before = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $(if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' })
        if (-not $before.Exists -or @($before.ProcessIds).Count -eq 0) { throw 'Exact managed PM2 process is missing; stop refused.' }
        $previousHome = $env:PM2_HOME
        $pm2HomePath = if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' }
        try {
            if ($pm2HomePath) { $env:PM2_HOME = $pm2HomePath }
            foreach ($pm2Id in @($before.ProcessIds)) {
                Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2HomePath
                & $State.CommandName stop ([string]$pm2Id) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "PM2 failed to stop exact process ID $pm2Id." }
            }
        } finally { $env:PM2_HOME = $previousHome }
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to stop '$($State.Name)' before package import." }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $pm2HomePath
        if ($current.WasRunning) { throw "PM2 app '$($State.Name)' is still running after the stop command." }
        return
    }

    if (-not (Get-Command Stop-Service -ErrorAction SilentlyContinue)) {
        throw "Stop-Service cmdlet is required to stop the running service before package import."
    }
    Stop-Service -Name $State.Name -Force -ErrorAction Stop
    Wait-AppPackageWindowsServiceState -Name $State.Name -DesiredStatus "Stopped"
}

function Start-AppPackageServiceAfterFailure {
    param($State)

    if (-not $State.WasRunning) { return }
    Write-Warning "Restarting the previous service after package import failure: $($State.Name)"
    if ($State.Kind -eq "pm2") {
        Assert-WindowsPm2DeploymentAppName -AppName ([string]$State.Name)
        $before = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $(if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' })
        if (-not $before.Exists -or @($before.ProcessIds).Count -eq 0) { throw 'Exact managed PM2 process is missing; restart refused.' }
        $previousHome = $env:PM2_HOME
        $pm2HomePath = if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' }
        try {
            if ($pm2HomePath) { $env:PM2_HOME = $pm2HomePath }
            foreach ($pm2Id in @($before.ProcessIds)) {
                Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2HomePath
                & $State.CommandName restart ([string]$pm2Id) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "PM2 failed to restart exact process ID $pm2Id." }
            }
        } finally { $env:PM2_HOME = $previousHome }
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to restart '$($State.Name)' after package import failure." }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $pm2HomePath
        if (-not $current.WasRunning) { throw "PM2 app '$($State.Name)' did not return to a running state." }
        return
    }

    if (-not (Get-Command Start-Service -ErrorAction SilentlyContinue)) {
        throw "Start-Service cmdlet is required to recover the previous service after package import failure."
    }
    Start-Service -Name $State.Name -ErrorAction Stop
    Wait-AppPackageWindowsServiceState -Name $State.Name -DesiredStatus "Running"
}

function Restore-AppPackageDirectoryFromBackup {
    param(
        [string]$AppDirectory,
        [string]$BackupPath,
        [bool]$PreviousAppExisted
    )

    $appPath = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\', '/')
    $appRoot = [System.IO.Path]::GetPathRoot($appPath).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($appPath) -or $appPath.Equals($appRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to restore an empty or filesystem-root AppDirectory."
    }
    if ($PreviousAppExisted) {
        if ([string]::IsNullOrWhiteSpace($BackupPath) -or -not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
            throw "Previous AppDirectory backup is missing; the failed deployment was left stopped."
        }
        $resolvedBackupPath = [System.IO.Path]::GetFullPath($BackupPath).TrimEnd('\', '/')
        if ($resolvedBackupPath.Equals($appPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolvedBackupPath.StartsWith($appPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Previous AppDirectory backup must not be AppDirectory or a child of it."
        }
    }
    if (Test-Path -LiteralPath $appPath) {
        Remove-Item -LiteralPath $appPath -Recurse -Force -ErrorAction Stop
    }
    if ($PreviousAppExisted) {
        Move-Item -LiteralPath $BackupPath -Destination $appPath -Force -ErrorAction Stop
    }
}

function Assert-AppPackageDeploymentTransactionState {
    param(
        [Parameter(Mandatory=$true)] $Config,
        [Parameter(Mandatory=$true)] $TransactionState
    )

    foreach ($propertyName in @(
        "schema", "appName", "appDirectory", "backupPath", "previousAppExisted",
        "serviceKind", "serviceName", "serviceCommandName", "serviceExisted", "serviceWasRunning"
    )) {
        if (-not $TransactionState.PSObject.Properties[$propertyName]) {
            throw "Package transaction state is missing '$propertyName'."
        }
    }
    if ([string]$TransactionState.schema -ne "node-enterprise-deploy-kit/package-transaction/v1") {
        throw "Unsupported package transaction state schema."
    }
    if ($TransactionState.PSObject.Properties['phase'] -and [string]$TransactionState.phase -notin @('prepared', 'replacement-ready')) {
        throw 'Unsupported package transaction phase.'
    }
    foreach ($propertyName in @("previousAppExisted", "serviceExisted", "serviceWasRunning")) {
        if ($TransactionState.$propertyName -isnot [bool]) {
            throw "Package transaction state '$propertyName' must be a JSON boolean."
        }
    }
    if ([bool]$TransactionState.serviceWasRunning -and -not [bool]$TransactionState.serviceExisted) {
        throw "Package transaction state cannot mark a missing service as previously running."
    }

    $expectedAppName = [string]$Config.AppName
    if ([string]::IsNullOrWhiteSpace($expectedAppName) -or [string]$TransactionState.appName -cne $expectedAppName) {
        throw "Package transaction state AppName does not match the deployment config."
    }
    if ([string]$TransactionState.serviceName -cne $expectedAppName) {
        throw "Package transaction state service name does not match the deployment config."
    }

    $expectedAppDirectory = [System.IO.Path]::GetFullPath([string]$Config.AppDirectory).TrimEnd('\', '/')
    $stateAppDirectory = [System.IO.Path]::GetFullPath([string]$TransactionState.appDirectory).TrimEnd('\', '/')
    if (-not $stateAppDirectory.Equals($expectedAppDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Package transaction state AppDirectory does not match the deployment config."
    }

    $deploymentMode = ([string]$Config.DeploymentMode).Trim().ToLowerInvariant().Replace("_", "-")
    $serviceManager = ([string]$Config.ServiceManager).Trim().ToLowerInvariant()
    $expectedKind = if ($deploymentMode -eq "static-iis") { "none" } elseif ($serviceManager -eq "pm2") { "pm2" } else { "windows-service" }
    if ([string]$TransactionState.serviceKind -ne $expectedKind) {
        throw "Package transaction state service kind does not match the deployment config."
    }
    if ($expectedKind -eq "none" -and ([bool]$TransactionState.serviceExisted -or [bool]$TransactionState.serviceWasRunning)) {
        throw "Static IIS package transaction state must not contain a service state."
    }

    $previousAppExisted = [bool]$TransactionState.previousAppExisted
    $backupPath = [string]$TransactionState.backupPath
    if ($previousAppExisted -and [string]::IsNullOrWhiteSpace($backupPath)) {
        throw "Package transaction state is missing the previous AppDirectory backup path."
    }
    if (-not $previousAppExisted -and -not [string]::IsNullOrWhiteSpace($backupPath)) {
        throw "Package transaction state contains an unexpected backup path."
    }
    if (-not [string]::IsNullOrWhiteSpace($backupPath) -and -not [System.IO.Path]::IsPathRooted($backupPath)) {
        throw "Package transaction state backup path must be absolute."
    }
}

function Remove-NewAppPackageServiceAfterFailure {
    param($State)

    if ($State.Kind -eq "none" -or -not $State.Exists) { return }
    if ($State.Kind -eq "pm2") {
        Assert-WindowsPm2DeploymentAppName -AppName ([string]$State.Name)
        $before = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $(if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' })
        if (-not $before.Exists -or @($before.ProcessIds).Count -eq 0) { throw 'Exact managed PM2 process is missing; rollback deletion refused.' }
        $previousHome = $env:PM2_HOME
        $pm2HomePath = if ($State.PSObject.Properties['Home']) { [string]$State.Home } else { '' }
        try {
            if ($pm2HomePath) { $env:PM2_HOME = $pm2HomePath }
            foreach ($pm2Id in @($before.ProcessIds)) {
                Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2HomePath
                & $State.CommandName delete ([string]$pm2Id) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "PM2 failed to remove exact process ID $pm2Id after deployment failure." }
            }
            Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2HomePath
            & $State.CommandName save --force | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "PM2 failed to save the process list after deployment rollback." }
        } finally { $env:PM2_HOME = $previousHome }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName -Pm2HomePath $pm2HomePath
        if ($current.Exists) { throw "New PM2 app is still registered after deployment rollback: $($State.Name)" }
        return
    }

    & sc.exe delete $State.Name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not remove the newly created Windows service after deployment failure."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-Service -Name $State.Name -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name $State.Name -ErrorAction SilentlyContinue) {
        throw "New Windows service is still registered after deployment rollback: $($State.Name)"
    }
}

function Invoke-AppPackageDeploymentRollback {
    param(
        [Parameter(Mandatory=$true)] $Config,
        [Parameter(Mandatory=$true)] $TransactionState,
        [scriptblock] $BeforeServiceRecovery
    )

    Assert-AppPackageDeploymentTransactionState -Config $Config -TransactionState $TransactionState

    $previousState = [pscustomobject]@{
        Kind = [string]$TransactionState.ServiceKind
        Name = [string]$TransactionState.ServiceName
        CommandName = [string]$TransactionState.ServiceCommandName
        Home = $(if ($Config.PSObject.Properties['PM2Home']) { [string]$Config.PM2Home } else { '' })
        Exists = [bool]$TransactionState.ServiceExisted
        WasRunning = [bool]$TransactionState.ServiceWasRunning
        Status = ""
    }
    $currentState = if ($previousState.Kind -eq "none") {
        [pscustomobject]@{ Kind = "none"; Name = $previousState.Name; CommandName = ""; Exists = $false; WasRunning = $false; Status = "" }
    } else {
        Get-AppPackageServiceState -Config $Config
    }

    if ($currentState.WasRunning) {
        Stop-AppPackageService -State $currentState
    }
    try {
        $prepared = $TransactionState.PSObject.Properties['phase'] -and [string]$TransactionState.phase -eq 'prepared'
        if ($prepared -and [bool]$TransactionState.PreviousAppExisted -and -not (Test-Path -LiteralPath $TransactionState.BackupPath)) {
            if (-not (Test-Path -LiteralPath $TransactionState.AppDirectory -PathType Container)) {
                throw 'Prepared package recovery has neither the original app nor its backup.'
            }
            # The atomic move did not happen, or the importer already restored
            # the old app. Never remove that previous directory in this case.
        } else {
            Restore-AppPackageDirectoryFromBackup `
                -AppDirectory ([string]$TransactionState.AppDirectory) `
                -BackupPath ([string]$TransactionState.BackupPath) `
                -PreviousAppExisted ([bool]$TransactionState.PreviousAppExisted)
        }
    }
    catch {
        throw "$($_.Exception.Message) The service was intentionally left stopped."
    }

    if ($BeforeServiceRecovery) { & $BeforeServiceRecovery }
    if ($BeforeServiceRecovery) {
        Write-Warning "Managed runtime configuration and service state restored before package recovery completed."
    } elseif ($previousState.Exists) {
        if ($previousState.WasRunning) {
            Start-AppPackageServiceAfterFailure -State $previousState
        }
    } else {
        Remove-NewAppPackageServiceAfterFailure -State $currentState
    }
    Write-Warning "Rolled back the application package after a downstream deployment failure."
}

function Invoke-AppPackageDirectoryReplacement {
    param(
        [string]$SourceRoot,
        [string]$AppDirectory,
        [string]$BackupDirectory,
        [scriptblock]$WriteManifest,
        [scriptblock]$WritePreparedState,
        [switch]$RedactBackupPath
    )

    $appPath = [System.IO.Path]::GetFullPath($AppDirectory).TrimEnd('\', '/')
    $backupRoot = [System.IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\', '/')
    if ($backupRoot.Equals($appPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $backupRoot.StartsWith($appPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "BackupDirectory must not be inside AppDirectory when importing packages."
    }

    $backupPath = ""
    $movedPreviousApp = $false
    $createdReplacement = $false
    $script:AppPackageDirectoryRecoverySucceeded = $true
    try {
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $appPath) | Out-Null
        $previousAppExists = Test-Path -LiteralPath $appPath
        if ($previousAppExists) {
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
            $backupPath = Join-Path $backupRoot ("app.{0}.{1}.{2}.bak" -f $timestamp, $PID, [Guid]::NewGuid().ToString('N'))
        }
        if ($WritePreparedState) { & $WritePreparedState $backupPath }
        if ($previousAppExists) {
            [IO.Directory]::Move($appPath, $backupPath)
            $movedPreviousApp = $true
            if ($RedactBackupPath) { Write-Host "Backed up existing AppDirectory." }
            else { Write-Host "Backed up existing AppDirectory to: $backupPath" }
        }

        New-Item -ItemType Directory -Force -Path $appPath | Out-Null
        $createdReplacement = $true
        foreach ($item in Get-ChildItem -LiteralPath $SourceRoot -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $appPath -Recurse -Force
        }
        & $WriteManifest
        return $backupPath
    }
    catch {
        $originalError = $_
        $recoveryErrors = New-Object System.Collections.Generic.List[string]
        if ($createdReplacement -and (Test-Path -LiteralPath $appPath)) {
            try { Remove-Item -LiteralPath $appPath -Recurse -Force -ErrorAction Stop }
            catch { $recoveryErrors.Add("Could not remove partial AppDirectory: $($_.Exception.Message)") }
        }
        if ($movedPreviousApp -and (Test-Path -LiteralPath $backupPath)) {
            try {
                Move-Item -LiteralPath $backupPath -Destination $appPath -Force -ErrorAction Stop
                Write-Warning "Restored previous AppDirectory after package import failure."
            }
            catch { $recoveryErrors.Add("Could not restore previous AppDirectory: $($_.Exception.Message)") }
        }
        if ($recoveryErrors.Count -gt 0) {
            $script:AppPackageDirectoryRecoverySucceeded = $false
            throw "$($originalError.Exception.Message) Recovery also failed: $($recoveryErrors -join ' ')"
        }
        throw $originalError
    }
}
