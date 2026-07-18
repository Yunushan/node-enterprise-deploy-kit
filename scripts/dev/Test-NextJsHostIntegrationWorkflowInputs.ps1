param(
  [string]$MatrixPath = $env:MATRIX_PATH,
  [string]$RunnerLabels = $env:RUNNER_LABELS,
  [string]$Platform = $env:PLATFORM,
  [string]$EvidenceName = $env:EVIDENCE_NAME,
  [string]$ExpectedTargetId = $env:EXPECTED_TARGET_ID,
  [string]$ExpectedServiceManager = $env:EXPECTED_SERVICE_MANAGER,
  [string]$ExpectedReverseProxy = $env:EXPECTED_REVERSE_PROXY,
  [string]$UploadRetentionDays = $env:UPLOAD_RETENTION_DAYS,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = "config/support-matrix.example.json"
}

function Get-NormalizedArray {
  param($Values)
  @($Values | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function Assert-SafeRelativeJsonPath {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "matrix_path is required and must be a relative .json path inside the repository workspace."
  }
  $pathText = $Value.Trim()
  if ($pathText.Length -gt 240 -or $pathText -match '[\x00-\x1F\x7F:*?"<>|]') {
    throw "matrix_path must not contain control characters, drive letters, wildcards, or shell metacharacters."
  }
  if ($pathText -match '^[A-Za-z]:[\\/]' -or $pathText -match '^[\\/]' -or $pathText -match '^\\\\' -or $pathText -match '^//') {
    throw "matrix_path must be a relative path inside the repository workspace."
  }
  $normalizedPath = $pathText.Replace('\', '/')
  if ($normalizedPath -match '(^|/)\.\.(/|$)' -or $normalizedPath -match '/{2,}' -or $normalizedPath.EndsWith('/') -or $normalizedPath -notmatch '\.json$') {
    throw "matrix_path must be a relative .json path inside the repository workspace."
  }
}

function Assert-GitTrackedFile {
  param([string]$Value)

  $normalizedPath = $Value.Trim().Replace('\', '/')
  $trackedPaths = @(& git -C $RepoRoot ls-files -- $normalizedPath)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify that matrix_path is tracked by git."
  }
  if (-not @($trackedPaths | Where-Object { [string]::Equals([string]$_, $normalizedPath, [StringComparison]::OrdinalIgnoreCase) })) {
    throw "matrix_path must reference a tracked repository file."
  }
}

function Invoke-NextJsHostIntegrationWorkflowInputValidation {
  param(
    [string]$MatrixPath,
    [string]$RunnerLabels,
    [string]$Platform,
    [string]$EvidenceName,
    [string]$ExpectedTargetId,
    [string]$ExpectedServiceManager,
    [string]$ExpectedReverseProxy,
    [string]$UploadRetentionDays
  )

  Assert-SafeRelativeJsonPath -Value $MatrixPath
  $matrixRelativePath = $MatrixPath.Trim().Replace('\', '/')
  Assert-GitTrackedFile -Value $matrixRelativePath
  $resolvedMatrixPath = Join-Path $RepoRoot $matrixRelativePath
  if (-not (Test-Path -LiteralPath $resolvedMatrixPath -PathType Leaf)) {
    throw "Support matrix not found: $resolvedMatrixPath"
  }

  $dimensions = [ordered]@{
    expected_target_id = $ExpectedTargetId
    expected_service_manager = $ExpectedServiceManager
    expected_reverse_proxy = $ExpectedReverseProxy
  }
  foreach ($name in $dimensions.Keys) {
    $value = [string]$dimensions[$name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value -notmatch '^[A-Za-z0-9._-]+$') {
      throw "expected_target_id, expected_service_manager, and expected_reverse_proxy are required and must contain only letters, numbers, dot, underscore, or dash."
    }
  }

  $expectedTarget = $ExpectedTargetId.Trim().ToLowerInvariant()
  $expectedServiceManager = $ExpectedServiceManager.Trim().ToLowerInvariant()
  $expectedReverseProxy = $ExpectedReverseProxy.Trim().ToLowerInvariant()
  if ($expectedServiceManager -notin @('winsw', 'nssm', 'systemd', 'systemv', 'openrc', 'launchd')) {
    throw "expected_service_manager must be one of winsw, nssm, systemd, systemv, openrc, or launchd."
  }
  if ($expectedReverseProxy -notin @('iis', 'nginx', 'apache', 'haproxy', 'traefik', 'none')) {
    throw "expected_reverse_proxy must be one of iis, nginx, apache, haproxy, traefik, or none."
  }

  $matrix = Get-Content -LiteralPath $resolvedMatrixPath -Raw | ConvertFrom-Json
  $target = @($matrix.targets | Where-Object { ([string]$_.id).Trim().ToLowerInvariant() -eq $expectedTarget } | Select-Object -First 1)
  if ($target.Count -ne 1) {
    throw "expected_target_id must match a support matrix target id."
  }
  $target = $target[0]
  $category = ([string]$target.category).Trim().ToLowerInvariant()
  if ($target.PSObject.Properties['localCommandOnly'] -and $target.localCommandOnly -eq $true) {
    throw "expected_target_id '$expectedTarget' is local-command-only and cannot use the self-hosted Next.js integration workflow."
  }
  $expectedPlatform = if ($category -in @('windows-client', 'windows-server')) { 'windows' } elseif ($category -in @('linux', 'macos')) { 'unix' } else { '' }
  if (-not $expectedPlatform) {
    throw "expected_target_id '$expectedTarget' cannot use the self-hosted Next.js integration workflow."
  }
  if ($Platform.Trim().ToLowerInvariant() -ne $expectedPlatform) {
    throw "platform must be '$expectedPlatform' for support matrix target '$expectedTarget'."
  }
  if ((Get-NormalizedArray $target.serviceManagers) -notcontains $expectedServiceManager) {
    throw "expected_service_manager '$expectedServiceManager' is not declared for support matrix target '$expectedTarget'."
  }
  if ((Get-NormalizedArray $target.reverseProxies) -notcontains $expectedReverseProxy) {
    throw "expected_reverse_proxy '$expectedReverseProxy' is not declared for support matrix target '$expectedTarget'."
  }
  $nextJsModes = Get-NormalizedArray $target.nextjsModes
  if ($nextJsModes -notcontains 'standalone' -or $nextJsModes -notcontains 'next-start') {
    throw "expected_target_id '$expectedTarget' must declare standalone and next-start Next.js modes for self-hosted integration."
  }

  if ($EvidenceName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "evidence_name must contain only letters, numbers, dot, underscore, or dash."
  }
  $expectedEvidenceName = "$expectedTarget-nextjs-$expectedServiceManager-$expectedReverseProxy"
  if ($EvidenceName.Trim().ToLowerInvariant() -ne $expectedEvidenceName) {
    throw "evidence_name must match expected support dimensions: $expectedEvidenceName."
  }
  if ($UploadRetentionDays -notmatch '^\d+$' -or [int]$UploadRetentionDays -lt 1 -or [int]$UploadRetentionDays -gt 90) {
    throw "upload_retention_days must be an integer from 1 to 90."
  }

  if ([string]::IsNullOrWhiteSpace($RunnerLabels) -or -not $RunnerLabels.Trim().StartsWith('[')) {
    throw "runner_labels must be a JSON array containing self-hosted and the expected target label."
  }
  try {
    $labels = @($RunnerLabels.Trim() | ConvertFrom-Json)
  } catch {
    throw "runner_labels must be a valid JSON array containing self-hosted and the expected target label."
  }
  $normalizedLabels = @()
  foreach ($label in $labels) {
    $labelText = ([string]$label).Trim()
    if ($labelText -notmatch '^[A-Za-z0-9._-]+$') {
      throw "runner_labels values must contain only letters, numbers, dot, underscore, or dash."
    }
    $normalizedLabels += $labelText.ToLowerInvariant()
  }
  if ($normalizedLabels -notcontains 'self-hosted') {
    throw "runner_labels must include self-hosted for real Next.js host integration."
  }
  if ($normalizedLabels -notcontains $expectedTarget) {
    throw "runner_labels must include the expected target label '$expectedTarget' for real Next.js host integration."
  }
  $requiredCapabilityLabels = @("nextjs-manager-$expectedServiceManager", "nextjs-proxy-$expectedReverseProxy")
  foreach ($requiredLabel in $requiredCapabilityLabels) {
    if ($normalizedLabels -notcontains $requiredLabel) {
      throw "runner_labels must include the required capability label '$requiredLabel' for real Next.js host integration."
    }
  }
  foreach ($pattern in @('^ubuntu-(latest|\d{2}\.\d{2}.*)$', '^windows-(latest|\d{4}.*)$', '^macos-(latest|\d+.*)$')) {
    if (@($normalizedLabels | Where-Object { $_ -match $pattern }).Count -gt 0) {
      throw "runner_labels must not use GitHub-hosted runner labels for real Next.js host integration."
    }
  }
  $targetIds = Get-NormalizedArray ($matrix.targets | ForEach-Object { $_.id })
  $conflicting = @($normalizedLabels | Where-Object { $targetIds -contains $_ -and $_ -ne $expectedTarget } | Sort-Object -Unique)
  if ($conflicting.Count -gt 0) {
    throw "runner_labels must not include support target labels other than expected_target_id '$expectedTarget': $($conflicting -join ', ')."
  }
}

function Invoke-ExpectValidationFailure {
  param([string]$Name, [string]$ExpectedMessage, [scriptblock]$Action)
  try {
    & $Action
  } catch {
    if ($_.Exception.Message.Contains($ExpectedMessage)) { return }
    throw "$Name failed with unexpected message: $($_.Exception.Message)"
  }
  throw "$Name succeeded unexpectedly."
}

function Invoke-SelfTest {
  $base = @{
    MatrixPath = $MatrixPath
    RunnerLabels = '["self-hosted","windows-server-2022","nextjs-manager-winsw","nextjs-proxy-iis"]'
    Platform = 'windows'
    EvidenceName = 'windows-server-2022-nextjs-winsw-iis'
    ExpectedTargetId = 'windows-server-2022'
    ExpectedServiceManager = 'winsw'
    ExpectedReverseProxy = 'iis'
    UploadRetentionDays = '14'
  }
  Invoke-NextJsHostIntegrationWorkflowInputValidation @base

  $linux = $base.Clone()
  $linux.RunnerLabels = '["self-hosted","ubuntu","nextjs-manager-systemd","nextjs-proxy-nginx"]'
  $linux.Platform = 'unix'
  $linux.EvidenceName = 'ubuntu-nextjs-systemd-nginx'
  $linux.ExpectedTargetId = 'ubuntu'
  $linux.ExpectedServiceManager = 'systemd'
  $linux.ExpectedReverseProxy = 'nginx'
  Invoke-NextJsHostIntegrationWorkflowInputValidation @linux

  $macos = $linux.Clone()
  $macos.RunnerLabels = '["self-hosted","macos","nextjs-manager-launchd","nextjs-proxy-apache"]'
  $macos.EvidenceName = 'macos-nextjs-launchd-apache'
  $macos.ExpectedTargetId = 'macos'
  $macos.ExpectedServiceManager = 'launchd'
  $macos.ExpectedReverseProxy = 'apache'
  Invoke-NextJsHostIntegrationWorkflowInputValidation @macos

  Invoke-ExpectValidationFailure -Name 'fallback manager' -ExpectedMessage 'must be one of winsw' -Action {
    $case = $base.Clone(); $case.ExpectedServiceManager = 'pm2'; $case.EvidenceName = 'windows-server-2022-nextjs-pm2-iis'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'hosted label' -ExpectedMessage 'must not use GitHub-hosted runner labels' -Action {
    $case = $linux.Clone(); $case.RunnerLabels = '["self-hosted","ubuntu","ubuntu-24.04","nextjs-manager-systemd","nextjs-proxy-nginx"]'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'wrong platform' -ExpectedMessage "platform must be 'unix'" -Action {
    $case = $linux.Clone(); $case.Platform = 'windows'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'missing manager capability label' -ExpectedMessage "must include the required capability label 'nextjs-manager-systemd'" -Action {
    $case = $linux.Clone(); $case.RunnerLabels = '["self-hosted","ubuntu","nextjs-proxy-nginx"]'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'missing proxy capability label' -ExpectedMessage "must include the required capability label 'nextjs-proxy-nginx'" -Action {
    $case = $linux.Clone(); $case.RunnerLabels = '["self-hosted","ubuntu","nextjs-manager-systemd"]'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'conflicting label' -ExpectedMessage 'must not include support target labels other than expected_target_id' -Action {
    $case = $linux.Clone(); $case.RunnerLabels = '["self-hosted","ubuntu","debian","nextjs-manager-systemd","nextjs-proxy-nginx"]'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name 'bsd local command only' -ExpectedMessage 'local-command-only' -Action {
    $case = $linux.Clone(); $case.RunnerLabels = '["self-hosted","freebsd","nextjs-manager-systemd","nextjs-proxy-nginx"]'; $case.EvidenceName = 'freebsd-nextjs-systemd-nginx'; $case.ExpectedTargetId = 'freebsd'; $case.ExpectedServiceManager = 'systemd'
    Invoke-NextJsHostIntegrationWorkflowInputValidation @case
  }

  if (-not $Quiet) { Write-Host 'Next.js host integration workflow input validation self-test OK' }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Invoke-NextJsHostIntegrationWorkflowInputValidation `
  -MatrixPath $MatrixPath `
  -RunnerLabels $RunnerLabels `
  -Platform $Platform `
  -EvidenceName $EvidenceName `
  -ExpectedTargetId $ExpectedTargetId `
  -ExpectedServiceManager $ExpectedServiceManager `
  -ExpectedReverseProxy $ExpectedReverseProxy `
  -UploadRetentionDays $UploadRetentionDays
if (-not $Quiet) { Write-Host 'Next.js host integration workflow inputs OK' }
