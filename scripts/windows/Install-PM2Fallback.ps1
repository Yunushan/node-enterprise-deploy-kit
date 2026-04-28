<#
.SYNOPSIS
  Optional PM2 fallback installer. WinSW is recommended for Windows production.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
Set-Location $config.AppDirectory
Write-Warning "PM2 fallback selected. For Windows enterprise production, WinSW is recommended."
if ($PSCmdlet.ShouldProcess($config.AppName, "Start PM2 process")) {
    pm2 delete $config.AppName 2>$null
    pm2 start $config.NodeExe --name $config.AppName --time --max-memory-restart 1024M -- $config.StartCommand $config.NodeArguments
    pm2 save
}
