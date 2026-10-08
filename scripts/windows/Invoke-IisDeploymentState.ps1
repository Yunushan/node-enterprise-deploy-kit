[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Save', 'Restore')][string]$Action,
    [Parameter(Mandatory=$true)][string]$ConfigSnapshotPath, [Parameter(Mandatory=$true)][string]$StatePath,
    [Parameter(Mandatory=$true)][string]$IisDeploymentLockLeasePath, [Parameter(Mandatory=$true)][string]$IisDeploymentLockToken)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IisDeploymentState.ps1')
Assert-IisDeploymentLockLease $IisDeploymentLockLeasePath $IisDeploymentLockToken
Assert-DeploymentPathNotReparsePoint $ConfigSnapshotPath
Assert-DeploymentPathNotReparsePoint $StatePath
if ($Action -eq 'Save') {
    $config = Import-Clixml -LiteralPath $ConfigSnapshotPath
    Get-IisManagedDeploymentState $config | Export-Clixml -LiteralPath $StatePath -Depth 40
} else { Restore-IisManagedDeploymentState (Import-Clixml -LiteralPath $StatePath) }
