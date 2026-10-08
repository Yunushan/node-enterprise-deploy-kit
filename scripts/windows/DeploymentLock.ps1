Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')

function Get-DeploymentLockConfigString {
    param($Config, [string]$Name, [string]$Default = "")

    if ($Config -is [Collections.IDictionary] -and $Config.Contains($Name) -and -not [string]::IsNullOrWhiteSpace([string]$Config[$Name])) {
        return [string]$Config[$Name]
    }
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

    $appName = Get-DeploymentLockConfigString $Config 'AppName' ''
    Assert-WindowsDeploymentAppName -AppName $appName
    $configured = Get-DeploymentLockConfigString $Config "DeploymentLockDirectory" ""
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not [System.IO.Path]::IsPathRooted($configured)) {
            throw "DeploymentLockDirectory must be an absolute path."
        }
        $resolved = [System.IO.Path]::GetFullPath($configured)
        if ($resolved.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\', '/')) {
            throw 'DeploymentLockDirectory must not be a filesystem root.'
        }
        return $resolved
    }

    # Service-manager selection and service-directory changes must not create
    # a second mutex for the same app name during a first install.
    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonApplicationData)) {
        throw "DeploymentLockDirectory is required because the system ProgramData path could not be resolved."
    }
    return [System.IO.Path]::GetFullPath((Join-Path $commonApplicationData "node-enterprise-deploy-kit\deployment-locks"))
}

function Set-ProtectedDeploymentLockDirectoryAcl {
    param([string]$Path)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        [IO.File]::SetUnixFileMode($Path, ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
        return
    }
    if (-not (Get-Command Set-WindowsProtectedPathSecurity -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'WindowsServiceSecurity.ps1')
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.User.Value -eq 'S-1-5-18') {
        Set-WindowsProtectedPathSecurity -Path $Path
    } else {
        # File-only standalone imports may use a caller-owned explicit lock
        # directory. Keep it private without requiring an administrator owner.
        Set-WindowsProtectedPathSecurity -Path $Path -Account $identity.Name -OwnerAccount $identity.Name -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl)
    }
}

function Assert-DeploymentPathNotReparsePoint {
    param([string]$Path)
    $current = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Deployment control paths must not contain reparse points: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-ExistingDeploymentLock {
    param($Config, $Lock)
    $appName = Get-DeploymentLockConfigString $Config "AppName" ""
    $expectedPath = Join-Path (Get-DeploymentLockDirectory $Config) (($appName -creplace '[^A-Za-z0-9_.-]', '_') + '.lock')
    if ($null -eq $Lock -or $Lock.OwnerProcessId -ne $PID -or $Lock.AppName -ne $appName -or
        $Lock.Stream -isnot [System.IO.FileStream] -or -not $Lock.Stream.CanWrite -or
        [System.IO.Path]::GetFullPath($Lock.Path) -ne [System.IO.Path]::GetFullPath($expectedPath) -or
        [System.IO.Path]::GetFullPath($Lock.Stream.Name) -ne [System.IO.Path]::GetFullPath($expectedPath)) {
        throw "The existing deployment lock must be a live lock for this application held by this process."
    }
    $probe = $null
    try {
        $probe = [System.IO.File]::Open($expectedPath, 'Open', 'Read', 'ReadWrite')
    } catch [System.IO.IOException] { return }
    finally { if ($probe) { $probe.Dispose() } }
    throw "The existing deployment lock does not hold exclusive access."
}

function Get-PendingDeploymentRecoveryPaths {
    param([string]$AppName, [string]$LockDirectory)

    if ([string]::IsNullOrWhiteSpace($AppName)) { throw 'AppName is required to inspect deployment recovery state.' }
    Assert-DeploymentPathNotReparsePoint -Path $LockDirectory
    if (-not (Test-Path -LiteralPath $LockDirectory -PathType Container)) { return @() }
    $safeName = $AppName -creplace '[^A-Za-z0-9_.-]', '_'
    $recoveryPattern = '^' + [regex]::Escape($safeName) + '\.[0-9]+\.(?:managed-transaction\..+|package-transaction\.json)$'
    return @(Get-ChildItem -LiteralPath $LockDirectory -Force -ErrorAction Stop | Where-Object {
        $_.Name -match $recoveryPattern
    } | ForEach-Object { $_.FullName })
}

function Assert-NoPendingDeploymentRecovery {
    param($Config, [string]$LockDirectory)

    $directories = @($LockDirectory)
    $serviceDirectory = Get-DeploymentLockConfigString $Config 'ServiceDirectory' ''
    if ($serviceDirectory -and [IO.Path]::IsPathRooted($serviceDirectory)) {
        $directories += Join-Path $serviceDirectory '.deployment-locks'
    }
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $monitorPath = Join-Path $programData "node-enterprise-deploy-kit\healthchecks\$($Config.AppName)\health-monitor.config.json"
    Assert-DeploymentPathNotReparsePoint $monitorPath
    if (Test-Path -LiteralPath $monitorPath -PathType Leaf) {
        $monitor = Get-Content -LiteralPath $monitorPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($monitor.PSObject.Properties['DeploymentLockPath'] -and [IO.Path]::IsPathRooted([string]$monitor.DeploymentLockPath)) {
            $directories += Split-Path -Parent ([string]$monitor.DeploymentLockPath)
        }
    }
    $pending = @($directories | Select-Object -Unique | ForEach-Object {
        Get-PendingDeploymentRecoveryPaths -AppName ([string]$Config.AppName) -LockDirectory $_
    })
    if ($pending.Count -gt 0) {
        throw "Unresolved deployment recovery state exists for '$($Config.AppName)'. Keep the service and health task stopped, inspect and recover the retained journal/backup as described in docs/RUNBOOK.md, then archive the recovery state before deploying again. Recovery paths: $($pending -join ', ')"
    }
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
    $safeName = ($appName -creplace '[^A-Za-z0-9_.-]', '_')
    $lockDirectory = Get-DeploymentLockDirectory $Config
    Assert-DeploymentPathNotReparsePoint -Path $lockDirectory
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    if (-not $SkipAclHardening) {
        Set-ProtectedDeploymentLockDirectoryAcl -Path $lockDirectory
    }

    $lockPath = Join-Path $lockDirectory "$safeName.lock"
    Assert-DeploymentPathNotReparsePoint -Path $lockPath
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
        Assert-NoPendingDeploymentRecovery -Config $Config -LockDirectory $lockDirectory
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
        OwnerProcessId = $PID
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
