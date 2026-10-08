<#
.SYNOPSIS
  Optional NSSM installer. WinSW remains the recommended Windows production default.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $NssmPath = "tools\nssm\nssm.exe",
    [object] $ExistingDeploymentLock,
    [object] $ExistingManagedDeploymentTransaction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run as Administrator." }
}
function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}
function ConvertTo-ServiceEnvironmentMap($Config) {
    $map = [ordered]@{}
    $bindAddress = Get-ConfigString $Config "BindAddress" "127.0.0.1"

    $map["NODE_ENV"] = "production"
    $map["PORT"] = [string]$Config.Port
    $map["APP_PORT"] = [string]$Config.Port
    $map["APP_NAME"] = [string]$Config.AppName
    $map["BIND_ADDRESS"] = $bindAddress
    $map["HOST"] = $bindAddress
    $map["HOSTNAME"] = $bindAddress

    if ($Config.Environment) {
        $Config.Environment.PSObject.Properties | ForEach-Object {
            $map[$_.Name] = [string]$_.Value
        }
    }

    return $map
}
function ConvertTo-NssmEnvironmentArguments($EnvironmentMap) {
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($name in $EnvironmentMap.Keys) {
        $entries.Add(("{0}={1}" -f $name, $EnvironmentMap[$name])) | Out-Null
    }
    return @($entries)
}
function Resolve-RepoPath([string]$Path, [string]$BasePath) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $BasePath $Path)
}
function Invoke-CheckedNativeCommand {
    param(
        [string]$FilePath,
        [object[]]$Arguments,
        [string]$Label
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}
function ConvertTo-NssmAccountName([string]$Account) {
    switch ($Account.Trim().ToLowerInvariant()) {
        "localsystem" { return "LocalSystem" }
        "nt authority\system" { return "LocalSystem" }
        "localservice" { return "NT AUTHORITY\LocalService" }
        "nt authority\localservice" { return "NT AUTHORITY\LocalService" }
        "networkservice" { return "NT AUTHORITY\NetworkService" }
        "nt authority\networkservice" { return "NT AUTHORITY\NetworkService" }
        default { return $Account.Trim() }
    }
}
function Get-NssmServiceAccountSettings {
    param($Config, $ExistingDefinition)

    $configuredAccount = Get-ConfigString $Config "ServiceAccount" ""
    $existingAccount = if ($ExistingDefinition) { ConvertTo-NssmAccountName ([string]$ExistingDefinition.StartName) } else { "" }
    $account = if ($configuredAccount) { ConvertTo-NssmAccountName $configuredAccount } elseif ($existingAccount) { $existingAccount } else { "NT AUTHORITY\NetworkService" }
    $password = Get-ConfigString $Config "ServiceAccountPassword" ""
    $isBuiltIn = $account -in @("LocalSystem", "NT AUTHORITY\LocalService", "NT AUTHORITY\NetworkService")
    $isGmsa = $account.EndsWith('$')
    # SCM retains the credential when an existing service is updated in place.
    # Do not require operators to re-export a dedicated account's password.
    $preserveExisting = ($null -ne $ExistingDefinition -and $account -ieq $existingAccount -and -not $password)
    if (-not $isBuiltIn -and -not $isGmsa -and -not $password -and -not $preserveExisting) {
        throw "ServiceAccount '$account' requires ServiceAccountPassword for a new or changed account. Prefer a gMSA for production."
    }
    return [pscustomobject]@{
        Account = $account; Password = $password; IsBuiltIn = $isBuiltIn
        IsGmsa = $isGmsa; PreserveExisting = $preserveExisting; GrantAccess = ($account -ne "LocalSystem")
    }
}
function Assert-NssmServicePathCompatible {
    param($ExistingDefinition, [string]$ExpectedNssmPath, [string]$ManagedNssmPath = '')

    if (-not $ExistingDefinition) { return }
    $pathName = ([string]$ExistingDefinition.PathName).Trim()
    $executablePath = $pathName
    if ($pathName.StartsWith('"')) {
        if ($pathName -notmatch '^"([^"]+)"(?:\s.*)?$') { throw "Existing NSSM service executable path is invalid." }
        $executablePath = $Matches[1]
    }
    $allowedPaths = @([System.IO.Path]::GetFullPath($ExpectedNssmPath))
    if ($ManagedNssmPath) { $allowedPaths += [System.IO.Path]::GetFullPath($ManagedNssmPath) }
    if (-not [System.IO.Path]::IsPathRooted($executablePath) -or
        [System.IO.Path]::GetFullPath($executablePath) -notin $allowedPaths) {
        throw "A service named '$($ExistingDefinition.Name)' already exists but points to a different executable: $pathName. Uninstall it or change AppName before deploying."
    }
}
function Resolve-NssmSourceExecutable {
    param([string]$Path, [string]$ChocolateyRoot = $env:ChocolateyInstall)
    $source = [IO.Path]::GetFullPath($Path)
    if (-not $ChocolateyRoot -and $env:ProgramData) { $ChocolateyRoot = Join-Path $env:ProgramData 'chocolatey' }
    if ($ChocolateyRoot) {
        $shim = [IO.Path]::GetFullPath((Join-Path $ChocolateyRoot 'bin/nssm.exe'))
        if ($source -ieq $shim) {
            # Chocolatey's shim resolves its target relative to its original
            # directory and cannot be relocated into the protected service tree.
            $source = [IO.Path]::GetFullPath((Join-Path $ChocolateyRoot 'lib/nssm/tools/nssm.exe'))
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw 'Chocolatey NSSM executable is missing. Pass -NssmPath pointing to the actual nssm.exe rather than its bin shim.'
            }
        }
    }
    return $source
}
function Copy-ManagedNssmBinary {
    param($Config, [string]$SourcePath, [string]$RuntimePath, [string]$Account)
    if ([IO.Path]::GetFullPath($SourcePath) -ieq [IO.Path]::GetFullPath($RuntimePath)) {
        Set-WindowsProtectedPathSecurity -Path $RuntimePath -Account $Account
        return
    }
    if (Test-Path -LiteralPath $RuntimePath -PathType Leaf) {
        $backupDirectory = Get-ConfigString $Config 'BackupDirectory' (Join-Path $Config.ServiceDirectory 'backups')
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
        Copy-Item -LiteralPath $RuntimePath -Destination (Join-Path $backupDirectory "$($Config.AppName).nssm.exe.$stamp.$([Guid]::NewGuid().ToString('N')).bak") -ErrorAction Stop
    }
    Copy-Item -LiteralPath $SourcePath -Destination $RuntimePath -Force -ErrorAction Stop
    Set-WindowsProtectedPathSecurity -Path $RuntimePath -Account $Account
}
function Set-NssmRuntimeServicePath {
    param($Config, [string]$RuntimePath)
    $escapedName = ([string]$Config.AppName).Replace("'", "''")
    $definition = Get-CimInstance Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
    if (-not $definition) { throw 'NSSM service registration is missing while migrating its protected executable.' }
    $result = Invoke-CimMethod -InputObject $definition -MethodName Change -Arguments @{ PathName = ('"' + $RuntimePath + '"') } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) { throw "Could not migrate NSSM to its protected executable (code $($result.ReturnValue))." }
}
function Set-NssmServiceAccount {
    param($Config, [string]$Nssm, $Settings)

    if (-not $Settings.PreserveExisting) {
        if (-not $Settings.IsBuiltIn) { Grant-WindowsServiceLogonRight -Account $Settings.Account }
        if ($Settings.Password) {
            # CIM keeps credentials out of child-process command lines.
            $escapedName = ([string]$Config.AppName).Replace("'", "''")
            $definition = Get-CimInstance Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
            if (-not $definition) { throw 'NSSM service registration is missing while configuring its credential.' }
            $result = Invoke-CimMethod -InputObject $definition -MethodName Change -Arguments @{ StartName = [string]$Settings.Account; StartPassword = [string]$Settings.Password } -ErrorAction Stop
            if ($result.ReturnValue -ne 0) { throw "Could not set NSSM service credential (code $($result.ReturnValue))." }
            return
        }
        $accountArgs = @("set", [string]$Config.AppName, "ObjectName", [string]$Settings.Account)
        if ($Settings.IsGmsa) {
            # Windows PowerShell and legacy native argument passing discard an
            # empty string; quoted empty text preserves NSSM's blank password.
            $argumentMode = Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
            $accountArgs += $(if ($PSVersionTable.PSEdition -eq "Desktop" -or -not $argumentMode -or $argumentMode -eq "Legacy") { '""' } else { "" })
        }
        Invoke-CheckedNativeCommand $Nssm $accountArgs "Set NSSM service account"
    }
}
function New-NssmRegistrySecurity {
    param([string]$Account)
    $acl = [Security.AccessControl.RegistrySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($administrators)
    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new($sid, [Security.AccessControl.RegistryRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    $runtime = Get-WindowsServiceSecuritySid -Account $Account
    if ($runtime -ne $system -and $runtime -ne $administrators) {
        $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new($runtime, [Security.AccessControl.RegistryRights]::ReadKey,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    return $acl
}
function Set-NssmRegistrySecurity {
    param($Config, [string]$Account)
    $acl = New-NssmRegistrySecurity -Account $Account
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters",
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        ([Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::TakeOwnership))
    if (-not $key) { throw 'NSSM Parameters registry key is missing while protecting environment secrets.' }
    try { $key.SetAccessControl($acl) } finally { $key.Dispose() }
}
function Set-NssmServiceEnvironment {
    param($Config, [string[]]$EnvironmentEntries)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$($Config.AppName)\Parameters", $true)
    if (-not $key) { throw 'NSSM Parameters registry key is missing while writing its runtime environment.' }
    try {
        # Environment secrets must not appear in NSSM child-process arguments.
        $key.SetValue('AppEnvironmentExtra', $EnvironmentEntries, [Microsoft.Win32.RegistryValueKind]::MultiString)
    } finally { $key.Dispose() }
}
Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')
Assert-WindowsDeploymentConfigIdentity -Config $config
if ($config.ServiceManager -ne "nssm") {
    throw "This installer supports ServiceManager='nssm'. For WinSW/PM2, use the dedicated scripts."
}
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
. (Join-Path $repoRoot "scripts\windows\PostDeployHealth.ps1")
. (Join-Path $repoRoot "scripts\windows\WindowsServiceSecurity.ps1")
. (Join-Path $repoRoot "scripts\windows\DeploymentTransaction.ps1")
[void](Assert-WindowsServiceSecurityPaths -Config $config)
$sourceNssm = Resolve-RepoPath -Path $NssmPath -BasePath $repoRoot
$sourceNssm = Resolve-NssmSourceExecutable -Path $sourceNssm
if (-not (Test-Path $sourceNssm -PathType Leaf)) { throw "NSSM not found at $sourceNssm. Place nssm.exe there or pass -NssmPath." }
$nssm = Join-Path $config.ServiceDirectory "$($config.AppName).nssm.exe"

$escapedName = ([string]$config.AppName).Replace("'", "''")
$existingDefinition = Get-CimInstance Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
Assert-NssmServicePathCompatible -ExistingDefinition $existingDefinition -ExpectedNssmPath $sourceNssm -ManagedNssmPath $nssm
$accountSettings = Get-NssmServiceAccountSettings -Config $config -ExistingDefinition $existingDefinition

if ($PSCmdlet.ShouldProcess($config.AppName, "Install NSSM service")) {
    $installerState = Start-ManagedServiceInstallerTransaction -Config $config -ExistingDeploymentLock $ExistingDeploymentLock -ExistingManagedDeploymentTransaction $ExistingManagedDeploymentTransaction
    $installerFailure = $null
    try {
    # Re-read under the app lease: a competing installer may have completed
    # between read-only prevalidation and our exclusive lock acquisition.
    $existingDefinition = Get-CimInstance Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
    Assert-NssmServicePathCompatible -ExistingDefinition $existingDefinition -ExpectedNssmPath $sourceNssm -ManagedNssmPath $nssm
    $accountSettings = Get-NssmServiceAccountSettings -Config $config -ExistingDefinition $existingDefinition
    Set-WindowsServiceFilesystemSecurity -Config $config -Account $accountSettings.Account
    $existingService = Get-Service -Name $config.AppName -ErrorAction SilentlyContinue
    if ($existingService) {
        if ([string]$existingService.Status -ne "Stopped") {
            Stop-Service -Name $config.AppName -Force -ErrorAction Stop
            $existingService.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        }
        Copy-ManagedNssmBinary -Config $config -SourcePath $sourceNssm -RuntimePath $nssm -Account $accountSettings.Account
        Set-NssmRuntimeServicePath -Config $config -RuntimePath $nssm
        Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "Application", [string]$config.NodeExe) "NSSM Application"
    } else {
        Copy-ManagedNssmBinary -Config $config -SourcePath $sourceNssm -RuntimePath $nssm -Account $accountSettings.Account
        Invoke-CheckedNativeCommand $nssm @("install", $config.AppName, [string]$config.NodeExe) "NSSM install"
    }

    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppDirectory", [string]$config.AppDirectory) "NSSM AppDirectory"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppParameters", "$($config.StartCommand) $($config.NodeArguments)") "NSSM AppParameters"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "DisplayName", [string]$config.DisplayName) "NSSM DisplayName"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "Description", [string]$config.Description) "NSSM Description"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppStdout", (Join-Path $config.LogDirectory "stdout.log")) "NSSM stdout log"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppStderr", (Join-Path $config.LogDirectory "stderr.log")) "NSSM stderr log"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRotateFiles", "1") "NSSM log rotation"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRotateBytes", "10485760") "NSSM log rotation size"
    Invoke-CheckedNativeCommand $nssm @("set", $config.AppName, "AppRestartDelay", "60000") "NSSM restart delay"
    $environmentEntries = @(ConvertTo-NssmEnvironmentArguments (ConvertTo-ServiceEnvironmentMap $config))
    Set-NssmRegistrySecurity -Config $config -Account $accountSettings.Account
    if ($environmentEntries.Count -gt 0) {
        Set-NssmServiceEnvironment -Config $config -EnvironmentEntries $environmentEntries
    }
    Set-NssmServiceAccount -Config $config -Nssm $nssm -Settings $accountSettings
    Invoke-CheckedNativeCommand "sc.exe" @("config", $config.AppName, "start=", "auto") "Set NSSM startup mode"
    Invoke-CheckedNativeCommand "sc.exe" @("failure", $config.AppName, "reset=", "86400", "actions=", "restart/60000/restart/60000/restart/300000") "Set NSSM recovery actions"
    Invoke-CheckedNativeCommand "sc.exe" @("failureflag", $config.AppName, "1") "Enable NSSM recovery actions"
    Invoke-CheckedNativeCommand $nssm @("start", $config.AppName) "NSSM start"

    $service = Get-Service -Name $config.AppName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Test-PostDeployHealth -Config $config
    Write-Host "Installed NSSM service: $($config.AppName)" -ForegroundColor Green
    } catch {
        $installerFailure = $_
        throw
    } finally {
        Complete-ManagedServiceInstallerTransaction -Config $config -State $installerState -Failure $installerFailure
    }
}
