<#
.SYNOPSIS
  Restart the configured Windows service and run a safe status check.
.EXAMPLE
  .\restart.ps1 -ConfigPath .\config\windows\app.config.json
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = ".\config\windows\app.config.json",
    [switch] $SkipStatus
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Host "Restarting service: $($config.AppName)" -ForegroundColor Cyan
Restart-Service -Name $config.AppName -Force -ErrorAction Stop
Start-Sleep -Seconds 5

if (-not $SkipStatus) {
    & (Join-Path $repoRoot "status.ps1") -ConfigPath $ConfigPath
}
