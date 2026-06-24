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
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"

function Get-ConfigString($Config, [string]$Name, [string]$Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $ConfigPath))
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$reverseProxy = (Get-ConfigString $config "ReverseProxy" "none").Trim().ToLowerInvariant()

switch ($reverseProxy) {
    "iis" {
        $installer = Join-Path $repoRoot "scripts\windows\Install-IISReverseProxy.ps1"
        if ($DryRun) {
            Write-Output "Would install IIS reverse proxy with: powershell -ExecutionPolicy Bypass -File `"$installer`" -ConfigPath `"$ConfigPath`""
            return
        }
        if ($PSCmdlet.ShouldProcess("IIS reverse proxy", "Run Install-IISReverseProxy.ps1")) {
            & $installer -ConfigPath $ConfigPath
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
