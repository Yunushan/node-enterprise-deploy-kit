param(
  [string]$EvidencePath = "",
  [string]$MatrixPath = "",
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$IncludeServiceOnly,
  [switch]$IncludeFallback,
  [switch]$AllowWarnings,
  [ValidateSet("Table", "Json", "Csv")]
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
if (-not [string]::IsNullOrWhiteSpace($EvidencePath) -and -not [System.IO.Path]::IsPathRooted($EvidencePath)) {
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

function Get-OptionalPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $null
}

function Get-PrimaryEvidenceTarget {
  param([object]$Evidence)

  $explicit = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if ($explicit) { return (Normalize-Token $explicit) }

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $family = Normalize-Token (Get-StringValue -Object $platform -Names @("Family", "family"))
  $osCaption = Get-StringValue -Object $platform -Names @("OsCaption", "osCaption")
  $osId = Normalize-Token (Get-StringValue -Object $platform -Names @("OsId", "osId"))
  $kernelName = Normalize-Token (Get-StringValue -Object $platform -Names @("KernelName", "kernelName"))
  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")

  if ($osCaption -match 'Windows Server') {
    if ($osCaption -match '2012\s+R2') { return "windows-server-2012-r2" }
    foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
      if ($osCaption -match $year) { return "windows-server-$year" }
    }
    return "windows-server"
  }
  if ($osCaption -match 'Windows\s+10' -and $osCaption -notmatch 'Windows Server') { return "windows-10" }
  if ($osCaption -match 'Windows\s+11' -and $osCaption -notmatch 'Windows Server') { return "windows-11" }
  if ($prettyName -match 'CentOS Stream') { return "centos-stream" }
  if ($prettyName -match 'Oracle Linux') { return "oracle-linux" }
  if ($prettyName -match 'Linux Mint') { return "linux-mint" }

  switch ($osId) {
    "linuxmint" { return "linux-mint" }
    "ol" { return "oracle-linux" }
    "redhat" { return "rhel" }
    "red-hat" { return "rhel" }
    "mac-os" { return "macos" }
  }

  if ($osId -in @("ubuntu", "debian", "rhel", "centos", "rocky", "almalinux", "fedora", "alpine", "macos", "freebsd", "openbsd", "netbsd")) {
    return $osId
  }
  if ($family -in @("macos", "freebsd", "openbsd", "netbsd")) { return $family }
  if ($kernelName -eq "darwin") { return "macos" }
  return ""
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
  return (Normalize-ReverseProxy $mode)
}

function Get-EvidenceGeneratedAt {
  param([object]$Evidence)
  return (Get-StringValue -Object $Evidence -Names @("GeneratedAtUtc", "generatedAtUtc"))
}

function Get-EvidenceCollectionEvidence {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  return [pscustomobject]@{
    source = Get-StringValue -Object $collection -Names @("Source", "source")
    collector = Get-StringValue -Object $collection -Names @("Collector", "collector")
    collectorVersion = Get-IntegerValue -Object $collection -Names @("CollectorVersion", "collectorVersion")
    liveHost = Get-BooleanValue -Object $collection -Names @("LiveHost", "liveHost", "CapturedFromLiveHost", "capturedFromLiveHost") -Default $null
    synthetic = Get-BooleanValue -Object $collection -Names @("Synthetic", "synthetic") -Default $null
    mock = Get-BooleanValue -Object $collection -Names @("Mock", "mock") -Default $null
    sample = Get-BooleanValue -Object $collection -Names @("Sample", "sample") -Default $null
    topLevelSynthetic = Get-BooleanValue -Object $Evidence -Names @("Synthetic", "synthetic") -Default $false
    topLevelMock = Get-BooleanValue -Object $Evidence -Names @("Mock", "mock") -Default $false
    topLevelSample = Get-BooleanValue -Object $Evidence -Names @("Sample", "sample") -Default $false
  }
}

function Test-SupportedEvidenceCollector {
  param([object]$Collection)

  $source = Normalize-Token $Collection.source
  $collector = Normalize-Token $Collection.collector
  $allowed = @(
    "node-enterprise-deploy-kit-status-ps1",
    "node-enterprise-deploy-kit-status-node-app-sh",
    "status-ps1",
    "scripts-linux-status-node-app-sh",
    "status-node-app-sh"
  )
  return (($source -in $allowed) -or ($collector -in $allowed))
}

function Test-LiveEvidenceCollection {
  param([object]$Collection)

  if (-not $Collection.source -and -not $Collection.collector) { return $false }
  if (-not (Test-SupportedEvidenceCollector -Collection $Collection)) { return $false }
  if ($null -eq $Collection.collectorVersion -or $Collection.collectorVersion -lt 1) { return $false }
  if ($Collection.liveHost -ne $true) { return $false }
  if ($Collection.synthetic -ne $false -or $Collection.mock -ne $false -or $Collection.sample -ne $false) { return $false }
  if ($Collection.topLevelSynthetic -eq $true -or $Collection.topLevelMock -eq $true -or $Collection.topLevelSample -eq $true) { return $false }
  return $true
}

function Get-DisplayPath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($RepoRoot.Length + 1)
  }
  return $fullPath
}

function Get-EvidenceRecords {
  param([string]$Path)

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.json")
  foreach ($file in $files) {
    try {
      $evidence = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      $collection = Get-EvidenceCollectionEvidence -Evidence $evidence
      [pscustomobject]@{
        file = $file.FullName
        relativeFile = Get-DisplayPath -Path $file.FullName
        targetId = Get-PrimaryEvidenceTarget -Evidence $evidence
        nextJsMode = Get-NextJsMode -Evidence $evidence
        serviceManager = Get-ServiceManager -Evidence $evidence
        reverseProxy = Get-ReverseProxyMode -Evidence $evidence
        generatedAtUtc = Get-EvidenceGeneratedAt -Evidence $evidence
        verdict = Get-StringValue -Object $evidence -Names @("Verdict", "verdict")
        critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
        warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
        liveEvidenceCollection = Test-LiveEvidenceCollection -Collection $collection
        parseError = ""
      }
    } catch {
      [pscustomobject]@{
        file = $file.FullName
        relativeFile = Get-DisplayPath -Path $file.FullName
        targetId = ""
        nextJsMode = ""
        serviceManager = ""
        reverseProxy = ""
        generatedAtUtc = ""
        verdict = ""
        critical = $null
        warnings = $null
        liveEvidenceCollection = $false
        parseError = $_.Exception.Message
      }
    }
  }
}

function Test-RecordHealthy {
  param([object]$Record)

  if ($Record.parseError) { return $false }
  if ($Record.verdict -eq "Critical") { return $false }
  if ($null -eq $Record.critical -or $Record.critical -gt 0) { return $false }
  if (-not $AllowWarnings -and ($null -eq $Record.warnings -or $Record.warnings -gt 0)) { return $false }
  if ($Record.liveEvidenceCollection -ne $true) { return $false }
  if ($MaxEvidenceAgeDays -gt 0) {
    if (-not $Record.generatedAtUtc) { return $false }
    try {
      $generatedDate = [DateTime]::Parse([string]$Record.generatedAtUtc).ToUniversalTime()
      if (((Get-Date).ToUniversalTime() - $generatedDate).TotalDays -gt $MaxEvidenceAgeDays) {
        return $false
      }
    } catch {
      return $false
    }
  }
  return $true
}

function New-ExpectedEntry {
  param(
    [object]$Target,
    [string]$Mode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [string]$Kind
  )
  [pscustomobject]@{
    kind = $Kind
    targetId = Normalize-Token ([string]$Target.id)
    nextJsMode = Normalize-Token $Mode
    serviceManager = Normalize-Token $ServiceManager
    reverseProxy = Normalize-ReverseProxy $ReverseProxy
  }
}

function Get-ExpectedEntries {
  param([object[]]$Targets)

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($target in $Targets) {
    $modes = @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $serviceManagers = @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $fallbackManagers = @(Get-ArrayValue (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers") | ForEach-Object { Normalize-Token ([string]$_) } | Where-Object { $_ })
    $proxies = @(Get-ArrayValue $target.reverseProxies | ForEach-Object { Normalize-ReverseProxy ([string]$_) } | Where-Object { $_ })
    $concreteProxies = @($proxies | Where-Object { $_ -ne "none" })
    $serviceOnlyProxies = @($proxies | Where-Object { $_ -eq "none" })

    foreach ($mode in $modes) {
      foreach ($serviceManager in $serviceManagers) {
        foreach ($proxy in $concreteProxies) {
          $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "strict")) | Out-Null
        }
        if ($IncludeServiceOnly) {
          foreach ($proxy in $serviceOnlyProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $serviceManager -ReverseProxy $proxy -Kind "service-only")) | Out-Null
          }
        }
      }
      if ($IncludeFallback) {
        foreach ($fallbackManager in $fallbackManagers) {
          foreach ($proxy in $concreteProxies) {
            $entries.Add((New-ExpectedEntry -Target $target -Mode $mode -ServiceManager $fallbackManager -ReverseProxy $proxy -Kind "fallback")) | Out-Null
          }
        }
      }
    }
  }
  return @($entries | ForEach-Object { $_ })
}

function New-SelfTestEvidence {
  param(
    [string]$Path,
    [object[]]$ExpectedEntries
  )
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  foreach ($entry in $ExpectedEntries) {
    $fileName = "$($entry.kind)-$($entry.targetId)-$($entry.nextJsMode)-$($entry.serviceManager)-$($entry.reverseProxy).json"
    $targetId = [string]$entry.targetId
    $serviceManager = [string]$entry.serviceManager
    $reverseProxy = [string]$entry.reverseProxy
    $nextJsMode = [string]$entry.nextJsMode
    $targetIsWindows = $targetId -like "windows*"
    $collection = if (([string]$entry.targetId) -like "windows*") {
      [ordered]@{
        source = "node-enterprise-deploy-kit/status.ps1"
        collector = "status.ps1"
        collectorVersion = 1
        liveHost = $true
        synthetic = $false
        mock = $false
        sample = $false
      }
    } else {
      [ordered]@{
        source = "node-enterprise-deploy-kit/status-node-app.sh"
        collector = "scripts/linux/status-node-app.sh"
        collectorVersion = 1
        liveHost = $true
        synthetic = $false
        mock = $false
        sample = $false
      }
    }
    $scheduleType = if ($targetIsWindows) {
      "windows-task"
    } elseif ($serviceManager -eq "systemd") {
      "systemd-timer"
    } elseif ($serviceManager -eq "launchd") {
      "launchd-timer"
    } else {
      "cron"
    }
    $monitor = [ordered]@{
      status = "ok"
      scheduled = $true
      scheduleType = $scheduleType
      stateExists = $true
      consecutiveFailures = 0
      lastSuccessAgeSeconds = 60
      lastSuccessFresh = $true
      logExists = $true
      logFailureCount = 0
      logRestartCount = 0
    }
    if ($scheduleType -eq "windows-task") {
      $monitor["taskExists"] = $true
      $monitor["taskLastResult"] = 0
      $monitor["taskMissedRuns"] = 0
    } else {
      $monitor["schedulerChecked"] = $true
      $monitor["schedulerExists"] = $true
      $monitor["schedulerActive"] = $true
      $monitor["schedulerEnabled"] = $true
      $monitor["schedulerActiveStatus"] = "active"
      $monitor["schedulerEnabledStatus"] = if ($scheduleType -eq "cron") { "persistent-entry" } else { "enabled" }
    }
    $proxyEvidence = if ($reverseProxy -eq "none") {
      [ordered]@{
        applicable = $false
        mode = "none"
        status = "not-applicable"
      }
    } elseif ($reverseProxy -eq "iis") {
      [ordered]@{
        applicable = $true
        mode = "iis"
        status = "ok"
        probeUrl = "https://example.local/health"
        statusCode = 200
        iis = [ordered]@{
          applicable = $true
          moduleAvailable = $true
          siteExists = $true
          sitePathMatchesConfig = $true
          bindingMatchesConfig = $true
          duplicateBindingConflict = $false
        }
      }
    } else {
      [ordered]@{
        applicable = $true
        mode = $reverseProxy
        status = "ok"
        probeUrl = "https://example.local/health"
        statusCode = 200
        config = [ordered]@{
          applicable = $true
          pathName = "example-next-app.conf"
          directoryName = "conf.d"
          exists = $true
          managedMarkerFound = $true
          expectedPort = "80"
        }
      }
    }
    $platformFamily = if ($targetIsWindows) {
      "windows"
    } elseif ($targetId -eq "macos") {
      "macos"
    } elseif ($targetId -in @("freebsd", "openbsd", "netbsd")) {
      $targetId
    } else {
      "linux"
    }
    $kernelName = switch ($platformFamily) {
      "windows" { "Windows" }
      "macos" { "Darwin" }
      "freebsd" { "FreeBSD" }
      "openbsd" { "OpenBSD" }
      "netbsd" { "NetBSD" }
      default { "Linux" }
    }
    $data = [ordered]@{
      evidenceSchemaVersion = 1
      evidenceCollection = $collection
      supportTargetId = $targetId
      generatedAtUtc = $now
      appName = "example-next-app"
      serviceName = "example-next-app"
      serviceManager = $serviceManager
      serviceActiveStatus = "active"
      serviceEnabledStatus = "enabled"
      platform = [ordered]@{
        family = $platformFamily
        supportTargetId = $targetId
        serviceManager = $serviceManager
        reverseProxy = $reverseProxy
        kernelName = $kernelName
        osId = $targetId
        osPrettyName = $targetId
        appFramework = "nextjs"
        nextjsDeploymentMode = $nextJsMode
      }
      port = [ordered]@{
        checked = $true
        port = "3000"
        listening = $true
        ownerReadable = $true
        ownerProcessCount = 1
        servicePidKnown = $true
        ownedByService = $true
      }
      health = [ordered]@{
        checked = $true
        url = "http://127.0.0.1:3000/health"
        status = "ok"
        statusCode = 200
        responseSeconds = "0.012"
        timeoutSeconds = "10"
      }
      uptime = [ordered]@{
        hostUptimeSeconds = 345600
        serviceUptimeSeconds = 259200
        minimumUptimeHours = "72"
        minimumSatisfied = $true
        serviceStartKnown = $true
      }
      healthMonitor = $monitor
      nextJsRuntime = [ordered]@{
        applicable = $true
        status = "ok"
        appFramework = "nextjs"
        mode = $nextJsMode
        runtimeRootName = "example-next-app"
      }
      reverseProxy = $proxyEvidence
      deploymentIdentity = [ordered]@{
        status = "ok"
        appDirectoryName = "example-next-app"
        deploymentId = "example-deploy-$targetId-$nextJsMode-$serviceManager-$reverseProxy"
        nextBuildId = "example-build-$nextJsMode"
        packageSha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
      verdict = "Healthy"
      critical = 0
      warnings = 0
      findings = @()
    }
    $data | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path $fileName) -Encoding UTF8
  }
}

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath | Out-Null
$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$targets = @(Get-ArrayValue $matrix.targets)

if ($SelfTest) {
  $IncludeServiceOnly = $true
  $IncludeFallback = $true
  $EvidencePath = Join-Path $RepoRoot ".tmp\support-evidence-coverage-selftest-$([Guid]::NewGuid().ToString('N'))"
  $expectedForSelfTest = @(Get-ExpectedEntries -Targets $targets)
  New-SelfTestEvidence -Path $EvidencePath -ExpectedEntries $expectedForSelfTest
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  throw "EvidencePath is required unless -SelfTest is used."
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $EvidencePath"
}

$expectedEntries = @(Get-ExpectedEntries -Targets $targets)
$records = @(Get-EvidenceRecords -Path $EvidencePath)
$healthyRecords = @($records | Where-Object { Test-RecordHealthy -Record $_ })
$covered = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[object]

foreach ($entry in $expectedEntries) {
  $matches = @($healthyRecords | Where-Object {
    $_.targetId -eq $entry.targetId -and
    $_.nextJsMode -eq $entry.nextJsMode -and
    $_.serviceManager -eq $entry.serviceManager -and
    $_.reverseProxy -eq $entry.reverseProxy
  })

  if ($matches.Count -gt 0) {
    $covered.Add([pscustomobject]@{
      kind = $entry.kind
      targetId = $entry.targetId
      nextJsMode = $entry.nextJsMode
      serviceManager = $entry.serviceManager
      reverseProxy = $entry.reverseProxy
      file = [string]$matches[0].relativeFile
      status = "covered"
    }) | Out-Null
  } else {
    $missing.Add([pscustomobject]@{
      kind = $entry.kind
      targetId = $entry.targetId
      nextJsMode = $entry.nextJsMode
      serviceManager = $entry.serviceManager
      reverseProxy = $entry.reverseProxy
      file = ""
      status = "missing"
    }) | Out-Null
  }
}

$coveredRows = @($covered | ForEach-Object { $_ })
$missingRows = @($missing | ForEach-Object { $_ })

$result = [pscustomobject]@{
  schemaVersion = 1
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  evidencePath = $EvidencePath
  summary = [pscustomobject]@{
    expectedCount = $expectedEntries.Count
    coveredCount = $coveredRows.Count
    missingCount = $missingRows.Count
    parsedEvidenceFiles = $records.Count
    healthyEvidenceFiles = $healthyRecords.Count
  }
  covered = $coveredRows
  missing = $missingRows
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
  "Csv" {
    $rows = @($result.covered + $result.missing)
    if ($OutputPath) { $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 } else { $rows | ConvertTo-Csv -NoTypeInformation }
  }
  "Table" {
    Write-Host ""
    Write-Host "==> Support evidence coverage"
    Write-Host "Expected: $($result.summary.expectedCount)"
    Write-Host "Covered:  $($result.summary.coveredCount)"
    Write-Host "Missing:  $($result.summary.missingCount)"
    if ($result.summary.missingCount -gt 0) {
      @($missing | Select-Object -First 50) | Format-Table kind, targetId, nextJsMode, serviceManager, reverseProxy -AutoSize
      if ($missing.Count -gt 50) {
        Write-Host "... $($missing.Count - 50) more missing entries."
      }
    }
  }
}

if ($SelfTest -and $result.summary.missingCount -ne 0) {
  throw "Support evidence coverage self-test failed."
}
if (-not $SelfTest -and $result.summary.missingCount -gt 0) {
  throw "Support evidence coverage has $($result.summary.missingCount) missing entr$(if ($result.summary.missingCount -eq 1) { 'y' } else { 'ies' })."
}
