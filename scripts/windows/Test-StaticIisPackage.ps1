<#
.SYNOPSIS
  Validate a static IIS SPA package before Windows deployment.
.DESCRIPTION
  Checks for unsafe archive paths, blocked private files, the configured SPA
  shell under StaticOutputDirectory, optional browser assets, and a plain IIS
  web.config when one is included. URL Rewrite sections are blocked unless the
  caller explicitly allows them for a separate rewrite-enabled mode.
.EXAMPLE
  .\scripts\windows\Test-StaticIisPackage.ps1 -PackagePath C:\deploy\example-static-spa.zip -StaticOutputDirectory dist/client -SpaShellFile _shell.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $PackagePath,
    [string] $StaticOutputDirectory = "dist/client",
    [string] $SpaShellFile = "_shell.html",
    [switch] $StripSingleTopLevelDirectory,
    [switch] $AllowRewrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Test-BlockedArtifactPath {
    param([string]$RelativePath)

    $name = [System.IO.Path]::GetFileName($RelativePath)
    $extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($name -eq ".env" -or $name -like ".env.*") { return $true }
    if ($extension -in @(".key", ".pem", ".pfx", ".p12", ".crt", ".csr")) { return $true }
    return $false
}

function ConvertTo-RuntimeEntryName {
    param(
        [string]$EntryName,
        [string]$TopLevelDirectory
    )

    $normalized = ($EntryName -replace "\\", "/").TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($TopLevelDirectory)) { return $normalized }
    $prefix = $TopLevelDirectory.TrimEnd("/") + "/"
    if ($normalized -eq $TopLevelDirectory.TrimEnd("/")) { return "" }
    if ($normalized.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        return $normalized.Substring($prefix.Length)
    }
    return $normalized
}

function Get-SingleTopLevelDirectory {
    param([string[]]$Entries)

    $topLevels = @($Entries |
        ForEach-Object {
            $value = ($_ -replace "\\", "/").Trim("/")
            if ($value.Contains("/")) { $value.Split("/")[0] } else { $value }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    if ($topLevels.Count -eq 1) { return $topLevels[0] }
    return ""
}

function Read-ZipEntryText {
    param($Entry)

    $reader = [System.IO.StreamReader]::new($Entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Assert-PlainIisWebConfigText {
    param(
        [string]$Text,
        [string]$Context,
        [string]$ShellFile,
        [bool]$RewriteAllowed
    )

    try {
        [xml]$xml = $Text
    }
    catch {
        throw "$Context is not valid XML. $($_.Exception.Message)"
    }

    $rewriteNodes = @($xml.SelectNodes("//*[local-name()='rewrite']"))
    if ($rewriteNodes.Count -gt 0 -and -not $RewriteAllowed) {
        throw "$Context contains an unsupported <rewrite> section. static_iis mode does not require URL Rewrite or ARR."
    }

    $defaultDocumentValues = @($xml.SelectNodes("//*[local-name()='defaultDocument']/*[local-name()='files']/*[local-name()='add']") |
        ForEach-Object { [string]$_.value })
    if ($defaultDocumentValues -notcontains $ShellFile) {
        throw "$Context must configure defaultDocument to include $ShellFile."
    }

    $expectedFallbackPath = "/" + $ShellFile
    $fallbacks = @($xml.SelectNodes("//*[local-name()='httpErrors']/*[local-name()='error']") |
        Where-Object {
            [string]$_.statusCode -eq "404" -and
            [string]$_.path -eq $expectedFallbackPath -and
            [string]$_.responseMode -eq "ExecuteURL"
        })
    if ($fallbacks.Count -eq 0) {
        throw "$Context must configure httpErrors 404 ExecuteURL fallback to $expectedFallbackPath."
    }
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "PackagePath not found: $PackagePath"
}
$PackagePath = [System.IO.Path]::GetFullPath($PackagePath)
if ([System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant() -ne ".zip") {
    throw "Windows static_iis package validation supports .zip only."
}

$staticRoot = Get-NormalizedRelativePath -Path $StaticOutputDirectory -Default "dist/client"
$shellFile = Get-NormalizedRelativePath -Path $SpaShellFile -Default "_shell.html"
if (-not (Test-SafeRelativePath $staticRoot)) {
    throw "StaticOutputDirectory must be a safe relative directory path."
}
if (-not (Test-SafeRelativePath $shellFile) -or $shellFile.Contains("/")) {
    throw "SpaShellFile must be a safe relative file name."
}

$shellEntry = "$staticRoot/$shellFile"
$assetsPrefix = "$staticRoot/assets/"
$webConfigEntry = "$staticRoot/web.config"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $rawEntries = @($zip.Entries | ForEach-Object { $_.FullName.Replace("\", "/") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($rawEntries.Count -eq 0) {
        throw "Package archive is empty."
    }

    foreach ($entry in $zip.Entries) {
        $entryName = $entry.FullName.Replace("\", "/")
        if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
        if (-not (Test-SafeArchiveEntryName $entryName)) {
            throw "Unsafe archive entry path detected: $entryName"
        }
        $unsafeType = Get-UnsafeZipEntryType $entry
        if (-not [string]::IsNullOrWhiteSpace($unsafeType)) {
            throw "Unsafe archive entry type detected: $entryName is $unsafeType. Symlinks and special files are intentionally unsupported in deployment archives."
        }
    }

    $topLevelDirectory = ""
    if ($StripSingleTopLevelDirectory) {
        $topLevelDirectory = Get-SingleTopLevelDirectory -Entries $rawEntries
    }

    $runtimeEntries = @($rawEntries |
        ForEach-Object { ConvertTo-RuntimeEntryName -EntryName $_ -TopLevelDirectory $topLevelDirectory } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $blocked = @($runtimeEntries | Where-Object { Test-BlockedArtifactPath $_ })
    if ($blocked.Count -gt 0) {
        throw "Package contains blocked private file(s): $($blocked -join ', ')"
    }

    if ($runtimeEntries -notcontains $shellEntry) {
        throw "Package is missing static_iis SPA shell file at $shellEntry."
    }

    $assetEntries = @($runtimeEntries | Where-Object { $_ -like "$assetsPrefix*" -and -not $_.EndsWith("/") })
    if ($assetEntries.Count -eq 0) {
        Write-Warning "Package has no browser asset entries under $assetsPrefix. This can be valid for tiny apps, but verify the built artifact contains browser assets."
    }

    if ($runtimeEntries -contains $webConfigEntry) {
        $webConfigZipEntry = @($zip.Entries | Where-Object {
            $runtimeName = ConvertTo-RuntimeEntryName -EntryName $_.FullName.Replace("\", "/") -TopLevelDirectory $topLevelDirectory
            $runtimeName -eq $webConfigEntry
        } | Select-Object -First 1)
        if ($webConfigZipEntry.Count -gt 0) {
            $webConfigText = Read-ZipEntryText $webConfigZipEntry[0]
            Assert-PlainIisWebConfigText -Text $webConfigText -Context $webConfigEntry -ShellFile $shellFile -RewriteAllowed ([bool]$AllowRewrite)
        }
    }

    Write-Host "Static IIS package OK" -ForegroundColor Green
}
finally {
    $zip.Dispose()
}
