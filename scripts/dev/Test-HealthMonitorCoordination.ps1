[CmdletBinding()]
param([switch]$ChildProcess, [string]$FixtureRoot, [string]$Scenario = "stopped")
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($ChildProcess) {
    function Get-Service {
        param($Name, $ErrorAction)
        Add-Content -LiteralPath (Join-Path $FixtureRoot "service-probes.txt") -Value "probe"
        return [pscustomobject]@{ Status = "Stopped" }
    }
    function Start-Service {
        param($Name, $ErrorAction)
        Add-Content -LiteralPath (Join-Path $FixtureRoot "start-attempts.txt") -Value "start"
        if ($Scenario -eq "failed-start") { throw "Injected service start failure" }
    }
    function Restart-Service { throw "Unexpected restart of stopped service" }
    . (Join-Path $repoRoot "scripts\windows\Invoke-NodeHealthCheck.ps1") -ConfigPath (Join-Path $FixtureRoot "monitor.config.json")
    exit $LASTEXITCODE
}
Set-StrictMode -Version Latest
. (Join-Path $repoRoot "scripts\windows\DeploymentLock.ps1")
. (Join-Path $repoRoot "scripts\windows\PostDeployHealth.ps1")
$defaultNative = Get-DeploymentLockDirectory ([pscustomobject]@{ AppName = 'first-install'; ServiceManager = 'winsw'; ServiceDirectory = 'C:\first-service' })
$defaultPm2 = Get-DeploymentLockDirectory ([pscustomobject]@{ AppName = 'first-install'; ServiceManager = 'pm2'; ServiceDirectory = 'C:\other-service' })
if ($defaultNative -ne $defaultPm2) { throw 'Different managers selected different first-install app mutex namespaces.' }
foreach ($invalidName in @('.', '..')) {
    $rejected = $false
    try { Get-DeploymentLockDirectory ([pscustomobject]@{ AppName = $invalidName }) | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Control path identity allowed dot traversal.' }
}
$rejected = $false
try { Get-DeploymentLockDirectory ([pscustomobject]@{ AppName = 'root-lock'; DeploymentLockDirectory = [IO.Path]::GetPathRoot($repoRoot) }) | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Control directory permitted filesystem-root ACL mutation.' }
$script:transientProbeAttempts = 0
Test-PostDeployHealth -Config ([pscustomobject]@{
    HealthUrl = 'http://127.0.0.1:39999/health'; PostDeployHealthAttempts = 2; PostDeployHealthDelaySeconds = 0
}) -Probe {
    param($Uri, $TimeoutSeconds)
    $script:transientProbeAttempts++
    if ($script:transientProbeAttempts -eq 1) { throw 'Injected connection failure without a Response property.' }
    return 200
}
if ($script:transientProbeAttempts -ne 2) { throw 'Post-deploy health did not retry an exception without a Response property.' }
$FixtureRoot = Join-Path $repoRoot (".tmp\health-coordination-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
$shellName = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
if ($env:OS -eq "Windows_NT") { $shellName += ".exe" }
$shellPath = Join-Path $PSHOME $shellName
$lock = $null
try {
    $lockConfig = [pscustomobject]@{ AppName = "coordination-test"; DeploymentLockDirectory = $FixtureRoot }
    $lock = Enter-DeploymentLock -Config $lockConfig -SkipAclHardening
    Assert-ExistingDeploymentLock -Config $lockConfig -Lock $lock
    $monitorConfig = [ordered]@{
        Schema = "node-enterprise-deploy-kit/windows-health-monitor/v1"
        AppName = $lockConfig.AppName; DeploymentLockPath = $lock.Path
        HealthUrl = "http://127.0.0.1:39999/health"
        LogDirectory = Join-Path $FixtureRoot "logs"
        BackupDirectory = Join-Path $FixtureRoot "backups"
        HealthCheckFailureThreshold = 1; HealthCheckRestartCooldownMinutes = 60
        HealthCheckTimeoutSeconds = 1; LogRetentionDays = 30; BackupRetentionDays = 90; DiagnosticRetentionDays = 14
    }
    $monitorConfig | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $FixtureRoot "monitor.config.json") -Encoding UTF8
    $output = & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ChildProcess -FixtureRoot $FixtureRoot 2>&1
    if ($LASTEXITCODE -ne 0 -or ($output -join '') -notmatch 'HEALTHCHECK_SKIPPED_DEPLOYMENT_LOCK') {
        throw "Health monitor did not safely skip a held deployment lock: $output"
    }
    if (Test-Path -LiteralPath (Join-Path $FixtureRoot "service-probes.txt")) { throw "Monitor probed service during deployment." }
    if (Test-Path -LiteralPath (Join-Path $FixtureRoot "healthcheck.state.json")) { throw "Busy monitor mutated health state." }
    Exit-DeploymentLock $lock
    $lock = $null
    foreach ($recoveryName in @('coordination-test.123.managed-transaction.interrupted', 'coordination-test.123.package-transaction.json')) {
        $recoveryPath = Join-Path $FixtureRoot $recoveryName
        [IO.File]::WriteAllText($recoveryPath, 'retained recovery evidence')
        $rejected = $false
        try { $unexpectedLock = Enter-DeploymentLock -Config $lockConfig -SkipAclHardening; Exit-DeploymentLock $unexpectedLock }
        catch { $rejected = $_.Exception.Message -match 'Unresolved deployment recovery state' }
        if (-not $rejected) { throw 'Deployment continued past unresolved recovery state.' }
        $output = & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ChildProcess -FixtureRoot $FixtureRoot 2>&1
        if ($LASTEXITCODE -ne 0 -or ($output -join '') -notmatch 'HEALTHCHECK_SKIPPED_PENDING_RECOVERY') { throw "Monitor did not defer unresolved recovery: $output" }
        if (Test-Path -LiteralPath (Join-Path $FixtureRoot 'service-probes.txt')) { throw 'Monitor probed an application with unresolved recovery.' }
        if (Test-Path -LiteralPath (Join-Path $FixtureRoot 'healthcheck.state.json')) { throw 'Monitor mutated state during unresolved recovery.' }
        if ([IO.File]::ReadAllText($recoveryPath) -ne 'retained recovery evidence') { throw 'Recovery evidence was modified.' }
        Remove-Item -LiteralPath $recoveryPath -Force
    }
    # A different app's recovery must not stop this app's operations.
    $otherRecovery = Join-Path $FixtureRoot 'coordination-test.other-app.123.managed-transaction.interrupted'
    [IO.File]::WriteAllText($otherRecovery, 'other app recovery')
    $lock = Enter-DeploymentLock -Config $lockConfig -SkipAclHardening
    Exit-DeploymentLock $lock; $lock = $null
    Remove-Item -LiteralPath $otherRecovery -Force
    foreach ($scenario in @("stopped", "failed-start")) {
        Remove-Item -LiteralPath (Join-Path $FixtureRoot "start-attempts.txt"), (Join-Path $FixtureRoot "healthcheck.state.json") -Force -ErrorAction SilentlyContinue
        1..2 | ForEach-Object {
            $output = & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ChildProcess -FixtureRoot $FixtureRoot -Scenario $scenario 2>&1
            if ($LASTEXITCODE -notin @(1, 2)) { throw "Unexpected monitor result ($LASTEXITCODE): $output" }
        }
        $attempts = @(Get-Content -LiteralPath (Join-Path $FixtureRoot "start-attempts.txt"))
        if ($attempts.Count -ne 1) {
            $detail = Get-Content -LiteralPath (Join-Path $FixtureRoot "healthcheck.log") -Raw
            throw "Stopped or failing service bypassed cooldown ($scenario), attempts=$($attempts.Count). $detail"
        }
        $state = Get-Content -LiteralPath (Join-Path $FixtureRoot "healthcheck.state.json") -Raw | ConvertFrom-Json
        if (-not $state.LastRestartUtc) { throw "Start attempt was not persisted before service command." }
    }
    $monitorConfig.ServiceManager = 'static-iis'
    $monitorConfig.RetentionOnly = $true
    $monitorConfig | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $FixtureRoot "monitor.config.json") -Encoding UTF8
    New-Item -ItemType Directory -Path $monitorConfig.BackupDirectory -Force | Out-Null
    $oldStamp = [DateTime]::UtcNow.AddDays(-100).ToString('yyyyMMddHHmmss')
    $newStamp = [DateTime]::UtcNow.AddDays(-1).ToString('yyyyMMddHHmmss')
    $oldBackup = Join-Path $monitorConfig.BackupDirectory "app.$oldStamp.123.bak"
    $newBackup = Join-Path $monitorConfig.BackupDirectory "static-site.$newStamp.123.fixture.bak"
    $unknownBackup = Join-Path $monitorConfig.BackupDirectory 'operator-backup.bak'
    New-Item -ItemType Directory -Path $oldBackup, $newBackup, $unknownBackup -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldBackup 'version.txt'), 'old')
    (Get-Item -LiteralPath $newBackup).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-200)
    $pendingRecovery = Join-Path $FixtureRoot 'coordination-test.123.managed-transaction.pending'
    New-Item -ItemType Directory -Path $pendingRecovery | Out-Null
    Remove-Item -LiteralPath (Join-Path $FixtureRoot 'service-probes.txt') -Force -ErrorAction SilentlyContinue
    $output = & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ChildProcess -FixtureRoot $FixtureRoot 2>&1
    if ($LASTEXITCODE -ne 0 -or ($output -join '') -notmatch 'HEALTHCHECK_SKIPPED_PENDING_RECOVERY' -or -not (Test-Path -LiteralPath $oldBackup)) { throw "Pending recovery backup was pruned: $output" }
    Remove-Item -LiteralPath $pendingRecovery
    $output = & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ChildProcess -FixtureRoot $FixtureRoot 2>&1
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $oldBackup) -or -not (Test-Path -LiteralPath $newBackup) -or -not (Test-Path -LiteralPath $unknownBackup)) {
        throw "Directory backup retention did not use managed creation timestamps: $output"
    }
    if (Test-Path -LiteralPath (Join-Path $FixtureRoot 'service-probes.txt')) { throw "Static retention attempted a Node service operation." }

    # Exercise actual manager-dispatch functions without invoking a live daemon.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\windows\Invoke-NodeHealthCheck.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-ManagedHealthServiceStatus', 'Invoke-ManagedHealthRestart') }, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $serviceManager = 'pm2'
    $config = [pscustomobject]@{ AppName = 'coordination-test' }
    $pm2Status = 'online'; $pm2Commands = [Collections.Generic.List[string]]::new()
    function Invoke-Pm2HealthCommand {
        param([string[]]$Arguments)
        $pm2Commands.Add(($Arguments -join ' '))
        if ($Arguments[0] -eq 'jlist') {
            return (ConvertTo-Json -InputObject @([pscustomobject]@{ name = 'coordination-test'; pm_id = 7; pm2_env = @{ name='coordination-test'; status = $pm2Status } }) -Depth 5 -Compress)
        }
        return ''
    }
    if ((Get-ManagedHealthServiceStatus) -ne 'Running') { throw 'PM2 online status was misclassified.' }
    $pm2Status = 'stopped'
    if ((Get-ManagedHealthServiceStatus) -ne 'Stopped') { throw 'PM2 stopped status was misclassified.' }
    Invoke-ManagedHealthRestart -StartStoppedService
    if ($pm2Commands[$pm2Commands.Count - 1] -ne 'restart 7') { throw 'Monitor restarted the wrong manager or PM2 process ID.' }
    Write-Host "Health monitor coordination, cooldown, backup retention, and manager dispatch OK"
} finally {
    if ($lock) { Exit-DeploymentLock $lock }
    $resolved = [IO.Path]::GetFullPath($FixtureRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $repoRoot ".tmp")).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
