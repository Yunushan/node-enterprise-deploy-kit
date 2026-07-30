[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $NssmPath = "tools\nssm\nssm.exe",
    [switch] $RemoveHealthCheckTask
)
function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run as Administrator." }
}
function Resolve-RepoPath([string]$Path, [string]$BasePath) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $BasePath $Path)
}
function Get-HealthTaskDirectory($Config) {
    if ([string]$Config.AppName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "AppName contains characters that are unsafe for the managed health-task directory."
    }
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw "Windows ProgramData directory could not be resolved." }
    return (Join-Path (Join-Path $programData "node-enterprise-deploy-kit\healthchecks") ([string]$Config.AppName))
}
function Remove-ManagedHealthTaskDirectory($Config) {
    $taskDirectory = Get-HealthTaskDirectory $Config
    if (-not (Test-Path -LiteralPath $taskDirectory)) { return }
    $item = Get-Item -LiteralPath $taskDirectory -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a managed health-task directory that is a reparse point: $taskDirectory"
    }
    if ($PSCmdlet.ShouldProcess($taskDirectory, "Remove protected managed health-task files")) {
        Remove-Item -LiteralPath $taskDirectory -Recurse -Force
    }
}
function Invoke-NativeCommand([string]$FilePath, [string[]]$Arguments, [string]$Label, [switch]$IgnoreExitCode) {
    & $FilePath @Arguments
    if (-not $IgnoreExitCode -and $LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}
function Uninstall-WinSWService($Config) {
    $serviceExe = Join-Path $Config.ServiceDirectory "$($Config.AppName).exe"
    if (Test-Path $serviceExe) {
        if ($PSCmdlet.ShouldProcess($Config.AppName, "Stop and uninstall WinSW service")) {
            Invoke-NativeCommand $serviceExe @("stop") "WinSW stop" -IgnoreExitCode
            Invoke-NativeCommand $serviceExe @("uninstall") "WinSW uninstall"
        }
    } else {
        Write-Warning "Service wrapper not found: $serviceExe"
    }
}
function Uninstall-NssmService($Config, [string]$ResolvedNssmPath) {
    if ($PSCmdlet.ShouldProcess($Config.AppName, "Stop and uninstall NSSM service")) {
        if (Test-Path $ResolvedNssmPath) {
            Invoke-NativeCommand $ResolvedNssmPath @("stop", $Config.AppName) "NSSM stop" -IgnoreExitCode
            Invoke-NativeCommand $ResolvedNssmPath @("remove", $Config.AppName, "confirm") "NSSM remove" -IgnoreExitCode
        } else {
            Write-Warning "NSSM not found at $ResolvedNssmPath. Falling back to sc.exe stop/delete for service '$($Config.AppName)'."
            Invoke-NativeCommand "sc.exe" @("stop", $Config.AppName) "sc.exe stop" -IgnoreExitCode
            Invoke-NativeCommand "sc.exe" @("delete", $Config.AppName) "sc.exe delete" -IgnoreExitCode
        }
    }
}
function Uninstall-Pm2Process($Config) {
    if ($PSCmdlet.ShouldProcess($Config.AppName, "Stop and remove PM2 fallback process")) {
        if (Get-Command pm2 -ErrorAction SilentlyContinue) {
            Invoke-NativeCommand "pm2" @("delete", $Config.AppName) "pm2 delete" -IgnoreExitCode
            Invoke-NativeCommand "pm2" @("save") "pm2 save" -IgnoreExitCode
        } else {
            Write-Warning "PM2 was not found in PATH. Remove any remaining PM2 process for '$($Config.AppName)' manually if it still exists."
        }
        if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
            $ecosystemPath = Join-Path $Config.ServiceDirectory "$($Config.AppName).pm2.config.cjs"
            Remove-Item -LiteralPath $ecosystemPath -Force -ErrorAction SilentlyContinue
        }
    }
}
Assert-Admin
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$serviceManager = "winsw"
if ($config.PSObject.Properties["ServiceManager"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ServiceManager)) {
    $serviceManager = [string]$config.ServiceManager
}
$serviceManager = $serviceManager.ToLowerInvariant()
$resolvedNssmPath = Resolve-RepoPath -Path $NssmPath -BasePath $repoRoot
switch ($serviceManager) {
    "winsw" { Uninstall-WinSWService $config }
    "nssm"  { Uninstall-NssmService $config $resolvedNssmPath }
    "pm2"   { Uninstall-Pm2Process $config }
    default { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
}
if ($RemoveHealthCheckTask) {
    $taskName = "$($config.AppName)-HealthCheck"
    if ($PSCmdlet.ShouldProcess($taskName, "Remove scheduled task")) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-ManagedHealthTaskDirectory $config
    }
}
