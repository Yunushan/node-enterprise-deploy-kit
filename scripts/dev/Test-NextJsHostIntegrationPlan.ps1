param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$PlannerPath = Join-Path $ScriptDir 'New-NextJsHostIntegrationPlan.ps1'
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\nextjs-host-integration.yml'
$InputValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationWorkflowInputs.ps1'

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Context)
  if (-not $Text.Contains($Expected)) { throw "$Context is missing expected text: $Expected" }
}

Write-Host ''
Write-Host '==> Next.js self-hosted integration plan'

foreach ($path in @($PlannerPath, $WorkflowPath, $InputValidatorPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing Next.js self-hosted integration plan artifact: $path"
  }
}

$planner = Get-Content -LiteralPath $PlannerPath -Raw
foreach ($expected in @(
    'nextjs-self-hosted-integration-plan',
    'nextjs-host-integration.yml',
    'requiredModes = @(''standalone'', ''next-start'')',
    'nextjs-manager-',
    'nextjs-proxy-',
    'windows-client',
    'windows-server',
    'localCommandOnlyTargets',
    'unsupported workflow category',
    'unavailable to the self-hosted workflow',
    'workflowTargetCount',
    'Test-NextJsHostIntegrationWorkflowInputs.ps1',
    'foreach ($entry in @($plan.dispatches))',
    'fallback manager was emitted',
    'BSD dispatch was emitted',
    'DispatchPowerShell',
    '& gh @arguments',
    'Assert-WorkflowSourceReadiness',
    'Refusing native dispatch from a dirty worktree. Commit the verified workflow changes first.',
    'Native dispatch must run from the protected branch',
    'origin/$WorkflowRef does not contain the local verified commit. Push it before native dispatch.',
    'git -C $RepositoryRoot ls-remote --heads origin',
    'Get-NextJsHostIntegrationRunnerInventory.ps1',
    '-DispatchJson $dispatchJson -FailOnNotReady -Quiet',
    'Self-hosted runner readiness check failed.',
    'Review runner labels, then rerun with -Run from the repository root to verify runner readiness and dispatch workflows.'
  )) {
  Assert-Contains -Text $planner -Expected $expected -Context 'New-NextJsHostIntegrationPlan.ps1'
}
if ($planner.Contains('Invoke-Expression')) {
  throw 'New-NextJsHostIntegrationPlan.ps1 must not use Invoke-Expression to dispatch workflows.'
}

& $PlannerPath -SelfTest -Quiet

$previewPath = Join-Path $RepoRoot ".tmp\nextjs-host-integration-plan-$([Guid]::NewGuid().ToString('N')).ps1"
& $PlannerPath -TargetId windows-server-2022,ubuntu,macos -Format DispatchPowerShell -OutputPath $previewPath -Quiet
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($previewPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
  $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
  throw "Next.js host integration plan preview has PowerShell parse errors: $messages"
}
$preview = Get-Content -LiteralPath $previewPath -Raw
foreach ($expected in @('windows-server-2022', 'ubuntu', 'macos', 'nextjs-manager-winsw', 'nextjs-proxy-iis', 'nextjs-host-integration.yml', '& gh @arguments', 'Assert-WorkflowSourceReadiness', 'git -C $RepositoryRoot ls-remote --heads origin', 'Get-NextJsHostIntegrationRunnerInventory.ps1', '-DispatchJson', '-FailOnNotReady')) {
  Assert-Contains -Text $preview -Expected $expected -Context 'generated Next.js host integration dispatch preview'
}

Write-Host 'Next.js self-hosted integration plan OK'
