param(
  [string]$EvidencePath = "",
  [string]$MatrixPath = "",
  [string[]]$TargetId = @(),
  [string[]]$Category = @(),
  [int]$MaxEvidenceAgeDays = 30,
  [switch]$RequireBothNextJsModes,
  [switch]$RequireDeclaredServiceManagers,
  [switch]$RequireDeclaredReverseProxies,
  [switch]$RequireCollectorSha256,
  [switch]$RequireHostEvidenceWorkflowCollection,
  [int]$RequireMinimumUptimeHours = 0,
  [switch]$AllowWarnings,
  [switch]$AllowReverseProxyNone,
  [string]$SelfTestEvidencePath = "",
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

function Get-MatrixRequiredMinimumUptimeHours {
  param([string]$Path)

  $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  try {
    $value = [int]$matrix.requiredMinimumUptimeHours
    if ($value -lt 1) {
      throw "requiredMinimumUptimeHours must be positive."
    }
    return $value
  } catch {
    throw "Support matrix requiredMinimumUptimeHours must be a positive integer."
  }
}

function Normalize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $normalized = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  return $normalized.Trim('-')
}

function Add-TargetAlias {
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

function Get-DisplayPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if ($fullPath.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
      return "."
    }
    $repoPrefix = $repoFull + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
    }
  } catch {
    return (Split-Path -Leaf $Path)
  }
  return (Split-Path -Leaf $Path)
}

function Test-WorkflowDispatchSupported {
  param([string]$Category)
  return ((Normalize-Token $Category) -in @("windows-client", "windows-server", "linux", "macos"))
}

function Test-TargetWorkflowDispatchSupported {
  param([object]$Target)

  $localCommandOnly = Get-BooleanValue -Object $Target -Names @("localCommandOnly") -Default $false
  if ($localCommandOnly -eq $true) {
    return $false
  }
  return (Test-WorkflowDispatchSupported -Category ([string]$Target.category))
}

function Get-EvidenceCollectionCi {
  param([object]$Evidence)

  $collection = Get-PropertyValue -Object $Evidence -Names @("EvidenceCollection", "evidenceCollection")
  $ci = Get-PropertyValue -Object $collection -Names @("Ci", "ci")
  [pscustomobject]@{
    IsCi = Get-BooleanValue -Object $ci -Names @("IsCi", "isCi") -Default $null
    Provider = (Get-StringValue -Object $ci -Names @("Provider", "provider")).Trim().ToLowerInvariant()
    WorkflowName = (Get-StringValue -Object $ci -Names @("WorkflowName", "workflowName")).Trim().ToLowerInvariant()
    EventName = (Get-StringValue -Object $ci -Names @("EventName", "eventName")).Trim().ToLowerInvariant()
  }
}

function Test-HostEvidenceWorkflowCollection {
  param([object]$Evidence)

  $ci = Get-EvidenceCollectionCi -Evidence $Evidence
  return (
    $ci.IsCi -eq $true -and
    $ci.Provider -eq "github-actions" -and
    $ci.WorkflowName -eq "host-evidence" -and
    $ci.EventName -eq "workflow_dispatch"
  )
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
  $prettyName = Get-StringValue -Object $platform -Names @("OsPrettyName", "osPrettyName")
  $serviceManager = Get-StringValue -Object $platform -Names @("ServiceManager", "serviceManager")
  if (-not $serviceManager) {
    $serviceManager = Get-StringValue -Object $Evidence -Names @("ServiceManager", "serviceManager")
  }

  Add-TargetAlias -Targets $targets -Value $family
  Add-TargetAlias -Targets $targets -Value $osId
  Add-TargetAlias -Targets $targets -Value $kernelName
  Add-TargetAlias -Targets $targets -Value $serviceManager

  foreach ($part in @($osIdLike -split '\s+')) {
    Add-TargetAlias -Targets $targets -Value $part
  }

  if ($osCaption -match 'Windows') {
    Add-TargetAlias -Targets $targets -Value "windows"
  }
  if ($osCaption -match 'Windows Server') {
    Add-TargetAlias -Targets $targets -Value "windows-server"
  }
  if ($osCaption -match 'Windows\s+10' -and $osCaption -notmatch 'Windows Server') {
    Add-TargetAlias -Targets $targets -Value "windows-10"
  }
  if ($osCaption -match 'Windows\s+11' -and $osCaption -notmatch 'Windows Server') {
    Add-TargetAlias -Targets $targets -Value "windows-11"
  }
  foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
    if ($osCaption -match $year) {
      Add-TargetAlias -Targets $targets -Value "windows-server-$year"
    }
  }
  if ($osCaption -match '2012\s+R2') {
    Add-TargetAlias -Targets $targets -Value "windows-server-2012-r2"
  }
  if ($prettyName -match 'CentOS Stream') {
    Add-TargetAlias -Targets $targets -Value "centos-stream"
  }
  if ($prettyName -match 'Oracle Linux') {
    Add-TargetAlias -Targets $targets -Value "oracle-linux"
  }
  if ($prettyName -match 'Linux Mint') {
    Add-TargetAlias -Targets $targets -Value "linux-mint"
  }
  if ($targets.Contains("ubuntu") -or $targets.Contains("debian") -or $targets.Contains("rhel") -or $targets.Contains("fedora") -or $targets.Contains("alpine") -or $targets.Contains("oracle-linux") -or $targets.Contains("centos") -or $targets.Contains("centos-stream") -or $targets.Contains("linux-mint")) {
    [void]$targets.Add("linux")
  }
  if ($targets.Contains("windows-server")) {
    [void]$targets.Add("windows")
  }

  return @($targets | Sort-Object)
}

function Get-PrimaryEvidenceTarget {
  param([object]$Evidence)

  $platform = Get-PropertyValue -Object $Evidence -Names @("Platform", "platform")
  $explicit = Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  if (-not $explicit) {
    $explicit = Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")
  }
  if ($explicit) { return (Normalize-Token $explicit) }

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
  if ($osCaption -match 'Windows\s+10' -and $osCaption -notmatch 'Windows Server') {
    return "windows-10"
  }
  if ($osCaption -match 'Windows\s+11' -and $osCaption -notmatch 'Windows Server') {
    return "windows-11"
  }

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
  if ($family -in @("macos", "freebsd", "openbsd", "netbsd")) {
    return $family
  }
  if ($kernelName -eq "darwin") {
    return "macos"
  }

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

function Normalize-ReverseProxy {
  param([string]$Value)

  $normalized = Normalize-Token $Value
  switch ($normalized) {
    "httpd" { return "apache" }
    default { return $normalized }
  }
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

function Get-EvidenceRecords {
  param([string]$Path)

  $files = @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.json")
  foreach ($file in $files) {
    try {
      $evidence = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
      [pscustomobject]@{
        File = $file.FullName
        Targets = @(Get-EvidenceTargets -Evidence $evidence)
        PrimaryTarget = Get-PrimaryEvidenceTarget -Evidence $evidence
        NextJsMode = Get-NextJsMode -Evidence $evidence
        ServiceManager = Get-ServiceManager -Evidence $evidence
        ReverseProxy = Get-ReverseProxyMode -Evidence $evidence
        HostEvidenceWorkflowCollected = Test-HostEvidenceWorkflowCollection -Evidence $evidence
      }
    } catch {
      [pscustomobject]@{
        File = $file.FullName
        Targets = @()
        PrimaryTarget = ""
        NextJsMode = ""
        ServiceManager = ""
        ReverseProxy = ""
        HostEvidenceWorkflowCollected = $false
      }
    }
  }
}

function Set-SelfTestWorkflowCollection {
  param(
    [string]$Path,
    [string[]]$LocalOnlyTargets = @()
  )

  $localOnly = @($LocalOnlyTargets | ForEach-Object { Normalize-Token $_ })
  foreach ($file in @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.json")) {
    $evidence = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $targetId = Get-PrimaryEvidenceTarget -Evidence $evidence
    $collection = Get-PropertyValue -Object $evidence -Names @("EvidenceCollection", "evidenceCollection")
    if ($null -eq $collection) { continue }
    foreach ($name in @("Ci", "ci")) {
      if ($null -ne $collection.PSObject.Properties[$name]) {
        $collection.PSObject.Properties.Remove($name)
      }
    }
    if ($localOnly -notcontains $targetId) {
      $ci = [ordered]@{
        isCi = $true
        provider = "github-actions"
        workflowName = "host-evidence"
        runId = "123456789"
        runAttempt = "1"
        eventName = "workflow_dispatch"
        refName = "main"
        sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
      $collection | Add-Member -MemberType NoteProperty -Name "ci" -Value $ci -Force
    }
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $file.FullName -Encoding UTF8
  }
}

function New-ClaimSelfTestEvidence {
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

  $windowsPort = [ordered]@{
    Checked = $true
    Port = 3000
    Listening = $true
    OwnerReadable = $true
    OwnerProcessCount = 1
    ServiceProcessIdsKnown = $true
    OwnedByService = $true
  }
  $unixPort = [ordered]@{
    checked = $true
    port = "3000"
    listening = $true
    ownerReadable = $true
    ownerProcessCount = 1
    servicePidKnown = $true
    ownedByService = $true
  }
  $windowsHealth = [ordered]@{
    Checked = $true
    Url = "http://127.0.0.1:3000/health"
    Status = "ok"
    StatusCode = 200
    ResponseMs = 12
    TimeoutSeconds = 10
  }
  $unixHealth = [ordered]@{
    checked = $true
    url = "http://127.0.0.1:3000/health"
    status = "ok"
    statusCode = 200
    responseSeconds = "0.012"
    timeoutSeconds = "10"
  }
  $windowsUptime = [ordered]@{
    HostUptimeSeconds = 345600
    ServiceUptimeSeconds = 259200
    MinimumUptimeHours = 72
    MinimumSatisfied = $true
    ServiceStartKnown = $true
  }
  $unixUptime = [ordered]@{
    hostUptimeSeconds = 345600
    serviceUptimeSeconds = 259200
    minimumUptimeHours = "72"
    minimumSatisfied = $true
    serviceStartKnown = $true
  }
  $windowsMonitor = [ordered]@{
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
  $systemdMonitor = [ordered]@{
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
  $launchdMonitor = [ordered]@{
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
  $cronMonitor = [ordered]@{
    status = "ok"
    scheduled = $true
    scheduleType = "cron"
    schedulerChecked = $true
    schedulerExists = $true
    schedulerActive = $true
    schedulerEnabled = $true
    schedulerActiveStatus = "active"
    schedulerEnabledStatus = "persistent-entry"
    stateExists = $true
    consecutiveFailures = 0
    lastSuccessAgeSeconds = 60
    lastSuccessFresh = $true
    logExists = $true
    logFailureCount = 0
    logRestartCount = 0
  }
  $unixProxyConfig = [ordered]@{
    applicable = $true
    pathName = "example-next-app.conf"
    directoryName = "conf.d"
    exists = $true
    managedMarkerFound = $true
    expectedPort = "80"
  }

  $windowsTargets = @(
    @{ Id = "windows-10"; Caption = "Microsoft Windows 10 Pro"; Build = "19045"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-11"; Caption = "Microsoft Windows 11 Pro"; Build = "22631"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2012"; Caption = "Microsoft Windows Server 2012 Standard"; Build = "9200"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2012-r2"; Caption = "Microsoft Windows Server 2012 R2 Standard"; Build = "9600"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2016"; Caption = "Microsoft Windows Server 2016 Datacenter"; Build = "14393"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2019"; Caption = "Microsoft Windows Server 2019 Datacenter"; Build = "17763"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2022"; Caption = "Microsoft Windows Server 2022 Datacenter"; Build = "20348"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") },
    @{ Id = "windows-server-2025"; Caption = "Microsoft Windows Server 2025 Datacenter"; Build = "26100"; ServiceManagers = @("winsw", "nssm"); ProxyModes = @("iis", "none") }
  )
  $unixTargets = @(
    @{ Id = "ubuntu"; Family = "linux"; OsId = "ubuntu"; OsIdLike = "debian ubuntu"; PrettyName = "Ubuntu 24.04 LTS"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "debian"; Family = "linux"; OsId = "debian"; OsIdLike = "debian"; PrettyName = "Debian GNU/Linux 12"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "linux-mint"; Family = "linux"; OsId = "linuxmint"; OsIdLike = "ubuntu debian linuxmint"; PrettyName = "Linux Mint 22"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "rhel"; Family = "linux"; OsId = "rhel"; OsIdLike = "rhel fedora"; PrettyName = "Red Hat Enterprise Linux 9"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "oracle-linux"; Family = "linux"; OsId = "ol"; OsIdLike = "rhel fedora ol oracle"; PrettyName = "Oracle Linux Server 9"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "centos"; Family = "linux"; OsId = "centos"; OsIdLike = "rhel fedora centos"; PrettyName = "CentOS Linux 7"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "centos-stream"; Family = "linux"; OsId = "centos"; OsIdLike = "rhel fedora centos stream"; PrettyName = "CentOS Stream 9"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "rocky"; Family = "linux"; OsId = "rocky"; OsIdLike = "rhel fedora rocky"; PrettyName = "Rocky Linux 9"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "almalinux"; Family = "linux"; OsId = "almalinux"; OsIdLike = "rhel fedora almalinux"; PrettyName = "AlmaLinux 9"; KernelName = "Linux"; ServiceManagers = @("systemd", "systemv"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "fedora"; Family = "linux"; OsId = "fedora"; OsIdLike = "fedora"; PrettyName = "Fedora Linux 40"; KernelName = "Linux"; ServiceManagers = @("systemd"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "alpine"; Family = "linux"; OsId = "alpine"; OsIdLike = "alpine"; PrettyName = "Alpine Linux 3.20"; KernelName = "Linux"; ServiceManagers = @("openrc"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "macos"; Family = "macos"; OsId = "macos"; OsIdLike = ""; PrettyName = "macOS 15"; KernelName = "Darwin"; ServiceManagers = @("launchd"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "freebsd"; Family = "freebsd"; OsId = "freebsd"; OsIdLike = "freebsd"; PrettyName = "FreeBSD 14"; KernelName = "FreeBSD"; ServiceManagers = @("bsdrc"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "openbsd"; Family = "openbsd"; OsId = "openbsd"; OsIdLike = "openbsd"; PrettyName = "OpenBSD 7"; KernelName = "OpenBSD"; ServiceManagers = @("bsdrc"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") },
    @{ Id = "netbsd"; Family = "netbsd"; OsId = "netbsd"; OsIdLike = "netbsd"; PrettyName = "NetBSD 10"; KernelName = "NetBSD"; ServiceManagers = @("bsdrc"); ProxyModes = @("nginx", "apache", "haproxy", "traefik", "none") }
  )

  foreach ($mode in @("standalone", "next-start")) {
    foreach ($target in $windowsTargets) {
      $targetId = [string]$target["Id"]
      foreach ($serviceManager in @(Get-ArrayValue $target["ServiceManagers"])) {
        foreach ($proxyMode in @(Get-ArrayValue $target["ProxyModes"] | Where-Object { (Normalize-ReverseProxy ([string]$_)) -ne "none" })) {
          $serviceManagerValue = Normalize-Token ([string]$serviceManager)
          $proxyModeValue = Normalize-ReverseProxy ([string]$proxyMode)
          $data = [ordered]@{
            EvidenceSchemaVersion = 1
            EvidenceCollection = $windowsCollectionEvidence
            SupportTargetId = $targetId
            GeneratedAtUtc = $now
            AppName = "example-next-app"
            Platform = [ordered]@{
              Family = "windows"
              SupportTargetId = $targetId
              OsCaption = [string]$target["Caption"]
              OsVersion = "10.0.$($target["Build"])"
              OsBuildNumber = [string]$target["Build"]
              ServiceManager = $serviceManagerValue
              AppFramework = "nextjs"
              NextjsDeploymentMode = $mode
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
              Manager = $serviceManagerValue
              DefinitionSource = switch ($serviceManagerValue) {
                "nssm" { "nssm-registry" }
                "pm2" { "pm2-ecosystem" }
                default { "winsw-xml" }
              }
              DefinitionExists = $true
              ServiceWrapperMatchesConfig = if ($serviceManagerValue -eq "winsw") { $true } else { $null }
              NodeExeMatchesConfig = $true
              WorkingDirectoryMatchesConfig = $true
              ArgumentsMatchConfig = $true
            }
            Port = $windowsPort
            Health = $windowsHealth
            Uptime = $windowsUptime
            HealthMonitor = $windowsMonitor
            NextJsRuntime = [ordered]@{
              Applicable = $true
              Status = "ok"
              AppFramework = "nextjs"
              Mode = $mode
              NodeVersion = "v20.11.1"
              MinimumNodeVersion = "20.9.0"
              NodeVersionSatisfied = $true
              NextVersion = "14.2.3"
              NextStartCommandIsExpectedCli = if ($mode -eq "next-start") { $true } else { $null }
              RuntimeRootName = "example-next-app"
            }
            ReverseProxy = [ordered]@{
              Applicable = $true
              Mode = $proxyModeValue
              Status = "ok"
              ProbeUrl = "https://example.local/health"
              StatusCode = 200
              Iis = [ordered]@{
                Applicable = $true
                ModuleAvailable = $true
                SiteExists = $true
                SiteStarted = $true
                SitePathMatchesConfig = $true
                BindingMatchesConfig = $true
                DuplicateBindingConflict = $false
              }
            }
            DeploymentIdentity = [ordered]@{
              Status = "ok"
              AppDirectoryName = "example-next-app"
              DeploymentId = "example-deploy-001-$mode-$serviceManagerValue-$proxyModeValue"
              NextBuildId = "example-build-$mode"
              PackageSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }
            Verdict = "Healthy"
            Critical = 0
            Warnings = 0
            Findings = @()
          }
          $data | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "$targetId-$mode-$serviceManagerValue-$proxyModeValue.json") -Encoding UTF8
        }
      }
    }

    foreach ($target in $unixTargets) {
      $targetId = [string]$target["Id"]
      foreach ($serviceManager in @(Get-ArrayValue $target["ServiceManagers"])) {
        foreach ($proxyMode in @(Get-ArrayValue $target["ProxyModes"] | Where-Object { (Normalize-ReverseProxy ([string]$_)) -ne "none" })) {
          $serviceManagerValue = Normalize-Token ([string]$serviceManager)
          $proxyModeValue = Normalize-ReverseProxy ([string]$proxyMode)
          $monitor = switch ($serviceManagerValue) {
            "systemd" { $systemdMonitor }
            "launchd" { $launchdMonitor }
            default { $cronMonitor }
          }
          $kernelRelease = if ($targetId -eq "macos") {
            "24.0.0"
          } elseif ($targetId -in @("freebsd", "openbsd", "netbsd")) {
            "14.0"
          } else {
            "6.8.0"
          }
          $machine = if ($targetId -eq "macos") { "arm64" } else { "x86_64" }
          $osVersionId = switch ($targetId) {
            "ubuntu" { "24.04" }
            "debian" { "12" }
            "linux-mint" { "22" }
            "rhel" { "9" }
            "oracle-linux" { "9" }
            "centos" { "8" }
            "centos-stream" { "9" }
            "rocky" { "9" }
            "almalinux" { "9" }
            "fedora" { "40" }
            "alpine" { "3.20" }
            "macos" { "15.0" }
            default { "14" }
          }
          $libcName = if ($targetId -eq "alpine") {
            "musl"
          } elseif ([string]$target["Family"] -eq "linux") {
            "glibc"
          } else {
            ""
          }
          $libcVersion = if ($libcName -eq "glibc") {
            "2.39"
          } elseif ($libcName -eq "musl") {
            "1.2.5"
          } else {
            ""
          }
          $platform = [ordered]@{
            family = [string]$target["Family"]
            supportTargetId = $targetId
            osId = [string]$target["OsId"]
            osIdLike = [string]$target["OsIdLike"]
            osVersionId = $osVersionId
            osPrettyName = [string]$target["PrettyName"]
            kernelName = [string]$target["KernelName"]
            kernelRelease = $kernelRelease
            machine = $machine
            libcName = $libcName
            libcVersion = $libcVersion
            serviceManager = $serviceManagerValue
            appFramework = "nextjs"
            nextjsDeploymentMode = $mode
          }
          $data = [ordered]@{
            evidenceSchemaVersion = 1
            evidenceCollection = $unixCollectionEvidence
            supportTargetId = $targetId
            generatedAtUtc = $now
            appName = "example-next-app"
            serviceName = "example-next-app"
            serviceManager = $serviceManagerValue
            serviceActiveStatus = "active"
            serviceEnabledStatus = "enabled"
            serviceDefinition = [ordered]@{
              checked = $true
              manager = $serviceManagerValue
              definitionSource = switch ($serviceManagerValue) {
                "launchd" { "launchd-plist" }
                "bsdrc" { "bsdrc-init" }
                "openrc" { "openrc-init" }
                "systemv" { "systemv-init" }
                default { "systemd-unit" }
              }
              definitionExists = $true
              nodeExeMatchesConfig = $true
              workingDirectoryMatchesConfig = $true
              argumentsMatchConfig = $true
              runnerScriptMatchesConfig = ($serviceManagerValue -eq "launchd")
            }
            platform = $platform
            port = $unixPort
            health = $unixHealth
            uptime = $unixUptime
            healthMonitor = $monitor
            nextJsRuntime = [ordered]@{
              applicable = $true
              status = "ok"
              appFramework = "nextjs"
              mode = $mode
              nodeVersion = "v20.11.1"
              minimumNodeVersion = "20.9.0"
              nodeVersionSatisfied = $true
              nextVersion = "14.2.3"
              nextStartScriptIsExpectedCli = if ($mode -eq "next-start") { $true } else { $null }
              runtimeRootName = "example-next-app"
            }
            reverseProxy = [ordered]@{
              applicable = $true
              mode = $proxyModeValue
              status = "ok"
              probeUrl = "https://example.local/health"
              statusCode = 200
              config = $unixProxyConfig
            }
            deploymentIdentity = [ordered]@{
              status = "ok"
              appDirectoryName = "example-next-app"
              deploymentId = "example-deploy-001-$mode-$serviceManagerValue-$proxyModeValue"
              nextBuildId = "example-build-$mode"
              packageSha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            }
            verdict = "Healthy"
            critical = 0
            warnings = 0
            findings = @()
          }
          $data | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Path "$targetId-$mode-$serviceManagerValue-$proxyModeValue.json") -Encoding UTF8
        }
      }
    }
  }
}

Write-Host ""
Write-Host "==> Support claim"

& (Join-Path $ScriptDir "Test-SupportMatrix.ps1") -MatrixPath $MatrixPath

if ($SelfTest) {
  if (-not [string]::IsNullOrWhiteSpace($SelfTestEvidencePath)) {
    $EvidencePath = $SelfTestEvidencePath
    if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
      $EvidencePath = Join-Path (Get-Location) $EvidencePath
    }
  } else {
    $EvidencePath = Join-Path $RepoRoot ".tmp\support-claim-selftest-$([Guid]::NewGuid().ToString('N'))"
  }
  New-ClaimSelfTestEvidence -Path $EvidencePath
  $failedWithoutWorkflowCollection = $false
  $workflowFailureArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    TargetId = [string[]]@("windows-11")
    RequireHostEvidenceWorkflowCollection = $true
    AllowReverseProxyNone = $true
  }
  try {
    & $PSCommandPath @workflowFailureArgs *> $null
  } catch {
    $failedWithoutWorkflowCollection = ($_.Exception.Message -match "workflow provenance validation failed")
  }
  if (-not $failedWithoutWorkflowCollection) {
    throw "Support claim self-test failed: workflow-capable evidence without host-evidence workflow provenance should be rejected."
  }
  Set-SelfTestWorkflowCollection -Path $EvidencePath -LocalOnlyTargets @("freebsd", "openbsd", "netbsd")
  $workflowSuccessArgs = @{
    EvidencePath = $EvidencePath
    MatrixPath = $MatrixPath
    TargetId = [string[]]@("windows-11", "freebsd")
    RequireHostEvidenceWorkflowCollection = $true
    AllowReverseProxyNone = $true
  }
  & $PSCommandPath @workflowSuccessArgs *> $null
  if ($TargetId.Count -eq 0 -and $Category.Count -eq 0) {
    $TargetId = @(
      "windows-10",
      "windows-11",
      "windows-server-2012",
      "windows-server-2012-r2",
      "windows-server-2016",
      "windows-server-2019",
      "windows-server-2022",
      "windows-server-2025",
      "ubuntu",
      "debian",
      "linux-mint",
      "rhel",
      "oracle-linux",
      "centos",
      "centos-stream",
      "rocky",
      "almalinux",
      "fedora",
      "alpine",
      "macos",
      "freebsd",
      "openbsd",
      "netbsd"
    )
  }
  $RequireBothNextJsModes = $true
  $RequireDeclaredServiceManagers = $true
  $RequireDeclaredReverseProxies = $true
  $RequireCollectorSha256 = $true
  if ($RequireMinimumUptimeHours -le 0) {
    $RequireMinimumUptimeHours = Get-MatrixRequiredMinimumUptimeHours -Path $MatrixPath
  }
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  throw "EvidencePath is required unless -SelfTest is used."
}

if (-not (Test-Path -LiteralPath $EvidencePath -PathType Container)) {
  throw "Evidence path not found: $EvidencePath"
}

$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$targets = @(Get-ArrayValue $matrix.targets)

$selected = @()
if ($TargetId.Count -gt 0) {
  $wanted = @($TargetId | ForEach-Object { Normalize-Token $_ })
  $selected = @($targets | Where-Object { $wanted -contains (Normalize-Token ([string]$_.id)) })
  $missing = @($wanted | Where-Object { $targetIdValue = $_; -not @($selected | Where-Object { (Normalize-Token ([string]$_.id)) -eq $targetIdValue }) })
  if ($missing.Count -gt 0) {
    throw "Unknown support matrix target id(s): $($missing -join ', ')"
  }
} elseif ($Category.Count -gt 0) {
  $wantedCategories = @($Category | ForEach-Object { Normalize-Token $_ })
  $selected = @($targets | Where-Object { $wantedCategories -contains (Normalize-Token ([string]$_.category)) })
  if ($selected.Count -eq 0) {
    throw "No support matrix targets matched category: $($Category -join ', ')"
  }
} else {
  $selected = $targets
}

$selectedTargetsById = @{}
foreach ($target in $selected) {
  $selectedTargetId = Normalize-Token ([string]$target.id)
  if ($selectedTargetId) {
    $selectedTargetsById[$selectedTargetId] = $target
  }
}

$requiredEvidenceTargets = New-Object System.Collections.Generic.List[string]
foreach ($target in $selected) {
  foreach ($evidenceTarget in @(Get-ArrayValue $target.evidenceTargets)) {
    $normalized = Normalize-Token $evidenceTarget
    if ($normalized -and -not $requiredEvidenceTargets.Contains($normalized)) {
      $requiredEvidenceTargets.Add($normalized) | Out-Null
    }
  }
}

$hostEvidenceArgs = @{
  EvidencePath = $EvidencePath
  RequiredTargets = [string[]]$requiredEvidenceTargets
  MaxEvidenceAgeDays = $MaxEvidenceAgeDays
  RequireNextJs = $true
  RequireReverseProxy = $true
  RequireDeploymentIdentity = $true
}
if ($RequireCollectorSha256) {
  $hostEvidenceArgs.RequireCollectorSha256 = $true
}
if ($RequireMinimumUptimeHours -gt 0) {
  $hostEvidenceArgs.RequireMinimumUptimeHours = $RequireMinimumUptimeHours
}
if (-not $AllowWarnings) {
  $hostEvidenceArgs.FailOnWarnings = $true
}
if ($AllowReverseProxyNone) {
  $hostEvidenceArgs.AllowReverseProxyNone = $true
}

& (Join-Path $ScriptDir "Test-HostEvidence.ps1") @hostEvidenceArgs

$needsEvidenceRecords = ($RequireHostEvidenceWorkflowCollection -or $RequireBothNextJsModes -or $RequireDeclaredServiceManagers -or $RequireDeclaredReverseProxies)
$records = @()
if ($needsEvidenceRecords) {
  $records = @(Get-EvidenceRecords -Path $EvidencePath)
}

if ($RequireHostEvidenceWorkflowCollection) {
  $workflowIssues = New-Object System.Collections.Generic.List[string]
  foreach ($record in $records) {
    if (-not $record.PrimaryTarget -or -not $selectedTargetsById.ContainsKey($record.PrimaryTarget)) { continue }
    $target = $selectedTargetsById[$record.PrimaryTarget]
    if (-not (Test-TargetWorkflowDispatchSupported -Target $target)) { continue }
    if ($record.HostEvidenceWorkflowCollected -ne $true) {
      $workflowIssues.Add("$(Get-DisplayPath -Path $record.File) for $($record.PrimaryTarget) does not prove github-actions host-evidence workflow_dispatch collection.") | Out-Null
    }
  }
  if ($workflowIssues.Count -gt 0) {
    Write-Host ""
    Write-Host "Support claim workflow provenance failures:"
    $workflowIssues | ForEach-Object { Write-Host "  $_" }
    throw "Support claim workflow provenance validation failed."
  }
}

if ($RequireBothNextJsModes -or $RequireDeclaredServiceManagers -or $RequireDeclaredReverseProxies) {
  $issues = New-Object System.Collections.Generic.List[string]
  foreach ($target in $selected) {
    $targetId = Normalize-Token ([string]$target.id)
    $expectedModes = if ($RequireBothNextJsModes) {
      @(Get-ArrayValue $target.nextjsModes | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    } else {
      @("")
    }
    $expectedServiceManagers = if ($RequireDeclaredServiceManagers) {
      @(Get-ArrayValue $target.serviceManagers | ForEach-Object { Normalize-Token $_ } | Where-Object { $_ })
    } else {
      @("")
    }
    $expectedReverseProxies = if ($RequireDeclaredReverseProxies) {
      @(Get-ArrayValue $target.reverseProxies | ForEach-Object { Normalize-ReverseProxy ([string]$_) } | Where-Object { $_ -and $_ -ne "none" })
    } else {
      @("")
    }
    $expectedModes = @($expectedModes)
    $expectedServiceManagers = @($expectedServiceManagers)
    $expectedReverseProxies = @($expectedReverseProxies)
    if ($expectedModes.Count -eq 0) { $expectedModes = @("") }
    if ($expectedServiceManagers.Count -eq 0) { $expectedServiceManagers = @("") }
    if ($expectedReverseProxies.Count -eq 0) { $expectedReverseProxies = @("") }

    foreach ($mode in $expectedModes) {
      foreach ($serviceManager in $expectedServiceManagers) {
        foreach ($reverseProxy in $expectedReverseProxies) {
          $matched = $false
          foreach ($record in $records) {
            if ($record.PrimaryTarget -ne $targetId) { continue }
            if ($mode -and $record.NextJsMode -ne $mode) { continue }
            if ($serviceManager -and $record.ServiceManager -ne $serviceManager) { continue }
            if ($reverseProxy -and $record.ReverseProxy -ne $reverseProxy) { continue }
            $matched = $true
            break
          }
          if (-not $matched) {
            $parts = New-Object System.Collections.Generic.List[string]
            if ($mode) { $parts.Add("Next.js mode '$mode'") | Out-Null }
            if ($serviceManager) { $parts.Add("service manager '$serviceManager'") | Out-Null }
            if ($reverseProxy) { $parts.Add("reverse proxy '$reverseProxy'") | Out-Null }
            $detail = if ($parts.Count -gt 0) { @($parts) -join ", " } else { "selected support dimensions" }
            $issues.Add("$targetId does not have real host evidence for $detail.") | Out-Null
          }
        }
      }
    }
  }

  if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "Support claim coverage failures:"
    $issues | ForEach-Object { Write-Host "  $_" }
    throw "Support claim validation failed."
  }
}

$targetList = @($selected | ForEach-Object { [string]$_.id }) -join ", "
Write-Host "Support claim OK for: $targetList"
