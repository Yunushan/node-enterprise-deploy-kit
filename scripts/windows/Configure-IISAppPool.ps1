<#
.SYNOPSIS
  Apply enterprise-friendly IIS application pool defaults for reverse proxy sites.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $AppPoolName = "NodeReverseProxyAppPool"
)
Import-Module WebAdministration -ErrorAction Stop
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    New-WebAppPool -Name $AppPoolName | Out-Null
}
if ($PSCmdlet.ShouldProcess($AppPoolName, "Configure IIS app pool")) {
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode -Value AlwaysRunning
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name recycling.periodicRestart.time -Value ([TimeSpan]::FromMinutes(0))
}
Write-Host "Configured IIS App Pool: $AppPoolName" -ForegroundColor Green
