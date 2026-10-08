[CmdletBinding()]
param([switch]$StaticChild, [string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($StaticChild) {
    function Get-Service { throw 'Static IIS status must not query Node SCM services.' }
    function Get-Module { param([switch]$ListAvailable, $Name); [pscustomobject]@{ Name = 'WebAdministration' } }
    function Import-Module { param($Name, $ErrorAction) }
    function Get-Website { param($Name, $ErrorAction); [pscustomobject]@{ Name = 'fixture-static'; State = 'Started'; PhysicalPath = (Join-Path $FixtureRoot 'iis'); ApplicationPool = 'fixture-pool'; Bindings = [pscustomobject]@{ Collection = @([pscustomobject]@{ protocol = 'http'; bindingInformation = '*:8080:' }) } } }
    function Get-ChildItem { param($Path, $ErrorAction); if ($Path -eq 'IIS:\Sites') { Get-Website } else { Microsoft.PowerShell.Management\Get-ChildItem -Path $Path -ErrorAction $ErrorAction } }
    try { . (Join-Path $repo 'status.ps1') -ConfigPath (Join-Path $FixtureRoot 'static.json') -JsonPath (Join-Path $FixtureRoot 'static-result.json') -FailOnCritical } catch { Write-Output $_.ScriptStackTrace; throw }
    return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'Windows runtime status tests require Windows; skipped on this host.'; return }
Set-StrictMode -Version Latest
. (Join-Path $repo 'scripts\windows\WindowsServiceSecurity.ps1')
. (Join-Path $repo 'scripts\windows\WindowsRuntimeStatus.ps1')
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
foreach ($manager in @('winsw', 'nssm', 'static-iis')) {
    Assert-Test (Test-WindowsHealthTaskRunLevel $manager 'Highest') 'Native task Highest run level was rejected.'
    Assert-Test (Test-WindowsHealthTaskRunLevel $manager '1') 'Native task numeric Highest run level was rejected.'
    Assert-Test (-not (Test-WindowsHealthTaskRunLevel $manager 'Limited')) 'Native task was allowed at Limited run level.'
}
Assert-Test (Test-WindowsHealthTaskRunLevel 'pm2' 'Limited') 'PM2 task Limited run level was rejected.'
Assert-Test (Test-WindowsHealthTaskRunLevel 'pm2' '0') 'PM2 task numeric Limited run level was rejected.'
Assert-Test (-not (Test-WindowsHealthTaskRunLevel 'pm2' 'Highest')) 'PM2 task was allowed to elevate.'
Assert-Test (-not (Test-WindowsHealthTaskRunLevel 'pm2' '1')) 'PM2 numeric Highest run level was accepted.'
function Import-StatusFunctions {
    param([string]$Path)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Status source must parse.'
    return $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
}
$testRoot = Join-Path (Join-Path $repo '.tmp') ('windows-runtime-status-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    & {
        param($fixture, $repository)
        foreach ($definition in @(Import-StatusFunctions (Join-Path $repository 'status.ps1'))) { . ([scriptblock]::Create($definition.Extent.Text)) }
        & {
            param($fixture)
            $script:aclModel = [Security.AccessControl.DirectorySecurity]::new()
            $script:aclModel.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            $script:aclModel.SetAccessRuleProtection($true,$false)
            $creator = [Security.Principal.SecurityIdentifier]::new('S-1-3-0')
            $allow = [Security.AccessControl.AccessControlType]::Allow
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($creator,[Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.InheritanceFlags]::ObjectInherit,[Security.AccessControl.PropagationFlags]::InheritOnly,$allow)
            $script:aclModel.AddAccessRule($rule)
            function Get-Acl {
                param($LiteralPath)
                $model = [pscustomobject]@{
                    AreAccessRulesProtected = $script:aclModel.AreAccessRulesProtected
                    Access = @($script:aclModel.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
                    OwnerSid = $script:aclModel.GetOwner([Security.Principal.SecurityIdentifier]).Value
                }
                $model | Add-Member ScriptMethod GetOwner { param($IdentityType); [Security.Principal.SecurityIdentifier]::new($this.OwnerSid) } -PassThru
            }
            Assert-Test (Test-PathAclPreventsUntrustedWrite $fixture '' $true) 'Exact PM2 data-file creator rule was rejected.'
            Assert-Test (-not (Test-PathAclPreventsUntrustedWrite $fixture)) 'CREATOR OWNER writes were accepted for native task/definition paths.'
            $script:aclModel.RemoveAccessRuleSpecific($rule)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($creator,[Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.InheritanceFlags]::ObjectInherit,[Security.AccessControl.PropagationFlags]::None,$allow)
            $script:aclModel.AddAccessRule($rule)
            Assert-Test (-not (Test-PathAclPreventsUntrustedWrite $fixture '' $true)) 'A creator rule that modifies the task directory was accepted.'
            $script:aclModel.RemoveAccessRuleSpecific($rule)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($creator,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]::ObjectInherit,[Security.AccessControl.PropagationFlags]::InheritOnly,$allow)
            $script:aclModel.AddAccessRule($rule)
            Assert-Test (-not (Test-PathAclPreventsUntrustedWrite $fixture '' $true)) 'Creator ownership/ACL-changing rights were accepted.'
        } $fixture
        Assert-Test (Test-TextContainsConfiguredPath '"C:\service\app.exe"' 'C:\service\app.exe') 'Exact quoted SCM wrapper path must match.'
        Assert-Test (-not (Test-TextContainsConfiguredPath 'C:\service\app.exe.evil' 'C:\service\app.exe')) 'A wrapper executable suffix must not pass path verification.'
        Assert-Test (-not (Test-TextContainsConfiguredPath '"C:\different.exe" C:\service\app.exe' 'C:\service\app.exe')) 'A wrapper path appearing only in arguments must not pass verification.'
        $config=[pscustomobject]@{ AppName='fixture'; ServiceManager='pm2'; AppDirectory=(Join-Path $fixture 'app'); ServiceDirectory=(Join-Path $fixture 'service'); LogDirectory=(Join-Path $fixture 'logs'); NodeExe='C:\tools\node.exe'; StartCommand='server.js'; NodeArguments='--port 3000'; HealthUrl='http://127.0.0.1:3000/health' }
        $query=Join-Path $fixture 'fake-pm2.ps1'
        [IO.File]::WriteAllText($query, 'Get-Content -LiteralPath (Join-Path $env:PM2_HOME "jlist.json") -Raw; $global:LASTEXITCODE=0')
        $script:context=[pscustomobject]@{ Home=$fixture; Account=[Security.Principal.WindowsIdentity]::GetCurrent().Name; CommandName=$query }
        function Get-WindowsPm2RuntimeContext { param($Config); $script:context }
        function Assert-WindowsPm2ExecutionAllowed { param($Pm2HomePath,$ExpectedOwnerSid) }
        $script:appTokenElevated=$false
        function Get-WindowsNativeProcessToken { param($ProcessId); [pscustomobject]@{ OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Elevated=$script:appTokenElevated; ProcessId=$ProcessId } }
        $script:start=(Get-Date).AddMinutes(-10)
        $script:ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        function Get-Process { param($Id,$ErrorAction); [pscustomobject]@{ StartTime=$script:start; Path='C:\tools\node.exe' } }
        function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); [pscustomobject]@{ ProcessId=12345 } }
        function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction); [pscustomobject]@{ ReturnValue=0; Sid=$script:ownerSid } }
        $entry=[ordered]@{ name='fixture'; pid=12345; pm2_env=[ordered]@{ status='online'; exec_interpreter='C:\tools\node.exe'; pm_cwd=$config.AppDirectory; pm_exec_path=(Join-Path $config.AppDirectory 'server.js'); args=@('--port','3000'); pm_uptime=([DateTimeOffset]$script:start).ToUnixTimeMilliseconds(); API_TOKEN='must-not-be-returned' } }
        function Save-Entry { ConvertTo-Json -InputObject @($entry) -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'jlist.json') -Encoding UTF8 }
        Save-Entry
        $before=[Environment]::GetEnvironmentVariable('PM2_HOME','Process')
        $runtime=Get-WindowsPm2RuntimeEvidence $config
        Assert-Test ($runtime.Exists -and $runtime.Online -and $runtime.OwnerMatches -and $runtime.RuntimeMatchesConfig -and $runtime.UptimeMatchesProcess) 'Healthy PM2 runtime was not recognized.'
        Assert-Test (-not (($runtime | ConvertTo-Json).Contains('must-not-be-returned'))) 'PM2 environment leaked into runtime evidence.'
        Assert-Test ([string][Environment]::GetEnvironmentVariable('PM2_HOME','Process') -ceq [string]$before) 'PM2 status leaked its daemon home into the caller.'
        $script:appTokenElevated=$true
        $privilegedRejected=$false
        try { Get-WindowsPm2RuntimeEvidence $config | Out-Null } catch { $privilegedRejected=$_.Exception.Message.Contains('unelevated PM2 owner') }
        Assert-Test $privilegedRejected 'Status reported an elevated PM2 application as healthy.'
        $script:appTokenElevated=$false
        $script:ownerSid='S-1-5-20'
        Assert-Test (-not (Get-WindowsPm2RuntimeEvidence $config).OwnerMatches) 'Different PID owner was accepted.'
        $script:ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $entry.pm2_env.pm_uptime-=3600000; Save-Entry
        Assert-Test (-not (Get-WindowsPm2RuntimeEvidence $config).UptimeMatchesProcess) 'Stale PM2 uptime was accepted.'
        $entry.pm2_env.pm_uptime=([DateTimeOffset]$script:start).ToUnixTimeMilliseconds()
        $entry.pm2_env.pm_exec_path='C:\different\server.js'; Save-Entry
        Assert-Test (-not (Get-WindowsPm2RuntimeEvidence $config).RuntimeMatchesConfig) 'Different PM2 active script was accepted.'
        $entry.pm2_env.status='stopped'; Save-Entry
        Assert-Test (-not (Get-WindowsPm2RuntimeEvidence $config).Online) 'Stopped PM2 app was treated as online.'
        [IO.File]::WriteAllText((Join-Path $fixture 'jlist.json'),'[]')
        Assert-Test (-not (Get-WindowsPm2RuntimeEvidence $config).Exists) 'Missing PM2 app was treated as installed.'
        Assert-Test (Test-WindowsPm2TaskPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) 'Current PM2 owner task SID was rejected.'
        Assert-Test (-not (Test-WindowsPm2TaskPrincipal 'S-1-5-20')) 'Different PM2 task owner SID was accepted.'

        $monitor=New-ExpectedHealthMonitorConfig $config
        $monitorPath=Join-Path $fixture 'monitor.json'
        $monitor | ConvertTo-Json | Set-Content -LiteralPath $monitorPath -Encoding UTF8
        Assert-Test (Test-HealthMonitorConfigMatchesDeployment $monitorPath $config) 'Matching PM2 monitor config was rejected.'
        $monitor.PM2Home=Join-Path $fixture 'different-home'
        $monitor | ConvertTo-Json | Set-Content -LiteralPath $monitorPath -Encoding UTF8
        Assert-Test (-not (Test-HealthMonitorConfigMatchesDeployment $monitorPath $config)) 'A different PM2 home was accepted by monitor evidence.'
    } $testRoot $repo

    & {
        param($repository)
        foreach ($definition in @(Import-StatusFunctions (Join-Path $repository 'scripts/dev/Test-SupportEvidenceCoverage.ps1'))) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $monitor=[ordered]@{ status='ok'; scheduled=$true; scheduleType='windows-task'; stateExists=$true; lastSuccessFresh=$true; consecutiveFailures=0; logExists=$true; logFailureCount=0; logRestartCount=0; taskExists=$true; taskPrincipalChecked=$true; taskRunsAsSystem=$false; taskRunsAsPm2Owner=$true; taskRunLevelHighest=$false; taskRunLevelLimited=$true; taskActionChecked=$true; taskActionUsesSystemPowerShell=$true; taskActionUsesWorkingDirectory=$true; taskActionUsesHealthCheckScript=$true; taskActionUsesConfigPath=$true; taskScriptHashMatchesSource=$true; taskConfigMatchesDeployment=$true; taskFilesAclProtected=$true; taskMissedRuns=0; taskLastResult=0 }
        $hostEvidence=[pscustomobject]@{ platform=[pscustomobject]@{ serviceManager='pm2' }; healthMonitor=[pscustomobject]$monitor }
        Assert-Test (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence)) 'Owner-bound PM2 health evidence was rejected.'
        $hostEvidence.healthMonitor.taskRunLevelHighest=$true; $hostEvidence.healthMonitor.taskRunLevelLimited=$false
        Assert-Test (-not (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence))) 'Elevated PM2 task evidence was accepted.'
        $hostEvidence.healthMonitor.taskRunLevelLimited=$true
        Assert-Test (-not (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence))) 'Contradictory Limited/Highest PM2 task evidence was accepted.'
        $hostEvidence.healthMonitor.taskRunLevelHighest=$false
        $hostEvidence.platform.serviceManager='winsw'
        Assert-Test (-not (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence))) 'Native Windows health evidence was allowed without SYSTEM.'
        $hostEvidence.healthMonitor.taskRunsAsSystem=$true
        Assert-Test (-not (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence))) 'Limited native Windows task evidence was accepted.'
        $hostEvidence.healthMonitor.taskRunLevelHighest=$true; $hostEvidence.healthMonitor.taskRunLevelLimited=$false
        Assert-Test (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence)) 'SYSTEM/Highest native Windows task evidence was rejected.'
        $hostEvidence.platform.serviceManager='pm2'; $hostEvidence.healthMonitor.taskRunsAsPm2Owner=$false; $hostEvidence.healthMonitor.taskRunsAsSystem=$true
        Assert-Test (-not (Test-HealthMonitorEvidence (Get-HealthMonitorEvidence $hostEvidence))) 'SYSTEM was allowed to monitor a different PM2 daemon owner.'
        $serviceEvidence=[pscustomobject]@{ activeStatus='running'; enabledStatus='automatic'; definitionChecked=$true; definitionExists=$true; serviceWrapperMatchesConfig=$false; nodeExeMatchesConfig=$true; workingDirectoryMatchesConfig=$true; argumentsMatchConfig=$true; runnerScriptMatchesConfig=$null }
        Assert-Test (-not (Test-ServiceEvidence $serviceEvidence 'nssm')) 'NSSM evidence accepted an unverified protected wrapper path.'
        $serviceEvidence.serviceWrapperMatchesConfig=$true
        Assert-Test (Test-ServiceEvidence $serviceEvidence 'nssm') 'Verified protected NSSM wrapper evidence was rejected.'
    } $repo

    [ordered]@{ AppName='fixture-static'; DeploymentMode='static_iis'; ServiceManager='none'; AppFramework='react'; AppDirectory=(Join-Path $testRoot 'app'); IisSiteName='fixture-static'; IisSitePath=(Join-Path $testRoot 'iis'); IisAppPoolName='fixture-pool'; PublicPort=8080; BackupDirectory=(Join-Path $testRoot 'backups') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'static.json') -Encoding UTF8
    $shell=(Get-Process -Id $PID).Path
    $output=& $shell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -StaticChild -FixtureRoot $testRoot 2>&1
    Assert-Test ($LASTEXITCODE -eq 0) "Static IIS status failed: $output"
    $staticResult=Get-Content -LiteralPath (Join-Path $testRoot 'static-result.json') -Raw | ConvertFrom-Json
    Assert-Test ($staticResult.NodeServiceApplicable -eq $false -and $staticResult.Critical -eq 0 -and $staticResult.Iis.SiteStarted) 'Static IIS status incorrectly required a Node service.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot); $allowed=[IO.Path]::GetFullPath((Join-Path $repo '.tmp'))+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing status-fixture cleanup outside repository .tmp.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'PM2 runtime/owner/uptime, health evidence and static IIS status scope tests OK'
& (Join-Path $PSScriptRoot 'Test-Pm2HealthTaskAcl.ps1')
