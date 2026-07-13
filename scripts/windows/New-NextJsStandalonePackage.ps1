<#
.SYNOPSIS
  Build a deployable Next.js zip package.
.DESCRIPTION
  In standalone mode, copies .next\standalone, adds .next\static, optionally
  adds public, blocks obvious private files from the staged artifact, and
  creates a zip whose root contains server.js. In next-start mode, stages the
  full production runtime needed by next start: package.json, .next,
  node_modules, optional public, plus common Next.js config and lock files.
.EXAMPLE
  .\scripts\windows\New-NextJsStandalonePackage.ps1 `
    -ProjectPath C:\src\example-node-app `
    -OutputPath C:\deploy\example-node-app.zip
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$ProjectPath = ".",
    [ValidateSet("standalone", "next-start")] [string]$Mode = "standalone",
    [string]$OutputPath = "",
    [string]$StageDirectory = "",
    [switch]$RequirePublicDirectory,
    [switch]$NoPublic,
    [switch]$KeepStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PackageProvenanceFileName = ".node-enterprise-package.json"
$PackageProvenanceSchema = "node-enterprise-deploy-kit/nextjs-package-provenance/v1"

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
    param(
        [string]$Path,
        [string]$Mode
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
        if ($Mode -eq "standalone") {
            if ($entries -notcontains "server.js") {
                throw "Package zip is missing server.js at the archive root."
            }
            if ($entries -notcontains ".next/BUILD_ID") {
                throw "Package zip is missing .next/BUILD_ID at the archive root."
            }
            if (-not ($entries | Where-Object { $_ -like ".next/static/*" })) {
                throw "Package zip is missing .next/static content."
            }
            if ($entries -notcontains "node_modules/next/package.json") {
                throw "Package zip is missing node_modules/next/package.json at the archive root."
            }
        } else {
            if ($entries -notcontains "package.json") {
                throw "Package zip is missing package.json at the archive root."
            }
            if ($entries -notcontains ".next/BUILD_ID") {
                throw "Package zip is missing .next/BUILD_ID at the archive root."
            }
            if (-not ($entries | Where-Object { $_ -like ".next/*" })) {
                throw "Package zip is missing .next build output."
            }
            if (-not ($entries | Where-Object { $_ -like "node_modules/next/*" })) {
                throw "Package zip is missing node_modules/next content."
            }
            if ($entries -notcontains "node_modules/next/package.json") {
                throw "Package zip is missing node_modules/next/package.json at the archive root."
            }
            if ($entries -notcontains "node_modules/next/dist/bin/next") {
                throw "Package zip is missing node_modules/next/dist/bin/next at the archive root."
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-NextJsPackageValid {
    param(
        [string]$Path,
        [string]$Mode
    )

    $validator = Join-Path $PSScriptRoot "Test-NextJsStandalonePackage.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Next.js package validator not found: $validator"
    }

    $arguments = @{
        PackagePath = $Path
        Mode = $Mode
    }
    if ($RequirePublicDirectory) {
        $arguments.RequirePublicDirectory = $true
    }
    & $validator @arguments *>&1 | Out-Null
}

function Get-WindowsArchitecture {
    $raw = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432", "Process")
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process")
    }
    if ($null -eq $raw) { $raw = "" }
    switch ($raw.Trim().ToLowerInvariant()) {
        { $_ -in @("amd64", "x64") } { return "x64" }
        { $_ -in @("arm64", "aarch64") } { return "arm64" }
        { $_ -in @("x86", "i386", "i686") } { return "x86" }
        default { return "unknown" }
    }
}

function Write-PackageProvenance {
    param(
        [string]$Root,
        [string]$Mode,
        [string]$NextPackageJsonPath,
        [string]$BuildIdPath
    )

    $nextMetadata = Get-Content -LiteralPath $NextPackageJsonPath -Raw | ConvertFrom-Json
    $nextVersion = ([string]$nextMetadata.version).Trim()
    $buildId = ([string](Get-Content -LiteralPath $BuildIdPath -TotalCount 1)).Trim()
    if ([string]::IsNullOrWhiteSpace($nextVersion) -or [string]::IsNullOrWhiteSpace($buildId)) {
        throw "Next.js package provenance requires a non-empty Next.js version and BUILD_ID."
    }

    $provenance = [ordered]@{
        schema = $PackageProvenanceSchema
        appFramework = "nextjs"
        nextjsMode = $Mode
        buildPlatform = "windows"
        buildArchitecture = Get-WindowsArchitecture
        buildLibc = "not-applicable"
        nextVersion = $nextVersion
        nextBuildId = $buildId
    }
    $path = Join-Path $Root $PackageProvenanceFileName
    $provenance | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
}

$projectRoot = Resolve-FullPath $ProjectPath
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "ProjectPath was not found: $projectRoot"
}

$modeNormalized = $Mode.Trim().ToLowerInvariant()
$standaloneRoot = Join-Path $projectRoot ".next\standalone"
$standaloneServer = Join-Path $standaloneRoot "server.js"
$standaloneNextPackageJsonPath = Join-Path $standaloneRoot "node_modules\next\package.json"
$staticRoot = Join-Path $projectRoot ".next\static"
$nextRoot = Join-Path $projectRoot ".next"
$buildIdPath = Join-Path $projectRoot ".next\BUILD_ID"
$publicRoot = Join-Path $projectRoot "public"
$packageJsonPath = Join-Path $projectRoot "package.json"
$nodeModulesRoot = Join-Path $projectRoot "node_modules"
$nextPackageRoot = Join-Path $nodeModulesRoot "next"
$nextPackageJsonPath = Join-Path $nextPackageRoot "package.json"
$nextCliPath = Join-Path $nextPackageRoot "dist\bin\next"

if (-not (Test-Path -LiteralPath $buildIdPath -PathType Leaf)) {
    throw "Next.js BUILD_ID was not found: $buildIdPath. Build the app before packaging so runtime evidence can identify the deployed build."
}
if ($RequirePublicDirectory -and -not (Test-Path -LiteralPath $publicRoot -PathType Container)) {
    throw "RequirePublicDirectory was set, but public directory was not found: $publicRoot"
}
if ($modeNormalized -eq "standalone") {
    if (-not (Test-Path -LiteralPath $standaloneServer -PathType Leaf)) {
        throw "Next.js standalone server was not found: $standaloneServer. Build with output: 'standalone' before packaging."
    }
    if (-not (Test-Path -LiteralPath $staticRoot -PathType Container)) {
        throw "Next.js static assets were not found: $staticRoot"
    }
    if (-not (Test-Path -LiteralPath $standaloneNextPackageJsonPath -PathType Leaf)) {
        throw "Next.js standalone package metadata was not found: $standaloneNextPackageJsonPath. Build with output: 'standalone' before packaging so runtime evidence can prove the installed Next.js version."
    }
} else {
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        throw "Next.js next-start package.json was not found: $packageJsonPath"
    }
    if (-not (Test-Path -LiteralPath $nextRoot -PathType Container)) {
        throw "Next.js next-start .next directory was not found: $nextRoot"
    }
    if (-not (Test-Path -LiteralPath $nextPackageRoot -PathType Container)) {
        throw "Next.js next-start node_modules/next directory was not found: $nextPackageRoot. Run a production install before packaging."
    }
    if (-not (Test-Path -LiteralPath $nextPackageJsonPath -PathType Leaf)) {
        throw "Next.js next-start package metadata was not found: $nextPackageJsonPath. Run a production install before packaging so runtime evidence can prove the installed Next.js version."
    }
    if (-not (Test-Path -LiteralPath $nextCliPath -PathType Leaf)) {
        throw "Next.js next-start CLI file was not found: $nextCliPath. Run a production install before packaging."
    }
}

$projectName = Split-Path -Leaf $projectRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "release\$projectName-nextjs-$modeNormalized.zip"
}
if ([string]::IsNullOrWhiteSpace($StageDirectory)) {
    $StageDirectory = Join-Path $projectRoot ".tmp\nextjs-$modeNormalized-package"
}

$zipPath = Resolve-FullPath $OutputPath
$stageRoot = Resolve-FullPath $StageDirectory

if ($PSCmdlet.ShouldProcess($stageRoot, "Stage Next.js standalone package")) {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

    if ($modeNormalized -eq "standalone") {
        Copy-DirectoryContents -Source $standaloneRoot -Destination $stageRoot

        $stageNextDir = Join-Path $stageRoot ".next"
        $stageStatic = Join-Path $stageNextDir "static"
        if (Test-Path -LiteralPath $stageStatic) {
            Remove-Item -LiteralPath $stageStatic -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $stageNextDir | Out-Null
        Copy-Item -LiteralPath $staticRoot -Destination $stageStatic -Recurse -Force
        Copy-Item -LiteralPath $buildIdPath -Destination (Join-Path $stageNextDir "BUILD_ID") -Force
    } else {
        Copy-Item -LiteralPath $packageJsonPath -Destination (Join-Path $stageRoot "package.json") -Force
        Copy-Item -LiteralPath $nextRoot -Destination (Join-Path $stageRoot ".next") -Recurse -Force
        Copy-Item -LiteralPath $nodeModulesRoot -Destination (Join-Path $stageRoot "node_modules") -Recurse -Force
        foreach ($optionalFile in @(
            "next.config.js",
            "next.config.mjs",
            "next.config.cjs",
            "next.config.ts",
            "package-lock.json",
            "npm-shrinkwrap.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            "bun.lock",
            "bun.lockb"
        )) {
            $optionalPath = Join-Path $projectRoot $optionalFile
            if (Test-Path -LiteralPath $optionalPath -PathType Leaf) {
                Copy-Item -LiteralPath $optionalPath -Destination (Join-Path $stageRoot $optionalFile) -Force
            }
        }
    }

    if (-not $NoPublic -and (Test-Path -LiteralPath $publicRoot -PathType Container)) {
        $stagePublic = Join-Path $stageRoot "public"
        if (Test-Path -LiteralPath $stagePublic) {
            Remove-Item -LiteralPath $stagePublic -Recurse -Force
        }
        Copy-Item -LiteralPath $publicRoot -Destination $stagePublic -Recurse -Force
    }

    $stageNextPackageJsonPath = Join-Path $stageRoot "node_modules\next\package.json"
    Write-PackageProvenance `
        -Root $stageRoot `
        -Mode $modeNormalized `
        -NextPackageJsonPath $stageNextPackageJsonPath `
        -BuildIdPath (Join-Path $stageRoot ".next\BUILD_ID")

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
    Assert-ZipContainsExpectedPaths -Path $zipPath -Mode $modeNormalized
    Assert-NextJsPackageValid -Path $zipPath -Mode $modeNormalized
    Write-Host "Next.js $modeNormalized package: $zipPath" -ForegroundColor Green
}

if (-not $KeepStage -and (Test-Path -LiteralPath $stageRoot)) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
