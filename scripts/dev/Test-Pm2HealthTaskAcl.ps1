Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'PM2 monitor NTFS inheritance tests require Windows; skipped.'; return }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/windows/WindowsServiceSecurity.ps1')
function Assert-AclTest([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$fixture = Join-Path $repoRoot ('.tmp/pm2-health-task-acl-' + [guid]::NewGuid().ToString('N'))
$taskDirectory = Join-Path $fixture 'task'
$lockDirectory = Join-Path $fixture 'locks'
$lockPath = Join-Path $lockDirectory 'fixture.lock'
$lockStream = $null
New-Item -ItemType Directory -Path $taskDirectory, $lockDirectory -Force | Out-Null
try {
    $scriptPath = Join-Path $taskDirectory 'Invoke-NodeHealthCheck.ps1'
    $configPath = Join-Path $taskDirectory 'health-monitor.config.json'
    $policyPath = Join-Path $taskDirectory 'WindowsPm2ExecutionPolicy.ps1'
    $identityPath = Join-Path $taskDirectory 'WindowsDeploymentIdentity.ps1'
    [IO.File]::WriteAllText($scriptPath, 'protected script fixture')
    [IO.File]::WriteAllText($configPath, 'protected config fixture')
    [IO.File]::WriteAllText($policyPath, 'protected execution policy fixture')
    [IO.File]::WriteAllText($identityPath, 'protected deployment identity fixture')
    [IO.File]::WriteAllText($lockPath, '')
    # This host may lack elevation. Preserve the current owner to test actual
    # NTFS ACE inheritance without claiming an admin-owned deployment or token
    # impersonation. Production directory/file ownership is tested separately.
    foreach ($directory in @($taskDirectory, $lockDirectory)) {
        Set-WindowsProtectedPathSecurity -Path $directory -Account $account -OwnerAccount $account
    }
    foreach ($file in @($scriptPath, $configPath, $policyPath, $identityPath, $lockPath)) {
        Set-WindowsProtectedFileSecurity -Path $file -Account $account -OwnerAccount $account
    }
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $scriptAclBefore = (Get-Acl -LiteralPath $scriptPath).GetSecurityDescriptorSddlForm($sections)
    $configAclBefore = (Get-Acl -LiteralPath $configPath).GetSecurityDescriptorSddlForm($sections)
    $policyAclBefore = (Get-Acl -LiteralPath $policyPath).GetSecurityDescriptorSddlForm($sections)
    $identityAclBefore = (Get-Acl -LiteralPath $identityPath).GetSecurityDescriptorSddlForm($sections)
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/windows/Register-HealthCheckTask.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-AclTest ($parseErrors.Count -eq 0) 'Registration source must parse.'
    & {
        param($ast, $taskDirectory, $lockPath, $ownerSid, $account)
        foreach ($definition in $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Grant-Pm2HealthTaskAccess', 'Assert-NotReparsePoint')
        }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        function Set-ProtectedFileAcl {
            param([string]$Path)
            Set-WindowsProtectedFileSecurity -Path $Path -Account $account -OwnerAccount $account
        }
        Grant-Pm2HealthTaskAccess -TaskDirectory $taskDirectory -LockPath $lockPath -OwnerSid $ownerSid
    } $ast $taskDirectory $lockPath $ownerSid $account

    $directoryAcl = Get-Acl -LiteralPath $taskDirectory
    $rules = @($directoryAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $ownerRules = @($rules | Where-Object { $_.IdentityReference.Value -eq $ownerSid })
    Assert-AclTest ($ownerRules.Count -eq 2 -or $ownerRules.Count -eq 1) 'PM2 owner directory access was lost.'
    $ownerRights = [Security.AccessControl.FileSystemRights]0
    foreach ($rule in $ownerRules) {
        $ownerRights = $ownerRights -bor $rule.FileSystemRights
        # Baseline RX may inherit; the new CreateFiles ACE must not grant
        # modification/deletion of any pre-existing file or child directory.
        if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::CreateFiles) -ne 0) {
            Assert-AclTest ($rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None) 'CreateFiles was inherited by protected definitions.'
        }
    }
    $disallowed = [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor [Security.AccessControl.FileSystemRights]::CreateDirectories
    Assert-AclTest (($ownerRights -band $disallowed) -eq 0) 'Task directory grants PM2 owner delete, ownership, ACL change or directory creation.'
    $creatorRule = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-3-0' })
    Assert-AclTest ($creatorRule.Count -eq 1 -and $creatorRule[0].InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::ObjectInherit -and $creatorRule[0].PropagationFlags -eq [Security.AccessControl.PropagationFlags]::InheritOnly) 'CREATOR OWNER data-file rule is missing or applies to the directory itself.'
    Assert-AclTest ((Get-Acl -LiteralPath $scriptPath).GetSecurityDescriptorSddlForm($sections) -eq $scriptAclBefore) 'Grant changed protected script ACL.'
    Assert-AclTest ((Get-Acl -LiteralPath $configPath).GetSecurityDescriptorSddlForm($sections) -eq $configAclBefore) 'Grant changed protected config ACL.'
    Assert-AclTest ((Get-Acl -LiteralPath $policyPath).GetSecurityDescriptorSddlForm($sections) -eq $policyAclBefore) 'Creator inheritance changed protected execution policy ACL.'
    Assert-AclTest ((Get-Acl -LiteralPath $identityPath).GetSecurityDescriptorSddlForm($sections) -eq $identityAclBefore) 'Creator inheritance changed protected deployment identity ACL.'

    $statePath = Join-Path $taskDirectory 'healthcheck.state.json'
    $logPath = Join-Path $taskDirectory 'healthcheck.log'
    foreach ($iteration in 1..2) {
        $temporaryState = "$statePath.$PID.tmp"
        [IO.File]::WriteAllText($temporaryState, ('{"generation":' + $iteration + '}'))
        $newFileAcl = Get-Acl -LiteralPath $temporaryState
        $actualFileOwner = $newFileAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        # Elevated Windows tokens can default new-file ownership to the
        # Administrators group. CREATOR OWNER resolves to the object owner,
        # not necessarily WindowsIdentity.User. Production PM2 rejects an
        # elevated owner; this fixture also runs in elevated CI jobs.
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Assert-AclTest ($actualFileOwner -eq $ownerSid) 'Non-admin data-file owner differs from the PM2 owner.'
        }
        $newFileRules = @($newFileAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Assert-AclTest (@($newFileRules | Where-Object { $_.IdentityReference.Value -eq $actualFileOwner -and $_.IsInherited -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify }).Count -ge 1) 'New data file did not inherit Modify for its object owner SID.'
        Move-Item -LiteralPath $temporaryState -Destination $statePath -Force
        Assert-AclTest ([IO.File]::ReadAllText($statePath) -eq ('{"generation":' + $iteration + '}')) 'Atomic state replacement failed.'
    }
    [IO.File]::AppendAllText($logPath, 'first log entry')
    Move-Item -LiteralPath $logPath -Destination ($logPath + '.1')
    [IO.File]::WriteAllText($logPath, 'new rotated log entry')
    [IO.File]::AppendAllText($logPath, '; append succeeds')
    Assert-AclTest ([IO.File]::ReadAllText($logPath + '.1') -eq 'first log entry') 'Log rotation lost previous data.'
    Assert-AclTest ([IO.File]::ReadAllText($scriptPath) -eq 'protected script fixture' -and [IO.File]::ReadAllText($configPath) -eq 'protected config fixture') 'Protected definition bytes changed during data writes.'
    $lockRules = @((Get-Acl -LiteralPath $lockPath).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $ownerSid })
    Assert-AclTest ($lockRules.Count -eq 1 -and ($lockRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -eq 0 -and ($lockRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq [Security.AccessControl.FileSystemRights]::Write) 'Deployment lock access must be Read/Write without Delete.'
    $lockStream = [IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Assert-AclTest ($lockStream.CanRead -and $lockStream.CanWrite) 'PM2 owner cannot open the exact deployment lock.'
    Write-Host 'Actual PM2 monitor NTFS creator inheritance, protected definitions, atomic state/log rotation and lock rights OK (current-owner fixture; no native task/token claim).'
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    $resolved=[IO.Path]::GetFullPath($fixture); $allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp'))+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing PM2 ACL fixture cleanup outside repository .tmp.' }
    if (Test-Path -LiteralPath $resolved) {
        Set-WindowsProtectedPathSecurity -Path $resolved -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account -Recurse
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
