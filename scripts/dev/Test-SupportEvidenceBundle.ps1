param(
  [string]$BundlePath = "",
  [string]$MatrixPath = "",
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

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Get-MatrixTargetsById {
  param([string]$Path)

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $targetsById = @{}
  foreach ($target in @(Get-ArrayValue $matrix.targets)) {
    $targetId = Normalize-Token ([string]$target.id)
    if ($targetId) {
      $targetsById[$targetId] = $target
    }
  }
  return $targetsById
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

function Add-PlatformTarget {
  param(
    [System.Collections.Generic.HashSet[string]]$Targets,
    [string]$Value
  )

  $normalized = Normalize-Token $Value
  if (-not $normalized) { return }

  [void]$Targets.Add($normalized)
  switch ($normalized) {
    "darwin" { [void]$Targets.Add("macos") }
    "mac-os" { [void]$Targets.Add("macos") }
    "linuxmint" { [void]$Targets.Add("linux-mint") }
    "ol" { [void]$Targets.Add("oracle-linux") }
    "redhat" { [void]$Targets.Add("rhel") }
    "red-hat" { [void]$Targets.Add("rhel") }
    "freebsd" { [void]$Targets.Add("bsd") }
    "openbsd" { [void]$Targets.Add("bsd") }
    "netbsd" { [void]$Targets.Add("bsd") }
  }
}

function Get-PlatformEvidenceTargets {
  param([object]$Evidence)

  $targets = New-Object System.Collections.Generic.HashSet[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $family = Get-StringValue -Object $platform -Names @("Family", "family")
  $osCaption = Get-StringValue -Object $platform -Names @("OsCaption", "osCaption")
  $osId = Get-StringValue -Object $platform -Names @("OsId", "osId")
  $osIdLike = Get-StringValue -Object $platform -Names @("OsIdLike", "osIdLike")
  $kernelName = Get-StringValue -Object $platform -Names @("KernelName", "kernelName")
  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")

  Add-PlatformTarget -Targets $targets -Value $family
  Add-PlatformTarget -Targets $targets -Value $osId
  Add-PlatformTarget -Targets $targets -Value $kernelName
  foreach ($part in @($osIdLike -split '\s+')) {
    Add-PlatformTarget -Targets $targets -Value $part
  }

  if ($osCaption -match 'Windows') {
    Add-PlatformTarget -Targets $targets -Value "windows"
  }
  if ($osCaption -match 'Windows Server') {
    Add-PlatformTarget -Targets $targets -Value "windows-server"
    if ($osCaption -match '2012\s+R2') {
      Add-PlatformTarget -Targets $targets -Value "windows-server-2012-r2"
    } else {
      foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
        if ($osCaption -match $year) {
          Add-PlatformTarget -Targets $targets -Value "windows-server-$year"
        }
      }
    }
  } else {
    if ($osCaption -match 'Windows\s+10') { Add-PlatformTarget -Targets $targets -Value "windows-10" }
    if ($osCaption -match 'Windows\s+11') { Add-PlatformTarget -Targets $targets -Value "windows-11" }
  }

  if ($prettyName -match 'CentOS Stream') { Add-PlatformTarget -Targets $targets -Value "centos-stream" }
  if ($prettyName -match 'Red Hat Enterprise Linux') { Add-PlatformTarget -Targets $targets -Value "rhel" }
  if ($prettyName -match 'Oracle Linux') { Add-PlatformTarget -Targets $targets -Value "oracle-linux" }
  if ($prettyName -match 'Rocky Linux') { Add-PlatformTarget -Targets $targets -Value "rocky" }
  if ($prettyName -match 'AlmaLinux') { Add-PlatformTarget -Targets $targets -Value "almalinux" }
  if ($prettyName -match 'Linux Mint') { Add-PlatformTarget -Targets $targets -Value "linux-mint" }

  if ($targets.Contains("ubuntu") -or $targets.Contains("debian") -or $targets.Contains("rhel") -or $targets.Contains("fedora") -or $targets.Contains("alpine") -or $targets.Contains("oracle-linux") -or $targets.Contains("centos") -or $targets.Contains("centos-stream") -or $targets.Contains("rocky") -or $targets.Contains("almalinux") -or $targets.Contains("linux-mint")) {
    [void]$targets.Add("linux")
  }
  if ($targets.Contains("windows-server")) {
    [void]$targets.Add("windows")
  }

  return @($targets | Sort-Object)
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

function Get-NextJsRuntimeValue {
  param(
    [object]$Evidence,
    [string[]]$Names
  )

  $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
  return Get-StringValue -Object $nextJs -Names $Names
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
  $ci = Get-PropertyValue -Object $collection -Names @("Ci", "ci")
  $workflowDispatch = Get-PropertyValue -Object $collection -Names @("WorkflowDispatch", "workflowDispatch")
  return [pscustomobject]@{
    Source = Get-StringValue -Object $collection -Names @("Source", "source")
    Collector = Get-StringValue -Object $collection -Names @("Collector", "collector")
    CollectorVersion = Get-IntegerValue -Object $collection -Names @("CollectorVersion", "collectorVersion")
    CollectorSha256 = (Get-StringValue -Object $collection -Names @("CollectorSha256", "collectorSha256")).Trim().ToLowerInvariant()
    LiveHost = Get-BooleanValue -Object $collection -Names @("LiveHost", "liveHost", "CapturedFromLiveHost", "capturedFromLiveHost") -Default $null
    Synthetic = Get-BooleanValue -Object $collection -Names @("Synthetic", "synthetic") -Default $null
    Mock = Get-BooleanValue -Object $collection -Names @("Mock", "mock") -Default $null
    Sample = Get-BooleanValue -Object $collection -Names @("Sample", "sample") -Default $null
    Ci = [pscustomobject]@{
      IsCi = Get-BooleanValue -Object $ci -Names @("IsCi", "isCi") -Default $null
      Provider = Get-StringValue -Object $ci -Names @("Provider", "provider")
      WorkflowName = Get-StringValue -Object $ci -Names @("WorkflowName", "workflowName")
      RunId = Get-StringValue -Object $ci -Names @("RunId", "runId")
      RunAttempt = Get-StringValue -Object $ci -Names @("RunAttempt", "runAttempt")
      EventName = Get-StringValue -Object $ci -Names @("EventName", "eventName")
      RefName = Get-StringValue -Object $ci -Names @("RefName", "refName")
      Sha = Get-StringValue -Object $ci -Names @("Sha", "sha")
    }
    WorkflowDispatch = [pscustomobject]@{
      SupportMatrixPath = (Get-StringValue -Object $workflowDispatch -Names @("SupportMatrixPath", "supportMatrixPath", "matrixPath", "matrix_path")).Trim().Replace("\", "/")
      SupportMatrixSha256 = (Get-StringValue -Object $workflowDispatch -Names @("SupportMatrixSha256", "supportMatrixSha256", "matrixSha256", "matrix_sha256")).Trim().ToLowerInvariant()
    }
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

function Test-Sha256Text {
  param([string]$Value)
  return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Fa-f0-9]{64}$')
}

function ConvertTo-RepoRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  $pathText = $Path.Trim()
  $normalizedInput = $pathText.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  if ([System.IO.Path]::IsPathRooted($normalizedInput)) {
    $fullPath = [System.IO.Path]::GetFullPath($normalizedInput)
    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "MatrixPath override must resolve inside the repository workspace."
    }
    return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
  }

  return $pathText.Replace("\", "/")
}

function Assert-SafeRelativeJsonPath {
  param(
    [string]$Value,
    [string]$DisplayName
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$DisplayName is required and must be a relative .json path inside the repository workspace."
  }

  $pathText = $Value.Trim()
  if ($pathText.Length -gt 240) {
    throw "$DisplayName must be 240 characters or less."
  }
  if ($pathText -match '[\x00-\x1F\x7F:*?"<>|]') {
    throw "$DisplayName must not contain control characters, drive letters, wildcards, or shell metacharacters."
  }
  if ($pathText -match '^[A-Za-z]:[\\/]' -or $pathText -match '^[\\/]' -or $pathText -match '^\\\\' -or $pathText -match '^//') {
    throw "$DisplayName must be a relative path inside the repository workspace."
  }

  $normalizedPath = $pathText.Replace('\', '/')
  if ($normalizedPath -match '(^|/)\.\.(/|$)' -or $normalizedPath -match '/{2,}' -or $normalizedPath.EndsWith('/')) {
    throw "$DisplayName must not contain parent traversal, empty path segments, or a trailing slash."
  }
  if ($normalizedPath -notmatch '\.json$') {
    throw "$DisplayName must be a relative .json path inside the repository workspace."
  }
}

function Assert-GitTrackedRepositoryFile {
  param(
    [string]$RelativePath,
    [string]$DisplayName
  )

  $normalizedPath = $RelativePath.Trim().Replace('\', '/')
  $trackedPaths = @(& git -C $RepoRoot ls-files -- $normalizedPath)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify that $DisplayName is tracked by git."
  }

  $trackedMatch = @(
    $trackedPaths | Where-Object {
      [string]::Equals([string]$_, $normalizedPath, [StringComparison]::OrdinalIgnoreCase)
    }
  )
  if ($trackedMatch.Count -eq 0) {
    throw "$DisplayName must reference a tracked repository file."
  }
}

function Resolve-ManifestMatrixPath {
  param(
    [object]$Manifest,
    [string]$OverridePath = ""
  )

  $manifestMatrixPath = ConvertTo-RepoRelativePath (Get-StringValue -Object $Manifest -Names @("matrixPath"))
  Assert-SafeRelativeJsonPath -Value $manifestMatrixPath -DisplayName "support-evidence-manifest.json matrixPath"

  if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
    $overrideMatrixPath = ConvertTo-RepoRelativePath $OverridePath
    Assert-SafeRelativeJsonPath -Value $overrideMatrixPath -DisplayName "MatrixPath"
    if (-not [string]::Equals($overrideMatrixPath, $manifestMatrixPath, [StringComparison]::OrdinalIgnoreCase)) {
      throw "MatrixPath override must match support-evidence-manifest.json matrixPath."
    }
  }

  Assert-GitTrackedRepositoryFile -RelativePath $manifestMatrixPath -DisplayName "support-evidence-manifest.json matrixPath"
  $fullMatrixPath = Join-Path $RepoRoot ($manifestMatrixPath -replace '/', '\')
  if (-not (Test-Path -LiteralPath $fullMatrixPath -PathType Leaf)) {
    throw "Support matrix not found: $manifestMatrixPath"
  }

  return [pscustomobject]@{
    RelativePath = $manifestMatrixPath
    FullPath = $fullMatrixPath
  }
}

function Get-VersionParts {
  param(
    [string]$Value,
    [int]$Count = 2
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $matches = [regex]::Matches($Value, '\d+')
  if ($matches.Count -lt $Count) { return $null }

  $parts = New-Object System.Collections.Generic.List[int]
  for ($index = 0; $index -lt $Count; $index += 1) {
    $parts.Add([int]$matches[$index].Value) | Out-Null
  }
  return @($parts)
}

function Test-VersionAtLeast {
  param(
    [string]$Actual,
    [string]$Minimum,
    [int]$Count = 2
  )

  $actualParts = Get-VersionParts -Value $Actual -Count $Count
  $minimumParts = Get-VersionParts -Value $Minimum -Count $Count
  if ($null -eq $actualParts -or $null -eq $minimumParts) { return $null }

  for ($index = 0; $index -lt $Count; $index += 1) {
    if ($actualParts[$index] -gt $minimumParts[$index]) { return $true }
    if ($actualParts[$index] -lt $minimumParts[$index]) { return $false }
  }
  return $true
}

function Get-NextJsPlatformRuntimeIssues {
  param(
    [object]$Evidence,
    [string]$SupportTargetId,
    [string]$Context
  )

  $issues = New-Object System.Collections.Generic.List[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $target = Normalize-Token $SupportTargetId
  $kernelRelease = Get-StringValue -Object $platform -Names @("KernelRelease", "kernelRelease")
  $machine = Normalize-Token (Get-StringValue -Object $platform -Names @("Machine", "machine", "OsArchitecture", "osArchitecture"))
  $osVersion = Get-StringValue -Object $platform -Names @("OsVersionId", "osVersionId", "OsVersion", "osVersion", "ProductVersion", "productVersion")
  $osBuild = Get-IntegerValue -Object $platform -Names @("OsBuildNumber", "osBuildNumber", "BuildNumber", "buildNumber")
  $libcName = Normalize-Token (Get-StringValue -Object $platform -Names @("LibcName", "libcName"))
  $libcVersion = Get-StringValue -Object $platform -Names @("LibcVersion", "libcVersion")

  $minimumWindowsBuilds = @{
    "windows-10" = 10240
    "windows-11" = 22000
    "windows-server-2012" = 9200
    "windows-server-2012-r2" = 9600
    "windows-server-2016" = 14393
    "windows-server-2019" = 17763
    "windows-server-2022" = 20348
    "windows-server-2025" = 26100
  }
  if ($minimumWindowsBuilds.ContainsKey($target)) {
    $minimumBuild = [int]$minimumWindowsBuilds[$target]
    if ($null -eq $osBuild) {
      $issues.Add("$Context does not prove a Windows build number for the Next.js Node runtime platform floor.") | Out-Null
    } elseif ($osBuild -lt $minimumBuild) {
      $issues.Add("$Context has Windows build $osBuild, below the $target floor of $minimumBuild for Next.js Node runtime platform support.") | Out-Null
    }
  }

  $glibcLinuxTargets = @("ubuntu", "debian", "linux-mint", "rhel", "oracle-linux", "centos", "centos-stream", "rocky", "almalinux", "fedora")
  if ($target -in $glibcLinuxTargets) {
    $kernelOk = Test-VersionAtLeast -Actual $kernelRelease -Minimum "4.18" -Count 2
    if ($null -eq $kernelOk) {
      $issues.Add("$Context does not prove Linux kernel release for the Next.js Node runtime platform floor.") | Out-Null
    } elseif ($kernelOk -ne $true) {
      $issues.Add("$Context has Linux kernel release '$kernelRelease', below the Node.js 20.x floor of 4.18 for Next.js support.") | Out-Null
    }

    if ($libcName -notin @("glibc", "gnu-libc", "gnu-c-library")) {
      $issues.Add("$Context does not prove glibc runtime metadata required for Node.js 20.x Tier 1 Linux support.") | Out-Null
    } else {
      $glibcOk = Test-VersionAtLeast -Actual $libcVersion -Minimum "2.28" -Count 2
      if ($null -eq $glibcOk) {
        $issues.Add("$Context does not prove glibc version for Node.js 20.x Tier 1 Linux support.") | Out-Null
      } elseif ($glibcOk -ne $true) {
        $issues.Add("$Context has glibc version '$libcVersion', below the Node.js 20.x floor of 2.28 for Next.js support.") | Out-Null
      }
    }
  }

  if ($target -eq "macos") {
    if ([string]::IsNullOrWhiteSpace($machine)) {
      $issues.Add("$Context does not prove macOS machine architecture for the Next.js Node runtime platform floor.") | Out-Null
    }
    $minimumMacosVersion = if ($machine -in @("arm64", "aarch64")) { "11.0" } else { "10.15" }
    $macosOk = Test-VersionAtLeast -Actual $osVersion -Minimum $minimumMacosVersion -Count 2
    if ($null -eq $macosOk) {
      $issues.Add("$Context does not prove macOS product version for the Next.js Node runtime platform floor.") | Out-Null
    } elseif ($macosOk -ne $true) {
      $issues.Add("$Context has macOS version '$osVersion', below the Node.js 20.x floor of $minimumMacosVersion for architecture '$machine'.") | Out-Null
    }
  }

  return @($issues)
}

function Assert-CollectionCiProvenance {
  param(
    [object]$Ci,
    [string]$Context
  )

  if ($null -eq $Ci -or $null -eq $Ci.IsCi) { return }

  if ($Ci.Provider -and $Ci.Provider -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$Context collection ci.provider contains unsupported characters."
  }
  if ($Ci.WorkflowName -and $Ci.WorkflowName -notmatch '^[A-Za-z0-9._/-]+$') {
    throw "$Context collection ci.workflowName contains unsupported characters."
  }
  if ($Ci.RunId -and $Ci.RunId -notmatch '^[0-9]+$') {
    throw "$Context collection ci.runId must be numeric when present."
  }
  if ($Ci.RunAttempt -and $Ci.RunAttempt -notmatch '^[0-9]+$') {
    throw "$Context collection ci.runAttempt must be numeric when present."
  }
  if ($Ci.EventName -and $Ci.EventName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "$Context collection ci.eventName contains unsupported characters."
  }
  if ($Ci.RefName -and $Ci.RefName -notmatch '^[A-Za-z0-9._/-]+$') {
    throw "$Context collection ci.refName contains unsupported characters."
  }
  if ($Ci.Sha -and $Ci.Sha -notmatch '^[A-Fa-f0-9]{40}$') {
    throw "$Context collection ci.sha must be a 40-character git SHA when present."
  }
  if ($Ci.IsCi -and -not $Ci.Provider) {
    throw "$Context collection ci.provider is required when ci.isCi is true."
  }
  if ($Ci.IsCi -eq $false -and $Ci.Provider) {
    throw "$Context collection ci.provider must be empty when ci.isCi is false."
  }
  if ($Ci.Provider -eq "github-actions") {
    if (-not $Ci.WorkflowName) {
      throw "$Context collection ci.workflowName is required for github-actions provenance."
    }
    if (-not $Ci.RunId) {
      throw "$Context collection ci.runId is required for github-actions provenance."
    }
    if (-not $Ci.RunAttempt) {
      throw "$Context collection ci.runAttempt is required for github-actions provenance."
    }
    if (-not $Ci.EventName) {
      throw "$Context collection ci.eventName is required for github-actions provenance."
    }
    if (-not $Ci.RefName) {
      throw "$Context collection ci.refName is required for github-actions provenance."
    }
    if (-not $Ci.Sha) {
      throw "$Context collection ci.sha is required for github-actions provenance."
    }
  }
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
  param(
    [string]$Path,
    [string]$MatrixPathOverride = ""
  )

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
    $matrixSha256 = Get-StringValue -Object $manifest -Names @("matrixSha256")
    if (-not (Test-Sha256Text -Value $matrixSha256)) {
      throw "support-evidence-manifest.json matrixSha256 is required and must be a SHA256 hash."
    }
    $matrixReference = Resolve-ManifestMatrixPath -Manifest $manifest -OverridePath $MatrixPathOverride
    $currentMatrixSha256 = (Get-FileHash -LiteralPath $matrixReference.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($matrixSha256.ToLowerInvariant() -ne $currentMatrixSha256) {
      throw "support-evidence-manifest.json matrixSha256 must match support-evidence-manifest.json matrixPath."
    }
    $sourceControl = Get-PropertyValue -Object $manifest -Names @("sourceControl")
    if ($null -eq $sourceControl) {
      throw "support-evidence-manifest.json sourceControl is required."
    }
    $repositoryName = Get-StringValue -Object $sourceControl -Names @("repositoryName")
    if ($repositoryName -notmatch '^[A-Za-z0-9._-]+$') {
      throw "sourceControl.repositoryName must contain only letters, numbers, dot, underscore, or dash."
    }
    $isGitRepository = Get-BooleanValue -Object $sourceControl -Names @("isGitRepository") -Default $null
    if ($null -eq $isGitRepository) {
      throw "sourceControl.isGitRepository must be true or false."
    }
    $trackedDirty = Get-BooleanValue -Object $sourceControl -Names @("trackedDirty") -Default $null
    if ($null -eq $trackedDirty) {
      throw "sourceControl.trackedDirty must be true or false."
    }
    $commitSha = Get-StringValue -Object $sourceControl -Names @("commitSha")
    if ($commitSha -and $commitSha -notmatch '^[A-Fa-f0-9]{40}$') {
      throw "sourceControl.commitSha must be a 40-character git SHA when present."
    }
    if ($isGitRepository -and -not $commitSha) {
      throw "sourceControl.commitSha is required for git repository bundles."
    }
    $branchName = Get-StringValue -Object $sourceControl -Names @("branchName")
    if ($branchName -and $branchName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "sourceControl.branchName contains unsupported characters."
    }
    $ci = Get-PropertyValue -Object $manifest -Names @("ci")
    if ($null -eq $ci) {
      throw "support-evidence-manifest.json ci provenance is required."
    }
    $isCi = Get-BooleanValue -Object $ci -Names @("isCi") -Default $null
    if ($null -eq $isCi) {
      throw "ci.isCi must be true or false."
    }
    $ciProvider = Get-StringValue -Object $ci -Names @("provider")
    if ($ciProvider -and $ciProvider -notmatch '^[A-Za-z0-9._-]+$') {
      throw "ci.provider contains unsupported characters."
    }
    $ciWorkflowName = Get-StringValue -Object $ci -Names @("workflowName")
    if ($ciWorkflowName -and $ciWorkflowName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "ci.workflowName contains unsupported characters."
    }
    $ciRunId = Get-StringValue -Object $ci -Names @("runId")
    if ($ciRunId -and $ciRunId -notmatch '^[0-9]+$') {
      throw "ci.runId must be numeric when present."
    }
    $ciRunAttempt = Get-StringValue -Object $ci -Names @("runAttempt")
    if ($ciRunAttempt -and $ciRunAttempt -notmatch '^[0-9]+$') {
      throw "ci.runAttempt must be numeric when present."
    }
    $ciEventName = Get-StringValue -Object $ci -Names @("eventName")
    if ($ciEventName -and $ciEventName -notmatch '^[A-Za-z0-9._-]+$') {
      throw "ci.eventName contains unsupported characters."
    }
    $ciRefName = Get-StringValue -Object $ci -Names @("refName")
    if ($ciRefName -and $ciRefName -notmatch '^[A-Za-z0-9._/-]+$') {
      throw "ci.refName contains unsupported characters."
    }
    $ciSha = Get-StringValue -Object $ci -Names @("sha")
    if ($ciSha -and $ciSha -notmatch '^[A-Fa-f0-9]{40}$') {
      throw "ci.sha must be a 40-character git SHA when present."
    }
    if ($ciSha -and $commitSha -and $ciSha.ToLowerInvariant() -ne $commitSha.ToLowerInvariant()) {
      throw "ci.sha must match sourceControl.commitSha when both are present."
    }
    if ($isCi -and -not $ciProvider) {
      throw "ci.provider is required when ci.isCi is true."
    }
    if ($isCi -eq $false -and $ciProvider) {
      throw "ci.provider must be empty when ci.isCi is false."
    }
    if ($ciProvider -eq "github-actions") {
      if (-not $ciWorkflowName) {
        throw "ci.workflowName is required for github-actions provenance."
      }
      if (-not $ciRunId) {
        throw "ci.runId is required for github-actions provenance."
      }
      if (-not $ciRunAttempt) {
        throw "ci.runAttempt is required for github-actions provenance."
      }
      if (-not $ciEventName) {
        throw "ci.eventName is required for github-actions provenance."
      }
      if (-not $ciRefName) {
        throw "ci.refName is required for github-actions provenance."
      }
      if (-not $ciSha) {
        throw "ci.sha is required for github-actions provenance."
      }
    }

    $supportClaimValidated = Get-BooleanValue -Object $manifest -Names @("supportClaimValidated") -Default $false
    $requireCollectorSha256 = Get-BooleanValue -Object $manifest -Names @("requireCollectorSha256") -Default $false
    $requireHostEvidenceWorkflowCollection = Get-BooleanValue -Object $manifest -Names @("requireHostEvidenceWorkflowCollection") -Default $false
    $requireMinimumUptimeHours = Get-IntegerValue -Object $manifest -Names @("requireMinimumUptimeHours")
    if ($null -eq $requireMinimumUptimeHours) {
      $requireMinimumUptimeHours = 0
    }
    if ($requireMinimumUptimeHours -lt 0) {
      throw "support-evidence-manifest.json requireMinimumUptimeHours must be zero or a positive integer."
    }
    if ($requireHostEvidenceWorkflowCollection -eq $true -and $supportClaimValidated -ne $true) {
      throw "support-evidence-manifest.json cannot require host-evidence workflow collection unless supportClaimValidated is true."
    }

    $manifestRows = @($manifest.files)
    if ($manifestRows.Count -eq 0) {
      throw "support-evidence-manifest.json must list at least one evidence file."
    }
    if ([int]$manifest.summary.evidenceFileCount -ne $manifestRows.Count) {
      throw "Manifest summary evidenceFileCount does not match files count."
    }

    $matrixTargetsById = Get-MatrixTargetsById -Path $matrixReference.FullPath
    $matrixTargetIds = @($matrixTargetsById.Keys | Sort-Object)
    $supportScope = Get-PropertyValue -Object $manifest -Names @("supportScope")
    if ($null -eq $supportScope) {
      throw "support-evidence-manifest.json supportScope is required."
    }
    $manifestSelectedTargets = @($manifest.selectedTargets | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ } | Sort-Object)
    $scopeSelectedTargets = @($supportScope.selectedTargets | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ } | Sort-Object)
    Assert-ArrayEqual -Actual $scopeSelectedTargets -Expected $manifestSelectedTargets -Name "supportScope.selectedTargets"
    if ([int]$supportScope.selectedTargetCount -ne $manifestSelectedTargets.Count) {
      throw "supportScope.selectedTargetCount does not match selectedTargets."
    }
    if ([int]$supportScope.matrixTargetCount -ne $matrixTargetIds.Count) {
      throw "supportScope.matrixTargetCount does not match the support matrix."
    }
    $scopeKind = Get-StringValue -Object $supportScope -Names @("kind")
    $hasManifestTargetFilter = @($manifest.targetIds | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ }).Count -gt 0
    $hasManifestCategoryFilter = @($manifest.categories | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ }).Count -gt 0
    $expectedScopeKind = "unfiltered"
    if (Get-BooleanValue -Object $manifest -Names @("productionRecommendedOnly") -Default $false) {
      $expectedScopeKind = "production-recommended"
    } elseif ($hasManifestTargetFilter -or $hasManifestCategoryFilter) {
      $expectedScopeKind = "filtered"
    } elseif (Get-BooleanValue -Object $manifest -Names @("coverageCompleteRequired") -Default $false) {
      $missingFromSelection = @($matrixTargetIds | Where-Object { $manifestSelectedTargets -notcontains $_ })
      $extraInSelection = @($manifestSelectedTargets | Where-Object { $matrixTargetIds -notcontains $_ })
      if ($missingFromSelection.Count -eq 0 -and $extraInSelection.Count -eq 0) {
        $expectedScopeKind = "full-matrix"
      } else {
        $expectedScopeKind = "filtered"
      }
    }
    if ($scopeKind -ne $expectedScopeKind) {
      throw "supportScope.kind must be '$expectedScopeKind', got '$scopeKind'."
    }
    if ((Get-BooleanValue -Object $supportScope -Names @("fullMatrix") -Default $false) -ne ($expectedScopeKind -eq "full-matrix")) {
      throw "supportScope.fullMatrix does not match supportScope.kind."
    }
    $expectedTargetFiltersApplied = ($hasManifestTargetFilter -or $hasManifestCategoryFilter)
    if ((Get-BooleanValue -Object $supportScope -Names @("targetFiltersApplied") -Default $false) -ne $expectedTargetFiltersApplied) {
      throw "supportScope.targetFiltersApplied does not match manifest target/category filters."
    }
    if ((Get-BooleanValue -Object $supportScope -Names @("productionRecommendedOnly") -Default $false) -ne (Get-BooleanValue -Object $manifest -Names @("productionRecommendedOnly") -Default $false)) {
      throw "supportScope.productionRecommendedOnly does not match manifest productionRecommendedOnly."
    }
    if ((Get-BooleanValue -Object $supportScope -Names @("supportClaimValidated") -Default $false) -ne $supportClaimValidated) {
      throw "supportScope.supportClaimValidated does not match manifest supportClaimValidated."
    }
    $expectedProofLevel = if ($requireCollectorSha256 -or $requireHostEvidenceWorkflowCollection -or $requireMinimumUptimeHours -gt 0) { "hardened-real-host-evidence" } else { "basic-real-host-evidence" }
    if ((Get-StringValue -Object $supportScope -Names @("proofLevel")) -ne $expectedProofLevel) {
      throw "supportScope.proofLevel must be '$expectedProofLevel'."
    }

    $listedPaths = New-Object System.Collections.Generic.HashSet[string]
    $listedHashes = @{}
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
      if ($listedHashes.ContainsKey($actualHash)) {
        throw "Manifest contains duplicate evidence SHA256 payload: $actualHash appears in '$($listedHashes[$actualHash])' and '$relative'."
      }
      $listedHashes[$actualHash] = $relative
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
      $rowTargetId = Normalize-Token ([string]$row.supportTargetId)
      if (-not $matrixTargetsById.ContainsKey($rowTargetId)) {
        throw "supportTargetId '$rowTargetId' was not found in the support matrix for $relative."
      }
      $platformTargets = @(Get-PlatformEvidenceTargets -Evidence $evidence)
      if ($platformTargets -notcontains $rowTargetId) {
        $platformTargetText = if ($platformTargets.Count -gt 0) { $platformTargets -join ", " } else { "<none>" }
        throw "supportTargetId '$rowTargetId' is not corroborated by platform metadata for ${relative}: $platformTargetText."
      }
      $platformRuntimeIssues = @(Get-NextJsPlatformRuntimeIssues -Evidence $evidence -SupportTargetId $rowTargetId -Context $relative)
      if ($platformRuntimeIssues.Count -gt 0) {
        throw "Next.js runtime platform floor evidence is invalid for ${relative}: $($platformRuntimeIssues -join ' ')"
      }
      $matrixTarget = $matrixTargetsById[$rowTargetId]
      $targetCategory = ([string]$row.targetCategory).Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($targetCategory)) {
        throw "targetCategory manifest value is required for $relative."
      }
      $nodeRuntimeSupport = Get-PropertyValue -Object $matrixTarget -Names @("nodeRuntimeSupport")
      if ([string]$row.nodeRuntimeMinimumNodeVersion -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("minimumNodeVersion"))) {
        throw "nodeRuntimeMinimumNodeVersion manifest mismatch for $relative."
      }
      if ([string]$row.nodeRuntimeSupportTier -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("supportTier"))) {
        throw "nodeRuntimeSupportTier manifest mismatch for $relative."
      }
      $rowNodeRuntimeProductionRecommended = Get-BooleanValue -Object $row -Names @("nodeRuntimeProductionRecommended") -Default $null
      $matrixNodeRuntimeProductionRecommended = Get-BooleanValue -Object $nodeRuntimeSupport -Names @("productionRecommended") -Default $null
      if ($rowNodeRuntimeProductionRecommended -ne $matrixNodeRuntimeProductionRecommended) {
        throw "nodeRuntimeProductionRecommended manifest mismatch for $relative."
      }
      if ([string]$row.nodeRuntimeRequirements -ne (Get-StringValue -Object $nodeRuntimeSupport -Names @("requirements"))) {
        throw "nodeRuntimeRequirements manifest mismatch for $relative."
      }
      $workflowDispatchSupported = Get-BooleanValue -Object $row -Names @("workflowDispatchSupported") -Default $null
      $localCommandOnly = Get-BooleanValue -Object $row -Names @("localCommandOnly") -Default $null
      if ($null -eq $workflowDispatchSupported -or $null -eq $localCommandOnly) {
        throw "workflowDispatchSupported and localCommandOnly manifest values are required for $relative."
      }
      if ($workflowDispatchSupported -eq $localCommandOnly) {
        throw "workflowDispatchSupported and localCommandOnly manifest values disagree for $relative."
      }
      $matrixLocalCommandOnly = Get-BooleanValue -Object $matrixTarget -Names @("localCommandOnly") -Default $false
      $matrixWorkflowDispatchSupported = ($matrixLocalCommandOnly -ne $true -and $targetCategory -in @("windows-client", "windows-server", "linux", "macos"))
      if ($workflowDispatchSupported -ne $matrixWorkflowDispatchSupported -or $localCommandOnly -ne (-not [bool]$matrixWorkflowDispatchSupported)) {
        throw "workflowDispatchSupported and localCommandOnly manifest values must match the support matrix for $relative."
      }
      if ($targetCategory -eq "bsd" -and $localCommandOnly -ne $true) {
        throw "BSD evidence must be marked local-command-only in the manifest for $relative."
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
      if ([string]$row.nodeVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersion", "nodeVersion"))) {
        throw "nodeVersion manifest mismatch for $relative."
      }
      if ([string]$row.minimumNodeVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("MinimumNodeVersion", "minimumNodeVersion"))) {
        throw "minimumNodeVersion manifest mismatch for $relative."
      }
      $rowNodeVersionSatisfied = Get-BooleanValue -Object $row -Names @("nodeVersionSatisfied") -Default $null
      $evidenceNodeVersionSatisfiedText = Get-NextJsRuntimeValue -Evidence $evidence -Names @("NodeVersionSatisfied", "nodeVersionSatisfied")
      $evidenceNodeVersionSatisfied = $null
      if (-not [string]::IsNullOrWhiteSpace($evidenceNodeVersionSatisfiedText)) {
        $evidenceNodeVersionSatisfied = ($evidenceNodeVersionSatisfiedText.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
      }
      if ($rowNodeVersionSatisfied -ne $evidenceNodeVersionSatisfied) {
        throw "nodeVersionSatisfied manifest mismatch for $relative."
      }
      if ([string]$row.nextVersion -ne (Get-NextJsRuntimeValue -Evidence $evidence -Names @("NextVersion", "nextVersion"))) {
        throw "nextVersion manifest mismatch for $relative."
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
      if ([string]$row.collectorSha256 -ne $collection.CollectorSha256) {
        throw "collectorSha256 manifest mismatch for $relative."
      }
      if ($requireCollectorSha256 -eq $true -and ([string]::IsNullOrWhiteSpace($collection.CollectorSha256) -or $collection.CollectorSha256 -notmatch '^[a-f0-9]{64}$')) {
        throw "Bundle requirement requireCollectorSha256 is true, but collectorSha256 is missing or invalid for $relative."
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
      $rowCollectionCiIsCi = Get-BooleanValue -Object $row -Names @("collectionCiIsCi") -Default $null
      $rowCollectionCiProvider = Get-StringValue -Object $row -Names @("collectionCiProvider")
      $rowCollectionCiWorkflowName = Get-StringValue -Object $row -Names @("collectionCiWorkflowName")
      $rowCollectionCiRunId = Get-StringValue -Object $row -Names @("collectionCiRunId")
      $rowCollectionCiRunAttempt = Get-StringValue -Object $row -Names @("collectionCiRunAttempt")
      $rowCollectionCiEventName = Get-StringValue -Object $row -Names @("collectionCiEventName")
      $rowCollectionCiRefName = Get-StringValue -Object $row -Names @("collectionCiRefName")
      $rowCollectionCiSha = Get-StringValue -Object $row -Names @("collectionCiSha")
      $rowCollectionWorkflowDispatchSupportMatrixPath = Get-StringValue -Object $row -Names @("collectionWorkflowDispatchSupportMatrixPath")
      $rowCollectionWorkflowDispatchSupportMatrixSha256 = Get-StringValue -Object $row -Names @("collectionWorkflowDispatchSupportMatrixSha256")
      $rowHasCollectionCi = (
        $null -ne $rowCollectionCiIsCi -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiProvider) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiWorkflowName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRunId) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRunAttempt) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiEventName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiRefName) -or
        -not [string]::IsNullOrWhiteSpace($rowCollectionCiSha)
      )
      $evidenceHasCollectionCi = (
        $null -ne $collection.Ci.IsCi -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.Provider) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.WorkflowName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RunId) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RunAttempt) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.EventName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.RefName) -or
        -not [string]::IsNullOrWhiteSpace($collection.Ci.Sha)
      )
      if ($requireHostEvidenceWorkflowCollection -eq $true -and $workflowDispatchSupported -eq $true -and (
          $collection.Ci.IsCi -ne $true -or
          $collection.Ci.Provider -ne "github-actions" -or
          $collection.Ci.WorkflowName -ne "host-evidence" -or
          $collection.Ci.EventName -ne "workflow_dispatch" -or
          $collection.WorkflowDispatch.SupportMatrixPath -ne $matrixReference.RelativePath -or
          $collection.WorkflowDispatch.SupportMatrixSha256 -ne $matrixSha256.ToLowerInvariant()
        )) {
        throw "Bundle requirement requireHostEvidenceWorkflowCollection is true, but workflow-capable evidence was not collected by the host-evidence workflow for the bundle support matrix for $relative."
      }
      if ($rowCollectionWorkflowDispatchSupportMatrixPath -ne $collection.WorkflowDispatch.SupportMatrixPath) {
        throw "collectionWorkflowDispatchSupportMatrixPath manifest mismatch for $relative."
      }
      if ($rowCollectionWorkflowDispatchSupportMatrixSha256 -ne $collection.WorkflowDispatch.SupportMatrixSha256) {
        throw "collectionWorkflowDispatchSupportMatrixSha256 manifest mismatch for $relative."
      }
      if ($rowHasCollectionCi -or $evidenceHasCollectionCi) {
        if ($rowCollectionCiIsCi -ne $collection.Ci.IsCi) {
          throw "collectionCiIsCi manifest mismatch for $relative."
        }
        if ($rowCollectionCiProvider -ne $collection.Ci.Provider) {
          throw "collectionCiProvider manifest mismatch for $relative."
        }
        if ($rowCollectionCiWorkflowName -ne $collection.Ci.WorkflowName) {
          throw "collectionCiWorkflowName manifest mismatch for $relative."
        }
        if ($rowCollectionCiRunId -ne $collection.Ci.RunId) {
          throw "collectionCiRunId manifest mismatch for $relative."
        }
        if ($rowCollectionCiRunAttempt -ne $collection.Ci.RunAttempt) {
          throw "collectionCiRunAttempt manifest mismatch for $relative."
        }
        if ($rowCollectionCiEventName -ne $collection.Ci.EventName) {
          throw "collectionCiEventName manifest mismatch for $relative."
        }
        if ($rowCollectionCiRefName -ne $collection.Ci.RefName) {
          throw "collectionCiRefName manifest mismatch for $relative."
        }
        if ($rowCollectionCiSha -ne $collection.Ci.Sha) {
          throw "collectionCiSha manifest mismatch for $relative."
        }
        Assert-CollectionCiProvenance -Ci $collection.Ci -Context $relative
      }
      if ($requireMinimumUptimeHours -gt 0) {
        $uptime = Get-PropertyValue -Object $evidence -Names @("Uptime", "uptime")
        if ($null -eq $uptime) {
          throw "Bundle requirement requireMinimumUptimeHours is $requireMinimumUptimeHours, but uptime evidence is missing for $relative."
        }
        $minimumUptimeHours = Get-IntegerValue -Object $uptime -Names @("MinimumUptimeHours", "minimumUptimeHours")
        $minimumSatisfied = Get-BooleanValue -Object $uptime -Names @("MinimumSatisfied", "minimumSatisfied") -Default $null
        if ($null -eq $minimumUptimeHours -or $minimumUptimeHours -lt $requireMinimumUptimeHours -or $minimumSatisfied -ne $true) {
          throw "Bundle requirement requireMinimumUptimeHours is $requireMinimumUptimeHours, but uptime evidence does not prove that window for $relative."
        }
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
    if ([int]$manifest.summary.uniqueEvidenceSha256Count -ne $listedHashes.Count) {
      throw "Manifest summary uniqueEvidenceSha256Count does not match unique evidence SHA256 payload count."
    }
    if ([int]$manifest.summary.uniqueEvidenceSha256Count -ne $manifestRows.Count) {
      throw "Manifest summary uniqueEvidenceSha256Count must match evidenceFileCount."
    }
    $expectedWorkflowCapableEvidenceCount = @($manifestRows | Where-Object { (Get-BooleanValue -Object $_ -Names @("workflowDispatchSupported") -Default $false) -eq $true }).Count
    $expectedLocalCommandOnlyEvidenceCount = @($manifestRows | Where-Object { (Get-BooleanValue -Object $_ -Names @("localCommandOnly") -Default $false) -eq $true }).Count
    if ([int]$supportScope.workflowCapableEvidenceCount -ne $expectedWorkflowCapableEvidenceCount) {
      throw "supportScope.workflowCapableEvidenceCount does not match manifest rows."
    }
    if ([int]$supportScope.localCommandOnlyEvidenceCount -ne $expectedLocalCommandOnlyEvidenceCount) {
      throw "supportScope.localCommandOnlyEvidenceCount does not match manifest rows."
    }
    if ([int]$supportScope.requiredMinimumUptimeHours -ne $requireMinimumUptimeHours) {
      throw "supportScope.requiredMinimumUptimeHours does not match manifest requireMinimumUptimeHours."
    }
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
  $selfTestOutputDirectory = Join-Path $RepoRoot ".tmp\support-evidence-bundle-verifier-selftest-$([Guid]::NewGuid().ToString('N'))"
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") -SelfTest -OutputDirectory $selfTestOutputDirectory | Out-Null
  $selfTestRoot = Join-Path $selfTestOutputDirectory "selftest-support-evidence"
  $selfTestZip = Join-Path $selfTestOutputDirectory "selftest-support-evidence.zip"
  Test-Bundle -Path $selfTestRoot
  Test-Bundle -Path $selfTestZip
  Test-Bundle -Path $selfTestRoot -MatrixPathOverride "config/support-matrix.example.json"

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

  $duplicateHashRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-duplicate-hash-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $duplicateHashRoot
  $duplicateHashSourceRelative = "evidence/ubuntu-systemd-nginx.json"
  $duplicateHashCopyRelative = "evidence/ubuntu-systemd-nginx-copy.json"
  $duplicateHashSourcePath = Join-Path $duplicateHashRoot ($duplicateHashSourceRelative -replace '/', '\')
  $duplicateHashCopyPath = Join-Path $duplicateHashRoot ($duplicateHashCopyRelative -replace '/', '\')
  Copy-Item -LiteralPath $duplicateHashSourcePath -Destination $duplicateHashCopyPath -Force
  $duplicateHashManifestPath = Join-Path $duplicateHashRoot "support-evidence-manifest.json"
  $duplicateHashManifest = Get-Content -LiteralPath $duplicateHashManifestPath -Raw | ConvertFrom-Json
  $duplicateHashRow = @($duplicateHashManifest.files | Where-Object { [string]$_.path -eq $duplicateHashSourceRelative } | Select-Object -First 1)[0] |
    ConvertTo-Json -Depth 12 |
    ConvertFrom-Json
  $duplicateHashRow.path = $duplicateHashCopyRelative
  $duplicateHashManifest.files = @($duplicateHashManifest.files) + @($duplicateHashRow)
  $duplicateHashManifest.summary.evidenceFileCount = @($duplicateHashManifest.files).Count
  ($duplicateHashManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $duplicateHashManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "duplicate evidence SHA256 payload" -Action {
    Test-Bundle -Path $duplicateHashRoot
  }

  $targetMismatchRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-target-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $targetMismatchRoot
  $targetMismatchFile = Join-Path $targetMismatchRoot "evidence\ubuntu-systemd-nginx.json"
  $targetMismatchEvidence = Get-Content -LiteralPath $targetMismatchFile -Raw | ConvertFrom-Json
  $targetMismatchEvidence.supportTargetId = "windows-server-2022"
  $targetMismatchEvidence.platform.supportTargetId = "windows-server-2022"
  ($targetMismatchEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $targetMismatchFile -Encoding UTF8
  $targetMismatchManifestPath = Join-Path $targetMismatchRoot "support-evidence-manifest.json"
  $targetMismatchManifest = Get-Content -LiteralPath $targetMismatchManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($targetMismatchManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.supportTargetId = "windows-server-2022"
      $row.sha256 = (Get-FileHash -LiteralPath $targetMismatchFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $targetMismatchFile).Length
    }
  }
  $targetMismatchManifest.summary.targets = @("windows-server-2022")
  ($targetMismatchManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $targetMismatchManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "not corroborated by platform metadata" -Action {
    Test-Bundle -Path $targetMismatchRoot
  }

  $runtimeFloorRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-runtime-floor-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $runtimeFloorRoot
  $runtimeFloorFile = Join-Path $runtimeFloorRoot "evidence\ubuntu-systemd-nginx.json"
  $runtimeFloorEvidence = Get-Content -LiteralPath $runtimeFloorFile -Raw | ConvertFrom-Json
  $runtimeFloorEvidence.platform.kernelRelease = "4.17.0"
  $runtimeFloorEvidence.platform.libcVersion = "2.27"
  ($runtimeFloorEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $runtimeFloorFile -Encoding UTF8
  $runtimeFloorManifestPath = Join-Path $runtimeFloorRoot "support-evidence-manifest.json"
  $runtimeFloorManifest = Get-Content -LiteralPath $runtimeFloorManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($runtimeFloorManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $runtimeFloorFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $runtimeFloorFile).Length
    }
  }
  ($runtimeFloorManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $runtimeFloorManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "runtime platform floor evidence is invalid" -Action {
    Test-Bundle -Path $runtimeFloorRoot
  }

  $missingMatrixRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-matrix-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingMatrixRoot
  $missingMatrixManifestPath = Join-Path $missingMatrixRoot "support-evidence-manifest.json"
  $missingMatrixManifest = Get-Content -LiteralPath $missingMatrixManifestPath -Raw | ConvertFrom-Json
  $missingMatrixManifest.PSObject.Properties.Remove("matrixSha256")
  ($missingMatrixManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingMatrixManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "matrixSha256 is required" -Action {
    Test-Bundle -Path $missingMatrixRoot
  }

  $staleMatrixRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-stale-matrix-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $staleMatrixRoot
  $staleMatrixManifestPath = Join-Path $staleMatrixRoot "support-evidence-manifest.json"
  $staleMatrixManifest = Get-Content -LiteralPath $staleMatrixManifestPath -Raw | ConvertFrom-Json
  $staleMatrixManifest.matrixSha256 = ("0" * 64)
  ($staleMatrixManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $staleMatrixManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "matrixSha256 must match" -Action {
    Test-Bundle -Path $staleMatrixRoot
  }

  $missingMatrixPathRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-matrix-path-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingMatrixPathRoot
  $missingMatrixPathManifestPath = Join-Path $missingMatrixPathRoot "support-evidence-manifest.json"
  $missingMatrixPathManifest = Get-Content -LiteralPath $missingMatrixPathManifestPath -Raw | ConvertFrom-Json
  $missingMatrixPathManifest.PSObject.Properties.Remove("matrixPath")
  ($missingMatrixPathManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingMatrixPathManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "matrixPath is required" -Action {
    Test-Bundle -Path $missingMatrixPathRoot
  }

  $untrackedMatrixPathRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-untracked-matrix-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $untrackedMatrixPathRoot
  $untrackedMatrixPathManifestPath = Join-Path $untrackedMatrixPathRoot "support-evidence-manifest.json"
  $untrackedMatrixPathManifest = Get-Content -LiteralPath $untrackedMatrixPathManifestPath -Raw | ConvertFrom-Json
  $untrackedMatrixPathManifest.matrixPath = "config/not-tracked-support-matrix.json"
  ($untrackedMatrixPathManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $untrackedMatrixPathManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "matrixPath must reference a tracked repository file" -Action {
    Test-Bundle -Path $untrackedMatrixPathRoot
  }

  Invoke-ExpectBundleFailure -ExpectedMessage "MatrixPath override must match" -Action {
    Test-Bundle -Path $selfTestRoot -MatrixPathOverride "config/not-tracked-support-matrix.json"
  }

  $missingSourceRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-source-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingSourceRoot
  $missingSourceManifestPath = Join-Path $missingSourceRoot "support-evidence-manifest.json"
  $missingSourceManifest = Get-Content -LiteralPath $missingSourceManifestPath -Raw | ConvertFrom-Json
  $missingSourceManifest.PSObject.Properties.Remove("sourceControl")
  ($missingSourceManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingSourceManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "sourceControl is required" -Action {
    Test-Bundle -Path $missingSourceRoot
  }

  $missingCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $missingCiRoot
  $missingCiManifestPath = Join-Path $missingCiRoot "support-evidence-manifest.json"
  $missingCiManifest = Get-Content -LiteralPath $missingCiManifestPath -Raw | ConvertFrom-Json
  $missingCiManifest.PSObject.Properties.Remove("ci")
  ($missingCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $missingCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci provenance is required" -Action {
    Test-Bundle -Path $missingCiRoot
  }

  $inconsistentCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-provider-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $inconsistentCiRoot
  $inconsistentCiManifestPath = Join-Path $inconsistentCiRoot "support-evidence-manifest.json"
  $inconsistentCiManifest = Get-Content -LiteralPath $inconsistentCiManifestPath -Raw | ConvertFrom-Json
  $inconsistentCiManifest.ci.isCi = $false
  $inconsistentCiManifest.ci.provider = "github-actions"
  ($inconsistentCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $inconsistentCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.provider must be empty when ci.isCi is false" -Action {
    Test-Bundle -Path $inconsistentCiRoot
  }

  $badCiShaRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-sha-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $badCiShaRoot
  $badCiShaManifestPath = Join-Path $badCiShaRoot "support-evidence-manifest.json"
  $badCiShaManifest = Get-Content -LiteralPath $badCiShaManifestPath -Raw | ConvertFrom-Json
  $badCiShaManifest.ci.sha = "not-a-sha"
  ($badCiShaManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $badCiShaManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.sha must be a 40-character git SHA" -Action {
    Test-Bundle -Path $badCiShaRoot
  }

  $mismatchCiShaRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-ci-source-sha-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $mismatchCiShaRoot
  $mismatchCiShaManifestPath = Join-Path $mismatchCiShaRoot "support-evidence-manifest.json"
  $mismatchCiShaManifest = Get-Content -LiteralPath $mismatchCiShaManifestPath -Raw | ConvertFrom-Json
  $mismatchCiShaManifest.ci.sha = ("0" * 40)
  ($mismatchCiShaManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $mismatchCiShaManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.sha must match sourceControl.commitSha" -Action {
    Test-Bundle -Path $mismatchCiShaRoot
  }

  $completeGithubCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-complete-github-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $completeGithubCiRoot
  $completeGithubCiManifestPath = Join-Path $completeGithubCiRoot "support-evidence-manifest.json"
  $completeGithubCiManifest = Get-Content -LiteralPath $completeGithubCiManifestPath -Raw | ConvertFrom-Json
  $completeGithubCiManifest.ci.isCi = $true
  $completeGithubCiManifest.ci.provider = "github-actions"
  $completeGithubCiManifest.ci.workflowName = "selftest"
  $completeGithubCiManifest.ci.runId = "123456"
  $completeGithubCiManifest.ci.runAttempt = "1"
  $completeGithubCiManifest.ci.eventName = "workflow_dispatch"
  $completeGithubCiManifest.ci.refName = "main"
  $completeGithubCiManifest.ci.sha = $completeGithubCiManifest.sourceControl.commitSha
  ($completeGithubCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $completeGithubCiManifestPath -Encoding UTF8
  Test-Bundle -Path $completeGithubCiRoot

  $collectionCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-collection-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $collectionCiRoot
  $collectionCiFile = Join-Path $collectionCiRoot "evidence\ubuntu-systemd-nginx.json"
  $collectionCiEvidence = Get-Content -LiteralPath $collectionCiFile -Raw | ConvertFrom-Json
  $collectionCiEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "123456"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = $completeGithubCiManifest.sourceControl.commitSha
    }) -Force
  ($collectionCiEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $collectionCiFile -Encoding UTF8
  $collectionCiManifestPath = Join-Path $collectionCiRoot "support-evidence-manifest.json"
  $collectionCiManifest = Get-Content -LiteralPath $collectionCiManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($collectionCiManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $collectionCiFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $collectionCiFile).Length
      $row.collectionCiIsCi = $true
      $row.collectionCiProvider = "github-actions"
      $row.collectionCiWorkflowName = "host-evidence"
      $row.collectionCiRunId = "123456"
      $row.collectionCiRunAttempt = "1"
      $row.collectionCiEventName = "workflow_dispatch"
      $row.collectionCiRefName = "main"
      $row.collectionCiSha = $completeGithubCiManifest.sourceControl.commitSha
    }
  }
  ($collectionCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $collectionCiManifestPath -Encoding UTF8
  Test-Bundle -Path $collectionCiRoot

  $badCollectionCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-collection-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $collectionCiRoot -Destination $badCollectionCiRoot
  $badCollectionCiFile = Join-Path $badCollectionCiRoot "evidence\ubuntu-systemd-nginx.json"
  $badCollectionCiEvidence = Get-Content -LiteralPath $badCollectionCiFile -Raw | ConvertFrom-Json
  $badCollectionCiEvidence.evidenceCollection.ci.runId = ""
  ($badCollectionCiEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiFile -Encoding UTF8
  $badCollectionCiManifestPath = Join-Path $badCollectionCiRoot "support-evidence-manifest.json"
  $badCollectionCiManifest = Get-Content -LiteralPath $badCollectionCiManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($badCollectionCiManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $badCollectionCiFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $badCollectionCiFile).Length
      $row.collectionCiRunId = ""
    }
  }
  ($badCollectionCiManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "collection ci.runId is required for github-actions provenance" -Action {
    Test-Bundle -Path $badCollectionCiRoot
  }

  $badCollectionCiProviderRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-collection-ci-provider-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $collectionCiRoot -Destination $badCollectionCiProviderRoot
  $badCollectionCiProviderFile = Join-Path $badCollectionCiProviderRoot "evidence\ubuntu-systemd-nginx.json"
  $badCollectionCiProviderEvidence = Get-Content -LiteralPath $badCollectionCiProviderFile -Raw | ConvertFrom-Json
  $badCollectionCiProviderEvidence.evidenceCollection.ci.isCi = $false
  $badCollectionCiProviderEvidence.evidenceCollection.ci.provider = "github-actions"
  ($badCollectionCiProviderEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiProviderFile -Encoding UTF8
  $badCollectionCiProviderManifestPath = Join-Path $badCollectionCiProviderRoot "support-evidence-manifest.json"
  $badCollectionCiProviderManifest = Get-Content -LiteralPath $badCollectionCiProviderManifestPath -Raw | ConvertFrom-Json
  foreach ($row in @($badCollectionCiProviderManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $badCollectionCiProviderFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $badCollectionCiProviderFile).Length
      $row.collectionCiIsCi = $false
      $row.collectionCiProvider = "github-actions"
    }
  }
  ($badCollectionCiProviderManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $badCollectionCiProviderManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "collection ci.provider must be empty when ci.isCi is false" -Action {
    Test-Bundle -Path $badCollectionCiProviderRoot
  }

  $incompleteGithubCiRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-github-ci-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $incompleteGithubCiRoot
  $incompleteGithubCiManifestPath = Join-Path $incompleteGithubCiRoot "support-evidence-manifest.json"
  $incompleteGithubCiManifest = Get-Content -LiteralPath $incompleteGithubCiManifestPath -Raw | ConvertFrom-Json
  $incompleteGithubCiManifest.ci.isCi = $true
  $incompleteGithubCiManifest.ci.provider = "github-actions"
  $incompleteGithubCiManifest.ci.workflowName = "selftest"
  $incompleteGithubCiManifest.ci.runId = ""
  $incompleteGithubCiManifest.ci.runAttempt = "1"
  $incompleteGithubCiManifest.ci.eventName = "workflow_dispatch"
  $incompleteGithubCiManifest.ci.refName = "main"
  $incompleteGithubCiManifest.ci.sha = $incompleteGithubCiManifest.sourceControl.commitSha
  ($incompleteGithubCiManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $incompleteGithubCiManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "ci.runId is required for github-actions provenance" -Action {
    Test-Bundle -Path $incompleteGithubCiRoot
  }

  $claimMismatchRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-claim-flags-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $claimMismatchRoot
  $claimMismatchManifestPath = Join-Path $claimMismatchRoot "support-evidence-manifest.json"
  $claimMismatchManifest = Get-Content -LiteralPath $claimMismatchManifestPath -Raw | ConvertFrom-Json
  $claimMismatchManifest.supportClaimValidated = $false
  $claimMismatchManifest | Add-Member -NotePropertyName "requireHostEvidenceWorkflowCollection" -NotePropertyValue $true -Force
  ($claimMismatchManifest | ConvertTo-Json -Depth 8) | Set-Content -Path $claimMismatchManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "cannot require host-evidence workflow collection unless supportClaimValidated is true" -Action {
    Test-Bundle -Path $claimMismatchRoot
  }

  $requiredCollectorRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-required-collector-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $requiredCollectorRoot
  $requiredCollectorFile = Join-Path $requiredCollectorRoot "evidence\ubuntu-systemd-nginx.json"
  $requiredCollectorEvidence = Get-Content -LiteralPath $requiredCollectorFile -Raw | ConvertFrom-Json
  $requiredCollectorEvidence.evidenceCollection.collectorSha256 = ""
  ($requiredCollectorEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredCollectorFile -Encoding UTF8
  $requiredCollectorManifestPath = Join-Path $requiredCollectorRoot "support-evidence-manifest.json"
  $requiredCollectorManifest = Get-Content -LiteralPath $requiredCollectorManifestPath -Raw | ConvertFrom-Json
  $requiredCollectorManifest | Add-Member -NotePropertyName "requireCollectorSha256" -NotePropertyValue $true -Force
  $requiredCollectorManifest.supportScope.proofLevel = "hardened-real-host-evidence"
  foreach ($row in @($requiredCollectorManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $requiredCollectorFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $requiredCollectorFile).Length
      $row.collectorSha256 = ""
    }
  }
  ($requiredCollectorManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredCollectorManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "requireCollectorSha256 is true" -Action {
    Test-Bundle -Path $requiredCollectorRoot
  }

  $requiredWorkflowRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-required-workflow-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $requiredWorkflowRoot
  $requiredWorkflowFile = Join-Path $requiredWorkflowRoot "evidence\ubuntu-systemd-nginx.json"
  $requiredWorkflowEvidence = Get-Content -LiteralPath $requiredWorkflowFile -Raw | ConvertFrom-Json
  $requiredWorkflowEvidence.evidenceCollection.ci.workflowName = "other-workflow"
  ($requiredWorkflowEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredWorkflowFile -Encoding UTF8
  $requiredWorkflowManifestPath = Join-Path $requiredWorkflowRoot "support-evidence-manifest.json"
  $requiredWorkflowManifest = Get-Content -LiteralPath $requiredWorkflowManifestPath -Raw | ConvertFrom-Json
  $requiredWorkflowManifest.supportClaimValidated = $true
  $requiredWorkflowManifest | Add-Member -NotePropertyName "requireHostEvidenceWorkflowCollection" -NotePropertyValue $true -Force
  $requiredWorkflowManifest.supportScope.proofLevel = "hardened-real-host-evidence"
  $requiredWorkflowManifest.supportScope.supportClaimValidated = $true
  foreach ($row in @($requiredWorkflowManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $requiredWorkflowFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $requiredWorkflowFile).Length
      $row.collectionCiWorkflowName = "other-workflow"
    }
  }
  ($requiredWorkflowManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredWorkflowManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "requireHostEvidenceWorkflowCollection is true" -Action {
    Test-Bundle -Path $requiredWorkflowRoot
  }

  $requiredUptimeRoot = Join-Path $RepoRoot ".tmp\support-evidence-bundle-negative-required-uptime-$([Guid]::NewGuid().ToString('N'))"
  Copy-BundleDirectory -Source $selfTestRoot -Destination $requiredUptimeRoot
  $requiredUptimeFile = Join-Path $requiredUptimeRoot "evidence\ubuntu-systemd-nginx.json"
  $requiredUptimeEvidence = Get-Content -LiteralPath $requiredUptimeFile -Raw | ConvertFrom-Json
  $requiredUptimeEvidence.uptime.minimumSatisfied = $false
  ($requiredUptimeEvidence | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredUptimeFile -Encoding UTF8
  $requiredUptimeManifestPath = Join-Path $requiredUptimeRoot "support-evidence-manifest.json"
  $requiredUptimeManifest = Get-Content -LiteralPath $requiredUptimeManifestPath -Raw | ConvertFrom-Json
  $requiredUptimeManifest | Add-Member -NotePropertyName "requireMinimumUptimeHours" -NotePropertyValue 72 -Force
  $requiredUptimeManifest.supportScope.proofLevel = "hardened-real-host-evidence"
  $requiredUptimeManifest.supportScope.requiredMinimumUptimeHours = 72
  foreach ($row in @($requiredUptimeManifest.files)) {
    if ([string]$row.path -eq "evidence/ubuntu-systemd-nginx.json") {
      $row.sha256 = (Get-FileHash -LiteralPath $requiredUptimeFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $row.bytes = (Get-Item -LiteralPath $requiredUptimeFile).Length
    }
  }
  ($requiredUptimeManifest | ConvertTo-Json -Depth 12) | Set-Content -Path $requiredUptimeManifestPath -Encoding UTF8
  Invoke-ExpectBundleFailure -ExpectedMessage "requireMinimumUptimeHours is 72" -Action {
    Test-Bundle -Path $requiredUptimeRoot
  }

  Write-Host "Support evidence bundle verification OK"
  return
}

if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  throw "BundlePath is required unless -SelfTest is used."
}
Test-Bundle -Path $BundlePath -MatrixPathOverride $MatrixPath
Write-Host "Support evidence bundle verification OK"
