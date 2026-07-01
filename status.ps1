<#
.SYNOPSIS
  Show safe Windows service, process, port, and health status.
.DESCRIPTION
  This script avoids printing environment variables, config Environment values,
  credentials, request bodies, or log contents. It reports only operational
  metadata needed to confirm whether the app is running.
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json -JsonPath .\evidence\windows-status.json -FailOnCritical
.EXAMPLE
  .\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical -FailOnWarnings
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [int] $MinimumUptimeHours = 0,
    [int] $HealthTimeoutSeconds = 0,
    [string] $JsonPath = "",
    [switch] $FailOnCritical,
    [switch] $FailOnWarnings
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
$DefaultNextJsMinimumNodeVersion = "20.9.0"

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$serviceName = [string]$config.AppName
$escapedServiceName = $serviceName.Replace("'", "''")
$configuredPort = [int]$config.Port
$healthUrl = [string]$config.HealthUrl
$script:findings = New-Object System.Collections.Generic.List[object]
$script:nextJsRuntimeEvidence = [pscustomobject]@{
    Applicable = $false
    Status = "not-applicable"
    AppFramework = "node"
    Mode = ""
    RuntimeRoot = ""
    NodeVersion = ""
    MinimumNodeVersion = ""
    NodeVersionSatisfied = $null
    NextVersion = ""
}
$script:reverseProxyEvidence = [pscustomobject]@{
    Applicable = $false
    Mode = ""
    Status = "not-applicable"
    ProbeUrl = ""
    StatusCode = $null
    ResponseMs = $null
    Iis = [pscustomobject]@{
        Applicable = $false
        ModuleAvailable = $false
        SiteName = ""
        SiteExists = $false
        SiteState = ""
        SiteStarted = $null
        SitePathName = ""
        ConfiguredSitePathName = ""
        SitePathMatchesConfig = $null
        AppPoolName = ""
        PublicPort = 0
        BindingProtocol = ""
        BindingHostConfigured = $false
        BindingMatchesConfig = $null
        DuplicateBindingCount = 0
        DuplicateBindingConflict = $false
    }
}
$script:deploymentIdentityEvidence = [pscustomobject]@{
    AppDirectory = ""
    AppDirectoryName = ""
    DeploymentId = ""
    NextBuildId = ""
    ManifestExists = $false
    ManifestSchema = ""
    PackageName = ""
    PackageSha256 = ""
    PackageImportedAtUtc = ""
    ManifestNextBuildId = ""
    Status = "unknown"
}
$script:portEvidence = [pscustomobject]@{
    Checked = $false
    Port = $configuredPort
    Listening = $false
    OwnerReadable = $false
    OwnerProcessCount = 0
    ServiceProcessIdsKnown = $false
    OwnedByService = $false
}
$script:healthEvidence = [pscustomobject]@{
    Checked = $false
    Url = ""
    Status = "not-checked"
    StatusCode = $null
    ResponseMs = $null
    TimeoutSeconds = $HealthTimeoutSeconds
}
$script:uptimeEvidence = [pscustomobject]@{
    HostUptimeSeconds = $null
    ServiceUptimeSeconds = $null
    MinimumUptimeHours = $MinimumUptimeHours
    MinimumSatisfied = $null
    ServiceStartKnown = $false
}
$script:serviceDefinitionEvidence = [pscustomobject]@{
    Checked = $false
    Manager = ""
    DefinitionSource = ""
    DefinitionExists = $false
    ServiceWrapperMatchesConfig = $null
    NodeExeMatchesConfig = $null
    WorkingDirectoryMatchesConfig = $null
    ArgumentsMatchConfig = $null
}
$script:healthMonitorEvidence = [pscustomobject]@{
    Status = "unknown"
    Scheduled = $false
    ScheduleType = "windows-task"
    TaskExists = $false
    TaskActionChecked = $false
    TaskActionUsesHealthCheckScript = $null
    TaskActionUsesConfigPath = $null
    TaskLastResult = $null
    TaskMissedRuns = $null
    StateExists = $false
    ConsecutiveFailures = $null
    LastSuccessAgeSeconds = $null
    LastSuccessFresh = $false
    LogExists = $false
    LogFailureCount = $null
    LogRestartCount = $null
}

function Add-Finding {
    param(
        [ValidateSet("Critical", "Warning", "Info")] [string] $Severity,
        [string] $Message
    )
    $script:findings.Add([pscustomobject]@{
        Severity = $Severity
        Message = $Message
    }) | Out-Null
}

function Get-ChildProcessTree {
    param([int] $ParentProcessId)

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byParent = @{}
    foreach ($process in $all) {
        $parentId = [int]$process.ParentProcessId
        if (-not $byParent.ContainsKey($parentId)) {
            $byParent[$parentId] = New-Object System.Collections.Generic.List[object]
        }
        $byParent[$parentId].Add($process) | Out-Null
    }

    $result = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($ParentProcessId)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $byParent.ContainsKey($current)) { continue }
        foreach ($child in $byParent[$current]) {
            $result.Add($child) | Out-Null
            if ($child.ProcessId) { $queue.Enqueue([int]$child.ProcessId) }
        }
    }

    return @($result)
}

function Format-Uptime {
    param($StartTime)
    if (-not $StartTime) { return "" }
    try {
        $span = (Get-Date) - $StartTime
        return "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
    } catch {
        return ""
    }
}
function Format-OptionalUtc {
    param($Value)
    if (-not $Value) { return "" }
    try {
        return ([DateTime]::Parse([string]$Value).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {
        return [string]$Value
    }
}
function Get-ConfigInt($Config, [string]$Name, [int]$Default) {
    if ($Config.PSObject.Properties[$Name] -and $Config.$Name) {
        try { return [int]$Config.$Name } catch {}
    }
    return $Default
}
function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}
function Get-ConfigEnvironmentString($Config, [string]$Name, [string]$Default = "") {
    if (-not $Config.PSObject.Properties["Environment"] -or -not $Config.Environment) { return $Default }
    if ($Config.Environment.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.Environment.$Name)) {
        return [string]$Config.Environment.$Name
    }
    return $Default
}
function Get-ConfigBool($Config, [string]$Name, [bool]$Default) {
    if (-not $Config.PSObject.Properties[$Name]) { return $Default }
    $value = $Config.$Name
    if ($value -is [bool]) { return [bool]$value }
    switch -Regex ([string]$value) {
        '^(true|1|yes)$' { return $true }
        '^(false|0|no)$' { return $false }
        default { return $Default }
    }
}
function Normalize-Name([string]$Value) {
    return $Value.ToLowerInvariant().Replace("_", "-")
}
function Get-WindowsSupportTargetId {
    param([string]$OsCaption)

    if ($OsCaption -match 'Windows Server') {
        if ($OsCaption -match '2012\s+R2') { return "windows-server-2012-r2" }
        foreach ($year in @("2012", "2016", "2019", "2022", "2025")) {
            if ($OsCaption -match $year) { return "windows-server-$year" }
        }
        return "windows-server"
    }
    if ($OsCaption -match 'Windows\s+10' -and $OsCaption -notmatch 'Windows Server') {
        return "windows-10"
    }
    if ($OsCaption -match 'Windows\s+11' -and $OsCaption -notmatch 'Windows Server') {
        return "windows-11"
    }
    return "windows"
}
function Test-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace("\", "/")
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    foreach ($part in $normalized.Split("/")) {
        if ($part -eq "..") { return $false }
    }
    return $true
}
function Split-ArgumentTokens([string]$Arguments) {
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return @() }
    return @($Arguments -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function Get-HostnameArgumentValue([string[]]$Tokens) {
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token -eq "-H" -or $token -eq "--hostname") {
            if (($i + 1) -lt $Tokens.Count) { return $Tokens[$i + 1] }
            return ""
        }
        if ($token -like "--hostname=*") {
            return $token.Substring("--hostname=".Length)
        }
        if ($token -like "-H=*") {
            return $token.Substring("-H=".Length)
        }
    }
    return ""
}
function Get-WorstFindingSeverity {
    if (@($script:findings | Where-Object { $_.Severity -eq "Critical" }).Count -gt 0) { return "Critical" }
    if (@($script:findings | Where-Object { $_.Severity -eq "Warning" }).Count -gt 0) { return "Warning" }
    return "Healthy"
}
function Get-SafeUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
    $safe = $Url -replace '#.*$', ''
    $safe = $safe -replace '\?.*$', ''
    return ($safe -replace '(https?://)[^/@]+@', '$1[redacted]@')
}
function Get-SafePathLeaf([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    try {
        return Split-Path -Leaf $Path
    } catch {
        return ""
    }
}
function Get-SafeEvidenceText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $safe = $Text
    foreach ($path in @(
        Get-ConfigString $config "AppDirectory" "",
        Get-ConfigString $config "ServiceDirectory" "",
        Get-ConfigString $config "LogDirectory" "",
        Get-ConfigString $config "BackupDirectory" "",
        $ConfigPath,
        (Split-Path -Parent $ConfigPath)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $safe = $safe -replace [regex]::Escape($path), "<path>"
        }
    }
    $safe = $safe -replace '(?i)[A-Z]:\\[^\s,;:"<>|]+', '<path>'
    $safe = $safe -replace '\\\\[^\s,;:"<>|]+', '<unc-path>'
    return $safe
}
function Get-SafeCiValue {
    param(
        [string] $Value,
        [string] $Pattern = '[^A-Za-z0-9._/-]'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return (($Value.Trim() -replace $Pattern, "-").Trim("-"))
}
function Get-SafeEvidenceCollectionCi {
    $isGitHubActions = ([string]$env:GITHUB_ACTIONS).Trim().ToLowerInvariant() -eq "true"
    $isCi = $isGitHubActions -or (([string]$env:CI).Trim().ToLowerInvariant() -eq "true")
    $provider = if ($isGitHubActions) { "github-actions" } elseif ($isCi) { "ci" } else { "" }

    return [pscustomobject]@{
        IsCi = $isCi
        Provider = $provider
        WorkflowName = Get-SafeCiValue -Value ([string]$env:GITHUB_WORKFLOW)
        RunId = Get-SafeCiValue -Value ([string]$env:GITHUB_RUN_ID) -Pattern '[^0-9]'
        RunAttempt = Get-SafeCiValue -Value ([string]$env:GITHUB_RUN_ATTEMPT) -Pattern '[^0-9]'
        EventName = Get-SafeCiValue -Value ([string]$env:GITHUB_EVENT_NAME) -Pattern '[^A-Za-z0-9._-]'
        RefName = Get-SafeCiValue -Value ([string]$env:GITHUB_REF_NAME)
        Sha = Get-SafeCiValue -Value ([string]$env:GITHUB_SHA) -Pattern '[^A-Fa-f0-9]'
    }
}
function Get-CollectorFileSha256 {
    try {
        $scriptPath = [string]$PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            return ""
        }
        $hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -match '^[a-f0-9]{64}$') { return $hash }
        return ""
    } catch {
        return ""
    }
}
function Get-ObjectPropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-SafeRuntimeVersionText([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $text = $Value.Trim()
    if ($text.Length -gt 80) { $text = $text.Substring(0, 80) }
    return (($text -replace '[^A-Za-z0-9._+:-]', "-").Trim("-"))
}
function Get-SemverParts([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value.Trim(), '^v?(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
    }
}
function Test-SemverAtLeast([string]$Actual, [string]$Minimum) {
    $actualParts = Get-SemverParts $Actual
    $minimumParts = Get-SemverParts $Minimum
    if ($null -eq $actualParts -or $null -eq $minimumParts) { return $null }
    if ($actualParts.Major -ne $minimumParts.Major) { return $actualParts.Major -gt $minimumParts.Major }
    if ($actualParts.Minor -ne $minimumParts.Minor) { return $actualParts.Minor -gt $minimumParts.Minor }
    return $actualParts.Patch -ge $minimumParts.Patch
}
function Get-NodeRuntimeVersion([string]$NodeExe) {
    $candidate = if ([string]::IsNullOrWhiteSpace($NodeExe)) { "node" } else { $NodeExe }
    try {
        $output = & $candidate --version 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        return Get-SafeRuntimeVersionText ([string](@($output)[0]))
    } catch {
        return ""
    }
}
function Get-PackageJsonVersion([string]$PackageJsonPath) {
    if ([string]::IsNullOrWhiteSpace($PackageJsonPath) -or -not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
        return ""
    }
    try {
        $package = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
        return Get-SafeRuntimeVersionText ([string](Get-ObjectPropertyValue $package "version" ""))
    } catch {
        return ""
    }
}
function Get-NextPackageVersion([string]$AppDirectory, [string]$RuntimeRoot) {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($RuntimeRoot, $AppDirectory)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidates.Add((Join-Path $root "node_modules\next\package.json")) | Out-Null
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $version = Get-PackageJsonVersion $candidate
        if ($version) { return $version }
    }
    return ""
}
function Get-SafeNextJsRuntimeEvidence($Evidence) {
    $runtimeRoot = [string](Get-ObjectPropertyValue $Evidence "RuntimeRoot" "")
    $nodeVersionSatisfied = Get-ObjectPropertyValue $Evidence "NodeVersionSatisfied" $null
    $nextStartCommandPath = [string](Get-ObjectPropertyValue $Evidence "NextStartCommandPath" "")
    $nextStartCommandIsExpectedCli = Get-ObjectPropertyValue $Evidence "NextStartCommandIsExpectedCli" $null
    return [pscustomobject]@{
        Applicable = [bool](Get-ObjectPropertyValue $Evidence "Applicable" $false)
        Status = [string](Get-ObjectPropertyValue $Evidence "Status" "unknown")
        AppFramework = [string](Get-ObjectPropertyValue $Evidence "AppFramework" "")
        Mode = [string](Get-ObjectPropertyValue $Evidence "Mode" "")
        NodeVersion = Get-SafeRuntimeVersionText ([string](Get-ObjectPropertyValue $Evidence "NodeVersion" ""))
        MinimumNodeVersion = Get-SafeRuntimeVersionText ([string](Get-ObjectPropertyValue $Evidence "MinimumNodeVersion" ""))
        NodeVersionSatisfied = if ($nodeVersionSatisfied -is [bool]) { [bool]$nodeVersionSatisfied } else { $null }
        NextVersion = Get-SafeRuntimeVersionText ([string](Get-ObjectPropertyValue $Evidence "NextVersion" ""))
        RuntimeRootName = Get-SafePathLeaf $runtimeRoot
        AppDirectoryExists = Get-ObjectPropertyValue $Evidence "AppDirectoryExists" $null
        StartCommand = Get-SafeEvidenceText ([string](Get-ObjectPropertyValue $Evidence "StartCommand" ""))
        NextStartCommandPathName = Get-SafePathLeaf $nextStartCommandPath
        NextStartCommandIsExpectedCli = if ($nextStartCommandIsExpectedCli -is [bool]) { [bool]$nextStartCommandIsExpectedCli } else { $null }
        NodeArguments = [string](Get-ObjectPropertyValue $Evidence "NodeArguments" "")
        BindAddress = [string](Get-ObjectPropertyValue $Evidence "BindAddress" "")
        ServerJsExists = Get-ObjectPropertyValue $Evidence "ServerJsExists" $null
        DotNextExists = Get-ObjectPropertyValue $Evidence "DotNextExists" $null
        BuildIdExists = Get-ObjectPropertyValue $Evidence "BuildIdExists" $null
        StaticAssetsExist = Get-ObjectPropertyValue $Evidence "StaticAssetsExist" $null
        PublicDirectoryExists = Get-ObjectPropertyValue $Evidence "PublicDirectoryExists" $null
        NodeModulesExists = Get-ObjectPropertyValue $Evidence "NodeModulesExists" $null
        PackageJsonExists = Get-ObjectPropertyValue $Evidence "PackageJsonExists" $null
        NextPackageExists = Get-ObjectPropertyValue $Evidence "NextPackageExists" $null
    }
}
function Get-SafeDeploymentIdentityEvidence($Evidence) {
    return [pscustomobject]@{
        Status = [string](Get-ObjectPropertyValue $Evidence "Status" "unknown")
        AppDirectoryName = [string](Get-ObjectPropertyValue $Evidence "AppDirectoryName" "")
        DeploymentId = [string](Get-ObjectPropertyValue $Evidence "DeploymentId" "")
        NextBuildId = [string](Get-ObjectPropertyValue $Evidence "NextBuildId" "")
        ManifestExists = [bool](Get-ObjectPropertyValue $Evidence "ManifestExists" $false)
        ManifestSchema = [string](Get-ObjectPropertyValue $Evidence "ManifestSchema" "")
        PackageName = [string](Get-ObjectPropertyValue $Evidence "PackageName" "")
        PackageSha256 = [string](Get-ObjectPropertyValue $Evidence "PackageSha256" "")
        PackageImportedAtUtc = [string](Get-ObjectPropertyValue $Evidence "PackageImportedAtUtc" "")
        ManifestNextBuildId = [string](Get-ObjectPropertyValue $Evidence "ManifestNextBuildId" "")
    }
}
function Get-SafeRelativeUrlPath([string]$Path, [string]$Default) {
    $value = if ([string]::IsNullOrWhiteSpace($Path)) { $Default } else { $Path }
    $value = $value.Replace("\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    if ($value -match '(^|/)\.\.($|/)') { return $Default }
    if ($value -notmatch '^[A-Za-z0-9._~/-]+$') { return $Default }
    return $value
}
function Get-DefaultProxyHealthUrl($Config) {
    $configured = Get-ConfigString $Config "ProxyHealthUrl" ""
    if ($configured) { return $configured }

    $reverseProxy = Normalize-Name (Get-ConfigString $Config "ReverseProxy" "none")
    if ([string]::IsNullOrWhiteSpace($reverseProxy) -or $reverseProxy -eq "none") { return "" }

    $tlsEnabled = Get-ConfigBool $Config "TlsEnabled" $false
    $scheme = if ($tlsEnabled) { "https" } else { "http" }
    $defaultPort = if ($tlsEnabled) { 443 } else { 80 }
    $publicPort = Get-ConfigInt $Config "PublicPort" $defaultPort
    $path = Get-SafeRelativeUrlPath (Get-ConfigString $Config "IisHealthProxyPath" "health") "health"
    return ("{0}://127.0.0.1:{1}/{2}" -f $scheme, $publicPort, $path)
}
function Get-NormalizedPathForCompare([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try {
        return ([System.IO.Path]::GetFullPath($expanded)).TrimEnd([char[]]@('\', '/'))
    } catch {
        return $expanded.TrimEnd([char[]]@('\', '/'))
    }
}
function Get-CommandArgumentValue {
    param(
        [string] $Arguments,
        [string] $Name
    )
    if ([string]::IsNullOrWhiteSpace($Arguments) -or [string]::IsNullOrWhiteSpace($Name)) { return "" }

    $pattern = '(?i)(?:^|\s)-' + [regex]::Escape($Name) + '(?:\s+|:)(?:"([^"]*)"|''([^'']*)''|(\S+))'
    $match = [regex]::Match($Arguments, $pattern)
    if (-not $match.Success) { return "" }

    foreach ($index in 1..3) {
        if ($match.Groups[$index].Success) {
            return [string]$match.Groups[$index].Value
        }
    }
    return ""
}
function Test-ConfiguredPathValue {
    param(
        [string] $Actual,
        [string] $Expected
    )
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }

    $actualValue = $Actual.Trim().Trim('"')
    $expectedValue = $Expected.Trim().Trim('"')
    if ([System.IO.Path]::IsPathRooted($actualValue) -and [System.IO.Path]::IsPathRooted($expectedValue)) {
        return ((Get-NormalizedPathForCompare $actualValue) -ieq (Get-NormalizedPathForCompare $expectedValue))
    }
    return ($actualValue -ieq $expectedValue)
}
function Test-TextContainsConfiguredPath {
    param(
        [string] $Text,
        [string] $Expected
    )
    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }

    $normalizedExpected = Get-NormalizedPathForCompare $Expected
    if ([string]::IsNullOrWhiteSpace($normalizedExpected)) { return $false }
    return ($Text.IndexOf($normalizedExpected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}
function Get-ExpectedServiceArguments($Config) {
    $startCommand = Get-ConfigString $Config "StartCommand" ""
    $nodeArguments = Get-ConfigString $Config "NodeArguments" ""
    return ("{0} {1}" -f $startCommand, $nodeArguments).Trim()
}
function Test-ConfiguredArgumentsValue {
    param(
        [string] $Actual,
        [string] $Expected
    )
    return ([string]$Actual).Trim() -eq ([string]$Expected).Trim()
}
function Add-ServiceDefinitionMismatchFindings($Evidence) {
    if ($Evidence.DefinitionExists -ne $true) {
        Add-Finding -Severity Critical -Message "Windows service definition was not found for the configured service manager."
        return
    }
    if ($Evidence.ServiceWrapperMatchesConfig -eq $false) {
        Add-Finding -Severity Critical -Message "Windows service wrapper path does not match the current ServiceDirectory/AppName."
    }
    if ($Evidence.NodeExeMatchesConfig -ne $true) {
        Add-Finding -Severity Critical -Message "Windows service NodeExe does not match the current deployment config."
    }
    if ($Evidence.WorkingDirectoryMatchesConfig -ne $true) {
        Add-Finding -Severity Critical -Message "Windows service working directory does not match the current AppDirectory."
    }
    if ($Evidence.ArgumentsMatchConfig -ne $true) {
        Add-Finding -Severity Critical -Message "Windows service arguments do not match the current StartCommand/NodeArguments."
    }
}
function Get-WindowsServiceDefinitionEvidence($Config, $ServiceProcess) {
    $manager = Normalize-Name (Get-ConfigString $Config "ServiceManager" "winsw")
    $appName = Get-ConfigString $Config "AppName" ""
    $serviceDirectory = Get-ConfigString $Config "ServiceDirectory" ""
    $appDirectory = Get-ConfigString $Config "AppDirectory" ""
    $nodeExe = Get-ConfigString $Config "NodeExe" "node"
    $expectedArguments = Get-ExpectedServiceArguments $Config

    $evidence = [pscustomobject]@{
        Checked = $true
        Manager = $manager
        DefinitionSource = ""
        DefinitionExists = $false
        ServiceWrapperMatchesConfig = $null
        NodeExeMatchesConfig = $null
        WorkingDirectoryMatchesConfig = $null
        ArgumentsMatchConfig = $null
    }

    switch ($manager) {
        "winsw" {
            $evidence.DefinitionSource = "winsw-xml"
            $serviceExe = if ($serviceDirectory -and $appName) { Join-Path $serviceDirectory "$appName.exe" } else { "" }
            $serviceXml = if ($serviceDirectory -and $appName) { Join-Path $serviceDirectory "$appName.xml" } else { "" }
            if ($serviceProcess -and $serviceExe) {
                $evidence.ServiceWrapperMatchesConfig = Test-TextContainsConfiguredPath -Text ([string]$serviceProcess.PathName) -Expected $serviceExe
            }
            if ($serviceXml -and (Test-Path -LiteralPath $serviceXml -PathType Leaf)) {
                $evidence.DefinitionExists = $true
                try {
                    [xml]$definition = Get-Content -LiteralPath $serviceXml -Raw
                    $evidence.NodeExeMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$definition.service.executable) -Expected $nodeExe
                    $evidence.WorkingDirectoryMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$definition.service.workingdirectory) -Expected $appDirectory
                    $evidence.ArgumentsMatchConfig = Test-ConfiguredArgumentsValue -Actual ([string]$definition.service.arguments) -Expected $expectedArguments
                } catch {
                    Add-Finding -Severity Critical -Message "Windows WinSW service XML exists but could not be parsed."
                }
            }
        }
        "nssm" {
            $evidence.DefinitionSource = "nssm-registry"
            $registryPath = Join-Path "HKLM:\SYSTEM\CurrentControlSet\Services" "$appName\Parameters"
            if (Test-Path -LiteralPath $registryPath) {
                $evidence.DefinitionExists = $true
                try {
                    $definition = Get-ItemProperty -LiteralPath $registryPath
                    $evidence.NodeExeMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$definition.Application) -Expected $nodeExe
                    $evidence.WorkingDirectoryMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$definition.AppDirectory) -Expected $appDirectory
                    $evidence.ArgumentsMatchConfig = Test-ConfiguredArgumentsValue -Actual ([string]$definition.AppParameters) -Expected $expectedArguments
                } catch {
                    Add-Finding -Severity Critical -Message "Windows NSSM service registry parameters exist but could not be read."
                }
            }
        }
        "pm2" {
            $evidence.DefinitionSource = "pm2-ecosystem"
            $ecosystemPath = if ($serviceDirectory -and $appName) { Join-Path $serviceDirectory "$appName.pm2.config.cjs" } else { "" }
            if ($ecosystemPath -and (Test-Path -LiteralPath $ecosystemPath -PathType Leaf)) {
                $evidence.DefinitionExists = $true
                try {
                    $content = Get-Content -LiteralPath $ecosystemPath -Raw
                    $json = ($content -replace '^\s*module\.exports\s*=\s*', '') -replace ';\s*$', ''
                    $ecosystem = $json | ConvertFrom-Json
                    $definition = @($ecosystem.apps | Where-Object { [string]$_.name -eq $appName } | Select-Object -First 1)
                    if ($definition.Count -gt 0) {
                        $appDefinition = $definition[0]
                        $evidence.NodeExeMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$appDefinition.interpreter) -Expected $nodeExe
                        $evidence.WorkingDirectoryMatchesConfig = Test-ConfiguredPathValue -Actual ([string]$appDefinition.cwd) -Expected $appDirectory
                        $scriptMatchesConfig = ([string]$appDefinition.script).Trim() -eq (Get-ConfigString $Config "StartCommand" "").Trim()
                        $argumentsMatchConfig = Test-ConfiguredArgumentsValue -Actual ([string]$appDefinition.args) -Expected (Get-ConfigString $Config "NodeArguments" "")
                        $evidence.ArgumentsMatchConfig = ($scriptMatchesConfig -and $argumentsMatchConfig)
                    } else {
                        Add-Finding -Severity Critical -Message "Windows PM2 ecosystem file does not contain the configured app name."
                    }
                } catch {
                    Add-Finding -Severity Critical -Message "Windows PM2 ecosystem file exists but could not be parsed."
                }
            }
        }
        default {
            $evidence.Checked = $false
            $evidence.DefinitionSource = "unsupported"
            Add-Finding -Severity Warning -Message "Windows service definition verification does not support service manager '$manager'."
        }
    }

    if ($evidence.Checked) {
        Add-ServiceDefinitionMismatchFindings $evidence
    }
    return $evidence
}
function Get-IisExpectedBindingInformation([string]$Protocol, [int]$Port, [string]$HostHeader) {
    if ([string]::IsNullOrWhiteSpace($HostHeader)) { return "*:${Port}:" }
    return "*:${Port}:$HostHeader"
}
function Get-IisSitesForBinding([string]$Protocol, [string]$BindingInformation) {
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($site in @(Get-ChildItem IIS:\Sites -ErrorAction SilentlyContinue)) {
        foreach ($binding in @($site.Bindings.Collection)) {
            if ([string]$binding.protocol -eq $Protocol -and [string]$binding.bindingInformation -eq $BindingInformation) {
                $matches.Add([pscustomobject]@{
                    SiteName = [string]$site.Name
                    State = [string]$site.State
                    PhysicalPath = [string]$site.PhysicalPath
                }) | Out-Null
            }
        }
    }
    return @($matches)
}
function Get-IisReverseProxyEvidence($Config, [string]$Mode) {
    $empty = [pscustomobject]@{
        Applicable = $false
        ModuleAvailable = $false
        SiteName = ""
        SiteExists = $false
        SiteState = ""
        SiteStarted = $null
        SitePathName = ""
        ConfiguredSitePathName = ""
        SitePathMatchesConfig = $null
        AppPoolName = ""
        PublicPort = 0
        BindingProtocol = ""
        BindingHostConfigured = $false
        BindingMatchesConfig = $null
        DuplicateBindingCount = 0
        DuplicateBindingConflict = $false
    }
    if ((Normalize-Name $Mode) -ne "iis") { return $empty }

    $siteName = Get-ConfigString $Config "IisSiteName" ([string]$Config.AppName)
    $configuredSitePath = Get-ConfigString $Config "IisSitePath" ""
    $appPoolName = Get-ConfigString $Config "IisAppPoolName" "$([string]$Config.AppName)-AppPool"
    $publicHostName = Get-ConfigString $Config "PublicHostName" ""
    $tlsEnabled = Get-ConfigBool $Config "TlsEnabled" $false
    $defaultPort = if ($tlsEnabled) { 443 } else { 80 }
    $publicPort = Get-ConfigInt $Config "PublicPort" $defaultPort
    $protocol = if ($tlsEnabled) { "https" } else { "http" }
    $expectedBinding = Get-IisExpectedBindingInformation -Protocol $protocol -Port $publicPort -HostHeader $publicHostName

    $evidence = [pscustomobject]@{
        Applicable = $true
        ModuleAvailable = $false
        SiteName = $siteName
        SiteExists = $false
        SiteState = ""
        SiteStarted = $false
        SitePathName = ""
        ConfiguredSitePathName = Get-SafePathLeaf $configuredSitePath
        SitePathMatchesConfig = $null
        AppPoolName = $appPoolName
        PublicPort = $publicPort
        BindingProtocol = $protocol
        BindingHostConfigured = -not [string]::IsNullOrWhiteSpace($publicHostName)
        BindingMatchesConfig = $null
        DuplicateBindingCount = 0
        DuplicateBindingConflict = $false
    }

    if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
        Add-Finding -Severity Warning -Message "IIS WebAdministration module was not found; IIS site and binding evidence could not be collected."
        return $evidence
    }
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $evidence.ModuleAvailable = $true
    } catch {
        Add-Finding -Severity Warning -Message "IIS WebAdministration module could not be loaded; IIS site and binding evidence could not be collected."
        return $evidence
    }

    $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
    if ($site) {
        $evidence.SiteExists = $true
        $evidence.SiteState = [string]$site.State
        $evidence.SiteStarted = ([string]$site.State) -ieq "Started"
        if (-not $evidence.SiteStarted) {
            Add-Finding -Severity Critical -Message "Configured IIS reverse proxy site is not started."
        }
        $evidence.SitePathName = Get-SafePathLeaf ([string]$site.PhysicalPath)
        if (-not [string]::IsNullOrWhiteSpace($configuredSitePath)) {
            $evidence.SitePathMatchesConfig = (
                (Get-NormalizedPathForCompare ([string]$site.PhysicalPath)) -ieq
                (Get-NormalizedPathForCompare $configuredSitePath)
            )
            if (-not $evidence.SitePathMatchesConfig) {
                Add-Finding -Severity Critical -Message "Configured IIS site physical path does not match IisSitePath."
            }
        }
    } else {
        Add-Finding -Severity Critical -Message "Configured IIS reverse proxy site was not found."
    }

    $bindingSites = @(Get-IisSitesForBinding -Protocol $protocol -BindingInformation $expectedBinding)
    $bindingOnConfiguredSite = @($bindingSites | Where-Object { $_.SiteName -eq $siteName }).Count -gt 0
    $conflictingBindings = @($bindingSites | Where-Object { $_.SiteName -ne $siteName })
    $evidence.BindingMatchesConfig = $bindingOnConfiguredSite
    $evidence.DuplicateBindingCount = $conflictingBindings.Count
    $evidence.DuplicateBindingConflict = $conflictingBindings.Count -gt 0
    if (-not $bindingOnConfiguredSite) {
        Add-Finding -Severity Critical -Message "Configured IIS site does not own the expected public binding."
    }
    if ($conflictingBindings.Count -gt 0) {
        Add-Finding -Severity Critical -Message "Expected IIS public binding is also assigned to another IIS site."
    }

    return $evidence
}
function New-ReverseProxyEvidence {
    param(
        [bool]$Applicable,
        [string]$Mode,
        [string]$Status,
        [string]$ProbeUrl = "",
        $StatusCode = $null,
        $ResponseMs = $null,
        $IisEvidence = $null
    )
    if ($null -eq $IisEvidence) {
        $IisEvidence = Get-IisReverseProxyEvidence $config $Mode
    }
    return [pscustomobject]@{
        Applicable = $Applicable
        Mode = $Mode
        Status = $Status
        ProbeUrl = $ProbeUrl
        StatusCode = $StatusCode
        ResponseMs = $ResponseMs
        Iis = $IisEvidence
    }
}
function Get-FirstLineFromFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    try {
        return [string](Get-Content -Path $Path -TotalCount 1 -ErrorAction Stop)
    } catch {
        return ""
    }
}
function Get-NextBuildId([string]$AppDirectory, [string]$RuntimeRoot) {
    foreach ($root in @($RuntimeRoot, $AppDirectory) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        $candidate = Join-Path $root ".next\BUILD_ID"
        $value = Get-FirstLineFromFile $candidate
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return ""
}
function Get-DeploymentManifest($AppDirectory) {
    if ([string]::IsNullOrWhiteSpace($AppDirectory)) { return $null }
    $manifestPath = Join-Path $AppDirectory ".node-enterprise-deploy.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Add-Finding -Severity Warning -Message "Deployment manifest exists but could not be parsed."
        return $null
    }
}
function Get-ManifestString($Manifest, [string]$Name) {
    if ($null -eq $Manifest) { return "" }
    if ($Manifest.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.$Name)) {
        return [string]$Manifest.$Name
    }
    return ""
}
function Update-DeploymentIdentityEvidence {
    $appDirectory = Get-ConfigString $config "AppDirectory" ""
    $manifest = Get-DeploymentManifest $appDirectory
    $manifestExists = $null -ne $manifest
    $manifestDeploymentId = Get-ManifestString $manifest "deploymentId"
    $manifestNextBuildId = Get-ManifestString $manifest "nextBuildId"
    $packageSha256 = Get-ManifestString $manifest "packageSha256"
    $deploymentId = Get-ConfigString $config "DeploymentId" ""
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        $deploymentId = Get-ConfigEnvironmentString $config "NEXT_DEPLOYMENT_ID" ""
    }
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        $deploymentId = Get-ConfigEnvironmentString $config "DEPLOYMENT_ID" ""
    }
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        $deploymentId = $manifestDeploymentId
    }
    $nextBuildId = ""
    if ($script:nextJsRuntimeEvidence -and $script:nextJsRuntimeEvidence.Applicable) {
        $nextBuildId = Get-NextBuildId -AppDirectory $appDirectory -RuntimeRoot ([string]$script:nextJsRuntimeEvidence.RuntimeRoot)
    }
    if ([string]::IsNullOrWhiteSpace($nextBuildId)) {
        $nextBuildId = $manifestNextBuildId
    }
    $status = if (-not [string]::IsNullOrWhiteSpace($deploymentId) -or -not [string]::IsNullOrWhiteSpace($nextBuildId) -or -not [string]::IsNullOrWhiteSpace($packageSha256)) { "ok" } else { "unknown" }
    $script:deploymentIdentityEvidence = [pscustomobject]@{
        AppDirectory = $appDirectory
        AppDirectoryName = if ($appDirectory) { Split-Path -Leaf $appDirectory } else { "" }
        DeploymentId = $deploymentId
        NextBuildId = $nextBuildId
        ManifestExists = $manifestExists
        ManifestSchema = Get-ManifestString $manifest "schema"
        PackageName = Get-ManifestString $manifest "packageName"
        PackageSha256 = $packageSha256
        PackageImportedAtUtc = Get-ManifestString $manifest "generatedAtUtc"
        ManifestNextBuildId = $manifestNextBuildId
        Status = $status
    }
}
function Test-AllOwnersMatch {
    param(
        [int[]] $OwnerProcessIds,
        [int[]] $ExpectedProcessIds
    )
    if ($OwnerProcessIds.Count -eq 0 -or $ExpectedProcessIds.Count -eq 0) { return $false }
    $mismatches = @($OwnerProcessIds | Where-Object { $ExpectedProcessIds -notcontains $_ })
    return ($mismatches.Count -eq 0)
}
function Get-DateTimeFromStateValue($Value) {
    if (-not $Value) { return $null }
    try {
        return [DateTime]::Parse([string]$Value).ToLocalTime()
    } catch {
        return $null
    }
}
function Get-BackupDirectory($Config) {
    if ($Config.PSObject.Properties["BackupDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.BackupDirectory)) {
        return [string]$Config.BackupDirectory
    }
    if ($Config.PSObject.Properties["ServiceDirectory"] -and -not [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return (Join-Path $Config.ServiceDirectory "backups")
    }
    return ""
}
function Get-HealthLogSummary([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $lines = @(Get-Content -Path $Path -Tail 2000 -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Path = $Path
        LastWriteTime = (Get-Item $Path).LastWriteTime
        LinesSampled = $lines.Count
        Ok = @($lines | Where-Object { $_ -match '\sOK\s' }).Count
        Failed = @($lines | Where-Object { $_ -match '\sFAILED|FAILED_THRESHOLD|EXCEPTION|BAD_STATUS|SERVICE_NOT_RUNNING' }).Count
        Restarted = @($lines | Where-Object { $_ -match 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' }).Count
        RestartSuppressed = @($lines | Where-Object { $_ -match 'RESTART_SUPPRESSED_COOLDOWN' }).Count
        RetentionRemoved = @($lines | Where-Object { $_ -match 'RETENTION_REMOVED' }).Count
    }
}
function Show-NextJsRuntimeLayout {
    $framework = Normalize-Name (Get-ConfigString $config "AppFramework" "node")
    $nodeVersion = Get-NodeRuntimeVersion (Get-ConfigString $config "NodeExe" "node")
    $minimumNodeVersion = Get-ConfigString $config "NextjsMinimumNodeVersion" $DefaultNextJsMinimumNodeVersion
    $nodeVersionSatisfied = $null
    $script:nextJsRuntimeEvidence = [pscustomobject]@{
        Applicable = $false
        Status = "not-applicable"
        AppFramework = $framework
        Mode = ""
        RuntimeRoot = ""
        NodeVersion = $nodeVersion
        MinimumNodeVersion = $minimumNodeVersion
        NodeVersionSatisfied = $nodeVersionSatisfied
        NextVersion = ""
    }
    if ($framework -notin @("next", "nextjs", "next-js")) { return }

    Write-Host ""
    Write-Host "Next.js runtime layout" -ForegroundColor Yellow

    $layoutFailed = $false
    $mode = Normalize-Name (Get-ConfigString $config "NextjsDeploymentMode" "standalone")
    $appDirectory = Get-ConfigString $config "AppDirectory"
    $startCommand = Get-ConfigString $config "StartCommand" "server.js"
    $nodeArguments = Get-ConfigString $config "NodeArguments" ""
    $bindAddress = Get-ConfigString $config "BindAddress" "127.0.0.1"
    $requiresStatic = Get-ConfigBool $config "NextjsRequireStaticAssets" $true
    $requiresPublic = Get-ConfigBool $config "NextjsRequirePublicDirectory" $false
    $startHasArguments = $startCommand -match '\s'
    $startPath = ""
    $runtimeRoot = $appDirectory

    if ($null -eq (Get-SemverParts $minimumNodeVersion)) {
        Add-Finding -Severity Critical -Message "NextjsMinimumNodeVersion must be a semantic version like 20.9.0."
        $layoutFailed = $true
    } elseif ([string]::IsNullOrWhiteSpace($nodeVersion)) {
        Add-Finding -Severity Critical -Message "Next.js requires Node.js >= $minimumNodeVersion, but NodeExe did not return a version with --version."
        $layoutFailed = $true
    } else {
        $nodeVersionSatisfied = Test-SemverAtLeast -Actual $nodeVersion -Minimum $minimumNodeVersion
        if ($null -eq $nodeVersionSatisfied) {
            Add-Finding -Severity Critical -Message "Next.js requires Node.js >= $minimumNodeVersion, but NodeExe returned an unrecognized version: $nodeVersion"
            $layoutFailed = $true
        } elseif (-not $nodeVersionSatisfied) {
            Add-Finding -Severity Critical -Message "Next.js requires Node.js >= $minimumNodeVersion; configured NodeExe reports $nodeVersion."
            $layoutFailed = $true
        }
    }

    if ([string]::IsNullOrWhiteSpace($appDirectory)) {
        Add-Finding -Severity Critical -Message "Next.js config is missing AppDirectory."
        $layoutFailed = $true
        $script:nextJsRuntimeEvidence = [pscustomobject]@{
            Applicable = $true
            Status = "failed"
            AppFramework = "nextjs"
            Mode = $mode
            NodeVersion = $nodeVersion
            MinimumNodeVersion = $minimumNodeVersion
            NodeVersionSatisfied = $nodeVersionSatisfied
            NextVersion = ""
            AppDirectoryExists = $false
            RuntimeRoot = ""
            StartCommand = $startCommand
            ServerJsExists = $false
            DotNextExists = $false
            BuildIdExists = $false
            StaticAssetsExist = $false
            PublicDirectoryExists = $false
            NodeModulesExists = $false
        }
        $script:nextJsRuntimeEvidence | Format-List
        return
    } elseif (-not (Test-Path -LiteralPath $appDirectory -PathType Container)) {
        Add-Finding -Severity Critical -Message "Next.js AppDirectory was not found: $appDirectory"
        $layoutFailed = $true
    }

    if ($mode -eq "standalone" -and -not $startHasArguments) {
        if ([System.IO.Path]::IsPathRooted($startCommand)) {
            $startPath = $startCommand
        } elseif (Test-SafeRelativePath $startCommand) {
            $startPath = Join-Path $appDirectory $startCommand
        } else {
            Add-Finding -Severity Critical -Message "Next.js StartCommand is not a safe relative path: $startCommand"
            $layoutFailed = $true
        }
        if ($startPath) {
            $runtimeRoot = Split-Path -Parent $startPath
        }
    } elseif ($mode -eq "standalone") {
        Add-Finding -Severity Critical -Message "Next.js standalone StartCommand must be a single file path. Put script arguments in NodeArguments."
        $layoutFailed = $true
    }

    $serverPath = if ($startPath) { $startPath } else { Join-Path $runtimeRoot "server.js" }
    $nextPath = Join-Path $runtimeRoot ".next"
    $buildIdPath = Join-Path $nextPath "BUILD_ID"
    $staticPath = Join-Path $nextPath "static"
    $publicPath = Join-Path $runtimeRoot "public"
    $nodeModulesPath = Join-Path $runtimeRoot "node_modules"
    $packagePath = Join-Path $appDirectory "package.json"
    $nextPackagePath = Join-Path $appDirectory "node_modules\next"
    $nextVersion = Get-NextPackageVersion -AppDirectory $appDirectory -RuntimeRoot $runtimeRoot

    $script:nextJsRuntimeEvidence = [pscustomobject]@{
        Applicable = $true
        Status = "pending"
        AppFramework = "nextjs"
        Mode = $mode
        NodeVersion = $nodeVersion
        MinimumNodeVersion = $minimumNodeVersion
        NodeVersionSatisfied = $nodeVersionSatisfied
        NextVersion = $nextVersion
        AppDirectoryExists = (Test-Path -LiteralPath $appDirectory -PathType Container)
        RuntimeRoot = $runtimeRoot
        StartCommand = $startCommand
        NodeArguments = $nodeArguments
        BindAddress = $bindAddress
        ServerJsExists = (Test-Path -LiteralPath $serverPath -PathType Leaf)
        DotNextExists = (Test-Path -LiteralPath $nextPath -PathType Container)
        BuildIdExists = (Test-Path -LiteralPath $buildIdPath -PathType Leaf)
        StaticAssetsExist = (Test-Path -LiteralPath $staticPath -PathType Container)
        PublicDirectoryExists = (Test-Path -LiteralPath $publicPath -PathType Container)
        NodeModulesExists = (Test-Path -LiteralPath $nodeModulesPath -PathType Container)
    }

    switch ($mode) {
        "standalone" {
            if ($startPath -and (Split-Path -Leaf $startPath) -ne "server.js") {
                Add-Finding -Severity Warning -Message "Next.js standalone StartCommand normally points to server.js."
            }
            if ($startPath -and -not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
                Add-Finding -Severity Critical -Message "Next.js standalone server.js was not found at: $serverPath"
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath $nextPath -PathType Container)) {
                Add-Finding -Severity Critical -Message "Next.js standalone runtime root is missing .next: $nextPath"
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath $buildIdPath -PathType Leaf)) {
                Add-Finding -Severity Critical -Message "Next.js standalone runtime root is missing .next\BUILD_ID: $buildIdPath"
                $layoutFailed = $true
            }
            if ($requiresStatic -and -not (Test-Path -LiteralPath $staticPath -PathType Container)) {
                Add-Finding -Severity Critical -Message "Next.js standalone runtime root is missing .next/static: $staticPath"
                $layoutFailed = $true
            }
            if ($requiresPublic -and -not (Test-Path -LiteralPath $publicPath -PathType Container)) {
                Add-Finding -Severity Critical -Message "Next.js standalone runtime root is missing public directory: $publicPath"
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath $nodeModulesPath -PathType Container)) {
                Add-Finding -Severity Warning -Message "Next.js standalone runtime root has no node_modules directory. Confirm the artifact includes traced dependencies."
            }
        }
        "next-start" {
            if ([string]::IsNullOrWhiteSpace($startCommand) -or $startHasArguments) {
                Add-Finding -Severity Critical -Message "Next.js next-start StartCommand must be a single file path."
                $layoutFailed = $true
            } else {
                $nextStartCommandPath = if ([System.IO.Path]::IsPathRooted($startCommand)) { $startCommand } elseif (Test-SafeRelativePath $startCommand) { Join-Path $appDirectory $startCommand } else { "" }
                if ([string]::IsNullOrWhiteSpace($nextStartCommandPath)) {
                    Add-Finding -Severity Critical -Message "Next.js next-start StartCommand is not a safe relative path: $startCommand"
                    $layoutFailed = $true
                } else {
                    $expectedNextStartCommandPath = Join-Path $appDirectory "node_modules\next\dist\bin\next"
                    $nextStartCommandIsExpectedCli = (Get-NormalizedPathForCompare $nextStartCommandPath) -ieq (Get-NormalizedPathForCompare $expectedNextStartCommandPath)
                    $script:nextJsRuntimeEvidence | Add-Member -NotePropertyName NextStartCommandPath -NotePropertyValue $nextStartCommandPath -Force
                    $script:nextJsRuntimeEvidence | Add-Member -NotePropertyName NextStartCommandIsExpectedCli -NotePropertyValue $nextStartCommandIsExpectedCli -Force
                    if (-not (Test-Path -LiteralPath $nextStartCommandPath -PathType Leaf)) {
                        Add-Finding -Severity Critical -Message "Next.js next-start StartCommand file was not found: $nextStartCommandPath"
                        $layoutFailed = $true
                    }
                    if (-not $nextStartCommandIsExpectedCli) {
                        Add-Finding -Severity Critical -Message "Next.js next-start StartCommand must point to node_modules/next/dist/bin/next under AppDirectory."
                        $layoutFailed = $true
                    }
                }
            }
            $argumentTokens = @(Split-ArgumentTokens $nodeArguments)
            if ($argumentTokens.Count -eq 0 -or $argumentTokens[0] -ne "start") {
                Add-Finding -Severity Critical -Message "Next.js next-start mode requires NodeArguments to start with 'start'."
                $layoutFailed = $true
            }
            $hostnameArgument = Get-HostnameArgumentValue $argumentTokens
            if ([string]::IsNullOrWhiteSpace($hostnameArgument)) {
                Add-Finding -Severity Critical -Message "Next.js next-start mode requires NodeArguments to include '-H $bindAddress' or '--hostname $bindAddress'."
                $layoutFailed = $true
            } elseif ($hostnameArgument -ne $bindAddress) {
                Add-Finding -Severity Critical -Message "Next.js next-start hostname argument '$hostnameArgument' must match BindAddress '$bindAddress'."
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
                Add-Finding -Severity Critical -Message "Next.js next-start mode is missing package.json under AppDirectory."
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath (Join-Path $appDirectory ".next") -PathType Container)) {
                Add-Finding -Severity Critical -Message "Next.js next-start mode is missing .next under AppDirectory."
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath (Join-Path $appDirectory ".next\BUILD_ID") -PathType Leaf)) {
                Add-Finding -Severity Critical -Message "Next.js next-start mode is missing .next\BUILD_ID under AppDirectory."
                $layoutFailed = $true
            }
            if (-not (Test-Path -LiteralPath $nextPackagePath -PathType Container)) {
                Add-Finding -Severity Critical -Message "Next.js next-start mode is missing node_modules/next under AppDirectory."
                $layoutFailed = $true
            }
        }
        default {
            Add-Finding -Severity Critical -Message "NextjsDeploymentMode must be standalone or next-start."
            $layoutFailed = $true
        }
    }

    $script:nextJsRuntimeEvidence.Status = if ($layoutFailed) { "failed" } else { "ok" }
    $script:nextJsRuntimeEvidence | Format-List
}

Write-Host "Status for: $serviceName" -ForegroundColor Cyan
Write-Host "Config: $ConfigPath"
Write-Host ""

$healthIntervalMinutes = Get-ConfigInt $config "HealthCheckIntervalMinutes" 1
$failureThreshold = Get-ConfigInt $config "HealthCheckFailureThreshold" 2
if ($HealthTimeoutSeconds -lt 1) {
    $HealthTimeoutSeconds = Get-ConfigInt $config "HealthCheckTimeoutSeconds" 10
}

Write-Host "Host uptime" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$supportTargetId = Get-WindowsSupportTargetId -OsCaption $(if ($os) { [string]$os.Caption } else { "" })
$platformEvidence = [pscustomobject]@{
    Family = "windows"
    SupportTargetId = $supportTargetId
    OsCaption = if ($os) { [string]$os.Caption } else { "" }
    OsVersion = if ($os) { [string]$os.Version } else { "" }
    OsBuildNumber = if ($os) { [string]$os.BuildNumber } else { "" }
    OsArchitecture = if ($os) { [string]$os.OSArchitecture } else { "" }
    ServiceManager = Get-ConfigString $config "ServiceManager" "winsw"
    ReverseProxy = Get-ConfigString $config "ReverseProxy" ""
    AppFramework = Get-ConfigString $config "AppFramework" "node"
    NextjsDeploymentMode = Get-ConfigString $config "NextjsDeploymentMode" ""
}
if ($os -and $os.LastBootUpTime) {
    $script:uptimeEvidence.HostUptimeSeconds = [int64]((Get-Date) - $os.LastBootUpTime).TotalSeconds
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        LastBootUpTime = $os.LastBootUpTime
        Uptime = Format-Uptime $os.LastBootUpTime
    } | Format-Table -AutoSize
} else {
    Add-Finding -Severity Warning -Message "Could not read host boot time from Win32_OperatingSystem."
    Write-Warning "Could not read host boot time."
}

Write-Host "Service" -ForegroundColor Yellow
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    $service | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
    if ($service.Status -ne "Running") {
        Add-Finding -Severity Critical -Message "Service '$serviceName' is $($service.Status), not Running."
    }
    if ($service.StartType -ne "Automatic") {
        Add-Finding -Severity Warning -Message "Service '$serviceName' StartType is $($service.StartType), not Automatic."
    }
} else {
    Add-Finding -Severity Critical -Message "Service '$serviceName' was not found."
    Write-Warning "Service not found: $serviceName"
}

$serviceProcess = Get-CimInstance Win32_Service -Filter "Name='$escapedServiceName'" -ErrorAction SilentlyContinue
if ($serviceProcess) {
    $serviceProcess | Select-Object Name, State, StartMode, ProcessId | Format-Table -AutoSize
    if ($serviceProcess.StartMode -ne "Auto") {
        Add-Finding -Severity Warning -Message "Win32 service StartMode is $($serviceProcess.StartMode), not Auto."
    }
    if ($serviceProcess.State -eq "Running" -and (-not $serviceProcess.ProcessId -or $serviceProcess.ProcessId -lt 1)) {
        Add-Finding -Severity Critical -Message "Service reports Running but has no process ID."
    }
}

$script:serviceDefinitionEvidence = Get-WindowsServiceDefinitionEvidence -Config $config -ServiceProcess $serviceProcess
$script:serviceDefinitionEvidence |
    Select-Object Checked, Manager, DefinitionSource, DefinitionExists, ServiceWrapperMatchesConfig, NodeExeMatchesConfig, WorkingDirectoryMatchesConfig, ArgumentsMatchConfig |
    Format-List

$serviceProcessIds = @()
if ($serviceProcess -and $serviceProcess.ProcessId -and $serviceProcess.ProcessId -gt 0) {
    $serviceProcessIds += [int]$serviceProcess.ProcessId
    $wrapper = Get-Process -Id $serviceProcess.ProcessId -ErrorAction SilentlyContinue
    if ($wrapper) {
        Write-Host ""
        Write-Host "Service wrapper uptime" -ForegroundColor Yellow
        $wrapperUptimeSeconds = [int64]((Get-Date) - $wrapper.StartTime).TotalSeconds
        $script:uptimeEvidence.ServiceUptimeSeconds = $wrapperUptimeSeconds
        $script:uptimeEvidence.ServiceStartKnown = $true
        if ($MinimumUptimeHours -gt 0) {
            $script:uptimeEvidence.MinimumSatisfied = ($wrapperUptimeSeconds -ge ($MinimumUptimeHours * 3600))
        }
        $wrapper |
            Select-Object Id, StartTime, @{Name="Uptime";Expression={ Format-Uptime $_.StartTime }}, Path |
            Format-Table -AutoSize
        if ($MinimumUptimeHours -gt 0) {
            $uptimeHours = ($wrapperUptimeSeconds / 3600)
            if ($uptimeHours -lt $MinimumUptimeHours) {
                Add-Finding -Severity Warning -Message ("Service wrapper uptime is {0:N1} hours, below requested minimum of {1} hours." -f $uptimeHours, $MinimumUptimeHours)
            }
        }
    } else {
        Add-Finding -Severity Critical -Message "Service process ID $($serviceProcess.ProcessId) was reported by SCM but the process was not found."
    }

    $children = Get-ChildProcessTree -ParentProcessId ([int]$serviceProcess.ProcessId)
    if ($children.Count -gt 0) {
        $serviceProcessIds += @($children | Select-Object -ExpandProperty ProcessId)
        Write-Host ""
        Write-Host "Service process tree" -ForegroundColor Yellow
        $children |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath |
            Format-Table -AutoSize
    }
}

Write-Host ""
Write-Host "Node processes" -ForegroundColor Yellow
$nodeProcesses = Get-Process node -ErrorAction SilentlyContinue
if ($nodeProcesses) {
    $nodeProcesses |
        Select-Object Id, StartTime, @{Name="Uptime";Expression={ Format-Uptime $_.StartTime }}, Path |
        Format-Table -AutoSize
} else {
    Add-Finding -Severity Warning -Message "No node.exe process was found."
    Write-Warning "No node.exe process found."
}

$serviceProcessIds = @($serviceProcessIds | Where-Object { $_ } | Sort-Object -Unique)
if ($nodeProcesses -and $serviceProcessIds.Count -gt 0) {
    $ownedNodeProcesses = @($nodeProcesses | Where-Object { $serviceProcessIds -contains $_.Id })
    if ($ownedNodeProcesses.Count -eq 0) {
        Add-Finding -Severity Warning -Message "node.exe is running, but no node.exe process is in the configured service process tree."
    }
}

Show-NextJsRuntimeLayout
Update-DeploymentIdentityEvidence

Write-Host ""
Write-Host "Deployment identity" -ForegroundColor Yellow
$script:deploymentIdentityEvidence |
    Select-Object Status, AppDirectoryName, DeploymentId, NextBuildId, ManifestExists, PackageName, PackageSha256, PackageImportedAtUtc |
    Format-List

Write-Host ""
Write-Host "Configured port listener" -ForegroundColor Yellow
$script:portEvidence.Checked = $true
$script:portEvidence.Port = $configuredPort
$script:portEvidence.ServiceProcessIdsKnown = ($serviceProcessIds.Count -gt 0)
$portConnections = Get-NetTCPConnection -LocalPort $configuredPort -State Listen -ErrorAction SilentlyContinue
if ($portConnections) {
    $portConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    $configuredPortOwnerIds = @($portConnections | Select-Object -ExpandProperty OwningProcess -Unique)
    $script:portEvidence.Listening = $true
    $script:portEvidence.OwnerReadable = $true
    $script:portEvidence.OwnerProcessCount = $configuredPortOwnerIds.Count
    if (Test-AllOwnersMatch -OwnerProcessIds $configuredPortOwnerIds -ExpectedProcessIds $serviceProcessIds) {
        $script:portEvidence.OwnedByService = $true
        Write-Host "Configured port $configuredPort is owned by the configured service process tree." -ForegroundColor Green
    } else {
        $script:portEvidence.OwnedByService = $false
        Add-Finding -Severity Critical -Message "Configured port $configuredPort is listening, but owner process ID(s) $($configuredPortOwnerIds -join ', ') do not all belong to the configured service process tree."
    }
} else {
    $script:portEvidence.Listening = $false
    Add-Finding -Severity Critical -Message "No listener was found on configured port $configuredPort."
    Write-Warning "No listener found on configured port $configuredPort."
}

Write-Host ""
Write-Host "Listeners owned by configured service" -ForegroundColor Yellow
if ($serviceProcessIds.Count -gt 0) {
    $ownedConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $serviceProcessIds -contains $_.OwningProcess }
    if ($ownedConnections) {
        $ownedConnections | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
    } else {
        Add-Finding -Severity Warning -Message "No listening sockets were found for configured service process IDs: $($serviceProcessIds -join ', ')."
        Write-Warning "No listening sockets found for configured service process IDs: $($serviceProcessIds -join ', ')."
    }
} else {
    Add-Finding -Severity Warning -Message "No configured service process IDs were available for listener ownership checks."
    Write-Warning "No configured service process IDs available for listener check."
}

Write-Host ""
Write-Host "HTTP health" -ForegroundColor Yellow
$script:healthEvidence.Checked = $true
$script:healthEvidence.Url = Get-SafeUrl $healthUrl
$script:healthEvidence.TimeoutSeconds = $HealthTimeoutSeconds
if ($healthUrl) {
    try {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec $HealthTimeoutSeconds
        $timer.Stop()
        $healthStatus = if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { "ok" } else { "failed" }
        $healthResult = [pscustomobject]@{
            StatusCode = $response.StatusCode
            StatusDescription = $response.StatusDescription
            ResponseMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
            TimeoutSeconds = $HealthTimeoutSeconds
        }
        $script:healthEvidence.Status = $healthStatus
        $script:healthEvidence.StatusCode = [int]$response.StatusCode
        $script:healthEvidence.ResponseMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
        $healthResult | Format-Table -AutoSize
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) {
            Add-Finding -Severity Critical -Message "Health probe returned HTTP $($response.StatusCode) for $(Get-SafeUrl $healthUrl)."
        }
    } catch {
        $script:healthEvidence.Status = "failed"
        Add-Finding -Severity Critical -Message "Health probe failed for configured HealthUrl $(Get-SafeUrl $healthUrl): $($_.Exception.Message)"
        Write-Warning "Health probe failed for configured HealthUrl. $($_.Exception.Message)"
    }
} else {
    $script:healthEvidence.Status = "not-configured"
    Add-Finding -Severity Critical -Message "No HealthUrl is configured."
    Write-Warning "No HealthUrl configured."
}

Write-Host ""
Write-Host "Reverse proxy health" -ForegroundColor Yellow
$reverseProxyMode = Normalize-Name (Get-ConfigString $config "ReverseProxy" "none")
$proxyHealthUrl = Get-DefaultProxyHealthUrl $config
$iisReverseProxyEvidence = Get-IisReverseProxyEvidence $config $reverseProxyMode
if ([string]::IsNullOrWhiteSpace($reverseProxyMode) -or $reverseProxyMode -eq "none") {
    $script:reverseProxyEvidence = New-ReverseProxyEvidence -Applicable $false -Mode $reverseProxyMode -Status "not-applicable" -IisEvidence $iisReverseProxyEvidence
    Write-Host "Reverse proxy check not applicable." -ForegroundColor DarkGray
} elseif ([string]::IsNullOrWhiteSpace($proxyHealthUrl)) {
    $script:reverseProxyEvidence = New-ReverseProxyEvidence -Applicable $true -Mode $reverseProxyMode -Status "not-configured" -IisEvidence $iisReverseProxyEvidence
    Add-Finding -Severity Warning -Message "ReverseProxy is '$reverseProxyMode', but no proxy health probe URL could be determined."
    Write-Warning "Reverse proxy health probe URL not configured."
} else {
    try {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $proxyResponse = Invoke-WebRequest -Uri $proxyHealthUrl -UseBasicParsing -TimeoutSec $HealthTimeoutSeconds
        $timer.Stop()
        $script:reverseProxyEvidence = New-ReverseProxyEvidence -Applicable $true -Mode $reverseProxyMode -Status $(if ($proxyResponse.StatusCode -ge 200 -and $proxyResponse.StatusCode -lt 400) { "ok" } else { "failed" }) -ProbeUrl (Get-SafeUrl $proxyHealthUrl) -StatusCode ([int]$proxyResponse.StatusCode) -ResponseMs ([Math]::Round($timer.Elapsed.TotalMilliseconds, 0)) -IisEvidence $iisReverseProxyEvidence
        $script:reverseProxyEvidence | Format-Table Mode, Status, StatusCode, ResponseMs, ProbeUrl -AutoSize
        if ($script:reverseProxyEvidence.Status -ne "ok") {
            Add-Finding -Severity Warning -Message "Reverse proxy probe returned HTTP $($proxyResponse.StatusCode) for $(Get-SafeUrl $proxyHealthUrl)."
        }
    } catch {
        $script:reverseProxyEvidence = New-ReverseProxyEvidence -Applicable $true -Mode $reverseProxyMode -Status "failed" -ProbeUrl (Get-SafeUrl $proxyHealthUrl) -IisEvidence $iisReverseProxyEvidence
        Add-Finding -Severity Warning -Message "Reverse proxy probe failed for $(Get-SafeUrl $proxyHealthUrl): $($_.Exception.Message)"
        Write-Warning "Reverse proxy probe failed. $($_.Exception.Message)"
    }
}
if ($script:reverseProxyEvidence.Iis -and $script:reverseProxyEvidence.Iis.Applicable) {
    $script:reverseProxyEvidence.Iis |
        Select-Object SiteName, SiteExists, SiteState, SiteStarted, SitePathName, ConfiguredSitePathName, SitePathMatchesConfig, PublicPort, BindingProtocol, BindingMatchesConfig, DuplicateBindingCount |
        Format-List
}

Write-Host ""
Write-Host "Health check task" -ForegroundColor Yellow
$taskName = "$serviceName-HealthCheck"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $script:healthMonitorEvidence.Scheduled = $true
    $script:healthMonitorEvidence.TaskExists = $true
    $expectedHealthCheckScript = Join-Path $repoRoot "scripts\windows\Invoke-NodeHealthCheck.ps1"
    $taskAction = @($task.Actions | Select-Object -First 1)
    if ($taskAction.Count -gt 0) {
        $script:healthMonitorEvidence.TaskActionChecked = $true
        $taskArguments = [string]$taskAction[0].Arguments
        $taskScriptPath = Get-CommandArgumentValue -Arguments $taskArguments -Name "File"
        $taskConfigPath = Get-CommandArgumentValue -Arguments $taskArguments -Name "ConfigPath"
        $script:healthMonitorEvidence.TaskActionUsesHealthCheckScript = (
            (Get-NormalizedPathForCompare $taskScriptPath) -ieq
            (Get-NormalizedPathForCompare $expectedHealthCheckScript)
        )
        $script:healthMonitorEvidence.TaskActionUsesConfigPath = (
            (Get-NormalizedPathForCompare $taskConfigPath) -ieq
            (Get-NormalizedPathForCompare $ConfigPath)
        )
        if ($script:healthMonitorEvidence.TaskActionUsesHealthCheckScript -ne $true) {
            Add-Finding -Severity Critical -Message "Health check scheduled task action does not run this kit's Invoke-NodeHealthCheck.ps1 script."
        }
        if ($script:healthMonitorEvidence.TaskActionUsesConfigPath -ne $true) {
            Add-Finding -Severity Critical -Message "Health check scheduled task action does not use the current deployment config path."
        }
    } else {
        Add-Finding -Severity Critical -Message "Health check scheduled task exists, but no task action could be read."
    }
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskInfo) {
        $taskInfo |
            Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
            Format-Table -AutoSize
        $nonFailureTaskCodes = @(0, 267009, 267010, 267011, 267014)
        $script:healthMonitorEvidence.TaskLastResult = [int]$taskInfo.LastTaskResult
        $script:healthMonitorEvidence.TaskMissedRuns = [int]$taskInfo.NumberOfMissedRuns
        if ($nonFailureTaskCodes -notcontains [int]$taskInfo.LastTaskResult) {
            Add-Finding -Severity Warning -Message "Health check task last result is $($taskInfo.LastTaskResult), not a known success/running code."
        }
        if ($taskInfo.NumberOfMissedRuns -gt 0) {
            Add-Finding -Severity Warning -Message "Health check task has $($taskInfo.NumberOfMissedRuns) missed run(s)."
        }
    } else {
        $task | Select-Object TaskName, State | Format-Table -AutoSize
        Add-Finding -Severity Warning -Message "Health check scheduled task exists, but task run metadata could not be read."
    }
} else {
    Add-Finding -Severity Warning -Message "Health check scheduled task was not found: $taskName."
    Write-Warning "Health check scheduled task not found: $taskName"
}

Write-Host ""
Write-Host "Health history" -ForegroundColor Yellow
$statePath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.state.json" } else { "" }
if ($statePath -and (Test-Path $statePath)) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $lastSuccess = Get-DateTimeFromStateValue $state.LastSuccessUtc
        $lastCheck = Get-DateTimeFromStateValue $state.LastCheckUtc
        $lastRestart = Get-DateTimeFromStateValue $state.LastRestartUtc
        $script:healthMonitorEvidence.StateExists = $true
        $script:healthMonitorEvidence.ConsecutiveFailures = [int]$state.ConsecutiveFailures
        [pscustomobject]@{
            ConsecutiveFailures = $state.ConsecutiveFailures
            LastCheck = Format-OptionalUtc $state.LastCheckUtc
            LastSuccess = Format-OptionalUtc $state.LastSuccessUtc
            LastFailure = Format-OptionalUtc $state.LastFailureUtc
            LastRestart = Format-OptionalUtc $state.LastRestartUtc
        } | Format-Table -AutoSize
        if ([int]$state.ConsecutiveFailures -ge $failureThreshold) {
            Add-Finding -Severity Critical -Message "Health check state has $($state.ConsecutiveFailures) consecutive failure(s), meeting or exceeding threshold $failureThreshold."
        } elseif ([int]$state.ConsecutiveFailures -gt 0) {
            Add-Finding -Severity Warning -Message "Health check state has $($state.ConsecutiveFailures) consecutive failure(s)."
        }
        $staleAfter = [TimeSpan]::FromMinutes([Math]::Max(5, $healthIntervalMinutes * 3))
        if ($lastSuccess -and ((Get-Date) - $lastSuccess) -gt $staleAfter) {
            Add-Finding -Severity Warning -Message "Last successful health check is older than $([int]$staleAfter.TotalMinutes) minutes."
        }
        if ($lastSuccess) {
            $script:healthMonitorEvidence.LastSuccessAgeSeconds = [int64]((Get-Date) - $lastSuccess).TotalSeconds
            $script:healthMonitorEvidence.LastSuccessFresh = (((Get-Date) - $lastSuccess) -le $staleAfter)
        }
        if (-not $lastSuccess) {
            Add-Finding -Severity Warning -Message "Health state has no recorded successful check yet."
        }
        if (-not $lastCheck) {
            Add-Finding -Severity Warning -Message "Health state has no recorded check time yet."
        }
        if ($lastRestart -and ((Get-Date) - $lastRestart).TotalMinutes -lt [Math]::Max(5, $healthIntervalMinutes * 3)) {
            Add-Finding -Severity Warning -Message "Health check restarted the service recently at $($lastRestart.ToString('yyyy-MM-dd HH:mm:ss'))."
        }
    } catch {
        Add-Finding -Severity Warning -Message "Could not read health state file: $statePath"
        Write-Warning "Could not read health state file: $statePath"
    }
} else {
    Add-Finding -Severity Warning -Message "Health state file was not found yet."
    Write-Warning "Health state file not found yet."
}

$healthLogPath = if ($config.LogDirectory) { Join-Path $config.LogDirectory "healthcheck.log" } else { "" }
$healthLogSummary = if ($healthLogPath) { Get-HealthLogSummary $healthLogPath } else { $null }
if ($healthLogSummary) {
    $script:healthMonitorEvidence.LogExists = $true
    $script:healthMonitorEvidence.LogFailureCount = [int]$healthLogSummary.Failed
    $script:healthMonitorEvidence.LogRestartCount = [int]$healthLogSummary.Restarted
    $healthLogSummary | Format-Table -AutoSize
    if ($healthLogSummary.Restarted -gt 0) {
        Add-Finding -Severity Warning -Message "Recent sampled health log contains $($healthLogSummary.Restarted) restart event(s)."
    }
    if ($healthLogSummary.Failed -gt 0) {
        Add-Finding -Severity Warning -Message "Recent sampled health log contains $($healthLogSummary.Failed) failure event(s)."
    }
} else {
    Add-Finding -Severity Warning -Message "Health check log was not found yet."
    Write-Warning "Health check log not found yet."
}

$script:healthMonitorEvidence.Status = if (
    $script:healthMonitorEvidence.TaskExists -and
    $script:healthMonitorEvidence.TaskActionChecked -and
    ($script:healthMonitorEvidence.TaskActionUsesHealthCheckScript -eq $true) -and
    ($script:healthMonitorEvidence.TaskActionUsesConfigPath -eq $true) -and
    $script:healthMonitorEvidence.StateExists -and
    $script:healthMonitorEvidence.LastSuccessFresh -and
    $script:healthMonitorEvidence.ConsecutiveFailures -eq 0 -and
    $script:healthMonitorEvidence.LogExists -and
    (($null -ne $script:healthMonitorEvidence.LogFailureCount) -and $script:healthMonitorEvidence.LogFailureCount -eq 0) -and
    (($null -ne $script:healthMonitorEvidence.LogRestartCount) -and $script:healthMonitorEvidence.LogRestartCount -eq 0)
) { "ok" } else { "warning" }

Write-Host ""
Write-Host "Recent log files" -ForegroundColor Yellow
if ($config.LogDirectory -and (Test-Path $config.LogDirectory)) {
    Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
} else {
    Write-Warning "Log directory not found or not configured."
}

Write-Host ""
Write-Host "Retention and backups" -ForegroundColor Yellow
$backupDirectory = Get-BackupDirectory $config
[pscustomobject]@{
    LogRetentionDays = Get-ConfigInt $config "LogRetentionDays" 30
    BackupRetentionDays = Get-ConfigInt $config "BackupRetentionDays" 90
    DiagnosticRetentionDays = Get-ConfigInt $config "DiagnosticRetentionDays" 14
    BackupDirectory = $backupDirectory
} | Format-List
if ($backupDirectory -and (Test-Path $backupDirectory)) {
    Get-ChildItem $backupDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
} else {
    Write-Warning "Backup directory not found yet."
}

Write-Host ""
Write-Host "Operational verdict" -ForegroundColor Yellow
$verdict = Get-WorstFindingSeverity
$criticalCount = @($script:findings | Where-Object { $_.Severity -eq "Critical" }).Count
$warningCount = @($script:findings | Where-Object { $_.Severity -eq "Warning" }).Count
$sortedFindings = @($script:findings |
    Sort-Object @{ Expression = { if ($_.Severity -eq "Critical") { 0 } elseif ($_.Severity -eq "Warning") { 1 } else { 2 } } }, Message)
$safeFindings = @($sortedFindings | ForEach-Object {
    [pscustomobject]@{
        Severity = $_.Severity
        Message = Get-SafeEvidenceText ([string]$_.Message)
    }
})
$statusEvidence = [pscustomobject]@{
    EvidenceSchemaVersion = 1
    EvidenceCollection = [pscustomobject]@{
        Source = "node-enterprise-deploy-kit/status.ps1"
        Collector = "status.ps1"
        CollectorVersion = 1
        CollectorSha256 = Get-CollectorFileSha256
        LiveHost = $true
        Synthetic = $false
        Mock = $false
        Sample = $false
        Ci = Get-SafeEvidenceCollectionCi
    }
    SupportTargetId = $supportTargetId
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    AppName = $serviceName
    ConfigFileName = Get-SafePathLeaf $ConfigPath
    HealthUrl = Get-SafeUrl $healthUrl
    Platform = $platformEvidence
    NextJsRuntime = Get-SafeNextJsRuntimeEvidence $script:nextJsRuntimeEvidence
    ReverseProxy = $script:reverseProxyEvidence
    DeploymentIdentity = Get-SafeDeploymentIdentityEvidence $script:deploymentIdentityEvidence
    Service = [pscustomobject]@{
        Installed = [bool]$service
        Status = if ($service) { [string]$service.Status } else { "NotFound" }
        StartType = if ($service) { [string]$service.StartType } else { "" }
        Win32State = if ($serviceProcess) { [string]$serviceProcess.State } else { "" }
        Win32StartMode = if ($serviceProcess) { [string]$serviceProcess.StartMode } else { "" }
        ProcessId = if ($serviceProcess) { [int]$serviceProcess.ProcessId } else { 0 }
    }
    ServiceDefinition = [pscustomobject]@{
        Checked = [bool]$script:serviceDefinitionEvidence.Checked
        Manager = [string]$script:serviceDefinitionEvidence.Manager
        DefinitionSource = [string]$script:serviceDefinitionEvidence.DefinitionSource
        DefinitionExists = [bool]$script:serviceDefinitionEvidence.DefinitionExists
        ServiceWrapperMatchesConfig = $script:serviceDefinitionEvidence.ServiceWrapperMatchesConfig
        NodeExeMatchesConfig = $script:serviceDefinitionEvidence.NodeExeMatchesConfig
        WorkingDirectoryMatchesConfig = $script:serviceDefinitionEvidence.WorkingDirectoryMatchesConfig
        ArgumentsMatchConfig = $script:serviceDefinitionEvidence.ArgumentsMatchConfig
    }
    Port = [pscustomobject]@{
        Checked = [bool]$script:portEvidence.Checked
        Port = [int]$script:portEvidence.Port
        Listening = [bool]$script:portEvidence.Listening
        OwnerReadable = [bool]$script:portEvidence.OwnerReadable
        OwnerProcessCount = [int]$script:portEvidence.OwnerProcessCount
        ServiceProcessIdsKnown = [bool]$script:portEvidence.ServiceProcessIdsKnown
        OwnedByService = [bool]$script:portEvidence.OwnedByService
    }
    Health = [pscustomobject]@{
        Checked = [bool]$script:healthEvidence.Checked
        Url = [string]$script:healthEvidence.Url
        Status = [string]$script:healthEvidence.Status
        StatusCode = $script:healthEvidence.StatusCode
        ResponseMs = $script:healthEvidence.ResponseMs
        TimeoutSeconds = [int]$script:healthEvidence.TimeoutSeconds
    }
    Uptime = [pscustomobject]@{
        HostUptimeSeconds = $script:uptimeEvidence.HostUptimeSeconds
        ServiceUptimeSeconds = $script:uptimeEvidence.ServiceUptimeSeconds
        MinimumUptimeHours = [int]$script:uptimeEvidence.MinimumUptimeHours
        MinimumSatisfied = $script:uptimeEvidence.MinimumSatisfied
        ServiceStartKnown = [bool]$script:uptimeEvidence.ServiceStartKnown
    }
    HealthMonitor = [pscustomobject]@{
        Status = [string]$script:healthMonitorEvidence.Status
        Scheduled = [bool]$script:healthMonitorEvidence.Scheduled
        ScheduleType = [string]$script:healthMonitorEvidence.ScheduleType
        TaskExists = [bool]$script:healthMonitorEvidence.TaskExists
        TaskActionChecked = [bool]$script:healthMonitorEvidence.TaskActionChecked
        TaskActionUsesHealthCheckScript = $script:healthMonitorEvidence.TaskActionUsesHealthCheckScript
        TaskActionUsesConfigPath = $script:healthMonitorEvidence.TaskActionUsesConfigPath
        TaskLastResult = $script:healthMonitorEvidence.TaskLastResult
        TaskMissedRuns = $script:healthMonitorEvidence.TaskMissedRuns
        StateExists = [bool]$script:healthMonitorEvidence.StateExists
        ConsecutiveFailures = $script:healthMonitorEvidence.ConsecutiveFailures
        LastSuccessAgeSeconds = $script:healthMonitorEvidence.LastSuccessAgeSeconds
        LastSuccessFresh = [bool]$script:healthMonitorEvidence.LastSuccessFresh
        LogExists = [bool]$script:healthMonitorEvidence.LogExists
        LogFailureCount = $script:healthMonitorEvidence.LogFailureCount
        LogRestartCount = $script:healthMonitorEvidence.LogRestartCount
    }
    Verdict = $verdict
    Critical = $criticalCount
    Warnings = $warningCount
    MinimumUptimeHours = $MinimumUptimeHours
    HealthTimeoutSeconds = $HealthTimeoutSeconds
    Findings = $safeFindings
}
$statusEvidence |
    Select-Object Verdict, Critical, Warnings, MinimumUptimeHours, HealthTimeoutSeconds |
    Format-List

if ($script:findings.Count -gt 0) {
    $sortedFindings | Format-Table Severity, Message -Wrap
} else {
    Write-Host "No critical or warning findings." -ForegroundColor Green
}

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
    $jsonOutputPath = $JsonPath
    if (-not [System.IO.Path]::IsPathRooted($jsonOutputPath)) {
        $jsonOutputPath = Join-Path (Get-Location) $jsonOutputPath
    }
    $jsonDirectory = Split-Path -Parent $jsonOutputPath
    if ($jsonDirectory) {
        New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
    }
    $statusEvidence | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonOutputPath -Encoding UTF8
    Write-Host "JSON status evidence written to: $jsonOutputPath" -ForegroundColor Green
}

if ($FailOnCritical -and $criticalCount -gt 0) {
    exit 2
}
if ($FailOnWarnings -and $warningCount -gt 0) {
    exit 3
}
