Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DeploymentLock.ps1')
. (Join-Path $PSScriptRoot 'WindowsPm2ExecutionPolicy.ps1')

function Get-WindowsServiceSecurityConfigString {
    param($Config, [string]$Name, [string]$Default = "")
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) { return [string]$Config.$Name }
    return $Default
}

function Get-WindowsServiceSecurityFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+[\\/])' -or $Path -match '[*?]|(?<!^[A-Za-z]):') { throw "Service security paths must be absolute directories below a drive/share root without wildcard or alternate-stream syntax." }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')) { throw "Refusing service security changes on a drive/share root." }
    return $full
}

function Test-WindowsServiceSecurityPathWithin {
    param([string]$Path, [string]$Root)
    return ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Assert-WindowsServiceSecurityNoReparse {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Service/cache security paths must not contain reparse points: $current" }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-WindowsRuntimeWritablePaths {
    param($Config)
    $app = Get-WindowsServiceSecurityFullPath -Path ([string]$Config.AppDirectory)
    $relativePaths = @()
    if ($Config.PSObject.Properties['RuntimeWritableDirectories']) {
        if ($Config.RuntimeWritableDirectories -is [string] -or $Config.RuntimeWritableDirectories -isnot [System.Collections.IEnumerable]) { throw "RuntimeWritableDirectories must be an array of app-relative directory paths." }
        $relativePaths = @($Config.RuntimeWritableDirectories)
    } elseif ((Get-WindowsServiceSecurityConfigString $Config 'AppFramework') -eq 'nextjs') {
        $relativePaths = @('.next/cache')
    }
    foreach ($relative in $relativePaths) {
        if ($relative -isnot [string] -or [string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)|[:*?]') { throw "RuntimeWritableDirectories must contain safe app-relative paths without traversal or alternate streams." }
        $full = [IO.Path]::GetFullPath((Join-Path $app $relative)).TrimEnd('\', '/')
        if ($full -eq $app -or -not (Test-WindowsServiceSecurityPathWithin -Path $full -Root $app)) { throw "Runtime-writable directories must stay strictly inside AppDirectory." }
        Assert-WindowsServiceSecurityNoReparse -Path $full
        $full
    }
}

function Assert-WindowsServiceSecurityPaths {
    param($Config)
    $app = Get-WindowsServiceSecurityFullPath ([string]$Config.AppDirectory)
    $service = Get-WindowsServiceSecurityFullPath ([string]$Config.ServiceDirectory)
    $logs = Get-WindowsServiceSecurityFullPath ([string]$Config.LogDirectory)
    $backup = Get-WindowsServiceSecurityFullPath (Get-WindowsServiceSecurityConfigString $Config 'BackupDirectory' (Join-Path $service 'backups'))
    $lock = Get-WindowsServiceSecurityFullPath (Get-DeploymentLockDirectory -Config $Config)
    foreach ($path in @($app, $service, $logs, $backup, $lock)) { Assert-WindowsServiceSecurityNoReparse -Path $path }
    foreach ($control in @($service, $backup, $lock)) {
        if ((Test-WindowsServiceSecurityPathWithin $control $app) -or (Test-WindowsServiceSecurityPathWithin $app $control)) { throw "AppDirectory must not overlap service, backup, or deployment-control directories." }
        if ((Test-WindowsServiceSecurityPathWithin $control $logs) -or (Test-WindowsServiceSecurityPathWithin $logs $control)) { throw "LogDirectory must not overlap service, backup, or deployment-control directories." }
        foreach ($cache in @(Get-WindowsRuntimeWritablePaths -Config $Config)) {
            if ((Test-WindowsServiceSecurityPathWithin $control $cache) -or (Test-WindowsServiceSecurityPathWithin $cache $control)) { throw "Runtime cache directories must not overlap deployment-control directories." }
        }
    }
    return [pscustomobject]@{ App = $app; Service = $service; Logs = $logs; Backup = $backup; Lock = $lock; Writable = @(Get-WindowsRuntimeWritablePaths -Config $Config) }
}

function Get-WindowsServiceSecuritySid {
    param([string]$Account)
    switch ($Account.Trim().ToLowerInvariant()) {
        'localsystem' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-18') }
        'nt authority\system' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-18') }
        'localservice' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-19') }
        'nt authority\localservice' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-19') }
        'networkservice' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-20') }
        'nt authority\networkservice' { return [Security.Principal.SecurityIdentifier]::new('S-1-5-20') }
        default { return ([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]) }
    }
}

function Initialize-WindowsServiceLogonRights {
    if ('NodeEnterpriseDeployKit.Security.ServiceLogonRights' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace NodeEnterpriseDeployKit.Security {
    public static class ServiceLogonRights {
        [StructLayout(LayoutKind.Sequential)]
        private struct ObjectAttributes {
            public uint Length; public IntPtr RootDirectory; public IntPtr ObjectName;
            public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
        [DllImport("advapi32.dll")] private static extern uint LsaOpenPolicy(IntPtr systemName, ref ObjectAttributes attributes, uint access, out IntPtr policy);
        [DllImport("advapi32.dll")] private static extern uint LsaAddAccountRights(IntPtr policy, IntPtr sid, [In] UnicodeString[] rights, uint count);
        [DllImport("advapi32.dll")] private static extern uint LsaClose(IntPtr policy);
        [DllImport("advapi32.dll")] private static extern uint LsaNtStatusToWinError(uint status);
        private static void Check(uint status) { if (status != 0) { throw new Win32Exception((int)LsaNtStatusToWinError(status)); } }
        public static void Grant(byte[] sidBytes) {
            IntPtr policy = IntPtr.Zero, sid = IntPtr.Zero, text = IntPtr.Zero;
            try {
                ObjectAttributes attributes = new ObjectAttributes();
                attributes.Length = (uint)Marshal.SizeOf(typeof(ObjectAttributes));
                // POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES, scoped to adding this right.
                Check(LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x810, out policy));
                sid = Marshal.AllocHGlobal(sidBytes.Length); Marshal.Copy(sidBytes, 0, sid, sidBytes.Length);
                const string name = "SeServiceLogonRight";
                text = Marshal.StringToHGlobalUni(name);
                UnicodeString right = new UnicodeString();
                right.Length = (ushort)(name.Length * 2); right.MaximumLength = (ushort)(right.Length + 2); right.Buffer = text;
                Check(LsaAddAccountRights(policy, sid, new UnicodeString[] { right }, 1));
            } finally {
                if (text != IntPtr.Zero) Marshal.FreeHGlobal(text);
                if (sid != IntPtr.Zero) Marshal.FreeHGlobal(sid);
                if (policy != IntPtr.Zero) LsaClose(policy);
            }
        }
    }
}
'@
}

function Grant-WindowsServiceLogonRight {
    param([string]$Account)
    $sid = Get-WindowsServiceSecuritySid -Account $Account
    if ($sid.Value -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')) { return }
    Initialize-WindowsServiceLogonRights
    $bytes = New-Object byte[] $sid.BinaryLength
    $sid.GetBinaryForm($bytes, 0)
    [NodeEnterpriseDeployKit.Security.ServiceLogonRights]::Grant($bytes)
}

function New-WindowsProtectedPathAcl {
    param([bool]$Directory, [string]$Account = '', [Security.AccessControl.FileSystemRights]$RuntimeRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute, [string]$OwnerAccount = '')
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $ownerSid = if ($OwnerAccount) { Get-WindowsServiceSecuritySid -Account $OwnerAccount } else { $administrators }
    $acl.SetOwner($ownerSid)
    $inherit = if ($Directory) { [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    if (-not [string]::IsNullOrWhiteSpace($Account)) {
        $runtimeSid = Get-WindowsServiceSecuritySid -Account $Account
        if ($runtimeSid -ne $system -and $runtimeSid -ne $administrators) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($runtimeSid, $RuntimeRights, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        }
    }
    return $acl
}

function Set-WindowsProtectedPathSecurity {
    param([string]$Path, [string]$Account = '', [Security.AccessControl.FileSystemRights]$RuntimeRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute, [switch]$Recurse, [string[]]$ExcludePaths = @(), [string]$OwnerAccount = '')
    Assert-WindowsServiceSecurityNoReparse -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $acl = New-WindowsProtectedPathAcl -Directory $item.PSIsContainer -Account $Account -RuntimeRights $RuntimeRights -OwnerAccount $OwnerAccount
    $existingAcl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
    $sections = [Security.AccessControl.AccessControlSections]::Access
    if ($existingAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { $sections = $sections -bor [Security.AccessControl.AccessControlSections]::Owner }
    $persistedAcl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $persistedAcl.SetSecurityDescriptorSddlForm($acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner), $sections)
    $acl = $persistedAcl
    try {
        # Set-Acl on PowerShell 7 may request SACL privileges when replacing an
        # already protected DACL. Persist only the changed owner/access sections.
        if ($PSVersionTable.PSEdition -eq 'Core') {
            if ($item.PSIsContainer) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$item, $acl) }
            else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$item, $acl) }
        } else { $item.SetAccessControl($acl) }
    } catch { throw "Failed to protect '$($item.FullName)': $($_.Exception.Message)" }
    if ($Recurse -and $item.PSIsContainer) {
        # Enumerate one directory at a time, rejecting links before descent.
        foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing ACL traversal through a reparse point: $($child.FullName)" }
            if (@($ExcludePaths | Where-Object { Test-WindowsServiceSecurityPathWithin -Path $child.FullName -Root $_ }).Count -gt 0) { continue }
            Set-WindowsProtectedPathSecurity -Path $child.FullName -Account $Account -RuntimeRights $RuntimeRights -Recurse -ExcludePaths $ExcludePaths -OwnerAccount $OwnerAccount
        }
    }
}

function Set-WindowsProtectedFileSecurity {
    param([string]$Path, [string]$Account = '', [string]$OwnerAccount = '')
    Set-WindowsProtectedPathSecurity -Path $Path -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::Read) -OwnerAccount $OwnerAccount
}

function Restore-WindowsPathSecurity {
    param([string]$Path, [string]$Sddl)
    Assert-WindowsServiceSecurityNoReparse -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetSecurityDescriptorSddlForm($Sddl, $sections)
    $existingAcl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
    $changed = [Security.AccessControl.AccessControlSections]::Access
    if ($existingAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { $changed = $changed -bor [Security.AccessControl.AccessControlSections]::Owner }
    if ($existingAcl.GetGroup([Security.Principal.SecurityIdentifier]).Value -ne $acl.GetGroup([Security.Principal.SecurityIdentifier]).Value) { $changed = $changed -bor [Security.AccessControl.AccessControlSections]::Group }
    $persistedAcl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $persistedAcl.SetSecurityDescriptorSddlForm($Sddl, $changed)
    $acl = $persistedAcl
    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            if ($item.PSIsContainer) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$item, $acl) }
            else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$item, $acl) }
        }
        else { $item.SetAccessControl($acl) }
    } catch { throw "Failed to restore path security for '$Path': $($_.Exception.Message)" }
}

function Restore-WindowsFileSecurity {
    param([string]$Path, [string]$Sddl)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'File ACL restoration requires an existing regular file.' }
    Restore-WindowsPathSecurity -Path $Path -Sddl $Sddl
}

function Set-WindowsServiceFilesystemSecurity {
    param($Config, [string]$Account)
    $paths = Assert-WindowsServiceSecurityPaths -Config $Config
    foreach ($path in @($paths.Service, $paths.Logs, $paths.Backup)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Set-WindowsProtectedPathSecurity -Path $paths.App -Account $Account -Recurse
    Set-WindowsProtectedPathSecurity -Path $paths.Service -Account $Account -Recurse -ExcludePaths @($paths.Backup, $paths.Lock)
    Set-WindowsProtectedPathSecurity -Path $paths.Backup -Recurse
    if (Test-Path -LiteralPath $paths.Lock) { Set-WindowsProtectedPathSecurity -Path $paths.Lock }
    Set-WindowsProtectedPathSecurity -Path $paths.Logs -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::Modify) -Recurse
    foreach ($path in $paths.Writable) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-WindowsProtectedPathSecurity -Path $path -Account $Account -RuntimeRights ([Security.AccessControl.FileSystemRights]::Modify) -Recurse
    }
}

function Get-WindowsPm2RuntimeContext {
    param($Config)
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pm2ResolvedHome = Get-WindowsServiceSecurityConfigString $Config 'PM2Home' ''
    if (-not $pm2ResolvedHome) { $pm2ResolvedHome = if ($env:PM2_HOME) { $env:PM2_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.pm2' } }
    $pm2ResolvedHome = Get-WindowsServiceSecurityFullPath -Path $pm2ResolvedHome
    Assert-WindowsServiceSecurityNoReparse -Path $pm2ResolvedHome
    $command = Get-Command (Get-WindowsServiceSecurityConfigString $Config 'PM2Command' 'pm2') -ErrorAction Stop
    if ($command.CommandType -notin @([Management.Automation.CommandTypes]::Application, [Management.Automation.CommandTypes]::ExternalScript) -or [string]::IsNullOrWhiteSpace($command.Source)) { throw 'PM2Command must resolve to an external executable or script path.' }
    $commandPath = Get-WindowsServiceSecurityFullPath -Path ([string]$command.Source)
    Assert-WindowsServiceSecurityNoReparse -Path $commandPath
    return [pscustomobject]@{ Account = $account; Home = $pm2ResolvedHome; CommandName = $commandPath }
}
