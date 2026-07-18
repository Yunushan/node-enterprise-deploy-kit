param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$InventoryPath = Join-Path $ScriptDir 'Get-NextJsHostIntegrationRunnerInventory.ps1'

function Assert-Contains {
  param([string]$Text, [string]$Expected)
  if (-not $Text.Contains($Expected)) { throw "Runner inventory checker is missing expected text: $Expected" }
}

Write-Host ''
Write-Host '==> Next.js self-hosted runner inventory'

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
  throw "Missing Next.js self-hosted runner inventory checker: $InventoryPath"
}
$inventory = Get-Content -LiteralPath $InventoryPath -Raw
foreach ($expected in @(
    'actions/runners?per_page=100',
    'Get-RedactedRunnerRecords',
    'sensitive-host-name',
    'readyForDispatch',
    'FailOnMissing',
    'FailOnNotReady',
    'DispatchJson',
    'New-DispatchInventory',
    'nextjs-manager-',
    'nextjs-proxy-',
    'online, idle compatible runner',
    'RequestedTargetIds',
    'Unknown support matrix target id(s)',
    'target filter',
    'omitted target filter',
    'Next.js self-hosted runner inventory self-test OK'
  )) {
  Assert-Contains -Text $inventory -Expected $expected
}
if ($inventory.Contains('Invoke-Expression')) {
  throw 'Runner inventory checker must not use Invoke-Expression.'
}

& $InventoryPath -SelfTest
Write-Host 'Next.js self-hosted runner inventory OK'
