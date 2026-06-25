param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$WorkflowPath = Join-Path $RepoRoot ".github\workflows\host-evidence.yml"

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Expected,
    [string]$Context
  )

  if (-not $Text.Contains($Expected)) {
    throw "$Context is missing expected text: $Expected"
  }
}

function Assert-DoesNotContain {
  param(
    [string]$Text,
    [string]$Unexpected,
    [string]$Context
  )

  if ($Text.Contains($Unexpected)) {
    throw "$Context contains unexpected text: $Unexpected"
  }
}

Write-Host ""
Write-Host "==> Host evidence workflow"

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Missing host evidence workflow: .github/workflows/host-evidence.yml"
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw

foreach ($expected in @(
    "workflow_dispatch:",
    "runner_labels:",
    "expected_target_id:",
    "expected_nextjs_mode:",
    "expected_service_manager:",
    "expected_reverse_proxy:",
    "expected_nextjs_mode must be standalone or next-start.",
    "expected_service_manager must be one of winsw, nssm, pm2, systemd, systemv, openrc, launchd, or bsdrc.",
    "expected_reverse_proxy must be one of iis, nginx, apache, haproxy, traefik, or none.",
    "expected_target_id, expected_nextjs_mode, expected_service_manager, and expected_reverse_proxy are required for real host evidence collection.",
    "config/support-matrix.example.json",
    '$expectedTarget = $env:EXPECTED_TARGET_ID.Trim().ToLowerInvariant()',
    "expected_target_id must match a support matrix target id.",
    "is not declared for support matrix target",
    "platform must be",
    "validate-dispatch:",
    "Validate self-hosted runner labels",
    "needs: validate-dispatch",
    "runs-on: `${{ fromJSON(inputs.runner_labels) }}",
    "actions/checkout@v7",
    "Checkout repository without deleting local private config",
    "clean: false",
    "actions/upload-artifact@v7",
    "actions/download-artifact@v8",
    "status.ps1",
    "scripts/linux/status-node-app.sh",
    "sudo env",
    "GITHUB_RUN_ID=",
    "GITHUB_SHA=",
    "scripts/dev/Test-HostEvidence.ps1",
    "-RequireNextJs",
    "-RequireDeploymentIdentity",
    "-RequireCollectorSha256",
    "-RequireMinimumUptimeHours",
    "-RequireReverseProxy",
    "-ExpectedTargetId",
    "-ExpectedNextJsMode",
    "-ExpectedServiceManager",
    "-ExpectedReverseProxy",
    "-AllowReverseProxyNone",
    "runner_labels must be a JSON array containing self-hosted and the expected target label.",
    "runner_labels must include self-hosted for real host evidence collection.",
    "runner_labels must include the expected target label",
    "runner_labels must not use GitHub-hosted runner labels for real host evidence.",
    "config_path is required and must be a relative path inside the repository workspace.",
    "config_path must not contain parent traversal, empty path segments, or a trailing slash.",
    "config_path was not found on the self-hosted runner workspace.",
    "evidence_name must contain only letters, numbers, dot, underscore, or dash.",
    "minimum_uptime_hours must be a non-negative integer.",
    "minimum_uptime_hours must be greater than or equal to support matrix requiredMinimumUptimeHours.",
    "support matrix requiredMinimumUptimeHours must be a positive integer.",
    "upload_retention_days must be an integer from 1 to 90.",
    "expected target, mode, service manager, and reverse proxy values must contain only letters, numbers, dot, underscore, or dash."
  )) {
  Assert-Contains -Text $workflow -Expected $expected -Context ".github/workflows/host-evidence.yml"
}

foreach ($unexpected in @(
    "push:",
    "pull_request:",
    "schedule:"
  )) {
  Assert-DoesNotContain -Text $workflow -Unexpected $unexpected -Context ".github/workflows/host-evidence.yml"
}

Write-Host "Host evidence workflow OK"
