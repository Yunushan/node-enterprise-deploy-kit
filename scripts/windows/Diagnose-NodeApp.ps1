<#
.SYNOPSIS
  Collect safe diagnostics for a Node app without exposing environment secret values.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $OutputDirectory = "",
    [switch] $IncludeRawDetails
)
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
. (Join-Path $repoRoot 'scripts/windows/WindowsServiceSecurity.ps1')
Assert-WindowsDeploymentConfigIdentity -Config $config
function Get-WindowsDiagnosticDirectory {
    param([string]$AppName, [string]$OutputDirectory = '', [string]$ProgramDataRoot = '')
    Assert-WindowsDeploymentAppName -AppName $AppName
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) { return Get-WindowsServiceSecurityFullPath -Path ([IO.Path]::GetFullPath($OutputDirectory)) }
    if (-not $ProgramDataRoot) { $ProgramDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData) }
    return Get-WindowsServiceSecurityFullPath -Path (Join-Path $ProgramDataRoot "node-enterprise-deploy-kit\healthchecks\$AppName\diagnostics")
}
function Assert-WindowsDiagnosticControlDirectory {
    param([string]$Path)
    Assert-WindowsServiceSecurityNoReparse -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Diagnostic control directory is missing: $Path" }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Default diagnostic parents must be protected and owned by SYSTEM or Administrators; register monitoring or use a private explicit OutputDirectory.' }
    $unsafe = [Security.AccessControl.FileSystemRights]::CreateDirectories -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($rule.IdentityReference.Value -notin $trusted -and ($rule.FileSystemRights -band $unsafe) -ne 0) { throw 'Default diagnostic parents allow untrusted control-directory changes; repair their ACLs before collecting diagnostics.' }
    }
}
function Initialize-WindowsDiagnosticOutput {
    param($Config, [string]$OutputDirectory = '', [string]$ProgramDataRoot = '')
    $managed = [string]::IsNullOrWhiteSpace($OutputDirectory)
    $directory = Get-WindowsDiagnosticDirectory -AppName ([string]$Config.AppName) -OutputDirectory $OutputDirectory -ProgramDataRoot $ProgramDataRoot
    Assert-WindowsServiceSecurityNoReparse -Path $directory
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($managed) {
        $appRoot = Split-Path -Parent $directory; $healthRoot = Split-Path -Parent $appRoot; $kitRoot = Split-Path -Parent $healthRoot
        # Preserve the existing PM2 owner's narrow monitor data-file rights.
        # New parents are private; existing managed parents must already prevent
        # runtime identities from replacing a diagnostic directory with a link.
        foreach ($parent in @($kitRoot, $healthRoot, $appRoot)) {
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null
                Set-WindowsProtectedPathSecurity -Path $parent
            }
            Assert-WindowsDiagnosticControlDirectory -Path $parent
        }
    }
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null }
    Assert-WindowsServiceSecurityNoReparse -Path $directory
    if ($managed) { Set-WindowsProtectedPathSecurity -Path $directory }
    else { Set-WindowsProtectedPathSecurity -Path $directory -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account }
    $name = 'diagnostics-{0}.{1}.{2}' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'), $PID, [guid]::NewGuid().ToString('N')
    $temporary = Join-Path $directory ($name + '.tmp')
    $final = Join-Path $directory ($name + '.txt')
    Assert-WindowsServiceSecurityNoReparse -Path $temporary
    # CreateNew never follows or overwrites a pre-existing output filename.
    $empty = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $empty.Dispose()
    if ($managed) { Set-WindowsProtectedFileSecurity -Path $temporary }
    else { Set-WindowsProtectedPathSecurity -Path $temporary -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account }
    return [pscustomobject]@{ Directory=$directory; TemporaryPath=$temporary; FinalPath=$final; ManagedDefault=$managed }
}
$diagnosticOutput = Initialize-WindowsDiagnosticOutput -Config $config -OutputDirectory $OutputDirectory
$OutputDirectory = $diagnosticOutput.Directory
$out = $diagnosticOutput.TemporaryPath
$diagnosticCompleted = $false
try {
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
    try { return ([DateTime]::Parse([string]$Value).ToLocalTime()).ToString("yyyy-MM-dd HH:mm:ss") } catch { return '[invalid timestamp]' }
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
        StartCommand = if ($IncludeRawDetails) { $startCommand } elseif ($startHasArguments) { '[omitted: command contains arguments]' } else { $startCommand }
        StartCommandHasArguments = $startHasArguments
        NextStartCommandPath = $nextStartCommandPath
        NextStartCommandUnderNextPackage = $nextStartCommandUnderNextPackage
        NextStartCommandIsExpectedCli = $nextStartCommandIsExpectedCli
        NodeArguments = if ($IncludeRawDetails) { $nodeArguments } else { '[omitted: use -IncludeRawDetails for sensitive arguments]' }
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
"RawDetailsIncluded=$([bool]$IncludeRawDetails)" | Out-File $out -Append -Encoding UTF8
"AppName=$($config.AppName)" | Out-File $out -Append -Encoding UTF8
"AppDirectory=$($config.AppDirectory)" | Out-File $out -Append -Encoding UTF8
"Port=$($config.Port)" | Out-File $out -Append -Encoding UTF8
$displayHealthUrl = '[invalid URL]'
try {
    $displayUri = [UriBuilder]::new([string]$config.HealthUrl)
    $displayUri.UserName = ''; $displayUri.Password = ''; $displayUri.Query = ''; $displayUri.Fragment = ''
    $displayHealthUrl = $displayUri.Uri.AbsoluteUri
} catch {}
"HealthUrl=$(if ($IncludeRawDetails) { $config.HealthUrl } else { $displayHealthUrl })" | Out-File $out -Append -Encoding UTF8
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
    $serviceFields = @('Name', 'State', 'StartMode', 'ProcessId')
    if ($IncludeRawDetails) { $serviceFields += 'PathName' }
    $serviceProcess | Select-Object $serviceFields | Format-List | Out-File $out -Append -Encoding UTF8
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
    [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        ResponseMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 0)
    } | Format-List | Out-File $out -Append -Encoding UTF8
} catch {
    $failureDetail = if ($IncludeRawDetails) { $_.Exception.Message } else { $_.Exception.GetType().FullName }
    "HTTP probe failed: $failureDetail" | Out-File $out -Append -Encoding UTF8
}
Add-Section "Health Check History"
$taskName = "$($config.AppName)-HealthCheck"
Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue |
Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns |
Format-List | Out-File $out -Append -Encoding UTF8
$healthStateDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) "node-enterprise-deploy-kit\healthchecks\$($config.AppName)"
$statePath = Join-Path $healthStateDirectory "healthcheck.state.json"
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
Add-HealthLogSummary (Join-Path $healthStateDirectory "healthcheck.log")
Add-Section "Recent Application Events"
$eventFields = @('TimeCreated', 'ProviderName', 'Id', 'LevelDisplayName')
if ($IncludeRawDetails) { $eventFields += 'Message' }
Get-WinEvent -LogName Application -MaxEvents 80 -ErrorAction SilentlyContinue |
Where-Object { $_.Message -like "*node*" -or $_.Message -like "*$($config.AppName)*" -or $_.Message -like "*iis*" -or $_.Message -like "*w3wp*" } |
Select-Object $eventFields | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Recent Reboot Events"
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005,6006,6008,1074} -MaxEvents 30 -ErrorAction SilentlyContinue |
Select-Object $eventFields | Format-List | Out-File $out -Append -Encoding UTF8
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
Assert-WindowsServiceSecurityNoReparse -Path $out
Assert-WindowsServiceSecurityNoReparse -Path $diagnosticOutput.FinalPath
Move-Item -LiteralPath $out -Destination $diagnosticOutput.FinalPath -ErrorAction Stop
$diagnosticCompleted = $true
Write-Host "Diagnostics written to: $($diagnosticOutput.FinalPath)" -ForegroundColor Green
} finally {
    if (-not $diagnosticCompleted -and (Test-Path -LiteralPath $out)) {
        Assert-WindowsServiceSecurityNoReparse -Path $out
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}
