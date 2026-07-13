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

function Get-PreparationEnvironment {
    $environment = @{}
    if (-not $config.PSObject.Properties["PreparationEnvironment"] -or $null -eq $config.PreparationEnvironment) {
        return $environment
    }

    foreach ($property in @($config.PreparationEnvironment.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "PreparationEnvironment contains an invalid environment variable name."
        }

        if ($null -eq $property.Value) {
            throw "PreparationEnvironment value is missing for '$name'."
        }

        $environment[$name] = [string]$property.Value
    }

    return $environment
}

function Invoke-WithPreparationEnvironment {
    param(
        [hashtable]$Environment,
        [scriptblock]$ScriptBlock
    )

    $previousValues = @{}
    try {
        foreach ($name in $Environment.Keys) {
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], "Process")
        }
        & $ScriptBlock
    }
    finally {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name], "Process")
        }
    }
}

$preparationEnvironment = Get-PreparationEnvironment

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
        Invoke-WithPreparationEnvironment -Environment $preparationEnvironment -ScriptBlock {
            & $commandProcessor /d /s /c $Command
        }
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
