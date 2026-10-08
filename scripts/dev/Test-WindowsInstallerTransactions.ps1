Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'Windows installer transaction tests require Windows; skipped.'; return }
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
function Assert-InstallerTest([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Get-InstallerAst([string]$Path) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-InstallerTest ($errors.Count -eq 0) "Installer failed to parse: $Path"
    return $ast
}
foreach ($manager in @('winsw','pm2')) {
    foreach ($owned in @($true,$false)) {
        foreach ($failHealth in @($false,$true)) {
            & {
                param($repository,$manager,$owned,$failHealth)
                $fixture=Join-Path $repository ('.tmp/windows-installer-transaction-' + [guid]::NewGuid().ToString('N'))
                $previousHome=[Environment]::GetEnvironmentVariable('PM2_HOME','Process')
                $previousLocation=(Get-Location).Path
                $global:installerTestEvents=[Collections.Generic.List[string]]::new()
                try {
                    $config=[pscustomobject]@{ AppName='installer-fixture'; ServiceManager=$manager; AppDirectory=(Join-Path $fixture 'app'); ServiceDirectory=(Join-Path $fixture 'service'); LogDirectory=(Join-Path $fixture 'logs'); BackupDirectory=(Join-Path $fixture 'backups'); Environment=[pscustomobject]@{ SAMPLE='fixture value' }; Port=3000; NodeExe='C:\fixture\node.exe'; StartCommand='server.js'; NodeArguments=''; DisplayName='Installer fixture'; Description='Local mocked host'; HealthUrl='http://127.0.0.1:3000/health' }
                    $repoRoot=Join-Path $fixture 'repo'
                    New-Item -ItemType Directory -Path $config.AppDirectory,$config.ServiceDirectory,$config.LogDirectory,$config.BackupDirectory,(Join-Path $repoRoot 'scripts/windows'),(Join-Path $repoRoot 'templates/windows') -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $repository 'templates/windows/winsw-service.xml.tpl') -Destination (Join-Path $repoRoot 'templates/windows/winsw-service.xml.tpl')
                    [IO.File]::WriteAllText((Join-Path $repoRoot 'scripts/windows/Ensure-WinSW.ps1'),'param($ConfigPath,$WinSWPath); $global:installerTestEvents.Add("ensure-wrapper")')
                    $WinSWPath=Join-Path $fixture 'trusted-winsw.exe'; [IO.File]::WriteAllText($WinSWPath,'fixture wrapper bytes')
                    $ensureWinswArgs=@{ ConfigPath=(Join-Path $fixture 'config.json'); WinSWPath=$WinSWPath }
                    $WhatIfPreference=$false
                    $pm2Account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
                    $pm2Home=Join-Path $fixture 'daemon'
                    $pm2CommandName=Join-Path $fixture 'pm2.cmd'
                    $ExistingDeploymentLock=if ($owned) { $null } else { [pscustomobject]@{ Borrowed='lock' } }
                    $ExistingManagedDeploymentTransaction=if ($owned) { $null } else { [pscustomobject]@{ Borrowed='transaction' } }
                    $source=Join-Path $repository ('scripts/windows/' + $(if ($manager -eq 'winsw') { 'Install-NodeService.ps1' } else { 'Install-PM2Fallback.ps1' }))
                    $ast=Get-InstallerAst $source
                    foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
                    function Start-ManagedServiceInstallerTransaction {
                        param($Config,$ExistingDeploymentLock,$ExistingManagedDeploymentTransaction)
                        Assert-InstallerTest ($global:installerTestEvents.Count -eq 0) 'Installer mutation preceded transaction ownership.'
                        Assert-InstallerTest (($null -eq $ExistingDeploymentLock) -eq $owned -and ($null -eq $ExistingManagedDeploymentTransaction) -eq $owned) 'Installer did not forward borrowed ownership.'
                        $global:installerTestEvents.Add('start-transaction')
                        return [pscustomobject]@{ Lock=$ExistingDeploymentLock;Transaction=$ExistingManagedDeploymentTransaction;OwnsLock=$owned;OwnsTransaction=$owned }
                    }
                    function Complete-ManagedServiceInstallerTransaction {
                        param($Config,$State,$Failure)
                        Assert-InstallerTest ($State.OwnsLock -eq $owned -and $State.OwnsTransaction -eq $owned) 'Installer lost the exact ownership state.'
                        Assert-InstallerTest (($null -ne $Failure) -eq $failHealth) 'Installer finalization lost the actual failure.'
                        if ($Failure) { Assert-InstallerTest ($Failure.Exception.Message -eq 'Injected final HTTP failure') 'Installer replaced the original failure.' }
                        if ($manager -eq 'pm2') {
                            Assert-InstallerTest ([string][Environment]::GetEnvironmentVariable('PM2_HOME','Process') -ceq [string]$previousHome) 'PM2 daemon home leaked into rollback finalization.'
                            Assert-InstallerTest ((Get-Location).Path -eq $previousLocation) 'PM2 installer did not restore its working directory.'
                        }
                        $global:installerTestEvents.Add('complete-transaction')
                    }
                    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); [pscustomobject]@{StartName='NT AUTHORITY\NetworkService'} }
                    function Get-Service { param($Name,$ErrorAction); [pscustomobject]@{Status='Stopped'} | Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)} -PassThru }
                    function Get-ServiceAccountSettings {param($Config,$ExistingDefinition); [pscustomobject]@{Account='NT AUTHORITY\NetworkService';PreserveExisting=$true;Password=''} }
                    function Assert-ServicePathCompatible {param($Name,$ExpectedWrapperPath)}
                    function Stop-ExistingService {param($Name,$WrapperPath);$global:installerTestEvents.Add('stop-existing');$true}
                    function Set-WindowsServiceFilesystemSecurity {param($Config,$Account);$global:installerTestEvents.Add('protect-files')}
                    function Set-WindowsProtectedFileSecurity {param($Path,$Account)}
                    function Set-WindowsProtectedPathSecurity {param($Path,$Account,$RuntimeRights,$OwnerAccount)}
                    function Set-ServiceAccount {param($Config,$Settings)}
                    function Invoke-NativeCommand {param($FilePath,$Arguments,$Action);$global:installerTestEvents.Add('native-command')}
                    function Test-PostStartListener {param($Config)}
                    function Get-WindowsServiceSecurityConfigString {param($Config,$Name,$Default);if($Config.PSObject.Properties[$Name] -and $Config.$Name){return [string]$Config.$Name};return $Default}
                    function Set-Pm2PrivateFilesystemSecurity {param($Config,$Account,$Pm2Home);$global:installerTestEvents.Add('protect-files')}
                    function Get-AppPackagePm2State {param($Name,$CommandName);[pscustomobject]@{Exists=$true;WasRunning=$true;ProcessIds=@(7)}}
                    function Invoke-CheckedPm2Command {param($CommandName,$Arguments,$Label);$global:installerTestEvents.Add('pm2-command')}
                    function Assert-WindowsPm2ExecutionAllowed {param($Pm2HomePath,$ExpectedOwnerSid)}
                    function Test-PostDeployHealth {param($Config);$global:installerTestEvents.Add('health');if($failHealth){throw 'Injected final HTTP failure'}}
                    $prefix=if($manager -eq 'winsw'){'if ($PSCmdlet.ShouldProcess($config.AppName, "Deploy WinSW service'}else{'if ($PSCmdlet.ShouldProcess($config.AppName, "Start PM2 process"))'}
                    $mutation=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith($prefix)},$true)
                    Assert-InstallerTest ($null -ne $mutation) 'Cannot locate the actual installer mutation block.'
                    $body=$mutation.Clauses[0].Item2.Extent.Text
                    $mutationBody=[scriptblock]::Create($body.Substring(1,$body.Length-2))
                    function Invoke-InstallerMutation { [CmdletBinding(SupportsShouldProcess=$true)] param($Body); . $Body }
                    $failure=$null
                    try { Invoke-InstallerMutation $mutationBody } catch { $failure=$_ }
                    Assert-InstallerTest (($null -ne $failure) -eq $failHealth) 'Installer success/failure outcome changed.'
                    if($failure){Assert-InstallerTest ($failure.Exception.Message -eq 'Injected final HTTP failure') "Unexpected installer failure: $($failure.Exception.Message)"}
                    Assert-InstallerTest ($global:installerTestEvents[0] -eq 'start-transaction' -and $global:installerTestEvents[$global:installerTestEvents.Count-1] -eq 'complete-transaction') 'Installer did not finalize the exact transaction around all mutations.'
                    Assert-InstallerTest ($global:installerTestEvents.Contains('health') -and $global:installerTestEvents.Contains('protect-files')) 'Actual mutation/health body was not exercised.'
                    Write-Host "Actual $manager installer lifecycle passed: owned=$owned, injectedHealthFailure=$failHealth"
                    if(-not $failHealth){
                        $global:installerTestEvents.Clear()
                        Invoke-InstallerMutation ([scriptblock]::Create($mutation.Extent.Text)) -WhatIf
                        Assert-InstallerTest ($global:installerTestEvents.Count -eq 0) 'Installer -WhatIf acquired/suspended a transaction or mutated host state.'
                    }
                } finally {
                    [Environment]::SetEnvironmentVariable('PM2_HOME',$previousHome,'Process')
                    Set-Location -LiteralPath $previousLocation
                    $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath((Join-Path $repository '.tmp'))+'\'
                    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing installer fixture cleanup outside repository .tmp.'}
                    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
                    Remove-Variable -Name installerTestEvents -Scope Global -ErrorAction SilentlyContinue
                }
            } $repoRoot $manager $owned $failHealth
        }
    }
}
Write-Host 'WinSW/PM2 actual installer mutation lifecycle and borrowed ownership regression OK (SCM/PM2 host calls mocked).'
