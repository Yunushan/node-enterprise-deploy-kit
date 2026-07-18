param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\nextjs-host-integration.yml'
$InputValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationWorkflowInputs.ps1'
$ResultValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationResult.mjs'
$PrerequisiteValidatorPath = Join-Path $ScriptDir 'Test-NextJsHostIntegrationPrerequisites.mjs'

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Context)
  if (-not $Text.Contains($Expected)) {
    throw "$Context is missing expected text: $Expected"
  }
}

function Assert-DoesNotContain {
  param([string]$Text, [string]$Unexpected, [string]$Context)
  if ($Text.Contains($Unexpected)) {
    throw "$Context contains unexpected text: $Unexpected"
  }
}

Write-Host ''
Write-Host '==> Next.js self-hosted integration workflow'

foreach ($path in @($WorkflowPath, $InputValidatorPath, $ResultValidatorPath, $PrerequisiteValidatorPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing Next.js self-hosted integration workflow artifact: $path"
  }
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$inputValidator = Get-Content -LiteralPath $InputValidatorPath -Raw
$resultValidator = Get-Content -LiteralPath $ResultValidatorPath -Raw
$prerequisiteValidator = Get-Content -LiteralPath $PrerequisiteValidatorPath -Raw

& $InputValidatorPath -SelfTest

foreach ($expected in @(
    'workflow_dispatch:',
    'concurrency:',
    'group: nextjs-host-integration-${{ inputs.expected_target_id }}-${{ inputs.expected_service_manager }}-${{ inputs.expected_reverse_proxy }}',
    'cancel-in-progress: false',
    'runner_labels:',
    'expected_target_id:',
    'expected_service_manager:',
    'expected_reverse_proxy:',
    'validate-dispatch:',
    'Require the protected default branch',
    'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}',
    'SOURCE_REF: ${{ github.ref }}',
    'Self-hosted Next.js integration can run only from the protected default branch',
    'Validate self-hosted target and service combination',
    'Test-NextJsHostIntegrationWorkflowInputs.ps1',
    'runs-on: ${{ fromJSON(inputs.runner_labels) }}',
    'Checkout clean repository workspace',
    'clean: true',
    'actions/setup-node@v6',
    "node-version: '22'",
    'Validate Windows native integration prerequisites',
    'Validate Unix native integration prerequisites',
    'Test-NextJsHostIntegrationPrerequisites.mjs',
    '--platform "$PLATFORM"',
    '--manager "$EXPECTED_SERVICE_MANAGER"',
    '--proxy "$EXPECTED_REVERSE_PROXY"',
    'The self-hosted Windows runner must run as an administrator',
    'RUN_WINSW_SERVICE_INTEGRATION',
    'RUN_NSSM_SERVICE_INTEGRATION',
    'RUN_WINDOWS_IIS_INTEGRATION',
    'sudo -n true',
    'RUN_SYSTEMD_SERVICE_INTEGRATION=true',
    'RUN_SYSTEMV_SERVICE_INTEGRATION=true',
    'RUN_OPENRC_SERVICE_INTEGRATION=true',
    'RUN_LAUNCHD_SERVICE_INTEGRATION=true',
    'RUN_NGINX_PROXY_INTEGRATION=true',
    'RUN_APACHE_PROXY_INTEGRATION=true',
    'RUN_HAPROXY_INTEGRATION=true',
    'RUN_TRAEFIK_PROXY_INTEGRATION=true',
    "NEXTJS_INTEGRATION_EXECUTION='native'",
    "NEXTJS_INTEGRATION_RUNNER_ENVIRONMENT='self-hosted'",
    'NEXTJS_INTEGRATION_TARGET="$EXPECTED_TARGET_ID"',
    'Validate safe Windows integration result when present',
    'Validate safe Unix integration result when present',
    '--sha $env:GITHUB_SHA',
    '--workflow $env:GITHUB_WORKFLOW',
    '--job collect',
    '--run-id $env:GITHUB_RUN_ID',
    '--run-attempt $env:GITHUB_RUN_ATTEMPT',
    '--sha "$GITHUB_SHA"',
    '--workflow "$GITHUB_WORKFLOW"',
    '--run-id "$GITHUB_RUN_ID"',
    '--run-attempt "$GITHUB_RUN_ATTEMPT"',
    'actions/upload-artifact@v7',
    'actions/download-artifact@v8',
    'Test-NextJsHostIntegrationResult.mjs',
    '--target',
    '--manager',
    '--proxy'
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context '.github/workflows/nextjs-host-integration.yml'
}

foreach ($expected in @(
    'expected_target_id, expected_service_manager, and expected_reverse_proxy are required',
    'expected_service_manager must be one of winsw, nssm, systemd, systemv, openrc, or launchd.',
    'expected_reverse_proxy must be one of iis, nginx, apache, haproxy, traefik, or none.',
    'must match expected support dimensions',
    'runner_labels must include self-hosted for real Next.js host integration.',
    'runner_labels must include the expected target label',
    'runner_labels must include the required capability label',
    'nextjs-manager-',
    'nextjs-proxy-',
    'runner_labels must not use GitHub-hosted runner labels',
    'runner_labels must not include support target labels other than expected_target_id',
    'local-command-only and cannot use the self-hosted Next.js integration workflow',
    'must declare standalone and next-start Next.js modes for self-hosted integration',
    'matrix_path must reference a tracked repository file'
  )) {
  Assert-Contains -Text $inputValidator -Expected $expected -Context 'Test-NextJsHostIntegrationWorkflowInputs.ps1'
}

foreach ($expected in @(
    'validateHostIntegrationResult',
    'Self-hosted integration result must have passed.',
    'Self-hosted integration result must use native execution.',
    'Self-hosted integration result must retain self-hosted runner provenance.',
    'does not match the dispatch target',
    'does not match the dispatch manager',
    'does not match the dispatch proxy',
    'platform.identity',
    'commit SHA does not match the assessed commit',
    'workflow does not match the collecting workflow',
    'job does not match the collecting job',
    'run ID does not match the collecting workflow run',
    'run attempt does not match the collecting workflow attempt',
    'Windows Server result identity',
    'mismatched platform identity',
    "'win32'",
    "'darwin'",
    "'linux'",
    'isMainModule',
    'pathToFileURL',
    '--self-test'
  )) {
  Assert-Contains -Text $resultValidator -Expected $expected -Context 'Test-NextJsHostIntegrationResult.mjs'
}

foreach ($expected in @(
    'verifyPrerequisites',
    'Node.js ${process.version} is below the required 20.9.0 runtime floor.',
    'passwordless sudo',
    'systemctl',
    'rc-service',
    'rc-update',
    'launchctl',
    'NSSM_PATH',
    'Current Windows runner process is not elevated.',
    'Windows Administrator token',
    'IIS WebAdministration',
    'RewriteModule',
    'ApplicationRequestRouting',
    'URL Rewrite and Application Request Routing',
    'Next.js host integration prerequisite validator OK',
    'isMainModule',
    'pathToFileURL'
  )) {
  Assert-Contains -Text $prerequisiteValidator -Expected $expected -Context 'Test-NextJsHostIntegrationPrerequisites.mjs'
}

foreach ($unexpected in @('push:', 'pull_request:', 'schedule:', 'clean: false')) {
  Assert-DoesNotContain -Text $workflow -Unexpected $unexpected -Context '.github/workflows/nextjs-host-integration.yml'
}

$windowsAdministratorIndex = $workflow.IndexOf('Verify Windows administrator context')
$windowsPrerequisiteIndex = $workflow.IndexOf('Validate Windows native integration prerequisites')
if ($windowsAdministratorIndex -lt 0 -or $windowsPrerequisiteIndex -lt 0 -or $windowsPrerequisiteIndex -lt $windowsAdministratorIndex) {
  throw 'Windows native integration prerequisites must run after the Windows administrator context check.'
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node is required to validate the Next.js self-hosted integration workflow.' }
& $node.Source --check $ResultValidatorPath
if ($LASTEXITCODE -ne 0) { throw 'Next.js host integration result validator syntax check failed.' }
& $node.Source $ResultValidatorPath --self-test
if ($LASTEXITCODE -ne 0) { throw 'Next.js host integration result validator self-test failed.' }
& $node.Source --check $PrerequisiteValidatorPath
if ($LASTEXITCODE -ne 0) { throw 'Next.js host integration prerequisite validator syntax check failed.' }
& $node.Source $PrerequisiteValidatorPath --self-test
if ($LASTEXITCODE -ne 0) { throw 'Next.js host integration prerequisite validator self-test failed.' }

Write-Host 'Next.js self-hosted integration workflow OK'
