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

function Test-TruthyValue {
  param($Value)

  if ($Value -is [bool]) { return [bool]$Value }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  return ($text -in @("true", "1", "yes"))
}

function Assert-HostEvidenceWorkflowCollection {
  param(
    [object]$Evidence,
    [string]$SourceFile
  )

  if ($AllowLocalCollection) { return }

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
  if ($ci.sha -notmatch '^[a-fA-F0-9]{40}$') {
    $issues.Add("evidenceCollection.ci.sha must be a 40-character git SHA") | Out-Null
  }
  if ($issues.Count -gt 0) {
    throw "Imported workflow artifact must prove controlled host-evidence workflow collection: $SourceFile. $($issues -join '; '). Use -AllowLocalCollection only for explicitly local evidence."
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
    if ($serviceManagers -notcontains $ServiceManager) {
      throw "Service-only evidence for '$TargetId' must use a declared strict service manager."
    }
    return "service-only"
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
    [string]$TargetId,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours
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
  if ($ReverseProxy -ne "none") {
    $validationArgs.RequireReverseProxy = $true
  }
  if (-not $AllowWarnings) {
    $validationArgs.FailOnWarnings = $true
  }

  & (Join-Path $ScriptDir "Test-HostEvidence.ps1") @validationArgs | Out-Null
}

function Import-OneEvidenceFile {
  param(
    [string]$SourceFile,
    [object]$Matrix,
    [int]$RequiredMinimumUptimeHours
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
  Assert-HostEvidenceWorkflowCollection -Evidence $evidence -SourceFile $SourceFile

  Invoke-HostEvidenceValidation -SourceFile $SourceFile -TargetId $targetId -Mode $mode -ServiceManager $serviceManager -ReverseProxy $reverseProxy -RequiredMinimumUptimeHours $RequiredMinimumUptimeHours

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
    [int]$RequiredMinimumUptimeHours
  )

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $requiredMinimumUptimeSeconds = [int64]$RequiredMinimumUptimeHours * 3600
  $status = [ordered]@{
    EvidenceSchemaVersion = 1
    EvidenceCollection = [ordered]@{
      Source = "node-enterprise-deploy-kit/status.ps1"
      Collector = "status.ps1"
      CollectorVersion = 1
      CollectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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

function Invoke-SelfTest {
  $selfTestRoot = Join-Path $RepoRoot ".tmp\host-evidence-import-selftest-$([Guid]::NewGuid().ToString('N'))"
  $artifactRoot = Join-Path $selfTestRoot "downloaded-artifacts"
  $importRoot = Join-Path $selfTestRoot "evidence"
  & (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
  $matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
  $requiredMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Matrix $matrix
  New-SelfTestEvidence -Path $artifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours

  $firstResult = @(& $PSCommandPath -ArtifactPath $artifactRoot -EvidencePath $importRoot -MatrixPath $MatrixPath -PassThru)
  if ($firstResult.Count -ne 1 -or $firstResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: first import did not import exactly one artifact."
  }
  $expectedDestination = Join-Path $importRoot "windows-server-2022\standalone-winsw-iis.json"
  if (-not (Test-Path -LiteralPath $expectedDestination -PathType Leaf)) {
    throw "Host evidence import self-test failed: expected destination was not created."
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

  $localOnlyArtifactRoot = Join-Path $selfTestRoot "local-only-artifacts"
  $localOnlyImportRoot = Join-Path $selfTestRoot "local-only-evidence"
  New-SelfTestEvidence -Path $localOnlyArtifactRoot -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
  $localOnlyStatusPath = Join-Path $localOnlyArtifactRoot "windows-server-2022-standalone-winsw-iis\status.json"
  $localOnlyStatus = Get-Content -LiteralPath $localOnlyStatusPath -Raw | ConvertFrom-Json
  $localOnlyStatus.EvidenceCollection.PSObject.Properties.Remove("Ci")
  $localOnlyStatus | ConvertTo-Json -Depth 10 | Set-Content -Path $localOnlyStatusPath -Encoding UTF8
  $failedWithoutWorkflowProvenance = $false
  try {
    & $PSCommandPath -ArtifactPath $localOnlyArtifactRoot -EvidencePath $localOnlyImportRoot -MatrixPath $MatrixPath -PassThru | Out-Null
  } catch {
    $failedWithoutWorkflowProvenance = ($_.Exception.Message -match "must prove controlled host-evidence workflow collection")
  }
  if (-not $failedWithoutWorkflowProvenance) {
    throw "Host evidence import self-test failed: missing workflow provenance should be rejected by default."
  }
  $localOnlyResult = @(& $PSCommandPath -ArtifactPath $localOnlyArtifactRoot -EvidencePath $localOnlyImportRoot -MatrixPath $MatrixPath -AllowLocalCollection -PassThru)
  if ($localOnlyResult.Count -ne 1 -or $localOnlyResult[0].status -ne "imported") {
    throw "Host evidence import self-test failed: -AllowLocalCollection should import explicit local evidence."
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
$sourceFiles = @(Get-ArtifactStatusFiles -Path $ArtifactPath)
if ($sourceFiles.Count -eq 0) {
  throw "No status.json files were found under ArtifactPath: $ArtifactPath"
}

$results = foreach ($sourceFile in $sourceFiles) {
  Import-OneEvidenceFile -SourceFile $sourceFile.FullName -Matrix $matrix -RequiredMinimumUptimeHours $requiredMinimumUptimeHours
}

if ($PassThru) {
  $results
} else {
  Write-Host ""
  Write-Host "==> Host evidence artifact import"
  $results | Sort-Object targetId, nextJsMode, serviceManager, reverseProxy | Format-Table status, kind, targetId, nextJsMode, serviceManager, reverseProxy, destinationFile -AutoSize
}
