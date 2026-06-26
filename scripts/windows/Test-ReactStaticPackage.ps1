<#
.SYNOPSIS
  Validate a React static build package before Windows deployment.
.DESCRIPTION
  Checks for unsafe archive paths, blocked private files, and index.html under
  the configured ReactDocumentRoot. This is a read-only package validation
  helper for React apps served by the configured Node.js service.
.EXAMPLE
  .\scripts\windows\Test-ReactStaticPackage.ps1 -PackagePath C:\deploy\react-app.zip -ReactDocumentRoot build
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $PackagePath,
    [string] $ReactDocumentRoot = "build",
    [switch] $StripSingleTopLevelDirectory
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

function Get-ReactDocumentRootPath([string]$Path) {
    $normalized = ($Path -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = "build"
    }
    return $normalized
}

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "PackagePath not found: $PackagePath"
}
$PackagePath = [System.IO.Path]::GetFullPath($PackagePath)
if ([System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant() -ne ".zip") {
    throw "Windows React package validation supports .zip only."
}

$documentRoot = Get-ReactDocumentRootPath $ReactDocumentRoot
if (-not (Test-SafeRelativePath $documentRoot)) {
    throw "ReactDocumentRoot must be a safe relative directory path."
}
$indexEntry = if ($documentRoot -eq ".") { "index.html" } else { "$documentRoot/index.html" }
$assetPrefix = if ($documentRoot -eq ".") { "" } else { "$documentRoot/" }

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

    if ($runtimeEntries -notcontains $indexEntry) {
        throw "Package is missing React index.html at $indexEntry."
    }
    if (-not ($runtimeEntries | Where-Object { $_ -like "${assetPrefix}static/*" -or $_ -like "${assetPrefix}assets/*" })) {
        Write-Warning "Package has no React static/assets entries under $documentRoot. This can be valid for tiny apps, but verify browser assets are present."
    }

    Write-Host "React static package OK: $PackagePath" -ForegroundColor Green
}
finally {
    $zip.Dispose()
}
