function Get-WindowsStatusServiceManager {
    param($Config)
    if ((Get-WindowsServiceSecurityConfigString $Config 'DeploymentMode').Trim().ToLowerInvariant().Replace('_', '-') -eq 'static-iis') { return 'static-iis' }
    return (Get-WindowsServiceSecurityConfigString $Config 'ServiceManager' 'winsw').Trim().ToLowerInvariant()
}

function Get-WindowsPm2RuntimeEvidence {
    param($Config)
    Assert-WindowsPm2DeploymentAppName -AppName ([string]$Config.AppName)
    $context = Get-WindowsPm2RuntimeContext -Config $Config
    $previous = [Environment]::GetEnvironmentVariable('PM2_HOME', 'Process')
    try {
        $env:PM2_HOME = $context.Home
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $context.Home
        $output = @(& $context.CommandName jlist 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'PM2 runtime query failed.' }
    } finally { [Environment]::SetEnvironmentVariable('PM2_HOME', $previous, 'Process') }
    try { $entries = @(ConvertFrom-WindowsPm2ProcessJson -Json ($output -join "`n")) } catch { throw 'PM2 runtime query returned invalid JSON.' }
    $named = @($entries | Where-Object { $_.PSObject.Properties['name'] -and [string]$_.name -ceq [string]$Config.AppName })
    $result = [pscustomobject]@{ Exists = $false; Online = $false; ProcessId = 0; StartTime = $null; OwnerMatches = $false; RuntimeMatchesConfig = $false; UptimeMatchesProcess = $false }
    if ($named.Count -eq 0) { return $result }
    if ($named.Count -ne 1) { throw 'PM2 returned multiple processes for an app configured as a single fork process.' }
    $entry = $named[0]
    $result.Exists = $true
    if (-not $entry.PSObject.Properties['pm2_env'] -or -not $entry.PSObject.Properties['pid']) { return $result }
    $runtime = $entry.pm2_env
    $result.Online = ([string]$runtime.status -eq 'online')
    $result.ProcessId = [int]$entry.pid
    if (-not $result.Online -or $result.ProcessId -lt 1) { return $result }
    $appToken = Get-WindowsNativeProcessToken -ProcessId $result.ProcessId
    if ($appToken.Elevated -isnot [bool] -or $appToken.Elevated -or $appToken.OwnerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'PM2 application process must belong to the unelevated PM2 owner.' }
    $process = Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue
    $nativeProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($result.ProcessId)" -ErrorAction SilentlyContinue
    if (-not $process -or -not $nativeProcess) { return $result }
    $result.StartTime = $process.StartTime
    $owner = Invoke-CimMethod -InputObject $nativeProcess -MethodName GetOwnerSid -ErrorAction Stop
    $result.OwnerMatches = ([int]$owner.ReturnValue -eq 0 -and [string]$owner.Sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $expectedNode = [string]$Config.NodeExe
    if (-not [IO.Path]::IsPathRooted($expectedNode)) { $expectedNode = (Get-Command $expectedNode -ErrorAction Stop).Source }
    $expectedScript = if ([IO.Path]::IsPathRooted([string]$Config.StartCommand)) { [string]$Config.StartCommand } else { Join-Path $Config.AppDirectory ([string]$Config.StartCommand) }
    $actualArguments = if ($runtime.PSObject.Properties['args']) { @($runtime.args | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) } else { @() }
    $expectedArguments = @(Split-ArgumentTokens (Get-WindowsServiceSecurityConfigString $Config 'NodeArguments'))
    $result.RuntimeMatchesConfig = (
        (Test-ConfiguredPathValue ([string]$process.Path) $expectedNode) -and
        (Test-ConfiguredPathValue ([string]$runtime.exec_interpreter) $expectedNode) -and
        (Test-ConfiguredPathValue ([string]$runtime.pm_cwd) ([string]$Config.AppDirectory)) -and
        (Test-ConfiguredPathValue ([string]$runtime.pm_exec_path) $expectedScript) -and
        (($actualArguments -join "`0") -ceq ($expectedArguments -join "`0"))
    )
    if ($runtime.PSObject.Properties['pm_uptime']) {
        $reportedStart = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$runtime.pm_uptime).UtcDateTime
        $result.UptimeMatchesProcess = ([Math]::Abs(($reportedStart - $process.StartTime.ToUniversalTime()).TotalSeconds) -le 60)
    }
    # Return operational fields only. PM2 jlist contains the full environment.
    return $result
}

function Test-WindowsPm2TaskPrincipal {
    param([string]$PrincipalUser)
    try {
        $sid = if ($PrincipalUser -match '^S-1-') { [Security.Principal.SecurityIdentifier]::new($PrincipalUser) } else { Get-WindowsServiceSecuritySid -Account $PrincipalUser }
        return $sid.Value -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    } catch { return $false }
}

function Test-WindowsHealthTaskRunLevel {
    param([string]$ServiceManager, [string]$RunLevel)
    if ($ServiceManager -eq 'pm2') { return $RunLevel -in @('Limited', '0') }
    return $RunLevel -in @('Highest', '1')
}
