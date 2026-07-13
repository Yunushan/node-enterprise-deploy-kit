param(
  [string]$EvidencePath = ".\evidence",
  [string[]]$RequiredTargets = @(),
  [string]$ExpectedTargetId = "",
  [string]$ExpectedNextJsMode = "",
  [string]$ExpectedServiceManager = "",
  [string]$ExpectedReverseProxy = "",
  [string]$ExpectedMatrixPath = "",
  [string]$ExpectedMatrixSha256 = "",
  [int]$MaxEvidenceAgeDays = 0,
  [switch]$RequireNextJs,
  [switch]$RequireReverseProxy,
  [switch]$AllowReverseProxyNone,
  [switch]$RequireDeploymentIdentity,
  [switch]$RequireCollectorSha256,
  [switch]$RequireCiCollection,
  [switch]$RequireHostEvidenceWorkflowCollection,
  [int]$RequireMinimumUptimeHours = 0,
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

function Normalize-ReverseProxy {
  param([string]$Value)
  $normalized = Normalize-Target $Value
  if ($normalized -eq "httpd") { return "apache" }
  return $normalized
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

function Get-DisplayPath {
  param(
    [string]$Path,
    [string]$BasePath = "",
    [string]$OutsideRepositoryLabel = "outside-evidence"
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if ($fullPath.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    return "."
  }

  $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
  if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
  }

  if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    if ($fullPath.Equals($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
      return $OutsideRepositoryLabel
    }

    $basePrefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      $relativeToBase = $fullPath.Substring($basePrefix.Length).Replace("\", "/")
      return "$OutsideRepositoryLabel/$relativeToBase"
    }
  }

  return $OutsideRepositoryLabel
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

  Add-Target -Targets $targets -Value $family
  Add-Target -Targets $targets -Value $osId
  Add-Target -Targets $targets -Value $kernelName

  foreach ($part in @($osIdLike -split '\s+')) {
    Add-Target -Targets $targets -Value $part
  }

  if ($osCaption -match 'Windows') {
    Add-Target -Targets $targets -Value "windows"
  }
  if ($osCaption -match 'Windows Server') {
    Add-Target -Targets $targets -Value "windows-server"
    if ($osCaption -match '2012\s+R2') {
      Add-Target -Targets $targets -Value "windows-server-2012-r2"
    } else {
      foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
        if ($osCaption -match $year) {
          Add-Target -Targets $targets -Value "windows-server-$year"
        }
      }
    }
  } else {
    if ($osCaption -match 'Windows\s+10') {
      Add-Target -Targets $targets -Value "windows-10"
    }
    if ($osCaption -match 'Windows\s+11') {
      Add-Target -Targets $targets -Value "windows-11"
    }
  }

  if ($prettyName -match 'CentOS Stream') {
    Add-Target -Targets $targets -Value "centos-stream"
  }
  if ($prettyName -match 'Red Hat Enterprise Linux') {
    Add-Target -Targets $targets -Value "rhel"
  }
  if ($prettyName -match 'Oracle Linux') {
    Add-Target -Targets $targets -Value "oracle-linux"
  }
  if ($prettyName -match 'Rocky Linux') {
    Add-Target -Targets $targets -Value "rocky"
  }
  if ($prettyName -match 'AlmaLinux') {
    Add-Target -Targets $targets -Value "almalinux"
  }
  if ($prettyName -match 'Linux Mint') {
    Add-Target -Targets $targets -Value "linux-mint"
  }

  if ($targets.Contains("ubuntu") -or $targets.Contains("debian") -or $targets.Contains("rhel") -or $targets.Contains("fedora") -or $targets.Contains("alpine") -or $targets.Contains("oracle-linux") -or $targets.Contains("centos") -or $targets.Contains("centos-stream") -or $targets.Contains("rocky") -or $targets.Contains("almalinux") -or $targets.Contains("linux-mint")) {
    [void]$targets.Add("linux")
  }
  if ($targets.Contains("windows-server")) {
    [void]$targets.Add("windows")
  }

  return @($targets | Sort-Object)
}

function Get-EvidenceTargets {
  param([object]$Evidence)

  $targets = New-Object System.Collections.Generic.HashSet[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $supportTargetId = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $supportTargetId) {
    $supportTargetId = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }

  Add-Target -Targets $targets -Value $supportTargetId
  foreach ($target in @(Get-PlatformEvidenceTargets -Evidence $Evidence)) {
    Add-Target -Targets $targets -Value $target
  }

  return @($targets | Sort-Object)
}

function Get-SupportTargetId {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $value = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $value) {
    $value = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }
  return (Normalize-Target $value)
}

function Get-ServiceManager {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }
  return (Normalize-Target $serviceManager)
}

function Get-ServiceEvidence {
  param([object]$Evidence)

  $service = Get-PropertyValue -Object $Evidence -Names @("Service", "service")
  $definition = Get-PropertyValue -Object $Evidence -Names @("ServiceDefinition", "serviceDefinition")
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
    DefinitionChecked = Get-BooleanValue -Object $definition -Names @("Checked", "checked")
    DefinitionExists = Get-BooleanValue -Object $definition -Names @("DefinitionExists", "definitionExists")
    DefinitionSource = Get-StringValue -Object $definition -Names @("DefinitionSource", "definitionSource")
    ServiceWrapperMatchesConfig = Get-BooleanValue -Object $definition -Names @("ServiceWrapperMatchesConfig", "serviceWrapperMatchesConfig")
    NodeExeMatchesConfig = Get-BooleanValue -Object $definition -Names @("NodeExeMatchesConfig", "nodeExeMatchesConfig")
    WorkingDirectoryMatchesConfig = Get-BooleanValue -Object $definition -Names @("WorkingDirectoryMatchesConfig", "workingDirectoryMatchesConfig")
    ArgumentsMatchConfig = Get-BooleanValue -Object $definition -Names @("ArgumentsMatchConfig", "argumentsMatchConfig")
    RunnerScriptMatchesConfig = Get-BooleanValue -Object $definition -Names @("RunnerScriptMatchesConfig", "runnerScriptMatchesConfig")
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
    HostBootTimeKnown = Get-BooleanValue -Object $uptime -Names @("HostBootTimeKnown", "hostBootTimeKnown") -Default $false
    ServiceUptimeSeconds = Get-IntegerValue -Object $uptime -Names @("ServiceUptimeSeconds", "serviceUptimeSeconds")
    MinimumUptimeHours = Get-IntegerValue -Object $uptime -Names @("MinimumUptimeHours", "minimumUptimeHours")
    MinimumSatisfied = Get-BooleanValue -Object $uptime -Names @("MinimumSatisfied", "minimumSatisfied")
    ServiceStartKnown = Get-BooleanValue -Object $uptime -Names @("ServiceStartKnown", "serviceStartKnown") -Default $false
    ServiceStartedDuringCurrentBoot = Get-BooleanValue -Object $uptime -Names @("ServiceStartedDuringCurrentBoot", "serviceStartedDuringCurrentBoot") -Default $false
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
    TaskActionChecked = Get-BooleanValue -Object $monitor -Names @("TaskActionChecked", "taskActionChecked")
    TaskActionUsesHealthCheckScript = Get-BooleanValue -Object $monitor -Names @("TaskActionUsesHealthCheckScript", "taskActionUsesHealthCheckScript")
    TaskActionUsesConfigPath = Get-BooleanValue -Object $monitor -Names @("TaskActionUsesConfigPath", "taskActionUsesConfigPath")
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
    NodeVersion = Get-StringValue -Object $nextJs -Names @("NodeVersion", "nodeVersion")
    MinimumNodeVersion = Get-StringValue -Object $nextJs -Names @("MinimumNodeVersion", "minimumNodeVersion")
    NodeVersionSatisfied = Get-BooleanValue -Object $nextJs -Names @("NodeVersionSatisfied", "nodeVersionSatisfied") -Default $null
    NextVersion = Get-StringValue -Object $nextJs -Names @("NextVersion", "nextVersion")
    NextPackageJsonExists = Get-BooleanValue -Object $nextJs -Names @("NextPackageJsonExists", "nextPackageJsonExists") -Default $null
    NextStartScriptIsExpectedCli = Get-BooleanValue -Object $nextJs -Names @("NextStartScriptIsExpectedCli", "nextStartScriptIsExpectedCli", "NextStartCommandIsExpectedCli", "nextStartCommandIsExpectedCli") -Default $null
  }
}

function Test-NextJsFrameworkEvidence {
  param([string]$Value)
  return ((Normalize-Target $Value) -in @("next", "nextjs", "next-js"))
}

function Test-SafeRuntimeVersionEvidence {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  return ($Value -match '^[A-Za-z0-9._+:-]{1,80}$')
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
    [string]$FileName
  )

  $issues = New-Object System.Collections.Generic.List[string]
  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $target = Normalize-Target $SupportTargetId
  $kernelRelease = Get-StringValue -Object $platform -Names @("KernelRelease", "kernelRelease")
  $machine = Normalize-Target (Get-StringValue -Object $platform -Names @("Machine", "machine", "OsArchitecture", "osArchitecture"))
  $osVersion = Get-StringValue -Object $platform -Names @("OsVersionId", "osVersionId", "OsVersion", "osVersion", "ProductVersion", "productVersion")
  $osBuild = Get-IntegerValue -Object $platform -Names @("OsBuildNumber", "osBuildNumber", "BuildNumber", "buildNumber")
  $libcName = Normalize-Target (Get-StringValue -Object $platform -Names @("LibcName", "libcName"))
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
      $issues.Add("$FileName does not prove a Windows build number for Next.js Node runtime platform support.") | Out-Null
    } elseif ($osBuild -lt $minimumBuild) {
      $issues.Add("$FileName has Windows build $osBuild, below the $target floor of $minimumBuild for Next.js Node runtime platform support.") | Out-Null
    }
  }

  $glibcLinuxTargets = @("ubuntu", "debian", "linux-mint", "rhel", "oracle-linux", "centos", "centos-stream", "rocky", "almalinux", "fedora")
  if ($target -in $glibcLinuxTargets) {
    $kernelOk = Test-VersionAtLeast -Actual $kernelRelease -Minimum "4.18" -Count 2
    if ($null -eq $kernelOk) {
      $issues.Add("$FileName does not prove Linux kernel release for Next.js Node runtime platform support.") | Out-Null
    } elseif ($kernelOk -ne $true) {
      $issues.Add("$FileName has Linux kernel release '$kernelRelease', below the Node.js 20.x floor of 4.18 for Next.js support.") | Out-Null
    }

    if ($libcName -notin @("glibc", "gnu-libc", "gnu-c-library")) {
      $issues.Add("$FileName does not prove glibc runtime metadata required for Node.js 20.x Tier 1 Linux support.") | Out-Null
    } else {
      $glibcOk = Test-VersionAtLeast -Actual $libcVersion -Minimum "2.28" -Count 2
      if ($null -eq $glibcOk) {
        $issues.Add("$FileName does not prove glibc version for Node.js 20.x Tier 1 Linux support.") | Out-Null
      } elseif ($glibcOk -ne $true) {
        $issues.Add("$FileName has glibc version '$libcVersion', below the Node.js 20.x floor of 2.28 for Next.js support.") | Out-Null
      }
    }
  }

  if ($target -eq "macos") {
    if ([string]::IsNullOrWhiteSpace($machine)) {
      $issues.Add("$FileName does not prove macOS machine architecture for Next.js Node runtime platform support.") | Out-Null
    }
    $minimumMacosVersion = if ($machine -in @("arm64", "aarch64")) { "11.0" } else { "10.15" }
    $macosOk = Test-VersionAtLeast -Actual $osVersion -Minimum $minimumMacosVersion -Count 2
    if ($null -eq $macosOk) {
      $issues.Add("$FileName does not prove macOS product version for Next.js Node runtime platform support.") | Out-Null
    } elseif ($macosOk -ne $true) {
      $issues.Add("$FileName has macOS version '$osVersion', below the Node.js 20.x floor of $minimumMacosVersion for architecture '$machine'.") | Out-Null
    }
  }

  return @($issues)
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
    IisSiteStarted = Get-BooleanValue -Object $iis -Names @("SiteStarted", "siteStarted")
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
      EvidenceName = Normalize-Target (Get-StringValue -Object $workflowDispatch -Names @("EvidenceName", "evidenceName"))
      ExpectedTargetId = Normalize-Target (Get-StringValue -Object $workflowDispatch -Names @("ExpectedTargetId", "expectedTargetId", "expected_target_id"))
      ExpectedNextJsMode = Normalize-Target (Get-StringValue -Object $workflowDispatch -Names @("ExpectedNextJsMode", "expectedNextJsMode", "expected_nextjs_mode"))
      ExpectedServiceManager = Normalize-Target (Get-StringValue -Object $workflowDispatch -Names @("ExpectedServiceManager", "expectedServiceManager", "expected_service_manager"))
      ExpectedReverseProxy = Normalize-ReverseProxy (Get-StringValue -Object $workflowDispatch -Names @("ExpectedReverseProxy", "expectedReverseProxy", "expected_reverse_proxy"))
      MinimumUptimeHours = Get-IntegerValue -Object $workflowDispatch -Names @("MinimumUptimeHours", "minimumUptimeHours", "minimum_uptime_hours")
      SupportMatrixPath = Normalize-RepositoryRelativePath (Get-StringValue -Object $workflowDispatch -Names @("SupportMatrixPath", "supportMatrixPath", "matrixPath", "matrix_path"))
      SupportMatrixSha256 = (Get-StringValue -Object $workflowDispatch -Names @("SupportMatrixSha256", "supportMatrixSha256", "matrixSha256", "matrix_sha256")).Trim().ToLowerInvariant()
    }
  }
}

function Get-WorkflowDispatchDimensionIssues {
  param(
    [object]$Dispatch,
    [string]$FileName,
    [string]$TargetId,
    [string]$NextJsMode,
    [string]$ServiceManager,
    [string]$ReverseProxy,
    [int]$RequiredMinimumUptimeHours,
    [string]$ExpectedMatrixPath,
    [string]$ExpectedMatrixSha256
  )

  $issues = New-Object System.Collections.Generic.List[string]
  $expectedEvidenceBaseName = "$TargetId-$NextJsMode-$ServiceManager-$ReverseProxy"
  $allowedEvidenceNames = @($expectedEvidenceBaseName, "$expectedEvidenceBaseName-fallback")

  if ([string]::IsNullOrWhiteSpace([string]$Dispatch.EvidenceName)) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.evidenceName is required for host-evidence workflow provenance.") | Out-Null
  } elseif ($allowedEvidenceNames -notcontains [string]$Dispatch.EvidenceName) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.evidenceName does not match evidence dimensions.") | Out-Null
  }
  if ([string]$Dispatch.ExpectedTargetId -ne $TargetId) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.expectedTargetId does not match supportTargetId '$TargetId'.") | Out-Null
  }
  if ([string]$Dispatch.ExpectedNextJsMode -ne $NextJsMode) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.expectedNextJsMode does not match Next.js mode '$NextJsMode'.") | Out-Null
  }
  if ([string]$Dispatch.ExpectedServiceManager -ne $ServiceManager) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.expectedServiceManager does not match service manager '$ServiceManager'.") | Out-Null
  }
  if ([string]$Dispatch.ExpectedReverseProxy -ne $ReverseProxy) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.expectedReverseProxy does not match reverse proxy '$ReverseProxy'.") | Out-Null
  }
  if ($null -eq $Dispatch.MinimumUptimeHours) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.minimumUptimeHours is required for host-evidence workflow provenance.") | Out-Null
  } elseif ($RequiredMinimumUptimeHours -gt 0 -and [int]$Dispatch.MinimumUptimeHours -lt $RequiredMinimumUptimeHours) {
    $issues.Add("$FileName evidenceCollection.workflowDispatch.minimumUptimeHours is below the required minimum uptime.") | Out-Null
  }
  $expectedMatrixPathValue = Normalize-RepositoryRelativePath $ExpectedMatrixPath
  if (-not [string]::IsNullOrWhiteSpace($expectedMatrixPathValue)) {
    if ([string]::IsNullOrWhiteSpace([string]$Dispatch.SupportMatrixPath)) {
      $issues.Add("$FileName evidenceCollection.workflowDispatch.supportMatrixPath is required for host-evidence workflow provenance.") | Out-Null
    } elseif ([string]$Dispatch.SupportMatrixPath -ne $expectedMatrixPathValue) {
      $issues.Add("$FileName evidenceCollection.workflowDispatch.supportMatrixPath does not match expected support matrix path '$expectedMatrixPathValue'.") | Out-Null
    }
  }
  $expectedMatrixShaValue = ([string]$ExpectedMatrixSha256).Trim().ToLowerInvariant()
  if (-not [string]::IsNullOrWhiteSpace($expectedMatrixShaValue)) {
    if ($expectedMatrixShaValue -notmatch '^[a-f0-9]{64}$') {
      $issues.Add("$FileName expected support matrix SHA256 is not a valid SHA256 hash.") | Out-Null
    } elseif ([string]::IsNullOrWhiteSpace([string]$Dispatch.SupportMatrixSha256)) {
      $issues.Add("$FileName evidenceCollection.workflowDispatch.supportMatrixSha256 is required for host-evidence workflow provenance.") | Out-Null
    } elseif ([string]$Dispatch.SupportMatrixSha256 -ne $expectedMatrixShaValue) {
      $issues.Add("$FileName evidenceCollection.workflowDispatch.supportMatrixSha256 does not match expected support matrix SHA256.") | Out-Null
    }
  }

  return @($issues | ForEach-Object { $_ })
}

function Test-SupportedEvidenceCollector {
  param([object]$Collection)

  $source = Normalize-Target $Collection.Source
  $collector = Normalize-Target $Collection.Collector
  $allowed = @(
    "node-enterprise-deploy-kit-status-ps1",
    "node-enterprise-deploy-kit-status-node-app-sh",
    "status-ps1",
    "scripts-linux-status-node-app-sh",
    "status-node-app-sh"
  )

  return (($source -in $allowed) -or ($collector -in $allowed))
}

function Get-CollectionCiIssues {
  param(
    [object]$Ci,
    [string]$FileName
  )

  $issues = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Ci -or $null -eq $Ci.IsCi) { return @() }

  if ($Ci.Provider -and $Ci.Provider -notmatch '^[A-Za-z0-9._-]+$') {
    $issues.Add("$FileName evidenceCollection.ci.provider contains unsupported characters.") | Out-Null
  }
  if ($Ci.WorkflowName -and $Ci.WorkflowName -notmatch '^[A-Za-z0-9._/-]+$') {
    $issues.Add("$FileName evidenceCollection.ci.workflowName contains unsupported characters.") | Out-Null
  }
  if ($Ci.RunId -and $Ci.RunId -notmatch '^[0-9]+$') {
    $issues.Add("$FileName evidenceCollection.ci.runId must be numeric when present.") | Out-Null
  }
  if ($Ci.RunAttempt -and $Ci.RunAttempt -notmatch '^[0-9]+$') {
    $issues.Add("$FileName evidenceCollection.ci.runAttempt must be numeric when present.") | Out-Null
  }
  if ($Ci.EventName -and $Ci.EventName -notmatch '^[A-Za-z0-9._-]+$') {
    $issues.Add("$FileName evidenceCollection.ci.eventName contains unsupported characters.") | Out-Null
  }
  if ($Ci.RefName -and $Ci.RefName -notmatch '^[A-Za-z0-9._/-]+$') {
    $issues.Add("$FileName evidenceCollection.ci.refName contains unsupported characters.") | Out-Null
  }
  if ($Ci.Sha -and $Ci.Sha -notmatch '^[A-Fa-f0-9]{40}$') {
    $issues.Add("$FileName evidenceCollection.ci.sha must be a 40-character git SHA when present.") | Out-Null
  }
  if ($Ci.IsCi -and -not $Ci.Provider) {
    $issues.Add("$FileName evidenceCollection.ci.provider is required when ci.isCi is true.") | Out-Null
  }
  if ($Ci.Provider -eq "github-actions") {
    if (-not $Ci.WorkflowName) { $issues.Add("$FileName evidenceCollection.ci.workflowName is required for github-actions provenance.") | Out-Null }
    if (-not $Ci.RunId) { $issues.Add("$FileName evidenceCollection.ci.runId is required for github-actions provenance.") | Out-Null }
    if (-not $Ci.RunAttempt) { $issues.Add("$FileName evidenceCollection.ci.runAttempt is required for github-actions provenance.") | Out-Null }
    if (-not $Ci.EventName) { $issues.Add("$FileName evidenceCollection.ci.eventName is required for github-actions provenance.") | Out-Null }
    if (-not $Ci.RefName) { $issues.Add("$FileName evidenceCollection.ci.refName is required for github-actions provenance.") | Out-Null }
    if (-not $Ci.Sha) { $issues.Add("$FileName evidenceCollection.ci.sha is required for github-actions provenance.") | Out-Null }
  }

  return @($issues | ForEach-Object { $_ })
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
  $windowsCollectionEvidence = [ordered]@{
    Source = "node-enterprise-deploy-kit/status.ps1"
    Collector = "status.ps1"
    CollectorVersion = 1
    CollectorSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    LiveHost = $true
    Synthetic = $false
    Mock = $false
    Sample = $false
  }
  $unixCollectionEvidence = [ordered]@{
    source = "node-enterprise-deploy-kit/status-node-app.sh"
    collector = "scripts/linux/status-node-app.sh"
    collectorVersion = 1
    collectorSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    liveHost = $true
    synthetic = $false
    mock = $false
    sample = $false
  }
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
    hostBootTimeKnown = $true
    serviceUptimeSeconds = 259200
    minimumUptimeHours = "72"
    minimumSatisfied = $true
    serviceStartKnown = $true
    serviceStartedDuringCurrentBoot = $true
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
  $systemdServiceDefinitionEvidence = [ordered]@{
    checked = $true
    manager = "systemd"
    definitionSource = "systemd-unit"
    definitionExists = $true
    nodeExeMatchesConfig = $true
    workingDirectoryMatchesConfig = $true
    argumentsMatchConfig = $true
    runnerScriptMatchesConfig = $false
  }
  $launchdServiceDefinitionEvidence = [ordered]@{
    checked = $true
    manager = "launchd"
    definitionSource = "launchd-plist"
    definitionExists = $true
    nodeExeMatchesConfig = $true
    workingDirectoryMatchesConfig = $true
    argumentsMatchConfig = $true
    runnerScriptMatchesConfig = $true
  }
  $bsdrcServiceDefinitionEvidence = [ordered]@{
    checked = $true
    manager = "bsdrc"
    definitionSource = "bsdrc-init"
    definitionExists = $true
    nodeExeMatchesConfig = $true
    workingDirectoryMatchesConfig = $true
    argumentsMatchConfig = $true
    runnerScriptMatchesConfig = $false
  }
  $examples = @(
    @{
      Name = "windows-server-2022.json"
      Data = [ordered]@{
        EvidenceSchemaVersion = 1
        EvidenceCollection = $windowsCollectionEvidence
        SupportTargetId = "windows-server-2022"
        GeneratedAtUtc = $now
        AppName = "example-next-app"
        Platform = [ordered]@{
          Family = "windows"
          SupportTargetId = "windows-server-2022"
          OsCaption = "Microsoft Windows Server 2022 Datacenter"
          OsVersion = "10.0.20348"
          OsBuildNumber = "20348"
          OsArchitecture = "64-bit"
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
          HostUptimeSeconds = 345600
          HostBootTimeKnown = $true
          ServiceUptimeSeconds = 259200
          MinimumUptimeHours = 72
          MinimumSatisfied = $true
          ServiceStartKnown = $true
          ServiceStartedDuringCurrentBoot = $true
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
    },
    @{
      Name = "windows-11.json"
      Data = [ordered]@{
        EvidenceSchemaVersion = 1
        EvidenceCollection = $windowsCollectionEvidence
        SupportTargetId = "windows-11"
        GeneratedAtUtc = $now
        AppName = "example-next-app"
        Platform = [ordered]@{
          Family = "windows"
          SupportTargetId = "windows-11"
          OsCaption = "Microsoft Windows 11 Pro"
          OsVersion = "10.0.22631"
          OsBuildNumber = "22631"
          OsArchitecture = "64-bit"
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
          ProcessId = 2234
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
          HostUptimeSeconds = 345600
          HostBootTimeKnown = $true
          ServiceUptimeSeconds = 259200
          MinimumUptimeHours = 72
          MinimumSatisfied = $true
          ServiceStartKnown = $true
          ServiceStartedDuringCurrentBoot = $true
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
          PackageSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
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
        evidenceCollection = $unixCollectionEvidence
        supportTargetId = "ubuntu"
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "systemd"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        serviceDefinition = $systemdServiceDefinitionEvidence
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
          nodeVersion = "v20.11.1"
          minimumNodeVersion = "20.9.0"
          nodeVersionSatisfied = $true
          nextVersion = "14.2.3"
          nextPackageJsonExists = $true
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
          supportTargetId = "ubuntu"
          kernelName = "Linux"
          kernelRelease = "6.8.0"
          machine = "x86_64"
          osId = "ubuntu"
          osIdLike = "debian"
          osVersionId = "24.04"
          osPrettyName = "Ubuntu 24.04 LTS"
          libcName = "glibc"
          libcVersion = "2.39"
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
        evidenceCollection = $unixCollectionEvidence
        supportTargetId = "macos"
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "launchd"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        serviceDefinition = $launchdServiceDefinitionEvidence
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
          nodeVersion = "v20.11.1"
          minimumNodeVersion = "20.9.0"
          nodeVersionSatisfied = $true
          nextVersion = "14.2.3"
          nextPackageJsonExists = $true
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
          supportTargetId = "macos"
          kernelName = "Darwin"
          kernelRelease = "24.0.0"
          machine = "arm64"
          osVersionId = "15.0"
          osPrettyName = "Apple macOS 15"
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
        evidenceCollection = $unixCollectionEvidence
        supportTargetId = "freebsd"
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        serviceDefinition = $bsdrcServiceDefinitionEvidence
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
          nodeVersion = "v20.11.1"
          minimumNodeVersion = "20.9.0"
          nodeVersionSatisfied = $true
          nextVersion = "14.2.3"
          nextPackageJsonExists = $true
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
          supportTargetId = "freebsd"
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
        evidenceCollection = $unixCollectionEvidence
        supportTargetId = "openbsd"
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        serviceDefinition = $bsdrcServiceDefinitionEvidence
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
          nodeVersion = "v20.11.1"
          minimumNodeVersion = "20.9.0"
          nodeVersionSatisfied = $true
          nextVersion = "14.2.3"
          nextPackageJsonExists = $true
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
          supportTargetId = "openbsd"
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
        evidenceCollection = $unixCollectionEvidence
        supportTargetId = "netbsd"
        generatedAtUtc = $now
        appName = "example-next-app"
        serviceName = "example-next-app"
        serviceManager = "bsdrc"
        serviceActiveStatus = "active"
        serviceEnabledStatus = "enabled"
        serviceDefinition = $bsdrcServiceDefinitionEvidence
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
          nodeVersion = "v20.11.1"
          minimumNodeVersion = "20.9.0"
          nodeVersionSatisfied = $true
          nextVersion = "14.2.3"
          nextPackageJsonExists = $true
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
          supportTargetId = "netbsd"
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

function Invoke-ExpectHostEvidenceFailure {
  param(
    [hashtable]$Parameters,
    [string]$ExpectedMessage
  )

  $failed = $false
  $outputText = ""
  try {
    $output = & $PSCommandPath @Parameters 6>&1 2>&1
    $outputText = ($output | Out-String)
  } catch {
    $failed = $true
    $outputText = $_.Exception.Message
  }

  if (-not $failed) {
    throw "Expected host evidence validation failure containing '$ExpectedMessage', but validation succeeded."
  }
  if ($outputText -notlike "*$ExpectedMessage*") {
    throw "Expected host evidence validation failure containing '$ExpectedMessage', got: $outputText"
  }
  if ($outputText.Contains($RepoRoot)) {
    throw "Host evidence validation self-test leaked the repository absolute path in failure output."
  }
}

function Invoke-ExpectHostEvidenceSuccess {
  param(
    [hashtable]$Parameters,
    [string]$Name
  )

  try {
    $null = & $PSCommandPath @Parameters 6>&1 2>&1
  } catch {
    throw "Expected host evidence validation success for '$Name', got: $($_.Exception.Message)"
  }
}

function Test-EvidenceFile {
  param(
    [System.IO.FileInfo]$File,
    [System.Collections.Generic.List[string]]$Issues
  )

  $displayFile = Get-DisplayPath -Path $File.FullName -BasePath $EvidencePath

  try {
    $raw = Get-Content -Path $File.FullName -Raw
    $evidence = $raw | ConvertFrom-Json
  } catch {
    $Issues.Add("$displayFile is not valid JSON: $($_.Exception.Message)") | Out-Null
    return $null
  }

  $appName = Get-StringValue -Object $evidence -Names @("AppName", "appName")
  $generatedAt = Get-StringValue -Object $evidence -Names @("GeneratedAtUtc", "generatedAtUtc")
  $verdict = Get-StringValue -Object $evidence -Names @("Verdict", "verdict")
  $critical = Get-IntegerValue -Object $evidence -Names @("Critical", "critical")
  $warnings = Get-IntegerValue -Object $evidence -Names @("Warnings", "warnings")
  $hasFindings = Test-PropertyExists -Object $evidence -Names @("Findings", "findings")
  $supportTargetId = Get-SupportTargetId -Evidence $evidence
  $targets = @(Get-EvidenceTargets -Evidence $evidence)
  $platformTargets = @(Get-PlatformEvidenceTargets -Evidence $evidence)
  $serviceManager = Get-ServiceManager -Evidence $evidence
  $serviceEvidence = Get-ServiceEvidence -Evidence $evidence
  $portEvidence = Get-PortEvidence -Evidence $evidence
  $healthEvidence = Get-HealthEvidence -Evidence $evidence
  $uptimeEvidence = Get-UptimeEvidence -Evidence $evidence
  $healthMonitorEvidence = Get-HealthMonitorEvidence -Evidence $evidence
  $nextJsEvidence = Get-NextJsEvidence -Evidence $evidence
  $reverseProxyEvidence = Get-ReverseProxyEvidence -Evidence $evidence
  $deploymentIdentityEvidence = Get-DeploymentIdentityEvidence -Evidence $evidence
  $collectionEvidence = Get-EvidenceCollectionEvidence -Evidence $evidence
  $nextJsMode = Normalize-Target $nextJsEvidence.Mode
  $reverseProxyMode = Normalize-ReverseProxy $reverseProxyEvidence.Mode
  $nextJsRawEvidence = Get-PropertyValue -Object $evidence -Names @("NextJsRuntime", "nextJsRuntime")
  $deploymentIdentityRawEvidence = Get-PropertyValue -Object $evidence -Names @("DeploymentIdentity", "deploymentIdentity")
  $findingsValue = Get-PropertyValue -Object $evidence -Names @("Findings", "findings")
  $topLevelSynthetic = Get-BooleanValue -Object $evidence -Names @("Synthetic", "synthetic") -Default $false
  $topLevelMock = Get-BooleanValue -Object $evidence -Names @("Mock", "mock") -Default $false
  $topLevelSample = Get-BooleanValue -Object $evidence -Names @("Sample", "sample") -Default $false

  if (-not $appName) {
    $Issues.Add("$displayFile is missing app name.") | Out-Null
  }
  if (-not $collectionEvidence.Source -and -not $collectionEvidence.Collector) {
    $Issues.Add("$displayFile is missing evidenceCollection source/collector metadata from the live status collector.") | Out-Null
  } elseif (-not (Test-SupportedEvidenceCollector -Collection $collectionEvidence)) {
    $Issues.Add("$displayFile does not identify a supported node-enterprise-deploy-kit live status collector.") | Out-Null
  }
  if ($null -eq $collectionEvidence.CollectorVersion -or $collectionEvidence.CollectorVersion -lt 1) {
    $Issues.Add("$displayFile is missing a valid evidence collector version.") | Out-Null
  }
  if ($collectionEvidence.CollectorSha256 -and $collectionEvidence.CollectorSha256 -notmatch '^[a-f0-9]{64}$') {
    $Issues.Add("$displayFile has an invalid evidence collector SHA256 digest.") | Out-Null
  }
  if ($RequireCollectorSha256 -and [string]::IsNullOrWhiteSpace($collectionEvidence.CollectorSha256)) {
    $Issues.Add("$displayFile is missing evidence collector SHA256 digest required for strict support claims.") | Out-Null
  }
  if ($collectionEvidence.LiveHost -ne $true) {
    $Issues.Add("$displayFile does not declare live-host collection.") | Out-Null
  }
  $missingCollectionMarkers = @()
  if ($null -eq $collectionEvidence.Synthetic) { $missingCollectionMarkers += "synthetic" }
  if ($null -eq $collectionEvidence.Mock) { $missingCollectionMarkers += "mock" }
  if ($null -eq $collectionEvidence.Sample) { $missingCollectionMarkers += "sample" }
  if ($missingCollectionMarkers.Count -gt 0) {
    $Issues.Add("$displayFile is missing explicit evidenceCollection anti-synthetic marker(s): $($missingCollectionMarkers -join ', ').") | Out-Null
  } elseif ($collectionEvidence.Synthetic -ne $false -or $collectionEvidence.Mock -ne $false -or $collectionEvidence.Sample -ne $false -or $topLevelSynthetic -eq $true -or $topLevelMock -eq $true -or $topLevelSample -eq $true) {
    $Issues.Add("$displayFile declares synthetic, mock, or sample evidence and cannot prove a real-host support claim.") | Out-Null
  }
  foreach ($ciIssue in @(Get-CollectionCiIssues -Ci $collectionEvidence.Ci -FileName $displayFile)) {
    $Issues.Add($ciIssue) | Out-Null
  }
  $collectionCiProvider = ([string]$collectionEvidence.Ci.Provider).Trim().ToLowerInvariant()
  $collectionCiWorkflowName = ([string]$collectionEvidence.Ci.WorkflowName).Trim().ToLowerInvariant()
  $collectionCiEventName = ([string]$collectionEvidence.Ci.EventName).Trim().ToLowerInvariant()
  if ($RequireCiCollection -and ($collectionEvidence.Ci.IsCi -ne $true -or [string]::IsNullOrWhiteSpace($collectionCiProvider))) {
    $Issues.Add("$displayFile does not prove CI collection provenance required for strict support claims.") | Out-Null
  }
  if ($RequireHostEvidenceWorkflowCollection -and (
      $collectionEvidence.Ci.IsCi -ne $true -or
      $collectionCiProvider -ne "github-actions" -or
      $collectionCiWorkflowName -ne "host-evidence" -or
      $collectionCiEventName -ne "workflow_dispatch"
    )) {
    $Issues.Add("$displayFile does not prove controlled host-evidence workflow_dispatch collection provenance.") | Out-Null
  }
  if ($RequireHostEvidenceWorkflowCollection) {
    foreach ($workflowDispatchIssue in @(Get-WorkflowDispatchDimensionIssues -Dispatch $collectionEvidence.WorkflowDispatch -FileName $displayFile -TargetId $supportTargetId -NextJsMode $nextJsMode -ServiceManager $serviceManager -ReverseProxy $reverseProxyMode -RequiredMinimumUptimeHours $RequireMinimumUptimeHours -ExpectedMatrixPath $ExpectedMatrixPath -ExpectedMatrixSha256 $ExpectedMatrixSha256)) {
      $Issues.Add($workflowDispatchIssue) | Out-Null
    }
  }
  if (Test-PropertyExists -Object $evidence -Names @("ComputerName", "computerName", "HostName", "hostName", "MachineName", "machineName")) {
    $Issues.Add("$displayFile contains a raw host identity field. Use a private evidence folder name or an external release record instead.") | Out-Null
  }
  if (Test-PropertyExists -Object $evidence -Names @("ConfigPath", "configPath")) {
    $Issues.Add("$displayFile contains raw config path metadata. Status JSON should emit ConfigFileName/configFileName only.") | Out-Null
  }
  if (Test-PropertyExists -Object $nextJsRawEvidence -Names @("RuntimeRoot", "runtimeRoot")) {
    $Issues.Add("$displayFile contains raw Next.js runtime path metadata. Status JSON should emit RuntimeRootName/runtimeRootName only.") | Out-Null
  }
  if (Test-PropertyExists -Object $deploymentIdentityRawEvidence -Names @("AppDirectory", "appDirectory")) {
    $Issues.Add("$displayFile contains raw app directory metadata. Status JSON should emit AppDirectoryName/appDirectoryName only.") | Out-Null
  }
  foreach ($finding in @($findingsValue)) {
    $message = Get-StringValue -Object $finding -Names @("Message", "message")
    if (Test-UnsafeEvidenceText $message) {
      $Issues.Add("$displayFile contains a finding message with an unsafe raw path. Status JSON should redact paths in findings.") | Out-Null
      break
    }
  }
  if (-not $generatedAt) {
    $Issues.Add("$displayFile is missing generated timestamp.") | Out-Null
  } else {
    try {
      $generatedDate = [DateTime]::Parse($generatedAt).ToUniversalTime()
      $nowUtc = (Get-Date).ToUniversalTime()
      if ($generatedDate -gt $nowUtc.AddMinutes(5)) {
        $Issues.Add("$displayFile has a generated timestamp in the future: $generatedAt") | Out-Null
      }
      if ($MaxEvidenceAgeDays -gt 0 -and ($nowUtc - $generatedDate).TotalDays -gt $MaxEvidenceAgeDays) {
        $Issues.Add("$displayFile is older than $MaxEvidenceAgeDays day(s).") | Out-Null
      }
    } catch {
      $Issues.Add("$displayFile has an invalid generated timestamp: $generatedAt") | Out-Null
    }
  }
  if ($verdict -notin @("Healthy", "Warning", "Critical")) {
    $Issues.Add("$displayFile has invalid verdict: $verdict") | Out-Null
  }
  if ($null -eq $critical) {
    $Issues.Add("$displayFile is missing critical count.") | Out-Null
  } elseif ($critical -gt 0) {
    $Issues.Add("$displayFile has $critical critical finding(s).") | Out-Null
  }
  if ($null -eq $warnings) {
    $Issues.Add("$displayFile is missing warning count.") | Out-Null
  } elseif ($FailOnWarnings -and $warnings -gt 0) {
    $Issues.Add("$displayFile has $warnings warning finding(s).") | Out-Null
  }
  if (-not $hasFindings) {
    $Issues.Add("$displayFile is missing findings array.") | Out-Null
  }
  if (-not $supportTargetId) {
    $Issues.Add("$displayFile is missing supportTargetId metadata required for matrix-level support claims.") | Out-Null
  } elseif ($platformTargets -notcontains $supportTargetId) {
    $Issues.Add("$displayFile has supportTargetId '$supportTargetId' that is not corroborated by platform metadata: $($platformTargets -join ', ').") | Out-Null
  }
  if ($platformTargets.Count -eq 0) {
    $Issues.Add("$displayFile has no recognizable platform target metadata.") | Out-Null
  }
  if (-not (Test-ServiceActiveEvidence -Status $serviceEvidence.ActiveStatus)) {
    $Issues.Add("$displayFile does not prove an active service state (status: $($serviceEvidence.ActiveStatus)).") | Out-Null
  }
  if (-not (Test-ServiceEnabledEvidence -Status $serviceEvidence.EnabledStatus)) {
    $Issues.Add("$displayFile does not prove service boot enablement (status: $($serviceEvidence.EnabledStatus)).") | Out-Null
  }
  if ($serviceManager -in @("winsw", "nssm", "pm2", "systemd", "systemv", "openrc", "launchd", "bsdrc")) {
    if ($serviceEvidence.DefinitionChecked -ne $true) {
      $Issues.Add("$displayFile does not prove the managed service definition was checked.") | Out-Null
    }
    if ($serviceEvidence.DefinitionExists -ne $true) {
      $Issues.Add("$displayFile does not prove the managed service definition exists.") | Out-Null
    }
    if ($serviceManager -eq "winsw" -and $serviceEvidence.ServiceWrapperMatchesConfig -ne $true) {
      $Issues.Add("$displayFile does not prove the WinSW service wrapper path matches the current ServiceDirectory/AppName.") | Out-Null
    }
    if ($serviceEvidence.NodeExeMatchesConfig -ne $true) {
      $Issues.Add("$displayFile does not prove the managed service Node executable matches the current config.") | Out-Null
    }
    if ($serviceEvidence.WorkingDirectoryMatchesConfig -ne $true) {
      $Issues.Add("$displayFile does not prove the managed service working directory matches the current app directory.") | Out-Null
    }
    if ($serviceEvidence.ArgumentsMatchConfig -ne $true) {
      $Issues.Add("$displayFile does not prove the managed service arguments match the current start command and arguments.") | Out-Null
    }
    if ($serviceManager -eq "launchd" -and $serviceEvidence.RunnerScriptMatchesConfig -ne $true) {
      $Issues.Add("$displayFile does not prove the launchd service plist references the configured runner script.") | Out-Null
    }
  }
  if ($portEvidence.Checked -ne $true) {
    $Issues.Add("$displayFile does not prove the configured app port check was performed.") | Out-Null
  }
  if ($portEvidence.Listening -ne $true) {
    $Issues.Add("$displayFile does not prove the configured app port is listening.") | Out-Null
  }
  if ($portEvidence.OwnerReadable -ne $true) {
    $Issues.Add("$displayFile does not prove configured app port owner PID(s) were readable.") | Out-Null
  }
  if ($null -eq $portEvidence.OwnerProcessCount -or $portEvidence.OwnerProcessCount -lt 1) {
    $Issues.Add("$displayFile does not prove at least one owner process for the configured app port.") | Out-Null
  }
  if ($portEvidence.ServicePidKnown -ne $true) {
    $Issues.Add("$displayFile does not prove the service process ID was known for port ownership comparison.") | Out-Null
  }
  if ($portEvidence.OwnedByService -ne $true) {
    $Issues.Add("$displayFile does not prove the configured app port is owned by the configured service process.") | Out-Null
  }
  if ($healthEvidence.Checked -ne $true) {
    $Issues.Add("$displayFile does not prove the HTTP health probe was performed.") | Out-Null
  }
  if ($healthEvidence.Status -ne "ok") {
    $Issues.Add("$displayFile does not prove HTTP health status ok (status: $($healthEvidence.Status)).") | Out-Null
  }
  if ($null -eq $healthEvidence.StatusCode -or $healthEvidence.StatusCode -lt 200 -or $healthEvidence.StatusCode -ge 400) {
    $Issues.Add("$displayFile does not prove a successful HTTP health status code.") | Out-Null
  }
  if ($uptimeEvidence.ServiceStartKnown -ne $true) {
    $Issues.Add("$displayFile does not prove service start time / service process uptime was known.") | Out-Null
  }
  if ($uptimeEvidence.HostBootTimeKnown -ne $true) {
    $Issues.Add("$displayFile does not prove host boot-session timing was known.") | Out-Null
  }
  if ($uptimeEvidence.ServiceStartedDuringCurrentBoot -ne $true) {
    $Issues.Add("$displayFile does not prove the service started during the current host boot session.") | Out-Null
  }
  if ($null -eq $uptimeEvidence.ServiceUptimeSeconds -or $uptimeEvidence.ServiceUptimeSeconds -lt 0) {
    $Issues.Add("$displayFile does not prove service process uptime seconds.") | Out-Null
  }
  if ($null -ne $uptimeEvidence.MinimumUptimeHours -and $uptimeEvidence.MinimumUptimeHours -gt 0 -and $uptimeEvidence.MinimumSatisfied -ne $true) {
    $Issues.Add("$displayFile does not prove the requested minimum uptime window was satisfied.") | Out-Null
  }
  if ($RequireMinimumUptimeHours -gt 0) {
    $requiredMinimumSeconds = [int64]$RequireMinimumUptimeHours * 3600
    if ($null -eq $uptimeEvidence.MinimumUptimeHours -or $uptimeEvidence.MinimumUptimeHours -lt $RequireMinimumUptimeHours) {
      $Issues.Add("$displayFile does not prove required minimum uptime evidence of $RequireMinimumUptimeHours hour(s).") | Out-Null
    }
    if ($uptimeEvidence.MinimumSatisfied -ne $true) {
      $Issues.Add("$displayFile does not prove the required minimum uptime window was satisfied.") | Out-Null
    }
    if ($null -eq $uptimeEvidence.ServiceUptimeSeconds -or $uptimeEvidence.ServiceUptimeSeconds -lt $requiredMinimumSeconds) {
      $Issues.Add("$displayFile does not prove service uptime reached the required $RequireMinimumUptimeHours hour window.") | Out-Null
    }
  }
  if ($healthMonitorEvidence.Status -ne "ok") {
    $Issues.Add("$displayFile does not prove health monitor status ok (status: $($healthMonitorEvidence.Status)).") | Out-Null
  }
  if ($healthMonitorEvidence.Scheduled -ne $true) {
    $Issues.Add("$displayFile does not prove a recurring health monitor has run.") | Out-Null
  }
  if ([string]::IsNullOrWhiteSpace($healthMonitorEvidence.ScheduleType)) {
    $Issues.Add("$displayFile does not identify the health monitor schedule type.") | Out-Null
  }
  if ($healthMonitorEvidence.StateExists -ne $true) {
    $Issues.Add("$displayFile does not prove health monitor state exists.") | Out-Null
  }
  if ($healthMonitorEvidence.LastSuccessFresh -ne $true) {
    $Issues.Add("$displayFile does not prove a recent successful health monitor run.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.ConsecutiveFailures -or $healthMonitorEvidence.ConsecutiveFailures -ne 0) {
    $Issues.Add("$displayFile does not prove zero consecutive health monitor failures.") | Out-Null
  }
  if ($healthMonitorEvidence.LogExists -ne $true) {
    $Issues.Add("$displayFile does not prove health monitor log summary exists.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.LogFailureCount -or $healthMonitorEvidence.LogFailureCount -ne 0) {
    $Issues.Add("$displayFile does not prove zero recent health monitor failures in the log summary.") | Out-Null
  }
  if ($null -eq $healthMonitorEvidence.LogRestartCount -or $healthMonitorEvidence.LogRestartCount -ne 0) {
    $Issues.Add("$displayFile does not prove zero recent health monitor restarts in the log summary.") | Out-Null
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "windows-task") {
    if ($healthMonitorEvidence.TaskExists -ne $true) {
      $Issues.Add("$displayFile does not prove the Windows health check scheduled task exists.") | Out-Null
    }
    if ($healthMonitorEvidence.TaskActionChecked -ne $true) {
      $Issues.Add("$displayFile does not prove the Windows health check scheduled task action was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.TaskActionUsesHealthCheckScript -ne $true) {
      $Issues.Add("$displayFile does not prove the Windows health check scheduled task runs this kit's health-check script.") | Out-Null
    }
    if ($healthMonitorEvidence.TaskActionUsesConfigPath -ne $true) {
      $Issues.Add("$displayFile does not prove the Windows health check scheduled task uses the current config path.") | Out-Null
    }
    if ($null -eq $healthMonitorEvidence.TaskMissedRuns -or $healthMonitorEvidence.TaskMissedRuns -ne 0) {
      $Issues.Add("$displayFile does not prove zero missed Windows health check task runs.") | Out-Null
    }
    if ($null -eq $healthMonitorEvidence.TaskLastResult -or $healthMonitorEvidence.TaskLastResult -ne 0) {
      $Issues.Add("$displayFile does not prove the Windows health check scheduled task last result was successful.") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "systemd-timer") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$displayFile does not prove the systemd healthcheck timer was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$displayFile does not prove the systemd healthcheck timer exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$displayFile does not prove the systemd healthcheck timer is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$displayFile does not prove the systemd healthcheck timer is enabled for boot (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "launchd-timer") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$displayFile does not prove the launchd healthcheck scheduler was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$displayFile does not prove the launchd healthcheck plist exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$displayFile does not prove the launchd healthcheck job is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$displayFile does not prove the launchd healthcheck job is enabled (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ((Normalize-Target $healthMonitorEvidence.ScheduleType) -eq "cron") {
    if ($healthMonitorEvidence.SchedulerChecked -ne $true) {
      $Issues.Add("$displayFile does not prove the cron healthcheck scheduler was checked.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerExists -ne $true) {
      $Issues.Add("$displayFile does not prove the managed cron healthcheck entry exists.") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerActive -ne $true) {
      $Issues.Add("$displayFile does not prove the cron daemon is active (status: $($healthMonitorEvidence.SchedulerActiveStatus)).") | Out-Null
    }
    if ($healthMonitorEvidence.SchedulerEnabled -ne $true) {
      $Issues.Add("$displayFile does not prove the cron healthcheck entry is persistent (status: $($healthMonitorEvidence.SchedulerEnabledStatus)).") | Out-Null
    }
  }
  if ($RequireNextJs) {
    if (-not (Test-NextJsFrameworkEvidence -Value $nextJsEvidence.AppFramework)) {
      $Issues.Add("$displayFile does not prove AppFramework=nextjs (value: $($nextJsEvidence.AppFramework)).") | Out-Null
    }
    if ($nextJsEvidence.Mode -notin @("standalone", "next-start")) {
      $Issues.Add("$displayFile does not prove a valid Next.js deployment mode (value: $($nextJsEvidence.Mode)).") | Out-Null
    }
    if (-not $nextJsEvidence.Applicable) {
      $Issues.Add("$displayFile does not prove Next.js runtime layout validation was applicable.") | Out-Null
    }
    if ($nextJsEvidence.Status -ne "ok") {
      $Issues.Add("$displayFile does not prove a successful Next.js runtime layout check (status: $($nextJsEvidence.Status)).") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($nextJsEvidence.NodeVersion)) {
      $Issues.Add("$displayFile does not prove the active Node.js runtime version used by the Next.js service.") | Out-Null
    }
    if (-not (Test-SafeRuntimeVersionEvidence -Value $nextJsEvidence.NodeVersion)) {
      $Issues.Add("$displayFile contains an unsafe Node.js runtime version value in Next.js evidence.") | Out-Null
    }
    if (-not (Test-SafeRuntimeVersionEvidence -Value $nextJsEvidence.MinimumNodeVersion)) {
      $Issues.Add("$displayFile contains an unsafe minimum Node.js version value in Next.js evidence.") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($nextJsEvidence.MinimumNodeVersion)) {
      $Issues.Add("$displayFile does not prove the minimum Node.js version required for Next.js.") | Out-Null
    }
    if ($nextJsEvidence.NodeVersionSatisfied -ne $true) {
      $Issues.Add("$displayFile does not prove the configured Node.js runtime satisfies the Next.js minimum version requirement.") | Out-Null
    }
    if ((Normalize-Target $nextJsEvidence.Mode) -eq "next-start" -and $nextJsEvidence.NextStartScriptIsExpectedCli -ne $true) {
      $Issues.Add("$displayFile does not prove Next.js next-start uses node_modules/next/dist/bin/next.") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($nextJsEvidence.NextVersion)) {
      $Issues.Add("$displayFile does not prove the installed Next.js package version.") | Out-Null
    }
    if ($nextJsEvidence.NextPackageJsonExists -ne $true) {
      $Issues.Add("$displayFile does not prove node_modules/next/package.json exists in the active Next.js runtime.") | Out-Null
    }
    if (-not (Test-SafeRuntimeVersionEvidence -Value $nextJsEvidence.NextVersion)) {
      $Issues.Add("$displayFile contains an unsafe Next.js package version value in Next.js evidence.") | Out-Null
    }
    foreach ($platformRuntimeIssue in @(Get-NextJsPlatformRuntimeIssues -Evidence $evidence -SupportTargetId $supportTargetId -FileName $displayFile)) {
      $Issues.Add($platformRuntimeIssue) | Out-Null
    }
  }
  if ($RequireReverseProxy) {
    $normalizedProxyMode = Normalize-Target $reverseProxyEvidence.Mode
    $serviceOnlyReverseProxy = ($AllowReverseProxyNone -and $normalizedProxyMode -eq "none")
    if ((-not $serviceOnlyReverseProxy) -and -not $reverseProxyEvidence.Applicable) {
      $Issues.Add("$displayFile does not prove a reverse-proxy check was applicable.") | Out-Null
    }
    if ((-not $serviceOnlyReverseProxy) -and ($normalizedProxyMode -in @("", "none", "unknown"))) {
      $Issues.Add("$displayFile does not prove a configured reverse-proxy mode (value: $($reverseProxyEvidence.Mode)).") | Out-Null
    }
    if ($serviceOnlyReverseProxy -and ((Normalize-Target $reverseProxyEvidence.Status) -notin @("not-applicable", "none", "disabled", "skipped"))) {
      $Issues.Add("$displayFile does not prove reverse-proxy mode 'none' is explicitly not applicable (status: $($reverseProxyEvidence.Status)).") | Out-Null
    }
    if ((-not $serviceOnlyReverseProxy) -and $reverseProxyEvidence.Status -ne "ok") {
      $Issues.Add("$displayFile does not prove a successful reverse-proxy health probe (status: $($reverseProxyEvidence.Status)).") | Out-Null
    }
    if ((-not $serviceOnlyReverseProxy) -and ($null -eq $reverseProxyEvidence.StatusCode -or $reverseProxyEvidence.StatusCode -lt 200 -or $reverseProxyEvidence.StatusCode -ge 400)) {
      $Issues.Add("$displayFile does not prove a successful reverse-proxy HTTP status code.") | Out-Null
    }
    if ($normalizedProxyMode -eq "iis") {
      if ($reverseProxyEvidence.IisModuleAvailable -ne $true) {
        $Issues.Add("$displayFile does not prove IIS WebAdministration evidence was available.") | Out-Null
      }
      if ($reverseProxyEvidence.IisSiteExists -ne $true) {
        $Issues.Add("$displayFile does not prove the configured IIS site exists.") | Out-Null
      }
      if ($reverseProxyEvidence.IisSiteStarted -ne $true) {
        $Issues.Add("$displayFile does not prove the configured IIS site is started.") | Out-Null
      }
      if ($reverseProxyEvidence.IisSitePathMatchesConfig -ne $true) {
        $Issues.Add("$displayFile does not prove the IIS site physical path matches the configured IisSitePath.") | Out-Null
      }
      if ($reverseProxyEvidence.IisBindingMatchesConfig -ne $true) {
        $Issues.Add("$displayFile does not prove the configured IIS site owns the expected public binding.") | Out-Null
      }
      if ($reverseProxyEvidence.IisDuplicateBindingConflict -eq $true) {
        $Issues.Add("$displayFile reports an IIS duplicate binding conflict.") | Out-Null
      }
    }
    if ($normalizedProxyMode -in @("nginx", "apache", "httpd", "haproxy", "traefik")) {
      if ($reverseProxyEvidence.ConfigApplicable -ne $true) {
        $Issues.Add("$displayFile does not prove reverse-proxy config evidence was applicable for mode '$($reverseProxyEvidence.Mode)'.") | Out-Null
      }
      if ($reverseProxyEvidence.ConfigExists -ne $true) {
        $Issues.Add("$displayFile does not prove the expected reverse-proxy config file exists.") | Out-Null
      }
      if ($reverseProxyEvidence.ConfigManagedMarkerFound -ne $true) {
        $Issues.Add("$displayFile does not prove the reverse-proxy config contains this kit's managed marker for the app.") | Out-Null
      }
    }
  }
  if ($RequireDeploymentIdentity) {
    if ($deploymentIdentityEvidence.Status -ne "ok") {
      $Issues.Add("$displayFile does not prove deployment identity status ok (status: $($deploymentIdentityEvidence.Status)).") | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.DeploymentId) -and [string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.NextBuildId)) {
      if ([string]::IsNullOrWhiteSpace($deploymentIdentityEvidence.PackageSha256)) {
        $Issues.Add("$displayFile does not prove a deployment ID, Next.js build ID, or package SHA256.") | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    File = $displayFile
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
    Collection = "$($collectionEvidence.Collector)/live=$($collectionEvidence.LiveHost)"
    SupportTargetId = $supportTargetId
    NextJsMode = $nextJsMode
    ServiceManager = $serviceManager
    ReverseProxy = $reverseProxyMode
    Targets = ($targets -join ",")
  }
}

Write-Step "Host evidence validation"

if ($SelfTest) {
  $EvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-selftest-$([Guid]::NewGuid().ToString('N'))"
  if ($RequiredTargets.Count -eq 0) {
    $RequiredTargets = @("windows-11", "windows-server", "linux", "macos", "freebsd", "openbsd", "netbsd")
  }
  $RequireCollectorSha256 = $true
  if ($RequireMinimumUptimeHours -le 0) {
    $RequireMinimumUptimeHours = 72
  }
  New-SelfTestEvidence -Path $EvidencePath

  Invoke-ExpectHostEvidenceSuccess -Name "expected Windows Server standalone WinSW IIS evidence" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
  }

  Invoke-ExpectHostEvidenceSuccess -Name "single-file expected Windows Server standalone WinSW IIS evidence" -Parameters @{
    EvidencePath = (Join-Path $EvidencePath "windows-server-2022.json")
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
  }

  $nonJsonEvidenceFile = Join-Path $EvidencePath "not-json.txt"
  "not json" | Set-Content -Path $nonJsonEvidenceFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "Host evidence file must be a JSON file" -Parameters @{
    EvidencePath = $nonJsonEvidenceFile
    RequireNextJs = $true
  }

  $stoppedIisEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-stopped-iis-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $stoppedIisEvidencePath
  $stoppedIisFile = Join-Path $stoppedIisEvidencePath "windows-server-2022.json"
  $stoppedIisEvidence = Get-Content -LiteralPath $stoppedIisFile -Raw | ConvertFrom-Json
  $stoppedIisEvidence.reverseProxy.iis.siteState = "Stopped"
  $stoppedIisEvidence.reverseProxy.iis.siteStarted = $false
  $stoppedIisEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $stoppedIisFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "configured IIS site is started" -Parameters @{
    EvidencePath = $stoppedIisEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
  }

  $wrongHealthConfigEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-health-task-config-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $wrongHealthConfigEvidencePath
  $wrongHealthConfigFile = Join-Path $wrongHealthConfigEvidencePath "windows-server-2022.json"
  $wrongHealthConfigEvidence = Get-Content -LiteralPath $wrongHealthConfigFile -Raw | ConvertFrom-Json
  $wrongHealthConfigEvidence.healthMonitor.taskActionUsesConfigPath = $false
  $wrongHealthConfigEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $wrongHealthConfigFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "Windows health check scheduled task uses the current config path" -Parameters @{
    EvidencePath = $wrongHealthConfigEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
  }

  $wrongServiceDefinitionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-service-definition-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $wrongServiceDefinitionEvidencePath
  $wrongServiceDefinitionFile = Join-Path $wrongServiceDefinitionEvidencePath "windows-server-2022.json"
  $wrongServiceDefinitionEvidence = Get-Content -LiteralPath $wrongServiceDefinitionFile -Raw | ConvertFrom-Json
  $wrongServiceDefinitionEvidence.serviceDefinition.workingDirectoryMatchesConfig = $false
  $wrongServiceDefinitionEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $wrongServiceDefinitionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "managed service working directory matches the current app directory" -Parameters @{
    EvidencePath = $wrongServiceDefinitionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
  }

  Invoke-ExpectHostEvidenceSuccess -Name "expected Ubuntu standalone systemd nginx evidence" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  $wrongUnixServiceDefinitionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-unix-service-definition-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $wrongUnixServiceDefinitionEvidencePath
  $wrongUnixServiceDefinitionFile = Join-Path $wrongUnixServiceDefinitionEvidencePath "ubuntu.json"
  $wrongUnixServiceDefinitionEvidence = Get-Content -LiteralPath $wrongUnixServiceDefinitionFile -Raw | ConvertFrom-Json
  $wrongUnixServiceDefinitionEvidence.serviceDefinition.argumentsMatchConfig = $false
  $wrongUnixServiceDefinitionEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $wrongUnixServiceDefinitionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "managed service arguments match the current start command and arguments" -Parameters @{
    EvidencePath = $wrongUnixServiceDefinitionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  $oldLinuxRuntimeEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-linux-runtime-floor-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $oldLinuxRuntimeEvidencePath
  $oldLinuxRuntimeFile = Join-Path $oldLinuxRuntimeEvidencePath "ubuntu.json"
  $oldLinuxRuntimeEvidence = Get-Content -LiteralPath $oldLinuxRuntimeFile -Raw | ConvertFrom-Json
  $oldLinuxRuntimeEvidence.platform.kernelRelease = "4.17.0"
  $oldLinuxRuntimeEvidence.platform.libcVersion = "2.27"
  $oldLinuxRuntimeEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $oldLinuxRuntimeFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "below the Node.js 20.x floor" -Parameters @{
    EvidencePath = $oldLinuxRuntimeEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  $oldMacosRuntimeEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-macos-runtime-floor-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $oldMacosRuntimeEvidencePath
  $oldMacosRuntimeFile = Join-Path $oldMacosRuntimeEvidencePath "macos.json"
  $oldMacosRuntimeEvidence = Get-Content -LiteralPath $oldMacosRuntimeFile -Raw | ConvertFrom-Json
  $oldMacosRuntimeEvidence.platform.machine = "arm64"
  $oldMacosRuntimeEvidence.platform.osVersionId = "10.15"
  $oldMacosRuntimeEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $oldMacosRuntimeFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "below the Node.js 20.x floor" -Parameters @{
    EvidencePath = $oldMacosRuntimeEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "macos"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "launchd"
    ExpectedReverseProxy = "nginx"
  }

  $wrongLaunchdRunnerEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-launchd-runner-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $wrongLaunchdRunnerEvidencePath
  $wrongLaunchdRunnerFile = Join-Path $wrongLaunchdRunnerEvidencePath "macos.json"
  $wrongLaunchdRunnerEvidence = Get-Content -LiteralPath $wrongLaunchdRunnerFile -Raw | ConvertFrom-Json
  $wrongLaunchdRunnerEvidence.serviceDefinition.runnerScriptMatchesConfig = $false
  $wrongLaunchdRunnerEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $wrongLaunchdRunnerFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "launchd service plist references the configured runner script" -Parameters @{
    EvidencePath = $wrongLaunchdRunnerEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "macos"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "launchd"
    ExpectedReverseProxy = "nginx"
  }

  $wrongSupportTargetEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-support-target-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $wrongSupportTargetEvidencePath
  $wrongSupportTargetFile = Join-Path $wrongSupportTargetEvidencePath "ubuntu.json"
  $wrongSupportTargetEvidence = Get-Content -LiteralPath $wrongSupportTargetFile -Raw | ConvertFrom-Json
  $wrongSupportTargetEvidence.supportTargetId = "windows-server-2022"
  $wrongSupportTargetEvidence.platform.supportTargetId = "windows-server-2022"
  $wrongSupportTargetEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $wrongSupportTargetFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "not corroborated by platform metadata" -Parameters @{
    EvidencePath = $wrongSupportTargetEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $syntheticEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-synthetic-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $syntheticEvidencePath
  $syntheticFile = Join-Path $syntheticEvidencePath "ubuntu.json"
  $syntheticEvidence = Get-Content -LiteralPath $syntheticFile -Raw | ConvertFrom-Json
  $syntheticEvidence.evidenceCollection.synthetic = $true
  $syntheticEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $syntheticFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "declares synthetic, mock, or sample evidence" -Parameters @{
    EvidencePath = $syntheticEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $missingMarkerEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-missing-marker-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingMarkerEvidencePath
  $missingMarkerFile = Join-Path $missingMarkerEvidencePath "ubuntu.json"
  $missingMarkerEvidence = Get-Content -LiteralPath $missingMarkerFile -Raw | ConvertFrom-Json
  $missingMarkerEvidence.evidenceCollection.PSObject.Properties.Remove("mock")
  $missingMarkerEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingMarkerFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "missing explicit evidenceCollection anti-synthetic marker" -Parameters @{
    EvidencePath = $missingMarkerEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $futureGeneratedAtEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-future-generated-at-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $futureGeneratedAtEvidencePath
  $futureGeneratedAtFile = Join-Path $futureGeneratedAtEvidencePath "ubuntu.json"
  $futureGeneratedAtEvidence = Get-Content -LiteralPath $futureGeneratedAtFile -Raw | ConvertFrom-Json
  $futureGeneratedAtEvidence.generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(1).ToString("o")
  $futureGeneratedAtEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $futureGeneratedAtFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "generated timestamp in the future" -Parameters @{
    EvidencePath = $futureGeneratedAtEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $unsafeVersionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-runtime-version-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $unsafeVersionEvidencePath
  $unsafeVersionFile = Join-Path $unsafeVersionEvidencePath "ubuntu.json"
  $unsafeVersionEvidence = Get-Content -LiteralPath $unsafeVersionFile -Raw | ConvertFrom-Json
  $unsafeVersionEvidence.nextJsRuntime.nodeVersion = "v20.11.1 C:\unsafe\path"
  $unsafeVersionEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $unsafeVersionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "unsafe Node.js runtime version" -Parameters @{
    EvidencePath = $unsafeVersionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $unsupportedNodeEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-node-version-minimum-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $unsupportedNodeEvidencePath
  $unsupportedNodeFile = Join-Path $unsupportedNodeEvidencePath "ubuntu.json"
  $unsupportedNodeEvidence = Get-Content -LiteralPath $unsupportedNodeFile -Raw | ConvertFrom-Json
  $unsupportedNodeEvidence.nextJsRuntime.nodeVersion = "v18.20.0"
  $unsupportedNodeEvidence.nextJsRuntime.nodeVersionSatisfied = $false
  $unsupportedNodeEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $unsupportedNodeFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "configured Node.js runtime satisfies the Next.js minimum version requirement" -Parameters @{
    EvidencePath = $unsupportedNodeEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $missingNodeVersionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-node-version-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingNodeVersionEvidencePath
  $missingNodeVersionFile = Join-Path $missingNodeVersionEvidencePath "ubuntu.json"
  $missingNodeVersionEvidence = Get-Content -LiteralPath $missingNodeVersionFile -Raw | ConvertFrom-Json
  $missingNodeVersionEvidence.nextJsRuntime.nodeVersion = ""
  $missingNodeVersionEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingNodeVersionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "active Node.js runtime version" -Parameters @{
    EvidencePath = $missingNodeVersionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $missingNextVersionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-next-version-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingNextVersionEvidencePath
  $missingNextVersionFile = Join-Path $missingNextVersionEvidencePath "ubuntu.json"
  $missingNextVersionEvidence = Get-Content -LiteralPath $missingNextVersionFile -Raw | ConvertFrom-Json
  $missingNextVersionEvidence.nextJsRuntime.nextVersion = ""
  $missingNextVersionEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingNextVersionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "installed Next.js package version" -Parameters @{
    EvidencePath = $missingNextVersionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $missingNextPackageJsonEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-next-package-json-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingNextPackageJsonEvidencePath
  $missingNextPackageJsonFile = Join-Path $missingNextPackageJsonEvidencePath "ubuntu.json"
  $missingNextPackageJsonEvidence = Get-Content -LiteralPath $missingNextPackageJsonFile -Raw | ConvertFrom-Json
  $missingNextPackageJsonEvidence.nextJsRuntime.nextPackageJsonExists = $false
  $missingNextPackageJsonEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingNextPackageJsonFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "node_modules/next/package.json exists" -Parameters @{
    EvidencePath = $missingNextPackageJsonEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $missingCollectorDigestEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-collector-digest-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingCollectorDigestEvidencePath
  $missingCollectorDigestFile = Join-Path $missingCollectorDigestEvidencePath "ubuntu.json"
  $missingCollectorDigestEvidence = Get-Content -LiteralPath $missingCollectorDigestFile -Raw | ConvertFrom-Json
  $missingCollectorDigestEvidence.evidenceCollection.PSObject.Properties.Remove("collectorSha256")
  $missingCollectorDigestEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingCollectorDigestFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "missing evidence collector SHA256 digest" -Parameters @{
    EvidencePath = $missingCollectorDigestEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
  }

  $missingMinimumUptimeEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-minimum-uptime-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingMinimumUptimeEvidencePath
  $missingMinimumUptimeFile = Join-Path $missingMinimumUptimeEvidencePath "ubuntu.json"
  $missingMinimumUptimeEvidence = Get-Content -LiteralPath $missingMinimumUptimeFile -Raw | ConvertFrom-Json
  $missingMinimumUptimeEvidence.uptime.minimumUptimeHours = "0"
  $missingMinimumUptimeEvidence.uptime.minimumSatisfied = $false
  $missingMinimumUptimeEvidence.uptime.serviceUptimeSeconds = 3600
  $missingMinimumUptimeEvidence | ConvertTo-Json -Depth 8 | Set-Content -Path $missingMinimumUptimeFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "does not prove required minimum uptime evidence" -Parameters @{
    EvidencePath = $missingMinimumUptimeEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
  }

  $badCollectionCiEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-collection-ci-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $badCollectionCiEvidencePath
  $badCollectionCiFile = Join-Path $badCollectionCiEvidencePath "ubuntu.json"
  $badCollectionCiEvidence = Get-Content -LiteralPath $badCollectionCiFile -Raw | ConvertFrom-Json
  $badCollectionCiEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = ""
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = ("a" * 40)
    }) -Force
  $badCollectionCiEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $badCollectionCiFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "evidenceCollection.ci.runId is required for github-actions provenance" -Parameters @{
    EvidencePath = $badCollectionCiEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  $workflowCiEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-workflow-ci-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $workflowCiEvidencePath
  $workflowCiFile = Join-Path $workflowCiEvidencePath "ubuntu.json"
  $workflowCiEvidence = Get-Content -LiteralPath $workflowCiFile -Raw | ConvertFrom-Json
  $workflowCiEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "12345"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = ("b" * 40)
    }) -Force
  $workflowCiEvidence.evidenceCollection | Add-Member -NotePropertyName "workflowDispatch" -NotePropertyValue ([pscustomobject]@{
      evidenceName = "ubuntu-standalone-systemd-nginx"
      expectedTargetId = "ubuntu"
      expectedNextJsMode = "standalone"
      expectedServiceManager = "systemd"
      expectedReverseProxy = "nginx"
      minimumUptimeHours = "72"
      supportMatrixPath = "config/support-matrix.example.json"
      supportMatrixSha256 = ("d" * 64)
    }) -Force
  $workflowCiEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $workflowCiFile -Encoding UTF8
  Invoke-ExpectHostEvidenceSuccess -Name "expected controlled host-evidence workflow provenance" -Parameters @{
    EvidencePath = $workflowCiFile
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    RequireCiCollection = $true
    RequireHostEvidenceWorkflowCollection = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
    ExpectedMatrixPath = "config/support-matrix.example.json"
    ExpectedMatrixSha256 = ("d" * 64)
  }

  $missingBootSessionEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-boot-session-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $missingBootSessionEvidencePath
  $missingBootSessionFile = Join-Path $missingBootSessionEvidencePath "ubuntu.json"
  $missingBootSessionEvidence = Get-Content -LiteralPath $missingBootSessionFile -Raw | ConvertFrom-Json
  $missingBootSessionEvidence.uptime.serviceStartedDuringCurrentBoot = $false
  $missingBootSessionEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingBootSessionFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "does not prove the service started during the current host boot session" -Parameters @{
    EvidencePath = $missingBootSessionEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
  }

  $badWorkflowMatrixEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-workflow-matrix-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $badWorkflowMatrixEvidencePath
  $badWorkflowMatrixFile = Join-Path $badWorkflowMatrixEvidencePath "ubuntu.json"
  $badWorkflowMatrixEvidence = Get-Content -LiteralPath $badWorkflowMatrixFile -Raw | ConvertFrom-Json
  $badWorkflowMatrixEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "12345"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = ("d" * 40)
    }) -Force
  $badWorkflowMatrixEvidence.evidenceCollection | Add-Member -NotePropertyName "workflowDispatch" -NotePropertyValue ([pscustomobject]@{
      evidenceName = "ubuntu-standalone-systemd-nginx"
      expectedTargetId = "ubuntu"
      expectedNextJsMode = "standalone"
      expectedServiceManager = "systemd"
      expectedReverseProxy = "nginx"
      minimumUptimeHours = "72"
      supportMatrixPath = "config/support-matrix.example.json"
      supportMatrixSha256 = ("e" * 64)
    }) -Force
  $badWorkflowMatrixEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $badWorkflowMatrixFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "workflowDispatch.supportMatrixSha256 does not match" -Parameters @{
    EvidencePath = $badWorkflowMatrixFile
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    RequireCiCollection = $true
    RequireHostEvidenceWorkflowCollection = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
    ExpectedMatrixPath = "config/support-matrix.example.json"
    ExpectedMatrixSha256 = ("d" * 64)
  }

  $badWorkflowDispatchEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-workflow-dispatch-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $badWorkflowDispatchEvidencePath
  $badWorkflowDispatchFile = Join-Path $badWorkflowDispatchEvidencePath "ubuntu.json"
  $badWorkflowDispatchEvidence = Get-Content -LiteralPath $badWorkflowDispatchFile -Raw | ConvertFrom-Json
  $badWorkflowDispatchEvidence.evidenceCollection | Add-Member -NotePropertyName "ci" -NotePropertyValue ([pscustomobject]@{
      isCi = $true
      provider = "github-actions"
      workflowName = "host-evidence"
      runId = "12345"
      runAttempt = "1"
      eventName = "workflow_dispatch"
      refName = "main"
      sha = ("c" * 40)
    }) -Force
  $badWorkflowDispatchEvidence.evidenceCollection | Add-Member -NotePropertyName "workflowDispatch" -NotePropertyValue ([pscustomobject]@{
      evidenceName = "debian-standalone-systemd-nginx"
      expectedTargetId = "debian"
      expectedNextJsMode = "standalone"
      expectedServiceManager = "systemd"
      expectedReverseProxy = "nginx"
      minimumUptimeHours = "72"
      supportMatrixPath = "config/support-matrix.example.json"
      supportMatrixSha256 = ("d" * 64)
    }) -Force
  $badWorkflowDispatchEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $badWorkflowDispatchFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "workflowDispatch.expectedTargetId does not match" -Parameters @{
    EvidencePath = $badWorkflowDispatchFile
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireCollectorSha256 = $true
    RequireMinimumUptimeHours = 72
    RequireCiCollection = $true
    RequireHostEvidenceWorkflowCollection = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "does not prove controlled host-evidence workflow_dispatch collection provenance" -Parameters @{
    EvidencePath = (Join-Path $EvidencePath "ubuntu.json")
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    RequireHostEvidenceWorkflowCollection = $true
  }

  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "No evidence file matched expected collection dimensions" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "next-start"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  $badNextStartCliEvidencePath = Join-Path $RepoRoot ".tmp\host-evidence-negative-next-start-cli-$([Guid]::NewGuid().ToString('N'))"
  New-SelfTestEvidence -Path $badNextStartCliEvidencePath
  $badNextStartCliFile = Join-Path $badNextStartCliEvidencePath "ubuntu.json"
  $badNextStartCliEvidence = Get-Content -LiteralPath $badNextStartCliFile -Raw | ConvertFrom-Json
  $badNextStartCliEvidence.nextJsRuntime.mode = "next-start"
  $badNextStartCliEvidence | ConvertTo-Json -Depth 12 | Set-Content -Path $badNextStartCliFile -Encoding UTF8
  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "does not prove Next.js next-start uses node_modules/next/dist/bin/next" -Parameters @{
    EvidencePath = $badNextStartCliEvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
  }

  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "target 'debian'" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "debian"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "nginx"
  }

  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "service manager 'launchd'" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "launchd"
    ExpectedReverseProxy = "nginx"
  }

  Invoke-ExpectHostEvidenceFailure -ExpectedMessage "reverse proxy 'apache'" -Parameters @{
    EvidencePath = $EvidencePath
    RequireNextJs = $true
    RequireReverseProxy = $true
    RequireDeploymentIdentity = $true
    ExpectedTargetId = "ubuntu"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "systemd"
    ExpectedReverseProxy = "apache"
  }
}

if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path (Get-Location) $EvidencePath
}
$evidenceDisplayPath = Get-DisplayPath -Path $EvidencePath
$evidenceItem = Get-Item -LiteralPath $EvidencePath -ErrorAction SilentlyContinue
if ($null -eq $evidenceItem) {
  throw "Evidence path not found: $evidenceDisplayPath"
}

$issues = New-Object System.Collections.Generic.List[string]
$files = @()
if ($evidenceItem -is [System.IO.FileInfo]) {
  if ($evidenceItem.Extension -ine ".json") {
    throw "Host evidence file must be a JSON file: $evidenceDisplayPath"
  }
  $files = @($evidenceItem)
} else {
  $files = @(Get-ChildItem -Path $EvidencePath -Recurse -File -Filter "*.json")
}
if ($files.Count -eq 0) {
  throw "No host evidence JSON files found under: $evidenceDisplayPath"
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

$expectedTarget = Normalize-Target $ExpectedTargetId
$expectedMode = Normalize-Target $ExpectedNextJsMode
$expectedServiceManager = Normalize-Target $ExpectedServiceManager
$expectedReverseProxy = Normalize-ReverseProxy $ExpectedReverseProxy
if ($expectedTarget -or $expectedMode -or $expectedServiceManager -or $expectedReverseProxy) {
  $matchedExpected = $false
  foreach ($result in $results) {
    if ($expectedTarget -and $result.SupportTargetId -ne $expectedTarget) { continue }
    if ($expectedMode -and $result.NextJsMode -ne $expectedMode) { continue }
    if ($expectedServiceManager -and $result.ServiceManager -ne $expectedServiceManager) { continue }
    if ($expectedReverseProxy -and $result.ReverseProxy -ne $expectedReverseProxy) { continue }
    $matchedExpected = $true
    break
  }
  if (-not $matchedExpected) {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($expectedTarget) { $parts.Add("target '$expectedTarget'") | Out-Null }
    if ($expectedMode) { $parts.Add("Next.js mode '$expectedMode'") | Out-Null }
    if ($expectedServiceManager) { $parts.Add("service manager '$expectedServiceManager'") | Out-Null }
    if ($expectedReverseProxy) { $parts.Add("reverse proxy '$expectedReverseProxy'") | Out-Null }
    $issues.Add("No evidence file matched expected collection dimensions: $(@($parts) -join ', ').") | Out-Null
  }
}

if ($results.Count -gt 0) {
  $results | Sort-Object File | Format-Table File, AppName, Verdict, Critical, Warnings, Service, Port, Health, Uptime, Monitor, NextJs, Proxy, Identity, Collection, SupportTargetId, NextJsMode, ServiceManager, ReverseProxy, Targets -Wrap
}

if ($issues.Count -gt 0) {
  Write-Host ""
  Write-Host "Host evidence validation failures:"
  $issues | ForEach-Object { Write-Host "  $_" }
  $issueSummary = (@($issues | Select-Object -First 5) -join " | ")
  if ($issues.Count -gt 5) {
    $issueSummary = "$issueSummary | ..."
  }
  throw "Host evidence validation failed. $issueSummary"
}

Write-Host "Host evidence validation OK"
