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
$expectedSchema = "node-enterprise-deploy-kit/windows-health-monitor/v1"
$allowedProperties = @(
    "Schema",
    "AppName",
    "HealthUrl",
    "LogDirectory",
    "BackupDirectory",
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
foreach ($required in @("AppName", "HealthUrl", "LogDirectory", "BackupDirectory")) {
    if (-not $config.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$config.$required)) {
        throw "Health monitor config is missing a required operational property. Re-register the managed health-check task."
    }
}
if ([string]$config.AppName -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Health monitor AppName is invalid."
}
$healthUri = [Uri]$config.HealthUrl
if ($healthUri.Scheme -notin @("http", "https") -or -not $healthUri.IsLoopback -or -not [string]::IsNullOrWhiteSpace($healthUri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($healthUri.Query) -or -not [string]::IsNullOrWhiteSpace($healthUri.Fragment)) {
    throw "Health monitor HealthUrl must be a loopback HTTP(S) URL without credentials, query text, or a fragment."
}
foreach ($pathProperty in @("LogDirectory", "BackupDirectory")) {
    if (-not [System.IO.Path]::IsPathRooted([string]$config.$pathProperty)) {
        throw "Health monitor $pathProperty must be an absolute path."
    }
}
$healthStateDirectory = Split-Path -Parent $ConfigPath
if ([string]::IsNullOrWhiteSpace($healthStateDirectory) -or -not (Test-Path -LiteralPath $healthStateDirectory -PathType Container)) {
    throw "Protected health monitor state directory was not found. Re-register the managed health-check task."
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
        [string[]]$Include = @("*")
    )

    if ($RetentionDays -lt 1 -or [string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $directory = Get-Item -LiteralPath $Path -Force
    if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-HealthLog "RETENTION_SKIPPED_REPARSE_POINT path='$Path'"
        return
    }
    $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
    Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
        Where-Object {
            $fileName = $_.Name
            $_.LastWriteTime -lt $cutoff -and @($Include | Where-Object { $fileName -like $_ }).Count -gt 0
        } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-HealthLog "RETENTION_REMOVED path='$($_.FullName)' retentionDays=$RetentionDays"
            } catch {
                Write-HealthLog "RETENTION_REMOVE_FAILED path='$($_.FullName)' message='$($_.Exception.Message)'"
            }
        }
}
function Invoke-RetentionCleanup {
    $logRetentionDays = Get-ConfigInt $config "LogRetentionDays" 30 1
    $backupRetentionDays = Get-ConfigInt $config "BackupRetentionDays" 90 1
    $diagnosticRetentionDays = Get-ConfigInt $config "DiagnosticRetentionDays" 14 1
    $backupDirectory = Get-BackupDirectory $config

    Remove-OldFiles -Path $config.LogDirectory -RetentionDays $logRetentionDays -Include @("*.log", "*.out", "*.err")
    Remove-OldFiles -Path (Join-Path $config.LogDirectory "diagnostics") -RetentionDays $diagnosticRetentionDays -Include @("*.txt", "*.log")
    if ($backupDirectory) {
        Remove-OldFiles -Path $backupDirectory -RetentionDays $backupRetentionDays -Include @("*.bak")
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
        $lastRestart = [DateTime]::Parse([string]$State.LastRestartUtc).ToUniversalTime()
        return ((Get-Date).ToUniversalTime() - $lastRestart).TotalMinutes -ge $CooldownMinutes
    } catch {
        return $true
    }
}
function Restart-AppService([string]$Reason, $State, [int]$CooldownMinutes) {
    if (-not (Test-RestartCooldown $State $CooldownMinutes)) {
        Write-HealthLog "RESTART_SUPPRESSED_COOLDOWN reason='$Reason' cooldownMinutes=$CooldownMinutes"
        Write-HealthState $State
        return
    }

    Write-HealthLog "RESTARTING_SERVICE reason='$Reason'"
    try {
        Restart-Service -Name $config.AppName -Force -ErrorAction Stop
        $State.LastRestartUtc = (Get-Date).ToUniversalTime().ToString("o")
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
try {
    $svc = Get-Service -Name $config.AppName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-HealthLog "SERVICE_NOT_RUNNING status=$($svc.Status); starting service"
        Start-Service -Name $config.AppName
        Start-Sleep -Seconds 5
        Reset-HealthState
        exit 2
    }
    $response = Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec $timeoutSeconds -MaximumRedirection 0
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
        Write-HealthLog "OK status=$($response.StatusCode) url=$($config.HealthUrl)"
        Reset-HealthState -MarkSuccess
        exit 0
    }
    Handle-HttpFailure "BAD_STATUS status=$($response.StatusCode)"
} catch {
    Handle-HttpFailure "EXCEPTION message='$($_.Exception.Message)'"
}
