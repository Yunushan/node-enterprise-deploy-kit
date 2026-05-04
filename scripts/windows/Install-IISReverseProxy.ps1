<#
.SYNOPSIS
  Generate an IIS web.config reverse proxy to localhost Node.js port.
.NOTES
  Requires IIS URL Rewrite and ARR if using IIS as a reverse proxy.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run this script as Administrator." }
}
function Replace-Token([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace("{{$k}}", [string]$Values[$k]) }
    return $Text
}
function Get-ConfigValue($Config, [string]$Name, $Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Config.$Name
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
    return (Join-Path $Config.IisSitePath "backups")
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
function Test-WebGlobalModule([string]$Name) {
    try {
        return $null -ne (Get-WebGlobalModule -Name $Name -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}
function Ensure-AppPool([string]$Name) {
    if (-not (Test-Path "IIS:\AppPools\$Name")) {
        New-WebAppPool -Name $Name | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$Name" -Name startMode -Value AlwaysRunning
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
    Set-ItemProperty "IIS:\AppPools\$Name" -Name recycling.periodicRestart.time -Value ([TimeSpan]::FromMinutes(0))
}
function Ensure-WebBinding([string]$SiteName, [string]$Protocol, [int]$Port, [string]$HostHeader) {
    $binding = Get-WebBinding -Name $SiteName -Protocol $Protocol -ErrorAction SilentlyContinue |
        Where-Object {
            $_.bindingInformation -eq "*:${Port}:$HostHeader" -or
            ($HostHeader -eq "" -and $_.bindingInformation -eq "*:${Port}:")
        }
    if (-not $binding) {
        New-WebBinding -Name $SiteName -Protocol $Protocol -Port $Port -HostHeader $HostHeader | Out-Null
    }
}
function Ensure-SslBinding([int]$Port, [string]$HostHeader, [string]$Thumbprint) {
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        Write-Warning "TlsEnabled is true, but IisCertificateThumbprint is not configured. Create/verify the HTTPS certificate binding manually."
        return
    }
    $certPath = "Cert:\LocalMachine\My\$Thumbprint"
    if (-not (Test-Path $certPath)) {
        Write-Warning "TLS certificate not found in LocalMachine\My: $Thumbprint. Create/verify the HTTPS certificate binding manually."
        return
    }

    $sslPath = if ([string]::IsNullOrWhiteSpace($HostHeader)) {
        "IIS:\SslBindings\0.0.0.0!$Port"
    } else {
        "IIS:\SslBindings\0.0.0.0!$Port!$HostHeader"
    }
    if (-not (Test-Path $sslPath)) {
        $sslFlags = if ([string]::IsNullOrWhiteSpace($HostHeader)) { 0 } else { 1 }
        Get-Item $certPath | New-Item $sslPath -SSLFlags $sslFlags | Out-Null
    }
}

Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$templatePath = Join-Path $repoRoot "templates\windows\iis-web.config.tpl"

Import-Module WebAdministration -ErrorAction Stop

$siteName = [string](Get-ConfigValue $config "IisSiteName" $config.AppName)
$appPoolName = [string](Get-ConfigValue $config "IisAppPoolName" "$($config.AppName)-AppPool")
$publicHostName = [string](Get-ConfigValue $config "PublicHostName" "")
$tlsEnabled = $false
if ($config.PSObject.Properties["TlsEnabled"]) { $tlsEnabled = [bool]$config.TlsEnabled }
$publicPort = if ($config.PSObject.Properties["PublicPort"] -and $config.PublicPort) { [int]$config.PublicPort } elseif ($tlsEnabled) { 443 } else { 80 }
$protocol = if ($tlsEnabled) { "https" } else { "http" }
$thumbprint = [string](Get-ConfigValue $config "IisCertificateThumbprint" "")
$backupDirectory = Get-BackupDirectory $config

if (-not (Test-WebGlobalModule "RewriteModule")) {
    Write-Warning "IIS URL Rewrite module was not detected. Reverse proxy rules in web.config will not work until it is installed."
}
if (-not (Test-WebGlobalModule "ApplicationRequestRouting")) {
    Write-Warning "IIS ARR module was not detected. Verify Application Request Routing is installed and proxy support is enabled."
}

New-Item -ItemType Directory -Force -Path $config.IisSitePath | Out-Null
$template = Get-Content $templatePath -Raw
$webConfig = Replace-Token $template @{ "APP_PORT" = $config.Port }
$out = Join-Path $config.IisSitePath "web.config"
if ($PSCmdlet.ShouldProcess($out, "Write IIS reverse proxy web.config")) {
    Set-TextFileWithBackup -Path $out -Content $webConfig -BackupDirectory $backupDirectory
}

if ($PSCmdlet.ShouldProcess($appPoolName, "Configure IIS app pool")) {
    Ensure-AppPool $appPoolName
}

if ($PSCmdlet.ShouldProcess($siteName, "Configure IIS site")) {
    if (-not (Test-Path "IIS:\Sites\$siteName")) {
        $initialPort = if ($tlsEnabled) { 80 } else { $publicPort }
        New-Website -Name $siteName -PhysicalPath $config.IisSitePath -ApplicationPool $appPoolName -Port $initialPort -HostHeader $publicHostName | Out-Null
        if ($tlsEnabled) {
            Remove-WebBinding -Name $siteName -Protocol "http" -Port $initialPort -HostHeader $publicHostName -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $config.IisSitePath
        Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $appPoolName
    }
    Ensure-WebBinding -SiteName $siteName -Protocol $protocol -Port $publicPort -HostHeader $publicHostName
    if ($tlsEnabled) {
        Ensure-SslBinding -Port $publicPort -HostHeader $publicHostName -Thumbprint $thumbprint
    }
}

Write-Host "IIS web.config created: $out" -ForegroundColor Green
Write-Host "IIS site: $siteName"
Write-Host "IIS app pool: $appPoolName"
