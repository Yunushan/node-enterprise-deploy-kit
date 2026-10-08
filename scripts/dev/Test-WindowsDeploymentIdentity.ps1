Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/windows/DeploymentLock.ps1')
. (Join-Path $repoRoot 'scripts/windows/WindowsServiceSecurity.ps1')
. (Join-Path $repoRoot 'scripts/windows/AppPackageLifecycle.ps1')
. (Join-Path $repoRoot 'scripts/windows/WindowsRuntimeStatus.ps1')
function Assert-IdentityTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-IdentityRejected([scriptblock]$Action,[string]$Message,[string]$Expected=''){$failure=$null;try{& $Action|Out-Null}catch{$failure=$_};Assert-IdentityTest ($null-ne$failure) $Message;if($Expected){Assert-IdentityTest ($failure.Exception.Message.Contains($Expected)) ('Unexpected failure: '+$failure.Exception.Message)}}
foreach($name in @('Foo','Foo.Bar','Foo-Bar_2','.hidden','CON_app','CON2','COM10','LPT10','all','123','-native')){Assert-WindowsDeploymentAppName -AppName $name}
foreach($cfg in @([pscustomobject]@{AppName='minimal-valid'},@{AppName='minimal-valid'},[pscustomobject]@{AppName='all';ServiceManager='winsw'},[pscustomobject]@{AppName='all';ServiceManager='pm2';DeploymentMode='static_iis'})){Assert-WindowsDeploymentConfigIdentity -Config $cfg}
Assert-IdentityTest (@(ConvertFrom-WindowsPm2ProcessJson -Json '[]').Count-eq0) 'Empty jlist was treated as a null process.'
Assert-IdentityTest (@(ConvertFrom-WindowsPm2ProcessJson -Json '[{"name":"api"}]').Count-eq1) 'A one-entry jlist lost its array shape.'
foreach($json in @('[null]','[null,null]','null','{}','{"name":"api"}','[1]','["api"]','[{}]trailing')){Assert-IdentityRejected {ConvertFrom-WindowsPm2ProcessJson -Json $json} 'Non-array/null/scalar process state was admitted.'}
foreach($name in @('1api','NaN','infinity','0xinvalid','1_2','all-api','api-1')){Assert-WindowsPm2DeploymentAppName -AppName $name}
foreach($name in @('all','ALL','-api','--only','0','123','01','1.5','.5','1e2','1E-2','1e999','0xFF','0Xabc','0b10','0B01','0o17','0O07','Infinity')){
    Assert-IdentityRejected {Assert-WindowsPm2DeploymentAppName -AppName $name} "PM2 selector was admitted: $name"
    Assert-IdentityRejected {Assert-WindowsDeploymentConfigIdentity -Config ([pscustomobject]@{AppName=$name;ServiceManager='pm2'})} 'PM2 configured selector reached downstream probes.'
}
foreach($name in @('', '.', '..', 'Foo.', 'Foo...', 'Foo ', 'a/b', 'a\b', 'a:stream', 'CON','con.txt','PrN','AUX.json','NUL','COM1','com9.log','LPT1','lPt9.xml',"COM$([char]0xb9)","f$([char]0x131)xture")){
    Assert-IdentityRejected {Assert-WindowsDeploymentAppName -AppName $name} "Unsafe namespace identity was admitted: $name"
    Assert-IdentityRejected {Get-DeploymentLockDirectory ([pscustomobject]@{AppName=$name;DeploymentLockDirectory=(Join-Path $repoRoot '.tmp/identity-unused')})} "Common lock namespace admitted $name"
}
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){Write-Host 'Portable Windows app identity validation OK; native alias demonstration skipped.';return}
$fixture=Join-Path $repoRoot ('.tmp/windows-identity-test-'+[guid]::NewGuid().ToString('N'))
$lease=$null
try{
    $healthRoot=Join-Path $fixture 'healthchecks';$locks=Join-Path $fixture 'locks'
    New-Item -ItemType Directory -Path $healthRoot,$locks -Force|Out-Null
    $plain=Join-Path $healthRoot 'Foo';$dotted=Join-Path $healthRoot 'Foo.'
    New-Item -ItemType Directory -Path $plain -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $plain 'owner.txt'),'plain-owner')
    New-Item -ItemType Directory -Path $dotted -Force|Out-Null
    Assert-IdentityTest (@([IO.Directory]::GetDirectories($healthRoot)).Count-eq1) 'Native alias fixture did not normalize a trailing dot on this Windows filesystem.'
    Assert-IdentityTest ([IO.File]::ReadAllText((Join-Path $dotted 'owner.txt'))-eq'plain-owner') 'Native trailing-dot path did not alias the original owner.'
    $lease=Enter-DeploymentLock -Config ([pscustomobject]@{AppName='Foo';DeploymentLockDirectory=$locks}) -SkipAclHardening
    foreach($name in @('Foo.','CON','con.txt','NUL','COM1','LPT9.xml')){
        Assert-IdentityRejected {Enter-DeploymentLock -Config ([pscustomobject]@{AppName=$name;DeploymentLockDirectory=$locks}) -SkipAclHardening} 'Invalid name reached lock mutation.'
    }
    Assert-IdentityTest (@([IO.Directory]::GetFiles($locks)).Count-eq1) 'Rejected alias/device name created a second mutex file.'
    Assert-IdentityTest ([IO.Path]::GetFileName(@([IO.Directory]::GetFiles($locks))[0])-ceq'Foo.lock') 'Valid lock namespace changed.'
    & {
        param($repoRoot)
        foreach($source in @('Install-PM2Fallback.ps1','Invoke-NodeHealthCheck.ps1','Register-HealthCheckTask.ps1')){
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "scripts/windows/$source"),[ref]$tokens,[ref]$errors)
            foreach($definition in $ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-in@('Invoke-CheckedPm2Command','Invoke-Pm2HealthCommand','New-HealthMonitorConfig')},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
        }
        $script:pm2IdentityProbes=0
        function Assert-WindowsPm2ExecutionAllowed{param($Pm2HomePath,$ExpectedOwnerSid);$script:pm2IdentityProbes++;throw 'Unexpected token probe'}
        function Get-WindowsServiceSecurityFullPath{param($Path);$script:pm2IdentityProbes++;throw 'Unexpected path probe'}
        function Get-Command{param($Name);$script:pm2IdentityProbes++;throw 'Unexpected command resolution'}
        function identityUnexpectedPm2{ $script:pm2IdentityProbes++;throw 'Unexpected CLI'}
        foreach($name in @('all','--only','-api','123','1.5','.5','1e2','1E-2','0xFF','0b10','0o17','Infinity')){
            $config=[pscustomobject]@{AppName=$name;ServiceManager='pm2';PM2Home='C:\unused';PM2Command='identityUnexpectedPm2'}
            $state=[pscustomobject]@{Kind='pm2';Name=$name;Exists=$true;WasRunning=$true;CommandName='identityUnexpectedPm2'}
            foreach($action in @(
                {Get-WindowsPm2RuntimeContext $config}, {Get-AppPackagePm2State -Name $name},
                {Stop-AppPackageService $state}, {Start-AppPackageServiceAfterFailure $state}, {Remove-NewAppPackageServiceAfterFailure $state},
                {Get-WindowsPm2RuntimeEvidence $config}, {Invoke-CheckedPm2Command 'identityUnexpectedPm2' @('delete',$name) 'test'},
                {Invoke-Pm2HealthCommand @('restart',$name)}, {New-HealthMonitorConfig $config}
            )){Assert-IdentityRejected $action 'Actual PM2 boundary admitted selector' 'PM2 AppName'}
        }
        Assert-IdentityTest ($script:pm2IdentityProbes-eq0) 'Rejected selector reached CLI, token, path or command-resolution probe.'
    } $repoRoot
    & {
        param($repoRoot)
        # The real lifecycle/monitor functions control a fake daemon with two
        # exact-name cluster entries and unrelated name/path/namespace aliases.
        $script:identityPm2Entries=[Collections.Generic.List[object]]::new()
        foreach($entry in @(
            @{name='api';pm_id=7;pm2_env=@{name='api';status='online';namespace='owned';pm_exec_path='C:\app\server.js'}},
            @{name='api';pm_id=8;pm2_env=@{name='api';status='online';namespace='owned';pm_exec_path='C:\app\server.js'}},
            @{name='other-path';pm_id=9;pm2_env=@{name='other-path';status='online';namespace='api';pm_exec_path=[IO.Path]::GetFullPath((Join-Path (Get-Location).Path 'api'))}}
        )){$script:identityPm2Entries.Add(($entry|ConvertTo-Json -Depth 5|ConvertFrom-Json))}
        $script:identityPm2Commands=[Collections.Generic.List[string]]::new()
        function Assert-WindowsPm2ExecutionAllowed{param($Pm2HomePath,$ExpectedOwnerSid)}
        function identityFakePm2{
            param([Parameter(ValueFromRemainingArguments=$true)][object[]]$CommandArgs)
            $global:LASTEXITCODE=0
            if($CommandArgs[0]-eq'jlist'){return ConvertTo-Json -InputObject @($script:identityPm2Entries.ToArray()) -Depth 6 -Compress}
            $script:identityPm2Commands.Add(($CommandArgs-join' '))
            if($CommandArgs[0]-eq'save'){if($CommandArgs.Count-ne2-or$CommandArgs[1]-ne'--force'){throw 'Empty process dump must use forced save'};return}
            Assert-IdentityTest ($CommandArgs.Count-eq2-and[string]$CommandArgs[1]-in@('7','8')) 'Mutation used a name/namespace selector or unrelated process ID.'
            $entry=@($script:identityPm2Entries|Where-Object{[string]$_.pm_id-ceq[string]$CommandArgs[1]})[0]
            switch($CommandArgs[0]){'stop'{$entry.pm2_env.status='stopped'}'restart'{$entry.pm2_env.status='online'}'delete'{[void]$script:identityPm2Entries.Remove($entry)}default{throw 'Unexpected command'}}
        }
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/windows/Invoke-NodeHealthCheck.ps1'),[ref]$tokens,[ref]$errors)
        foreach($definition in $ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-in@('Invoke-ManagedHealthRestart')},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
        function Invoke-Pm2HealthCommand{param([string[]]$Arguments);return (& identityFakePm2 @Arguments|Out-String)}
        $serviceManager='pm2';$config=[pscustomobject]@{AppName='api'}
        $state=[pscustomobject]@{Kind='pm2';Name='api';Exists=$true;WasRunning=$true;CommandName='identityFakePm2'}
        Stop-AppPackageService $state
        Assert-IdentityTest (@($script:identityPm2Entries|Where-Object{$_.name-ceq'api'-and$_.pm2_env.status-ne'stopped'}).Count-eq0) 'Cluster stop missed an exact app process.'
        Start-AppPackageServiceAfterFailure $state
        Invoke-ManagedHealthRestart
        Assert-IdentityTest ($script:identityPm2Commands.Contains('restart 7')-and$script:identityPm2Commands.Contains('restart 8')) 'Health restart did not target each exact cluster process ID.'
        Remove-NewAppPackageServiceAfterFailure $state
        Assert-IdentityTest ($script:identityPm2Entries.Count-eq1-and$script:identityPm2Entries[0].name-ceq'other-path'-and$script:identityPm2Entries[0].pm2_env.status-eq'online') 'Exact mutations affected a foreign path/namespace app.'
        $before=$script:identityPm2Commands.Count
        Assert-IdentityRejected {Stop-AppPackageService $state} 'Missing exact app fell back to namespace.' 'Exact managed PM2 process is missing'
        Assert-IdentityRejected {Invoke-ManagedHealthRestart} 'Missing health app fell back to namespace.' 'Exact managed PM2 process is missing'
        Assert-IdentityTest ($script:identityPm2Commands.Count-eq$before) 'Missing exact process issued a mutating CLI command.'
    } $repoRoot
    $tokens=$null;$errors=$null
    foreach($source in @('Register-HealthCheckTask.ps1','Diagnose-NodeApp.ps1')){
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "scripts/windows/$source"),[ref]$tokens,[ref]$errors)
        foreach($definition in $ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-in@('Get-HealthTaskDirectory','Get-WindowsDiagnosticDirectory','New-HealthMonitorConfig')},$true)){
            & {
                param($definition)
                . ([scriptblock]::Create($definition.Extent.Text))
                foreach($name in @('Foo.','CON','con.xml','LPT1')){
                    $script:identityProbeReached=$false
                    function Get-WindowsServiceSecurityFullPath{param($Path);$script:identityProbeReached=$true;throw 'Unexpected path probe'}
                    $cfg=[pscustomobject]@{AppName=$name}
                    if($definition.Name-eq'Get-WindowsDiagnosticDirectory'){Assert-IdentityRejected {Get-WindowsDiagnosticDirectory -AppName $name -OutputDirectory 'C:\private'} 'Diagnostics admitted a namespace alias'}
                    else{Assert-IdentityRejected {& $definition.Name $cfg} 'Monitor admitted a namespace alias'}
                    Assert-IdentityTest (-not $script:identityProbeReached) 'Invalid identity reached a configured-path probe.'
                }
            } $definition
        }
    }
    Write-Host 'Actual Windows Foo/Foo. directory alias, distinct-lock prevention, reserved names and monitor/diagnostic entry guards OK.'
}finally{
    if($lease){Exit-DeploymentLock $lease}
    $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp')).TrimEnd('\','/')
    if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$parent-or(Split-Path -Leaf $resolved)-notmatch'^windows-identity-test-[a-f0-9]{32}$'){throw 'Unsafe identity fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
