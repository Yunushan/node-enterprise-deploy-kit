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

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath. Copy config/windows/app.config.example.json first."
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

switch ($config.ServiceManager) {
    "winsw" { & (Join-Path $repoRoot "scripts\windows\Install-NodeService.ps1") -ConfigPath $ConfigPath }
    "nssm"  { & (Join-Path $repoRoot "scripts\windows\Install-NSSMService.ps1") -ConfigPath $ConfigPath }
    "pm2"   { & (Join-Path $repoRoot "scripts\windows\Install-PM2Fallback.ps1") -ConfigPath $ConfigPath }
    default  { throw "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2." }
}

if (-not $SkipReverseProxy -and $config.ReverseProxy -eq "iis") {
    & (Join-Path $repoRoot "scripts\windows\Install-IISReverseProxy.ps1") -ConfigPath $ConfigPath
}

if (-not $SkipHealthCheck) {
    & (Join-Path $repoRoot "scripts\windows\Register-HealthCheckTask.ps1") -ConfigPath $ConfigPath
}

Write-Host "Deployment finished for $($config.AppName)." -ForegroundColor Green
