param(
  [string]$ArtifactPath = "",
  [string]$EvidencePath = ".\evidence",
  [string]$MatrixPath = "",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$AllowWarnings,
  [switch]$AllowLocalCollection,
  [switch]$SkipValidation,
  [switch]$Force,
  [switch]$PassThru,
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
if (-not [string]::IsNullOrWhiteSpace($ArtifactPath) -and -not [System.IO.Path]::IsPathRooted($ArtifactPath)) {
  $ArtifactPath = Join-Path (Get-Location) $ArtifactPath
}
if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}

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

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
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

function Get-MatrixRequiredMinimumUptimeHours {
  param([object]$Matrix)

  try {
    $value = [int]$Matrix.requiredMinimumUptimeHours
    if ($value -lt 1) {
      throw "requiredMinimumUptimeHours must be positive."
    }
    return $value
  } catch {
    throw "Support matrix requiredMinimumUptimeHours must be a positive integer."
  }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SafePathName {
  param([string]$Value)

  $name = Normalize-Token $Value
  if (-not $name) { return "artifact" }
  return $name
}

function Normalize-RepositoryRelativePath {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().Replace("\", "/")
  if ($normalized.StartsWith("./", [StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(2)
  }
  return $normalized.Trim("/")
}

function Get-RepositoryRelativePath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if ($fullPath.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Support matrix path must be inside the repository: $Path"
  }

  return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
}

function Expand-ArtifactZip {
  param(
    [string]$ZipPath,
    [string]$ExtractionRoot,
    [int]$Index
  )

  if ([System.IO.Path]::GetExtension($ZipPath).ToLowerInvariant() -ne ".zip") {
    throw "ArtifactPath file must be a .zip file or a directory: $ZipPath"
  }
  $zipName = Get-SafePathName ([System.IO.Path]::GetFileNameWithoutExtension($ZipPath))
  $destination = Join-Path $ExtractionRoot ("$Index-$zipName")
  New-Item -ItemType Directory -Path $destination -Force | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $destination -Force
  return $destination
}

function Get-ArtifactStatusFiles {
  param([string]$Path)

  $candidateRoots = New-Object System.Collections.Generic.List[string]
  $extractionRoot = Join-Path $RepoRoot ".tmp\host-evidence-artifacts-$([Guid]::NewGuid().ToString('N'))"
  $zipIndex = 0

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $candidateRoots.Add((Expand-ArtifactZip -ZipPath $Path -ExtractionRoot $extractionRoot -Index $zipIndex)) | Out-Null
  } elseif (Test-Path -LiteralPath $Path -PathType Container) {
    $candidateRoots.Add($Path) | Out-Null
    foreach ($zipFile in @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.zip")) {
      $zipIndex += 1
      $candidateRoots.Add((Expand-ArtifactZip -ZipPath $zipFile.FullName -ExtractionRoot $extractionRoot -Index $zipIndex)) | Out-Null
    }
  } else {
    throw "ArtifactPath not found: $Path"
  }

  $sourceFiles = New-Object System.Collections.Generic.List[object]
  foreach ($root in @($candidateRoots)) {
    foreach ($file in @(Get-ChildItem -Path $root -Recurse -File -Filter "status.json")) {
      $sourceFiles.Add($file) | Out-Null
    }
  }
  return @($sourceFiles | ForEach-Object { $_ })
}

function Get-SupportTargetId {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $value = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $value) {
    $value = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }
  return (Normalize-Token $value)
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

function Assert-SupportTargetCorroborated {
  param(
    [object]$Evidence,
    [string]$TargetId,
    [string]$SourceFile
  )

  $platformTargets = @(Get-PlatformEvidenceTargets -Evidence $Evidence)
  if ($platformTargets -notcontains $TargetId) {
    throw "Evidence support target '$TargetId' is not corroborated by platform metadata in $SourceFile. Platform-derived target(s): $($platformTargets -join ', ')."
  }
}

function Test-WorkflowDispatchSupported {
  param([string]$Category)
  return ((Normalize-Token $Category) -in @("windows-client", "windows-server", "linux", "macos"))
}

function Test-TargetWorkflowDispatchSupported {
  param([object]$Target)

  $localCommandOnly = Get-PropertyValue -Object $Target -Names @("localCommandOnly")
  if ($localCommandOnly -eq $true) {
    return $false
  }
  return (Test-WorkflowDispatchSupported -Category ([string]$Target.category))
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
  return (Normalize-Token $mode)
}

function Get-ServiceManager {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }
  return (Normalize-Token $serviceManager)
}

function Get-ReverseProxy {
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
  return (Normalize-ReverseProxy $mode)
}

function Get-EvidenceCollectionCi {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  $ci = Get-PropertyValue -Object $collection -Names @("Ci", "ci")
  [pscustomobject]@{
    isCi = Get-PropertyValue -Object $ci -Names @("IsCi", "isCi")
    provider = Get-StringValue -Object $ci -Names @("Provider", "provider")
    workflowName = Get-StringValue -Object $ci -Names @("WorkflowName", "workflowName")
    runId = Get-StringValue -Object $ci -Names @("RunId", "runId")
    runAttempt = Get-StringValue -Object $ci -Names @("RunAttempt", "runAttempt")
    eventName = Get-StringValue -Object $ci -Names @("EventName", "eventName")
    refName = Get-StringValue -Object $ci -Names @("RefName", "refName")
    sha = Get-StringValue -Object $ci -Names @("Sha", "sha")
  }
}

function Get-EvidenceWorkflowDispatch {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  $dispatch = Get-PropertyValue -Object $collection -Names @("WorkflowDispatch", "workflowDispatch")
  [pscustomobject]@{
    evidenceName = Normalize-Token (Get-StringValue -Object $dispatch -Names @("EvidenceName", "evidenceName"))
    expectedTargetId = Normalize-Token (Get-StringValue -Object $dispatch -Names @("ExpectedTargetId", "expectedTargetId", "expected_target_id"))
    expectedNextJsMode = Normalize-Token (Get-StringValue -Object $dispatch -Names @("ExpectedNextJsMode", "expectedNextJsMode", "expected_nextjs_mode"))
    expectedServiceManager = Normalize-Token (Get-StringValue -Object $dispatch -Names @("ExpectedServiceManager", "expectedServiceManager", "expected_service_manager"))
    expectedReverseProxy = Normalize-ReverseProxy (Get-StringValue -Object $dispatch -Names @("ExpectedReverseProxy", "expectedReverseProxy", "expected_reverse_proxy"))
    minimumUptimeHours = Get-IntegerValue -Object $dispatch -Names @("MinimumUptimeHours", "minimumUptimeHours", "minimum_uptime_hours")
    supportMatrixPath = Normalize-RepositoryRelativePath (Get-StringValue -Object $dispatch -Names @("SupportMatrixPath", "supportMatrixPath", "matrixPath", "matrix_path"))
    supportMatrixSha256 = (Get-StringValue -Object $dispatch -Names @("SupportMatrixSha256", "supportMatrixSha256", "matrixSha256", "matrix_sha256")).Trim().ToLowerInvariant()
  }
}

function Test-TruthyValue {
  param($Value)

  if ($Value -is [bool]) { return [bool]$Value }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  return ($text -in @("true", "1", "yes"))
}

function Assert-HostEvidenceWorkflowCollection {
  param(
    [object]$Evidence,
    [object]$Target,
    [string]$SourceFile,
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours,
    [string]$ExpectedMatrixPath,
    [string]$ExpectedMatrixSha256
  )

  if ($AllowLocalCollection -and -not (Test-TargetWorkflowDispatchSupported -Target $Target)) {
    return
  }

  $ci = Get-EvidenceCollectionCi -Evidence $Evidence
  $issues = New-Object System.Collections.Generic.List[string]
  if (-not (Test-TruthyValue $ci.isCi)) {
    $issues.Add("evidenceCollection.ci.isCi must be true") | Out-Null
  }
  if ($ci.provider -ne "github-actions") {
    $issues.Add("evidenceCollection.ci.provider must be github-actions") | Out-Null
  }
  if ($ci.workflowName -ne "host-evidence") {
    $issues.Add("evidenceCollection.ci.workflowName must be host-evidence") | Out-Null
  }
  if ($ci.eventName -ne "workflow_dispatch") {
    $issues.Add("evidenceCollection.ci.eventName must be workflow_dispatch") | Out-Null
  }
  if ($ci.runId -notmatch '^\d+$') {
    $issues.Add("evidenceCollection.ci.runId must be numeric") | Out-Null
  }
  if ($ci.runAttempt -notmatch '^\d+$') {
    $issues.Add("evidenceCollection.ci.runAttempt must be numeric") | Out-Null
  }
  if ([string]::IsNullOrWhiteSpace([string]$ci.refName)) {
    $issues.Add("evidenceCollection.ci.refName is required") | Out-Null
  } elseif ($ci.refName -notmatch '^[A-Za-z0-9._/-]+$') {
    $issues.Add("evidenceCollection.ci.refName contains unsupported characters") | Out-Null
  }
  if ($ci.sha -notmatch '^[a-fA-F0-9]{40}$') {
    $issues.Add("evidenceCollection.ci.sha must be a 40-character git SHA") | Out-Null
  }
  $dispatch = Get-EvidenceWorkflowDispatch -Evidence $Evidence
  $expectedEvidenceBaseName = "$TargetId-$Mode-$ServiceManager-$ReverseProxy"
  $allowedEvidenceNames = @($expectedEvidenceBaseName, "$expectedEvidenceBaseName-fallback")
  if (-not $dispatch.evidenceName) {
    $issues.Add("evidenceCollection.workflowDispatch.evidenceName is required") | Out-Null
  } elseif ($allowedEvidenceNames -notcontains [string]$dispatch.evidenceName) {
    $issues.Add("evidenceCollection.workflowDispatch.evidenceName must match imported dimensions") | Out-Null
  }
  if ($dispatch.expectedTargetId -ne $TargetId) {
    $issues.Add("evidenceCollection.workflowDispatch.expectedTargetId must match imported target") | Out-Null
  }
  if ($dispatch.expectedNextJsMode -ne $Mode) {
    $issues.Add("evidenceCollection.workflowDispatch.expectedNextJsMode must match imported Next.js mode") | Out-Null
  }
  if ($dispatch.expectedServiceManager -ne $ServiceManager) {
    $issues.Add("evidenceCollection.workflowDispatch.expectedServiceManager must match imported service manager") | Out-Null
  }
  if ($dispatch.expectedReverseProxy -ne $ReverseProxy) {
    $issues.Add("evidenceCollection.workflowDispatch.expectedReverseProxy must match imported reverse proxy") | Out-Null
  }
  if ($null -eq $dispatch.minimumUptimeHours) {
    $issues.Add("evidenceCollection.workflowDispatch.minimumUptimeHours is required") | Out-Null
  } elseif ([int]$dispatch.minimumUptimeHours -lt $RequiredMinimumUptimeHours) {
    $issues.Add("evidenceCollection.workflowDispatch.minimumUptimeHours must be at least support matrix requiredMinimumUptimeHours") | Out-Null
  }
  $expectedMatrixPathValue = Normalize-RepositoryRelativePath $ExpectedMatrixPath
  if (-not [string]::IsNullOrWhiteSpace($expectedMatrixPathValue)) {
    if ([string]::IsNullOrWhiteSpace([string]$dispatch.supportMatrixPath)) {
      $issues.Add("evidenceCollection.workflowDispatch.supportMatrixPath is required") | Out-Null
    } elseif ([string]$dispatch.supportMatrixPath -ne $expectedMatrixPathValue) {
      $issues.Add("evidenceCollection.workflowDispatch.supportMatrixPath must match imported support matrix path") | Out-Null
    }
  }
  $expectedMatrixSha256Value = ([string]$ExpectedMatrixSha256).Trim().ToLowerInvariant()
  if (-not [string]::IsNullOrWhiteSpace($expectedMatrixSha256Value)) {
    if ($expectedMatrixSha256Value -notmatch '^[a-f0-9]{64}$') {
      $issues.Add("expected support matrix SHA256 must be a valid SHA256 hash") | Out-Null
    } elseif ([string]::IsNullOrWhiteSpace([string]$dispatch.supportMatrixSha256)) {
      $issues.Add("evidenceCollection.workflowDispatch.supportMatrixSha256 is required") | Out-Null
    } elseif ([string]$dispatch.supportMatrixSha256 -ne $expectedMatrixSha256Value) {
      $issues.Add("evidenceCollection.workflowDispatch.supportMatrixSha256 must match imported support matrix SHA256") | Out-Null
    }
  }
  if ($issues.Count -gt 0) {
    throw "Imported workflow artifact must prove controlled host-evidence workflow collection: $SourceFile. $($issues -join '; '). -AllowLocalCollection only bypasses this check for support matrix rows marked localCommandOnly."
  }
}

function Get-TargetById {
  param(
    [object]$Matrix,
    [string]$TargetId
  )

  foreach ($target in @(Get-ArrayValue $Matrix.targets)) {
    if ((Normalize-Token ([string]$target.id)) -eq $TargetId) {
      return $target
    }
  }
  return $null
}

function Get-CanonicalEvidenceFile {
  param(
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind
  )

  $fileName = "$Mode-$ServiceManager-$ReverseProxy.json"
  if ($Kind -eq "fallback") {
    $fileName = "$Mode-$ServiceManager-$ReverseProxy-fallback.json"
  }
  return Join-Path (Join-Path $EvidencePath $TargetId) $fileName
}

function Resolve-EvidenceKind {
  param(
    [object]$Target,
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy
  )

  $modes = @(Get-ArrayValue $Target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $serviceManagers = @(Get-ArrayValue $Target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $fallbackManagers = @(Get-ArrayValue (Get-PropertyValue -Object $Target -Names @("fallbackManagers")) | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
  $reverseProxies = @(Get-ArrayValue $Target.reverseProxies | ForEach-Object { Normalize-ReverseProxy ([string]$_) } | Where-Object { $_ })

  if ($modes -notcontains $Mode) {
    throw "Evidence Next.js mode '$Mode' is not declared for support matrix target '$TargetId'."
  }
  if ($reverseProxies -notcontains $ReverseProxy) {
    throw "Evidence reverse proxy '$ReverseProxy' is not declared for support matrix target '$TargetId'."
  }
  if ($ReverseProxy -eq "none") {
    if ($serviceManagers -contains $ServiceManager) {
      return "service-only"
    }
    if ($fallbackManagers -contains $ServiceManager) {
      return "fallback"
    }
    throw "Service-only evidence for '$TargetId' must use a declared strict or fallback service manager."
  }
  if ($serviceManagers -contains $ServiceManager) {
    return "strict"
  }
  if ($fallbackManagers -contains $ServiceManager) {
    return "fallback"
  }
  throw "Evidence service manager '$ServiceManager' is not declared for support matrix target '$TargetId'."
}

function Invoke-HostEvidenceValidation {
  param(
    [string]$SourceFile,
    [object]$Target,
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours,
    [string]$ExpectedMatrixPath,
    [string]$ExpectedMatrixSha256
  )

  if ($SkipValidation) { return }

  $validationArgs = @{
    EvidencePath = Split-Path -Parent $SourceFile
    RequireNextJs = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = $RequiredMinimumUptimeHours
    MaxEvidenceAgeDays = $MaxEvidenceAgeDays
    ExpectedTargetId = $TargetId
    ExpectedNextJsMode = $Mode
    ExpectedServiceManager = $ServiceManager
    ExpectedReverseProxy = $ReverseProxy
  }
  $validationArgs.RequireReverseProxy = $true
  if ($ReverseProxy -eq "none") {
    $validationArgs.AllowReverseProxyNone = $true
  }
  if (-not $AllowWarnings) {
    $validationArgs.FailOnWarnings = $true
  }
  if ((-not $AllowLocalCollection) -or (Test-TargetWorkflowDispatchSupported -Target $Target)) {
    $validationArgs.RequireCiCollection = $true
    $validationArgs.RequireHostEvidenceWorkflowCollection = $true
    $validationArgs.ExpectedMatrixPath = $ExpectedMatrixPath
    $validationArgs.ExpectedMatrixSha256 = $ExpectedMatrixSha256
  }

  & (Join-Path $ScriptDir "Test-HostEvidence.ps1") @validationArgs | Out-Null
}

function Import-OneEvidenceFile {
  param(
    [string]$SourceFile,
    [object]$Matrix,
    [int]$RequiredMinimumUptimeHours,
    [string]$ExpectedMatrixPath,
    [string]$ExpectedMatrixSha256
  )

  $evidence = Get-Content -LiteralPath $SourceFile -Raw | ConvertFrom-Json
  $targetId = Get-SupportTargetId -Evidence $evidence
  $mode = Get-NextJsMode -Evidence $evidence
  $serviceManager = Get-ServiceManager -Evidence $evidence
  $reverseProxy = Get-ReverseProxy -Evidence $evidence
  foreach ($nameValue in @(
      @{ Name = "support target"; Value = $targetId },
      @{ Name = "Next.js mode"; Value = $mode },
      @{ Name = "service manager"; Value = $serviceManager },
      @{ Name = "reverse proxy"; Value = $reverseProxy }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$nameValue.Value)) {
      throw "Evidence file is missing $($nameValue.Name): $SourceFile"
    }
  }
  Assert-SupportTargetCorroborated -Evidence $evidence -TargetId $targetId -SourceFile $SourceFile

  $target = Get-TargetById -Matrix $Matrix -TargetId $targetId
  if ($null -eq $target) {
    throw "Evidence target '$targetId' is not declared in the support matrix."
  }
  $kind = Resolve-EvidenceKind -Target $target -TargetId $targetId -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy
  Assert-HostEvidenceWorkflowCollection -Evidence $evidence -Target $target -SourceFile $SourceFile -TargetId $targetId -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -ExpectedMatrixPath $ExpectedMatrixPath -ExpectedMatrixSha256 $ExpectedMatrixSha256

  Invoke-HostEvidenceValidation -SourceFile $SourceFile -Target $target -TargetId $targetId -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -ExpectedMatrixPath $ExpectedMatrixPath -ExpectedMatrixSha256 $ExpectedMatrixSha256

  $destinationFile = Get-CanonicalEvidenceFile -TargetId $targetId -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy -Kind $kind
  $sourceHash = Get-Sha256 -Path $SourceFile
  $status = "imported"
  if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
    $destinationHash = Get-Sha256 -Path $destinationFile
    if ($destinationHash -eq $sourceHash) {
      $status = "unchanged"
    } elseif (-not $Force) {
      throw "Destination evidence already exists with different content: $destinationFile. Re-run with -Force to replace it."
    } else {
      $status = "overwritten"
    }
  }

  if ($status -ne "unchanged") {
    $destinationDirectory = Split-Path -Parent $destinationFile
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $SourceFile -Destination $destinationFile -Force
  }

  [pscustomobject]@{
    status = $status
    kind = $kind
    targetId = $targetId
    nextJsMode = $mode
    serviceManager = $serviceManager
    reverseProxy = $reverseProxy
    sourceFile = $SourceFile
    destinationFile = $destinationFile
    sha256 = $sourceHash
  }
}

function New-SelfTestEvidence {
  param(
    [string]$Path,
    [int]$RequiredMinimumUptimeHours,
    [string]$SupportMatrixPath = "",
    [string]$SupportMatrixSha256 = ""
  )

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  if ([string]::IsNullOrWhiteSpace($SupportMatrixPath)) {
    $SupportMatrixPath = Get-RepositoryRelativePath -Path $MatrixPath
  }
  if ([string]::IsNullOrWhiteSpace($SupportMatrixSha256)) {
    $SupportMatrixSha256 = Get-Sha256 -Path $MatrixPath
  }
  $requiredMinimumUptimeSeconds = [int64]$RequiredMinimumUptimeHours * 3600
  $status = [ordered]@{
    EvidenceSchemaVersion = 1
    EvidenceCollection = [ordered]@{
      Source = "node-enterprise-deploy-kit/status.ps1"
      Collector = "status.ps1"
      CollectorVersion = 1
      CollectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      WorkflowDispatch = [ordered]@{
        EvidenceName = "windows-server-2022-standalone-winsw-iis"
        ExpectedTargetId = "windows-server-2022"
        ExpectedNextJsMode = "standalone"
        ExpectedServiceManager = "winsw"
        ExpectedReverseProxy = "iis"
        MinimumUptimeHours = [string]$RequiredMinimumUptimeHours
        SupportMatrixPath = $SupportMatrixPath
        SupportMatrixSha256 = $SupportMatrixSha256
      }
      Ci = [ordered]@{
        IsCi = $true
        Provider = "github-actions"
        WorkflowName = "host-evidence"
        RunId = "123456789"
        RunAttempt = "1"
        EventName = "workflow_dispatch"
        RefName = "main"
        Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
      LiveHost = $true
      Synthetic = $false
      Mock = $false
      Sample = $false
    }
    SupportTargetId = "windows-server-2022"
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    AppName = "example-next-app"
    Platform = [ordered]@{
      Family = "windows"
      SupportTargetId = "windows-server-2022"
      OsCaption = "Microsoft Windows Server 2022 Datacenter"
      OsVersion = "10.0.20348"
      OsBuildNumber = "20348"
      ServiceManager = "winsw"
      AppFramework = "nextjs"
      NextjsDeploymentMode = "standalone"
    }
    Service = [ordered]@{
      Installed = $true
      Status = "Running"
      StartType = "Automatic"
      Win32State = "Running"
      Win32StartMode = "Auto"
      ProcessId = 1234
    }
    ServiceDefinition = [ordered]@{
      Checked = $true
      Manager = "winsw"
      DefinitionSource = "winsw-xml"
      DefinitionExists = $true
      ServiceWrapperMatchesConfig = $true
      NodeExeMatchesConfig = $true
      WorkingDirectoryMatchesConfig = $true
      ArgumentsMatchConfig = $true
    }
    Port = [ordered]@{
      Checked = $true
      Port = 3000
      Listening = $true
      OwnerReadable = $true
      OwnerProcessCount = 1
      ServiceProcessIdsKnown = $true
      OwnedByService = $true
    }
    Health = [ordered]@{
      Checked = $true
      Url = "http://127.0.0.1:3000/health"
      Status = "ok"
      StatusCode = 200
      ResponseMs = 12
      TimeoutSeconds = 10
    }
    Uptime = [ordered]@{
      HostUptimeSeconds = $requiredMinimumUptimeSeconds + 86400
      ServiceUptimeSeconds = $requiredMinimumUptimeSeconds
      MinimumUptimeHours = $RequiredMinimumUptimeHours
      MinimumSatisfied = $true
      ServiceStartKnown = $true
    }
    HealthMonitor = [ordered]@{
      Status = "ok"
      Scheduled = $true
      ScheduleType = "windows-task"
      TaskExists = $true
      TaskActionChecked = $true
      TaskActionUsesHealthCheckScript = $true
      TaskActionUsesConfigPath = $true
      TaskLastResult = 0
      TaskMissedRuns = 0
      StateExists = $true
      ConsecutiveFailures = 0
      LastSuccessAgeSeconds = 60
      LastSuccessFresh = $true
      LogExists = $true
      LogFailureCount = 0
      LogRestartCount = 0
    }
    NextJsRuntime = [ordered]@{
      Applicable = $true
      Status = "ok"
      AppFramework = "nextjs"
      Mode = "standalone"
      NodeVersion = "v20.11.1"
      MinimumNodeVersion = "20.9.0"
      NodeVersionSatisfied = $true
      NextVersion = "14.2.3"
      NextPackageJsonExists = $true
      RuntimeRootName = "example-next-app"
    }
    ReverseProxy = [ordered]@{
      Applicable = $true
      Mode = "iis"
      Status = "ok"
      ProbeUrl = "https://example.local/health"
      StatusCode = 200
      ResponseMs = 23
      Iis = [ordered]@{
        Applicable = $true
        ModuleAvailable = $true
        SiteName = "example-next-app"
        SiteExists = $true
        SiteState = "Started"
        SiteStarted = $true
        SitePathName = "example-next-app"
        ConfiguredSitePathName = "example-next-app"
        SitePathMatchesConfig = $true
        PublicPort = 443
        BindingProtocol = "https"
        BindingHostConfigured = $true
        BindingMatchesConfig = $true
        DuplicateBindingCount = 0
        DuplicateBindingConflict = $false
      }
    }
    DeploymentIdentity = [ordered]@{
      Status = "ok"
      AppDirectoryName = "example-next-app"
      DeploymentId = "example-deploy-001"
      NextBuildId = "example-build"
      PackageSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    Verdict = "Healthy"
    Critical = 0
    Warnings = 0
    Findings = @()
  }

  $artifactDirectory = Join-Path $Path "windows-server-2022-standalone-winsw-iis"
  New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
  $status | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $artifactDirectory "status.json") -Encoding UTF8
}

function Set-ObjectProperty {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Value
  )

  if ($Object.PSObject.Properties[$Name]) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-LocalCommandOnlySelfTestEvidence {
  param(
    [string]$Path,
    [int]$RequiredMinimumUptimeHours,
    [string]$SupportMatrixPath = "",
    [string]$SupportMatrixSha256 = ""
  )

  New-SelfTestEvidence -Path $Path -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -SupportMatrixPath $SupportMatrixPath -SupportMatrixSha256 $SupportMatrixSha256
  $windowsArtifactDirectory = Join-Path $Path "windows-server-2022-standalone-winsw-iis"
  $windowsStatusPath = Join-Path $windowsArtifactDirectory "status.json"
  $status = Get-Content -LiteralPath $windowsStatusPath -Raw | ConvertFrom-Json
  Remove-Item -LiteralPath $windowsArtifactDirectory -Recurse -Force

  $status.EvidenceCollection.Source = "node-enterprise-deploy-kit/status-node-app.sh"
  $status.EvidenceCollection.Collector = "scripts/linux/status-node-app.sh"
  if ($status.EvidenceCollection.PSObject.Properties["Ci"]) {
    $status.EvidenceCollection.PSObject.Properties.Remove("Ci")
  }

  $status.SupportTargetId = "freebsd"
  Set-ObjectProperty -Object $status -Name "ServiceName" -Value "example-next-app"
  Set-ObjectProperty -Object $status -Name "ServiceManager" -Value "bsdrc"
  Set-ObjectProperty -Object $status -Name "ServiceActiveStatus" -Value "active"
  Set-ObjectProperty -Object $status -Name "ServiceEnabledStatus" -Value "enabled"
  $status.Platform.Family = "freebsd"
  $status.Platform.SupportTargetId = "freebsd"
  $status.Platform.OsCaption = ""
  $status.Platform.ServiceManager = "bsdrc"
  Set-ObjectProperty -Object $status.Platform -Name "KernelName" -Value "FreeBSD"
  Set-ObjectProperty -Object $status.Platform -Name "OsPrettyName" -Value "FreeBSD"
  $status.ServiceDefinition = [ordered]@{
    Checked = $true
    Manager = "bsdrc"
    DefinitionSource = "bsdrc-init"
    DefinitionExists = $true
    NodeExeMatchesConfig = $true
    WorkingDirectoryMatchesConfig = $true
    ArgumentsMatchConfig = $true
    RunnerScriptMatchesConfig = $false
  }
  $status.HealthMonitor = [ordered]@{
    Status = "ok"
    Scheduled = $true
    ScheduleType = "cron"
    SchedulerChecked = $true
    SchedulerExists = $true
    SchedulerActive = $true
    SchedulerEnabled = $true
    SchedulerActiveStatus = "cron:active"
    SchedulerEnabledStatus = "persistent-entry"
    StateExists = $true
    ConsecutiveFailures = 0
    LastSuccessAgeSeconds = 60
    LastSuccessFresh = $true
    LogExists = $true
    LogFailureCount = 0
    LogRestartCount = 0
  }
  $status.NextJsRuntime.Mode = "standalone"
  $status.ReverseProxy = [ordered]@{
    Applicable = $true
    Mode = "nginx"
    Status = "ok"
    ProbeUrl = "http://127.0.0.1:80/health"
    StatusCode = 200
    ResponseMs = 23
    Config = [ordered]@{
      Applicable = $true
      PathName = "example-next-app.conf"
      DirectoryName = "conf.d"
      Exists = $true
      ManagedMarkerFound = $true
      ExpectedPort = "80"
    }
  }

  $artifactDirectory = Join-Path $Path "freebsd-standalone-bsdrc-nginx"
  New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
  $status | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $artifactDirectory "status.json") -Encoding UTF8
}

function New-FallbackServiceOnlySelfTestEvidence {
  param(
    [string]$Path,
    [int]$RequiredMinimumUptimeHours,
    [string]$SupportMatrixPath = "",
    [string]$SupportMatrixSha256 = ""
  )

  New-SelfTestEvidence -Path $Path -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours -SupportMatrixPath $SupportMatrixPath -SupportMatrixSha256 $SupportMatrixSha256
  if ([string]::IsNullOrWhiteSpace($SupportMatrixPath)) {
    $SupportMatrixPath = Get-RepositoryRelativePath -Path $MatrixPath
  }
  if ([string]::IsNullOrWhiteSpace($SupportMatrixSha256)) {
    $SupportMatrixSha256 = Get-Sha256 -Path $MatrixPath
  }
  $sourceArtifactDirectory = Join-Path $Path "windows-server-2022-standalone-winsw-iis"
  $sourceStatusPath = Join-Path $sourceArtifactDirectory "status.json"
  $status = Get-Content -LiteralPath $sourceStatusPath -Raw | ConvertFrom-Json
  Remove-Item -LiteralPath $sourceArtifactDirectory -Recurse -Force

  $status.SupportTargetId = "windows-10"
  $status.Platform.SupportTargetId = "windows-10"
  $status.Platform.OsCaption = "Microsoft Windows 10 Pro"
  $status.Platform.OsVersion = "10.0.19045"
  $status.Platform.OsBuildNumber = "19045"
  $status.Platform.ServiceManager = "pm2"
  $status.EvidenceCollection.WorkflowDispatch = [ordered]@{
    EvidenceName = "windows-10-standalone-pm2-none-fallback"
    ExpectedTargetId = "windows-10"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "pm2"
    ExpectedReverseProxy = "none"
    MinimumUptimeHours = [string]$RequiredMinimumUptimeHours
    SupportMatrixPath = $SupportMatrixPath
    SupportMatrixSha256 = $SupportMatrixSha256
  }
  $status.ServiceDefinition = [ordered]@{
    Checked = $true
    Manager = "pm2"
    DefinitionSource = "pm2-process-list"
    DefinitionExists = $true
    ServiceWrapperMatchesConfig = $null
    NodeExeMatchesConfig = $true
    WorkingDirectoryMatchesConfig = $true
    ArgumentsMatchConfig = $true
  }
  $status.ReverseProxy = [ordered]@{
    Applicable = $false
    Mode = "none"
    Status = "not-applicable"
  }

  $artifactDirectory = Join-Path $Path "windows-10-standalone-pm2-none-fallback"
  New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
  $status | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $artifactDirectory "status.json") -Encoding UTF8
}

function Invoke-SelfTest {
  $selfTestRoot = Join-Path $RepoRoot ".tmp\host-evidence-import-selftest-$([Guid]::NewGuid().ToString('N'))"
  $artifactRoot = Join-Path $selfTestRoot "downloaded-artifacts"
  $importRoot = Join-Path $selfTestRoot "evidence"
  & (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
  $matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
  $requiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Matrix $matrix
  $matrixRelativePath = Get-RepositoryRelativePath -Path $MatrixPath
  $matrixSha256 = Get-Sha256 -Path $MatrixPath
  New-SelfTestEvidence -Path $artifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours

  $firstResult = @(& $PSCommandPath -ArtifactPath $artifactRoot -EvidencePath $importRoot -MatrixPath $MatrixPath -PassThru)
  if ($firstResult.Count -ne 1 -or $firstResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: first import did not import exactly one artifact."
  }
  $expectedDestination = Join-Path $importRoot "windows-server-2022\standalone-winsw-iis.json"
  if (-not (Test-Path -LiteralPath $expectedDestination -PathType Leaf)) {
    throw "Host evidence import self-test failed: expected destination was not created."
  }

  $fallbackServiceOnlyArtifactRoot = Join-Path $selfTestRoot "fallback-service-only-artifacts"
  $fallbackServiceOnlyImportRoot = Join-Path $selfTestRoot "fallback-service-only-evidence"
  New-FallbackServiceOnlySelfTestEvidence -Path $fallbackServiceOnlyArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $fallbackServiceOnlyResult = @(& $PSCommandPath -ArtifactPath $fallbackServiceOnlyArtifactRoot -EvidencePath $fallbackServiceOnlyImportRoot -MatrixPath $MatrixPath -PassThru)
  if ($fallbackServiceOnlyResult.Count -ne 1 -or $fallbackServiceOnlyResult[0].kind -ne "fallback") {
    throw "Host evidence import self-test failed: fallback service-only import should produce one fallback row."
  }
  $fallbackServiceOnlyDestination = Join-Path $fallbackServiceOnlyImportRoot "windows-10\standalone-pm2-none-fallback.json"
  if (-not (Test-Path -LiteralPath $fallbackServiceOnlyDestination -PathType Leaf)) {
    throw "Host evidence import self-test failed: fallback service-only destination was not created."
  }

  $secondResult = @(& $PSCommandPath -ArtifactPath $artifactRoot -EvidencePath $importRoot -MatrixPath $MatrixPath -PassThru)
  if ($secondResult.Count -ne 1 -or $secondResult[0].status -ne "unchanged") {
    throw "Host evidence import self-test failed: duplicate import should be unchanged."
  }

  $targetMismatchArtifactRoot = Join-Path $selfTestRoot "target-mismatch-artifacts"
  $targetMismatchImportRoot = Join-Path $selfTestRoot "target-mismatch-evidence"
  New-SelfTestEvidence -Path $targetMismatchArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $targetMismatchStatusPath = Join-Path $targetMismatchArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $targetMismatchStatus = Get-Content -LiteralPath $targetMismatchStatusPath -Raw | ConvertFrom-Json
  $targetMismatchStatus.SupportTargetId = "windows-server-2019"
  $targetMismatchStatus.Platform.SupportTargetId = "windows-server-2019"
  $targetMismatchStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $targetMismatchStatusPath -Encoding UTF8
  $failedTargetCorroboration = $false
  try {
    & $PSCommandPath -ArtifactPath $targetMismatchArtifactRoot -EvidencePath $targetMismatchImportRoot -MatrixPath $MatrixPath -SkipValidation -PassThru | Out-Null
  } catch {
    $failedTargetCorroboration = ($_.Exception.Message -match "not corroborated by platform metadata")
  }
  if (-not $failedTargetCorroboration) {
    throw "Host evidence import self-test failed: target-mismatched evidence should be rejected even with -SkipValidation."
  }

  $zipPath = Join-Path $selfTestRoot "downloaded-artifacts.zip"
  Compress-Archive -Path (Join-Path $artifactRoot "*") -DestinationPath $zipPath -Force
  $zipImportRoot = Join-Path $selfTestRoot "zip-evidence"
  $zipResult = @(& $PSCommandPath -ArtifactPath $zipPath -EvidencePath $zipImportRoot -MatrixPath $MatrixPath -PassThru)
  if ($zipResult.Count -ne 1 -or $zipResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: zip artifact import should import exactly one artifact."
  }

  $zipDownloadRoot = Join-Path $selfTestRoot "zip-downloads"
  New-Item -ItemType Directory -Path $zipDownloadRoot -Force | Out-Null
  Copy-Item -LiteralPath $zipPath -Destination (Join-Path $zipDownloadRoot "host-evidence-download.zip") -Force
  $zipDirectoryImportRoot = Join-Path $selfTestRoot "zip-directory-evidence"
  $zipDirectoryResult = @(& $PSCommandPath -ArtifactPath $zipDownloadRoot -EvidencePath $zipDirectoryImportRoot -MatrixPath $MatrixPath -PassThru)
  if ($zipDirectoryResult.Count -ne 1 -or $zipDirectoryResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: directory of zip artifacts should import exactly one artifact."
  }

  $workflowCapableLocalArtifactRoot = Join-Path $selfTestRoot "workflow-capable-local-artifacts"
  $workflowCapableLocalImportRoot = Join-Path $selfTestRoot "workflow-capable-local-evidence"
  New-SelfTestEvidence -Path $workflowCapableLocalArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $workflowCapableLocalStatusPath = Join-Path $workflowCapableLocalArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $workflowCapableLocalStatus = Get-Content -LiteralPath $workflowCapableLocalStatusPath -Raw | ConvertFrom-Json
  $workflowCapableLocalStatus.EvidenceCollection.PSObject.Properties.Remove("Ci")
  $workflowCapableLocalStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $workflowCapableLocalStatusPath -Encoding UTF8
  $failedWithoutWorkflowProvenance = $false
  try {
    & $PSCommandPath -ArtifactPath $workflowCapableLocalArtifactRoot -EvidencePath $workflowCapableLocalImportRoot -MatrixPath $MatrixPath -PassThru | Out-Null
  } catch {
    $failedWithoutWorkflowProvenance = ($_.Exception.Message -match "must prove controlled host-evidence workflow collection")
  }
  if (-not $failedWithoutWorkflowProvenance) {
    throw "Host evidence import self-test failed: missing workflow provenance should be rejected by default."
  }
  $failedAllowLocalForWorkflowCapable = $false
  try {
    & $PSCommandPath -ArtifactPath $workflowCapableLocalArtifactRoot -EvidencePath $workflowCapableLocalImportRoot -MatrixPath $MatrixPath -AllowLocalCollection -PassThru | Out-Null
  } catch {
    $failedAllowLocalForWorkflowCapable = ($_.Exception.Message -match "must prove controlled host-evidence workflow collection")
  }
  if (-not $failedAllowLocalForWorkflowCapable) {
    throw "Host evidence import self-test failed: -AllowLocalCollection should not bypass workflow provenance for workflow-capable evidence."
  }

  $badWorkflowCiArtifactRoot = Join-Path $selfTestRoot "bad-workflow-ci-artifacts"
  $badWorkflowCiImportRoot = Join-Path $selfTestRoot "bad-workflow-ci-evidence"
  New-SelfTestEvidence -Path $badWorkflowCiArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $badWorkflowCiStatusPath = Join-Path $badWorkflowCiArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $badWorkflowCiStatus = Get-Content -LiteralPath $badWorkflowCiStatusPath -Raw | ConvertFrom-Json
  $badWorkflowCiStatus.EvidenceCollection.Ci.RunId = "not-a-run-id"
  $badWorkflowCiStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $badWorkflowCiStatusPath -Encoding UTF8
  $failedBadWorkflowCi = $false
  try {
    & $PSCommandPath -ArtifactPath $badWorkflowCiArtifactRoot -EvidencePath $badWorkflowCiImportRoot -MatrixPath $MatrixPath -SkipValidation -PassThru | Out-Null
  } catch {
    $failedBadWorkflowCi = ($_.Exception.Message -match "evidenceCollection\.ci\.runId must be numeric")
  }
  if (-not $failedBadWorkflowCi) {
    throw "Host evidence import self-test failed: malformed workflow CI metadata should be rejected even with -SkipValidation."
  }

  $missingWorkflowRefArtifactRoot = Join-Path $selfTestRoot "missing-workflow-ref-artifacts"
  $missingWorkflowRefImportRoot = Join-Path $selfTestRoot "missing-workflow-ref-evidence"
  New-SelfTestEvidence -Path $missingWorkflowRefArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $missingWorkflowRefStatusPath = Join-Path $missingWorkflowRefArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $missingWorkflowRefStatus = Get-Content -LiteralPath $missingWorkflowRefStatusPath -Raw | ConvertFrom-Json
  $missingWorkflowRefStatus.EvidenceCollection.Ci.RefName = ""
  $missingWorkflowRefStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $missingWorkflowRefStatusPath -Encoding UTF8
  $failedMissingWorkflowRef = $false
  try {
    & $PSCommandPath -ArtifactPath $missingWorkflowRefArtifactRoot -EvidencePath $missingWorkflowRefImportRoot -MatrixPath $MatrixPath -SkipValidation -PassThru | Out-Null
  } catch {
    $failedMissingWorkflowRef = ($_.Exception.Message -match "evidenceCollection\.ci\.refName is required")
  }
  if (-not $failedMissingWorkflowRef) {
    throw "Host evidence import self-test failed: missing workflow refName should be rejected even with -SkipValidation."
  }

  $badWorkflowDispatchArtifactRoot = Join-Path $selfTestRoot "bad-workflow-dispatch-artifacts"
  $badWorkflowDispatchImportRoot = Join-Path $selfTestRoot "bad-workflow-dispatch-evidence"
  New-SelfTestEvidence -Path $badWorkflowDispatchArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $badWorkflowDispatchStatusPath = Join-Path $badWorkflowDispatchArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $badWorkflowDispatchStatus = Get-Content -LiteralPath $badWorkflowDispatchStatusPath -Raw | ConvertFrom-Json
  $badWorkflowDispatchStatus.EvidenceCollection.WorkflowDispatch.ExpectedTargetId = "windows-server-2019"
  $badWorkflowDispatchStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $badWorkflowDispatchStatusPath -Encoding UTF8
  $failedBadWorkflowDispatch = $false
  try {
    & $PSCommandPath -ArtifactPath $badWorkflowDispatchArtifactRoot -EvidencePath $badWorkflowDispatchImportRoot -MatrixPath $MatrixPath -SkipValidation -PassThru | Out-Null
  } catch {
    $failedBadWorkflowDispatch = ($_.Exception.Message -match "workflowDispatch\.expectedTargetId must match imported target")
  }
  if (-not $failedBadWorkflowDispatch) {
    throw "Host evidence import self-test failed: mismatched workflow dispatch metadata should be rejected even with -SkipValidation."
  }

  $badWorkflowMatrixArtifactRoot = Join-Path $selfTestRoot "bad-workflow-matrix-artifacts"
  $badWorkflowMatrixImportRoot = Join-Path $selfTestRoot "bad-workflow-matrix-evidence"
  New-SelfTestEvidence -Path $badWorkflowMatrixArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -SupportMatrixPath $matrixRelativePath -SupportMatrixSha256 $matrixSha256
  $badWorkflowMatrixStatusPath = Join-Path $badWorkflowMatrixArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $badWorkflowMatrixStatus = Get-Content -LiteralPath $badWorkflowMatrixStatusPath -Raw | ConvertFrom-Json
  $badWorkflowMatrixStatus.EvidenceCollection.WorkflowDispatch.SupportMatrixSha256 = ("0" * 64)
  $badWorkflowMatrixStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $badWorkflowMatrixStatusPath -Encoding UTF8
  $failedBadWorkflowMatrix = $false
  try {
    & $PSCommandPath -ArtifactPath $badWorkflowMatrixArtifactRoot -EvidencePath $badWorkflowMatrixImportRoot -MatrixPath $MatrixPath -SkipValidation -PassThru | Out-Null
  } catch {
    $failedBadWorkflowMatrix = ($_.Exception.Message -match "workflowDispatch\.supportMatrixSha256 must match imported support matrix SHA256")
  }
  if (-not $failedBadWorkflowMatrix) {
    throw "Host evidence import self-test failed: mismatched workflow support matrix SHA256 should be rejected even with -SkipValidation."
  }

  $localOnlyArtifactRoot = Join-Path $selfTestRoot "local-only-artifacts"
  $localOnlyImportRoot = Join-Path $selfTestRoot "local-only-evidence"
  New-LocalCommandOnlySelfTestEvidence -Path $localOnlyArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $localOnlyResult = @(& $PSCommandPath -ArtifactPath $localOnlyArtifactRoot -EvidencePath $localOnlyImportRoot -MatrixPath $MatrixPath -AllowLocalCollection -PassThru)
  if ($localOnlyResult.Count -ne 1 -or $localOnlyResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: -AllowLocalCollection should import local-command-only evidence."
  }
  if ($localOnlyResult[0].targetId -ne "freebsd" -or $localOnlyResult[0].kind -ne "strict") {
    throw "Host evidence import self-test failed: local-command-only import should preserve FreeBSD strict evidence dimensions."
  }

  $statusPath = Join-Path $artifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  $status.DeploymentIdentity.DeploymentId = "example-deploy-002"
  $status | ConvertTo-Json -Depth 10 | Set-Content -Path $statusPath -Encoding UTF8
  $failedWithoutForce = $false
  try {
    & $PSCommandPath -ArtifactPath $artifactRoot -EvidencePath $importRoot -MatrixPath $MatrixPath -PassThru | Out-Null
  } catch {
    $failedWithoutForce = ($_.Exception.Message -match "Destination evidence already exists")
  }
  if (-not $failedWithoutForce) {
    throw "Host evidence import self-test failed: changed destination should require -Force."
  }

  $forcedResult = @(& $PSCommandPath -ArtifactPath $artifactRoot -EvidencePath $importRoot -MatrixPath $MatrixPath -Force -PassThru)
  if ($forcedResult.Count -ne 1 -or $forcedResult[0].status -ne "overwritten") {
    throw "Host evidence import self-test failed: -Force should overwrite changed evidence."
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
  throw "ArtifactPath is required unless -SelfTest is used."
}
if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$requiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Matrix $matrix
$matrixRelativePath = Get-RepositoryRelativePath -Path $MatrixPath
$matrixSha256 = Get-Sha256 -Path $MatrixPath
$sourceFiles = @(Get-ArtifactStatusFiles -Path $ArtifactPath)
if ($sourceFiles.Count -eq 0) {
  throw "No status.json files were found under ArtifactPath: $ArtifactPath"
}

$results = foreach ($sourceFile in $sourceFiles) {
  Import-OneEvidenceFile -SourceFile $sourceFile.FullName -Matrix $matrix -RequiredMinimumUptimeHours $requiredMinimumUptimeHours -ExpectedMatrixPath $matrixRelativePath -ExpectedMatrixSha256 $matrixSha256
}

if ($PassThru) {
  $results
} else {
  Write-Host ""
  Write-Host "==> Host evidence artifact import"
  $results | Sort-Object targetId, nextJsMode, serviceManager, reverseProxy | Format-Table status, kind, targetId, nextJsMode, serviceManager, reverseProxy, destinationFile -AutoSize
}
