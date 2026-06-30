param(
  [string]$MatrixPath = "",
  [string]$RunnerLabels = $env:RUNNER_LABELS,
  [string]$Platform = $env:PLATFORM,
  [string]$ConfigPath = $env:CONFIG_PATH,
  [string]$EvidenceName = $env:EVIDENCE_NAME,
  [string]$ExpectedTargetId = $env:EXPECTED_TARGET_ID,
  [string]$ExpectedNextJsMode = $env:EXPECTED_NEXTJS_MODE,
  [string]$ExpectedServiceManager = $env:EXPECTED_SERVICE_MANAGER,
  [string]$ExpectedReverseProxy = $env:EXPECTED_REVERSE_PROXY,
  [string]$MinimumUptimeHours = $env:MINIMUM_UPTIME_HOURS,
  [string]$UploadRetentionDays = $env:UPLOAD_RETENTION_DAYS,
  [switch]$Quiet,
  [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot "config\support-matrix.example.json"
}
if (-not [System.IO.Path]::IsPathRooted($MatrixPath)) {
  $MatrixPath = Join-Path $RepoRoot $MatrixPath
}

function Get-NormalizedArray {
  param($Values)
  @($Values | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function Get-OptionalPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $null
}

function Assert-SafeRelativeConfigPath {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "config_path is required and must be a relative path inside the repository workspace."
  }
  $pathText = $Value.Trim()
  if ($pathText.Length -gt 240) {
    throw "config_path must be 240 characters or less."
  }
  if ($pathText -match '[\x00-\x1F\x7F:*?"<>|]') {
    throw "config_path must not contain control characters, drive letters, wildcards, or shell metacharacters."
  }
  if ($pathText -match '^[A-Za-z]:[\\/]' -or $pathText -match '^[\\/]' -or $pathText -match '^\\\\' -or $pathText -match '^//') {
    throw "config_path must be a relative path inside the repository workspace."
  }
  $normalizedPath = $pathText.Replace('\', '/')
  if ($normalizedPath -match '(^|/)\.\.(/|$)' -or $normalizedPath -match '/{2,}' -or $normalizedPath.EndsWith('/')) {
    throw "config_path must not contain parent traversal, empty path segments, or a trailing slash."
  }
}

function Invoke-HostEvidenceWorkflowInputValidation {
  param(
    [string]$MatrixPath,
    [string]$RunnerLabels,
    [string]$Platform,
    [string]$ConfigPath,
    [string]$EvidenceName,
    [string]$ExpectedTargetId,
    [string]$ExpectedNextJsMode,
    [string]$ExpectedServiceManager,
    [string]$ExpectedReverseProxy,
    [string]$MinimumUptimeHours,
    [string]$UploadRetentionDays
  )

  if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
    throw "Support matrix not found: $MatrixPath"
  }

  $expectedDimensions = [ordered]@{
    expected_target_id = $ExpectedTargetId
    expected_nextjs_mode = $ExpectedNextJsMode
    expected_service_manager = $ExpectedServiceManager
    expected_reverse_proxy = $ExpectedReverseProxy
  }
  foreach ($name in $expectedDimensions.Keys) {
    $value = [string]$expectedDimensions[$name]
    if ([string]::IsNullOrWhiteSpace($value)) {
      throw "expected_target_id, expected_nextjs_mode, expected_service_manager, and expected_reverse_proxy are required for real host evidence collection."
    }
    if ($value -notmatch '^[A-Za-z0-9._-]+$') {
      throw "expected target, mode, service manager, and reverse proxy values must contain only letters, numbers, dot, underscore, or dash."
    }
  }

  $expectedNextJsMode = $ExpectedNextJsMode.Trim().ToLowerInvariant()
  $expectedServiceManager = $ExpectedServiceManager.Trim().ToLowerInvariant()
  $expectedReverseProxy = $ExpectedReverseProxy.Trim().ToLowerInvariant()
  $expectedTarget = $ExpectedTargetId.Trim().ToLowerInvariant()

  if ($expectedNextJsMode -notin @("standalone", "next-start")) {
    throw "expected_nextjs_mode must be standalone or next-start."
  }
  if ($expectedServiceManager -notin @("winsw", "nssm", "pm2", "systemd", "systemv", "openrc", "launchd", "bsdrc")) {
    throw "expected_service_manager must be one of winsw, nssm, pm2, systemd, systemv, openrc, launchd, or bsdrc."
  }
  if ($expectedReverseProxy -notin @("iis", "nginx", "apache", "haproxy", "traefik", "none")) {
    throw "expected_reverse_proxy must be one of iis, nginx, apache, haproxy, traefik, or none."
  }

  $matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
  $target = @($matrix.targets | Where-Object { ([string]$_.id).Trim().ToLowerInvariant() -eq $expectedTarget } | Select-Object -First 1)
  if ($target.Count -ne 1) {
    throw "expected_target_id must match a support matrix target id."
  }
  $target = $target[0]

  $targetModes = @(Get-NormalizedArray $target.nextjsModes)
  if ($targetModes -notcontains $expectedNextJsMode) {
    throw "expected_nextjs_mode '$expectedNextJsMode' is not declared for support matrix target '$expectedTarget'."
  }
  $targetPrimaryServiceManagers = @(Get-NormalizedArray $target.serviceManagers)
  $targetFallbackServiceManagers = @(Get-NormalizedArray (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers"))
  $targetServiceManagers = @(
    $targetPrimaryServiceManagers +
    $targetFallbackServiceManagers |
      Sort-Object -Unique
  )
  if ($targetServiceManagers -notcontains $expectedServiceManager) {
    throw "expected_service_manager '$expectedServiceManager' is not declared for support matrix target '$expectedTarget'."
  }
  $targetReverseProxies = @(Get-NormalizedArray $target.reverseProxies)
  if ($targetReverseProxies -notcontains $expectedReverseProxy) {
    throw "expected_reverse_proxy '$expectedReverseProxy' is not declared for support matrix target '$expectedTarget'."
  }

  Assert-SafeRelativeConfigPath -Value $ConfigPath

  if ($EvidenceName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "evidence_name must contain only letters, numbers, dot, underscore, or dash."
  }
  $expectedEvidenceName = "$expectedTarget-$expectedNextJsMode-$expectedServiceManager-$expectedReverseProxy"
  if ($targetFallbackServiceManagers -contains $expectedServiceManager) {
    $expectedEvidenceName = "$expectedEvidenceName-fallback"
  }
  if ($EvidenceName.Trim().ToLowerInvariant() -ne $expectedEvidenceName) {
    throw "evidence_name must match expected support dimensions: $expectedEvidenceName."
  }
  if ($MinimumUptimeHours -notmatch '^\d+$') {
    throw "minimum_uptime_hours must be a non-negative integer."
  }
  $minimumUptimeHoursValue = [int]$MinimumUptimeHours
  try {
    $requiredMinimumUptimeHours = [int]$matrix.requiredMinimumUptimeHours
  } catch {
    throw "support matrix requiredMinimumUptimeHours must be a positive integer."
  }
  if ($requiredMinimumUptimeHours -lt 1) {
    throw "support matrix requiredMinimumUptimeHours must be a positive integer."
  }
  if ($minimumUptimeHoursValue -lt $requiredMinimumUptimeHours) {
    throw "minimum_uptime_hours must be greater than or equal to support matrix requiredMinimumUptimeHours."
  }

  if ($UploadRetentionDays -notmatch '^\d+$') {
    throw "upload_retention_days must be an integer from 1 to 90."
  }
  $retentionDays = [int]$UploadRetentionDays
  if ($retentionDays -lt 1 -or $retentionDays -gt 90) {
    throw "upload_retention_days must be an integer from 1 to 90."
  }

  $targetCategory = ([string]$target.category).Trim().ToLowerInvariant()
  $expectedPlatform = if ($targetCategory -in @("windows-client", "windows-server")) { "windows" } else { "unix" }
  if ($Platform.Trim().ToLowerInvariant() -ne $expectedPlatform) {
    throw "platform must be '$expectedPlatform' for support matrix target '$expectedTarget'."
  }

  $rawLabels = $RunnerLabels.Trim()
  if (-not $rawLabels.StartsWith("[")) {
    throw "runner_labels must be a JSON array containing self-hosted and the expected target label."
  }
  try {
    $labels = @($rawLabels | ConvertFrom-Json)
  } catch {
    throw "runner_labels must be a valid JSON array containing self-hosted and the expected target label."
  }
  if ($labels.Count -eq 0) {
    throw "runner_labels must include self-hosted and the expected target label."
  }

  $normalizedLabels = @()
  foreach ($label in $labels) {
    $labelText = ([string]$label).Trim()
    if ($labelText -notmatch '^[A-Za-z0-9._-]+$') {
      throw "runner_labels values must contain only letters, numbers, dot, underscore, or dash."
    }
    $normalizedLabels += $labelText.ToLowerInvariant()
  }

  $hostedLabelPatterns = @(
    '^ubuntu-(latest|\d{2}\.\d{2}.*)$',
    '^windows-(latest|\d{4}.*)$',
    '^macos-(latest|\d+.*)$'
  )
  foreach ($label in $normalizedLabels) {
    foreach ($hostedLabelPattern in $hostedLabelPatterns) {
      if ($label -match $hostedLabelPattern) {
        throw "runner_labels must not use GitHub-hosted runner labels for real host evidence."
      }
    }
  }

  if ($normalizedLabels -notcontains "self-hosted") {
    throw "runner_labels must include self-hosted for real host evidence collection."
  }
  if ($normalizedLabels -notcontains $expectedTarget) {
    throw "runner_labels must include the expected target label '$expectedTarget' for real host evidence collection."
  }
}

function Invoke-ExpectValidationFailure {
  param(
    [string]$Name,
    [string]$ExpectedMessage,
    [scriptblock]$Action
  )

  $failed = $false
  try {
    & $Action
  } catch {
    $failed = $true
    if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
      throw "$Name failed with unexpected message: $($_.Exception.Message)"
    }
  }
  if (-not $failed) {
    throw "$Name succeeded unexpectedly."
  }
}

function Invoke-SelfTest {
  $base = @{
    MatrixPath = $MatrixPath
    RunnerLabels = '["self-hosted","windows-server-2022"]'
    Platform = "windows"
    ConfigPath = "config/windows/app.config.json"
    EvidenceName = "windows-server-2022-standalone-winsw-iis"
    ExpectedTargetId = "windows-server-2022"
    ExpectedNextJsMode = "standalone"
    ExpectedServiceManager = "winsw"
    ExpectedReverseProxy = "iis"
    MinimumUptimeHours = "72"
    UploadRetentionDays = "30"
  }
  Invoke-HostEvidenceWorkflowInputValidation @base

  $unix = $base.Clone()
  $unix.RunnerLabels = '["self-hosted","ubuntu"]'
  $unix.Platform = "unix"
  $unix.ConfigPath = "config/linux/app.env"
  $unix.EvidenceName = "ubuntu-next-start-systemd-nginx"
  $unix.ExpectedTargetId = "ubuntu"
  $unix.ExpectedNextJsMode = "next-start"
  $unix.ExpectedServiceManager = "systemd"
  $unix.ExpectedReverseProxy = "nginx"
  Invoke-HostEvidenceWorkflowInputValidation @unix

  $fallback = $base.Clone()
  $fallback.RunnerLabels = '["self-hosted","windows-10"]'
  $fallback.ExpectedTargetId = "windows-10"
  $fallback.ExpectedServiceManager = "pm2"
  $fallback.EvidenceName = "windows-10-standalone-pm2-iis-fallback"
  Invoke-HostEvidenceWorkflowInputValidation @fallback

  Invoke-ExpectValidationFailure -Name "hosted ubuntu label" -ExpectedMessage "runner_labels must not use GitHub-hosted runner labels" -Action {
    $case = $unix.Clone()
    $case.RunnerLabels = '["self-hosted","ubuntu-24.04","ubuntu"]'
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "hosted windows label" -ExpectedMessage "runner_labels must not use GitHub-hosted runner labels" -Action {
    $case = $base.Clone()
    $case.RunnerLabels = '["self-hosted","windows-2022","windows-server-2022"]'
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "hosted macos label" -ExpectedMessage "runner_labels must not use GitHub-hosted runner labels" -Action {
    $case = $unix.Clone()
    $case.RunnerLabels = '["self-hosted","macos-15","macos"]'
    $case.ExpectedTargetId = "macos"
    $case.ExpectedServiceManager = "launchd"
    $case.ExpectedReverseProxy = "nginx"
    $case.EvidenceName = "macos-next-start-launchd-nginx"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "missing target label" -ExpectedMessage "runner_labels must include the expected target label" -Action {
    $case = $base.Clone()
    $case.RunnerLabels = '["self-hosted","windows"]'
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "platform mismatch" -ExpectedMessage "platform must be 'windows'" -Action {
    $case = $base.Clone()
    $case.Platform = "unix"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "minimum uptime too low" -ExpectedMessage "minimum_uptime_hours must be greater than or equal" -Action {
    $case = $base.Clone()
    $case.MinimumUptimeHours = "1"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "unsafe config path" -ExpectedMessage "config_path must not contain control characters" -Action {
    $case = $base.Clone()
    $case.ConfigPath = "C:\secret\app.config.json"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "undeclared manager" -ExpectedMessage "is not declared for support matrix target" -Action {
    $case = $unix.Clone()
    $case.ExpectedServiceManager = "winsw"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "mismatched evidence name" -ExpectedMessage "evidence_name must match expected support dimensions" -Action {
    $case = $base.Clone()
    $case.EvidenceName = "windows-server-2022-next-start-winsw-iis"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }
  Invoke-ExpectValidationFailure -Name "fallback evidence name without suffix" -ExpectedMessage "evidence_name must match expected support dimensions" -Action {
    $case = $fallback.Clone()
    $case.EvidenceName = "windows-10-standalone-pm2-iis"
    Invoke-HostEvidenceWorkflowInputValidation @case
  }

  if (-not $Quiet) {
    Write-Host "Host evidence workflow input validation self-test OK"
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  return
}

Invoke-HostEvidenceWorkflowInputValidation `
  -MatrixPath $MatrixPath `
  -RunnerLabels $RunnerLabels `
  -Platform $Platform `
  -ConfigPath $ConfigPath `
  -EvidenceName $EvidenceName `
  -ExpectedTargetId $ExpectedTargetId `
  -ExpectedNextJsMode $ExpectedNextJsMode `
  -ExpectedServiceManager $ExpectedServiceManager `
  -ExpectedReverseProxy $ExpectedReverseProxy `
  -MinimumUptimeHours $MinimumUptimeHours `
  -UploadRetentionDays $UploadRetentionDays

if (-not $Quiet) {
  Write-Host "Host evidence workflow inputs OK"
}
