param(
  [string]$EvidencePath = ".\evidence",
  [string[]]$RequiredTargets = @(),
  [int]$MaxEvidenceAgeDays = 0,
  [switch]$RequireNextJs,
  [switch]$RequireReverseProxy,
  [switch]$RequireDeploymentIdentity,
  [switch]$FailOnWarnings,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Normalize-Target {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Add-Target {
  param(
    [System.Collections.Generic.HashSet[string]]$Targets,
    [string]$Value
  )

  $normalized = Normalize-Target $Value
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

function Test-PropertyExists {
  param(
    [object]$Object,
    [string[]]$Names
  )

  if ($null -eq $Object) { return $false }
  foreach ($name in $Names) {
    foreach ($property in $Object.PSObject.Properties) {
      if ($property.Name -ieq $name) {
        return $true
      }
    }
  }
  return $false
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
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $null
  }
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

function Get-EvidenceTargets {
  param([object]$Evidence)

  $targets = New-Object System.Collections.Generic.HashSet[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $family = Get-StringValue -Object $platform -Names @("Family", "family")
  $osCaption = Get-StringValue -Object $platform -Names @("OsCaption", "osCaption")
  $osId = Get-StringValue -Object $platform -Names @("OsId", "osId")
  $osIdLike = Get-StringValue -Object $platform -Names @("OsIdLike", "osIdLike")
  $kernelName = Get-StringValue -Object $platform -Names @("KernelName", "kernelName")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }

  Add-Target -Targets $targets -Value $family
  Add-Target -Targets $targets -Value $osId
  Add-Target -Targets $targets -Value $kernelName
  Add-Target -Targets $targets -Value $serviceManager

  foreach ($part in @($osIdLike -split '\s+')) {
    Add-Target -Targets $targets -Value $part
  }

  if ($osCaption -match 'Windows') {
    Add-Target -Targets $targets -Value "windows"
  }
  if ($osCaption -match 'Windows Server') {
    Add-Target -Targets $targets -Value "windows-server"
  }
  foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
    if ($osCaption -match $year) {
      Add-Target -Targets $targets -Value "windows-server-$year"
    }
  }
  if ($osCaption -match '2012\s+R2') {
    Add-Target -Targets $targets -Value "windows-server-2012-r2"
  }

  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")
  if ($prettyName -match 'CentOS Stream') {
    Add-Target -Targets $targets -Value "centos-stream"
  }
  if ($prettyName -match 'Oracle Linux') {
    Add-Target -Targets $targets -Value "oracle-linux"
  }
  if ($prettyName -match 'Linux Mint') {
    Add-Target -Targets $targets -Value "linux-mint"
  }

  if ($targets.Contains("ubuntu") -or $targets.Contains("debian") -or $targets.Contains("rhel") -or $targets.Contains("fedora") -or $targets.Contains("alpine") -or $targets.Contains("oracle-linux") -or $targets.Contains("centos") -or $targets.Contains("centos-stream") -or $targets.Contains("linux-mint")) {
    [void]$targets.Add("linux")
  }
  if ($targets.Contains("windows-server")) {
    [void]$targets.Add("windows")
  }

  return @($targets | Sort-Object)
}

function Get-ServiceEvidence {
  param([object]$Evidence)

  $service = Get-PropertyValue -Object $Evidence -Names @("Service", "service")
  $activeStatus = Get-StringValue -Object $Evidence -Names @("ServiceActiveStatus", "serviceActiveStatus")
  $enabledStatus = Get-StringValue -Object $Evidence -Names @("ServiceEnabledStatus", "serviceEnabledStatus")

  if ($service) {
    $status = Get-StringValue -Object $service -Names @("Status", "status")
    $startType = Get-StringValue -Object $service -Names @("StartType", "startType")
    $win32State = Get-StringValue -Object $service -Names @("Win32State", "win32State")
    $win32StartMode = Get-StringValue -Object $service -Names @("Win32StartMode", "win32StartMode")

    if (-not $activeStatus) {
      if ($status -eq "Running" -or $win32State -eq "Running") {
        $activeStatus = "active"
      } elseif ($status -or $win32State) {
        $activeStatus = "inactive"
      }
    }
    if (-not $enabledStatus) {
      if ($startType -eq "Automatic" -or $win32StartMode -eq "Auto") {
        $enabledStatus = "enabled"
      } elseif ($startType -or $win32StartMode) {
        $enabledStatus = "disabled"
      }
    }
  }

  return [pscustomobject]@{
    ActiveStatus = if ($activeStatus) { $activeStatus } else { "unknown" }
    EnabledStatus = if ($enabledStatus) { $enabledStatus } else { "unknown" }
  }
}

function Test-ServiceActiveEvidence {
  param([string]$Status)
  return ($Status -in @("active", "running"))
}

function Test-ServiceEnabledEvidence {
  param([string]$Status)
  return ($Status -in @("enabled", "automatic", "auto", "static", "generated", "linked", "linked-runtime", "indirect", "enabled-runtime"))
}

function Get-PortEvidence {
  param([object]$Evidence)

  $port = Get-PropertyValue -Object $Evidence -Names @("Port", "port")
  $servicePidKnown = Get-BooleanValue -Object $port -Names @("ServicePidKnown", "servicePidKnown", "ServiceProcessIdsKnown", "serviceProcessIdsKnown")

  return [pscustomobject]@{
    Checked = Get-BooleanValue -Object $port -Names @("Checked", "checked") -Default $false
    Port = Get-IntegerValue -Object $port -Names @("Port", "port")
    Listening = Get-BooleanValue -Object $port -Names @("Listening", "listening") -Default $false
    OwnerReadable = Get-BooleanValue -Object $port -Names @("OwnerReadable", "ownerReadable") -Default $false
    OwnerProcessCount = Get-IntegerValue -Object $port -Names @("OwnerProcessCount", "ownerProcessCount")
    ServicePidKnown = $servicePidKnown
    OwnedByService = Get-BooleanValue -Object $port -Names @("OwnedByService", "ownedByService") -Default $false
  }
}

function Get-HealthEvidence {
  param([object]$Evidence)

  $health = Get-PropertyValue -Object $Evidence -Names @("Health", "health")

  return [pscustomobject]@{
    Checked = Get-BooleanValue -Object $health -Names @("Checked", "checked") -Default $false
    Status = Get-StringValue -Object $health -Names @("Status", "status")
    StatusCode = Get-IntegerValue -Object $health -Names @("StatusCode", "statusCode")
    Url = Get-StringValue -Object $health -Names @("Url", "url")
  }
}

function Get-UptimeEvidence {
  param([object]$Evidence)

  $uptime = Get-PropertyValue -Object $Evidence -Names @("Uptime", "uptime")

  return [pscustomobject]@{
    HostUptimeSeconds = Get-IntegerValue -Object $uptime -Names @("HostUptimeSeconds", "hostUptimeSeconds")
    ServiceUptimeSeconds = Get-IntegerValue -Object $uptime -Names @("ServiceUptimeSeconds", "serviceUptimeSeconds")
    MinimumUptimeHours = Get-IntegerValue -Object $uptime -Names @("MinimumUptimeHours", "minimumUptimeHours")
    MinimumSatisfied = Get-BooleanValue -Object $uptime -Names @("MinimumSatisfied", "minimumSatisfied")
    ServiceStartKnown = Get-BooleanValue -Object $uptime -Names @("ServiceStartKnown", "serviceStartKnown") -Default $false
  }
}

function Get-HealthMonitorEvidence {
  param([object]$Evidence)

  $monitor = Get-PropertyValue -Object $Evidence -Names @("HealthMonitor", "healthMonitor")
  $status = Get-StringValue -Object $monitor -Names @("Status", "status")

  return [pscustomobject]@{
    Status = if ($status) { $status } else { "unknown" }
    Scheduled = Get-BooleanValue -Object $monitor -Names @("Scheduled", "scheduled") -Default $false
    ScheduleType = Get-StringValue -Object $monitor -Names @("ScheduleType", "scheduleType")
    TaskExists = Get-BooleanValue -Object $monitor -Names @("TaskExists", "taskExists")
    TaskLastResult = Get-IntegerValue -Object $monitor -Names @("TaskLastResult", "taskLastResult")
    TaskMissedRuns = Get-IntegerValue -Object $monitor -Names @("TaskMissedRuns", "taskMissedRuns")
    SchedulerChecked = Get-BooleanValue -Object $monitor -Names @("SchedulerChecked", "schedulerChecked")
    SchedulerExists = Get-BooleanValue -Object $monitor -Names @("SchedulerExists", "schedulerExists")
    SchedulerActive = Get-BooleanValue -Object $monitor -Names @("SchedulerActive", "schedulerActive")
    SchedulerEnabled = Get-BooleanValue -Object $monitor -Names @("SchedulerEnabled", "schedulerEnabled")
    SchedulerActiveStatus = Get-StringValue -Object $monitor -Names @("SchedulerActiveStatus", "schedulerActiveStatus")
    SchedulerEnabledStatus = Get-StringValue -Object $monitor -Names @("SchedulerEnabledStatus", "schedulerEnabledStatus")
    StateExists = Get-BooleanValue -Object $monitor -Names @("StateExists", "stateExists") -Default $false
    ConsecutiveFailures = Get-IntegerValue -Object $monitor -Names @("ConsecutiveFailures", "consecutiveFailures")
    LastSuccessAgeSeconds = Get-IntegerValue -Object $monitor -Names @("LastSuccessAgeSeconds", "lastSuccessAgeSeconds")
    LastSuccessFresh = Get-BooleanValue -Object $monitor -Names @("LastSuccessFresh", "lastSuccessFresh") -Default $false
    LogExists = Get-BooleanValue -Object $monitor -Names @("LogExists", "logExists") -Default $false
    LogFailureCount = Get-IntegerValue -Object $monitor -Names @("LogFailureCount", "logFailureCount")
    LogRestartCount = Get-IntegerValue -Object $monitor -Names @("LogRestartCount", "logRestartCount")
  }
}

function Get-NextJsEvidence {
  param([object]$Evidence)

  $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $appFramework = Get-StringValue -Object $nextJs -Names @("AppFramework", "appFramework")
  if (-not $appFramework) {
    $appFramework = Get-StringValue -Object $platform -Names @("AppFramework", "appFramework")
  }
  if (-not $appFramework) {
    $appFramework = Get-StringValue -Object $Evidence -Names @("AppFramework", "appFramework")
  }

  $mode = Get-StringValue -Object $nextJs -Names @("Mode", "mode")
  if (-not $mode) {
    $mode = Get-StringValue -Object $platform -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }
  if (-not $mode) {
    $mode = Get-StringValue -Object $Evidence -Names @("NextjsDeploymentMode", "nextjsDeploymentMode", "NextJsDeploymentMode")
  }

  $status = Get-StringValue -Object $nextJs -Names @("Status", "status")
  $applicableValue = Get-PropertyValue -Object $nextJs -Names @("Applicable", "applicable")
  $applicable = $false
  if ($applicableValue -is [bool]) {
    $applicable = [bool]$applicableValue
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$applicableValue)) {
    $applicable = ([string]$applicableValue) -match '^(true|1|yes)$'
  }

  return [pscustomobject]@{
    Applicable = $applicable
    Status = if ($status) { $status } else { "unknown" }
    AppFramework = $appFramework
    Mode = $mode
  }
}

function Test-NextJsFrameworkEvidence {
  param([string]$Value)
  return ((Normalize-Target $Value) -in @("next", "nextjs", "next-js"))
}

function Get-ReverseProxyEvidence {
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

  $status = Get-StringValue -Object $reverseProxy -Names @("Status", "status")
  $probeUrl = Get-StringValue -Object $reverseProxy -Names @("ProbeUrl", "probeUrl")
  $statusCode = Get-IntegerValue -Object $reverseProxy -Names @("StatusCode", "statusCode")
  $iis = Get-PropertyValue -Object $reverseProxy -Names @("Iis", "iis")
  $config = Get-PropertyValue -Object $reverseProxy -Names @("Config", "config")
  $applicableValue = Get-PropertyValue -Object $reverseProxy -Names @("Applicable", "applicable")
  $applicable = $false
  if ($applicableValue -is [bool]) {
    $applicable = [bool]$applicableValue
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$applicableValue)) {
    $applicable = ([string]$applicableValue) -match '^(true|1|yes)$'
  } elseif ($mode -and (Normalize-Target $mode) -ne "none") {
    $applicable = $true
  }

  return [pscustomobject]@{
    Applicable = $applicable
    Mode = if ($mode) { $mode } else { "unknown" }
    Status = if ($status) { $status } else { "unknown" }
    ProbeUrl = $probeUrl
    StatusCode = $statusCode
    IisModuleAvailable = Get-BooleanValue -Object $iis -Names @("ModuleAvailable", "moduleAvailable")
    IisSiteExists = Get-BooleanValue -Object $iis -Names @("SiteExists", "siteExists")
    IisSitePathMatchesConfig = Get-BooleanValue -Object $iis -Names @("SitePathMatchesConfig", "sitePathMatchesConfig")
    IisBindingMatchesConfig = Get-BooleanValue -Object $iis -Names @("BindingMatchesConfig", "bindingMatchesConfig")
    IisDuplicateBindingConflict = Get-BooleanValue -Object $iis -Names @("DuplicateBindingConflict", "duplicateBindingConflict")
    ConfigApplicable = Get-BooleanValue -Object $config -Names @("Applicable", "applicable")
    ConfigExists = Get-BooleanValue -Object $config -Names @("Exists", "exists")
    ConfigManagedMarkerFound = Get-BooleanValue -Object $config -Names @("ManagedMarkerFound", "managedMarkerFound")
  }
}

function Get-DeploymentIdentityEvidence {
  param([object]$Evidence)

  $identity = Get-PropertyValue -Object $Evidence -Names @("DeploymentIdentity", "deploymentIdentity")
  $status = Get-StringValue -Object $identity -Names @("Status", "status")
  $deploymentId = Get-StringValue -Object $identity -Names @("DeploymentId", "deploymentId")
  $nextBuildId = Get-StringValue -Object $identity -Names @("NextBuildId", "nextBuildId")
  $packageSha256 = Get-StringValue -Object $identity -Names @("PackageSha256", "packageSha256")
  $appDirectoryName = Get-StringValue -Object $identity -Names @("AppDirectoryName", "appDirectoryName")

  if (-not $deploymentId) {
    $deploymentId = Get-StringValue -Object $Evidence -Names @("DeploymentId", "deploymentId")
  }
  if (-not $nextBuildId) {
    $nextJs = Get-PropertyValue -Object $Evidence -Names @("NextJsRuntime", "nextJsRuntime")
    $nextBuildId = Get-StringValue -Object $nextJs -Names @("BuildId", "buildId", "NextBuildId", "nextBuildId")
  }

  return [pscustomobject]@{
    Status = if ($status) { $status } else { "unknown" }
    DeploymentId = $deploymentId
    NextBuildId = $nextBuildId
    PackageSha256 = $packageSha256
    AppDirectoryName = $appDirectoryName
  }
}

function Test-UnsafeEvidenceText {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value -match '(?i)[A-Z]:\\') { return $true }
  if ($Value -match '(^|\s)/(home|users|opt|srv|var|etc|inetpub|usr|tmp)/') { return $true }
  return $false
}

function New-SelfTestEvidence {
  param([string]$Path)

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $unixManagedProxyConfig = [ordered]@{
    applicable = $true
    pathName = "example-next-app.conf"
    directoryName = "conf.d"
    exists = $true
    managedMarkerFound = $true
    expectedPort = "80"
  }
  $unixPortEvidence = [ordered]@{
    checked = $true
    port = "3000"
    listening = $true
    ownerReadable = $true
    ownerProcessCount = 1
    servicePidKnown = $true
    ownedByService = $true
  }
  $unixHealthEvidence = [ordered]@{
    checked = $true
    url = "http://127.0.0.1:3000/health"
    status = "ok"
    statusCode = 200
    responseSeconds = "0.012"
    timeoutSeconds = "10"
  }
  $unixUptimeEvidence = [ordered]@{
    hostUptimeSeconds = 345600
    serviceUptimeSeconds = 259200
    minimumUptimeHours = "72"
    minimumSatisfied = $true
    serviceStartKnown = $true
  }
  $unixHealthMonitorEvidence = [ordered]@{
    status = "ok"
    scheduled = $true
    scheduleType = "state-log"
    stateExists = $true
    consecutiveFailures = 0
    lastSuccessAgeSeconds = 60
    lastSuccessFresh = $true
    logExists = $true
    logFailureCount = 0
    logRestartCount = 0
  }
  $systemdHealthMonitorEvidence = [ordered]@{
    status = "ok"
    scheduled = $true
    scheduleType = "systemd-timer"
    schedulerChecked = $true
    schedulerExists = $true
    schedulerActive = $true
    schedulerEnabled = $true
    schedulerActiveStatus = "active"
    schedulerEnabledStatus = "enabled"
    stateExists = $true
    consecutiveFailures = 0
    lastSuccessAgeSeconds = 60
    lastSuccessFresh = $true
    logExists = $true
    logFailureCount = 0
    logRestartCount = 0
  }
  $launchdHealthMonitorEvidence = [ordered]@{
    status = "ok"
    scheduled = $true
    scheduleType = "launchd-timer"
    schedulerChecked = $true
    schedulerExists = $true
    schedulerActive = $true
    schedulerEnabled = $true
    schedulerActiveStatus = "active"
    schedulerEnabledStatus = "enabled"
    stateExists = $true
    consecutiveFailures = 0
    lastSuccessAgeSeconds = 60
    lastSuccessFresh = $true
    logExists = $true
    logFailureCount = 0
    logRestartCount = 0
  }
  $cronHealthMonitorEvidence = [ordered]@{
    status = "ok"
    scheduled = $true
    scheduleType = "cron"
    schedulerChecked = $true
    schedulerExists = $true
    schedulerActive = $true
    schedulerEnabled = $true
    schedulerActiveStatus = "cron:active"
    schedulerEnabledStatus = "persistent-entry"
    stateExists = $true
    consecutiveFailures = 0
    lastSuccessAgeSeconds = 60
    lastSuccessFresh = $true
    logExists = $true
    logFailureCount = 0
    logRestartCount = 0
  }
  $examples = @(
    @{
      Name = "windows-server-2022.json"
      Data = [ordered]@{
        EvidenceSchemaVersion = 1
        GeneratedAtUtc = $now
        AppName = "example-next-app"
        Platform = [ordered]@{
          Family = "windows"
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
          HostUptimeSeconds = 345600
          ServiceUptimeSeconds = 259200
          MinimumUptimeHours = 72
          MinimumSatisfied = $true
          ServiceStartKnown = $true
        }
        HealthMonitor = [ordered]@{
          Status = "ok"
          Scheduled = $true
          ScheduleType = "windows-task"
          TaskExists = $true
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
    },
    @{
      Name = "ubuntu.json"
      Data = [ordered]@{
        evidenceSchemaVersion = 1
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "systemd"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        appRuntime = "node"
        port = $unixPortEvidence
        health = $unixHealthEvidence
        uptime = $unixUptimeEvidence
        healthMonitor = $systemdHealthMonitorEvidence
        nextJsRuntime = [ordered]@{
          applicable = $true
          status = "ok"
          appFramework = "nextjs"
          mode = "standalone"
          runtimeRootName = "example-next-app"
        }
        reverseProxy = [ordered]@{
          applicable = $true
          mode = "nginx"
          status = "ok"
          probeUrl = "http://127.0.0.1:80/health"
          statusCode = 200
          responseSeconds = "0.012"
          config = $unixManagedProxyConfig
        }
        deploymentIdentity = [ordered]@{
          status = "ok"
          appDirectoryName = "example-next-app"
          deploymentId = "example-deploy-001"
          nextBuildId = "example-build"
          packageSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }
        platform = [ordered]@{
          family = "linux"
          kernelName = "Linux"
          osId = "ubuntu"
          osIdLike = "debian"
          osPrettyName = "Ubuntu 24.04 LTS"
        }
        verdict = "Healthy"
        critical = 0
        warnings = 0
        findings = @()
      }
    },
    @{
      Name = "macos.json"
      Data = [ordered]@{
        evidenceSchemaVersion = 1
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "launchd"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        appRuntime = "node"
        port = $unixPortEvidence
        health = $unixHealthEvidence
        uptime = $unixUptimeEvidence
        healthMonitor = $launchdHealthMonitorEvidence
        nextJsRuntime = [ordered]@{
          applicable = $true
          status = "ok"
          appFramework = "nextjs"
          mode = "standalone"
          runtimeRootName = "example-next-app"
        }
        reverseProxy = [ordered]@{
          applicable = $true
          mode = "nginx"
          status = "ok"
          probeUrl = "http://127.0.0.1:80/health"
          statusCode = 200
          responseSeconds = "0.012"
          config = $unixManagedProxyConfig
        }
        deploymentIdentity = [ordered]@{
          status = "ok"
          appDirectoryName = "example-next-app"
          deploymentId = "example-deploy-001"
          nextBuildId = "example-build"
        }
        platform = [ordered]@{
          family = "macos"
          kernelName = "Darwin"
          osPrettyName = "Apple macOS"
        }
        verdict = "Healthy"
        critical = 0
        warnings = 0
        findings = @()
      }
    },
    @{
      Name = "freebsd.json"
      Data = [ordered]@{
        evidenceSchemaVersion = 1
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        appRuntime = "node"
        port = $unixPortEvidence
        health = $unixHealthEvidence
        uptime = $unixUptimeEvidence
        healthMonitor = $cronHealthMonitorEvidence
        nextJsRuntime = [ordered]@{
          applicable = $true
          status = "ok"
          appFramework = "nextjs"
          mode = "standalone"
          runtimeRootName = "example-next-app"
        }
        reverseProxy = [ordered]@{
          applicable = $true
          mode = "nginx"
          status = "ok"
          probeUrl = "http://127.0.0.1:80/health"
          statusCode = 200
          responseSeconds = "0.012"
          config = $unixManagedProxyConfig
        }
        deploymentIdentity = [ordered]@{
          status = "ok"
          appDirectoryName = "example-next-app"
          deploymentId = "example-deploy-001"
          nextBuildId = "example-build"
        }
        platform = [ordered]@{
          family = "freebsd"
          kernelName = "FreeBSD"
          osPrettyName = "FreeBSD"
        }
        verdict = "Healthy"
        critical = 0
        warnings = 0
        findings = @()
      }
    },
    @{
      Name = "openbsd.json"
      Data = [ordered]@{
        evidenceSchemaVersion = 1
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        appRuntime = "node"
        port = $unixPortEvidence
        health = $unixHealthEvidence
        uptime = $unixUptimeEvidence
        healthMonitor = $cronHealthMonitorEvidence
        nextJsRuntime = [ordered]@{
          applicable = $true
          status = "ok"
          appFramework = "nextjs"
          mode = "standalone"
          runtimeRootName = "example-next-app"
        }
        reverseProxy = [ordered]@{
          applicable = $true
          mode = "nginx"
          status = "ok"
          probeUrl = "http://127.0.0.1:80/health"
          statusCode = 200
          responseSeconds = "0.012"
          config = $unixManagedProxyConfig
        }
        deploymentIdentity = [ordered]@{
          status = "ok"
          appDirectoryName = "example-next-app"
          deploymentId = "example-deploy-001"
          nextBuildId = "example-build"
        }
        platform = [ordered]@{
          family = "openbsd"
          kernelName = "OpenBSD"
          osPrettyName = "OpenBSD"
        }
        verdict = "Healthy"
        critical = 0
        warnings = 0
        findings = @()
      }
    },
    @{
      Name = "netbsd.json"
      Data = [ordered]@{
        evidenceSchemaVersion = 1
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        appRuntime = "node"
        port = $unixPortEvidence
        health = $unixHealthEvidence
        uptime = $unixUptimeEvidence
        healthMonitor = $cronHealthMonitorEvidence
        nextJsRuntime = [ordered]@{
          applicable = $true
          status = "ok"
          appFramework = "nextjs"
          mode = "standalone"
          runtimeRootName = "example-next-app"
        }
        reverseProxy = [ordered]@{
          applicable = $true
          mode = "nginx"
          status = "ok"
          probeUrl = "http://127.0.0.1:80/health"
          statusCode = 200
          responseSeconds = "0.012"
          config = $unixManagedProxyConfig
        }
        deploymentIdentity = [ordered]@{
          status = "ok"
          appDirectoryName = "example-next-app"
          deploymentId = "example-deploy-001"
          nextBuildId = "example-build"
        }
        platform = [ordered]@{
          family = "netbsd"
          kernelName = "NetBSD"
          osPrettyName = "NetBSD"
        }
        verdict = "Healthy"
        critical = 0
        warnings = 0
        findings = @()
      }
    }
  )

  foreach ($example in $examples) {
    $examplePath = Join-Path $Path $example.Name
    $example.Data | ConvertTo-Json -Depth 8 | Set-Content -Path $examplePath -Encoding UTF8
  }
}

function Test-EvidenceFile {
  param(
    [System.IO.FileInfo]$File,
    [System.Collections.Generic.List[string]]$Issues
  )

  try {
    $raw = Get-Content -Path $File.FullName -Raw
    $evidence = $raw | ConvertFrom-Json
  } catch {
    $Issues.Add("$($File.FullName) is not valid JSON: $($_.Exception.Message)") | Out-Null
    return $null
  }

  $appName = Get-StringValue -Object $evidence -Names @("AppName", "appName")
  $generatedAt = Get-StringValue -Object $evidence -Names @("GeneratedAtUtc", "generatedAtUtc")
  $verdict = Get-StringValue -Object $evidence -Names @("Verdict", "verdict")
  $critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
  $warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
  $hasFindings = Test-PropertyExists -Object $evidence -Names @("Findings", "findings")
  $targets = @(Get-EvidenceTargets -Evidence $evidence)
  $serviceEvidence = Get-ServiceEvidence -Evidence $evidence
  $portEvidence = Get-PortEvidence -Evidence $evidence
  $healthEvidence = Get-HealthEvidence -Evidence $evidence
  $uptimeEvidence = Get-UptimeEvidence -Evidence $evidence
  $healthMonitorEvidence = Get-HealthMonitorEvidence -Evidence $evidence
  $nextJsEvidence = Get-NextJsEvidence -Evidence $evidence
  $reverseProxyEvidence = Get-ReverseProxyEvidence -Evidence $evidence
  $deploymentIdentityEvidence = Get-DeploymentIdentityEvidence -Evidence $evidence
  $nextJsRawEvidence = Get-PropertyValue -Object $evidence -Names @("NextJsRuntime", "nextJsRuntime")
  $deploymentIdentityRawEvidence = Get-PropertyValue -Object $evidence -Names @("DeploymentIdentity", "deploymentIdentity")
  $findingsValue = Get-PropertyValue -Object $evidence -Names @("Findings", "findings")

  if (-not $appName) {
    $Issues.Add("$($File.FullName) is missing app name.") | Out-Null
  }
  if (Test-PropertyExists -Object $evidence -Names @("ComputerName", "computerName", "HostName", "hostName", "MachineName", "machineName")) {
    $Issues.Add("$($File.FullName) contains a raw host identity field. Use a private evidence folder name or an external release record instead.") | Out-Null
  }
  if (Test-PropertyExists -Object $evidence -Names @("ConfigPath", "configPath")) {
    $Issues.Add("$($File.FullName) contains raw config path metadata. Status JSON should emit ConfigFileName/configFileName only.") | Out-Null
  }
  if (Test-PropertyExists -Object $nextJsRawEvidence -Names @("RuntimeRoot", "runtimeRoot")) {
    $Issues.Add("$($File.FullName) contains raw Next.js runtime path metadata. Status JSON should emit RuntimeRootName/runtimeRootName only.") | Out-Null
  }
  if (Test-PropertyExists -Object $deploymentIdentityRawEvidence -Names @("AppDirectory", "appDirectory")) {
    $Issues.Add("$($File.FullName) contains raw app directory metadata. Status JSON should emit AppDirectoryName/appDirectoryName only.") | Out-Null
  }
  foreach ($finding in @($findingsValue)) {
    $message = Get-StringValue -Object $finding -Names @("Message", "message")
    if (Test-UnsafeEvidenceText $message) {
      $Issues.Add("$($File.FullName) contains a finding message with an unsafe raw path. Status JSON should redact paths in findings.") | Out-Null
      break
    }
  }
  if (-not $generatedAt) {
    $Issues.Add("$($File.FullName) is missing generated timestamp.") | Out-Null
  } else {
    try {
      $generatedDate = [DateTime]::Parse($generatedAt).ToUniversalTime()
      if ($MaxEvidenceAgeDays -gt 0 -and ((Get-Date).ToUniversalTime() - $generatedDate).TotalDays -gt $MaxEvidenceAgeDays) {
        $Issues.Add("$($File.FullName) is older than $MaxEvidenceAgeDays day(s).") | Out-Null
      }
    } catch {
      $Issues.Add("$($File.FullName) has an invalid generated timestamp: $generatedAt") | Out-Null
    }
  }
  if ($verdict -notin @("Healthy", "Warning", "Critical")) {
    $Issues.Add("$($File.FullName) has invalid verdict: $verdict") | Out-Null
  }
  if ($null -eq $critical) {
    $Issues.Add("$($File.FullName) is missing critical count.") | Out-Null
  } elseif ($critical -gt 0) {
    $Issues.Add("$($File.FullName) has $critical critical finding(s).") | Out-Null
  }
  if ($null -eq $warnings) {
    $Issues.Add("$($File.FullName) is missing warning count.") | Out-Null
  } elseif ($FailOnWarnings -and $warnings -gt 0) {
    $Issues.Add("$($File.FullName) has $warnings warning finding(s).") | Out-Null
  }
  if (-not $hasFindings) {
    $Issues.Add("$($File.FullName) is missing findings array.") | Out-Null
  }
  if ($targets.Count -eq 0) {
    $Issues.Add("$($File.FullName) has no recognizable platform target metadata.") | Out-Null
  }
  if (-not (Test-ServiceActiveEvidence -Status $serviceEvidence.ActiveStatus)) {
    $Issues.Add("$($File.FullName) does not prove an active service state (status: $($serviceEvidence.ActiveStatus)).") | Out-Null
  }
  if (-not (Test-ServiceEnabledEvidence -Status $serviceEvidence.EnabledStatus)) {
    $Issues.Add("$($File.FullName) does not prove service boot enablement (status: $($serviceEvidence.EnabledStatus)).") | Out-Null
  }
  if ($portEvidence.Checked -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the configured app port check was performed.") | Out-Null
  }
  if ($portEvidence.Listening -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the configured app port is listening.") | Out-Null
  }
  if ($portEvidence.OwnerReadable -ne $true) {
    $Issues.Add("$($File.FullName) does not prove configured app port owner PID(s) were readable.") | Out-Null
  }
  if ($null -eq $portEvidence.OwnerProcessCount -or $portEvidence.OwnerProcessCount -lt 1) {
    $Issues.Add("$($File.FullName) does not prove at least one owner process for the configured app port.") | Out-Null
  }
  if ($portEvidence.ServicePidKnown -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the service process ID was known for port ownership comparison.") | Out-Null
  }
  if ($portEvidence.OwnedByService -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the configured app port is owned by the configured service process.") | Out-Null
  }
  if ($healthEvidence.Checked -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the HTTP health probe was performed.") | Out-Null
  }
  if ($healthEvidence.Status -ne "ok") {
    $Issues.Add("$($File.FullName) does not prove HTTP health status ok (status: $($healthEvidence.Status)).") | Out-Null
  }
  if ($null -eq $healthEvidence.StatusCode -or $healthEvidence.StatusCode -lt 200 -or $healthEvidence.StatusCode -ge 400) {
    $Issues.Add("$($File.FullName) does not prove a successful HTTP health status code.") | Out-Null
  }
  if ($uptimeEvidence.ServiceStartKnown -ne $true) {
    $Issues.Add("$($File.FullName) does not prove service start time / service process uptime was known.") | Out-Null
  }
  if ($null -eq $uptimeEvidence.ServiceUptimeSeconds -or $uptimeEvidence.ServiceUptimeSeconds -lt 0) {
    $Issues.Add("$($File.FullName) does not prove service process uptime seconds.") | Out-Null
  }
  if ($null -ne $uptimeEvidence.MinimumUptimeHours -and $uptimeEvidence.MinimumUptimeHours -gt 0 -and $uptimeEvidence.MinimumSatisfied -ne $true) {
    $Issues.Add("$($File.FullName) does not prove the requested minimum uptime window was satisfied.") | Out-Null
  }
  if ($healthMonitorEvidence.Status -ne "ok") {
    $Issues.Add("$($File.FullName) does not prove health monitor status ok (status: $($healthMonitorEvidence.Status)).") | Out-Null
  }
  if ($healthMonitorEvidence.Scheduled -ne $true) {
    $Issues.Add("$($File.FullName) does not prove a recurring health monitor has run.") | Out-Null
  }
  if ([string]::IsNullOrWhiteSpace($healthMonitorEvidence.ScheduleType)) {
    $Issues.Add("$($File.FullName) does not identify the health monitor schedule type.") | Out-Null
  }
  if ($healthMonitorEvidence.StateExists -ne $true) {
    $Issues.Add("$($File.FullName) does not prove health monitor state exists.") | Out-Null
  }
  if ($healthMonitorEvidence.LastSuccessFresh -ne $true) {
    $Issues.Add("$($File.FullName) does not prove a recent successful health monitor run.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.ConsecutiveFailures -or $healthMonitorEvidence.ConsecutiveFailures -ne 0) {
    $Issues.Add("$($File.FullName) does not prove zero consecutive health monitor failures.") | Out-Null
  }
  if ($healthMonitorEvidence.LogExists -ne $true) {
    $Issues.Add("$($File.FullName) does not prove health monitor log summary exists.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.LogFailureCount -or $healthMonitorEvidence.LogFailureCount -ne 0) {
    $Issues.Add("$($File.FullName) does not prove zero recent health monitor failures in the log summary.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.LogRestartCount -or $healthMonitorEvidence.LogRestartCount -ne 0) {
    $Issues.Add("$($File.FullName) does not prove zero recent health monitor restarts in the log summary.") | Out-Null
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "windows-task") {
    if ($healthMonitorEvidence.TaskExists -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the Windows health check scheduled task exists.") | Out-Null
    }
    if ($null -eq $healthMonitorEvidence.TaskMissedRuns -or $healthMonitorEvidence.TaskMissedRuns -ne 0) {
      $Issues.Add("$($File.FullName) does not prove zero missed Windows health check task runs.") | Out-Null
    }
    if ($null -eq $healthMonitorEvidence.TaskLastResult -or $healthMonitorEvidence.TaskLastResult -ne 0) {
      $Issues.Add("$($File.FullName) does not prove the Windows health check scheduled task last result was successful.") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "systemd-timer") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the systemd healthcheck timer was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the systemd healthcheck timer exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the systemd healthcheck timer is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the systemd healthcheck timer is enabled for boot (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "launchd-timer") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the launchd healthcheck scheduler was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the launchd healthcheck plist exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the launchd healthcheck job is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the launchd healthcheck job is enabled (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "cron") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the cron healthcheck scheduler was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the managed cron healthcheck entry exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the cron daemon is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$($File.FullName) does not prove the cron healthcheck entry is persistent (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ($RequireNextJs) {
    if (-not (Test-NextJsFrameworkEvidence -Value $nextJsEvidence.AppFramework)) {
      $Issues.Add("$($File.FullName) does not prove AppFramework=nextjs (value: $($nextJsEvidence.AppFramework)).") | Out-Null
    }
    if ($nextJsEvidence.Mode -notin @("standalone", "next-start")) {
      $Issues.Add("$($File.FullName) does not prove a valid Next.js deployment mode (value: $($nextJsEvidence.Mode)).") | Out-Null
    }
    if (-not $nextJsEvidence.Applicable) {
      $Issues.Add("$($File.FullName) does not prove Next.js runtime layout validation was applicable.") | Out-Null
    }
    if ($nextJsEvidence.Status -ne "ok") {
      $Issues.Add("$($File.FullName) does not prove a successful Next.js runtime layout check (status: $($nextJsEvidence.Status)).") | Out-Null
    }
  }
  if ($RequireReverseProxy) {
    if (-not $reverseProxyEvidence.Applicable) {
      $Issues.Add("$($File.FullName) does not prove a reverse-proxy check was applicable.") | Out-Null
    }
    if ((Normalize-Target $reverseProxyEvidence.Mode) -in @("", "none", "unknown")) {
      $Issues.Add("$($File.FullName) does not prove a configured reverse-proxy mode (value: $($reverseProxyEvidence.Mode)).") | Out-Null
    }
    if ($reverseProxyEvidence.Status -ne "ok") {
      $Issues.Add("$($File.FullName) does not prove a successful reverse-proxy health probe (status: $($reverseProxyEvidence.Status)).") | Out-Null
    }
    if ($null -eq $reverseProxyEvidence.StatusCode -or $reverseProxyEvidence.StatusCode -lt 200 -or $reverseProxyEvidence.StatusCode -ge 400) {
      $Issues.Add("$($File.FullName) does not prove a successful reverse-proxy HTTP status code.") | Out-Null
    }
    $normalizedProxyMode = Normalize-Target $reverseProxyEvidence.Mode
    if ($normalizedProxyMode -eq "iis") {
      if ($reverseProxyEvidence.IisModuleAvailable -ne $true) {
        $Issues.Add("$($File.FullName) does not prove IIS WebAdministration evidence was available.") | Out-Null
      }
      if ($reverseProxyEvidence.IisSiteExists -ne $true) {
        $Issues.Add("$($File.FullName) does not prove the configured IIS site exists.") | Out-Null
      }
      if ($reverseProxyEvidence.IisSitePathMatchesConfig -ne $true) {
        $Issues.Add("$($File.FullName) does not prove the IIS site physical path matches the configured IisSitePath.") | Out-Null
      }
      if ($reverseProxyEvidence.IisBindingMatchesConfig -ne $true) {
        $Issues.Add("$($File.FullName) does not prove the configured IIS site owns the expected public binding.") | Out-Null
      }
      if ($reverseProxyEvidence.IisDuplicateBindingConflict -eq $true) {
        $Issues.Add("$($File.FullName) reports an IIS duplicate binding conflict.") | Out-Null
      }
    }
    if ($normalizedProxyMode -in @("nginx", "apache", "httpd", "haproxy", "traefik")) {
      if ($reverseProxyEvidence.ConfigApplicable -ne $true) {
        $Issues.Add("$($File.FullName) does not prove reverse-proxy config evidence was applicable for mode '$($reverseProxyEvidence.Mode)'.") | Out-Null
      }
      if ($reverseProxyEvidence.ConfigExists -ne $true) {
        $Issues.Add("$($File.FullName) does not prove the expected reverse-proxy config file exists.") | Out-Null
      }
      if ($reverseProxyEvidence.ConfigManagedMarkerFound -ne $true) {
        $Issues.Add("$($File.FullName) does not prove the reverse-proxy config contains this kit's managed marker for the app.") | Out-Null
      }
    }
  }
  if ($RequireDeploymentIdentity) {
    if ($deploymentIdentityEvidence.Status -ne "ok") {
      $Issues.Add("$($File.FullName) does not prove deployment identity status ok (status: $($deploymentIdentityEvidence.Status)).") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.DeploymentId) -and [string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.NextBuildId)) {
      if ([string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.PackageSha256)) {
        $Issues.Add("$($File.FullName) does not prove a deployment ID, Next.js build ID, or package SHA256.") | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    File = $File.FullName.Substring($RepoRoot.Length + 1)
    AppName = $appName
    Verdict = $verdict
    Critical = if ($null -eq $critical) { "" } else { $critical }
    Warnings = if ($null -eq $warnings) { "" } else { $warnings }
    Service = "$($serviceEvidence.ActiveStatus)/$($serviceEvidence.EnabledStatus)"
    Port = "$($portEvidence.Port)/listening=$($portEvidence.Listening)/owned=$($portEvidence.OwnedByService)"
    Health = "$($healthEvidence.Status)/$($healthEvidence.StatusCode)"
    Uptime = "$($uptimeEvidence.ServiceUptimeSeconds)s/min=$($uptimeEvidence.MinimumSatisfied)"
    Monitor = "$($healthMonitorEvidence.Status)/fail=$($healthMonitorEvidence.ConsecutiveFailures)/fresh=$($healthMonitorEvidence.LastSuccessFresh)"
    NextJs = "$($nextJsEvidence.AppFramework)/$($nextJsEvidence.Mode)/$($nextJsEvidence.Status)"
    Proxy = "$($reverseProxyEvidence.Mode)/$($reverseProxyEvidence.Status)"
    Identity = "$($deploymentIdentityEvidence.Status)/$($deploymentIdentityEvidence.DeploymentId)/$($deploymentIdentityEvidence.NextBuildId)/$($deploymentIdentityEvidence.PackageSha256)"
    Targets = ($targets -join ",")
  }
}

Write-Step "Host evidence validation"

if ($SelfTest) {
  $EvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-selftest-$([Guid]::NewGuid().ToString('N'))"
  if ($RequiredTargets.Count -eq 0) {
    $RequiredTargets = @("windows-server", "linux", "macos", "freebsd", "openbsd", "netbsd")
  }
  New-SelfTestEvidence -Path $EvidencePath
}

if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $EvidencePath"
}

$issues = New-Object System.Collections.Generic.List[string]
$files = @(Get-ChildItem -Path $EvidencePath -Recurse -File -Filter "*.json")
if ($files.Count -eq 0) {
  throw "No host evidence JSON files found under: $EvidencePath"
}

$results = New-Object System.Collections.Generic.List[object]
$allTargets = New-Object System.Collections.Generic.HashSet[string]
foreach ($file in $files) {
  $result = Test-EvidenceFile -File $file -Issues $issues
  if ($null -ne $result) {
    $results.Add($result) | Out-Null
    foreach ($target in @($result.Targets -split "," | Where-Object { $_ })) {
      [void]$allTargets.Add($target)
    }
  }
}

foreach ($required in $RequiredTargets) {
  $target = Normalize-Target $required
  if ($target -and -not $allTargets.Contains($target)) {
    $issues.Add("Missing required target evidence: $target") | Out-Null
  }
}

if ($results.Count -gt 0) {
  $results | Sort-Object File | Format-Table File, AppName, Verdict, Critical, Warnings, Service, Port, Health, Uptime, Monitor, NextJs, Proxy, Identity, Targets -Wrap
}

if ($issues.Count -gt 0) {
  Write-Host ""
  Write-Host "Host evidence validation failures:"
  $issues | ForEach-Object { Write-Host "  $_" }
  throw "Host evidence validation failed."
}

Write-Host "Host evidence validation OK"
