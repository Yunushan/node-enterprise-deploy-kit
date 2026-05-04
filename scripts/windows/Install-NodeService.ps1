<#
.SYNOPSIS
  Install a Node.js / Next.js app as a Windows Service using WinSW.
.PARAMETER ConfigPath
  Path to config/windows/app.config.json.
.PARAMETER WinSWPath
  Optional path to a WinSW executable. If omitted, the script looks under tools/winsw/winsw-x64.exe.
.NOTES
  Run as Administrator.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe"
)

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}
function Read-Config($Path) {
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    return Get-Content $Path -Raw | ConvertFrom-Json
}
function Replace-Token([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace("{{$k}}", [string]$Values[$k]) }
    return $Text
}
function Escape-XmlValue($Value) {
    if ($null -eq $Value) { return "" }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}
function Invoke-NativeCommand([string]$FilePath, [string[]]$Arguments, [string]$Action) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    return (Join-Path $Config.ServiceDirectory "backups")
}
function Backup-FileIfExists([string]$Path, [string]$BackupDirectory) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $BackupDirectory ("{0}.{1}.{2}.bak" -f ([System.IO.Path]::GetFileName($Path)), $timestamp, $PID)
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Host "Backed up $Path to $backupPath"
    return $backupPath
}
function Test-FileContentEqual([string]$Path, [string]$Content) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ([System.IO.File]::ReadAllText($Path) -eq $Content)
}
function Set-TextFileWithBackup([string]$Path, [string]$Content, [string]$BackupDirectory) {
    if (Test-FileContentEqual -Path $Path -Content $Content) {
        Write-Host "Unchanged: $Path"
        return
    }
    [void](Backup-FileIfExists -Path $Path -BackupDirectory $BackupDirectory)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated: $Path"
}
function Copy-FileWithBackup([string]$Source, [string]$Destination, [string]$BackupDirectory) {
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Destination).Hash)) {
        Write-Host "Unchanged: $Destination"
        return
    }
    [void](Backup-FileIfExists -Path $Destination -BackupDirectory $BackupDirectory)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Host "Updated: $Destination"
}
function Stop-ExistingService([string]$Name, [string]$WrapperPath) {
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $false }

    if ($service.Status -ne "Stopped") {
        Write-Host "Stopping existing service: $Name"
        if (Test-Path $WrapperPath) {
            & $WrapperPath stop
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "WinSW stop returned exit code $LASTEXITCODE. Falling back to Stop-Service."
                Stop-Service -Name $Name -Force -ErrorAction Stop
            }
        } else {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        }
        $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }

    return $true
}
function Assert-ServicePathCompatible([string]$Name, [string]$ExpectedWrapperPath) {
    $escaped = $Name.Replace("'", "''")
    $existing = Get-CimInstance Win32_Service -Filter "Name='$escaped'" -ErrorAction SilentlyContinue
    if (-not $existing) { return }

    $expected = [System.IO.Path]::GetFullPath($ExpectedWrapperPath)
    $pathName = [string]$existing.PathName
    if ($pathName -and $pathName.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "A service named '$Name' already exists but points to a different executable: $pathName. Uninstall it or change AppName before deploying."
    }
}
function Test-PostStartHealth($Config) {
    Start-Sleep -Seconds 3
    if ($Config.Port -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        $listener = Get-NetTCPConnection -LocalPort ([int]$Config.Port) -State Listen -ErrorAction SilentlyContinue
        if (-not $listener) {
            Write-Warning "Service is running, but no listener was found on configured port $($Config.Port). Check app logs and StartCommand."
        }
    }
    if ($Config.HealthUrl) {
        try {
            $response = Invoke-WebRequest -Uri $Config.HealthUrl -UseBasicParsing -TimeoutSec 10
            Write-Host "Health check returned HTTP $($response.StatusCode)." -ForegroundColor Green
        } catch {
            Write-Warning "Service started, but HTTP health check failed. $($_.Exception.Message)"
        }
    }
}

Assert-Admin
$config = Read-Config $ConfigPath
if ($config.ServiceManager -ne "winsw") {
    throw "This installer supports ServiceManager='winsw'. For NSSM/PM2, use fallback scripts."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$winswCandidate = Join-Path $repoRoot $WinSWPath
if (-not (Test-Path $winswCandidate)) {
    throw "WinSW executable not found at '$winswCandidate'. Download WinSW separately and place it there, or pass -WinSWPath. No binaries are bundled in this repository."
}

New-Item -ItemType Directory -Force -Path $config.ServiceDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null
$backupDirectory = Get-BackupDirectory $config
New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null

$serviceExe = Join-Path $config.ServiceDirectory "$($config.AppName).exe"
$serviceXml = Join-Path $config.ServiceDirectory "$($config.AppName).xml"
Assert-ServicePathCompatible -Name $config.AppName -ExpectedWrapperPath $serviceExe
$serviceExists = $null -ne (Get-Service -Name $config.AppName -ErrorAction SilentlyContinue)
if ($serviceExists -and $PSCmdlet.ShouldProcess($config.AppName, "Stop existing Windows Service for update")) {
    [void](Stop-ExistingService -Name $config.AppName -WrapperPath $serviceExe)
}

$envBlock = ""
if ($config.Environment) {
    $config.Environment.PSObject.Properties | ForEach-Object {
        $name = Escape-XmlValue $_.Name
        $value = Escape-XmlValue $_.Value
        $envBlock += "  <env name=`"$name`" value=`"$value`"/>`r`n"
    }
}

$templatePath = Join-Path $repoRoot "templates\windows\winsw-service.xml.tpl"
$template = Get-Content $templatePath -Raw
$values = @{
    "APP_NAME" = Escape-XmlValue $config.AppName
    "DISPLAY_NAME" = Escape-XmlValue $config.DisplayName
    "DESCRIPTION" = Escape-XmlValue $config.Description
    "NODE_EXE" = Escape-XmlValue $config.NodeExe
    "START_COMMAND" = Escape-XmlValue $config.StartCommand
    "NODE_ARGUMENTS" = Escape-XmlValue $config.NodeArguments
    "APP_DIRECTORY" = Escape-XmlValue $config.AppDirectory
    "LOG_DIRECTORY" = Escape-XmlValue $config.LogDirectory
    "ENVIRONMENT_BLOCK" = $envBlock.TrimEnd()
}
$xml = Replace-Token $template $values
[void]([xml]$xml)
if ($PSCmdlet.ShouldProcess($serviceExe, "Update WinSW executable")) {
    Copy-FileWithBackup -Source $winswCandidate -Destination $serviceExe -BackupDirectory $backupDirectory
}
if ($PSCmdlet.ShouldProcess($serviceXml, "Write WinSW XML")) {
    Set-TextFileWithBackup -Path $serviceXml -Content $xml -BackupDirectory $backupDirectory
}

if ($PSCmdlet.ShouldProcess($config.AppName, "Install Windows Service")) {
    if ($serviceExists) {
        Write-Host "Updating existing service: $($config.AppName)"
    } else {
        Invoke-NativeCommand $serviceExe @("install") "WinSW install"
    }

    $restartDelaySeconds = 60
    if ($config.PSObject.Properties["FailureRestartDelaySeconds"]) {
        $restartDelaySeconds = [Math]::Max(1, [int]$config.FailureRestartDelaySeconds)
    }
    $restartDelayMs = $restartDelaySeconds * 1000
    $thirdRestartDelayMs = $restartDelayMs * 5

    Invoke-NativeCommand "sc.exe" @("config", $config.AppName, "start=", "auto") "Set service startup mode"
    Invoke-NativeCommand "sc.exe" @("failure", $config.AppName, "reset=", "86400", "actions=", "restart/$restartDelayMs/restart/$restartDelayMs/restart/$thirdRestartDelayMs") "Set service recovery actions"
    Invoke-NativeCommand "sc.exe" @("failureflag", $config.AppName, "1") "Enable service recovery actions"
    Invoke-NativeCommand $serviceExe @("start") "WinSW start"

    $service = Get-Service -Name $config.AppName -ErrorAction Stop
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    Test-PostStartHealth $config
}

Write-Host "Installed service: $($config.AppName)" -ForegroundColor Green
Write-Host "Service XML: $serviceXml"
Write-Host "Logs: $($config.LogDirectory)"
