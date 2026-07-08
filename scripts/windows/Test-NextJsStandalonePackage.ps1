<#
.SYNOPSIS
  Validate a Next.js zip package before Windows deployment.
.DESCRIPTION
  Checks for unsafe archive paths, blocked private files, and the expected
  Next.js runtime entries for standalone or next-start mode. This is a
  read-only package validation helper.
.EXAMPLE
  .\scripts\windows\Test-NextJsStandalonePackage.ps1 -PackagePath C:\deploy\example-node-app.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $PackagePath,
    [ValidateSet("standalone", "next-start")] [string] $Mode = "standalone",
    [switch] $StripSingleTopLevelDirectory,
    [switch] $RequirePublicDirectory
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

$modeNormalized = $Mode.Trim().ToLowerInvariant()
if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "PackagePath not found: $PackagePath"
}
$PackagePath = [System.IO.Path]::GetFullPath($PackagePath)
if ([System.IO.Path]::GetExtension($PackagePath).ToLowerInvariant() -ne ".zip") {
    throw "Windows Next.js package validation supports .zip only."
}

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

    if ($modeNormalized -eq "standalone") {
        if ($runtimeEntries -notcontains "server.js") {
            throw "Package is missing server.js at the runtime root."
        }
        if ($runtimeEntries -notcontains ".next/BUILD_ID") {
            throw "Package is missing .next/BUILD_ID at the runtime root."
        }
        if (-not ($runtimeEntries | Where-Object { $_ -like ".next/static/*" })) {
            throw "Package is missing .next/static content."
        }
        if ($runtimeEntries -notcontains "node_modules/next/package.json") {
            throw "Package is missing node_modules/next/package.json at the runtime root."
        }
    } elseif ($modeNormalized -eq "next-start") {
        if ($runtimeEntries -notcontains "package.json") {
            throw "Package is missing package.json at the runtime root."
        }
        if ($runtimeEntries -notcontains ".next/BUILD_ID") {
            throw "Package is missing .next/BUILD_ID at the runtime root."
        }
        if (-not ($runtimeEntries | Where-Object { $_ -like ".next/*" })) {
            throw "Package is missing .next build output."
        }
        if (-not ($runtimeEntries | Where-Object { $_ -like "node_modules/next/*" })) {
            throw "Package is missing node_modules/next content."
        }
        if ($runtimeEntries -notcontains "node_modules/next/package.json") {
            throw "Package is missing node_modules/next/package.json at the runtime root."
        }
        if ($runtimeEntries -notcontains "node_modules/next/dist/bin/next") {
            throw "Package is missing node_modules/next/dist/bin/next at the runtime root."
        }
    }

    if ($RequirePublicDirectory -and -not ($runtimeEntries | Where-Object { $_ -like "public/*" })) {
        throw "Package is missing public content, but RequirePublicDirectory was set."
    }

    Write-Host "Next.js $modeNormalized package OK: $PackagePath" -ForegroundColor Green
}
finally {
    $zip.Dispose()
}
