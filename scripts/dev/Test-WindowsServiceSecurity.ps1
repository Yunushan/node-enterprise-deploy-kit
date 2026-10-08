Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'Windows service ACL tests require Windows; skipped on this host.'; return }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repo 'scripts\windows\WindowsServiceSecurity.ps1')
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected $Message
}
function Import-FunctionDefinitions([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) "Invalid PowerShell source: $Path"
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    # Function definitions are returned for installation in the caller's scope.
    return $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
}

$runtimeSid = 'S-1-5-20'
foreach ($directory in @($false, $true)) {
    foreach ($rights in @([Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.FileSystemRights]::ReadAndExecute, [Security.AccessControl.FileSystemRights]::Modify)) {
        $acl = New-WindowsProtectedPathAcl -Directory $directory -Account NetworkService -RuntimeRights $rights
        Assert-Test $acl.AreAccessRulesProtected 'Service ACL must disable inherited access.'
        Assert-Test ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Service ACL owner must be Administrators.'
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-Test ($rules.Count -eq 3) 'Service ACL must contain exactly SYSTEM, Administrators and the runtime identity.'
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $rule = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
            Assert-Test ($rule.Count -eq 1 -and $rule[0].FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl) 'Administrative recovery access was lost.'
        }
        $runtime = @($rules | Where-Object { $_.IdentityReference.Value -eq $runtimeSid })
        # FileSystemAccessRule adds Synchronize to allow rules on Windows.
        $effective = $runtime[0].FileSystemRights -band (-bnot [Security.AccessControl.FileSystemRights]::Synchronize)
        Assert-Test ($effective -eq $rights) 'Runtime ACL has broader rights than requested.'
    }
}
$private = New-WindowsProtectedPathAcl -Directory $true
Assert-Test (@($private.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])).Count -eq 2) 'Private backups must exclude the runtime identity.'
# Compile the native bridge without changing any local account policy.
Initialize-WindowsServiceLogonRights
Grant-WindowsServiceLogonRight -Account NetworkService

$testRoot = Join-Path (Join-Path $repo '.tmp') ('windows-service-security-' + [Guid]::NewGuid().ToString('N'))
$config = [pscustomobject]@{ AppName='security-fixture'; DeploymentLockDirectory=(Join-Path $testRoot 'deployment-locks'); AppDirectory = (Join-Path $testRoot 'app'); ServiceDirectory = (Join-Path $testRoot 'service'); LogDirectory = (Join-Path $testRoot 'logs'); AppFramework = 'nextjs' }
$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
try {
    New-Item -ItemType Directory -Path $config.AppDirectory -Force | Out-Null
    $paths = Assert-WindowsServiceSecurityPaths $config
    Assert-Test ($paths.Writable.Count -eq 1 -and $paths.Writable[0] -eq (Join-Path $config.AppDirectory '.next\cache')) 'Next.js must get a dedicated cache directory by default.'
    foreach ($bad in @('.', '..', '..\outside', 'C:\outside', 'safe\..\..\outside', 'cache:stream', 'cache*')) {
        $config | Add-Member NoteProperty RuntimeWritableDirectories @($bad) -Force
        Assert-Rejected { Assert-WindowsServiceSecurityPaths $config } "Unsafe runtime-writable path was accepted: $bad"
    }
    $config.RuntimeWritableDirectories = 'cache'
    Assert-Rejected { Assert-WindowsServiceSecurityPaths $config } 'String cache-path configuration must fail.'
    $config.RuntimeWritableDirectories = @('data\cache')
    $config.ServiceDirectory = Join-Path $config.AppDirectory 'control'
    Assert-Rejected { Assert-WindowsServiceSecurityPaths $config } 'Control directories inside code must fail.'
    $config.ServiceDirectory = Join-Path $testRoot 'service'
    $config.LogDirectory = Join-Path $config.ServiceDirectory 'logs'
    Assert-Rejected { Assert-WindowsServiceSecurityPaths $config } 'Writable logs inside control directories must fail.'
    $config.LogDirectory = Join-Path $testRoot 'logs'
    foreach ($bad in @('C:\', 'relative\path', 'C:\cache:stream', 'C:\cache*')) {
        Assert-Rejected { Get-WindowsServiceSecurityFullPath $bad } "Unsafe absolute ACL target was accepted: $bad"
    }

    $outside = Join-Path $testRoot 'outside'
    $link = Join-Path $config.AppDirectory 'cache-link'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    # Directory junctions do not require symlink privilege on Windows.
    $config.RuntimeWritableDirectories = @('cache-link\nested')
    $junctionCreated = $false
    try { New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop | Out-Null; $junctionCreated = $true } catch {
        if ($_.Exception -isnot [UnauthorizedAccessException] -and -not ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 5)) { throw }
        Write-Host 'Junction creation is denied by this host; testing reparse ancestor rejection with filesystem metadata.'
    }
    if ($junctionCreated) {
        Assert-Rejected { Assert-WindowsServiceSecurityPaths $config } 'A cache path through a junction must fail.'
        Remove-Item -LiteralPath $link -Force
    } else {
        & {
            param($reparsePath, $fixtureConfig)
            function Test-Path { param([string]$LiteralPath); if ($LiteralPath -eq $reparsePath) { return $true }; Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
            function Get-Item { param([string]$LiteralPath, [switch]$Force); if ($LiteralPath -eq $reparsePath) { return [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint } }; Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force }
            Assert-Rejected { Assert-WindowsServiceSecurityPaths $fixtureConfig } 'A cache path through a reparse ancestor must fail.'
        } $link $config
    }

    # Apply a real private-file ACL without changing any source/deployment paths.
    $privateFile = Join-Path $testRoot 'private.cjs'
    [IO.File]::WriteAllText($privateFile, '')
    Set-WindowsProtectedPathSecurity -Path $privateFile -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account
    [IO.File]::WriteAllText($privateFile, 'fixture only')
    $actualAcl = Get-Acl -LiteralPath $privateFile
    Assert-Test $actualAcl.AreAccessRulesProtected 'Actual secret file inherited broad access.'
    $actualSids = @($actualAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
    foreach ($broad in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')) { Assert-Test ($actualSids -notcontains $broad) 'Actual secret file grants general user access.' }
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    $originalSddl = $actualAcl.GetSecurityDescriptorSddlForm($sections)
    Set-WindowsProtectedPathSecurity -Path $privateFile -Account NetworkService -RuntimeRights ([Security.AccessControl.FileSystemRights]::Read) -OwnerAccount $account
    Restore-WindowsFileSecurity -Path $privateFile -Sddl $originalSddl
    Assert-Test ((Get-Acl -LiteralPath $privateFile).GetSecurityDescriptorSddlForm($sections) -eq $originalSddl) 'Rollback must restore file owner/group/access without SACL changes.'

    & {
        param($installer, $fixtureConfig, $fixtureRoot, $fixtureAccount)
        foreach ($definition in @(Import-FunctionDefinitions $installer)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $fixtureConfig.RuntimeWritableDirectories = @()
        $pm2FixtureHome = Join-Path $fixtureRoot 'pm2-home'
        Set-Pm2PrivateFilesystemSecurity -Config $fixtureConfig -Account $fixtureAccount -Pm2Home $pm2FixtureHome
        $path = Join-Path $fixtureConfig.ServiceDirectory 'fixture.pm2.config.cjs'
        $backupDirectory = Join-Path $fixtureConfig.ServiceDirectory 'backups'
        Write-Pm2PrivateEcosystemFile -Path $path -Content 'first fixture content' -BackupDirectory $backupDirectory -Account $fixtureAccount
        Write-Pm2PrivateEcosystemFile -Path $path -Content 'second fixture content' -BackupDirectory $backupDirectory -Account $fixtureAccount
        $backups = @(Get-ChildItem -LiteralPath $backupDirectory -File)
        Assert-Test ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -eq 'first fixture content') 'PM2 private config backup did not preserve previous content.'
        foreach ($privatePath in @($path, $backups[0].FullName, $pm2FixtureHome)) {
            $acl = Get-Acl -LiteralPath $privatePath
            $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
            Assert-Test ($acl.AreAccessRulesProtected -and $sids -notcontains 'S-1-5-32-545' -and $sids -notcontains 'S-1-5-11' -and $sids -notcontains 'S-1-1-0') 'PM2 config/backup/home is readable by general users.'
        }
        function Get-Command { param($Name, $ErrorAction); [pscustomobject]@{ CommandType = [Management.Automation.CommandTypes]::Application; Source = 'C:\tools\pm2.cmd' } }
        $fixtureConfig | Add-Member NoteProperty PM2Home $pm2FixtureHome
        $context = Get-WindowsPm2RuntimeContext $fixtureConfig
        Assert-Test ($context.Home -eq $pm2FixtureHome -and $context.CommandName -eq 'C:\tools\pm2.cmd') 'PM2 home and external command must be pinned.'
        function Get-Command { param($Name, $ErrorAction); [pscustomobject]@{ CommandType = [Management.Automation.CommandTypes]::Function; Source = '' } }
        Assert-Rejected { Get-WindowsPm2RuntimeContext $fixtureConfig } 'PM2 function/alias resolution must fail.'
    } (Join-Path $repo 'scripts\windows\Install-PM2Fallback.ps1') $config $testRoot $account

    & {
        param($installer)
        foreach ($definition in @(Import-FunctionDefinitions $installer)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $base = [pscustomobject]@{ AppName = 'security-fixture' }
        Assert-Test ((Get-ServiceAccountSettings $base).Account -eq 'NT AUTHORITY\NetworkService') 'New WinSW service must default to NetworkService.'
        $existing = [pscustomobject]@{ StartName = 'CONTOSO\fixture' }
        $preserved = Get-ServiceAccountSettings $base $existing
        Assert-Test ($preserved.PreserveExisting -and $preserved.Account -eq $existing.StartName) 'Omitted identity must preserve an existing custom account.'
        $base | Add-Member NoteProperty ServiceAccount 'CONTOSO\fixture'
        Assert-Test ((Get-ServiceAccountSettings $base $existing).PreserveExisting) 'Same custom identity without a password must preserve the SCM credential.'
        Assert-Rejected { Get-ServiceAccountSettings $base } 'A new custom account requires credentials.'
        $base.ServiceAccount = 'CONTOSO\fixture$'
        Assert-Test (-not (Get-ServiceAccountSettings $base).NeedsPassword) 'gMSA must not require a password.'
        $script:nativeCalls = 0; $script:cimCalls = 0; $script:logonGrants = 0
        function Grant-WindowsServiceLogonRight { param($Account); $script:logonGrants++ }
        function Invoke-NativeCommand { $script:nativeCalls++ }
        function Get-CimInstance { [pscustomobject]@{ Name = 'security-fixture' } }
        function Invoke-CimMethod { param($InputObject, $MethodName, $Arguments, $ErrorAction); $script:cimCalls++; Assert-Test ($MethodName -eq 'Change' -and $Arguments.StartPassword -eq 'fixture-only-value') 'Credential rotation must use CIM Change.'; [pscustomobject]@{ ReturnValue = 0 } }
        Set-ServiceAccount $base $preserved
        Assert-Test ($script:nativeCalls -eq 0 -and $script:cimCalls -eq 0 -and $script:logonGrants -eq 0) 'Preserved identity must not issue an SCM credential reset.'
        $rotated = [pscustomobject]@{ Account = 'CONTOSO\fixture'; Password = 'fixture-only-value'; NeedsPassword = $true; PreserveExisting = $false }
        Set-ServiceAccount $base $rotated
        Assert-Test ($script:nativeCalls -eq 0 -and $script:cimCalls -eq 1 -and $script:logonGrants -eq 1) 'Credential rotation must provision service logon rights without native password arguments.'
    } (Join-Path $repo 'scripts\windows\Install-NodeService.ps1')
} finally {
    if ((Get-Variable link -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link -Force }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $repo '.tmp')) + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside repository .tmp.' }
    if (Test-Path -LiteralPath $resolved) {
        Set-WindowsProtectedPathSecurity -Path $resolved -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account -Recurse
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host 'Windows service ACL, safe cache-path, private-file and identity-preservation tests OK'
