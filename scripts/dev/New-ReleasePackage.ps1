<#
.SYNOPSIS
  Build a sanitized source release zip for this deployment kit.
.DESCRIPTION
  Packages tracked repository files into .tmp/release while blocking private
  deployment configs, secrets, generated output, logs, and external binaries.
.EXAMPLE
  .\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Version = "dev",
  [string]$OutputDirectory = ".tmp/release",
  [string]$PackageName = "node-enterprise-deploy-kit",
  [switch]$NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Get-RelativePath {
  param([string]$Path)
  return $Path.Substring($RepoRoot.Length + 1).Replace("\", "/")
}

function Get-ReleaseFiles {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    Push-Location $RepoRoot
    try {
      $files = @(& $git.Source ls-files --cached --others --exclude-standard)
      if ($LASTEXITCODE -eq 0 -and $files.Count -gt 0) {
        return @($files | ForEach-Object { $_ -replace "\\", "/" })
      }
    }
    finally {
      Pop-Location
    }
  }

  return @(Get-ChildItem -Path $RepoRoot -Recurse -File |
    Where-Object { $_.FullName -notmatch "\\\.git\\" } |
    ForEach-Object { Get-RelativePath $_.FullName })
}

function Test-BlockedReleasePath {
  param([string]$Path)

  $normalized = $Path -replace "\\", "/"
  if ($normalized -match '(^|/)(node_modules|\.next|dist|build|coverage|logs|\.tmp)/') { return $true }
  if ($normalized -in @("config/windows/app.config.json", "config/linux/app.env", ".env")) { return $true }
  if ($normalized -like ".env.*" -and $normalized -ne ".env.example") { return $true }
  if ($normalized -match '\.(key|pem|pfx|p12|crt|csr)$') { return $true }
  if ($normalized -match '^tools/(winsw|nssm)/.+\.exe$') { return $true }
  if ($normalized -match '\.(log|out|err)$') { return $true }
  return $false
}

function Copy-ReleaseFile {
  param(
    [string]$RelativePath,
    [string]$StageRoot
  )

  $source = Join-Path $RepoRoot ($RelativePath -replace "/", "\")
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Release source file not found: $RelativePath"
  }

  $destination = Join-Path $StageRoot ($RelativePath -replace "/", "\")
  $destinationDirectory = Split-Path -Parent $destination
  New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

& (Join-Path $ScriptDir "Test-ReleasePackage.ps1")

$safeVersion = $Version -replace '[^A-Za-z0-9._-]', '-'
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $RepoRoot $OutputDirectory }
$stageRoot = Join-Path $outputRoot "stage\$PackageName"
$zipPath = Join-Path $outputRoot "$PackageName-$safeVersion.zip"
$manifestPath = Join-Path $outputRoot "$PackageName-$safeVersion.manifest.txt"

if ($PSCmdlet.ShouldProcess($outputRoot, "Create sanitized release package staging directory")) {
  if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
}

$releaseFiles = @(Get-ReleaseFiles | Where-Object { -not (Test-BlockedReleasePath $_) } | Sort-Object)
foreach ($file in $releaseFiles) {
  if ($PSCmdlet.ShouldProcess($file, "Stage release file")) {
    Copy-ReleaseFile -RelativePath $file -StageRoot $stageRoot
  }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$releaseFiles | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Release manifest: $manifestPath"

if (-not $NoZip) {
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  if ($PSCmdlet.ShouldProcess($zipPath, "Create release zip")) {
    Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -Force
    Write-Host "Release package: $zipPath" -ForegroundColor Green
  }
} else {
  Write-Host "Release staging directory: $stageRoot" -ForegroundColor Green
}
