Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SecretPatterns.ps1')
function Assert-SecretTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-SecretFound([string]$Text,[string]$Path){Assert-SecretTest (@(Get-ObviousSecretFindings -Text $Text -RelativePath $Path).Count-gt0) "Secret gate missed literal in $Path"}
$badValue=[guid]::NewGuid().ToString('N')
$badAssignment='$Password = '+[char]39+$badValue+[char]39
foreach($path in @('scripts/windows/UnrelatedProduction.ps1','scripts/dev/UnrelatedTest.ps1','scripts/dev/Test-WindowsProductionSafety.ps1')){Assert-SecretFound $badAssignment $path}
$approved='fixture-private-password'
$approvedAssignment='$Password = '+[char]39+$approved+[char]39
Assert-SecretTest (@(Get-ObviousSecretFindings -Text $approvedAssignment -RelativePath 'scripts/dev/Test-WindowsProductionSafety.ps1').Count-eq0) 'Exact synthetic fixture allowance was lost.'
foreach($path in @('scripts/windows/UnrelatedProduction.ps1','scripts/dev/UnrelatedTest.ps1')){Assert-SecretFound $approvedAssignment $path}
Assert-SecretFound ('$Password = '+[char]39+$approved+'@'+$badValue+[char]39) 'scripts/dev/Test-WindowsProductionSafety.ps1'
Assert-SecretFound ('$TOKEN = '+[char]39+$badValue+'()'+[char]39) 'scripts/windows/UnrelatedProduction.ps1'
Assert-SecretFound ('$Password = '+'1234'+'5678'+'9012') 'config/app.psd1'
Assert-SecretFound ('API_TOKEN='+$badValue) 'scripts/linux/unrelated.sh'
Assert-SecretFound ('{"api_key":"'+$badValue+'"}') 'config/unrelated.json'
Assert-SecretFound ('$details = "token='+$badValue+'"') 'scripts/dev/UnrelatedTest.ps1'
Assert-SecretFound ('$details = "token='+$badValue+'()"') 'scripts/dev/UnrelatedTest.ps1'
$compiledCall='Add-Type -TypeDefinition @'+[char]39+"`n"+'class Api { void Run() { token = '+'EnableShutdownPrivilege(out previousPrivilege); } }'+"`n"+[char]39+'@'
foreach($text in @(('$Password = '+'Get-ManagedTaskRollbackCredential -Transaction $state'),('$token = '+'Get-WindowsNativeProcessToken -ProcessId $PID'),$compiledCall)){Assert-SecretTest (@(Get-ObviousSecretFindings -Text $text -RelativePath 'scripts/windows/Production.ps1').Count-eq0) 'Command or embedded function expression was mistaken for a credential.'}
$privateKeyHeader='-----BEGIN '+'PRIVATE KEY-----'
Assert-SecretFound $privateKeyHeader 'scripts/windows/UnrelatedProduction.ps1'
Assert-SecretFound $privateKeyHeader 'scripts/dev/UnrelatedTest.ps1'
# Execute the aggregate's actual scanner against isolated production/test files,
# then the working tree, without invoking the expensive aggregate fixtures.
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $repoRoot ('.tmp/secret-gate-test-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $fixture -Force|Out-Null
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-Repository.ps1'),[ref]$tokens,[ref]$errors)
    Assert-SecretTest ($errors.Count-eq0) 'Aggregate scanner source did not parse.'
    & {
        # PowerShell variable names are case-insensitive: keep the actual root
        # distinct from the aggregate function's dynamic $RepoRoot variable.
        param($ast,$fixture,$badAssignment,$actualRepositoryRoot)
        foreach($definition in $ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-in@('Write-Step','Test-NoObviousSecrets')},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
        $RepoRoot=$fixture
        $fakeInventory=Join-Path $fixture 'inventory.ps1'
        [IO.File]::WriteAllText($fakeInventory,'Write-Output "scripts/windows/injected.ps1"; Write-Output "scripts/dev/unrelated.ps1"; $global:LASTEXITCODE=0')
        function Get-Command{param($Name);if($Name-eq'git'-and$RepoRoot-eq$fixture){return [pscustomobject]@{Source=$fakeInventory}};Microsoft.PowerShell.Core\Get-Command $Name}
        foreach($relative in @('scripts/windows/injected.ps1','scripts/dev/unrelated.ps1')){
            $path=Join-Path $fixture $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null
            [IO.File]::WriteAllText($path,$badAssignment)
            $failure=$null;try{Test-NoObviousSecrets}catch{$failure=$_}
            Assert-SecretTest ($null-ne$failure-and$failure.Exception.Message-eq'Secret pattern check failed.') 'Actual aggregate gate admitted injected credential.'
            Remove-Item -LiteralPath $path -Force
        }
        Test-NoObviousSecrets
        $RepoRoot=$actualRepositoryRoot
        Assert-SecretTest (Test-Path -LiteralPath (Join-Path $RepoRoot 'scripts/dev/Test-Repository.ps1')) 'The working-tree gate is still pointed at the synthetic fixture.'
        Assert-SecretTest ((Get-Command git).Source-ne$fakeInventory) 'The working-tree gate is still using the fake empty inventory.'
        Test-NoObviousSecrets
    } $ast $fixture $badAssignment $repoRoot
    Write-Host 'Precise synthetic allowances, injected production/test credentials, private keys and actual aggregate source gate OK.'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp')).TrimEnd('\','/')
    if((Split-Path -Parent $resolved).TrimEnd('\','/')-ne$allowed-or(Split-Path -Leaf $resolved)-notmatch'^secret-gate-test-[a-f0-9]{32}$'){throw 'Unsafe secret gate fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
