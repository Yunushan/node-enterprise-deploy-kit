param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$OnboardingPath = Join-Path $ScriptDir 'New-NextJsHostIntegrationRunnerOnboarding.ps1'

function Assert-Contains {
  param([string]$Text, [string]$Expected)
  if (-not $Text.Contains($Expected)) { throw "Runner onboarding generator is missing expected text: $Expected" }
}

function Assert-Throws {
  param([scriptblock]$Action, [string]$Expected)
  try {
    & $Action
  } catch {
    if ($_.Exception.Message.Contains($Expected)) { return }
    throw "Runner onboarding generator failed with an unexpected message: $($_.Exception.Message)"
  }
  throw "Runner onboarding generator succeeded unexpectedly; expected: $Expected"
}

Write-Host ''
Write-Host '==> Next.js native runner onboarding'
if (-not (Test-Path -LiteralPath $OnboardingPath -PathType Leaf)) {
  throw "Missing Next.js native runner onboarding generator: $OnboardingPath"
}
$onboarding = Get-Content -LiteralPath $OnboardingPath -Raw
foreach ($expected in @(
    'nextjs-native-runner-onboarding',
    'nextjs-manager-',
    'nextjs-proxy-',
    'registration token',
    '<issued-token>',
    '.\config.cmd --unattended',
    './config.sh --unattended',
    'sudo ./svc.sh install',
    'RepositoryUrl must be an https://github.com/owner/repository URL.',
    '--use-system-ca',
    'NODE_TLS_REJECT_UNAUTHORIZED=0',
    'NSSM_PATH',
    'Application Request Routing',
    'Test-NextJsHostIntegrationPrerequisites.mjs',
    'ServiceManager and ReverseProxy must be supplied together.',
    'local-command-only',
    'Next.js native runner onboarding self-test OK'
  )) {
  Assert-Contains -Text $onboarding -Expected $expected
}
if ($onboarding.Contains('Invoke-Expression')) {
  throw 'Runner onboarding generator must not use Invoke-Expression.'
}

& $OnboardingPath -SelfTest
$previewPath = Join-Path $RepoRoot ".tmp\nextjs-runner-onboarding-$([Guid]::NewGuid().ToString('N')).md"
& $OnboardingPath -TargetId ubuntu -ServiceManager systemd -ReverseProxy nginx -OutputPath $previewPath -Quiet
$preview = Get-Content -LiteralPath $previewPath -Raw
Assert-Contains -Text $preview -Expected 'nextjs-manager-systemd'
Assert-Contains -Text $preview -Expected 'nextjs-proxy-nginx'
Assert-Throws -Expected 'not declared for target' -Action {
  & $OnboardingPath -TargetId windows-server-2022 -ServiceManager systemd -ReverseProxy nginx -Quiet
}

Write-Host 'Next.js native runner onboarding OK'
