Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'Windows PM2 token tests require native Windows; skipped.'; return }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/windows/WindowsServiceSecurity.ps1')
. (Join-Path $repoRoot 'scripts/windows/AppPackageLifecycle.ps1')
. (Join-Path $repoRoot 'scripts/windows/DeploymentTransaction.ps1')
. (Join-Path $repoRoot 'scripts/windows/WindowsRuntimeStatus.ps1')
function Assert-Pm2PolicyTest([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Pm2PolicyRejected([scriptblock]$Action, [string]$Message, [string]$ExpectedError = '') {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-Pm2PolicyTest ($null -ne $failure) $Message
    if ($ExpectedError) { Assert-Pm2PolicyTest ($failure.Exception.Message.Contains($ExpectedError)) ("Unexpected rejection: " + $failure.Exception.Message) }
}
function Get-Pm2PolicySourceAst([string]$Path) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-Pm2PolicyTest ($errors.Count -eq 0) "Source does not parse: $Path"
    return $ast
}
$ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$actual=Get-WindowsNativeProcessToken -ProcessId $PID
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-Pm2PolicyTest ($actual.ProcessId -eq $PID -and $actual.OwnerSid -eq $ownerSid -and $actual.Elevated -is [bool]) 'Native caller token query returned invalid ownership/elevation.'
Assert-Pm2PolicyTest ($actual.Elevated -eq $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Native token elevation disagrees with the current Windows principal.'
Assert-Pm2PolicyRejected { Get-WindowsNativeProcessToken -ProcessId 2147483647 } 'A nonexistent native PID was accepted.'
Write-Host "Actual readonly Windows token verified: Elevated=$($actual.Elevated)"
$fixture=Join-Path $repoRoot ('.tmp/windows-pm2-policy-' + [guid]::NewGuid().ToString('N'))
$pm2TestHome=Join-Path $fixture 'home'; $daemonId=2147483000
New-Item -ItemType Directory -Path $pm2TestHome -Force | Out-Null
try {
    if ($actual.Elevated -or $actual.OwnerSid -eq 'S-1-5-18') { Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Native elevated caller was accepted.' }
    else { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome -ExpectedOwnerSid $ownerSid }
    & {
        param($pm2TestHome,$ownerSid,$daemonId)
        $callerToken=[pscustomobject]@{ OwnerSid=$ownerSid; Elevated=$false }
        $daemonToken=[pscustomobject]@{ OwnerSid=$ownerSid; Elevated=$false }
        $daemonReadFails=$false; $daemonReads=[Collections.Generic.List[int]]::new()
        function Get-WindowsNativeProcessToken {
            param($ProcessId)
            if ($ProcessId -eq $PID) { return $callerToken }
            $daemonReads.Add($ProcessId)
            if ($daemonReadFails) { throw 'Injected stale/inaccessible token.' }
            Assert-Pm2PolicyTest ($ProcessId -eq $daemonId) 'Policy queried a different daemon PID.'
            return $daemonToken
        }
        $pidPath=Join-Path $pm2TestHome 'pm2.pid'
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome -ExpectedOwnerSid $ownerSid
        foreach ($badCaller in @([pscustomobject]@{OwnerSid=$ownerSid;Elevated=$true},[pscustomobject]@{OwnerSid='S-1-5-18';Elevated=$false},[pscustomobject]@{OwnerSid='S-1-5-20';Elevated=$false},[pscustomobject]@{OwnerSid=$ownerSid;Elevated='unknown'})) {
            $callerToken=$badCaller
            Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome -ExpectedOwnerSid $ownerSid } 'Privileged, different-owner or unknown caller token was accepted.'
        }
        $callerToken=[pscustomobject]@{ OwnerSid=$ownerSid; Elevated=$false }
        Assert-Pm2PolicyTest ($daemonReads.Count -eq 0) 'Rejected caller still queried a daemon.'
        [IO.File]::WriteAllText($pidPath,[string]$daemonId)
        Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome -ExpectedOwnerSid $ownerSid
        Assert-Pm2PolicyTest ($daemonReads.Count -eq 1) 'Existing daemon token was not queried.'
        $heldPidFile=[IO.File]::Open($pidPath,'Open','ReadWrite','None')
        try { Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Unreadable PID file was accepted.' }
        finally { $heldPidFile.Dispose() }
        foreach ($badDaemon in @([pscustomobject]@{OwnerSid=$ownerSid;Elevated=$true},[pscustomobject]@{OwnerSid='S-1-5-18';Elevated=$false},[pscustomobject]@{OwnerSid='S-1-5-20';Elevated=$false},[pscustomobject]@{OwnerSid=$ownerSid;Elevated='unknown'})) {
            $daemonToken=$badDaemon
            Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome -ExpectedOwnerSid $ownerSid } 'Privileged, different-owner or unknown daemon token was accepted.'
        }
        $daemonReadFails=$true
        Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Stale/inaccessible daemon PID was accepted.'
        $daemonReadFails=$false
        foreach ($badPid in @('0','-1','not-a-pid','2147483648',('1' * 65))) {
            [IO.File]::WriteAllText($pidPath,$badPid)
            Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Malformed daemon PID was accepted.'
        }
        Remove-Item -LiteralPath $pidPath -Force
        New-Item -ItemType Directory -Path $pidPath | Out-Null
        Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Directory daemon PID file was accepted.'
        Remove-Item -LiteralPath $pidPath -Force
        foreach ($badHome in @('relative','.','C:\','C:\pm2:stream','C:\pm2*')) { Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $badHome } 'Unsafe PM2_HOME was accepted.' }
        & {
            param($pm2TestHome)
            function Get-Item { [CmdletBinding()] param($LiteralPath,[switch]$Force); if ($LiteralPath -eq $pm2TestHome) { throw [UnauthorizedAccessException]::new('Injected unreadable control directory') }; Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force }
            Assert-Pm2PolicyRejected { Assert-WindowsPm2ExecutionAllowed -Pm2HomePath $pm2TestHome } 'Unreadable control directory was treated as a missing daemon.'
        } $pm2TestHome
    } $pm2TestHome $ownerSid $daemonId
    & {
        param($repoRoot,$fixture,$pm2TestHome,$ownerSid)
        foreach ($source in @('Install-PM2Fallback.ps1','Invoke-NodeHealthCheck.ps1')) {
            $ast=Get-Pm2PolicySourceAst (Join-Path $repoRoot "scripts/windows/$source")
            foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Invoke-CheckedPm2Command','Invoke-Pm2HealthCommand')},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Assert-WindowsPm2ExecutionAllowed { param($Pm2HomePath,$ExpectedOwnerSid); throw 'policy-block-before-command' }
        $marker=Join-Path $fixture 'unexpected-command.txt'
        $command=Join-Path $fixture 'fake-pm2.ps1'
        [IO.File]::WriteAllText($command, 'param([Parameter(ValueFromRemainingArguments=$true)]$Rest); [IO.File]::WriteAllText($env:PM2_POLICY_TEST_MARKER,"executed"); $global:LASTEXITCODE=0')
        $beforeMarker=[Environment]::GetEnvironmentVariable('PM2_POLICY_TEST_MARKER','Process')
        try {
            $env:PM2_POLICY_TEST_MARKER=$marker
            $config=[pscustomobject]@{ AppName='fixture'; PM2Home=$pm2TestHome; PM2Command=$command; PM2OwnerSid=$ownerSid }
            $state=[pscustomobject]@{Kind='pm2';Exists=$true;WasRunning=$true;Name='fixture';Home=$pm2TestHome;CommandName=$command}
            function Get-WindowsPm2RuntimeContext {param($Config); [pscustomobject]@{Home=$pm2TestHome;CommandName=$command}}
            foreach ($action in @(
                { Get-AppPackagePm2State -Name fixture -CommandName $command -Pm2HomePath $pm2TestHome },
                { Stop-AppPackageService $state }, { Start-AppPackageServiceAfterFailure $state }, { Remove-NewAppPackageServiceAfterFailure $state },
                { Invoke-ManagedPm2Command -CommandName $command -Arguments @('jlist') -Pm2HomePath $pm2TestHome },
                { Invoke-CheckedPm2Command -CommandName $command -Arguments @('jlist') -Label fixture },
                { Invoke-Pm2HealthCommand @('jlist') }, { Get-WindowsPm2RuntimeEvidence $config }
            )) { Assert-Pm2PolicyRejected $action 'A command path bypassed policy rejection.' 'policy-block-before-command' }
            Assert-Pm2PolicyTest (-not (Test-Path -LiteralPath $marker)) 'Policy rejection executed a CLI, which could start a daemon.'
            # Rendering the monitor's pinned context must remain usable without
            # executing the CLI or requiring an administrative deployment.
            $renderConfig=Join-Path $fixture 'render.json'
            $config | Add-Member NoteProperty ServiceManager 'pm2'
            $config | Add-Member NoteProperty ServiceDirectory (Join-Path $fixture 'service')
            $config | Add-Member NoteProperty LogDirectory (Join-Path $fixture 'logs')
            $config | Add-Member NoteProperty HealthUrl 'http://127.0.0.1:3000/health'
            $config | Add-Member NoteProperty DeploymentLockDirectory (Join-Path $fixture 'locks')
            $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $renderConfig -Encoding UTF8
            $rendered=& (Join-Path $repoRoot 'scripts/windows/Register-HealthCheckTask.ps1') -ConfigPath $renderConfig -RenderMonitorConfigOnly | ConvertFrom-Json
            Assert-Pm2PolicyTest ($rendered.PM2Home -eq $pm2TestHome -and $rendered.PM2Command -eq $command -and -not (Test-Path -LiteralPath $marker)) 'Monitor rendering executed PM2 or lost its pinned owner context.'
            # Execute the installer's actual mutation body: policy must reject
            # before even starting a host transaction or modifying its files.
            $ast=Get-Pm2PolicySourceAst (Join-Path $repoRoot 'scripts/windows/Install-PM2Fallback.ps1')
            $mutation=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($PSCmdlet.ShouldProcess($config.AppName, "Start PM2 process"))')},$true)
            $body=$mutation.Clauses[0].Item2.Extent.Text
            $pm2Home=$pm2TestHome; $ExistingDeploymentLock=$ExistingManagedDeploymentTransaction=$null
            function Start-ManagedServiceInstallerTransaction {throw 'Unexpected transaction mutation'}
            Assert-Pm2PolicyRejected ([scriptblock]::Create($body.Substring(1,$body.Length-2))) 'Installer mutated host state before policy.' 'policy-block-before-command'
        } finally { [Environment]::SetEnvironmentVariable('PM2_POLICY_TEST_MARKER',$beforeMarker,'Process') }
    } $repoRoot $fixture $pm2TestHome $ownerSid
    Write-Host 'Windows PM2 caller/daemon token policy and actual command rejection paths OK; no PM2 daemon was started.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture); $parent=[IO.Path]::GetFullPath((Join-Path $repoRoot '.tmp')).TrimEnd('\','/')
    if ((Split-Path -Parent $resolved).TrimEnd('\','/') -ne $parent -or (Split-Path -Leaf $resolved) -notmatch '^windows-pm2-policy-[a-f0-9]{32}$') { throw 'Unsafe PM2 token fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
