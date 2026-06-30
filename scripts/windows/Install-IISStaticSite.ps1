<#
.SYNOPSIS
  Deploy a static SPA output directory to IIS without URL Rewrite or ARR.
.DESCRIPTION
  Copies only StaticOutputDirectory contents to the configured IIS physical
  path, backs up the previous static folder contents, generates or validates a
  plain IIS web.config, configures an IIS site and No Managed Code app pool,
  and restarts the site/app pool.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $RenderWebConfigOnly
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run this script as Administrator." }
}

function Get-ConfigValue($Config, [string]$Name, $Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Config.$Name
    }
    return $Default
}

function Get-ConfigString($Config, [string]$Name, [string]$Default) {
    return [string](Get-ConfigValue $Config $Name $Default)
}

function Get-ConfigBool($Config, [string]$Name, [bool]$Default) {
    if (-not $Config.PSObject.Properties[$Name] -or $null -eq $Config.$Name) {
        return $Default
    }
    if ($Config.$Name -is [bool]) {
        return [bool]$Config.$Name
    }

    $text = ([string]$Config.$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }
    switch ($text) {
        "true" { return $true }
        "1" { return $true }
        "yes" { return $true }
        "false" { return $false }
        "0" { return $false }
        "no" { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Get-ConfigInt($Config, [string]$Name, [int]$Default, [int]$Minimum) {
    $value = $Default
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        if (-not [int]::TryParse([string]$Config.$Name, [ref]$value)) {
            throw "$Name must be an integer."
        }
    }
    if ($value -lt $Minimum) {
        throw "$Name must be an integer >= $Minimum."
    }
    return $value
}

function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}

function Test-SafeRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = $Path -replace "\\", "/"
    foreach ($part in $normalized.Split("/")) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq ".") { continue }
        if ($part -eq "..") { return $false }
    }
    return $true
}

function Get-NormalizedRelativePath {
    param(
        [string]$Path,
        [string]$Default
    )

    $value = $Path
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    $value = ($value -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    return $value
}

function Join-AppRelativePath([string]$Root, [string]$RelativePath) {
    $normalized = ($RelativePath -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq ".") {
        return $Root
    }
    return (Join-Path $Root ($normalized -replace "/", "\"))
}

function ConvertTo-XmlAttributeValue([string]$Value) {
    $escaped = [System.Security.SecurityElement]::Escape($Value)
    if ($null -eq $escaped) { return "" }
    return $escaped
}

function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    return (Join-Path $Config.IisSitePath "backups")
}

function New-StaticIisWebConfig {
    param([string]$ShellFile)

    $shell = ConvertTo-XmlAttributeValue $ShellFile
    $defaultDocuments = if ($ShellFile -ieq "index.html") {
        '        <add value="index.html" />'
    } else {
        @"
        <add value="$shell" />
        <add value="index.html" />
"@
    }
    $fallbackPath = ConvertTo-XmlAttributeValue ("/" + $ShellFile)
    return @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <remove fileExtension=".json" />
      <remove fileExtension=".webmanifest" />
      <remove fileExtension=".mjs" />
      <remove fileExtension=".wasm" />
      <remove fileExtension=".svg" />
      <remove fileExtension=".woff2" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
      <mimeMap fileExtension=".webmanifest" mimeType="application/manifest+json" />
      <mimeMap fileExtension=".mjs" mimeType="text/javascript" />
      <mimeMap fileExtension=".wasm" mimeType="application/wasm" />
      <mimeMap fileExtension=".svg" mimeType="image/svg+xml" />
      <mimeMap fileExtension=".woff2" mimeType="font/woff2" />
    </staticContent>

    <defaultDocument enabled="true">
      <files>
        <clear />
$defaultDocuments
      </files>
    </defaultDocument>

    <httpErrors errorMode="Custom" existingResponse="Replace">
      <remove statusCode="404" subStatusCode="-1" />
      <error statusCode="404" path="$fallbackPath" responseMode="ExecuteURL" />
    </httpErrors>
  </system.webServer>
</configuration>
"@
}

function Assert-PlainIisWebConfig {
    param(
        [string]$Path,
        [string]$ShellFile,
        [bool]$RewriteAllowed
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "web.config not found."
    }
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
    }
    catch {
        throw "web.config is not valid XML. $($_.Exception.Message)"
    }

    $rewriteNodes = @($xml.SelectNodes("//*[local-name()='rewrite']"))
    if ($rewriteNodes.Count -gt 0 -and -not $RewriteAllowed) {
        throw "web.config contains an unsupported <rewrite> section. static_iis mode does not require URL Rewrite or ARR."
    }

    $defaultDocumentValues = @($xml.SelectNodes("//*[local-name()='defaultDocument']/*[local-name()='files']/*[local-name()='add']") |
        ForEach-Object { [string]$_.value })
    if ($defaultDocumentValues -notcontains $ShellFile) {
        throw "web.config must configure defaultDocument to include ${ShellFile}."
    }

    $expectedFallbackPath = "/" + $ShellFile
    $fallbacks = @($xml.SelectNodes("//*[local-name()='httpErrors']/*[local-name()='error']") |
        Where-Object {
            [string]$_.statusCode -eq "404" -and
            [string]$_.path -eq $expectedFallbackPath -and
            [string]$_.responseMode -eq "ExecuteURL"
        })
    if ($fallbacks.Count -eq 0) {
        throw "web.config must configure httpErrors 404 ExecuteURL fallback to ${expectedFallbackPath}."
    }
}

function Assert-StaticSource {
    param(
        [string]$SourcePath,
        [string]$ShellFile,
        [bool]$AllowRewrite
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "StaticOutputDirectory was not found after build."
    }
    $shellPath = Join-Path $SourcePath $ShellFile
    if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
        throw "Static output directory is missing SPA shell file."
    }

    $assetsPath = Join-Path $SourcePath "assets"
    if (Test-Path -LiteralPath $assetsPath -PathType Container) {
        $assetFiles = @(Get-ChildItem -LiteralPath $assetsPath -File -Recurse -ErrorAction SilentlyContinue)
        if ($assetFiles.Count -eq 0) {
            Write-Warning "Assets directory exists but contains no files."
        }
    }

    $webConfigPath = Join-Path $SourcePath "web.config"
    if (Test-Path -LiteralPath $webConfigPath -PathType Leaf) {
        Assert-PlainIisWebConfig -Path $webConfigPath -ShellFile $ShellFile -RewriteAllowed $AllowRewrite
    }
}

function Test-WindowsFeatureInstalled([string]$ServerFeatureName, [string]$OptionalFeatureName) {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $feature = Get-WindowsFeature -Name $ServerFeatureName -ErrorAction SilentlyContinue
        if ($null -eq $feature) { return $false }
        return [bool]$feature.Installed
    }
    if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $OptionalFeatureName -ErrorAction SilentlyContinue
        if ($null -eq $feature) { return $false }
        return ([string]$feature.State -eq "Enabled")
    }
    return $null
}

function Assert-IisStaticPrerequisites {
    $iisInstalled = Test-WindowsFeatureInstalled -ServerFeatureName "Web-Server" -OptionalFeatureName "IIS-WebServerRole"
    if ($iisInstalled -ne $true) {
        throw "IIS is not installed or could not be verified. Install the IIS Web Server role before static_iis deployment."
    }
    $staticContentInstalled = Test-WindowsFeatureInstalled -ServerFeatureName "Web-Static-Content" -OptionalFeatureName "IIS-StaticContent"
    if ($staticContentInstalled -ne $true) {
        throw "IIS Static Content feature is not installed. Install Web-Static-Content before static_iis deployment."
    }
}

function Test-DirectoryWriteAccess {
    param([string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $probe = Join-Path $Path (".static-iis-write-test.{0}.tmp" -f $PID)
    try {
        [System.IO.File]::WriteAllText($probe, "ok", [System.Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

function Backup-StaticSiteIfPresent {
    param(
        [string]$SitePath,
        [string]$BackupDirectory
    )

    if (-not (Test-Path -LiteralPath $SitePath -PathType Container)) { return "" }
    $items = @(Get-ChildItem -LiteralPath $SitePath -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return "" }

    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $BackupDirectory ("static-site.{0}.{1}.bak" -f $timestamp, $PID)
    New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination $backupPath -Recurse -Force
    }
    Write-Host "Backed up existing IIS static folder."
    return $backupPath
}

function Clear-DirectoryContents {
    param([string]$Path)

    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function Copy-StaticOutputContents {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    foreach ($item in Get-ChildItem -LiteralPath $SourcePath -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $DestinationPath -Recurse -Force
    }
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

function Ensure-StaticAppPool([string]$Name) {
    if (-not (Test-Path "IIS:\AppPools\$Name")) {
        New-WebAppPool -Name $Name | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value ""
    Set-ItemProperty "IIS:\AppPools\$Name" -Name startMode -Value AlwaysRunning
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
}

function Restart-StaticIisTarget([string]$SiteName, [string]$AppPoolName) {
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        try {
            Restart-WebAppPool -Name $AppPoolName -ErrorAction Stop
            Write-Host "Restarted IIS app pool: $AppPoolName"
        }
        catch {
            Start-WebAppPool -Name $AppPoolName
            Write-Host "Started IIS app pool: $AppPoolName"
        }
    }

    $site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        throw "IIS site was not found after configuration: $SiteName"
    }
    if ([string]$site.State -eq "Started") {
        Stop-Website -Name $SiteName | Out-Null
    }
    Start-Website -Name $SiteName | Out-Null
    Write-Host "Restarted IIS site: $SiteName"
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $ConfigPath))
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$deploymentMode = Normalize-Name (Get-ConfigString $config "DeploymentMode" "")
if ($deploymentMode -ne "static-iis") {
    throw "Install-IISStaticSite.ps1 requires DeploymentMode=static_iis."
}

$staticOutputDirectory = Get-NormalizedRelativePath (Get-ConfigString $config "StaticOutputDirectory" "dist/client") "dist/client"
$spaShellFile = Get-NormalizedRelativePath (Get-ConfigString $config "SpaShellFile" "_shell.html") "_shell.html"
if (-not (Test-SafeRelativePath $staticOutputDirectory)) {
    throw "StaticOutputDirectory must be a safe relative directory path."
}
if (-not (Test-SafeRelativePath $spaShellFile) -or $spaShellFile.Contains("/")) {
    throw "SpaShellFile must be a safe relative file name."
}

if ($RenderWebConfigOnly) {
    Write-Output (New-StaticIisWebConfig -ShellFile $spaShellFile)
    return
}

Assert-Admin
Assert-IisStaticPrerequisites
Import-Module WebAdministration -ErrorAction Stop

$appDirectory = [System.IO.Path]::GetFullPath([string]$config.AppDirectory)
$sourcePath = Join-AppRelativePath -Root $appDirectory -RelativePath $staticOutputDirectory
$sitePath = [System.IO.Path]::GetFullPath([string]$config.IisSitePath)
$siteName = [string](Get-ConfigValue $config "IisSiteName" $config.AppName)
$appPoolName = [string](Get-ConfigValue $config "IisAppPoolName" "$($config.AppName)-AppPool")
$publicHostName = [string](Get-ConfigValue $config "PublicHostName" "")
$tlsEnabled = Get-ConfigBool $config "TlsEnabled" $false
$defaultPort = if ($tlsEnabled) { 443 } else { 80 }
$publicPort = Get-ConfigInt $config "PublicPort" $defaultPort 1
$protocol = if ($tlsEnabled) { "https" } else { "http" }
$thumbprint = [string](Get-ConfigValue $config "IisCertificateThumbprint" "")
$backupDirectory = [System.IO.Path]::GetFullPath((Get-BackupDirectory $config))
$allowRewrite = Get-ConfigBool $config "IisStaticAllowUrlRewrite" $false

Assert-StaticSource -SourcePath $sourcePath -ShellFile $spaShellFile -AllowRewrite $allowRewrite

if ($PSCmdlet.ShouldProcess("IIS static site folder", "Deploy static_iis output")) {
    New-Item -ItemType Directory -Force -Path $sitePath | Out-Null
    Test-DirectoryWriteAccess -Path $sitePath
    $backupPath = Backup-StaticSiteIfPresent -SitePath $sitePath -BackupDirectory $backupDirectory
    try {
        Clear-DirectoryContents -Path $sitePath
        Copy-StaticOutputContents -SourcePath $sourcePath -DestinationPath $sitePath

        $webConfigPath = Join-Path $sitePath "web.config"
        if (Test-Path -LiteralPath $webConfigPath -PathType Leaf) {
            Assert-PlainIisWebConfig -Path $webConfigPath -ShellFile $spaShellFile -RewriteAllowed $allowRewrite
        } else {
            $webConfig = New-StaticIisWebConfig -ShellFile $spaShellFile
            [System.IO.File]::WriteAllText($webConfigPath, $webConfig, [System.Text.UTF8Encoding]::new($false))
            Write-Host "Generated static IIS web.config."
        }

        $deployedShell = Join-Path $sitePath $spaShellFile
        if (-not (Test-Path -LiteralPath $deployedShell -PathType Leaf)) {
            throw "Deployed folder is missing SPA shell file after copy."
        }
    }
    catch {
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
            Clear-DirectoryContents -Path $sitePath
            Copy-StaticOutputContents -SourcePath $backupPath -DestinationPath $sitePath
            Write-Warning "Restored previous IIS static folder after deployment failure."
        }
        throw
    }
}

if ($PSCmdlet.ShouldProcess($appPoolName, "Configure IIS No Managed Code app pool")) {
    Ensure-StaticAppPool $appPoolName
}

if ($PSCmdlet.ShouldProcess($siteName, "Configure IIS static site")) {
    if (-not (Test-Path "IIS:\Sites\$siteName")) {
        $initialPort = if ($tlsEnabled) { 80 } else { $publicPort }
        New-Website -Name $siteName -PhysicalPath $sitePath -ApplicationPool $appPoolName -Port $initialPort -HostHeader $publicHostName | Out-Null
        if ($tlsEnabled) {
            Remove-WebBinding -Name $siteName -Protocol "http" -Port $initialPort -HostHeader $publicHostName -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $sitePath
        Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $appPoolName
    }
    Ensure-WebBinding -SiteName $siteName -Protocol $protocol -Port $publicPort -HostHeader $publicHostName
    if ($tlsEnabled) {
        Ensure-SslBinding -Port $publicPort -HostHeader $publicHostName -Thumbprint $thumbprint
    }
    Restart-StaticIisTarget -SiteName $siteName -AppPoolName $appPoolName
}

Write-Host "Static IIS deployment finished: $siteName"
Write-Host "IIS app pool configured for No Managed Code: $appPoolName"
