param(
  [string]$BundlePath = "",
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Normalize-ReverseProxy {
  param([string]$Value)
  $normalized = Normalize-Token $Value
  if ($normalized -eq "httpd") { return "apache" }
  return $normalized
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    foreach ($property in $Object.PSObject.Properties) {
      if ($property.Name -ieq $name) {
        return $property.Value
      }
    }
  }
  return $null
}

function Get-StringValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value) { return "" }
  if ($value -is [DateTime]) { return $value.ToUniversalTime().ToString("o") }
  return [string]$value
}

function Get-IntegerValue {
  param(
    [object]$Object,
    [string[]]$Names
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
  try {
    return [int]$value
  } catch {
    return $null
  }
}

function Get-BooleanValue {
  param(
    [object]$Object,
    [string[]]$Names,
    $Default = $null
  )

  $value = Get-PropertyValue -Object $Object -Names $Names
  if ($null -eq $value) { return $Default }
  if ($value -is [bool]) { return [bool]$value }
  $text = ([string]$value).Trim().ToLowerInvariant()
  if ($text -in @("true", "1", "yes")) { return $true }
  if ($text -in @("false", "0", "no")) { return $false }
  return $Default
}

function Get-SupportTargetId {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $target = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $target) {
    $target = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }
  return Normalize-Token $target
}

function Get-NextJsMode {
  param([object]$Evidence)

  $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $mode = Get-StringValue -Object $nextJs -Names @("Mode", "mode")
  if (-not $mode) {
    $mode = Get-StringValue -Object $platform -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }
  if (-not $mode) {
    $mode = Get-StringValue -Object $Evidence -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }
  return Normalize-Token $mode
}

function Get-ServiceManager {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }
  return Normalize-Token $serviceManager
}

function Get-ReverseProxyMode {
  param([object]$Evidence)

  $reverseProxy = Get-PropertyValue -Object $Evidence -Names @("ReverseProxy", "reverseProxy")
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $mode = Get-StringValue -Object $reverseProxy -Names @("Mode", "mode")
  if (-not $mode) {
    $mode = Get-StringValue -Object $platform -Names @("ReverseProxy", "reverseProxy")
  }
  if (-not $mode) {
    $mode = Get-StringValue -Object $Evidence -Names @("ReverseProxy", "reverseProxy")
  }
  return Normalize-ReverseProxy $mode
}

function Get-DeploymentIdentityValue {
  param(
    [object]$Evidence,
    [string[]]$Names
  )

  $identity = Get-PropertyValue -Object $Evidence -Names @("DeploymentIdentity", "deploymentIdentity")
  return Get-StringValue -Object $identity -Names $Names
}

function Get-EvidenceCollectionEvidence {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  return [pscustomobject]@{
    Source = Get-StringValue -Object $collection -Names @("Source", "source")
    Collector = Get-StringValue -Object $collection -Names @("Collector", "collector")
    CollectorVersion = Get-IntegerValue -Object $collection -Names @("CollectorVersion", "collectorVersion")
    LiveHost = Get-BooleanValue -Object $collection -Names @("LiveHost", "liveHost", "CapturedFromLiveHost", "capturedFromLiveHost") -Default $null
    Synthetic = Get-BooleanValue -Object $collection -Names @("Synthetic", "synthetic") -Default $null
    Mock = Get-BooleanValue -Object $collection -Names @("Mock", "mock") -Default $null
    Sample = Get-BooleanValue -Object $collection -Names @("Sample", "sample") -Default $null
  }
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
  return [System.IO.Path]::GetFileName($Path)
}

function Test-RelativeBundlePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
  $normalized = $Path.Replace("\", "/")
  if ($normalized -match '(^|/)\.\.(/|$)') { return $false }
  if (-not $normalized.StartsWith("evidence/")) { return $false }
  return $true
}

function Get-UniqueValues {
  param(
    [object[]]$Rows,
    [string]$PropertyName
  )

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($row in $Rows) {
    $value = [string]$row.$PropertyName
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $values.Add($value) | Out-Null
    }
  }
  return @($values | Sort-Object -Unique)
}

function Assert-ArrayEqual {
  param(
    [string[]]$Actual,
    [string[]]$Expected,
    [string]$Name
  )

  $actualJoined = @($Actual | Sort-Object) -join ","
  $expectedJoined = @($Expected | Sort-Object) -join ","
  if ($actualJoined -ne $expectedJoined) {
    throw "$Name summary mismatch. Expected '$expectedJoined', got '$actualJoined'."
  }
}

function Invoke-ExpectBundleFailure {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )

  $failed = $false
  try {
    & $Action
  } catch {
    $failed = $true
    if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
      throw "Expected bundle verification failure containing '$ExpectedMessage', got: $($_.Exception.Message)"
    }
  }

  if (-not $failed) {
    throw "Expected bundle verification failure containing '$ExpectedMessage', but verification succeeded."
  }
}

function Copy-BundleDirectory {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function ConvertTo-UtcDateValue {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }
  if ($Value -is [DateTime]) {
    return $Value.ToUniversalTime()
  }
  try {
    return ([DateTime]::Parse([string]$Value).ToUniversalTime())
  } catch {
    return $null
  }
}

function Test-DateValueEqual {
  param(
    [object]$Actual,
    [object]$Expected
  )

  $actualDate = ConvertTo-UtcDateValue $Actual
  $expectedDate = ConvertTo-UtcDateValue $Expected
  if ($null -eq $actualDate -or $null -eq $expectedDate) {
    return ([string]$Actual -eq [string]$Expected)
  }
  return ($actualDate -eq $expectedDate)
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
    $extractRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-verify-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $fullPath -DestinationPath $extractRoot -Force
    return [pscustomobject]@{
      Root = $extractRoot
      Cleanup = $true
    }
  }
  throw "BundlePath not found: $fullPath"
}

function Test-Bundle {
  param([string]$Path)

  $resolved = Resolve-BundleRoot -Path $Path
  try {
    $bundleRoot = $resolved.Root
    $manifestPath = Join-Path $bundleRoot "support-evidence-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      $nestedManifests = @(Get-ChildItem -Path $bundleRoot -Recurse -File -Filter "support-evidence-manifest.json")
      if ($nestedManifests.Count -eq 1) {
        $bundleRoot = Split-Path -Parent $nestedManifests[0].FullName
        $manifestPath = $nestedManifests[0].FullName
      } else {
        throw "support-evidence-manifest.json was not found at the bundle root."
      }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) {
      throw "support-evidence-manifest.json schemaVersion must be 1."
    }

    $manifestRows = @($manifest.files)
    if ($manifestRows.Count -eq 0) {
      throw "support-evidence-manifest.json must list at least one evidence file."
    }
    if ([int]$manifest.summary.evidenceFileCount -ne $manifestRows.Count) {
      throw "Manifest summary evidenceFileCount does not match files count."
    }

    $listedPaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($row in $manifestRows) {
      $relative = ([string]$row.path).Replace("\", "/")
      if (-not (Test-RelativeBundlePath -Path $relative)) {
        throw "Manifest contains unsafe or invalid evidence path: $relative"
      }
      if (-not $listedPaths.Add($relative)) {
        throw "Manifest contains duplicate evidence path: $relative"
      }

      $filePath = Join-Path $bundleRoot ($relative -replace '/', '\')
      if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Manifest evidence file is missing: $relative"
      }

      $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -ne ([string]$row.sha256).ToLowerInvariant()) {
        throw "SHA256 mismatch for $relative."
      }
      $actualBytes = (Get-Item -LiteralPath $filePath).Length
      if ([int64]$row.bytes -ne $actualBytes) {
        throw "Byte size mismatch for $relative."
      }

      $evidence = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
      if ([string]$row.parseError) {
        throw "Manifest parseError must be empty for validated evidence: $relative"
      }
      if ([string]$row.supportTargetId -ne (Get-SupportTargetId -Evidence $evidence)) {
        throw "supportTargetId manifest mismatch for $relative."
      }
      if ([string]$row.nextJsMode -ne (Get-NextJsMode -Evidence $evidence)) {
        throw "nextJsMode manifest mismatch for $relative."
      }
      if ([string]$row.serviceManager -ne (Get-ServiceManager -Evidence $evidence)) {
        throw "serviceManager manifest mismatch for $relative."
      }
      if ([string]$row.reverseProxy -ne (Get-ReverseProxyMode -Evidence $evidence)) {
        throw "reverseProxy manifest mismatch for $relative."
      }
      $evidenceGeneratedAt = Get-StringValue -Object $evidence -Names @("GeneratedAtUtc", "generatedAtUtc")
      if (-not (Test-DateValueEqual -Actual $row.generatedAtUtc -Expected $evidenceGeneratedAt)) {
        throw "generatedAtUtc manifest mismatch for $relative."
      }
      if ([string]$row.verdict -ne (Get-StringValue -Object $evidence -Names @("Verdict", "verdict"))) {
        throw "verdict manifest mismatch for $relative."
      }
      $critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
      $warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
      if ($null -ne $critical -and [int]$row.critical -ne $critical) {
        throw "critical manifest mismatch for $relative."
      }
      if ($null -ne $warnings -and [int]$row.warnings -ne $warnings) {
        throw "warnings manifest mismatch for $relative."
      }
      if ([string]$row.deploymentId -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("DeploymentId", "deploymentId"))) {
        throw "deploymentId manifest mismatch for $relative."
      }
      if ([string]$row.nextBuildId -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("NextBuildId", "nextBuildId"))) {
        throw "nextBuildId manifest mismatch for $relative."
      }
      if ([string]$row.packageSha256 -ne (Get-DeploymentIdentityValue -Evidence $evidence -Names @("PackageSha256", "packageSha256"))) {
        throw "packageSha256 manifest mismatch for $relative."
      }
      $collection = Get-EvidenceCollectionEvidence -Evidence $evidence
      if ([string]$row.collectorSource -ne $collection.Source) {
        throw "collectorSource manifest mismatch for $relative."
      }
      if ([string]$row.collector -ne $collection.Collector) {
        throw "collector manifest mismatch for $relative."
      }
      $collectorVersion = Get-IntegerValue -Object $row -Names @("collectorVersion")
      if ($null -eq $collectorVersion -or $collectorVersion -ne $collection.CollectorVersion) {
        throw "collectorVersion manifest mismatch for $relative."
      }
      $liveHost = Get-BooleanValue -Object $row -Names @("liveHost") -Default $null
      if ($liveHost -ne $collection.LiveHost) {
        throw "liveHost manifest mismatch for $relative."
      }
      if ($liveHost -ne $true) {
        throw "Bundle evidence does not prove live-host collection for $relative."
      }
      $synthetic = Get-BooleanValue -Object $row -Names @("synthetic") -Default $null
      if ($synthetic -ne $collection.Synthetic) {
        throw "synthetic manifest mismatch for $relative."
      }
      if ($synthetic -ne $false) {
        throw "Bundle evidence declares synthetic collection for $relative."
      }
      $mock = Get-BooleanValue -Object $row -Names @("mock") -Default $null
      if ($mock -ne $collection.Mock) {
        throw "mock manifest mismatch for $relative."
      }
      if ($mock -ne $false) {
        throw "Bundle evidence declares mock collection for $relative."
      }
      $sample = Get-BooleanValue -Object $row -Names @("sample") -Default $null
      if ($sample -ne $collection.Sample) {
        throw "sample manifest mismatch for $relative."
      }
      if ($sample -ne $false) {
        throw "Bundle evidence declares sample collection for $relative."
      }
    }

    $actualEvidenceFiles = @(Get-ChildItem -Path (Join-Path $bundleRoot "evidence") -Recurse -File -Filter "*.json" | ForEach-Object {
        Get-RelativePath -BasePath $bundleRoot -Path $_.FullName
      })
    $unlistedFiles = @($actualEvidenceFiles | Where-Object { -not $listedPaths.Contains($_) })
    if ($unlistedFiles.Count -gt 0) {
      throw "Bundle contains evidence files not listed in manifest: $($unlistedFiles -join ', ')"
    }

    Assert-ArrayEqual -Actual @($manifest.summary.targets) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "supportTargetId") -Name "targets"
    Assert-ArrayEqual -Actual @($manifest.summary.nextJsModes) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "nextJsMode") -Name "nextJsModes"
    Assert-ArrayEqual -Actual @($manifest.summary.serviceManagers) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "serviceManager") -Name "serviceManagers"
    Assert-ArrayEqual -Actual @($manifest.summary.reverseProxies) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "reverseProxy") -Name "reverseProxies"
    Assert-ArrayEqual -Actual @($manifest.summary.collectors) -Expected (Get-UniqueValues -Rows $manifestRows -PropertyName "collector") -Name "collectors"
  }
  finally {
    if ($resolved.Cleanup -and (Test-Path -LiteralPath $resolved.Root)) {
      Remove-Item -LiteralPath $resolved.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ""
Write-Host "==> Support evidence bundle verification"

if ($SelfTest) {
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") -SelfTest | Out-Null
  $selfTestRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output\selftest-support-evidence"
  $selfTestZip = Join-Path $RepoRoot ".tmp\support-evidence-bundle-selftest-output\selftest-support-evidence.zip"
  Test-Bundle -Path $selfTestRoot
  Test-Bundle -Path $selfTestZip

  $hashTamperRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-hash-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $hashTamperRoot
  Add-Content -LiteralPath (Join-Path $hashTamperRoot "evidence\ubuntu-systemd-nginx.json") -Value " "
  Invoke-ExpectBundleFailure -ExpectedMessage "SHA256 mismatch" -Action {
    Test-Bundle -Path $hashTamperRoot
  }

  $unlistedRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-unlisted-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $unlistedRoot
  Copy-Item -LiteralPath (Join-Path $unlistedRoot "evidence\ubuntu-systemd-nginx.json") -Destination (Join-Path $unlistedRoot "evidence\unlisted-copy.json") -Force
  Invoke-ExpectBundleFailure -ExpectedMessage "not listed in manifest" -Action {
    Test-Bundle -Path $unlistedRoot
  }

  Write-Host "Support evidence bundle verification OK"
  return
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  throw "BundlePath is required unless -SelfTest is used."
}
Test-Bundle -Path $BundlePath
Write-Host "Support evidence bundle verification OK"
