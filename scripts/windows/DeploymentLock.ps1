Set-StrictMode -Version Latest

function Get-DeploymentLockConfigString {
    param($Config, [string]$Name, [string]$Default = "")

    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

function Get-DeploymentLockTimeoutSeconds {
    param($Config)

    $raw = Get-DeploymentLockConfigString $Config "DeploymentLockTimeoutSeconds" "0"
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value) -or $value -lt 0 -or $value -gt 3600) {
        throw "DeploymentLockTimeoutSeconds must be an integer from 0 through 3600."
    }
    return $value
}

function Get-DeploymentLockDirectory {
    param($Config)

    $configured = Get-DeploymentLockConfigString $Config "DeploymentLockDirectory" ""
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not [System.IO.Path]::IsPathRooted($configured)) {
            throw "DeploymentLockDirectory must be an absolute path."
        }
        return [System.IO.Path]::GetFullPath($configured)
    }

    $serviceDirectory = Get-DeploymentLockConfigString $Config "ServiceDirectory" ""
    if (-not [string]::IsNullOrWhiteSpace($serviceDirectory)) {
        if (-not [System.IO.Path]::IsPathRooted($serviceDirectory)) {
            throw "ServiceDirectory must be an absolute path for deployment locking."
        }
        return [System.IO.Path]::GetFullPath((Join-Path $serviceDirectory ".deployment-locks"))
    }

    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonApplicationData)) {
        throw "DeploymentLockDirectory is required because the system ProgramData path could not be resolved."
    }
    return [System.IO.Path]::GetFullPath((Join-Path $commonApplicationData "node-enterprise-deploy-kit\deployment-locks"))
}

function Set-ProtectedDeploymentLockDirectoryAcl {
    param([string]$Path)

    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, $rights, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($administratorsSid, $rights, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Enter-DeploymentLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Config,
        [switch]$SkipAclHardening
    )

    $appName = Get-DeploymentLockConfigString $Config "AppName" ""
    if ([string]::IsNullOrWhiteSpace($appName)) {
        throw "AppName is required for deployment locking."
    }
    $safeName = ($appName -replace '[^A-Za-z0-9_.-]', '_')
    $lockDirectory = Get-DeploymentLockDirectory $Config
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    if (-not $SkipAclHardening) {
        Set-ProtectedDeploymentLockDirectoryAcl -Path $lockDirectory
    }

    $lockPath = Join-Path $lockDirectory "$safeName.lock"
    $timeoutSeconds = Get-DeploymentLockTimeoutSeconds $Config
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    $stream = $null
    do {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Another deployment is already active for '$appName'. Lock: $lockPath"
            }
            Start-Sleep -Milliseconds 250
        }
    } while ($null -eq $stream)

    try {
        $metadata = "AppName=$appName`r`nProcessId=$PID`r`nAcquiredAtUtc=$([DateTime]::UtcNow.ToString('o'))`r`n"
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($metadata)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch {
        $stream.Dispose()
        throw
    }

    Write-Host "Acquired deployment lock for: $appName"
    return [pscustomobject]@{
        AppName = $appName
        Path = $lockPath
        Stream = $stream
    }
}

function Exit-DeploymentLock {
    param($Lock)

    if ($null -eq $Lock) { return }
    if ($Lock.Stream) {
        $Lock.Stream.Dispose()
    }
    Write-Host "Released deployment lock for: $($Lock.AppName)"
}
