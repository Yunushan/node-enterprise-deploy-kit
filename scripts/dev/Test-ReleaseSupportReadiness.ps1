param(
  [string]$BundlePath = "",
  [string]$MatrixPath = "",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$AllowWarnings,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [ValidateSet("Table", "Json")]
  [string]$Format = "Table",
  [string]$OutputPath = "",
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot "config\support-matrix.example.json"
}
if (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Get-RelativePath {
  param(
    [string]$BasePath,
    [string]$Path
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  if ($pathFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
    return $pathFull.Substring($baseFull.Length).TrimStart('\', '/').Replace("\", "/")
  }
  return $pathFull
}

function Resolve-BundleRoot {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (Test-Path -LiteralPath $fullPath -PathType Container) {
    return [pscustomobject]@{
      Root = $fullPath
      Cleanup = $false
    }
  }
  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne ".zip") {
      throw "BundlePath file must be a .zip bundle: $fullPath"
    }
    $extractRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-bundle-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $fullPath -DestinationPath $extractRoot -Force
    return [pscustomobject]@{
      Root = $extractRoot
      Cleanup = $true
    }
  }
  throw "BundlePath not found: $fullPath"
}

function Get-BundleManifestRoot {
  param([string]$Root)

  $manifestPath = Join-Path $Root "support-evidence-manifest.json"
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    return $Root
  }

  $nested = @(Get-ChildItem -Path $Root -Recurse -File -Filter "support-evidence-manifest.json")
  if ($nested.Count -eq 1) {
    return (Split-Path -Parent $nested[0].FullName)
  }

  throw "support-evidence-manifest.json was not found at the bundle root."
}

if ($SelfTest) {
  Write-Step "Release support readiness self-test setup"
  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-support-readiness-selftest-$([Guid]::NewGuid().ToString('N'))"
  $coverageJson = Join-Path $selfTestRoot "coverage.json"
  New-Item -ItemType Directory -Force -Path $selfTestRoot | Out-Null

  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") -SelfTest -Format Json -OutputPath $coverageJson | Out-Null
  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  $evidencePath = [string]$coverage.evidencePath

  $bundleOutput = Join-Path $selfTestRoot "bundles"
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") `
    -EvidencePath $evidencePath `
    -OutputDirectory $bundleOutput `
    -BundleName "selftest-release-support-readiness" `
    -ValidateSupportClaim `
    -RequireBothNextJsModes `
    -RequireDeclaredServiceManagers `
    -RequireDeclaredReverseProxies `
    -RequireCoverageComplete `
    -IncludeServiceOnly `
    -IncludeFallback `
    -AllowReverseProxyNone | Out-Null

  $BundlePath = Join-Path $bundleOutput "selftest-release-support-readiness.zip"
  $MaxEvidenceAgeDays = 30
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  throw "BundlePath is required unless -SelfTest is used."
}
if (-not [System.IO.Path]::IsPathRooted($BundlePath)) {
  $BundlePath = Join-Path (Get-Location) $BundlePath
}

Write-Step "Release support readiness"

& (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -BundlePath $BundlePath | Out-Null

$resolved = Resolve-BundleRoot -Path $BundlePath
try {
  $bundleRoot = Get-BundleManifestRoot -Root $resolved.Root
  $manifestPath = Join-Path $bundleRoot "support-evidence-manifest.json"
  $evidencePath = Join-Path $bundleRoot "evidence"
  if (-not (Test-Path -LiteralPath $evidencePath -PathType Container)) {
    throw "Bundle evidence directory not found: $evidencePath"
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

  $claimArgs = @{
    EvidencePath = $evidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    RequireBothNextJsModes = $true
    RequireDeclaredServiceManagers = $true
    RequireDeclaredReverseProxies = $true
  }
  if ($AllowWarnings) {
    $claimArgs.AllowWarnings = $true
  }
  if ($IncludeServiceOnly) {
    $claimArgs.AllowReverseProxyNone = $true
  }
  & (Join-Path $ScriptDir "Test-SupportClaim.ps1") @claimArgs | Out-Null

  $coverageJson = Join-Path $RepoRoot ".tmp\release-support-readiness-coverage-$([Guid]::NewGuid().ToString('N')).json"
  $coverageArgs = @{
    EvidencePath = $evidencePath
    MatrixPath = $MatrixPath
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    Format = "Json"
    OutputPath = $coverageJson
  }
  if ($AllowWarnings) {
    $coverageArgs.AllowWarnings = $true
  }
  if ($IncludeServiceOnly) {
    $coverageArgs.IncludeServiceOnly = $true
  }
  if ($IncludeFallback) {
    $coverageArgs.IncludeFallback = $true
  }
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") @coverageArgs | Out-Null
  $coverage = Get-Content -LiteralPath $coverageJson -Raw | ConvertFrom-Json
  Remove-Item -LiteralPath $coverageJson -Force -ErrorAction SilentlyContinue

  $result = [pscustomobject]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ready = $true
    bundlePath = Get-RelativePath -BasePath $RepoRoot -Path $BundlePath
    matrixPath = Get-RelativePath -BasePath $RepoRoot -Path $MatrixPath
    maxEvidenceAgeDays = $MaxEvidenceAgeDays
    allowWarnings = [bool]$AllowWarnings
    strictSupportClaim = [pscustomobject]@{
      requireBothNextJsModes = $true
      requireDeclaredServiceManagers = $true
      requireDeclaredReverseProxies = $true
    }
    coverage = [pscustomobject]@{
      includeServiceOnly = [bool]$IncludeServiceOnly
      includeFallback = [bool]$IncludeFallback
      expectedCount = [int]$coverage.summary.expectedCount
      coveredCount = [int]$coverage.summary.coveredCount
      missingCount = [int]$coverage.summary.missingCount
    }
    bundle = [pscustomobject]@{
      evidenceFileCount = [int]$manifest.summary.evidenceFileCount
      targets = @($manifest.summary.targets)
      nextJsModes = @($manifest.summary.nextJsModes)
      serviceManagers = @($manifest.summary.serviceManagers)
      reverseProxies = @($manifest.summary.reverseProxies)
      collectors = @($manifest.summary.collectors)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
      $OutputPath = Join-Path (Get-Location) $OutputPath
    }
    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory) {
      New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
  }

  switch ($Format) {
    "Json" {
      $content = $result | ConvertTo-Json -Depth 8
      if ($OutputPath) { $content | Set-Content -Path $OutputPath -Encoding UTF8 } else { $content }
    }
    "Table" {
      if ($OutputPath) {
        ($result | ConvertTo-Json -Depth 8) | Set-Content -Path $OutputPath -Encoding UTF8
      }
      Write-Host "Ready: $($result.ready)"
      Write-Host "Bundle evidence files: $($result.bundle.evidenceFileCount)"
      Write-Host "Coverage expected: $($result.coverage.expectedCount)"
      Write-Host "Coverage covered:  $($result.coverage.coveredCount)"
      Write-Host "Coverage missing:  $($result.coverage.missingCount)"
      Write-Host "Targets: $(@($result.bundle.targets) -join ', ')"
    }
  }
}
finally {
  if ($resolved.Cleanup -and (Test-Path -LiteralPath $resolved.Root)) {
    Remove-Item -LiteralPath $resolved.Root -Recurse -Force -ErrorAction SilentlyContinue
  }
}
