[CmdletBinding()]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
function Resolve-ConfigPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
$ConfigPath = Resolve-ConfigPath $ConfigPath
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')
Assert-WindowsDeploymentAppName -AppName ([string]$config.AppName)
$expectedSchema = "node-enterprise-deploy-kit/windows-health-monitor/v1"
$allowedProperties = @(
    "Schema",
    "AppName",
    "HealthUrl",
    "LogDirectory",
    "BackupDirectory",
    "DeploymentLockPath",
    "ServiceManager",
    "PM2Home",
    "PM2Command",
    "PM2OwnerSid",
    "RetentionOnly",
    "HealthCheckFailureThreshold",
    "HealthCheckRestartCooldownMinutes",
    "HealthCheckTimeoutSeconds",
    "LogRetentionDays",
    "BackupRetentionDays",
    "DiagnosticRetentionDays"
)
if ([string]$config.Schema -ne $expectedSchema) {
    throw "Health monitor config schema is missing or unsupported. Re-register the managed health-check task."
}
foreach ($property in @($config.PSObject.Properties)) {
    if ([string]$property.Name -notin $allowedProperties) {
        throw "Health monitor config contains an unsupported property. Re-register the managed health-check task."
    }
}
foreach ($required in @("AppName", "HealthUrl", "LogDirectory", "BackupDirectory", "DeploymentLockPath")) {
    if (-not $config.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$config.$required)) {
        throw "Health monitor config is missing a required operational property. Re-register the managed health-check task."
    }
}
$healthUri = [Uri]$config.HealthUrl
$serviceManager = if ($config.PSObject.Properties['ServiceManager']) { [string]$config.ServiceManager } else { 'winsw' }
if ($serviceManager -notin @('winsw', 'nssm', 'pm2', 'static-iis')) { throw 'Unsupported health monitor service manager.' }
if ($serviceManager -eq 'pm2') {
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$config.AppName)
    . (Join-Path $PSScriptRoot 'WindowsPm2ExecutionPolicy.ps1')
    foreach ($name in @('PM2Home', 'PM2Command', 'PM2OwnerSid')) {
        if (-not $config.PSObject.Properties[$name] -or -not $config.$name) { throw 'PM2 monitor context is incomplete; re-register the task.' }
    }
    if (-not [IO.Path]::IsPathRooted([string]$config.PM2Home) -or -not [IO.Path]::IsPathRooted([string]$config.PM2Command)) { throw 'PM2 monitor paths must be absolute.' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne [string]$config.PM2OwnerSid) { throw 'PM2 health monitor is running as the wrong owner.' }
    $env:PM2_HOME = [string]$config.PM2Home
}
if ($healthUri.Scheme -notin @("http", "https") -or -not $healthUri.IsLoopback -or -not [string]::IsNullOrWhiteSpace($healthUri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($healthUri.Query) -or -not [string]::IsNullOrWhiteSpace($healthUri.Fragment)) {
    throw "Health monitor HealthUrl must be a loopback HTTP(S) URL without credentials, query text, or a fragment."
}
foreach ($pathProperty in @("LogDirectory", "BackupDirectory", "DeploymentLockPath")) {
    if (-not [System.IO.Path]::IsPathRooted([string]$config.$pathProperty)) {
        throw "Health monitor $pathProperty must be an absolute path."
    }
}
$healthStateDirectory = Split-Path -Parent $ConfigPath
if ([string]::IsNullOrWhiteSpace($healthStateDirectory) -or -not (Test-Path -LiteralPath $healthStateDirectory -PathType Container)) {
    throw "Protected health monitor state directory was not found. Re-register the managed health-check task."
}
# Hold the same exclusive lock as deployment for the entire check, including
# retention and restart decisions. Checking for a lock file would race with a
# deployment beginning between the check and Start-Service.
$lockParent = Split-Path -Parent ([string]$config.DeploymentLockPath)
if (-not (Test-Path -LiteralPath $lockParent -PathType Container)) {
    throw "Deployment lock directory is missing. Re-register the managed health-check task."
}
foreach ($controlPath in @($lockParent, [string]$config.DeploymentLockPath)) {
    if (Test-Path -LiteralPath $controlPath) {
        if (((Get-Item -LiteralPath $controlPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Health monitor lock paths must not be reparse points."
        }
    }
}
$monitorLock = $null
try {
    $monitorLock = [IO.File]::Open([string]$config.DeploymentLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch [IO.IOException] {
    Write-Output "HEALTHCHECK_SKIPPED_DEPLOYMENT_LOCK"
    exit 0
}
try {
$pendingRecoveryPattern = '^' + [regex]::Escape([string]$config.AppName) + '\.[0-9]+\.(?:managed-transaction\..+|package-transaction\.json)$'
if (@(Get-ChildItem -LiteralPath $lockParent -Force -ErrorAction Stop | Where-Object {
    $_.Name -match $pendingRecoveryPattern
}).Count -gt 0) {
    Write-Output 'HEALTHCHECK_SKIPPED_PENDING_RECOVERY'
    exit 0
}
New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null
$logFile = Join-Path $healthStateDirectory "healthcheck.log"
$stateFile = Join-Path $healthStateDirectory "healthcheck.state.json"
$healthLogMaxBytes = 10MB
$healthLogFileCount = 5
function Rotate-HealthLogIfNeeded {
    if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $logFile).Length -lt $healthLogMaxBytes) { return }
    $oldest = "$logFile.$healthLogFileCount"
    Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue
    for ($index = $healthLogFileCount - 1; $index -ge 1; $index--) {
        $source = "$logFile.$index"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Move-Item -LiteralPath $source -Destination "$logFile.$($index + 1)" -Force
        }
    }
    Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force
}
function Write-HealthLog([string]$Message) {
    Rotate-HealthLogIfNeeded
    "$(Get-Date -Format o) $Message" | Out-File $logFile -Append -Encoding UTF8
}
function Get-ConfigInt($Config, [string]$Name, [int]$Default, [int]$Minimum) {
    if ($Config.PSObject.Properties[$Name] -and $Config.$Name) {
        try { return [Math]::Max($Minimum, [int]$Config.$Name) } catch {}
    }
    return [Math]::Max($Minimum, $Default)
}
function Invoke-Pm2HealthCommand {
    param([string[]]$Arguments)
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$config.AppName)
    Assert-WindowsPm2ExecutionAllowed -Pm2HomePath ([string]$config.PM2Home) -ExpectedOwnerSid ([string]$config.PM2OwnerSid)
    $result = & ([string]$config.PM2Command) @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'PM2 health command failed.' }
    return ($result | Out-String)
}
function Get-ManagedHealthServiceStatus {
    if ($serviceManager -eq 'static-iis') { return 'Running' }
    if ($serviceManager -eq 'pm2') {
        $parsed = @(ConvertFrom-WindowsPm2ProcessJson -Json (Invoke-Pm2HealthCommand @('jlist')))
        $entries = @($parsed | Where-Object { [string]$_.name -ceq [string]$config.AppName })
        if ($entries.Count -eq 0) { throw 'Managed PM2 process is missing.' }
        if (@($entries | Where-Object { [string]$_.pm2_env.status -ne 'online' }).Count -eq 0) { return 'Running' }
        return 'Stopped'
    }
    return [string](Get-Service -Name $config.AppName -ErrorAction Stop).Status
}
function Invoke-ManagedHealthRestart {
    param([switch]$StartStoppedService)
    if ($serviceManager -eq 'static-iis') { throw 'Static IIS monitoring cannot restart a Node service.' }
    if ($serviceManager -eq 'pm2') {
        $parsed = @(ConvertFrom-WindowsPm2ProcessJson -Json (Invoke-Pm2HealthCommand @('jlist')))
        $ids = @(Get-WindowsPm2ExactProcessIds -Entries @($parsed) -AppName ([string]$config.AppName))
        if ($ids.Count -eq 0) { throw 'Exact managed PM2 process is missing; health restart refused.' }
        foreach ($pm2Id in $ids) { [void](Invoke-Pm2HealthCommand @('restart', [string]$pm2Id)) }
        return
    }
    if ($StartStoppedService) { Start-Service -Name $config.AppName -ErrorAction Stop }
    else { Restart-Service -Name $config.AppName -Force -ErrorAction Stop }
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return (Join-Path $Config.ServiceDirectory "backups")
    }
    return ""
}
function Remove-OldFiles {
    param(
        [string]$Path,
        [int]$RetentionDays,
        [string[]]$Include = @("*"),
        [switch]$UseBackupTimestamp,
        [switch]$RequireExclusiveAccess
    )

    if ($RetentionDays -lt 1 -or [string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (-not (Test-HealthRetentionPathNoReparse -Path $Path)) {
        Write-HealthLog "RETENTION_SKIPPED_REPARSE_POINT path='$Path'"
        return
    }
    $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
    Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
        Where-Object {
            $fileName = $_.Name
            $created = $_.LastWriteTime
            if ($UseBackupTimestamp -and $fileName -match '\.(?<stamp>[0-9]{14})\.') {
                try {
                    $created = [DateTime]::ParseExact($Matches.stamp, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
                } catch { return $false }
            }
            $created -lt $cutoff -and @($Include | Where-Object { $fileName -like $_ }).Count -gt 0
        } |
        ForEach-Object {
            $entry = $_
            try {
                if (-not (Test-HealthRetentionPathNoReparse -Path $entry.FullName)) { throw 'Retention file path contains a reparse point.' }
                if ($RequireExclusiveAccess) {
                    # An exclusive handle proves no writer/reader is using the
                    # report; DeleteOnClose avoids a close-then-delete race.
                    $removal = [IO.FileStream]::new($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
                    $removal.Dispose()
                } else { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop }
                Write-HealthLog "RETENTION_REMOVED path='$($entry.FullName)' retentionDays=$RetentionDays"
            } catch {
                Write-HealthLog "RETENTION_REMOVE_FAILED path='$($entry.FullName)' message='$($_.Exception.Message)'"
            }
        }
}
function Test-HealthRetentionPathNoReparse {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $true
}
function Invoke-RetentionCleanup {
    $logRetentionDays = Get-ConfigInt $config "LogRetentionDays" 30 1
    $backupRetentionDays = Get-ConfigInt $config "BackupRetentionDays" 90 1
    $diagnosticRetentionDays = Get-ConfigInt $config "DiagnosticRetentionDays" 14 1
    $backupDirectory = Get-BackupDirectory $config

    # Only archived generations are candidates; deleting an active open log can
    # lose its pathname without releasing disk space.
    Remove-OldFiles -Path $config.LogDirectory -RetentionDays $logRetentionDays -Include @("*.log.*", "*.out.*", "*.err.*")
    # Completed reports use .txt; the collector's active .tmp file is excluded.
    Remove-OldFiles -Path (Join-Path $healthStateDirectory "diagnostics") -RetentionDays $diagnosticRetentionDays -Include @("diagnostics-*.txt") -RequireExclusiveAccess
    # Clean legacy direct files by metadata only, without reading raw reports.
    Remove-OldFiles -Path (Join-Path $config.LogDirectory "diagnostics") -RetentionDays $diagnosticRetentionDays -Include @("diagnostics-*.txt", "*.log") -RequireExclusiveAccess
    $lockDirectory = Split-Path -Parent ([string]$config.DeploymentLockPath)
    $pendingRecovery = @(Get-ChildItem -LiteralPath $lockDirectory -Directory -Filter "$($config.AppName).*.managed-transaction.*" -ErrorAction SilentlyContinue).Count -gt 0
    $pendingRecovery = $pendingRecovery -or @(Get-ChildItem -LiteralPath $lockDirectory -File -Filter "$($config.AppName).*.package-transaction.json" -ErrorAction SilentlyContinue).Count -gt 0
    if ($backupDirectory -and -not $pendingRecovery) {
        Remove-OldFiles -Path $backupDirectory -RetentionDays $backupRetentionDays -Include @("*.bak") -UseBackupTimestamp
        Remove-OldManagedBackupDirectories -Path $backupDirectory -RetentionDays $backupRetentionDays
    } elseif ($pendingRecovery) {
        Write-HealthLog "BACKUP_RETENTION_SKIPPED_PENDING_RECOVERY"
    }
}
function Remove-OldManagedBackupDirectories {
    param([string]$Path, [int]$RetentionDays)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    $parent = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $cutoff = [DateTime]::UtcNow.AddDays(-$RetentionDays)
    foreach ($directory in @(Get-ChildItem -LiteralPath $Path -Directory -Force)) {
        if ($directory.Name -notmatch '^(?:app|static-site)\.(?<stamp>[0-9]{14})\.[A-Za-z0-9.-]+\.bak$') { continue }
        try {
            $created = [DateTime]::ParseExact($Matches.stamp, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
            if ($created -ge $cutoff) { continue }
            $target = [IO.Path]::GetFullPath($directory.FullName)
            if (-not $target.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe backup directory path.' }
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($target)
            while ($pending.Count -gt 0) {
                $entry = Get-Item -LiteralPath $pending.Pop() -Force
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Backup tree contains a reparse point.' }
                if ($entry.PSIsContainer) {
                    foreach ($child in @(Get-ChildItem -LiteralPath $entry.FullName -Force)) { $pending.Push($child.FullName) }
                }
            }
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-HealthLog "RETENTION_REMOVED_MANAGED_BACKUP"
        } catch { Write-HealthLog "RETENTION_BACKUP_DIRECTORY_SKIPPED message='$($_.Exception.Message)'" }
    }
}
function Read-HealthState {
    function Add-MissingStateProperty($State, [string]$Name, $Value) {
        if (-not $State.PSObject.Properties[$Name]) {
            $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        }
    }
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            Add-MissingStateProperty $state "ConsecutiveFailures" 0
            Add-MissingStateProperty $state "LastRestartUtc" $null
            Add-MissingStateProperty $state "LastSuccessUtc" $null
            Add-MissingStateProperty $state "LastFailureUtc" $null
            Add-MissingStateProperty $state "LastCheckUtc" $null
            return $state
        } catch {}
    }
    return [pscustomobject]@{
        ConsecutiveFailures = 0
        LastRestartUtc = $null
        LastSuccessUtc = $null
        LastFailureUtc = $null
        LastCheckUtc = $null
    }
}
function Write-HealthState($State) {
    $temporaryStateFile = "$stateFile.$PID.tmp"
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryStateFile -Encoding UTF8
        Move-Item -LiteralPath $temporaryStateFile -Destination $stateFile -Force
    } finally {
        Remove-Item -LiteralPath $temporaryStateFile -Force -ErrorAction SilentlyContinue
    }
}
function Reset-HealthState {
    param([switch]$MarkSuccess)
    $existing = Read-HealthState
    $now = (Get-Date).ToUniversalTime().ToString("o")
    Write-HealthState ([pscustomobject]@{
        ConsecutiveFailures = 0
        LastRestartUtc = $existing.LastRestartUtc
        LastSuccessUtc = if ($MarkSuccess) { $now } else { $existing.LastSuccessUtc }
        LastFailureUtc = $existing.LastFailureUtc
        LastCheckUtc = $now
    })
}
function Test-RestartCooldown($State, [int]$CooldownMinutes) {
    if (-not $State.LastRestartUtc) { return $true }
    try {
        $lastRestart = if ($State.LastRestartUtc -is [DateTime]) {
            $State.LastRestartUtc.ToUniversalTime()
        } else {
            [DateTime]::Parse([string]$State.LastRestartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        return ((Get-Date).ToUniversalTime() - $lastRestart).TotalMinutes -ge $CooldownMinutes
    } catch {
        return $true
    }
}
function Restart-AppService([string]$Reason, $State, [int]$CooldownMinutes, [switch]$StartStoppedService) {
    if (-not (Test-RestartCooldown $State $CooldownMinutes)) {
        Write-HealthLog "RESTART_SUPPRESSED_COOLDOWN reason='$Reason' cooldownMinutes=$CooldownMinutes"
        Write-HealthState $State
        return
    }

    # Record the attempt before invoking the manager, so a failing start cannot
    # trigger a restart storm on the next scheduled run.
    $State.LastRestartUtc = (Get-Date).ToUniversalTime().ToString("o")
    $State.LastCheckUtc = $State.LastRestartUtc
    Write-HealthState $State
    Write-HealthLog "RESTARTING_SERVICE reason='$Reason'"
    try {
        Invoke-ManagedHealthRestart -StartStoppedService:$StartStoppedService
        $State.LastCheckUtc = $State.LastRestartUtc
        $State.ConsecutiveFailures = 0
        Write-HealthState $State
    } catch {
        Write-HealthLog "RESTART_FAILED message='$($_.Exception.Message)'"
        Write-HealthState $State
    }
}
function Handle-HttpFailure([string]$Reason) {
    $failureThreshold = Get-ConfigInt $config "HealthCheckFailureThreshold" 2 1
    $cooldownMinutes = Get-ConfigInt $config "HealthCheckRestartCooldownMinutes" 5 1
    $state = Read-HealthState
    $state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1
    $state.LastFailureUtc = (Get-Date).ToUniversalTime().ToString("o")
    $state.LastCheckUtc = $state.LastFailureUtc

    if ([int]$state.ConsecutiveFailures -lt $failureThreshold) {
        Write-HealthLog "FAILED reason='$Reason' consecutiveFailures=$($state.ConsecutiveFailures) threshold=$failureThreshold"
        Write-HealthState $state
        exit 1
    }

    Write-HealthLog "FAILED_THRESHOLD_REACHED reason='$Reason' consecutiveFailures=$($state.ConsecutiveFailures) threshold=$failureThreshold"
    Restart-AppService -Reason $Reason -State $state -CooldownMinutes $cooldownMinutes
    exit 1
}

$timeoutSeconds = Get-ConfigInt $config "HealthCheckTimeoutSeconds" 10 1
Invoke-RetentionCleanup
if ($config.PSObject.Properties['RetentionOnly']) {
    if ($config.RetentionOnly -isnot [bool] -or $serviceManager -ne 'static-iis') { throw 'Invalid retention-only monitor configuration.' }
    if ($config.RetentionOnly) { Write-HealthLog 'RETENTION_ONLY_COMPLETED'; exit 0 }
}
try {
    $serviceStatus = Get-ManagedHealthServiceStatus
    if ($serviceStatus -ne 'Running') {
        $state = Read-HealthState
        Restart-AppService -Reason "SERVICE_NOT_RUNNING status=$serviceStatus" -State $state -CooldownMinutes (Get-ConfigInt $config "HealthCheckRestartCooldownMinutes" 5 1) -StartStoppedService
        exit 2
    }
    $response = Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec $timeoutSeconds -MaximumRedirection 0
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        Write-HealthLog "OK status=$($response.StatusCode) url=$($config.HealthUrl)"
        Reset-HealthState -MarkSuccess
        exit 0
    }
    Handle-HttpFailure "BAD_STATUS status=$($response.StatusCode)"
} catch {
    Handle-HttpFailure "EXCEPTION message='$($_.Exception.Message)'"
}
} finally {
    if ($monitorLock) { $monitorLock.Dispose() }
}
