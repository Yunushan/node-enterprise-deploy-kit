<#
.SYNOPSIS
  List or restore managed Windows deployment backups.
.DESCRIPTION
  Restores only files and scheduled-task exports created by this deployment kit.
  It does not restore application databases, release artifacts, or private
  runtime secrets outside the configured backup directory.
.EXAMPLE
  .\scripts\windows\Restore-ManagedBackup.ps1 -ConfigPath .\config\windows\app.config.json -List
.EXAMPLE
  .\scripts\windows\Restore-ManagedBackup.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest
.EXAMPLE
  .\scripts\windows\Restore-ManagedBackup.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [ValidateSet("All", "ServiceExe", "ServiceXml", "IisWebConfig", "HealthCheckTask")] [string] $Target = "All",
    [switch] $List,
    [switch] $Latest,
    [string] $BackupPath = "",
    [switch] $RestartService,
    [switch] $RecycleIisAppPool
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator when restoring backups."
    }
}
function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return (Join-Path $Config.ServiceDirectory "backups")
    }
    throw "BackupDirectory or ServiceDirectory must be configured."
}
function New-TargetDefinition($Name, $Pattern, $Destination, $Kind) {
    [pscustomobject]@{
        Target = $Name
        Pattern = $Pattern
        Destination = $Destination
        Kind = $Kind
    }
}
function Get-TargetDefinitions($Config) {
    $definitions = New-Object System.Collections.Generic.List[object]
    $appName = [string]$Config.AppName
    $serviceDirectory = Get-ConfigString $Config "ServiceDirectory" ""
    if ($serviceDirectory) {
        $definitions.Add((New-TargetDefinition "ServiceExe" "$appName.exe.*.bak" (Join-Path $serviceDirectory "$appName.exe") "File")) | Out-Null
        $definitions.Add((New-TargetDefinition "ServiceXml" "$appName.xml.*.bak" (Join-Path $serviceDirectory "$appName.xml") "File")) | Out-Null
    }

    $iisSitePath = Get-ConfigString $Config "IisSitePath" ""
    if ($iisSitePath) {
        $definitions.Add((New-TargetDefinition "IisWebConfig" "web.config.*.bak" (Join-Path $iisSitePath "web.config") "File")) | Out-Null
    }

    $taskName = "$appName-HealthCheck"
    $definitions.Add((New-TargetDefinition "HealthCheckTask" "$taskName.*.xml.bak" "ScheduledTask:$taskName" "ScheduledTask")) | Out-Null
    return @($definitions)
}
function New-BackupRecord($Definition, [System.IO.FileInfo]$File) {
    [pscustomobject]@{
        Target = $Definition.Target
        BackupPath = $File.FullName
        Destination = $Definition.Destination
        Kind = $Definition.Kind
        LastWriteTime = $File.LastWriteTime
        Length = $File.Length
    }
}
function Get-BackupRecords($Config) {
    $backupDirectory = Get-BackupDirectory $Config
    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        return @()
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($definition in Get-TargetDefinitions $Config) {
        Get-ChildItem -LiteralPath $backupDirectory -File -Filter $definition.Pattern -ErrorAction SilentlyContinue |
            ForEach-Object { $records.Add((New-BackupRecord $definition $_)) | Out-Null }
    }
    return @($records | Sort-Object Target, LastWriteTime -Descending)
}
function Resolve-BackupRecordByPath($Config, [string]$Path) {
    $backupDirectory = Get-BackupDirectory $Config
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $backupDirectory $candidate
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Backup file not found: $candidate"
    }

    $file = Get-Item -LiteralPath $candidate
    foreach ($definition in Get-TargetDefinitions $Config) {
        if ($file.Name -like $definition.Pattern) {
            if ($Target -ne "All" -and $Target -ne $definition.Target) {
                throw "Backup '$candidate' is for $($definition.Target), but Target is $Target."
            }
            return New-BackupRecord $definition $file
        }
    }

    throw "Backup file name does not match a known managed backup pattern: $candidate"
}
function Select-RestoreRecords($Config) {
    if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
        return @(Resolve-BackupRecordByPath $Config $BackupPath)
    }
    if (-not $Latest) {
        throw "Use -List to inspect backups, or provide -Latest or -BackupPath to restore."
    }

    $records = @(Get-BackupRecords $Config)
    if ($Target -ne "All") {
        $records = @($records | Where-Object { $_.Target -eq $Target })
    }
    if ($records.Count -eq 0) {
        throw "No managed backups found for target: $Target"
    }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($records | Group-Object Target)) {
        $selected.Add(($group.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1)) | Out-Null
    }
    return @($selected | Sort-Object Target)
}
function Stop-AppServiceIfRequested($Config, [bool]$Requested) {
    if (-not $Requested) { return $false }
    $service = Get-Service -Name $Config.AppName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning "Service not found for restart: $($Config.AppName)"
        return $false
    }
    if ($service.Status -ne "Stopped") {
        if ($PSCmdlet.ShouldProcess($Config.AppName, "Stop service before restore")) {
            Stop-Service -Name $Config.AppName -Force -ErrorAction Stop
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        }
    }
    return $true
}
function Start-AppServiceIfRequested($Config, [bool]$Requested) {
    if (-not $Requested) { return }
    $service = Get-Service -Name $Config.AppName -ErrorAction SilentlyContinue
    if (-not $service) { return }
    if ($PSCmdlet.ShouldProcess($Config.AppName, "Start service after restore")) {
        Start-Service -Name $Config.AppName -ErrorAction Stop
    }
}
function Restore-FileBackup($Record) {
    $destinationDirectory = Split-Path -Parent $Record.Destination
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    }
    if ($PSCmdlet.ShouldProcess($Record.Destination, "Restore $($Record.Target) from $($Record.BackupPath)")) {
        Copy-Item -LiteralPath $Record.BackupPath -Destination $Record.Destination -Force
        Write-Host "Restored $($Record.Target): $($Record.Destination)" -ForegroundColor Green
    }
}
function Restore-ScheduledTaskBackup($Record) {
    $taskName = $Record.Destination.Substring("ScheduledTask:".Length)
    if ($PSCmdlet.ShouldProcess($taskName, "Restore scheduled task from $($Record.BackupPath)")) {
        $xml = Get-Content -LiteralPath $Record.BackupPath -Raw
        Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
        Write-Host "Restored scheduled task: $taskName" -ForegroundColor Green
    }
}
function Restart-IisAppPoolIfRequested($Config, [bool]$Requested) {
    if (-not $Requested) { return }
    $appPoolName = Get-ConfigString $Config "IisAppPoolName" "$($Config.AppName)-AppPool"
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path "IIS:\AppPools\$appPoolName") {
            if ($PSCmdlet.ShouldProcess($appPoolName, "Recycle IIS app pool after restore")) {
                Restart-WebAppPool -Name $appPoolName
                Write-Host "Recycled IIS app pool: $appPoolName" -ForegroundColor Green
            }
        } else {
            Write-Warning "IIS app pool not found: $appPoolName"
        }
    } catch {
        Write-Warning "Could not recycle IIS app pool. $($_.Exception.Message)"
    }
}

$records = @(Get-BackupRecords $config)
if ($List) {
    if ($records.Count -eq 0) {
        Write-Warning "No managed backups found in $(Get-BackupDirectory $config)."
        return
    }
    $records |
        Where-Object { $Target -eq "All" -or $_.Target -eq $Target } |
        Select-Object Target, LastWriteTime, Length, BackupPath, Destination |
        Format-Table -AutoSize
    return
}

if (-not $Latest -and [string]::IsNullOrWhiteSpace($BackupPath)) {
    throw "Use -List to inspect backups, or provide -Latest or -BackupPath to restore."
}

Assert-Admin
$restoreRecords = @(Select-RestoreRecords $config)
Write-Host "Selected managed backup(s):" -ForegroundColor Cyan
$restoreRecords | Select-Object Target, LastWriteTime, BackupPath, Destination | Format-Table -AutoSize

$serviceFileRestoreCount = @($restoreRecords | Where-Object { $_.Target -in @("ServiceExe", "ServiceXml") }).Count
if ($serviceFileRestoreCount -gt 0 -and -not $RestartService) {
    Write-Warning "Restoring service wrapper files usually requires -RestartService. Restoring ServiceExe can fail while the service is running."
}
$shouldRestartService = [bool]$RestartService
[void](Stop-AppServiceIfRequested $config $shouldRestartService)
try {
    foreach ($record in $restoreRecords) {
        switch ($record.Kind) {
            "File" { Restore-FileBackup $record }
            "ScheduledTask" { Restore-ScheduledTaskBackup $record }
            default { throw "Unsupported backup kind: $($record.Kind)" }
        }
    }
}
finally {
    Start-AppServiceIfRequested $config $shouldRestartService
}

if (@($restoreRecords | Where-Object { $_.Target -eq "IisWebConfig" }).Count -gt 0) {
    Restart-IisAppPoolIfRequested $config $RecycleIisAppPool
}

Write-Host "Restore completed. Run status.ps1 to verify service, port, and health." -ForegroundColor Green
