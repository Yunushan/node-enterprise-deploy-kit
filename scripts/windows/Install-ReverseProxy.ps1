<#
.SYNOPSIS
  Install the Windows reverse proxy selected by config/windows/app.config.json.
.DESCRIPTION
  Dispatches ReverseProxy=iis to the IIS installer and skips cleanly for
  ReverseProxy=none. Linux/Unix proxy installers are intentionally not routed
  through the Windows deployment flow.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $DryRun,
    [string]$IisDeploymentLockLeasePath = '', [string]$IisDeploymentLockToken = '',
    [object]$ExistingDeploymentLock
)

$ErrorActionPreference = "Stop"

function Get-ConfigString($Config, [string]$Name, [string]$Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $ConfigPath))
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')
Assert-WindowsDeploymentConfigIdentity -Config $config
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$deploymentMode = Normalize-Name (Get-ConfigString $config "DeploymentMode" "")
$installerArguments = @{ ConfigPath = $ConfigPath }
if ($ExistingDeploymentLock) { $installerArguments.ExistingDeploymentLock = $ExistingDeploymentLock }
if ($IisDeploymentLockLeasePath -or $IisDeploymentLockToken) {
    $installerArguments.IisDeploymentLockLeasePath = $IisDeploymentLockLeasePath
    $installerArguments.IisDeploymentLockToken = $IisDeploymentLockToken
}
if ($WhatIfPreference) { $installerArguments.WhatIf = $true }
if ($PSBoundParameters.ContainsKey('Confirm')) { $installerArguments.Confirm = [bool]$PSBoundParameters['Confirm'] }
if ($deploymentMode -eq "static-iis") {
    $installer = Join-Path $repoRoot "scripts\windows\Install-IISStaticSite.ps1"
    if ($DryRun) {
        Write-Output "Would install IIS static site with: powershell -ExecutionPolicy Bypass -File `"$installer`" -ConfigPath `"$ConfigPath`""
        return
    }
    if ($PSCmdlet.ShouldProcess("IIS static site", "Run Install-IISStaticSite.ps1")) {
        & $installer @installerArguments
    }
    return
}
$reverseProxy = (Get-ConfigString $config "ReverseProxy" "none").Trim().ToLowerInvariant()

switch ($reverseProxy) {
    "iis" {
        $installer = Join-Path $repoRoot "scripts\windows\Install-IISReverseProxy.ps1"
        if ($DryRun) {
            Write-Output "Would install IIS reverse proxy with: powershell -ExecutionPolicy Bypass -File `"$installer`" -ConfigPath `"$ConfigPath`""
            return
        }
        if ($PSCmdlet.ShouldProcess("IIS reverse proxy", "Run Install-IISReverseProxy.ps1")) {
            & $installer @installerArguments
        }
    }
    "none" {
        Write-Output "ReverseProxy=none; skipping Windows reverse proxy install."
    }
    "" {
        Write-Output "ReverseProxy is empty; skipping Windows reverse proxy install."
    }
    default {
        throw "Unsupported Windows ReverseProxy: $($config.ReverseProxy). Use iis or none. Apache, HAProxy, and Traefik installers are Linux/Unix scripts in this kit."
    }
}
