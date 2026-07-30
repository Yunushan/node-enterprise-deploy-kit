if (-not (Get-Variable -Name AppPackageDirectoryRecoverySucceeded -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AppPackageDirectoryRecoverySucceeded = $true
}

function Get-AppPackagePm2State {
    param(
        [string]$Name,
        [string]$CommandName = ""
    )

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        $pm2 = Get-Command pm2 -ErrorAction SilentlyContinue
        if (-not $pm2) { throw "PM2 is required to manage the running app during package import." }
        $CommandName = if ([string]::IsNullOrWhiteSpace([string]$pm2.Source)) { $pm2.Name } else { $pm2.Source }
    }

    $output = @(& $CommandName jlist 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query PM2 state before package import."
    }
    try {
        $entries = @(($output -join "`n") | ConvertFrom-Json)
    }
    catch {
        throw "PM2 returned invalid process state JSON before package import."
    }
    $entry = @($entries | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)
    $status = if ($entry.Count -gt 0 -and $entry[0].pm2_env) { ([string]$entry[0].pm2_env.status).ToLowerInvariant() } else { "" }
    $runningStatuses = @("online", "launching", "stopping", "waiting restart", "one-launch-status")
    return [pscustomobject]@{
        Kind = "pm2"
        Name = $Name
        CommandName = $CommandName
        Exists = ($entry.Count -gt 0)
        WasRunning = ($status -in $runningStatuses)
        Status = $status
    }
}

function Get-AppPackageServiceState {
    param($Config)

    $name = [string]$Config.AppName
    $manager = ([string]$Config.ServiceManager).ToLowerInvariant()
    if ($manager -eq "pm2") {
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
        & $State.CommandName stop $State.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to stop '$($State.Name)' before package import." }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName
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
        & $State.CommandName restart $State.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to restart '$($State.Name)' after package import failure." }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName
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
        & $State.CommandName delete $State.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to remove the newly created app after deployment failure." }
        & $State.CommandName save | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "PM2 failed to save the process list after deployment rollback." }
        $current = Get-AppPackagePm2State -Name $State.Name -CommandName $State.CommandName
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
        [Parameter(Mandatory=$true)] $TransactionState
    )

    Assert-AppPackageDeploymentTransactionState -Config $Config -TransactionState $TransactionState

    $previousState = [pscustomobject]@{
        Kind = [string]$TransactionState.ServiceKind
        Name = [string]$TransactionState.ServiceName
        CommandName = [string]$TransactionState.ServiceCommandName
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
        Restore-AppPackageDirectoryFromBackup `
            -AppDirectory ([string]$TransactionState.AppDirectory) `
            -BackupPath ([string]$TransactionState.BackupPath) `
            -PreviousAppExisted ([bool]$TransactionState.PreviousAppExisted)
    }
    catch {
        throw "$($_.Exception.Message) The service was intentionally left stopped."
    }

    if ($previousState.Exists) {
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
        if (Test-Path -LiteralPath $appPath) {
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
            $backupPath = Join-Path $backupRoot ("app.{0}.{1}.bak" -f $timestamp, $PID)
            Move-Item -LiteralPath $appPath -Destination $backupPath -Force
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
