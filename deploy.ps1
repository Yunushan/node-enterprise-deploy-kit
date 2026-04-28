<#
.SYNOPSIS
  Windows one-command deployment wrapper.
.EXAMPLE
  .\deploy.ps1 -ConfigPath .\config\windows\app.config.json
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [switch] $SkipReverseProxy,
    [switch] $SkipHealthCheck
)

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy config/windows/app.config.example.json first."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

switch ($config.ServiceManager) {
    "winsw" { .\scripts\windows\Install-NodeService.ps1 -ConfigPath $ConfigPath }
    "nssm"  { .\scripts\windows\Install-NSSMService.ps1 -ConfigPath $ConfigPath }
    "pm2"   { .\scripts\windows\Install-PM2Fallback.ps1 -ConfigPath $ConfigPath }
    default  { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
}

if (-not $SkipReverseProxy -and $config.ReverseProxy -eq "iis") {
    .\scripts\windows\Install-IISReverseProxy.ps1 -ConfigPath $ConfigPath
}

if (-not $SkipHealthCheck) {
    .\scripts\windows\Register-HealthCheckTask.ps1 -ConfigPath $ConfigPath
}

Write-Host "Deployment finished for $($config.AppName)." -ForegroundColor Green
