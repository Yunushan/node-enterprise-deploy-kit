<#
.SYNOPSIS
  Safely import a Windows application package into AppDirectory.
.DESCRIPTION
  Supports .zip packages using built-in .NET archive handling. The package is
  validated before extraction, extracted to a temporary directory, checked for
  expected files, and then moved into AppDirectory after backing up the current
  application directory.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $PackagePath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-ConfigRelativePath {
    param(
        [string] $BasePath,
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $BasePath) $Path))
}

function Get-ConfigString {
    param($Config, [string]$Name, [string]$Default = "")
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

function Get-ConfigEnvironmentString {
    param($Config, [string]$Name, [string]$Default = "")
    if (-not $Config.PSObject.Properties["Environment"] -or -not $Config.Environment) { return $Default }
    if ($Config.Environment.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.Environment.$Name)) {
        return [string]$Config.Environment.$Name
    }
    return $Default
}

function Get-ConfigBool {
    param($Config, [string]$Name, [bool]$Default)
    if (-not $Config.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Default
    }
    switch -Regex ([string]$Config.$Name) {
        '^(true|1|yes)$' { return $true }
        '^(false|0|no)$' { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}

function Test-ReactFramework([string]$Framework) {
    return (Normalize-Name $Framework) -in @("react", "reactjs", "react-js")
}

function Test-StaticIisDeploymentMode($Config) {
    return (Normalize-Name (Get-ConfigString $Config "DeploymentMode" "")) -eq "static-iis"
}

function Test-StaticIisFramework([string]$Framework) {
    return (Normalize-Name $Framework) -in @("tanstack-start", "vite-spa")
}

function Get-NormalizedStaticRelativePath([string]$Path, [string]$Default) {
    $value = $Path
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
    }
    $value = ($value -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
    }
    return $value
}

function Get-StaticOutputDirectory($Config) {
    return Get-NormalizedStaticRelativePath (Get-ConfigString $Config "StaticOutputDirectory" "dist/client") "dist/client"
}

function Get-SpaShellFile($Config) {
    return Get-NormalizedStaticRelativePath (Get-ConfigString $Config "SpaShellFile" "_shell.html") "_shell.html"
}

function Join-StaticRelativePath([string]$Root, [string]$Leaf) {
    $rootValue = ($Root -replace "\\", "/").Trim("/")
    $leafValue = ($Leaf -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($rootValue)) { return $leafValue }
    return "$rootValue/$leafValue"
}

function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return (Join-Path $Config.ServiceDirectory "backups")
    }
    return (Join-Path (Split-Path -Parent $Config.AppDirectory) "backups")
}

function Test-SafeArchiveEntryName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = $Name -replace "\\", "/"
    if ($normalized.StartsWith("/") -or $normalized -match '^[A-Za-z]:') { return $false }
    $parts = @($normalized.Split("/") | Where-Object { $_ -ne "" })
    if ($parts.Count -eq 0) { return $false }
    foreach ($part in $parts) {
        if ($part -eq "." -or $part -eq "..") { return $false }
        if ($part.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    }
    return $true
}

function Get-UnsafeZipEntryType {
    param($Entry)

    $rawAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Entry.ExternalAttributes), 0)
    $unixFileType = (($rawAttributes -shr 16) -band 0xF000)
    if ($unixFileType -eq 0 -or $unixFileType -eq 0x4000 -or $unixFileType -eq 0x8000) {
        return ""
    }
    if ($unixFileType -eq 0xA000) {
        return "symlink"
    }
    return ("special Unix file type 0x{0:X4}" -f $unixFileType)
}

function Assert-ZipPackageSafe {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not (Test-SafeArchiveEntryName $entry.FullName)) {
                throw "Unsafe archive entry path detected: $($entry.FullName)"
            }
            $unsafeType = Get-UnsafeZipEntryType $entry
            if (-not [string]::IsNullOrWhiteSpace($unsafeType)) {
                throw "Unsafe archive entry type detected: $($entry.FullName) is $unsafeType. Symlinks and special files are intentionally unsupported in deployment archives."
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-ExtractedTreeSafe {
    param([string]$RootPath)

    foreach ($item in Get-ChildItem -LiteralPath $RootPath -Force -Recurse) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe extracted reparse point detected: $($item.FullName). Symlinks and junctions are intentionally unsupported in deployment archives."
        }
    }
}

function Get-ExpectedPackageFiles {
    param($Config)

    if ($Config.PSObject.Properties["PackageExpectedFiles"]) {
        $value = $Config.PackageExpectedFiles
        if ($value -is [array]) {
            return @($value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        return @(([string]$value) -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if (Test-StaticIisDeploymentMode $Config) {
        return @((Join-StaticRelativePath (Get-StaticOutputDirectory $Config) (Get-SpaShellFile $Config)))
    }
    return @((Get-ConfigString $Config "StartCommand" "server.js"))
}

function Get-PackageSourceRoot {
    param(
        [string] $ExtractRoot,
        [bool] $StripSingleTopLevelDirectory
    )

    if (-not $StripSingleTopLevelDirectory) { return $ExtractRoot }
    $children = @(Get-ChildItem -LiteralPath $ExtractRoot -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        return $children[0].FullName
    }
    return $ExtractRoot
}

function Assert-ExpectedFiles {
    param(
        [string] $SourceRoot,
        [string[]] $ExpectedFiles
    )

    foreach ($relative in $ExpectedFiles) {
        if (-not (Test-SafeArchiveEntryName $relative)) {
            throw "PackageExpectedFiles contains an unsafe relative path: $relative"
        }
        $candidate = Join-Path $SourceRoot ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Imported package is missing expected path: $relative"
        }
    }
}

function Test-NextJsPackageIfNeeded {
    param(
        $Config,
        [string]$Path,
        [bool]$StripSingleTopLevelDirectory
    )

    $framework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
    $mode = Normalize-Name (Get-ConfigString $Config "NextjsDeploymentMode" "standalone")
    if ($framework -notin @("next", "nextjs", "next-js")) {
        return
    }
    if ($mode -notin @("standalone", "next-start")) {
        throw "NextjsDeploymentMode must be standalone or next-start."
    }

    $validator = Join-Path $PSScriptRoot "Test-NextJsStandalonePackage.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Next.js package validator not found: $validator"
    }

    $arguments = @{
        PackagePath = $Path
        Mode = $mode
    }
    if ($StripSingleTopLevelDirectory) {
        $arguments.StripSingleTopLevelDirectory = $true
    }
    if (Get-ConfigBool $Config "NextjsRequirePublicDirectory" $false) {
        $arguments.RequirePublicDirectory = $true
    }
    & $validator @arguments
}

function Get-ReactDocumentRoot {
    param($Config)

    $documentRoot = (Get-ConfigString $Config "ReactDocumentRoot" "build").Trim()
    if ([string]::IsNullOrWhiteSpace($documentRoot)) {
        $documentRoot = "build"
    }
    return ($documentRoot -replace "\\", "/").Trim("/")
}

function Test-ReactPackageIfNeeded {
    param(
        $Config,
        [string]$Path,
        [bool]$StripSingleTopLevelDirectory
    )

    $framework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
    if (-not (Test-ReactFramework $framework)) {
        return
    }

    $validator = Join-Path $PSScriptRoot "Test-ReactStaticPackage.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "React package validator not found: $validator"
    }

    $arguments = @{
        PackagePath = $Path
        ReactDocumentRoot = Get-ReactDocumentRoot $Config
    }
    if ($StripSingleTopLevelDirectory) {
        $arguments.StripSingleTopLevelDirectory = $true
    }
    & $validator @arguments
}

function Test-StaticIisPackageIfNeeded {
    param(
        $Config,
        [string]$Path,
        [bool]$StripSingleTopLevelDirectory
    )

    $framework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
    if (-not (Test-StaticIisDeploymentMode $Config) -and -not (Test-StaticIisFramework $framework)) {
        return
    }
    if (-not (Test-StaticIisDeploymentMode $Config)) {
        throw "Static IIS package validation requires DeploymentMode=static_iis."
    }
    if (-not (Test-StaticIisFramework $framework)) {
        throw "static_iis AppFramework must be tanstack-start or vite-spa."
    }

    $validator = Join-Path $PSScriptRoot "Test-StaticIisPackage.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Static IIS package validator not found: $validator"
    }

    $arguments = @{
        PackagePath = $Path
        StaticOutputDirectory = Get-StaticOutputDirectory $Config
        SpaShellFile = Get-SpaShellFile $Config
    }
    if ($StripSingleTopLevelDirectory) {
        $arguments.StripSingleTopLevelDirectory = $true
    }
    if (Get-ConfigBool $Config "IisStaticAllowUrlRewrite" $false) {
        $arguments.AllowRewrite = $true
    }
    & $validator @arguments
}

function Stop-AppServiceIfPresent {
    param([string]$Name)

    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Host "Windows service cmdlets are unavailable; skipping service stop before package import."
        return
    }

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Stopped") {
        if (-not (Get-Command Stop-Service -ErrorAction SilentlyContinue)) {
            throw "Stop-Service cmdlet is required to stop running service before package import."
        }
        Write-Host "Stopping service before package import: $Name"
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(60))
    }
}

function Get-FirstLineFromFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    try {
        return [string](Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
    } catch {
        return ""
    }
}

function Get-NextBuildIdFromDirectory {
    param([string]$AppDirectory)
    $candidate = Join-Path $AppDirectory ".next\BUILD_ID"
    $value = Get-FirstLineFromFile $candidate
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    return ""
}

function Get-DeploymentIdFromConfig {
    param($Config)
    $deploymentId = Get-ConfigString $Config "DeploymentId" ""
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        $deploymentId = Get-ConfigEnvironmentString $Config "NEXT_DEPLOYMENT_ID" ""
    }
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        $deploymentId = Get-ConfigEnvironmentString $Config "DEPLOYMENT_ID" ""
    }
    return $deploymentId
}

function Write-DeploymentManifest {
    param(
        $Config,
        [string]$AppDirectory,
        [string]$PackagePath
    )

    $manifestPath = Join-Path $AppDirectory ".node-enterprise-deploy.json"
    $packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schema = "node-enterprise-deploy-kit/import-manifest/v1"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        appName = [string]$Config.AppName
        deploymentMode = Normalize-Name (Get-ConfigString $Config "DeploymentMode" "")
        appFramework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
        nextjsMode = Normalize-Name (Get-ConfigString $Config "NextjsDeploymentMode" "")
        reactDocumentRoot = Get-ReactDocumentRoot $Config
        staticOutputDirectory = Get-StaticOutputDirectory $Config
        spaShellFile = Get-SpaShellFile $Config
        packageName = [System.IO.Path]::GetFileName($PackagePath)
        packageSha256 = $packageHash
        deploymentId = Get-DeploymentIdFromConfig $Config
        nextBuildId = Get-NextBuildIdFromDirectory $AppDirectory
    }
    $manifest |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if (Test-StaticIisDeploymentMode $Config) {
        Write-Host "Deployment manifest written."
    } else {
        Write-Host "Deployment manifest written: $manifestPath"
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Get-ConfigString $config "PackagePath" ""
}
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    Write-Host "No PackagePath configured; skipping package import."
    return
}

$PackagePath = Resolve-ConfigRelativePath -BasePath $ConfigPath -Path $PackagePath
if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "PackagePath not found: $PackagePath"
}
if ([System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant() -ne ".zip") {
    throw "Windows package import supports .zip only. Use .zip for Windows deployments; .rar and .7z require external tooling and are intentionally unsupported."
}

$appDirectory = [System.IO.Path]::GetFullPath([string]$config.AppDirectory)
$backupDirectory = [System.IO.Path]::GetFullPath((Get-BackupDirectory $config))
$stripSingleTopLevelDirectory = Get-ConfigBool $config "PackageStripSingleTopLevelDirectory" $true
$expectedFiles = @(Get-ExpectedPackageFiles $config)

if ($backupDirectory.StartsWith($appDirectory.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupDirectory must not be inside AppDirectory when importing packages."
}

Assert-ZipPackageSafe -Path $PackagePath
Test-NextJsPackageIfNeeded -Config $config -Path $PackagePath -StripSingleTopLevelDirectory $stripSingleTopLevelDirectory
Test-ReactPackageIfNeeded -Config $config -Path $PackagePath -StripSingleTopLevelDirectory $stripSingleTopLevelDirectory
Test-StaticIisPackageIfNeeded -Config $config -Path $PackagePath -StripSingleTopLevelDirectory $stripSingleTopLevelDirectory

$extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("node-enterprise-package-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
$backupPath = ""

try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $extractRoot)
    Assert-ExtractedTreeSafe -RootPath $extractRoot
    $sourceRoot = Get-PackageSourceRoot -ExtractRoot $extractRoot -StripSingleTopLevelDirectory $stripSingleTopLevelDirectory
    Assert-ExpectedFiles -SourceRoot $sourceRoot -ExpectedFiles $expectedFiles

    if ($PSCmdlet.ShouldProcess($appDirectory, "Import application package $PackagePath")) {
        if (-not (Test-StaticIisDeploymentMode $config)) {
            Stop-AppServiceIfPresent -Name ([string]$config.AppName)
        }
        New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $appDirectory) | Out-Null

        if (Test-Path -LiteralPath $appDirectory) {
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
            $backupPath = Join-Path $backupDirectory ("app.{0}.{1}.bak" -f $timestamp, $PID)
            Move-Item -LiteralPath $appDirectory -Destination $backupPath -Force
            if (Test-StaticIisDeploymentMode $config) {
                Write-Host "Backed up existing AppDirectory."
            } else {
                Write-Host "Backed up existing AppDirectory to: $backupPath"
            }
        }

        New-Item -ItemType Directory -Force -Path $appDirectory | Out-Null
        try {
            foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Force) {
                Copy-Item -LiteralPath $item.FullName -Destination $appDirectory -Recurse -Force
            }
            Write-DeploymentManifest -Config $config -AppDirectory $appDirectory -PackagePath $PackagePath
        }
        catch {
            if (Test-Path -LiteralPath $appDirectory) {
                Remove-Item -LiteralPath $appDirectory -Recurse -Force
            }
            if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $appDirectory -Force
                Write-Warning "Restored previous AppDirectory after package import failure."
            }
            throw
        }

        if (Test-StaticIisDeploymentMode $config) {
            Write-Host "Imported package into AppDirectory." -ForegroundColor Green
        } else {
            Write-Host "Imported package into AppDirectory: $appDirectory" -ForegroundColor Green
        }
    }
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
}
