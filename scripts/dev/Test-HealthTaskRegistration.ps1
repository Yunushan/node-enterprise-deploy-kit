Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/windows/DeploymentTransaction.ps1')
$registrationPath = Join-Path $repoRoot 'scripts/windows/Register-HealthCheckTask.ps1'
$tokens = $null; $parseErrors = $null
$registrationAst = [Management.Automation.Language.Parser]::ParseFile($registrationPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Health task registration has syntax errors.' }
foreach ($definition in $registrationAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$mutation = $registrationAst.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($PSCmdlet.ShouldProcess($taskName,')
}, $true)
if (-not $mutation) { throw 'Cannot locate the actual health-task registration mutation block.' }
$body = $mutation.Clauses[0].Item2.Extent.Text
$registrationBody = [scriptblock]::Create($body.Substring(1, $body.Length - 2))

# Execute the production registration block with real files and a real borrowed
# deployment lock. Task Scheduler and ACL calls are mocked; this is recovery
# verification, not evidence of a native installed task.
foreach ($scenario in @('restore-success', 'restore-failure', 'case-alias')) {
    & {
        param($scenario, $repoRoot, $registrationBody)
        $fixtureRoot = Join-Path $repoRoot ('.tmp/health-task-registration-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $testLock = $null
        $script:recoveryDirectory = ''
        try {
            $config = [pscustomobject]@{ AppName = 'registration-test'; DeploymentLockDirectory = $fixtureRoot }
            if ($scenario -eq 'case-alias') { $config | Add-Member NoteProperty ServiceManager 'pm2' }
            $testLock = Enter-DeploymentLock -Config $config -SkipAclHardening
            $ExistingDeploymentLock = $testLock
            $taskDirectory = Join-Path $fixtureRoot 'health'
            New-Item -ItemType Directory -Path $taskDirectory -Force | Out-Null
            $sourceScriptPath = Join-Path $repoRoot 'scripts/windows/Invoke-NodeHealthCheck.ps1'
            $sourcePolicyPath = Join-Path $repoRoot 'scripts/windows/WindowsPm2ExecutionPolicy.ps1'
            $sourceIdentityPath = Join-Path $repoRoot 'scripts/windows/WindowsDeploymentIdentity.ps1'
            $deployedScriptPath = Join-Path $taskDirectory 'Invoke-NodeHealthCheck.ps1'
            $deployedConfigPath = Join-Path $taskDirectory 'health-monitor.config.json'
            $deployedPolicyPath = Join-Path $taskDirectory 'WindowsPm2ExecutionPolicy.ps1'
            $deployedIdentityPath = Join-Path $taskDirectory 'WindowsDeploymentIdentity.ps1'
            [IO.File]::WriteAllText($deployedScriptPath, 'previous-script')
            [IO.File]::WriteAllText($deployedConfigPath, 'previous-config')
            [IO.File]::WriteAllText($deployedPolicyPath, 'previous-policy')
            [IO.File]::WriteAllText($deployedIdentityPath, 'previous-identity')
            if ($scenario -eq 'case-alias') { [IO.File]::WriteAllText($deployedConfigPath, '{"AppName":"Registration-Test","ServiceManager":"pm2"}') }
            $monitorConfig = [pscustomobject]@{ ServiceManager = 'winsw'; DeploymentLockPath = $testLock.Path }
            $taskName = 'registration-test-HealthCheck'
            $backupDirectory = Join-Path $fixtureRoot 'backups'
            $action = $trigger = $principal = $settings = [pscustomobject]@{}
            $taskUser = $taskPassword = ''
            $taskRunLevel = 'Highest'
            $script:taskCalls = 0; $script:credentialChecked = $false; $script:restoredTask = $null
            function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = $TaskName } }
            function Export-ScheduledTask { param($TaskName) return '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>fixture-owner</UserId><LogonType>Password</LogonType></Principal></Principals></Task>' }
            function Get-ManagedTaskRollbackCredential {
                param($Config, $PrincipalUser)
                if ($PrincipalUser -ne 'fixture-owner') { throw 'Incorrect previous task owner.' }
                $script:credentialChecked = $true
                return 'fixture-rollback-credential'
            }
            function Initialize-ProtectedTaskDirectories {
                param($TaskDirectory)
                if (-not $script:credentialChecked) { throw 'Host mutation preceded credential validation.' }
            }
            function Set-ProtectedDirectoryAcl { param($Path) $script:recoveryDirectory = $Path }
            function Set-ProtectedFileAcl { param($Path) }
            function Set-ProtectedDeploymentLockDirectoryAcl { param($Path) }
            function Register-ScheduledTask {
                [CmdletBinding()]
                param($TaskName, $Action, $Trigger, $Principal, $Settings, $User, $Password, $RunLevel, $Xml, [switch]$Force)
                $script:taskCalls++
                if ($script:taskCalls -eq 1) { throw 'Injected registration failure.' }
                $script:restoredTask = @{ User = $User; Password = $Password; Xml = $Xml }
                if ($scenario -eq 'restore-failure') { throw 'Injected task recovery failure.' }
            }
            $failure = $null
            try { . $registrationBody } catch { $failure = $_ }
            if ($scenario -eq 'case-alias') {
                if (-not $failure -or $failure.Exception.Message -notmatch 'differently cased PM2 app' -or $script:taskCalls -ne 0 -or $script:recoveryDirectory) { throw 'PM2 case alias reached task registration or file staging.' }
                if ([IO.File]::ReadAllText($deployedScriptPath) -ne 'previous-script' -or ([IO.File]::ReadAllText($deployedConfigPath) | ConvertFrom-Json).AppName -cne 'Registration-Test') { throw 'Case alias replaced another monitor definition.' }
                Assert-ExistingDeploymentLock -Config $config -Lock $testLock
                return
            }
            if (-not $failure -or $script:taskCalls -ne 2) { throw 'Task failure did not invoke recovery.' }
            if ([IO.File]::ReadAllText($deployedScriptPath) -ne 'previous-script' -or [IO.File]::ReadAllText($deployedConfigPath) -ne 'previous-config') { throw 'Previous health script/config bytes were not recovered.' }
            if ([IO.File]::ReadAllText($deployedPolicyPath) -ne 'previous-policy') { throw 'Previous protected PM2 execution policy bytes were not recovered.' }
            if ([IO.File]::ReadAllText($deployedIdentityPath) -ne 'previous-identity') { throw 'Previous protected identity validator bytes were not recovered.' }
            if ($script:restoredTask.User -ne 'fixture-owner' -or $script:restoredTask.Password -ne 'fixture-rollback-credential') { throw 'Password-logon task recovery lost its principal or credential.' }
            Assert-ExistingDeploymentLock -Config $config -Lock $testLock
            $recoveryFilesExist = Test-Path -LiteralPath $script:recoveryDirectory
            if ($recoveryFilesExist -ne ($scenario -eq 'restore-failure')) { throw 'Recovery files were deleted after failed recovery, or retained after successful recovery.' }
            if ($scenario -eq 'restore-failure' -and $failure.Exception.Message -notmatch 'Recovery files remain') { throw 'Failed recovery did not identify preserved recovery files.' }
        } finally {
            if ($testLock) { Exit-DeploymentLock -Lock $testLock }
            if ($script:recoveryDirectory -and (Test-Path -LiteralPath $script:recoveryDirectory)) {
                $resolvedRecovery = [IO.Path]::GetFullPath($script:recoveryDirectory)
                $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
                if ((Split-Path -Parent $resolvedRecovery).TrimEnd('\', '/') -ne $tempParent -or (Split-Path -Leaf $resolvedRecovery) -notmatch '^node-enterprise-health-task-[a-f0-9]{32}$') { throw 'Unsafe temporary recovery cleanup target.' }
                Remove-Item -LiteralPath $resolvedRecovery -Recurse -Force
            }
            $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
            $expectedParent = [IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp')).TrimEnd('\', '/')
            if ((Split-Path -Parent $resolvedFixture).TrimEnd('\', '/') -ne $expectedParent -or (Split-Path -Leaf $resolvedFixture) -notmatch '^health-task-registration-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup target.' }
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        }
    } $scenario $repoRoot $registrationBody
}
Write-Host 'Health-task credential recovery, preserved failure snapshots, and borrowed-lock ownership OK'
