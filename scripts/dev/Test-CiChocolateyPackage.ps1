Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'Install-CiChocolateyPackage.ps1'
function Assert-CiPackage([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
foreach ($case in @(
    @{ Codes=@(0); Attempts=3; Calls=1; Delays=@(); Fails=$false },
    @{ Codes=@(1,1,0); Attempts=3; Calls=3; Delays=@(10,20); Fails=$false },
    @{ Codes=@(1,1,1); Attempts=3; Calls=3; Delays=@(10,20); Fails=$true },
    @{ Codes=@(1); Attempts=1; Calls=1; Delays=@(); Fails=$true }
)) {
    & {
        param($case, $installer)
        $installCalls = [Collections.Generic.List[object]]::new()
        $installDelays = [Collections.Generic.List[int]]::new()
        function choco {
            $installCalls.Add(@($args))
            $global:LASTEXITCODE = $case.Codes[$installCalls.Count - 1]
        }
        function Start-Sleep { param([int]$Seconds) $installDelays.Add($Seconds) }
        $caught=$null
        try { & $installer -Name iis-arr -Version 3.0.20210521 -Attempts $case.Attempts } catch { $caught=$_ }
        Assert-CiPackage (($null -ne $caught) -eq $case.Fails) "Package failure was swallowed or a successful retry threw: $caught"
        if ($caught) { Assert-CiPackage ($caught.Exception.Message -like '*iis-arr 3.0.20210521*exit code 1*') 'Final dependency failure lost package/version/exit-code context.' }
        Assert-CiPackage ($installCalls.Count -eq $case.Calls) 'Unexpected retry attempt count.'
        Assert-CiPackage (($installDelays -join ',') -eq ($case.Delays -join ',')) 'Retry delay was missing or unbounded.'
        foreach ($call in $installCalls) {
            Assert-CiPackage (($call -join '|') -eq 'install|iis-arr|--version=3.0.20210521|--yes|--no-progress') 'Retry changed the reviewed package version or arguments.'
        }
    } $case $installer
}
$global:LASTEXITCODE=0
Write-Host 'Chocolatey dependency retries, pinned arguments, first-attempt success and final failure propagation passed.'
