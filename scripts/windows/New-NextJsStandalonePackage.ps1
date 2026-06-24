<#
.SYNOPSIS
  Build a deployable Next.js standalone zip package.
.DESCRIPTION
  Copies .next\standalone, adds .next\static, optionally adds public, blocks
  obvious private files from the staged artifact, and creates a zip whose root
  contains server.js.
.EXAMPLE
  .\scripts\windows\New-NextJsStandalonePackage.ps1 `
    -ProjectPath C:\src\example-node-app `
    -OutputPath C:\deploy\example-node-app.zip
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$ProjectPath = ".",
    [string]$OutputPath = "",
    [string]$StageDirectory = "",
    [switch]$RequirePublicDirectory,
    [switch]$NoPublic,
    [switch]$KeepStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source directory not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-RelativeArtifactPath {
    param(
        [string]$Root,
        [string]$Path
    )

    return $Path.Substring($Root.Length + 1).Replace("\", "/")
}

function Test-BlockedArtifactPath {
    param([string]$RelativePath)

    $name = [System.IO.Path]::GetFileName($RelativePath)
    $extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($name -eq ".env" -or $name -like ".env.*") { return $true }
    if ($extension -in @(".key", ".pem", ".pfx", ".p12", ".crt", ".csr")) { return $true }
    return $false
}

function Assert-NoBlockedArtifactFiles {
    param([string]$Root)

    $blocked = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { Get-RelativeArtifactPath -Root $Root -Path $_.FullName } |
        Where-Object { Test-BlockedArtifactPath $_ })

    if ($blocked.Count -gt 0) {
        $summary = $blocked -join ", "
        throw "Next.js package stage contains blocked private file(s): $summary"
    }
}

function Assert-ZipContainsExpectedPaths {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
        if ($entries -notcontains "server.js") {
            throw "Package zip is missing server.js at the archive root."
        }
        if ($entries -notcontains ".next/BUILD_ID") {
            throw "Package zip is missing .next/BUILD_ID at the archive root."
        }
        if (-not ($entries | Where-Object { $_ -like ".next/static/*" })) {
            throw "Package zip is missing .next/static content."
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-NextJsPackageValid {
    param([string]$Path)

    $validator = Join-Path $PSScriptRoot "Test-NextJsStandalonePackage.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Next.js package validator not found: $validator"
    }

    $arguments = @{
        PackagePath = $Path
        Mode = "standalone"
    }
    if ($RequirePublicDirectory) {
        $arguments.RequirePublicDirectory = $true
    }
    & $validator @arguments *>&1 | Out-Null
}

$projectRoot = Resolve-FullPath $ProjectPath
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectPath was not found: $projectRoot"
}

$standaloneRoot = Join-Path $projectRoot ".next\standalone"
$standaloneServer = Join-Path $standaloneRoot "server.js"
$staticRoot = Join-Path $projectRoot ".next\static"
$buildIdPath = Join-Path $projectRoot ".next\BUILD_ID"
$publicRoot = Join-Path $projectRoot "public"

if (-not (Test-Path -LiteralPath $standaloneServer -PathType Leaf)) {
    throw "Next.js standalone server was not found: $standaloneServer. Build with output: 'standalone' before packaging."
}
if (-not (Test-Path -LiteralPath $staticRoot -PathType Container)) {
    throw "Next.js static assets were not found: $staticRoot"
}
if (-not (Test-Path -LiteralPath $buildIdPath -PathType Leaf)) {
    throw "Next.js BUILD_ID was not found: $buildIdPath. Build the app before packaging so runtime evidence can identify the deployed build."
}
if ($RequirePublicDirectory -and -not (Test-Path -LiteralPath $publicRoot -PathType Container)) {
    throw "RequirePublicDirectory was set, but public directory was not found: $publicRoot"
}

$projectName = Split-Path -Leaf $projectRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "release\$projectName-nextjs-standalone.zip"
}
if ([string]::IsNullOrWhiteSpace($StageDirectory)) {
    $StageDirectory = Join-Path $projectRoot ".tmp\nextjs-standalone-package"
}

$zipPath = Resolve-FullPath $OutputPath
$stageRoot = Resolve-FullPath $StageDirectory

if ($PSCmdlet.ShouldProcess($stageRoot, "Stage Next.js standalone package")) {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

    Copy-DirectoryContents -Source $standaloneRoot -Destination $stageRoot

    $stageNextDir = Join-Path $stageRoot ".next"
    $stageStatic = Join-Path $stageNextDir "static"
    if (Test-Path -LiteralPath $stageStatic) {
        Remove-Item -LiteralPath $stageStatic -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stageNextDir | Out-Null
    Copy-Item -LiteralPath $staticRoot -Destination $stageStatic -Recurse -Force
    Copy-Item -LiteralPath $buildIdPath -Destination (Join-Path $stageNextDir "BUILD_ID") -Force

    if (-not $NoPublic -and (Test-Path -LiteralPath $publicRoot -PathType Container)) {
        $stagePublic = Join-Path $stageRoot "public"
        if (Test-Path -LiteralPath $stagePublic) {
            Remove-Item -LiteralPath $stagePublic -Recurse -Force
        }
        Copy-Item -LiteralPath $publicRoot -Destination $stagePublic -Recurse -Force
    }

    Assert-NoBlockedArtifactFiles -Root $stageRoot
}

$zipDirectory = Split-Path -Parent $zipPath
New-Item -ItemType Directory -Force -Path $zipDirectory | Out-Null
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

if ($PSCmdlet.ShouldProcess($zipPath, "Create Next.js standalone zip package")) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    Assert-ZipContainsExpectedPaths -Path $zipPath
    Assert-NextJsPackageValid -Path $zipPath
    Write-Host "Next.js standalone package: $zipPath" -ForegroundColor Green
}

if (-not $KeepStage -and (Test-Path -LiteralPath $stageRoot)) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
