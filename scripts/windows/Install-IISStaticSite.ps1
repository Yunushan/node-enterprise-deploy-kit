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
    [string] $ConfigPath,
    [switch] $RenderWebConfigOnly,
    [switch] $LoadFunctionsOnly
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
    $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonApplicationData)) {
        throw "BackupDirectory is required because the system ProgramData path could not be resolved."
    }
    return (Join-Path $commonApplicationData ("node-enterprise-deploy-kit\backups\{0}" -f $Config.AppName))
}

function Test-PathAtOrBelow {
    param(
        [string]$Path,
        [string]$ParentPath
    )

    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    if ($candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidate.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-StaticDeploymentPathsDoNotOverlap {
    param(
        [string]$SourcePath,
        [string]$SitePath,
        [string]$BackupDirectory
    )

    if ((Test-PathAtOrBelow -Path $SourcePath -ParentPath $SitePath) -or
        (Test-PathAtOrBelow -Path $SitePath -ParentPath $SourcePath)) {
        throw "StaticOutputDirectory and IisSitePath must not overlap. Use separate build and live-site directories."
    }
    if (Test-PathAtOrBelow -Path $BackupDirectory -ParentPath $SitePath) {
        throw "BackupDirectory must not be inside IisSitePath because deployment clears the live-site directory."
    }
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

function Get-SslBindingPath([int]$Port, [string]$HostHeader) {
    if ([string]::IsNullOrWhiteSpace($HostHeader)) {
        return "IIS:\SslBindings\0.0.0.0!$Port"
    }
    return "IIS:\SslBindings\0.0.0.0!$Port!$HostHeader"
}

function Test-ConfiguredWebBinding([string]$SiteName, [string]$Protocol, [int]$Port, [string]$HostHeader) {
    return $null -ne (Get-WebBinding -Name $SiteName -Protocol $Protocol -ErrorAction SilentlyContinue |
        Where-Object {
            $_.bindingInformation -eq "*:${Port}:$HostHeader" -or
            ($HostHeader -eq "" -and $_.bindingInformation -eq "*:${Port}:")
        } |
        Select-Object -First 1)
}

function Get-StaticIisDeploymentSnapshot {
    param(
        [string]$SiteName,
        [string]$AppPoolName,
        [string]$Protocol,
        [int]$Port,
        [string]$HostHeader,
        [bool]$TlsEnabled
    )

    $site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    $appPoolExists = Test-Path "IIS:\AppPools\$AppPoolName"
    $appPoolState = ""
    if ($appPoolExists) {
        $state = Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop
        $appPoolState = [string]$state.Value
    }
    $sslPath = if ($TlsEnabled) { Get-SslBindingPath -Port $Port -HostHeader $HostHeader } else { "" }

    return [pscustomobject]@{
        SiteExisted = $null -ne $site
        SiteState = if ($site) { [string]$site.State } else { "" }
        SitePhysicalPath = if ($site) { [string]$site.PhysicalPath } else { "" }
        SiteApplicationPool = if ($site) { [string]$site.ApplicationPool } else { "" }
        AppPoolExisted = $appPoolExists
        AppPoolState = $appPoolState
        DesiredBindingExisted = if ($site) { Test-ConfiguredWebBinding -SiteName $SiteName -Protocol $Protocol -Port $Port -HostHeader $HostHeader } else { $false }
        SslBindingPath = $sslPath
        SslBindingExisted = if ($TlsEnabled) { Test-Path $sslPath } else { $false }
    }
}

function Stop-StaticIisSiteForDeployment {
    param(
        [string]$SiteName,
        $Snapshot
    )

    if ($Snapshot.SiteExisted -and $Snapshot.SiteState -eq "Started") {
        Stop-Website -Name $SiteName -ErrorAction Stop | Out-Null
        $site = Get-Website -Name $SiteName -ErrorAction Stop
        if ([string]$site.State -ne "Stopped") {
            throw "IIS site did not stop before static content replacement: $SiteName"
        }
        Write-Host "Stopped IIS site before replacing static content: $SiteName"
    }
}

function Restore-StaticSiteContent {
    param(
        [string]$SitePath,
        [string]$BackupPath,
        [bool]$SitePathExisted
    )

    if (Test-Path -LiteralPath $SitePath -PathType Container) {
        Clear-DirectoryContents -Path $SitePath
    } else {
        New-Item -ItemType Directory -Force -Path $SitePath | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupPath) -and (Test-Path -LiteralPath $BackupPath -PathType Container)) {
        Copy-StaticOutputContents -SourcePath $BackupPath -DestinationPath $SitePath
    } elseif (-not $SitePathExisted) {
        Remove-Item -LiteralPath $SitePath -Recurse -Force
    }
}

function Restore-StaticIisDeploymentSnapshot {
    param(
        [string]$SiteName,
        [string]$AppPoolName,
        [string]$Protocol,
        [int]$Port,
        [string]$HostHeader,
        $Snapshot
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Snapshot.SslBindingPath) -and
        -not $Snapshot.SslBindingExisted -and
        (Test-Path $Snapshot.SslBindingPath)) {
        Remove-Item $Snapshot.SslBindingPath -Force -ErrorAction Stop
    }

    $currentSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if ($currentSite -and [string]$currentSite.State -eq "Started") {
        Stop-Website -Name $SiteName -ErrorAction Stop | Out-Null
    }

    if ($Snapshot.SiteExisted) {
        if (-not $currentSite) {
            throw "Cannot restore IIS site because it no longer exists: $SiteName"
        }
        if (-not $Snapshot.DesiredBindingExisted -and
            (Test-ConfiguredWebBinding -SiteName $SiteName -Protocol $Protocol -Port $Port -HostHeader $HostHeader)) {
            Remove-WebBinding -Name $SiteName -Protocol $Protocol -Port $Port -HostHeader $HostHeader -ErrorAction Stop
        }
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $Snapshot.SitePhysicalPath
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $Snapshot.SiteApplicationPool
        if ($Snapshot.SiteState -eq "Started") {
            Start-Website -Name $SiteName -ErrorAction Stop | Out-Null
        }
    } elseif ($currentSite) {
        Remove-Website -Name $SiteName -ErrorAction Stop
    }

    if (-not $Snapshot.AppPoolExisted -and (Test-Path "IIS:\AppPools\$AppPoolName")) {
        $currentPoolState = Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop
        if ([string]$currentPoolState.Value -eq "Started") {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction Stop
        }
        Remove-WebAppPool -Name $AppPoolName -ErrorAction Stop
    } elseif ($Snapshot.AppPoolExisted -and $Snapshot.AppPoolState -eq "Stopped") {
        $currentPoolState = Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop
        if ([string]$currentPoolState.Value -eq "Started") {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction Stop
        }
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
        throw "TlsEnabled is true, but IisCertificateThumbprint is not configured. Configure a LocalMachine certificate before deployment."
    }
    $normalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    $certPath = "Cert:\LocalMachine\My\$normalizedThumbprint"
    if (-not (Test-Path $certPath)) {
        throw "TLS certificate not found in LocalMachine\My: $Thumbprint"
    }

    $sslPath = Get-SslBindingPath -Port $Port -HostHeader $HostHeader
    if (Test-Path $sslPath) {
        $existingSslBinding = Get-Item $sslPath -ErrorAction Stop
        $existingThumbprint = ([string]$existingSslBinding.Thumbprint).Replace(" ", "").ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($existingThumbprint) -and $existingThumbprint -ne $normalizedThumbprint) {
            throw "Existing IIS SSL binding uses a different certificate than IisCertificateThumbprint."
        }
    } else {
        $sslFlags = if ([string]::IsNullOrWhiteSpace($HostHeader)) { 0 } else { 1 }
        Get-Item $certPath | New-Item $sslPath -SSLFlags $sslFlags | Out-Null
    }
    if (-not (Test-Path $sslPath)) {
        throw "IIS SSL binding was not created: $sslPath"
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

function Assert-StaticIisTargetReady {
    param(
        [string]$SiteName,
        [string]$AppPoolName,
        [string]$SitePath,
        [string]$Protocol,
        [int]$Port,
        [string]$HostHeader
    )

    $site = Get-Website -Name $SiteName -ErrorAction Stop
    if ([string]$site.State -ne "Started") {
        throw "IIS site is not started after static deployment: $SiteName"
    }
    if (-not ([System.IO.Path]::GetFullPath([string]$site.PhysicalPath)).Equals(
        [System.IO.Path]::GetFullPath($SitePath), [StringComparison]::OrdinalIgnoreCase)) {
        throw "IIS site physical path does not match IisSitePath after deployment."
    }
    if ([string]$site.ApplicationPool -ne $AppPoolName) {
        throw "IIS site application pool does not match IisAppPoolName after deployment."
    }
    $appPoolState = Get-WebAppPoolState -Name $AppPoolName -ErrorAction Stop
    if ([string]$appPoolState.Value -ne "Started") {
        throw "IIS application pool is not started after static deployment: $AppPoolName"
    }
    if (-not (Test-ConfiguredWebBinding -SiteName $SiteName -Protocol $Protocol -Port $Port -HostHeader $HostHeader)) {
        throw "Configured IIS binding was not found after static deployment."
    }
}

if ($LoadFunctionsOnly) {
    return
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    throw "ConfigPath is required."
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
Assert-StaticDeploymentPathsDoNotOverlap -SourcePath $sourcePath -SitePath $sitePath -BackupDirectory $backupDirectory

if ($PSCmdlet.ShouldProcess($siteName, "Transactionally deploy static_iis output and configure IIS")) {
    $sitePathExisted = Test-Path -LiteralPath $sitePath -PathType Container
    $snapshot = Get-StaticIisDeploymentSnapshot `
        -SiteName $siteName `
        -AppPoolName $appPoolName `
        -Protocol $protocol `
        -Port $publicPort `
        -HostHeader $publicHostName `
        -TlsEnabled $tlsEnabled
    $backupPath = ""
    try {
        New-Item -ItemType Directory -Force -Path $sitePath | Out-Null
        Test-DirectoryWriteAccess -Path $sitePath
        $backupPath = Backup-StaticSiteIfPresent -SitePath $sitePath -BackupDirectory $backupDirectory
        Stop-StaticIisSiteForDeployment -SiteName $siteName -Snapshot $snapshot
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

        Ensure-StaticAppPool $appPoolName
        if (-not (Test-Path "IIS:\Sites\$siteName")) {
            $initialPort = if ($tlsEnabled) { 80 } else { $publicPort }
            New-Website -Name $siteName -PhysicalPath $sitePath -ApplicationPool $appPoolName -Port $initialPort -HostHeader $publicHostName | Out-Null
            if ($tlsEnabled) {
                Remove-WebBinding -Name $siteName -Protocol "http" -Port $initialPort -HostHeader $publicHostName -ErrorAction Stop
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
        Assert-StaticIisTargetReady `
            -SiteName $siteName `
            -AppPoolName $appPoolName `
            -SitePath $sitePath `
            -Protocol $protocol `
            -Port $publicPort `
            -HostHeader $publicHostName
    } catch {
        $deploymentFailure = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        try {
            Restore-StaticSiteContent -SitePath $sitePath -BackupPath $backupPath -SitePathExisted $sitePathExisted
            Write-Warning "Restored previous IIS static folder after deployment failure."
        } catch {
            $rollbackFailures.Add("content: $($_.Exception.Message)") | Out-Null
        }
        try {
            Restore-StaticIisDeploymentSnapshot `
                -SiteName $siteName `
                -AppPoolName $appPoolName `
                -Protocol $protocol `
                -Port $publicPort `
                -HostHeader $publicHostName `
                -Snapshot $snapshot
            Write-Warning "Restored previous IIS site state after deployment failure."
        } catch {
            $rollbackFailures.Add("IIS: $($_.Exception.Message)") | Out-Null
        }
        if ($rollbackFailures.Count -gt 0) {
            throw "Static IIS deployment failed: $($deploymentFailure.Exception.Message) Rollback also failed: $($rollbackFailures -join '; ')"
        }
        throw $deploymentFailure
    }
}

Write-Host "Static IIS deployment finished: $siteName"
Write-Host "IIS app pool configured for No Managed Code: $appPoolName"
