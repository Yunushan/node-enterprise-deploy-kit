Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'Windows diagnostic privacy tests require Windows; skipped.';return}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/windows/WindowsServiceSecurity.ps1')
function Assert-DiagnosticTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Import-DiagnosticFunctions([string]$Path){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-DiagnosticTest ($errors.Count -eq 0) 'Diagnostic/retention source must parse.'
    return $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
}
$fixture=Join-Path $repoRoot ('.tmp/windows-diagnostic-privacy-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture,(Join-Path $fixture 'app'),(Join-Path $fixture 'logs') -Force | Out-Null
try {
    $secrets=@('diag-secret-query-value','diag-secret-argument-value','diag-secret-start-value','diag-secret-service-value','diag-secret-event-value','diag-secret-http-value')
    $config=[ordered]@{AppName='diagnostic-fixture';AppFramework='nextjs';NextjsDeploymentMode='standalone';AppDirectory=(Join-Path $fixture 'app');LogDirectory=(Join-Path $fixture 'logs');ServiceDirectory=(Join-Path $fixture 'service');Port=3000;HealthUrl='http://127.0.0.1/health?token=diag-secret-query-value';StartCommand='server.js --token diag-secret-start-value';NodeArguments='--password diag-secret-argument-value';Environment=@{API_TOKEN='diag-private-environment-value'}}
    $configPath=Join-Path $fixture 'config.json';$config|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $configPath -Encoding UTF8
    & {
        param($repo,$fixture,$configPath,$secrets)
        function Get-CimInstance {param($ClassName,$Filter,$ErrorAction);if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{LastBootUpTime=(Get-Date).AddHours(-2)}}elseif($ClassName -eq 'Win32_Service'){[pscustomobject]@{Name='diagnostic-fixture';State='Running';StartMode='Auto';ProcessId=0;PathName='"C:\fixture\node.exe" --token diag-secret-service-value'}}}
        function Get-Service {param($Name,$ErrorAction);[pscustomobject]@{Name=$Name;Status='Running'}}
        function Get-Process {param($Name,$ErrorAction)}
        function Get-NetTCPConnection {param($LocalPort,$ErrorAction)}
        function Get-ScheduledTaskInfo {param($TaskName,$ErrorAction)}
        function Invoke-WebRequest {param($Uri,[switch]$UseBasicParsing,$TimeoutSec);throw 'diag-secret-http-value'}
        function Get-WinEvent {param($LogName,$FilterHashtable,$MaxEvents,$ErrorAction);[pscustomobject]@{TimeCreated=Get-Date;ProviderName='FixtureNode';Id=123;LevelDisplayName='Error';Message='node diagnostic-fixture diag-secret-event-value'}}
        foreach($raw in @($false,$true)){
            $output=Join-Path $fixture $(if($raw){'raw'}else{'summary'})
            & (Join-Path $repo 'scripts/windows/Diagnose-NodeApp.ps1') -ConfigPath $configPath -OutputDirectory $output -IncludeRawDetails:$raw
            $files=@(Get-ChildItem -LiteralPath $output -File)
            if($files.Count -ne 1){throw 'Diagnostic script did not produce exactly one bundle.'}
            Assert-DiagnosticTest ($files[0].Name -match '^diagnostics-[0-9]{14}\.[0-9]+\.[a-f0-9]{32}\.txt$') 'Diagnostic output lacks a unique completed-report filename.'
            $acl=Get-Acl -LiteralPath $files[0].FullName
            Assert-DiagnosticTest $acl.AreAccessRulesProtected 'Explicit diagnostic file inherited broad permissions.'
            $sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object{$_.IdentityReference.Value})
            Assert-DiagnosticTest ($sids -notcontains 'S-1-1-0' -and $sids -notcontains 'S-1-5-11' -and $sids -notcontains 'S-1-5-32-545') 'Explicit private diagnostic file grants broad user access.'
            $text=[IO.File]::ReadAllText($files[0].FullName)
            foreach($secret in $secrets){if($text.Contains($secret) -ne $raw){throw "Diagnostic privacy expectation failed: raw=$raw, fixture=$secret"}}
            if($text.Contains('diag-private-environment-value')){throw 'Diagnostic bundle exported private deployment environment.'}
            if(-not $text.Contains("RawDetailsIncluded=$raw")){throw 'Diagnostic bundle lost the raw-detail marker.'}
            if(-not $text.Contains('ProviderName') -or -not $text.Contains('FixtureNode')){throw 'Safe diagnostic event metadata was lost.'}
        }
    } $repoRoot $fixture $configPath $secrets
    & {
        param($repo,$fixture)
        foreach($definition in Import-DiagnosticFunctions (Join-Path $repo 'scripts/windows/Diagnose-NodeApp.ps1')){. ([scriptblock]::Create($definition.Extent.Text))}
        $actualCommon=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        Assert-DiagnosticTest ((Get-WindowsDiagnosticDirectory -AppName 'fixture') -eq (Join-Path $actualCommon 'node-enterprise-deploy-kit/healthchecks/fixture/diagnostics')) 'Default diagnostics still target runtime-writable application logs.'
        foreach($name in @('..','.','../escape','bad:name')){
            $rejected=$false;try{Get-WindowsDiagnosticDirectory -AppName $name|Out-Null}catch{$rejected=$true}
            Assert-DiagnosticTest $rejected 'Unsafe AppName was accepted for default diagnostics.'
        }
        & {
            param($fixture)
            $script:controlAcl=New-WindowsProtectedPathAcl -Directory $true
            function Get-Acl {param($LiteralPath,$ErrorAction);$script:controlAcl}
            Assert-WindowsDiagnosticControlDirectory $fixture
            $untrusted=[Security.Principal.SecurityIdentifier]::new('S-1-5-20')
            $dangerous=[Security.AccessControl.FileSystemAccessRule]::new($untrusted,[Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.AccessControlType]::Allow)
            $script:controlAcl.AddAccessRule($dangerous)
            $rejected=$false;try{Assert-WindowsDiagnosticControlDirectory $fixture}catch{$rejected=$true}
            Assert-DiagnosticTest $rejected 'Default diagnostic parent accepted runtime deletion/control changes.'
            $script:controlAcl.RemoveAccessRuleSpecific($dangerous)
            $narrow=[Security.AccessControl.FileSystemAccessRule]::new($untrusted,([Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::CreateFiles),[Security.AccessControl.AccessControlType]::Allow)
            $script:controlAcl.AddAccessRule($narrow)
            Assert-WindowsDiagnosticControlDirectory $fixture
            $script:controlAcl.SetOwner($untrusted)
            $rejected=$false;try{Assert-WindowsDiagnosticControlDirectory $fixture}catch{$rejected=$true}
            Assert-DiagnosticTest $rejected 'Default diagnostics accepted a runtime-owned control directory.'
        } $fixture
        $fixtureIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $realPathSetter=${function:Set-WindowsProtectedPathSecurity}
        $script:diagnosticAclCalls=[Collections.Generic.List[object]]::new()
        function Set-WindowsProtectedPathSecurity {
            param($Path,$Account='',$RuntimeRights=[Security.AccessControl.FileSystemRights]::ReadAndExecute,$OwnerAccount='')
            $script:diagnosticAclCalls.Add([pscustomobject]@{Kind='path';Path=$Path;RequestedAccount=$Account;RequestedOwner=$OwnerAccount})
            # Apply actual private NTFS ACLs with the current owner because this
            # workstation is not elevated. Production calls below must request
            # the default SYSTEM/Admin-only ACL, with no runtime account.
            & $realPathSetter -Path $Path -Account $fixtureIdentity -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $fixtureIdentity
        }
        function Set-WindowsProtectedFileSecurity {
            param($Path,$Account='',$OwnerAccount='')
            $script:diagnosticAclCalls.Add([pscustomobject]@{Kind='file';Path=$Path;RequestedAccount=$Account;RequestedOwner=$OwnerAccount})
            & $realPathSetter -Path $Path -Account $fixtureIdentity -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $fixtureIdentity
        }
        function Assert-WindowsDiagnosticControlDirectory {
            param($Path)
            Assert-WindowsServiceSecurityNoReparse $Path
            Assert-DiagnosticTest ((Get-Acl -LiteralPath $Path).AreAccessRulesProtected) 'Simulated managed diagnostic parent is not protected.'
        }
        $simulatedCommon=Join-Path $fixture 'ProgramData'
        New-Item -ItemType Directory -Path $simulatedCommon -Force|Out-Null
        $context=Initialize-WindowsDiagnosticOutput -Config ([pscustomobject]@{AppName='fixture'}) -ProgramDataRoot $simulatedCommon
        $second=Initialize-WindowsDiagnosticOutput -Config ([pscustomobject]@{AppName='fixture'}) -ProgramDataRoot $simulatedCommon
        Assert-DiagnosticTest ($context.ManagedDefault -and $context.Directory -eq (Join-Path $simulatedCommon 'node-enterprise-deploy-kit/healthchecks/fixture/diagnostics')) 'Default path wiring changed.'
        Assert-DiagnosticTest ($context.TemporaryPath -ne $second.TemporaryPath -and [IO.Path]::GetExtension($context.TemporaryPath) -eq '.tmp') 'Collector staging names collide or are exposed to completed-report pruning.'
        foreach($call in $script:diagnosticAclCalls){Assert-DiagnosticTest (-not $call.RequestedAccount -and -not $call.RequestedOwner) 'Default diagnostic ACL granted runtime ownership/access.'}
        Assert-DiagnosticTest (@($script:diagnosticAclCalls|Where-Object{$_.Kind -eq 'file'}).Count -eq 2) 'Default collector did not protect empty report files before writing.'
        Remove-Item -LiteralPath $context.TemporaryPath,$second.TemporaryPath -Force
    } $repoRoot $fixture
    & {
        param($repo,$fixture)
        foreach($definition in Import-DiagnosticFunctions (Join-Path $repo 'scripts/windows/Invoke-NodeHealthCheck.ps1')){. ([scriptblock]::Create($definition.Extent.Text))}
        $healthStateDirectory=Join-Path $fixture 'monitor'
        $protectedDiagnostics=Join-Path $healthStateDirectory 'diagnostics'
        $legacyDiagnostics=Join-Path $fixture 'logs/diagnostics'
        $locks=Join-Path $fixture 'locks'
        New-Item -ItemType Directory -Path $protectedDiagnostics,$legacyDiagnostics,$locks -Force|Out-Null
        $config=[pscustomobject]@{AppName='fixture';LogDirectory=(Join-Path $fixture 'logs');BackupDirectory='';DeploymentLockPath=(Join-Path $locks 'fixture.lock');DiagnosticRetentionDays=14}
        function Write-HealthLog {param($Message)}
        $expired=Join-Path $protectedDiagnostics 'diagnostics-expired.txt'
        $active=Join-Path $protectedDiagnostics 'diagnostics-active.txt'
        $temporary=Join-Path $protectedDiagnostics 'diagnostics-in-progress.tmp'
        $legacy=Join-Path $legacyDiagnostics 'diagnostics-old.txt'
        $fresh=Join-Path $protectedDiagnostics 'diagnostics-fresh.txt'
        foreach($path in @($expired,$active,$temporary,$legacy,$fresh)){[IO.File]::WriteAllText($path,'fixture report')}
        foreach($path in @($expired,$active,$temporary,$legacy)){[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddDays(-40))}
        $held=[IO.File]::Open($active,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        try{
            Invoke-RetentionCleanup
            Assert-DiagnosticTest (-not (Test-Path -LiteralPath $expired) -and -not (Test-Path -LiteralPath $legacy)) 'Protected/legacy expired diagnostic reports were not pruned.'
            foreach($path in @($active,$temporary,$fresh)){Assert-DiagnosticTest (Test-Path -LiteralPath $path) 'Retention removed an open, active staging or fresh report.'}
        }finally{$held.Dispose()}
        $outside=Join-Path $fixture 'outside';$junction=Join-Path $fixture 'diagnostic-junction'
        New-Item -ItemType Directory -Path $outside -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'diagnostics-outside.txt'),'outside fixture')
        $created=$false
        try{New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop|Out-Null;$created=$true}catch{
            $rootException=$_.Exception;while($rootException.InnerException){$rootException=$rootException.InnerException}
            if($rootException -isnot [UnauthorizedAccessException] -and -not ($rootException -is [ComponentModel.Win32Exception] -and $rootException.NativeErrorCode -eq 5)){throw}
        }
        if($created){
            try{
                Assert-DiagnosticTest (-not (Test-HealthRetentionPathNoReparse (Join-Path $junction 'diagnostics-outside.txt'))) 'Retention accepted a reparse ancestor.'
                Remove-OldFiles -Path $junction -RetentionDays 1 -Include @('*.txt') -RequireExclusiveAccess
                Assert-DiagnosticTest (Test-Path -LiteralPath (Join-Path $outside 'diagnostics-outside.txt')) 'Retention traversed a diagnostic junction.'
                $rejected=$false;try{Assert-WindowsServiceSecurityNoReparse (Join-Path $junction 'report.txt')}catch{$rejected=$true}
                Assert-DiagnosticTest $rejected 'Diagnostic output accepted a reparse ancestor.'
                & {
                    param($repo,$junction)
                    foreach($definition in Import-DiagnosticFunctions (Join-Path $repo 'scripts/windows/Diagnose-NodeApp.ps1')){. ([scriptblock]::Create($definition.Extent.Text))}
                    $rejected=$false;try{Initialize-WindowsDiagnosticOutput -Config ([pscustomobject]@{AppName='fixture'}) -OutputDirectory (Join-Path $junction 'nested')|Out-Null}catch{$rejected=$true}
                    Assert-DiagnosticTest $rejected 'Actual output initialization traversed a reparse ancestor.'
                } $repo $junction
            }finally{Remove-Item -LiteralPath $junction -Force}
        }
    } $repoRoot $fixture
    Write-Host 'Actual Windows diagnostic script excludes event/argv/URL/HTTP secrets by default and includes explicitly requested sensitive raw details.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp'))+'\'
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing diagnostic fixture cleanup outside repository .tmp.'}
    if(Test-Path -LiteralPath $resolved){
        $account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        Set-WindowsProtectedPathSecurity -Path $resolved -Account $account -RuntimeRights ([Security.AccessControl.FileSystemRights]::FullControl) -OwnerAccount $account -Recurse
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
