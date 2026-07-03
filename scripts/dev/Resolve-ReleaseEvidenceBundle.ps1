param(
  [string]$ArtifactRoot,
  [string]$BundleFile = "",
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Assert-SafeBundleFileName {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  $name = $Value.Trim()
  if ($name.Length -gt 128) {
    throw "bundle_file must be 128 characters or less."
  }
  if ($name -in @(".", "..")) {
    throw "bundle_file must not be '.' or '..'."
  }
  if ($name -notmatch '^[A-Za-z0-9._-]+$') {
    throw "bundle_file must contain only letters, numbers, dot, underscore, or dash."
  }
  if ($name -notmatch '^[A-Za-z0-9._-]+\.zip$') {
    throw "bundle_file must be a simple .zip filename containing only letters, numbers, dot, underscore, or dash."
  }
}

function Resolve-ReleaseEvidenceBundle {
  param(
    [string]$ArtifactRoot,
    [string]$BundleFile
  )

  if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    throw "ArtifactRoot is required."
  }
  if (-not (Test-Path -LiteralPath $ArtifactRoot -PathType Container)) {
    throw "Downloaded release evidence artifact directory was not found."
  }

  if ([string]::IsNullOrWhiteSpace($BundleFile)) {
    $bundles = @(Get-ChildItem -LiteralPath $ArtifactRoot -Recurse -File -Filter "*.zip" | Sort-Object FullName)
    if ($bundles.Count -ne 1) {
      throw "Expected exactly one release evidence .zip bundle in the downloaded artifact; found $($bundles.Count). Set bundle_file when the artifact contains more than one zip."
    }
    return $bundles[0].FullName
  }

  Assert-SafeBundleFileName -Value $BundleFile
  $bundlePath = Join-Path $ArtifactRoot $BundleFile.Trim()
  if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    throw "Requested bundle_file was not found in the downloaded artifact."
  }

  return (Get-Item -LiteralPath $bundlePath).FullName
}

function Invoke-ExpectResolveFailure {
  param(
    [string]$Name,
    [string]$ExpectedMessage,
    [scriptblock]$Action
  )

  $failed = $false
  try {
    & $Action
  }
  catch {
    $failed = $true
    if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
      throw "$Name failed with unexpected message: $($_.Exception.Message)"
    }
  }
  if (-not $failed) {
    throw "$Name succeeded unexpectedly."
  }
}

function Invoke-SelfTest {
  Write-Host ""
  Write-Host "==> Release evidence bundle resolver"

  $selfTestRoot = Join-Path $RepoRoot ".tmp\release-evidence-bundle-resolver-selftest-$([guid]::NewGuid().ToString('N'))"
  $artifactRoot = Join-Path $selfTestRoot "artifact"
  $nestedRoot = Join-Path $artifactRoot "nested"
  New-Item -ItemType Directory -Force -Path $nestedRoot | Out-Null
  $nestedBundle = Join-Path $nestedRoot "support-evidence.zip"
  Set-Content -LiteralPath $nestedBundle -Value "zip fixture" -Encoding UTF8

  $resolved = Resolve-ReleaseEvidenceBundle -ArtifactRoot $artifactRoot -BundleFile ""
  if ($resolved -ne (Get-Item -LiteralPath $nestedBundle).FullName) {
    throw "Release evidence bundle resolver self-test failed: automatic bundle resolution returned the wrong path."
  }

  $directRoot = Join-Path $selfTestRoot "direct"
  New-Item -ItemType Directory -Force -Path $directRoot | Out-Null
  $directBundle = Join-Path $directRoot "named-evidence.zip"
  Set-Content -LiteralPath $directBundle -Value "zip fixture" -Encoding UTF8
  $resolvedNamed = Resolve-ReleaseEvidenceBundle -ArtifactRoot $directRoot -BundleFile "named-evidence.zip"
  if ($resolvedNamed -ne (Get-Item -LiteralPath $directBundle).FullName) {
    throw "Release evidence bundle resolver self-test failed: named bundle resolution returned the wrong path."
  }

  $emptyRoot = Join-Path $selfTestRoot "empty"
  New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
  Invoke-ExpectResolveFailure -Name "no bundle" -ExpectedMessage "Expected exactly one release evidence .zip bundle" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $emptyRoot -BundleFile ""
  }

  $multipleRoot = Join-Path $selfTestRoot "multiple"
  New-Item -ItemType Directory -Force -Path $multipleRoot | Out-Null
  Set-Content -LiteralPath (Join-Path $multipleRoot "one.zip") -Value "zip fixture" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $multipleRoot "two.zip") -Value "zip fixture" -Encoding UTF8
  Invoke-ExpectResolveFailure -Name "multiple bundles" -ExpectedMessage "Expected exactly one release evidence .zip bundle" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $multipleRoot -BundleFile ""
  }

  Invoke-ExpectResolveFailure -Name "missing named bundle" -ExpectedMessage "Requested bundle_file was not found" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $directRoot -BundleFile "missing.zip"
  }
  Invoke-ExpectResolveFailure -Name "path bundle file" -ExpectedMessage "bundle_file must contain only letters" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $directRoot -BundleFile "nested/support-evidence.zip"
  }
  Invoke-ExpectResolveFailure -Name "non-zip bundle file" -ExpectedMessage "bundle_file must be a simple .zip filename" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $directRoot -BundleFile "support-evidence.7z"
  }
  Invoke-ExpectResolveFailure -Name "dot bundle file" -ExpectedMessage "bundle_file must not be '.' or '..'" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot $directRoot -BundleFile "."
  }
  Invoke-ExpectResolveFailure -Name "missing artifact root" -ExpectedMessage "Downloaded release evidence artifact directory was not found" -Action {
    Resolve-ReleaseEvidenceBundle -ArtifactRoot (Join-Path $selfTestRoot "missing-root") -BundleFile ""
  }

  if (-not $Quiet) {
    Write-Host "Release evidence bundle resolver OK"
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

$resolvedBundle = Resolve-ReleaseEvidenceBundle -ArtifactRoot $ArtifactRoot -BundleFile $BundleFile
if (-not $Quiet) {
  Write-Host "Release evidence bundle: $resolvedBundle"
}
$resolvedBundle
