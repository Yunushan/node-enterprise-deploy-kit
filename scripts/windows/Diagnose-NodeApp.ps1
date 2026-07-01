<#
.SYNOPSIS
  Collect safe diagnostics for a Node app without exposing environment secret values.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $OutputDirectory = ""
)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $config.LogDirectory "diagnostics" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $OutputDirectory "diagnostics-$stamp.txt"
$serviceName = [string]$config.AppName
$escapedServiceName = $serviceName.Replace("'", "''")
$configuredPort = [int]$config.Port
function Add-Section([string]$Title) { "`r`n===== $Title =====" | Out-File $out -Append -Encoding UTF8 }
function Format-Uptime($StartTime) {
    if (-not $StartTime) { return "" }
    try {
        $span = (Get-Date) - $StartTime
        return "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
    } catch {
        return ""
    }
}
function Format-OptionalUtc($Value) {
    if (-not $Value) { return "" }
    try { return ([DateTime]::Parse([string]$Value).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss") } catch { return [string]$Value }
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
function Test-AllOwnersMatch {
    param(
        [int[]] $OwnerProcessIds,
        [int[]] $ExpectedProcessIds
    )
    if ($OwnerProcessIds.Count -eq 0 -or $ExpectedProcessIds.Count -eq 0) { return $false }
    $mismatches = @($OwnerProcessIds | Where-Object { $ExpectedProcessIds -notcontains $_ })
    return ($mismatches.Count -eq 0)
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
function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
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
function Test-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace("\", "/")
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    foreach ($part in $normalized.Split("/")) {
        if ($part -eq "..") { return $false }
    }
    return $true
}
function Get-NormalizedPathForCompare([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try {
        return ([System.IO.Path]::GetFullPath($expanded)).TrimEnd([char[]]@('\', '/')).Replace("\", "/").ToLowerInvariant()
    } catch {
        return $expanded.TrimEnd([char[]]@('\', '/')).Replace("\", "/").ToLowerInvariant()
    }
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
function Add-HealthLogSummary([string]$Path) {
    if (-not (Test-Path $Path)) {
        "No healthcheck.log found." | Out-File $out -Append -Encoding UTF8
        return
    }
    $lines = @(Get-Content -Path $Path -Tail 2000 -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Path = $Path
        LastWriteTime = (Get-Item $Path).LastWriteTime
        LinesSampled = $lines.Count
        Ok = @($lines | Where-Object { $_ -match '\sOK\s' }).Count
        Failed = @($lines | Where-Object { $_ -match '\sFAILED|FAILED_THRESHOLD|EXCEPTION|BAD_STATUS|SERVICE_NOT_RUNNING' }).Count
        Restarted = @($lines | Where-Object { $_ -match 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' }).Count
        RestartSuppressed = @($lines | Where-Object { $_ -match 'RESTART_SUPPRESSED_COOLDOWN' }).Count
    } | Format-List | Out-File $out -Append -Encoding UTF8
}
function Add-NextJsRuntimeLayout {
    $framework = Normalize-Name (Get-ConfigString $config "AppFramework" "node")
    if ($framework -notin @("next", "nextjs", "next-js")) { return }

    Add-Section "Next.js Runtime Layout"
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

    if ([string]::IsNullOrWhiteSpace($appDirectory)) {
        "AppDirectory is not configured." | Out-File $out -Append -Encoding UTF8
        return
    }

    if ($mode -eq "standalone" -and -not $startHasArguments) {
        if ([System.IO.Path]::IsPathRooted($startCommand)) {
            $startPath = $startCommand
        } elseif (Test-SafeRelativePath $startCommand) {
            $startPath = Join-Path $appDirectory $startCommand
        }
        if ($startPath) {
            $runtimeRoot = Split-Path -Parent $startPath
        }
    }

    $serverPath = if ($startPath) { $startPath } else { Join-Path $runtimeRoot "server.js" }
    $nextPath = Join-Path $runtimeRoot ".next"
    $buildIdPath = Join-Path $nextPath "BUILD_ID"
    $staticPath = Join-Path $nextPath "static"
    $publicPath = Join-Path $runtimeRoot "public"
    $nodeModulesPath = Join-Path $runtimeRoot "node_modules"
    $nextPackagePath = Join-Path $appDirectory "node_modules\next"
    $argumentTokens = @(Split-ArgumentTokens $nodeArguments)
    $hostnameArgument = Get-HostnameArgumentValue $argumentTokens
    $nextStartCommandPath = ""
    $nextStartCommandUnderNextPackage = $true
    $nextStartCommandIsExpectedCli = $true
    if ($mode -eq "next-start") {
        if (-not [string]::IsNullOrWhiteSpace($startCommand) -and -not $startHasArguments) {
            if ([System.IO.Path]::IsPathRooted($startCommand)) {
                $nextStartCommandPath = $startCommand
            } elseif (Test-SafeRelativePath $startCommand) {
                $nextStartCommandPath = Join-Path $appDirectory $startCommand
            }
        }
        $nextStartCommandUnderNextPackage = (-not [string]::IsNullOrWhiteSpace($nextStartCommandPath) -and (($nextStartCommandPath -replace "\\", "/").ToLowerInvariant() -match '/node_modules/next/'))
        $expectedNextStartCommandPath = Join-Path $appDirectory "node_modules\next\dist\bin\next"
        $nextStartCommandIsExpectedCli = (-not [string]::IsNullOrWhiteSpace($nextStartCommandPath) -and ((Get-NormalizedPathForCompare $nextStartCommandPath) -ieq (Get-NormalizedPathForCompare $expectedNextStartCommandPath)))
    }

    [pscustomobject]@{
        AppFramework = "nextjs"
        Mode = $mode
        AppDirectoryExists = (Test-Path -LiteralPath $appDirectory -PathType Container)
        RuntimeRoot = $runtimeRoot
        StartCommand = $startCommand
        StartCommandHasArguments = $startHasArguments
        NextStartCommandPath = $nextStartCommandPath
        NextStartCommandUnderNextPackage = $nextStartCommandUnderNextPackage
        NextStartCommandIsExpectedCli = $nextStartCommandIsExpectedCli
        NodeArguments = $nodeArguments
        BindAddress = $bindAddress
        NextStartCommandStartsWithStart = ($mode -ne "next-start" -or ($argumentTokens.Count -gt 0 -and $argumentTokens[0] -eq "start"))
        NextStartHostnameArgument = $hostnameArgument
        NextStartHostnameMatchesBindAddress = ($mode -ne "next-start" -or $hostnameArgument -eq $bindAddress)
        RequiresStaticAssets = $requiresStatic
        RequiresPublicDirectory = $requiresPublic
        ServerJsExists = (Test-Path -LiteralPath $serverPath -PathType Leaf)
        DotNextExists = (Test-Path -LiteralPath $nextPath -PathType Container)
        BuildIdExists = (Test-Path -LiteralPath $buildIdPath -PathType Leaf)
        StaticAssetsExist = (Test-Path -LiteralPath $staticPath -PathType Container)
        PublicDirectoryExists = (Test-Path -LiteralPath $publicPath -PathType Container)
        NodeModulesExists = (Test-Path -LiteralPath $nodeModulesPath -PathType Container)
        PackageJsonExists = (Test-Path -LiteralPath (Join-Path $appDirectory "package.json") -PathType Leaf)
        NextPackageExists = (Test-Path -LiteralPath $nextPackagePath -PathType Container)
    } | Format-List | Out-File $out -Append -Encoding UTF8
}
"Diagnostics generated $(Get-Date -Format o)" | Out-File $out -Encoding UTF8
"AppName=$($config.AppName)" | Out-File $out -Append -Encoding UTF8
"AppDirectory=$($config.AppDirectory)" | Out-File $out -Append -Encoding UTF8
"Port=$($config.Port)" | Out-File $out -Append -Encoding UTF8
"HealthUrl=$($config.HealthUrl)" | Out-File $out -Append -Encoding UTF8
Add-Section "Host Uptime"
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os -and $os.LastBootUpTime) {
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        LastBootUpTime = $os.LastBootUpTime
        Uptime = Format-Uptime $os.LastBootUpTime
    } | Format-List | Out-File $out -Append -Encoding UTF8
}
Add-Section "Service"
$serviceProcessIds = @()
Get-Service -Name $serviceName -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append -Encoding UTF8
$serviceProcess = Get-CimInstance Win32_Service -Filter "Name='$escapedServiceName'" -ErrorAction SilentlyContinue
if ($serviceProcess) {
    $serviceProcess | Select-Object Name, State, StartMode, ProcessId, PathName | Format-List | Out-File $out -Append -Encoding UTF8
    if ($serviceProcess.ProcessId -and $serviceProcess.ProcessId -gt 0) {
        $serviceProcessIds += [int]$serviceProcess.ProcessId
        $children = Get-ChildProcessTree -ParentProcessId ([int]$serviceProcess.ProcessId)
        if ($children.Count -gt 0) {
            $serviceProcessIds += @($children | Select-Object -ExpandProperty ProcessId)
            Add-Section "Service Process Tree"
            $children | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
        }
    }
}
$serviceProcessIds = @($serviceProcessIds | Where-Object { $_ } | Sort-Object -Unique)
Add-Section "Node Processes"
Get-Process node -ErrorAction SilentlyContinue | Select-Object Id, CPU, PM, WS, StartTime, @{Name="Uptime";Expression={ Format-Uptime $_.StartTime }}, Path | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Port Check"
$portConnections = @(Get-NetTCPConnection -LocalPort $configuredPort -ErrorAction SilentlyContinue)
$portConnections | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
if ($portConnections.Count -gt 0) {
    $ownerIds = @($portConnections | Select-Object -ExpandProperty OwningProcess -Unique)
    [pscustomobject]@{
        ConfiguredPort = $configuredPort
        OwnerProcessIds = ($ownerIds -join ", ")
        OwnedByConfiguredService = Test-AllOwnersMatch -OwnerProcessIds $ownerIds -ExpectedProcessIds $serviceProcessIds
        ConfiguredServiceProcessIds = ($serviceProcessIds -join ", ")
    } | Format-List | Out-File $out -Append -Encoding UTF8
}
Add-NextJsRuntimeLayout
Add-Section "HTTP Health"
try {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec 10
    $timer.Stop()
    $response | Select-Object StatusCode, StatusDescription, @{Name="ResponseMs";Expression={ [Math]::Round($timer.Elapsed.TotalMilliseconds, 0) }} | Format-List | Out-File $out -Append -Encoding UTF8
} catch { "HTTP probe failed: $($_.Exception.Message)" | Out-File $out -Append -Encoding UTF8 }
Add-Section "Health Check History"
$taskName = "$($config.AppName)-HealthCheck"
Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue |
Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
Format-List | Out-File $out -Append -Encoding UTF8
$statePath = Join-Path $config.LogDirectory "healthcheck.state.json"
if (Test-Path $statePath) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        [pscustomobject]@{
            ConsecutiveFailures = $state.ConsecutiveFailures
            LastCheck = Format-OptionalUtc $state.LastCheckUtc
            LastSuccess = Format-OptionalUtc $state.LastSuccessUtc
            LastFailure = Format-OptionalUtc $state.LastFailureUtc
            LastRestart = Format-OptionalUtc $state.LastRestartUtc
        } | Format-List | Out-File $out -Append -Encoding UTF8
    } catch {
        "Could not read health state file." | Out-File $out -Append -Encoding UTF8
    }
} else {
    "No health state file found." | Out-File $out -Append -Encoding UTF8
}
Add-HealthLogSummary (Join-Path $config.LogDirectory "healthcheck.log")
Add-Section "Recent Application Events"
Get-WinEvent -LogName Application -MaxEvents 80 -ErrorAction SilentlyContinue |
Where-Object { $_.Message -like "*node*" -or $_.Message -like "*$($config.AppName)*" -or $_.Message -like "*iis*" -or $_.Message -like "*w3wp*" } |
Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Recent Reboot Events"
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005,6006,6008,1074} -MaxEvents 30 -ErrorAction SilentlyContinue |
Select-Object TimeCreated, Id, ProviderName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Logs Tail"
Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName, Length, LastWriteTime | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
Add-Section "Retention And Backups"
$backupDirectory = Get-BackupDirectory $config
[pscustomobject]@{
    LogRetentionDays = if ($config.PSObject.Properties["LogRetentionDays"]) { $config.LogRetentionDays } else { 30 }
    BackupRetentionDays = if ($config.PSObject.Properties["BackupRetentionDays"]) { $config.BackupRetentionDays } else { 90 }
    DiagnosticRetentionDays = if ($config.PSObject.Properties["DiagnosticRetentionDays"]) { $config.DiagnosticRetentionDays } else { 14 }
    BackupDirectory = $backupDirectory
} | Format-List | Out-File $out -Append -Encoding UTF8
if ($backupDirectory -and (Test-Path $backupDirectory)) {
    Get-ChildItem $backupDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 FullName, Length, LastWriteTime |
        Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
}
Write-Host "Diagnostics written to: $out" -ForegroundColor Green
