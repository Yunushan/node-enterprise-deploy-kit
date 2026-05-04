<#
.SYNOPSIS
  Run configured Windows app install/build commands before service deployment.
.DESCRIPTION
  Executes InstallCommand and BuildCommand from the local config inside the
  configured AppDirectory. Command output is allowed through for normal build
  troubleshooting, but this script does not print config Environment values.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $SkipInstall,
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not (Test-Path $config.AppDirectory)) {
    throw "AppDirectory not found: $($config.AppDirectory)"
}

function Invoke-ConfiguredCommand([string]$Command, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Host "$Label skipped; no command configured."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($config.AppName, $Label)) {
        return
    }

    Write-Host "$Label..." -ForegroundColor Cyan
    Push-Location $config.AppDirectory
    try {
        $commandProcessor = $env:ComSpec
        if ([string]::IsNullOrWhiteSpace($commandProcessor)) { $commandProcessor = "cmd.exe" }
        & $commandProcessor /d /s /c $Command
        if ($LASTEXITCODE -ne 0) {
            throw "$Label failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

if (-not $SkipInstall) {
    Invoke-ConfiguredCommand -Command ([string]$config.InstallCommand) -Label "InstallCommand"
}

if (-not $SkipBuild) {
    Invoke-ConfiguredCommand -Command ([string]$config.BuildCommand) -Label "BuildCommand"
}
