Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "DeploymentLock.ps1")
. (Join-Path $PSScriptRoot "ManagedServiceConfiguration.ps1")
. (Join-Path $PSScriptRoot "IisDeploymentState.ps1")
. (Join-Path $PSScriptRoot "WindowsServiceSecurity.ps1")
. (Join-Path $PSScriptRoot "PostDeployHealth.ps1")

function Get-ManagedDeploymentManager($Config) {
    if ($Config.PSObject.Properties['DeploymentMode'] -and
        ([string]$Config.DeploymentMode).Trim().Replace('_', '-').ToLowerInvariant() -eq 'static-iis') { return 'static' }
    if (-not $Config.PSObject.Properties['ServiceManager']) { return 'none' }
    return ([string]$Config.ServiceManager).Trim().ToLowerInvariant()
}

function Get-ManagedHealthMonitorConfigPath($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    return Join-Path $programData "node-enterprise-deploy-kit\healthchecks\$($Config.AppName)\health-monitor.config.json"
}

function Assert-ManagedDeploymentManagerTransition {
    param($Config)
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $desired = Get-ManagedDeploymentManager $Config
    if ($desired -eq 'pm2') { Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName) }
    if ($desired -notin @('winsw', 'nssm', 'pm2', 'static')) { return }
    $monitorPath = Get-ManagedHealthMonitorConfigPath $Config
    Assert-DeploymentPathNotReparsePoint $monitorPath
    if (Test-Path -LiteralPath $monitorPath) {
        $previous = Get-Content -LiteralPath $monitorPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $retentionOnly = $false
        if ($previous.PSObject.Properties['RetentionOnly']) {
            if ($previous.RetentionOnly -isnot [bool]) { throw 'Previous monitor RetentionOnly marker must be a JSON boolean; resolve deployment migration explicitly.' }
            $retentionOnly = [bool]$previous.RetentionOnly
        }
        $previousManager = if ($retentionOnly) { 'static' } else { Get-ManagedDeploymentManager $previous }
        if ($previousManager -notin @('winsw', 'nssm', 'pm2', 'static')) { throw 'Previous monitor lacks a reliable service manager marker; resolve deployment migration explicitly before mutation.' }
        if ($previousManager -ne $desired) {
            throw "Automatic deployment manager migration from '$previousManager' to '$desired' is unsupported. Stop and uninstall the previous manager and its health task, preserve the application data, verify its process/listener is gone, then deploy with the new manager (or use a distinct AppName)."
        }
    }
    # Even a deployment without a prior monitor must not leave an old native
    # runtime alive while introducing PM2/static hosting under the same name.
    $service = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop
    if ($service) {
        if ($desired -notin @('winsw', 'nssm')) { throw "A native service already uses AppName '$($Config.AppName)'. Complete an explicit manager migration or use a distinct AppName before deploying '$desired'." }
        Assert-ManagedServiceOwnership $Config $service
    }
}

function Get-ManagedScheduledTaskIfPresent {
    param([string]$TaskName)
    try { return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) { return $null }
        throw
    }
}

function ConvertTo-ManagedServiceAccount([string]$Account) {
    switch ($Account.Trim().ToLowerInvariant()) {
        { $_ -in @('localsystem', 'nt authority\system', 'system') } { return 'LocalSystem' }
        { $_ -in @('localservice', 'nt authority\localservice', 'nt authority\local service') } { return 'NT AUTHORITY\LocalService' }
        { $_ -in @('networkservice', 'nt authority\networkservice', 'nt authority\network service') } { return 'NT AUTHORITY\NetworkService' }
        default { return $Account.Trim() }
    }
}

function Assert-ManagedServiceIdentityRecoverable($Config, $Service) {
    if (-not $Service) { return }
    $oldAccount = ConvertTo-ManagedServiceAccount ([string]$Service.StartName)
    $newAccount = $oldAccount
    if ($Config.PSObject.Properties['ServiceAccount'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceAccount)) {
        $newAccount = ConvertTo-ManagedServiceAccount ([string]$Config.ServiceAccount)
    }
    $credentialWillChange = ($oldAccount -ine $newAccount) -or
        ($Config.PSObject.Properties['ServiceAccountPassword'] -and -not [string]::IsNullOrEmpty([string]$Config.ServiceAccountPassword))
    $oldNeedsPassword = $oldAccount -notin @('LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService') -and -not $oldAccount.EndsWith('$')
    if ($credentialWillChange -and $oldNeedsPassword -and
        (-not $Config.PSObject.Properties['PreviousServiceAccountPassword'] -or [string]::IsNullOrEmpty([string]$Config.PreviousServiceAccountPassword))) {
        throw 'Changing an existing custom service credential requires PreviousServiceAccountPassword before deployment can mutate the host.'
    }
    return [bool]($credentialWillChange -and $oldNeedsPassword)
}

function Assert-ManagedServiceOwnership($Config, $Service) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    if (-not $Service) { return }
    $manager = Get-ManagedDeploymentManager $Config
    $expected = if ($manager -eq 'winsw') {
        @(Join-Path $Config.ServiceDirectory "$($Config.AppName).exe")
    } elseif ($manager -eq 'nssm') {
        @((Join-Path $Config.ServiceDirectory "$($Config.AppName).nssm.exe"),
            (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\nssm\nssm.exe'))
    } else { throw 'Cannot suspend an unrelated Windows service for this deployment manager.' }
    $path = ([string]$Service.PathName).Trim()
    $executable = if ($path -match '^"(?<executable>[^"]+)"(?:\s|$)') { $Matches.executable } elseif ($path -match '^(?<executable>.+?\.exe)(?:\s|$)') { $Matches.executable } else { '' }
    $allowedPaths = @($expected | ForEach-Object { [IO.Path]::GetFullPath($_) })
    if (-not $executable -or [IO.Path]::GetFullPath($executable) -notin $allowedPaths) {
        throw "A service named '$($Config.AppName)' belongs to a different executable; deployment will not stop or change it."
    }
    Assert-DeploymentPathNotReparsePoint -Path $executable
}

function Invoke-ManagedPm2Command {
    param([string]$CommandName, [object[]]$Arguments, [string]$Pm2HomePath = '')
    $previousHome = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
    try {
        if ($Pm2HomePath) { [Environment]::SetEnvironmentVariable('PM2_HOME', $Pm2HomePath, 'Process') }
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $Pm2HomePath
        $output = @(& $CommandName @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "PM2 transaction command '$($Arguments[0])' failed with exit code $LASTEXITCODE." }
        return $output
    } finally { [Environment]::SetEnvironmentVariable('PM2_HOME', $previousHome, 'Process') }
}

function Get-ManagedPm2Entries {
    param([string]$CommandName, [string]$Name, [string]$Pm2HomePath = '')
    Assert-WindowsPm2DeploymentAppName -AppName $Name
    $output = @(Invoke-ManagedPm2Command $CommandName @('jlist') $Pm2HomePath)
    try {
        $json = ($output -join "`n").Trim()
        if (-not $json.StartsWith('[') -or -not $json.EndsWith(']')) { throw 'Expected a process array.' }
        $parsedEntries = $json | ConvertFrom-Json -ErrorAction Stop
        $entries = @()
        if ($null -ne $parsedEntries) { $entries = @($parsedEntries) }
        if ($entries.Count -eq 0 -and $json -cnotmatch '^\[\s*\]$') { throw 'Expected an empty array or process records.' }
    }
    catch { throw 'PM2 returned invalid process-state JSON; deployment will not mutate the host.' }
    $ids = @(Get-WindowsPm2ExactProcessIds -Entries $entries -AppName $Name)
    return @($entries | Where-Object { $ids -contains [long]$_.pm_id })
}

function Get-ManagedPm2Snapshot($Config) {
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    $context = Get-WindowsPm2RuntimeContext $Config
    $commandName = $context.CommandName
    $entries = @(Get-ManagedPm2Entries $commandName ([string]$Config.AppName) $context.Home)
    if ($entries.Count -gt 1) { throw 'Transactional PM2 deployment requires one managed process; multiple existing definitions require an explicit migration.' }
    $definition = $null; $wasRunning = $false
    if ($entries.Count -eq 1) {
        $environment = $entries[0].pm2_env
        if (-not $environment -or -not $environment.PSObject.Properties['pm_exec_path'] -or -not $environment.PSObject.Properties['pm_cwd']) {
            throw 'PM2 process definition is incomplete; deployment will not mutate the host.'
        }
        $definition = [ordered]@{ name = [string]$Config.AppName; script = [string]$environment.pm_exec_path; cwd = [string]$environment.pm_cwd }
        $fieldMap = @{ exec_interpreter = 'interpreter'; pm_out_log_path = 'out_file'; pm_err_log_path = 'error_file'; pm_pid_path = 'pid_file' }
        foreach ($field in $fieldMap.Keys) { if ($environment.PSObject.Properties[$field]) { $definition[$fieldMap[$field]] = $environment.$field } }
        foreach ($field in @('args', 'node_args', 'env', 'exec_mode', 'instances', 'watch', 'ignore_watch', 'watch_options', 'autorestart',
            'max_memory_restart', 'min_uptime', 'max_restarts', 'restart_delay', 'exp_backoff_restart_delay', 'kill_timeout', 'listen_timeout',
            'wait_ready', 'shutdown_with_message', 'cron_restart', 'merge_logs', 'log_date_format', 'time', 'source_map_support', 'disable_source_map_support',
            'instance_var', 'increment_var', 'filter_env', 'force', 'vizion', 'interpreter_args', 'uid', 'gid', 'treekill', 'windowsHide')) {
            if ($environment.PSObject.Properties[$field]) { $definition[$field] = $environment.$field }
        }
        $wasRunning = [string]$environment.status -in @('online', 'launching', 'waiting restart', 'one-launch-status')
    }
    return [pscustomobject]@{ CommandName = $commandName; Home = $context.Home; Account = $context.Account; Name = [string]$Config.AppName; Exists = ($entries.Count -gt 0); WasRunning = $wasRunning; Definition = $definition }
}

function Get-ManagedTaskRollbackCredential {
    param($Config, [string]$PrincipalUser)
    if ($Config.PSObject.Properties['PreviousHealthCheckTaskPassword'] -and -not [string]::IsNullOrEmpty([string]$Config.PreviousHealthCheckTaskPassword)) {
        return [string]$Config.PreviousHealthCheckTaskPassword
    }
    if ($Config.PSObject.Properties['HealthCheckTaskPassword'] -and -not [string]::IsNullOrEmpty([string]$Config.HealthCheckTaskPassword)) {
        $current = [Security.Principal.WindowsIdentity]::GetCurrent()
        $sameOwner = $PrincipalUser -ieq $current.Name -or $PrincipalUser -eq $current.User.Value
        if (-not $sameOwner) {
            try { $sameOwner = ([Security.Principal.NTAccount]::new($PrincipalUser)).Translate([Security.Principal.SecurityIdentifier]).Value -eq $current.User.Value }
            catch { $sameOwner = $false }
        }
        if ($sameOwner) { return [string]$Config.HealthCheckTaskPassword }
    }
    throw 'The existing Password-logon health task requires PreviousHealthCheckTaskPassword (or its current owner HealthCheckTaskPassword) before deployment can mutate the host.'
}

function Save-ManagedDeploymentFile {
    param($Transaction, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-DeploymentPathNotReparsePoint $fullPath
    if (@($Transaction.Files | Where-Object { $_.Path -ieq $fullPath }).Count -gt 0) { return }
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ((Test-Path -LiteralPath $fullPath) -and -not $exists) { throw "Managed file path is not a regular file: $fullPath" }
    $snapshot = Join-Path $Transaction.Directory ("file.{0}" -f $Transaction.Files.Count)
    $sddl = $null
    if ($exists) {
        Copy-Item -LiteralPath $fullPath -Destination $snapshot -ErrorAction Stop
        if (-not $Transaction.SkipAclHardening) {
            $sddl = (Get-Acl -LiteralPath $fullPath).Sddl
        }
    }
    $Transaction.Files.Add([pscustomobject]@{ Path = $fullPath; Existed = $exists; Snapshot = $snapshot; Sddl = $sddl })
    $Transaction | Export-Clixml -LiteralPath (Join-Path $Transaction.Directory "transaction.xml") -Depth 20
}

function Get-ManagedDeploymentSecurityTreeItems {
    param([string[]]$Roots, [string[]]$ExcludePaths = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [System.Collections.Generic.Stack[object]]::new()
    foreach ($root in $Roots) {
        Assert-WindowsServiceSecurityNoReparse -Path $root
        if (Test-Path -LiteralPath $root) { $pending.Push((Get-Item -LiteralPath $root -Force -ErrorAction Stop)) }
    }
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if (-not $seen.Add($item.FullName)) { continue }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing managed ACL traversal through a reparse point: $($item.FullName)" }
        if (@($ExcludePaths | Where-Object { Test-WindowsServiceSecurityPathWithin -Path $item.FullName -Root $_ }).Count -gt 0) { continue }
        $item
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) { $pending.Push($child) }
        }
    }
}

function Save-ManagedDeploymentFilesystemSecurity {
    param($Config, $Transaction)
    if ($Transaction.SkipAclHardening -or $Transaction.Manager -notin @('winsw', 'nssm', 'pm2')) { return }
    $paths = Assert-WindowsServiceSecurityPaths -Config $Config
    $roots = @($paths.App, $paths.Service, $paths.Logs, $paths.Backup) + @($paths.Writable)
    if ($Transaction.Manager -eq 'pm2' -and $Transaction.Pm2) { $roots += [string]$Transaction.Pm2.Home }
    $roots = @($roots | Select-Object -Unique)
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    # Fully enumerate and reject links before any installer can rewrite ACLs.
    # The held lock subtree includes this new journal and is never traversed.
    $items = @(Get-ManagedDeploymentSecurityTreeItems -Roots $roots -ExcludePaths @($paths.Lock))
    $entries = @($items | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Directory = [bool]$_.PSIsContainer; Sddl = (Get-Acl -LiteralPath $_.FullName -ErrorAction Stop).GetSecurityDescriptorSddlForm($sections) }
    })
    $snapshot = [pscustomobject]@{ Roots = $roots; ExcludePaths = @($paths.Lock); InheritIntroducedPaths = @($paths.App, $paths.Logs); Entries = $entries }
    $Transaction.FilesystemSecuritySnapshot = Join-Path $Transaction.Directory 'filesystem-security.xml'
    $snapshot | Export-Clixml -LiteralPath $Transaction.FilesystemSecuritySnapshot -Depth 12
}

function Restore-ManagedDeploymentFilesystemSecurity {
    param($Transaction)
    if (-not $Transaction.FilesystemSecuritySnapshot) { return }
    Assert-DeploymentPathNotReparsePoint $Transaction.FilesystemSecuritySnapshot
    if (-not (Test-Path -LiteralPath $Transaction.FilesystemSecuritySnapshot -PathType Leaf)) { throw 'Filesystem ACL recovery snapshot is missing; service stays stopped.' }
    $snapshot = Import-Clixml -LiteralPath $Transaction.FilesystemSecuritySnapshot -ErrorAction Stop
    $items = @(Get-ManagedDeploymentSecurityTreeItems -Roots @($snapshot.Roots) -ExcludePaths @($snapshot.ExcludePaths))
    $previous = @{}
    foreach ($entry in @($snapshot.Entries)) { $previous[[string]$entry.Path] = $entry }
    foreach ($item in $items) {
        if ($previous.ContainsKey($item.FullName) -and [bool]$previous[$item.FullName].Directory -ne [bool]$item.PSIsContainer) { throw 'An ACL recovery path changed its file/directory type; service stays stopped.' }
    }
    # Restore parents before children so inherited entries and protection flags
    # end at their exact previous values, including custom administrative ACEs.
    foreach ($entry in @($snapshot.Entries | Sort-Object { ([string]$_.Path).Length })) {
        if (Test-Path -LiteralPath $entry.Path) { Restore-WindowsPathSecurity -Path $entry.Path -Sddl $entry.Sddl }
    }
    foreach ($item in @($items | Sort-Object { $_.FullName.Length })) {
        if ($previous.ContainsKey($item.FullName)) { continue }
        if (@($snapshot.InheritIntroducedPaths | Where-Object { Test-WindowsServiceSecurityPathWithin -Path $item.FullName -Root $_ }).Count -eq 0) { continue }
        # New app/log objects have no previous ACL. Remove replacement-account
        # explicit grants and inherit the restored parent policy. New backups
        # and control artifacts retain their private administrative ACLs.
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $acl.RemoveAccessRuleSpecific($rule) }
        $acl.SetAccessRuleProtection($false, $false)
        $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
        Restore-WindowsPathSecurity -Path $item.FullName -Sddl $acl.GetSecurityDescriptorSddlForm($sections)
    }
}

function Get-ManagedRollbackHealthConfig {
    param($Config, [string]$MonitorSnapshot = '')
    $policy = [ordered]@{ AppName = [string]$Config.AppName; RequirePostDeployHealthCheck = $true }
    foreach ($field in @('HealthUrl', 'PostDeployHealthAttempts', 'PostDeployHealthDelaySeconds', 'HealthCheckTimeoutSeconds')) {
        if ($Config.PSObject.Properties[$field]) { $policy[$field] = $Config.$field }
    }
    if ($MonitorSnapshot) {
        $previous = Get-Content -LiteralPath $MonitorSnapshot -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($field in @('HealthUrl', 'RequirePostDeployHealthCheck', 'PostDeployHealthAttempts', 'PostDeployHealthDelaySeconds', 'HealthCheckTimeoutSeconds')) {
            if ($previous.PSObject.Properties[$field]) { $policy[$field] = $previous.$field }
        }
    } elseif ($Config.PSObject.Properties['RequirePostDeployHealthCheck']) {
        $policy.RequirePostDeployHealthCheck = $Config.RequirePostDeployHealthCheck
    }
    if ($Config.PSObject.Properties['PreviousHealthUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.PreviousHealthUrl)) {
        $policy.HealthUrl = [string]$Config.PreviousHealthUrl
    }
    return [pscustomobject]$policy
}

function Test-ManagedRollbackRequiresHealth {
    param($Transaction)
    if ($Transaction.SkipHostState) { return $false }
    if ($Transaction.Manager -in @('winsw', 'nssm') -and $Transaction.Service) {
        return [bool]($Transaction.Service.WasRunning -and $Transaction.Service.State -ne 'Paused')
    }
    return [bool]($Transaction.Manager -eq 'pm2' -and $Transaction.Pm2 -and $Transaction.Pm2.Exists -and $Transaction.Pm2.WasRunning)
}

function Start-ManagedDeploymentTransaction {
    [CmdletBinding()]
    param($Config, $Lock, [switch]$SkipHostState, [switch]$SkipAclHardening)
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    Assert-ExistingDeploymentLock -Config $Config -Lock $Lock
    Assert-NoPendingDeploymentRecovery -Config $Config -LockDirectory (Split-Path -Parent $Lock.Path)
    if (-not $SkipHostState) { Assert-ManagedDeploymentManagerTransition -Config $Config }
    $directory = Join-Path (Split-Path -Parent $Lock.Path) ("{0}.{1}.managed-transaction.{2}" -f $Config.AppName, $PID, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    if (-not $SkipAclHardening) { Set-ProtectedDeploymentLockDirectoryAcl $directory }
    $transaction = [pscustomobject]@{
        Schema = "node-enterprise-deploy-kit/managed-transaction/v1"
        Directory = $directory; AppName = [string]$Config.AppName; OwnerProcessId = $PID
        Files = [System.Collections.Generic.List[object]]::new()
        Manager = Get-ManagedDeploymentManager $Config
        Service = $null; Pm2 = $null; TaskXml = $null; TaskExisted = $false; TaskName = "$($Config.AppName)-HealthCheck"
        TaskWasEnabled = $false; TaskSuspended = $false
        TaskCredentialUser = ''
        ParametersExisted = $false; ParametersSnapshot = $null; ParametersSddl = $null; SkipAclHardening = [bool]$SkipAclHardening
        SkipHostState = [bool]$SkipHostState; Restored = $false; Suspended = $false
        PreviousHealthConfig = $null; RollbackHealthVerified = $false
        FilesystemSecuritySnapshot = ''
        IisLockLeasePath = ''; IisLockToken = ''; IisSnapshotReady = $false
    }
    try {
    foreach ($suffix in @(".exe", ".nssm.exe", ".xml", ".pm2.config.cjs")) {
        if ($Config.PSObject.Properties["ServiceDirectory"] -and $Config.ServiceDirectory) {
            Save-ManagedDeploymentFile $transaction (Join-Path $Config.ServiceDirectory "$($Config.AppName)$suffix")
        }
    }
    if ($Config.PSObject.Properties["IisSitePath"] -and $Config.IisSitePath) {
        Save-ManagedDeploymentFile $transaction (Join-Path $Config.IisSitePath "web.config")
    }
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $monitorDirectory = Join-Path $programData "node-enterprise-deploy-kit\healthchecks\$($Config.AppName)"
    foreach ($name in @("Invoke-NodeHealthCheck.ps1", "WindowsPm2ExecutionPolicy.ps1", "WindowsDeploymentIdentity.ps1", "health-monitor.config.json")) {
        Save-ManagedDeploymentFile $transaction (Join-Path $monitorDirectory $name)
    }
    if ($transaction.Manager -in @('winsw', 'nssm', 'pm2')) {
        $monitorFile = @($transaction.Files | Where-Object { $_.Existed -and (Split-Path -Leaf $_.Path) -eq 'health-monitor.config.json' })
        $monitorSnapshot = if ($monitorFile.Count -gt 0) { [string]$monitorFile[0].Snapshot } else { '' }
        $transaction.PreviousHealthConfig = Get-ManagedRollbackHealthConfig -Config $Config -MonitorSnapshot $monitorSnapshot
    }
    if (-not $SkipHostState) {
        $service = $null
        if ($transaction.Manager -in @('winsw', 'nssm')) { $service = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop }
        if ($service) {
            Assert-ManagedServiceOwnership $Config $service
            $restoreCredential = Assert-ManagedServiceIdentityRecoverable $Config $service
            $transaction.Service = [pscustomobject]@{
                Name = $service.Name; PathName = $service.PathName; StartMode = $service.StartMode
                StartName = $service.StartName; DisplayName = $service.DisplayName; State = [string]$service.State; WasRunning = ($service.State -ne 'Stopped')
                RestoreCredential = [bool]$restoreCredential; Recovery = Get-ManagedServiceRecoveryConfiguration -Name $service.Name
            }
        }
        if ($transaction.Manager -eq 'pm2') { $transaction.Pm2 = Get-ManagedPm2Snapshot $Config }
        $parametersPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters"
        $transaction.ParametersExisted = ($transaction.Manager -in @('winsw', 'nssm')) -and (Test-Path -LiteralPath $parametersPath)
        if ($transaction.ParametersExisted) {
            $transaction.ParametersSddl = (Get-Acl -LiteralPath $parametersPath -ErrorAction Stop).Sddl
            $transaction.ParametersSnapshot = Join-Path $directory "service-parameters.reg"
            & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters" $transaction.ParametersSnapshot /y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not snapshot service manager parameters." }
        }
        $task = $null
        if ($transaction.Manager -in @('winsw', 'nssm', 'pm2', 'static')) { $task = Get-ManagedScheduledTaskIfPresent -TaskName $transaction.TaskName }
        if ($task) {
            $transaction.TaskExisted = $true
            $transaction.TaskWasEnabled = if ($task.PSObject.Properties['Settings'] -and $task.Settings.PSObject.Properties['Enabled']) { [bool]$task.Settings.Enabled } else { -not ($task.PSObject.Properties['State'] -and [string]$task.State -eq 'Disabled') }
            $transaction.TaskXml = Export-ScheduledTask -TaskName $transaction.TaskName -ErrorAction Stop
            $taskDocument = [xml]$transaction.TaskXml
            $logonNode = $taskDocument.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='LogonType']")
            if ($logonNode -and $logonNode.InnerText -eq 'Password') {
                $userNode = $taskDocument.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']")
                if (-not $userNode -or [string]::IsNullOrWhiteSpace($userNode.InnerText)) { throw 'Existing password-based health task principal is incomplete.' }
                $transaction.TaskCredentialUser = $userNode.InnerText
                Get-ManagedTaskRollbackCredential $Config $transaction.TaskCredentialUser | Out-Null
            }
        }
        $usesIis = $transaction.Manager -eq 'static' -or
            ($Config.PSObject.Properties['ReverseProxy'] -and [string]$Config.ReverseProxy -ieq 'iis')
        if ($usesIis) {
            $lease = Enter-IisDeploymentLock -JournalDirectory $directory -AppLock $Lock
            $transaction.IisLockLeasePath = $lease.LeasePath; $transaction.IisLockToken = $lease.Token
            Invoke-NativeIisDeploymentState -Action Save -Transaction $transaction -Config $Config
            $transaction.IisSnapshotReady = $true
        }
    }
    Save-ManagedDeploymentFilesystemSecurity -Config $Config -Transaction $transaction
    $transaction | Export-Clixml -LiteralPath (Join-Path $directory "transaction.xml") -Depth 20
    return $transaction
    } catch {
        $snapshotFailure = $_
        Release-ManagedIisDeploymentLock -Transaction $transaction
        $target = [IO.Path]::GetFullPath($directory)
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $Lock.Path)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($target.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $target) -like "$($Config.AppName).*.managed-transaction.*") {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        }
        throw $snapshotFailure
    }
}

function Assert-ManagedDeploymentTransaction {
    param($Config, $Transaction)
    if ($null -eq $Transaction -or $Transaction.Schema -ne "node-enterprise-deploy-kit/managed-transaction/v1" -or
        $Transaction.AppName -ne [string]$Config.AppName -or $Transaction.OwnerProcessId -ne $PID) {
        throw "Invalid managed deployment transaction."
    }
    Assert-DeploymentPathNotReparsePoint $Transaction.Directory
    if (-not (Test-Path -LiteralPath (Join-Path $Transaction.Directory "transaction.xml") -PathType Leaf)) {
        throw "Managed deployment recovery journal is missing."
    }
}

function Set-ManagedNativeServiceStartMode {
    param($Service, [string]$StartMode)
    $result = Invoke-CimMethod -InputObject $Service -MethodName Change -Arguments @{ StartMode = $StartMode } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) { throw "Could not change managed service startup mode (code $($result.ReturnValue))." }
}

function Suspend-ManagedDeploymentServiceState {
    [CmdletBinding()]
    param($Config, $Transaction)
    Assert-ManagedDeploymentTransaction $Config $Transaction
    if ($Transaction.SkipHostState -or $Transaction.Suspended) { return }
    if ($Transaction.TaskExisted) {
        Disable-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction Stop | Out-Null
        $Transaction.TaskSuspended = $true
        $task = Get-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction Stop
        if ($task.PSObject.Properties['State'] -and [string]$task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction Stop
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                $task = Get-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction Stop
                if ([string]$task.State -ne 'Running') { break }
                if ([DateTime]::UtcNow -ge $deadline) { throw 'Managed health task did not stop before deployment.' }
                Start-Sleep -Milliseconds 200
            } while ($true)
        }
    }
    if ($Transaction.Manager -in @('winsw', 'nssm') -and $Transaction.Service) {
        $current = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop
        if (-not $current) { throw 'Managed service disappeared before deployment suspension.' }
        Assert-ManagedServiceOwnership $Config $current
        # Disabling startup also prevents an already queued SCM crash restart.
        Set-ManagedNativeServiceStartMode $current 'Disabled'
        $service = Get-Service -Name $Config.AppName -ErrorAction Stop
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $Config.AppName -Force -ErrorAction Stop }
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    } elseif ($Transaction.Manager -eq 'pm2' -and $Transaction.Pm2) {
        $entries = @(Get-ManagedPm2Entries $Transaction.Pm2.CommandName $Transaction.AppName $Transaction.Pm2.Home)
        foreach ($entry in $entries) { Invoke-ManagedPm2Command $Transaction.Pm2.CommandName @('delete', ([long]$entry.pm_id).ToString([Globalization.CultureInfo]::InvariantCulture)) $Transaction.Pm2.Home | Out-Null }
        if (@(Get-ManagedPm2Entries $Transaction.Pm2.CommandName $Transaction.AppName $Transaction.Pm2.Home).Count -gt 0) { throw 'PM2 process or watchers survived deployment suspension.' }
        Invoke-ManagedPm2Command $Transaction.Pm2.CommandName @('save', '--force') $Transaction.Pm2.Home | Out-Null
    }
    $Transaction.Suspended = $true
    $Transaction | Export-Clixml -LiteralPath (Join-Path $Transaction.Directory 'transaction.xml') -Depth 30
}

function Restore-ManagedDeploymentTransaction {
    [CmdletBinding()]
    param($Config, $Transaction, [switch]$FilesOnly)
    Assert-ManagedDeploymentTransaction $Config $Transaction
    if (-not $Transaction.SkipHostState -and -not $FilesOnly) {
        if ($Transaction.Manager -in @('winsw', 'nssm')) {
            $definition = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop
            if ($definition) {
                Assert-ManagedServiceOwnership $Config $definition
                Set-ManagedNativeServiceStartMode $definition 'Disabled'
                $current = Get-Service -Name $Config.AppName -ErrorAction Stop
                if ($current.Status -ne 'Stopped') { Stop-Service -Name $Config.AppName -Force -ErrorAction Stop }
                $current.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            }
        } elseif ($Transaction.Manager -eq 'pm2' -and $Transaction.Pm2) {
            $entries = @(Get-ManagedPm2Entries $Transaction.Pm2.CommandName $Transaction.AppName $Transaction.Pm2.Home)
            foreach ($entry in $entries) { Invoke-ManagedPm2Command $Transaction.Pm2.CommandName @('delete', ([long]$entry.pm_id).ToString([Globalization.CultureInfo]::InvariantCulture)) $Transaction.Pm2.Home | Out-Null }
            if (@(Get-ManagedPm2Entries $Transaction.Pm2.CommandName $Transaction.AppName $Transaction.Pm2.Home).Count -gt 0) { throw 'PM2 process survived rollback suspension.' }
        }
    }
    for ($index = $Transaction.Files.Count - 1; $index -ge 0; $index--) {
        $file = $Transaction.Files[$index]
        Assert-DeploymentPathNotReparsePoint $file.Path
        if ($file.Existed) {
            if (-not (Test-Path -LiteralPath $file.Snapshot -PathType Leaf)) { throw "Managed deployment file snapshot is missing; service stays stopped." }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file.Path) | Out-Null
            Copy-Item -LiteralPath $file.Snapshot -Destination $file.Path -Force -ErrorAction Stop
            if ($file.Sddl) {
                Restore-WindowsFileSecurity -Path $file.Path -Sddl $file.Sddl
            }
        } elseif (Test-Path -LiteralPath $file.Path -PathType Leaf) {
            Remove-Item -LiteralPath $file.Path -Force -ErrorAction Stop
        }
    }
    if ($Transaction.SkipHostState -or $FilesOnly) { Restore-ManagedDeploymentFilesystemSecurity -Transaction $Transaction; return }
    $parametersPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters"
    if ($Transaction.Manager -in @('winsw', 'nssm') -and $Transaction.ParametersExisted) {
        if (Test-Path -LiteralPath $parametersPath) { Remove-Item -LiteralPath $parametersPath -Recurse -Force -ErrorAction Stop }
        & reg.exe import $Transaction.ParametersSnapshot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restore service manager parameters." }
        if ($Transaction.ParametersSddl) {
            $acl = [Security.AccessControl.RegistrySecurity]::new()
            $acl.SetSecurityDescriptorSddlForm($Transaction.ParametersSddl, ([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group))
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters",
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                ([Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::TakeOwnership))
            if (-not $key) { throw 'Service Parameters registry key disappeared during rollback.' }
            try { $key.SetAccessControl($acl) } finally { $key.Dispose() }
        }
    } elseif ($Transaction.Manager -in @('winsw', 'nssm') -and (Test-Path -LiteralPath $parametersPath)) {
        Remove-Item -LiteralPath $parametersPath -Recurse -Force -ErrorAction Stop
    }
    $current = $null
    if ($Transaction.Manager -in @('winsw', 'nssm')) { $current = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop }
    if ($Transaction.Service) {
        if (-not $current) { throw "Previous service registration is missing; recovery journal retained." }
        $old = $Transaction.Service
        $arguments = @{ PathName = [string]$old.PathName; DisplayName = [string]$old.DisplayName; StartMode = 'Disabled' }
        if ((ConvertTo-ManagedServiceAccount ([string]$current.StartName)) -ine (ConvertTo-ManagedServiceAccount ([string]$old.StartName)) -or $old.RestoreCredential) {
            $arguments.StartName = [string]$old.StartName
            if ((ConvertTo-ManagedServiceAccount ([string]$old.StartName)) -notin @('LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService') -and -not ([string]$old.StartName).EndsWith('$')) {
                if (-not $Config.PSObject.Properties['PreviousServiceAccountPassword'] -or -not $Config.PreviousServiceAccountPassword) {
                    throw "Restoring the previous service identity requires PreviousServiceAccountPassword; service stays stopped."
                }
                $arguments.StartPassword = [string]$Config.PreviousServiceAccountPassword
            }
        }
        $result = Invoke-CimMethod -InputObject $current -MethodName Change -Arguments $arguments -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { throw "Could not restore the previous service configuration (code $($result.ReturnValue))." }
        Restore-ManagedServiceRecoveryConfiguration -Name $old.Name -Configuration $old.Recovery
    } elseif ($current) {
        & sc.exe delete $Config.AppName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not remove newly installed service during rollback." }
    }
    if ($Transaction.TaskExisted) {
        $taskArguments = @{ TaskName = $Transaction.TaskName; Xml = $Transaction.TaskXml; Force = $true; ErrorAction = 'Stop' }
        if ($Transaction.TaskCredentialUser) {
            $taskArguments.User = $Transaction.TaskCredentialUser
            $taskArguments.Password = Get-ManagedTaskRollbackCredential $Config $Transaction.TaskCredentialUser
        }
        Register-ScheduledTask @taskArguments | Out-Null
    } else {
        if (Get-ManagedScheduledTaskIfPresent -TaskName $Transaction.TaskName) {
            Unregister-ScheduledTask -TaskName $Transaction.TaskName -Confirm:$false -ErrorAction Stop
        }
        if (Get-ManagedScheduledTaskIfPresent -TaskName $Transaction.TaskName) { throw 'New health task survived rollback removal; recovery journal retained and service stays stopped.' }
    }
    if ($Transaction.IisSnapshotReady) { Invoke-NativeIisDeploymentState -Action Restore -Transaction $Transaction -Config $Config }
    Restore-ManagedDeploymentFilesystemSecurity -Transaction $Transaction
    $Transaction.Restored = $true
    $Transaction | Export-Clixml -LiteralPath (Join-Path $Transaction.Directory 'transaction.xml') -Depth 30
}

function Resume-ManagedDeploymentServiceState {
    [CmdletBinding()]
    param($Config, $Transaction)
    Assert-ManagedDeploymentTransaction $Config $Transaction
    if ($Transaction.SkipHostState) { return }
    if (-not $Transaction.Restored) { throw 'Restore the managed deployment transaction before resuming the previous service.' }
    if ($Transaction.Manager -in @('winsw', 'nssm') -and $Transaction.Service) {
        $current = Get-CimInstance Win32_Service -Filter "Name='$($Config.AppName)'" -ErrorAction Stop
        if (-not $current) { throw 'Previous managed service is missing during resume.' }
        Assert-ManagedServiceOwnership $Config $current
        $startMode = if ($Transaction.Service.StartMode -eq 'Auto') { 'Automatic' } else { [string]$Transaction.Service.StartMode }
        Set-ManagedNativeServiceStartMode $current $(if ($startMode -eq 'Disabled' -and $Transaction.Service.WasRunning) { 'Manual' } else { $startMode })
        if ($Transaction.Service.WasRunning) {
            Start-Service -Name $Transaction.AppName -ErrorAction Stop
            (Get-Service -Name $Transaction.AppName -ErrorAction Stop).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            if ($Transaction.Service.State -eq 'Paused') { Suspend-Service -Name $Transaction.AppName -ErrorAction Stop }
            if ($startMode -eq 'Disabled') { Set-ManagedNativeServiceStartMode $current 'Disabled' }
        }
    } elseif ($Transaction.Manager -eq 'pm2' -and $Transaction.Pm2) {
        if ($Transaction.Pm2.Exists) {
            $definition = $Transaction.Pm2.Definition
            # Restore a stopped definition without briefly launching its executable.
            $definition['autostart'] = [bool]$Transaction.Pm2.WasRunning
            $ecosystemPath = Join-Path $Transaction.Directory 'previous.pm2.config.cjs'
            $content = 'module.exports = ' + (@{ apps = @($definition) } | ConvertTo-Json -Depth 40) + ';'
            [IO.File]::WriteAllText($ecosystemPath, $content, [Text.UTF8Encoding]::new($false))
            Invoke-ManagedPm2Command $Transaction.Pm2.CommandName @('start', $ecosystemPath, '--only', $Transaction.AppName, '--update-env') $Transaction.Pm2.Home | Out-Null
            $entries = @(Get-ManagedPm2Entries $Transaction.Pm2.CommandName $Transaction.AppName $Transaction.Pm2.Home)
            if ($entries.Count -ne 1) { throw 'PM2 did not restore exactly one previous process definition.' }
            $running = [string]$entries[0].pm2_env.status -in @('online', 'launching', 'waiting restart', 'one-launch-status')
            if ($running -ne [bool]$Transaction.Pm2.WasRunning) { throw 'PM2 did not restore the previous process running state.' }
        }
        Invoke-ManagedPm2Command $Transaction.Pm2.CommandName @('save', '--force') $Transaction.Pm2.Home | Out-Null
    }
    if (Test-ManagedRollbackRequiresHealth $Transaction) {
        # Verify the old endpoint, after application/proxy restoration and resume,
        # before callers may discard the only protected recovery journal.
        Test-PostDeployHealth -Config $Transaction.PreviousHealthConfig
    }
    $Transaction.RollbackHealthVerified = $true
    $Transaction | Export-Clixml -LiteralPath (Join-Path $Transaction.Directory 'transaction.xml') -Depth 30
}

function Complete-ManagedDeploymentTransaction {
    param($Config, $Transaction)
    Assert-ManagedDeploymentTransaction $Config $Transaction
    if ($Transaction.Restored -and (Test-ManagedRollbackRequiresHealth $Transaction) -and -not $Transaction.RollbackHealthVerified) {
        throw 'Previous HTTP health has not been verified; recovery journal retained.'
    }
    $target = [IO.Path]::GetFullPath($Transaction.Directory)
    $parent = [IO.Path]::GetFullPath((Get-DeploymentLockDirectory $Config)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $target) -notlike "$($Config.AppName).*.managed-transaction.*") {
        throw "Refusing to remove a recovery journal outside the configured deployment lock directory."
    }
    if (-not $Transaction.SkipHostState -and $Transaction.TaskSuspended -and $Transaction.TaskWasEnabled) {
        $task = Get-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction SilentlyContinue
        if ($task -and (($task.PSObject.Properties['Settings'] -and -not [bool]$task.Settings.Enabled) -or
            ($task.PSObject.Properties['State'] -and [string]$task.State -eq 'Disabled'))) {
            Enable-ScheduledTask -TaskName $Transaction.TaskName -ErrorAction Stop | Out-Null
        }
    }
    Release-ManagedIisDeploymentLock -Transaction $Transaction
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
}

function Release-ManagedIisDeploymentLock {
    param($Transaction)
    if ($Transaction -and $Transaction.PSObject.Properties['IisLockToken'] -and $Transaction.IisLockToken) { Exit-IisDeploymentLock -Token $Transaction.IisLockToken }
}

function Start-ManagedServiceInstallerTransaction {
    [CmdletBinding()]
    param($Config, [object]$ExistingDeploymentLock, [object]$ExistingManagedDeploymentTransaction)
    $state = [pscustomobject]@{ Lock = $null; Transaction = $null; OwnsLock = $false; OwnsTransaction = $false }
    try {
        if ($ExistingManagedDeploymentTransaction -and -not $ExistingDeploymentLock) {
            throw 'A borrowed service installer transaction requires its live deployment lock.'
        }
        # This check precedes acquiring a manager-specific lock: a PM2/native
        # migration otherwise could use a different lock while the old runtime lives.
        Assert-ManagedDeploymentManagerTransition -Config $Config
        if ($ExistingDeploymentLock) {
            Assert-ExistingDeploymentLock -Config $Config -Lock $ExistingDeploymentLock
            $state.Lock = $ExistingDeploymentLock
        } else {
            $state.Lock = Enter-DeploymentLock -Config $Config
            $state.OwnsLock = $true
        }
        if ($ExistingManagedDeploymentTransaction) {
            Assert-ManagedDeploymentTransaction -Config $Config -Transaction $ExistingManagedDeploymentTransaction
            if ($ExistingManagedDeploymentTransaction.Manager -ne (Get-ManagedDeploymentManager $Config)) {
                throw 'Borrowed service installer transaction has a different service manager.'
            }
            $state.Transaction = $ExistingManagedDeploymentTransaction
        } else {
            $state.Transaction = Start-ManagedDeploymentTransaction -Config $Config -Lock $state.Lock
            $state.OwnsTransaction = $true
        }
        Suspend-ManagedDeploymentServiceState -Config $Config -Transaction $state.Transaction
        return $state
    } catch {
        $initialFailure = $_
        Complete-ManagedServiceInstallerTransaction -Config $Config -State $state -Failure $initialFailure
        throw $initialFailure
    }
}

function Complete-ManagedServiceInstallerTransaction {
    [CmdletBinding()]
    param($Config, $State, [object]$Failure)
    if (-not $State) { return }
    try {
        if ($State.OwnsTransaction -and $State.Transaction) {
            if ($Failure) {
                Restore-ManagedDeploymentTransaction -Config $Config -Transaction $State.Transaction
                Resume-ManagedDeploymentServiceState -Config $Config -Transaction $State.Transaction
            }
            Complete-ManagedDeploymentTransaction -Config $Config -Transaction $State.Transaction
        }
    } catch {
        $recoveryFailure = $_
        $journal = if ($State.Transaction) { [string]$State.Transaction.Directory } else { '' }
        $originalMessage = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception.Message } elseif ($Failure -is [Exception]) { $Failure.Message } else { [string]$Failure }
        if ($Failure) {
            throw "Service installer failed: $originalMessage. Recovery failed: $($recoveryFailure.Exception.Message). Recovery journal retained at '$journal'."
        }
        throw
    } finally {
        # A child installer must leave its parent's recovery journal and leases
        # intact so package bytes can be restored before the old runtime resumes.
        if ($State.OwnsTransaction -and $State.Transaction) { Release-ManagedIisDeploymentLock -Transaction $State.Transaction }
        if ($State.OwnsLock -and $State.Lock) { Exit-DeploymentLock -Lock $State.Lock }
    }
}
