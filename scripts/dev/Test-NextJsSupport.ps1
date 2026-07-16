param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function New-Directory {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Text
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Directory $directory
  }
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-ForwardSlashPath {
  param([string]$Path)
  return $Path.Replace("\", "/")
}

function Assert-FileContainsText {
  param(
    [string]$Path,
    [string]$ExpectedText
  )

  $text = Get-Content -Path $Path -Raw
  if (-not $text.Contains($ExpectedText)) {
    throw "$(Get-RepoRelativePath $Path) is missing expected text: $ExpectedText"
  }
}

function Assert-FileDoesNotContainText {
  param(
    [string]$Path,
    [string]$UnexpectedText
  )

  $text = Get-Content -Path $Path -Raw
  if ($text.Contains($UnexpectedText)) {
    throw "$(Get-RepoRelativePath $Path) contains unexpected text: $UnexpectedText"
  }
}

function Test-WindowsStatusSmokeSupported {
  return [bool](
    (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) -and
    (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) -and
    (Get-Command Get-Service -ErrorAction SilentlyContinue)
  )
}

function Get-RepoRelativePath {
  param([string]$Path)
  return (ConvertTo-ForwardSlashPath $Path.Substring($RepoRoot.Length + 1))
}

function Test-LinuxRuntimeEnvironmentDefaults {
  $installerPath = Join-Path $RepoRoot "scripts/linux/install-node-service.sh"
  foreach ($expected in @(
      'write_shell_env_assignment "$ENV_FILE" "$key" "$value"',
      'write_env_value "PORT" "$APP_PORT"',
      'write_env_value "APP_PORT" "$APP_PORT"',
      'write_env_value "BIND_ADDRESS" "$BIND_ADDRESS"',
      'write_env_value "HOST" "$runtime_host"',
      'write_env_value "HOSTNAME" "$runtime_host"',
      'PREPARATION_ENV_FILE="${PREPARATION_ENV_FILE:-}"',
      'load_preparation_environment',
      'PREPARATION_ENV_FILE line $line_number must use NAME=value syntax.',
      'env "${PREPARATION_ENV_ASSIGNMENTS[@]}" bash -lc',
      'NODE_ENV|PORT|APP_PORT|APP_NAME|BIND_ADDRESS|HOST|HOSTNAME|"") continue ;;'
    )) {
    Assert-FileContainsText -Path $installerPath -ExpectedText $expected
  }

  $preflightPath = Join-Path $RepoRoot "scripts/linux/test-deployment-preflight.sh"
  foreach ($expected in @(
      'PREPARATION_ENV_FILE must be an absolute target-local path.',
      'PREPARATION_ENV_FILE line $preparation_line_number must use NAME=value syntax.'
    )) {
    Assert-FileContainsText -Path $preflightPath -ExpectedText $expected
  }

  Assert-FileContainsText `
    -Path (Join-Path $RepoRoot "ansible/roles/linux_node_service/templates/deploy.env.j2") `
    -ExpectedText "['NODE_ENV', 'PORT', 'APP_PORT', 'APP_NAME', 'BIND_ADDRESS', 'HOST', 'HOSTNAME']"

  $commonPath = Join-Path $RepoRoot "scripts/linux/common.sh"
  foreach ($expected in @(
      "shell_single_quote()",
      "write_shell_env_assignment()",
      "Invalid environment key"
    )) {
    Assert-FileContainsText -Path $commonPath -ExpectedText $expected
  }
}

function Test-WindowsFallbackRuntimeEnvironmentDefaults {
  $nssmInstallerPath = Join-Path $RepoRoot "scripts/windows/Install-NSSMService.ps1"
  foreach ($expected in @(
      'ConvertTo-ServiceEnvironmentMap',
      '$map["PORT"] = [string]$Config.Port',
      '$map["APP_PORT"] = [string]$Config.Port',
      '$map["BIND_ADDRESS"] = $bindAddress',
      '$map["HOSTNAME"] = $bindAddress',
      'AppEnvironmentExtra @environmentEntries',
      'sc.exe config $config.AppName start= auto'
    )) {
    Assert-FileContainsText -Path $nssmInstallerPath -ExpectedText $expected
  }

  $pm2InstallerPath = Join-Path $RepoRoot "scripts/windows/Install-PM2Fallback.ps1"
  foreach ($expected in @(
      'ConvertTo-ServiceEnvironmentMap',
      '$map["PORT"] = [string]$Config.Port',
      '$map["APP_PORT"] = [string]$Config.Port',
      '$map["BIND_ADDRESS"] = $bindAddress',
      '$map["HOSTNAME"] = $bindAddress',
      'interpreter = [string]$Config.NodeExe',
      'pm2 start $ecosystemPath --only $config.AppName --update-env'
    )) {
    Assert-FileContainsText -Path $pm2InstallerPath -ExpectedText $expected
  }
}

function Test-WindowsPreparationEnvironmentIsolation {
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Host "Skipping Windows preparation environment smoke; cmd.exe is only available on Windows."
    return
  }

  $preparationPath = Join-Path $RepoRoot "scripts/windows/Invoke-AppPreparation.ps1"
  foreach ($expected in @(
      "Get-PreparationEnvironment",
      "Invoke-WithPreparationEnvironment",
      "PreparationEnvironment contains an invalid environment variable name.",
      '[Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], "Process")',
      '[Environment]::SetEnvironmentVariable($name, $previousValues[$name], "Process")'
    )) {
    Assert-FileContainsText -Path $preparationPath -ExpectedText $expected
  }

  $testRoot = Join-Path $RepoRoot (".tmp\preparation-environment-" + [guid]::NewGuid().ToString("N"))
  $appDirectory = Join-Path $testRoot "app"
  $configPath = Join-Path $testRoot "app.config.json"
  $outputPath = Join-Path $testRoot "install-environment.txt"
  $variableName = "NODE_ENTERPRISE_DEPLOY_KIT_PREPARATION_TEST"
  $previousValue = [Environment]::GetEnvironmentVariable($variableName, "Process")

  try {
    New-Directory $appDirectory
    [Environment]::SetEnvironmentVariable($variableName, "outside", "Process")
    $config = [ordered]@{
      AppName = "PreparationEnvironmentTest"
      AppDirectory = $appDirectory
      InstallCommand = "echo %$variableName%> `"$outputPath`""
      BuildCommand = ""
      PreparationEnvironment = [ordered]@{
        $variableName = "inside"
      }
    }
    Write-Utf8NoBom -Path $configPath -Text (($config | ConvertTo-Json -Depth 10) + "`n")

    & $preparationPath -ConfigPath $configPath -SkipBuild | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Invoke-AppPreparation.ps1 failed while testing PreparationEnvironment."
    }
    if ((Get-Content -LiteralPath $outputPath -Raw).Trim() -ne "inside") {
      throw "PreparationEnvironment was not visible to InstallCommand."
    }
    if ([Environment]::GetEnvironmentVariable($variableName, "Process") -ne "outside") {
      throw "PreparationEnvironment was not restored after InstallCommand."
    }

    $config.PreparationEnvironment = [ordered]@{ "INVALID-NAME" = "value" }
    Write-Utf8NoBom -Path $configPath -Text (($config | ConvertTo-Json -Depth 10) + "`n")
    $invalidError = ""
    try {
      & $preparationPath -ConfigPath $configPath -SkipInstall -SkipBuild
    }
    catch {
      $invalidError = $_.Exception.Message
    }
    if ($invalidError -notmatch "invalid environment variable name") {
      throw "PreparationEnvironment should reject invalid variable names."
    }
  }
  finally {
    [Environment]::SetEnvironmentVariable($variableName, $previousValue, "Process")
    if (Test-Path -LiteralPath $testRoot) {
      Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-PostDeployDiagnosticsIncludeNextJsLayout {
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Next.js runtime layout"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "MinimumNodeVersion"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "NodeVersionSatisfied"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Next.js standalone StartCommand must be a single file path."
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Next.js next-start mode requires NodeArguments to start with 'start'."
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "DuplicateBindingCount"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Configured IIS reverse proxy site is not started."
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Configured IIS site does not own the expected public binding."
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "OwnedByService"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/windows/Install-IISReverseProxy.ps1") -ExpectedText "Ensure-WebsiteStarted"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the configured IIS site is started."
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Health = [pscustomobject]"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "Uptime = [pscustomobject]"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "ServiceStartedDuringCurrentBoot"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "status.ps1") -ExpectedText "HealthMonitor = [pscustomobject]"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"ownedByService"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"health": {'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"uptime": {'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"serviceStartedDuringCurrentBoot"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"healthMonitor": {'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"minimumNodeVersion"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"nodeVersionSatisfied"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"nextStartScriptIsExpectedCli"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"schedulerChecked"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText "launchd-timer"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText "HealthCronEntryExists"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the configured app port is owned by the configured service process"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the HTTP health probe was performed"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove service process uptime seconds"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the service started during the current host boot session"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove health monitor status ok"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the systemd healthcheck timer exists"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the launchd healthcheck plist exists"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the managed cron healthcheck entry exists"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "deploy.sh") -ExpectedText "install-healthcheck-scheduler.sh"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/install-healthcheck-scheduler.sh") -ExpectedText "install_launchd_scheduler"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/install-healthcheck-scheduler.sh") -ExpectedText "install_cron_scheduler"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "templates/linux/launchd-healthcheck.plist.tpl") -ExpectedText "<key>StartInterval</key>"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/windows/Test-DeploymentPreflight.ps1") -ExpectedText "deliberate binding takeover workflow"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/status-node-app.sh") -ExpectedText '"managedMarkerFound"'
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/dev/Test-HostEvidence.ps1") -ExpectedText "does not prove the expected reverse-proxy config file exists"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "templates/linux/nginx-site.conf.tpl") -ExpectedText "Managed by node-enterprise-deploy-kit"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "templates/linux/apache-vhost.conf.tpl") -ExpectedText "Managed by node-enterprise-deploy-kit"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "templates/linux/traefik-dynamic.yml.tpl") -ExpectedText "Managed by node-enterprise-deploy-kit"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/windows/Diagnose-NodeApp.ps1") -ExpectedText "Next.js Runtime Layout"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/windows/Diagnose-NodeApp.ps1") -ExpectedText "NextStartCommandUnderNextPackage"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/windows/Diagnose-NodeApp.ps1") -ExpectedText "NextStartCommandIsExpectedCli"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/diagnose-node-app.sh") -ExpectedText "nextjs_runtime_summary"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/diagnose-node-app.sh") -ExpectedText "NextStartScriptUnderNextPackage"
  Assert-FileContainsText -Path (Join-Path $RepoRoot "scripts/linux/diagnose-node-app.sh") -ExpectedText "NextStartScriptIsExpectedCli"
}

function New-WindowsConfig {
  param(
    [string]$Path,
    [string]$AppDirectory,
    [string]$ServiceDirectory,
    [string]$LogDirectory,
    [int]$Port,
    [string]$NextjsDeploymentMode = "standalone",
    [string]$StartCommand = "server.js",
    [string]$NodeArguments = "",
    [string]$ServiceManager = "nssm",
    [string]$ReverseProxy = "none",
    [switch]$NoEnvironment,
    [switch]$RequireServerActionsEncryptionKey,
    [switch]$RequireDeploymentId,
    [switch]$RequirePackageProvenance,
    [switch]$WithMultiInstanceEnvironment,
    [string]$ServerActionsEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    [string]$DeploymentId = "example-deploy-001"
  )

  if ($NextjsDeploymentMode.ToLowerInvariant() -eq "next-start" -and [string]::IsNullOrWhiteSpace($NodeArguments)) {
    $NodeArguments = "start -H 127.0.0.1"
  }
  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCommand) {
    $nodeExe = $nodeCommand.Source
  } else {
    $nodeExe = Join-Path (Split-Path -Parent $Path) "fake-node.cmd"
    Write-Utf8NoBom -Path $nodeExe -Text "@echo off`r`nif ""%~1""==""--version"" (`r`n  echo v20.11.1`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n"
  }
  $config = [ordered]@{
    AppName = "ExampleNextSmoke"
    DisplayName = "Example Next Smoke"
    Description = "Example Next Smoke"
    DeploymentMode = "reverse_proxy"
    AppFramework = "nextjs"
    NextjsDeploymentMode = $NextjsDeploymentMode
    NextjsRequireStaticAssets = $true
    NextjsRequirePublicDirectory = $false
    NextjsRequirePackageProvenance = [bool]$RequirePackageProvenance
    NextjsRequireServerActionsEncryptionKey = [bool]$RequireServerActionsEncryptionKey
    NextjsRequireDeploymentId = [bool]$RequireDeploymentId
    NextjsMinimumNodeVersion = "20.9.0"
    AutoDownloadWinSW = $true
    WinSWDownloadUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
    RequireWinSWDownloadSha256 = $false
    WinSWDownloadSha256 = ""
    AppDirectory = $AppDirectory
    StartCommand = $StartCommand
    NodeExe = $nodeExe
    NodeArguments = $NodeArguments
    Port = $Port
    BindAddress = "127.0.0.1"
    HealthUrl = "http://127.0.0.1:$Port/health"
    ServiceManager = $ServiceManager
    ReverseProxy = $ReverseProxy
    ServiceDirectory = $ServiceDirectory
    LogDirectory = $LogDirectory
    BackupDirectory = (Join-Path $ServiceDirectory "backups")
    IisSitePath = $AppDirectory
    IisSiteName = "ExampleNextSmoke"
    IisAppPoolName = "ExampleNextSmoke-AppPool"
    PublicHostName = "example.local"
    PublicPort = 443
    TlsEnabled = $false
    IisCertificateThumbprint = ""
    IisEnableArrProxy = $true
    IisRequireUrlRewrite = $false
    IisRequireArrProxy = $false
    IisSetForwardedHeaders = $true
    IisHealthProxyPath = "health"
    IisWebSocketSupport = $true
    IisProxyTimeoutSeconds = 300
    ServiceAccount = "NetworkService"
    ServiceAccountPassword = ""
    FailureRestartDelaySeconds = 60
    HealthCheckIntervalMinutes = 1
    HealthCheckFailureThreshold = 2
    HealthCheckRestartCooldownMinutes = 5
    HealthCheckTimeoutSeconds = 10
    LogRetentionDays = 30
    BackupRetentionDays = 90
    DiagnosticRetentionDays = 14
  }
  if ($NextjsDeploymentMode.ToLowerInvariant() -eq "next-start") {
    $config["PackageExpectedFiles"] = @("package.json", ".next/BUILD_ID", ".next", "node_modules/next/package.json", "node_modules/next/dist/bin/next")
  } else {
    $config["PackageExpectedFiles"] = @("server.js", ".next/BUILD_ID", ".next/static", "node_modules/next/package.json")
  }

  if (-not $NoEnvironment) {
    $config["Environment"] = [ordered]@{
      NODE_ENV = "production"
      PORT = [string]$Port
      APP_PORT = [string]$Port
      APP_NAME = "ExampleNextSmoke"
      BIND_ADDRESS = "127.0.0.1"
      HOST = "127.0.0.1"
      HOSTNAME = "127.0.0.1"
    }
    if ($WithMultiInstanceEnvironment) {
      $config["Environment"]["NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"] = $ServerActionsEncryptionKey
      $config["Environment"]["NEXT_DEPLOYMENT_ID"] = $DeploymentId
    }
  }

  Write-Utf8NoBom -Path $Path -Text (($config | ConvertTo-Json -Depth 20) + "`n")
}

function New-UnixEnv {
  param(
    [string]$Path,
    [string]$RelativeRoot,
    [int]$Port,
    [string]$NextjsDeploymentMode = "standalone",
    [string]$StartScript = "server.js",
    [string]$NodeArguments = "",
    [string]$ServiceManager = "bsdrc",
    [switch]$RequireServerActionsEncryptionKey,
    [switch]$RequireDeploymentId,
    [switch]$WithMultiInstanceEnvironment,
    [string]$ServerActionsEncryptionKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    [string]$DeploymentId = "example-deploy-001"
  )

  $relativeRoot = ConvertTo-ForwardSlashPath $RelativeRoot
  $nodeBinPath = Join-Path (Split-Path -Parent $Path) "fake-node.sh"
  $nodeBinRelative = "$relativeRoot/fake-node.sh"
  Write-Utf8NoBom -Path $nodeBinPath -Text "#!/bin/sh`nif [ ""`${1:-}"" = ""--version"" ]; then`n  echo v20.11.1`n  exit 0`nfi`nif [ ""`${1:-}"" = ""-p"" ] && [ ""`${2:-}"" = ""process.versions.modules"" ]; then`n  echo 115`n  exit 0`nfi`nexit 0`n"
  $bashForChmod = Get-Command bash -ErrorAction SilentlyContinue
  if ($bashForChmod) {
    & $bashForChmod.Source "-lc" "chmod +x '$nodeBinRelative'" | Out-Null
  }
  if ($NextjsDeploymentMode.ToLowerInvariant() -eq "next-start" -and [string]::IsNullOrWhiteSpace($NodeArguments)) {
    $NodeArguments = "start -H 127.0.0.1"
  }
  if ($NextjsDeploymentMode.ToLowerInvariant() -eq "next-start") {
    $packageExpectedFiles = "package.json .next/BUILD_ID .next node_modules/next/package.json node_modules/next/dist/bin/next"
  } else {
    $packageExpectedFiles = "server.js .next/BUILD_ID .next/static node_modules/next/package.json"
  }
  $text = @"
APP_NAME="example-next-smoke"
APP_DISPLAY_NAME="Example Next Smoke"
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="$NextjsDeploymentMode"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="$([bool]$RequireServerActionsEncryptionKey)"
NEXTJS_REQUIRE_DEPLOYMENT_ID="$([bool]$RequireDeploymentId)"
NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
APP_DIR="$relativeRoot/app"
NODE_BIN="$nodeBinRelative"
START_SCRIPT="$StartScript"
NODE_ARGUMENTS="$NodeArguments"
APP_PORT="$Port"
BIND_ADDRESS="127.0.0.1"
HEALTH_URL="http://127.0.0.1:$Port/health"
LOG_DIR="$relativeRoot/logs"
SERVICE_MANAGER="$ServiceManager"
REVERSE_PROXY="none"
SERVICE_USER="nodeapp"
SERVICE_GROUP="nodeapp"
ENV_FILE="$relativeRoot/etc/example-next-smoke.env"
HEALTHCHECK_STATE_DIR="$relativeRoot/state"
PACKAGE_EXPECTED_FILES="$packageExpectedFiles"
"@

  if ($WithMultiInstanceEnvironment) {
    $text += @"
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="$ServerActionsEncryptionKey"
NEXT_DEPLOYMENT_ID="$DeploymentId"
RUNTIME_ENV_KEYS="NEXT_SERVER_ACTIONS_ENCRYPTION_KEY NEXT_DEPLOYMENT_ID"
"@
  }

  Write-Utf8NoBom -Path $Path -Text (($text -replace "`r`n", "`n").Trim() + "`n")
}

function New-StandaloneLayout {
  param(
    [string]$AppDirectory,
    [switch]$WithoutStatic
  )

  New-Directory $AppDirectory
  New-Directory (Join-Path $AppDirectory ".next")
  if (-not $WithoutStatic) {
    New-Directory (Join-Path $AppDirectory ".next\static")
    Write-Utf8NoBom -Path (Join-Path $AppDirectory ".next\static\app.js") -Text "console.log('static');`n"
  }
  Write-Utf8NoBom -Path (Join-Path $AppDirectory ".next\BUILD_ID") -Text "example-build`n"
  New-Directory (Join-Path $AppDirectory "node_modules")
  New-Directory (Join-Path $AppDirectory "node_modules\next")
  Write-Utf8NoBom -Path (Join-Path $AppDirectory "node_modules\next\package.json") -Text "{`"name`":`"next`",`"version`":`"0.0.0-test`"}`n"
  Write-Utf8NoBom -Path (Join-Path $AppDirectory "server.js") -Text "console.log('ok');`n"
}

function New-NextProjectLayout {
  param(
    [string]$ProjectDirectory,
    [switch]$WithPublic
  )

  $standaloneRoot = Join-Path $ProjectDirectory ".next\standalone"
  $staticRoot = Join-Path $ProjectDirectory ".next\static"
  New-Directory $standaloneRoot
  New-Directory $staticRoot
  New-Directory (Join-Path $standaloneRoot "node_modules")
  New-Directory (Join-Path $standaloneRoot "node_modules\next")
  Write-Utf8NoBom -Path (Join-Path $standaloneRoot "server.js") -Text "console.log('standalone');`n"
  Write-Utf8NoBom -Path (Join-Path $standaloneRoot "node_modules\next\package.json") -Text "{`"name`":`"next`",`"version`":`"0.0.0-test`"}`n"
  Write-Utf8NoBom -Path (Join-Path $standaloneRoot "package.json") -Text "{`"scripts`":{`"start`":`"node server.js`"}}`n"
  Write-Utf8NoBom -Path (Join-Path $staticRoot "app.js") -Text "console.log('static');`n"
  Write-Utf8NoBom -Path (Join-Path $ProjectDirectory ".next\BUILD_ID") -Text "example-build`n"

  if ($WithPublic) {
    $publicRoot = Join-Path $ProjectDirectory "public"
    New-Directory $publicRoot
    Write-Utf8NoBom -Path (Join-Path $publicRoot "robots.txt") -Text "User-agent: *`n"
  }
}

function New-NextStartLayout {
  param(
    [string]$AppDirectory,
    [switch]$WithoutNextPackage,
    [switch]$WithoutNextPackageJson,
    [switch]$WithoutNextCli
  )

  New-Directory $AppDirectory
  New-Directory (Join-Path $AppDirectory ".next")
  Write-Utf8NoBom -Path (Join-Path $AppDirectory ".next\BUILD_ID") -Text "example-build`n"
  Write-Utf8NoBom -Path (Join-Path $AppDirectory "package.json") -Text "{`"scripts`":{`"start`":`"next start`"},`"dependencies`":{`"next`":`"0.0.0-test`"}}`n"
  if (-not $WithoutNextPackage) {
    $nextPackage = Join-Path $AppDirectory "node_modules\next"
    New-Directory $nextPackage
    if (-not $WithoutNextPackageJson) {
      Write-Utf8NoBom -Path (Join-Path $nextPackage "package.json") -Text "{`"name`":`"next`",`"version`":`"0.0.0-test`"}`n"
    }
    $nextCli = Join-Path $nextPackage "dist\bin"
    New-Directory $nextCli
    if (-not $WithoutNextCli) {
      Write-Utf8NoBom -Path (Join-Path $nextCli "next") -Text "#!/usr/bin/env node`n"
    }
  }
}

function Assert-ZipContains {
  param(
    [string]$Path,
    [string[]]$ExpectedEntries
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
    foreach ($expected in $ExpectedEntries) {
      if ($entries -notcontains $expected) {
        throw "Zip package $Path is missing expected entry: $expected"
      }
    }
  }
  finally {
    $zip.Dispose()
  }
}

function New-ZipFromDirectory {
  param(
    [string]$SourceDirectory,
    [string]$OutputPath
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $outputDirectory = Split-Path -Parent $OutputPath
  New-Directory $outputDirectory
  if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
  }
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $SourceDirectory,
    $OutputPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
  )
}

function New-ZipWithUnsafeUnixSymlinkEntry {
  param([string]$OutputPath)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $outputDirectory = Split-Path -Parent $OutputPath
  New-Directory $outputDirectory
  if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
  }

  $zip = [System.IO.Compression.ZipFile]::Open(
    $OutputPath,
    [System.IO.Compression.ZipArchiveMode]::Create
  )
  try {
    foreach ($item in @(
        @{ Name = "server.js"; Content = "console.log('standalone');`n" },
        @{ Name = ".next/BUILD_ID"; Content = "example-build`n" },
        @{ Name = ".next/static/app.js"; Content = "console.log('static');`n" }
      )) {
      $entry = $zip.CreateEntry([string]$item.Name)
      $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($false))
      try {
        $writer.Write([string]$item.Content)
      }
      finally {
        $writer.Dispose()
      }
    }

    $linkEntry = $zip.CreateEntry("public/current")
    $symlinkAttributes = [uint32]2716663808
    $linkEntry.ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes($symlinkAttributes), 0)
    $writer = New-Object System.IO.StreamWriter($linkEntry.Open(), [System.Text.UTF8Encoding]::new($false))
    try {
      $writer.Write("target`n")
    }
    finally {
      $writer.Dispose()
    }
  }
  finally {
    $zip.Dispose()
  }
}

function Assert-TarContains {
  param(
    [string]$BashPath,
    [string]$ArchivePath,
    [string[]]$ExpectedEntries
  )

  $archive = ConvertTo-ForwardSlashPath $ArchivePath
  $entries = @(& $BashPath "-lc" "tar -tzf '$archive'" 2>&1 | ForEach-Object {
      $entry = [string]$_
      if ($entry.StartsWith("./")) { $entry = $entry.Substring(2) }
      $entry
    })
  if ($LASTEXITCODE -ne 0) {
    throw "Could not list tar archive: $ArchivePath"
  }
  foreach ($expected in $ExpectedEntries) {
    if ($entries -notcontains $expected) {
      throw "Tar package $ArchivePath is missing expected entry: $expected"
    }
  }
}

function Invoke-ExpectPackageValidatorPowerShellSuccess {
  param(
    [string]$PackagePath,
    [string]$Mode = "standalone"
  )

  & (Join-Path $RepoRoot "scripts\windows\Test-NextJsStandalonePackage.ps1") -PackagePath $PackagePath -Mode $Mode *>&1 | Out-Null
}

function Invoke-ExpectPackageValidatorPowerShellFailure {
  param(
    [string]$PackagePath,
    [string]$ExpectedText,
    [string]$Mode = "standalone"
  )

  $failed = $false
  $captured = New-Object System.Collections.Generic.List[string]
  try {
    & (Join-Path $RepoRoot "scripts\windows\Test-NextJsStandalonePackage.ps1") -PackagePath $PackagePath -Mode $Mode *>&1 |
      ForEach-Object { $captured.Add([string]$_) | Out-Null }
  } catch {
    $failed = $true
    $captured.Add($_.Exception.Message) | Out-Null
  }

  if (-not $failed) {
    throw "Expected Windows package validator failure, but command succeeded."
  }
  $outputText = $captured -join "`n"
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package validator failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectPackageValidatorBashSuccess {
  param(
    [string]$BashPath,
    [string]$PackagePath,
    [string]$Mode = "standalone"
  )

  $output = & $BashPath "scripts/linux/validate-nextjs-standalone-package.sh" "--package-path" $PackagePath "--mode" $Mode 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "Expected Unix package validator success, but command exited with $LASTEXITCODE."
  }
}

function Invoke-ExpectPackageValidatorBashFailure {
  param(
    [string]$BashPath,
    [string]$PackagePath,
    [string]$ExpectedText,
    [string]$Mode = "standalone"
  )

  $output = & $BashPath "scripts/linux/validate-nextjs-standalone-package.sh" "--package-path" $PackagePath "--mode" $Mode 2>&1
  $outputText = ($output | Out-String)
  if ($LASTEXITCODE -eq 0) {
    throw "Expected Unix package validator failure, but command succeeded."
  }
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package validator failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectImportPowerShellSuccess {
  param(
    [string]$ConfigPath,
    [string]$PackagePath
  )

  & (Join-Path $RepoRoot "scripts\windows\Import-AppPackage.ps1") -ConfigPath $ConfigPath -PackagePath $PackagePath *>&1 | Out-Null
}

function Invoke-ExpectImportPowerShellFailure {
  param(
    [string]$ConfigPath,
    [string]$PackagePath,
    [string]$ExpectedText
  )

  $failed = $false
  $captured = New-Object System.Collections.Generic.List[string]
  try {
    & (Join-Path $RepoRoot "scripts\windows\Import-AppPackage.ps1") -ConfigPath $ConfigPath -PackagePath $PackagePath *>&1 |
      ForEach-Object { $captured.Add([string]$_) | Out-Null }
  } catch {
    $failed = $true
    $captured.Add($_.Exception.Message) | Out-Null
  }

  if (-not $failed) {
    throw "Expected Windows package import failure, but command succeeded."
  }
  $outputText = $captured -join "`n"
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package import failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectImportBashFailure {
  param(
    [string]$BashPath,
    [string]$EnvPath,
    [string]$PackagePath,
    [string]$ExpectedText
  )

  $output = & $BashPath "scripts/linux/import-app-package.sh" $EnvPath $PackagePath 2>&1
  $outputText = ($output | Out-String)
  if ($LASTEXITCODE -eq 0) {
    throw "Expected Unix package import failure, but command succeeded."
  }
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package import failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectPackagePowerShellFailure {
  param(
    [string]$ProjectPath,
    [string]$OutputPath,
    [string]$ExpectedText,
    [string]$Mode = "standalone"
  )

  $failed = $false
  $captured = New-Object System.Collections.Generic.List[string]
  try {
    & (Join-Path $RepoRoot "scripts\windows\New-NextJsStandalonePackage.ps1") -ProjectPath $ProjectPath -OutputPath $OutputPath -Mode $Mode *>&1 |
      ForEach-Object { $captured.Add([string]$_) | Out-Null }
  } catch {
    $failed = $true
    $captured.Add($_.Exception.Message) | Out-Null
  }

  if (-not $failed) {
    throw "Expected Windows package helper failure, but command succeeded."
  }
  $outputText = $captured -join "`n"
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package helper failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectPackageBashFailure {
  param(
    [string]$BashPath,
    [string]$ProjectPath,
    [string]$OutputPath,
    [string]$ExpectedText,
    [string]$Mode = "standalone",
    [string]$NodeBin = ""
  )

  $arguments = @("scripts/linux/package-nextjs-standalone.sh", "--project-path", $ProjectPath, "--output-path", $OutputPath, "--mode", $Mode)
  if (-not [string]::IsNullOrWhiteSpace($NodeBin)) {
    $arguments += @("--node-bin", $NodeBin)
  }
  $output = & $BashPath @arguments 2>&1
  $outputText = ($output | Out-String)
  if ($LASTEXITCODE -eq 0) {
    throw "Expected Unix package helper failure, but command succeeded."
  }
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected package helper failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectPowerShellSuccess {
  param(
    [string]$ScriptPath,
    [string]$ConfigPath,
    [string[]]$ExtraArgs = @("-SkipReverseProxy", "-SkipHealthCheck")
  )

  & $ScriptPath -ConfigPath $ConfigPath @ExtraArgs *>&1 | Out-Null
}

function Invoke-ExpectPowerShellFailure {
  param(
    [string]$ScriptPath,
    [string]$ConfigPath,
    [string]$ExpectedText,
    [string[]]$ExtraArgs = @("-SkipReverseProxy", "-SkipHealthCheck")
  )

  $failed = $false
  $captured = New-Object System.Collections.Generic.List[string]
  try {
    & $ScriptPath -ConfigPath $ConfigPath @ExtraArgs *>&1 |
      ForEach-Object { $captured.Add([string]$_) | Out-Null }
  } catch {
    $failed = $true
    $captured.Add($_.Exception.Message) | Out-Null
  }

  if (-not $failed) {
    throw "Expected PowerShell preflight failure, but command succeeded."
  }
  $outputText = $captured -join "`n"
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectRuntimeLayoutPowerShellSuccess {
  param([string]$ConfigPath)

  & (Join-Path $RepoRoot "scripts\windows\Test-NextJsRuntimeLayout.ps1") -ConfigPath $ConfigPath *>&1 | Out-Null
}

function Invoke-ExpectRuntimeLayoutPowerShellFailure {
  param(
    [string]$ConfigPath,
    [string]$ExpectedText
  )

  $failed = $false
  $captured = New-Object System.Collections.Generic.List[string]
  try {
    & (Join-Path $RepoRoot "scripts\windows\Test-NextJsRuntimeLayout.ps1") -ConfigPath $ConfigPath *>&1 |
      ForEach-Object { $captured.Add([string]$_) | Out-Null }
  } catch {
    $failed = $true
    $captured.Add($_.Exception.Message) | Out-Null
  }

  if (-not $failed) {
    throw "Expected Windows runtime layout failure, but command succeeded."
  }
  $outputText = $captured -join "`n"
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected runtime layout failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectBashSuccess {
  param(
    [string]$BashPath,
    [string]$EnvPath,
    [string[]]$ExtraArgs = @()
  )

  $output = & $BashPath "scripts/linux/test-deployment-preflight.sh" $EnvPath "--skip-reverse-proxy" "--skip-health-check" @ExtraArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "Expected Unix preflight success, but command exited with $LASTEXITCODE."
  }
}

function Invoke-ExpectRuntimeLayoutBashSuccess {
  param(
    [string]$BashPath,
    [string]$EnvPath
  )

  $output = & $BashPath "scripts/linux/test-nextjs-runtime-layout.sh" $EnvPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "Expected Unix runtime layout success, but command exited with $LASTEXITCODE."
  }
}

function Invoke-ExpectRuntimeLayoutBashFailure {
  param(
    [string]$BashPath,
    [string]$EnvPath,
    [string]$ExpectedText
  )

  $output = & $BashPath "scripts/linux/test-nextjs-runtime-layout.sh" $EnvPath 2>&1
  $outputText = ($output | Out-String)
  if ($LASTEXITCODE -eq 0) {
    throw "Expected Unix runtime layout failure, but command succeeded."
  }
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected runtime layout failure containing '$ExpectedText', got: $outputText"
  }
}

function Invoke-ExpectBashFailure {
  param(
    [string]$BashPath,
    [string]$EnvPath,
    [string]$ExpectedText
  )

  $output = & $BashPath "scripts/linux/test-deployment-preflight.sh" $EnvPath "--skip-reverse-proxy" "--skip-health-check" 2>&1
  $outputText = ($output | Out-String)
  if ($LASTEXITCODE -eq 0) {
    throw "Expected Unix preflight failure, but command succeeded."
  }
  if ($outputText -notmatch [regex]::Escape($ExpectedText)) {
    throw "Expected failure containing '$ExpectedText', got: $outputText"
  }
}

Write-Step "Next.js support"
Test-LinuxRuntimeEnvironmentDefaults
Test-WindowsFallbackRuntimeEnvironmentDefaults
Test-WindowsPreparationEnvironmentIsolation
Test-PostDeployDiagnosticsIncludeNextJsLayout
$testRoot = Join-Path $RepoRoot (".tmp\nextjs-support-" + [guid]::NewGuid().ToString("N"))
$windowsPreflight = Join-Path $RepoRoot "scripts\windows\Test-DeploymentPreflight.ps1"

try {
  $windowsOkRoot = Join-Path $testRoot "windows-ok"
  $windowsOkApp = Join-Path $windowsOkRoot "app"
  New-StandaloneLayout -AppDirectory $windowsOkApp
  $windowsOkConfig = Join-Path $windowsOkRoot "app.config.json"
  New-WindowsConfig -Path $windowsOkConfig -AppDirectory $windowsOkApp -ServiceDirectory (Join-Path $windowsOkRoot "svc") -LogDirectory (Join-Path $windowsOkRoot "logs") -Port 39100
  Invoke-ExpectPowerShellSuccess -ScriptPath $windowsPreflight -ConfigPath $windowsOkConfig
  Invoke-ExpectRuntimeLayoutPowerShellSuccess -ConfigPath $windowsOkConfig
  if (Test-WindowsStatusSmokeSupported) {
    $windowsStatusJson = Join-Path $windowsOkRoot "status.json"
    & (Join-Path $RepoRoot "status.ps1") -ConfigPath $windowsOkConfig -HealthTimeoutSeconds 1 -JsonPath $windowsStatusJson *>&1 | Out-Null
    $windowsStatusEvidence = Get-Content -Path $windowsStatusJson -Raw | ConvertFrom-Json
    if (-not $windowsStatusEvidence.PSObject.Properties["ConfigFileName"]) {
      throw "Windows status JSON should include ConfigFileName."
    }
    if ($windowsStatusEvidence.PSObject.Properties["ConfigPath"]) {
      throw "Windows status JSON must not include raw ConfigPath."
    }
    if ($windowsStatusEvidence.PSObject.Properties["ComputerName"]) {
      throw "Windows status JSON must not include raw ComputerName."
    }
    if ($windowsStatusEvidence.NextJsRuntime.RuntimeRootName -ne "app") {
      throw "Windows status JSON should expose RuntimeRootName instead of raw RuntimeRoot."
    }
    if ($windowsStatusEvidence.NextJsRuntime.NodeVersionSatisfied -ne $true) {
      throw "Windows status JSON should prove NodeVersionSatisfied for Next.js."
    }
    if ([string]$windowsStatusEvidence.NextJsRuntime.MinimumNodeVersion -ne "20.9.0") {
      throw "Windows status JSON should expose the configured minimum Node.js version."
    }
    if ($windowsStatusEvidence.NextJsRuntime.PSObject.Properties["RuntimeRoot"]) {
      throw "Windows status JSON must not include raw NextJsRuntime.RuntimeRoot."
    }
    if ($windowsStatusEvidence.DeploymentIdentity.AppDirectoryName -ne "app") {
      throw "Windows status JSON should expose DeploymentIdentity.AppDirectoryName."
    }
    if ($windowsStatusEvidence.DeploymentIdentity.PSObject.Properties["AppDirectory"]) {
      throw "Windows status JSON must not include raw DeploymentIdentity.AppDirectory."
    }
    Assert-FileDoesNotContainText -Path $windowsStatusJson -UnexpectedText $windowsOkApp
  } else {
    Write-Host "Skipping Windows status JSON smoke; Windows CIM/networking cmdlets are unavailable."
  }

  $windowsLegacyRoot = Join-Path $testRoot "windows-no-environment"
  $windowsLegacyApp = Join-Path $windowsLegacyRoot "app"
  New-StandaloneLayout -AppDirectory $windowsLegacyApp
  $windowsLegacyConfig = Join-Path $windowsLegacyRoot "app.config.json"
  New-WindowsConfig -Path $windowsLegacyConfig -AppDirectory $windowsLegacyApp -ServiceDirectory (Join-Path $windowsLegacyRoot "svc") -LogDirectory (Join-Path $windowsLegacyRoot "logs") -Port 39104 -NoEnvironment
  Invoke-ExpectPowerShellSuccess -ScriptPath $windowsPreflight -ConfigPath $windowsLegacyConfig

  $windowsServerRoot = Join-Path $testRoot "windows-server-winsw-iis"
  $windowsServerApp = Join-Path $windowsServerRoot "app"
  New-StandaloneLayout -AppDirectory $windowsServerApp
  $windowsServerConfig = Join-Path $windowsServerRoot "app.config.json"
  New-WindowsConfig -Path $windowsServerConfig -AppDirectory $windowsServerApp -ServiceDirectory (Join-Path $windowsServerRoot "svc") -LogDirectory (Join-Path $windowsServerRoot "logs") -Port 39117 -ServiceManager "winsw" -ReverseProxy "iis"
  Invoke-ExpectPowerShellSuccess -ScriptPath $windowsPreflight -ConfigPath $windowsServerConfig -ExtraArgs @("-SkipHealthCheck")

  $windowsBadRoot = Join-Path $testRoot "windows-missing-static"
  $windowsBadApp = Join-Path $windowsBadRoot "app"
  New-StandaloneLayout -AppDirectory $windowsBadApp -WithoutStatic
  $windowsBadConfig = Join-Path $windowsBadRoot "app.config.json"
  New-WindowsConfig -Path $windowsBadConfig -AppDirectory $windowsBadApp -ServiceDirectory (Join-Path $windowsBadRoot "svc") -LogDirectory (Join-Path $windowsBadRoot "logs") -Port 39101
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsBadConfig -ExpectedText ".next/static"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsBadConfig -ExpectedText ".next/static"

  $windowsMissingBuildIdRoot = Join-Path $testRoot "windows-missing-build-id"
  $windowsMissingBuildIdApp = Join-Path $windowsMissingBuildIdRoot "app"
  New-StandaloneLayout -AppDirectory $windowsMissingBuildIdApp
  Remove-Item -LiteralPath (Join-Path $windowsMissingBuildIdApp ".next\BUILD_ID") -Force
  $windowsMissingBuildIdConfig = Join-Path $windowsMissingBuildIdRoot "app.config.json"
  New-WindowsConfig -Path $windowsMissingBuildIdConfig -AppDirectory $windowsMissingBuildIdApp -ServiceDirectory (Join-Path $windowsMissingBuildIdRoot "svc") -LogDirectory (Join-Path $windowsMissingBuildIdRoot "logs") -Port 39124
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsMissingBuildIdConfig -ExpectedText "BUILD_ID"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsMissingBuildIdConfig -ExpectedText "BUILD_ID"

  $windowsOldNodeRoot = Join-Path $testRoot "windows-old-node"
  $windowsOldNodeApp = Join-Path $windowsOldNodeRoot "app"
  New-StandaloneLayout -AppDirectory $windowsOldNodeApp
  $windowsOldNodeConfig = Join-Path $windowsOldNodeRoot "app.config.json"
  New-WindowsConfig -Path $windowsOldNodeConfig -AppDirectory $windowsOldNodeApp -ServiceDirectory (Join-Path $windowsOldNodeRoot "svc") -LogDirectory (Join-Path $windowsOldNodeRoot "logs") -Port 39126
  $windowsOldNodeExe = Join-Path $windowsOldNodeRoot "old-node.cmd"
  Write-Utf8NoBom -Path $windowsOldNodeExe -Text "@echo off`r`nif ""%~1""==""--version"" (`r`n  echo v18.20.0`r`n  exit /b 0`r`n)`r`nexit /b 0`r`n"
  $windowsOldNodeConfigData = Get-Content -LiteralPath $windowsOldNodeConfig -Raw | ConvertFrom-Json
  $windowsOldNodeConfigData.NodeExe = $windowsOldNodeExe
  Write-Utf8NoBom -Path $windowsOldNodeConfig -Text (($windowsOldNodeConfigData | ConvertTo-Json -Depth 20) + "`n")
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsOldNodeConfig -ExpectedText "Node.js >= 20.9.0"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsOldNodeConfig -ExpectedText "Node.js >= 20.9.0"

  $windowsShellStyleStartRoot = Join-Path $testRoot "windows-shell-style-start-command"
  $windowsShellStyleStartApp = Join-Path $windowsShellStyleStartRoot "app"
  New-StandaloneLayout -AppDirectory $windowsShellStyleStartApp -WithoutStatic
  Write-Utf8NoBom -Path (Join-Path $windowsShellStyleStartApp "node server.js") -Text "console.log('placeholder');`n"
  $windowsShellStyleStartConfig = Join-Path $windowsShellStyleStartRoot "app.config.json"
  New-WindowsConfig -Path $windowsShellStyleStartConfig -AppDirectory $windowsShellStyleStartApp -ServiceDirectory (Join-Path $windowsShellStyleStartRoot "svc") -LogDirectory (Join-Path $windowsShellStyleStartRoot "logs") -Port 39125 -StartCommand "node server.js"
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsShellStyleStartConfig -ExpectedText "StartCommand must be a single file path for Next.js layout validation"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsShellStyleStartConfig -ExpectedText "StartCommand must be a single file path"
  if (Test-WindowsStatusSmokeSupported) {
    $windowsShellStyleStatusJson = Join-Path $windowsShellStyleStartRoot "status.json"
    & (Join-Path $RepoRoot "status.ps1") -ConfigPath $windowsShellStyleStartConfig -HealthTimeoutSeconds 1 -JsonPath $windowsShellStyleStatusJson *>&1 | Out-Null
    $windowsShellStyleEvidence = Get-Content -Path $windowsShellStyleStatusJson -Raw | ConvertFrom-Json
    if ($windowsShellStyleEvidence.NextJsRuntime.Status -ne "failed") {
      throw "Windows status JSON should mark shell-style StartCommand Next.js layout as failed."
    }
    if ([int]$windowsShellStyleEvidence.Critical -lt 1) {
      throw "Windows status JSON should report a critical finding for shell-style StartCommand."
    }
    if (@($windowsShellStyleEvidence.Findings | Where-Object { [string]$_.Message -match "StartCommand must be a single file path" }).Count -lt 1) {
      throw "Windows status JSON should include the shell-style StartCommand finding."
    }
  }

  $windowsNextStartRoot = Join-Path $testRoot "windows-next-start"
  $windowsNextStartApp = Join-Path $windowsNextStartRoot "app"
  New-NextStartLayout -AppDirectory $windowsNextStartApp
  $windowsNextStartConfig = Join-Path $windowsNextStartRoot "app.config.json"
  New-WindowsConfig -Path $windowsNextStartConfig -AppDirectory $windowsNextStartApp -ServiceDirectory (Join-Path $windowsNextStartRoot "svc") -LogDirectory (Join-Path $windowsNextStartRoot "logs") -Port 39105 -NextjsDeploymentMode "next-start" -StartCommand "node_modules/next/dist/bin/next"
  Invoke-ExpectPowerShellSuccess -ScriptPath $windowsPreflight -ConfigPath $windowsNextStartConfig
  Invoke-ExpectRuntimeLayoutPowerShellSuccess -ConfigPath $windowsNextStartConfig

  $windowsWrongNextCliRoot = Join-Path $testRoot "windows-next-start-wrong-cli"
  $windowsWrongNextCliApp = Join-Path $windowsWrongNextCliRoot "app"
  New-NextStartLayout -AppDirectory $windowsWrongNextCliApp
  Write-Utf8NoBom -Path (Join-Path $windowsWrongNextCliApp "node_modules\next\dist\bin\not-next") -Text "#!/usr/bin/env node`n"
  $windowsWrongNextCliConfig = Join-Path $windowsWrongNextCliRoot "app.config.json"
  New-WindowsConfig -Path $windowsWrongNextCliConfig -AppDirectory $windowsWrongNextCliApp -ServiceDirectory (Join-Path $windowsWrongNextCliRoot "svc") -LogDirectory (Join-Path $windowsWrongNextCliRoot "logs") -Port 39127 -NextjsDeploymentMode "next-start" -StartCommand "node_modules/next/dist/bin/not-next"
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsWrongNextCliConfig -ExpectedText "node_modules/next/dist/bin/next"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsWrongNextCliConfig -ExpectedText "node_modules/next/dist/bin/next"
  if (Test-WindowsStatusSmokeSupported) {
    $windowsWrongNextCliStatusJson = Join-Path $windowsWrongNextCliRoot "status.json"
    & (Join-Path $RepoRoot "status.ps1") -ConfigPath $windowsWrongNextCliConfig -HealthTimeoutSeconds 1 -JsonPath $windowsWrongNextCliStatusJson *>&1 | Out-Null
    $windowsWrongNextCliEvidence = Get-Content -Path $windowsWrongNextCliStatusJson -Raw | ConvertFrom-Json
    if ($windowsWrongNextCliEvidence.NextJsRuntime.Status -ne "failed") {
      throw "Windows status JSON should mark wrong next-start CLI path as failed."
    }
    if ($windowsWrongNextCliEvidence.NextJsRuntime.NextStartCommandIsExpectedCli -ne $false) {
      throw "Windows status JSON should prove wrong next-start CLI path is not the expected CLI."
    }
  }

  $windowsBadNextStartArgsRoot = Join-Path $testRoot "windows-next-start-missing-host-arg"
  $windowsBadNextStartArgsApp = Join-Path $windowsBadNextStartArgsRoot "app"
  New-NextStartLayout -AppDirectory $windowsBadNextStartArgsApp
  $windowsBadNextStartArgsConfig = Join-Path $windowsBadNextStartArgsRoot "app.config.json"
  New-WindowsConfig -Path $windowsBadNextStartArgsConfig -AppDirectory $windowsBadNextStartArgsApp -ServiceDirectory (Join-Path $windowsBadNextStartArgsRoot "svc") -LogDirectory (Join-Path $windowsBadNextStartArgsRoot "logs") -Port 39115 -NextjsDeploymentMode "next-start" -StartCommand "node_modules/next/dist/bin/next" -NodeArguments "start"
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsBadNextStartArgsConfig -ExpectedText "requires NodeArguments to include '-H"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsBadNextStartArgsConfig -ExpectedText "requires NodeArguments to include '-H"

  $windowsMultiInstanceRoot = Join-Path $testRoot "windows-multi-instance-ok"
  $windowsMultiInstanceApp = Join-Path $windowsMultiInstanceRoot "app"
  New-StandaloneLayout -AppDirectory $windowsMultiInstanceApp
  $windowsMultiInstanceConfig = Join-Path $windowsMultiInstanceRoot "app.config.json"
  New-WindowsConfig -Path $windowsMultiInstanceConfig -AppDirectory $windowsMultiInstanceApp -ServiceDirectory (Join-Path $windowsMultiInstanceRoot "svc") -LogDirectory (Join-Path $windowsMultiInstanceRoot "logs") -Port 39118 -RequireServerActionsEncryptionKey -RequireDeploymentId -WithMultiInstanceEnvironment
  Invoke-ExpectPowerShellSuccess -ScriptPath $windowsPreflight -ConfigPath $windowsMultiInstanceConfig

  $windowsMissingServerActionsKeyRoot = Join-Path $testRoot "windows-missing-server-actions-key"
  $windowsMissingServerActionsKeyApp = Join-Path $windowsMissingServerActionsKeyRoot "app"
  New-StandaloneLayout -AppDirectory $windowsMissingServerActionsKeyApp
  $windowsMissingServerActionsKeyConfig = Join-Path $windowsMissingServerActionsKeyRoot "app.config.json"
  New-WindowsConfig -Path $windowsMissingServerActionsKeyConfig -AppDirectory $windowsMissingServerActionsKeyApp -ServiceDirectory (Join-Path $windowsMissingServerActionsKeyRoot "svc") -LogDirectory (Join-Path $windowsMissingServerActionsKeyRoot "logs") -Port 39119 -RequireServerActionsEncryptionKey
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsMissingServerActionsKeyConfig -ExpectedText "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"

  $windowsInvalidServerActionsKeyRoot = Join-Path $testRoot "windows-invalid-server-actions-key"
  $windowsInvalidServerActionsKeyApp = Join-Path $windowsInvalidServerActionsKeyRoot "app"
  New-StandaloneLayout -AppDirectory $windowsInvalidServerActionsKeyApp
  $windowsInvalidServerActionsKeyConfig = Join-Path $windowsInvalidServerActionsKeyRoot "app.config.json"
  New-WindowsConfig -Path $windowsInvalidServerActionsKeyConfig -AppDirectory $windowsInvalidServerActionsKeyApp -ServiceDirectory (Join-Path $windowsInvalidServerActionsKeyRoot "svc") -LogDirectory (Join-Path $windowsInvalidServerActionsKeyRoot "logs") -Port 39120 -RequireServerActionsEncryptionKey -WithMultiInstanceEnvironment -ServerActionsEncryptionKey "not-base64"
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsInvalidServerActionsKeyConfig -ExpectedText "valid AES key length"

  $windowsMissingDeploymentIdRoot = Join-Path $testRoot "windows-missing-deployment-id"
  $windowsMissingDeploymentIdApp = Join-Path $windowsMissingDeploymentIdRoot "app"
  New-StandaloneLayout -AppDirectory $windowsMissingDeploymentIdApp
  $windowsMissingDeploymentIdConfig = Join-Path $windowsMissingDeploymentIdRoot "app.config.json"
  New-WindowsConfig -Path $windowsMissingDeploymentIdConfig -AppDirectory $windowsMissingDeploymentIdApp -ServiceDirectory (Join-Path $windowsMissingDeploymentIdRoot "svc") -LogDirectory (Join-Path $windowsMissingDeploymentIdRoot "logs") -Port 39121 -RequireDeploymentId
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsMissingDeploymentIdConfig -ExpectedText "NEXT_DEPLOYMENT_ID"

  $windowsBadNextStartRoot = Join-Path $testRoot "windows-next-start-missing-next"
  $windowsBadNextStartApp = Join-Path $windowsBadNextStartRoot "app"
  New-NextStartLayout -AppDirectory $windowsBadNextStartApp -WithoutNextPackage
  $windowsBadNextStartConfig = Join-Path $windowsBadNextStartRoot "app.config.json"
  New-WindowsConfig -Path $windowsBadNextStartConfig -AppDirectory $windowsBadNextStartApp -ServiceDirectory (Join-Path $windowsBadNextStartRoot "svc") -LogDirectory (Join-Path $windowsBadNextStartRoot "logs") -Port 39106 -NextjsDeploymentMode "next-start" -StartCommand "server.js"
  Write-Utf8NoBom -Path (Join-Path $windowsBadNextStartApp "server.js") -Text "console.log('placeholder');`n"
  Invoke-ExpectPowerShellFailure -ScriptPath $windowsPreflight -ConfigPath $windowsBadNextStartConfig -ExpectedText "node_modules/next"
  Invoke-ExpectRuntimeLayoutPowerShellFailure -ConfigPath $windowsBadNextStartConfig -ExpectedText "node_modules/next"

  $windowsPackageProject = Join-Path $testRoot "windows-package-project"
  New-NextProjectLayout -ProjectDirectory $windowsPackageProject -WithPublic
  $windowsPackagePath = Join-Path $testRoot "packages\example-next.zip"
  & (Join-Path $RepoRoot "scripts\windows\New-NextJsStandalonePackage.ps1") -ProjectPath $windowsPackageProject -OutputPath $windowsPackagePath | Out-Null
  Assert-ZipContains -Path $windowsPackagePath -ExpectedEntries @(
    "server.js",
    ".next/BUILD_ID",
    ".next/static/app.js",
    "node_modules/next/package.json",
    "public/robots.txt"
  )
  Invoke-ExpectPackageValidatorPowerShellSuccess -PackagePath $windowsPackagePath

  $windowsCliPackagePreflightRoot = Join-Path $testRoot "windows-cli-package-preflight"
  $windowsCliPackagePreflightConfig = Join-Path $windowsCliPackagePreflightRoot "app.config.json"
  $windowsCliPackagePreflightApp = Join-Path $windowsCliPackagePreflightRoot "missing-app"
  New-WindowsConfig -Path $windowsCliPackagePreflightConfig -AppDirectory $windowsCliPackagePreflightApp -ServiceDirectory (Join-Path $windowsCliPackagePreflightRoot "svc") -LogDirectory (Join-Path $windowsCliPackagePreflightRoot "logs") -Port 39118
  & $windowsPreflight -ConfigPath $windowsCliPackagePreflightConfig -SkipReverseProxy -SkipHealthCheck -PackagePath $windowsPackagePath *>&1 | Out-Null
  $skipPackageImportFailed = $false
  $skipPackageImportOutput = New-Object System.Collections.Generic.List[string]
  try {
    & $windowsPreflight -ConfigPath $windowsCliPackagePreflightConfig -SkipReverseProxy -SkipHealthCheck -PackagePath $windowsPackagePath -SkipPackageImport *>&1 |
      ForEach-Object { $skipPackageImportOutput.Add([string]$_) | Out-Null }
  } catch {
    $skipPackageImportFailed = $true
    $skipPackageImportOutput.Add($_.Exception.Message) | Out-Null
  }
  if (-not $skipPackageImportFailed) {
    throw "Expected Windows preflight to fail when PackagePath is provided but package import is skipped."
  }
  if (($skipPackageImportOutput -join "`n") -notmatch [regex]::Escape("AppDirectory not found")) {
    throw "Expected skipped package import preflight failure to mention AppDirectory not found, got: $($skipPackageImportOutput -join "`n")"
  }

  $windowsMissingStaticPackage = Join-Path $testRoot "packages\missing-static.zip"
  New-ZipFromDirectory -SourceDirectory $windowsBadApp -OutputPath $windowsMissingStaticPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsMissingStaticPackage -ExpectedText ".next/static"

  $windowsMissingBuildIdPackage = Join-Path $testRoot "packages\missing-build-id.zip"
  New-ZipFromDirectory -SourceDirectory $windowsMissingBuildIdApp -OutputPath $windowsMissingBuildIdPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsMissingBuildIdPackage -ExpectedText "BUILD_ID"

  $windowsNextStartPackage = Join-Path $testRoot "packages\next-start.zip"
  & (Join-Path $RepoRoot "scripts\windows\New-NextJsStandalonePackage.ps1") -ProjectPath $windowsNextStartApp -OutputPath $windowsNextStartPackage -Mode next-start | Out-Null
  Assert-ZipContains -Path $windowsNextStartPackage -ExpectedEntries @(
    "package.json",
    ".next/BUILD_ID",
    "node_modules/next/package.json",
    "node_modules/next/dist/bin/next"
  )
  Invoke-ExpectPackageValidatorPowerShellSuccess -PackagePath $windowsNextStartPackage -Mode "next-start"

  $windowsBadNextStartPackage = Join-Path $testRoot "packages\next-start-missing-next.zip"
  New-ZipFromDirectory -SourceDirectory $windowsBadNextStartApp -OutputPath $windowsBadNextStartPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsBadNextStartPackage -ExpectedText "node_modules/next" -Mode "next-start"

  $windowsMissingNextPackageJsonApp = Join-Path $testRoot "windows-next-start-missing-next-package-json\app"
  New-NextStartLayout -AppDirectory $windowsMissingNextPackageJsonApp -WithoutNextPackageJson
  $windowsMissingNextPackageJsonPackage = Join-Path $testRoot "packages\next-start-missing-next-package-json.zip"
  New-ZipFromDirectory -SourceDirectory $windowsMissingNextPackageJsonApp -OutputPath $windowsMissingNextPackageJsonPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsMissingNextPackageJsonPackage -ExpectedText "node_modules/next/package.json" -Mode "next-start"
  Invoke-ExpectPackagePowerShellFailure -ProjectPath $windowsMissingNextPackageJsonApp -OutputPath (Join-Path $testRoot "packages\next-start-helper-missing-next-package-json.zip") -ExpectedText "package metadata" -Mode "next-start"

  $windowsMissingNextCliApp = Join-Path $testRoot "windows-next-start-missing-cli\app"
  New-NextStartLayout -AppDirectory $windowsMissingNextCliApp -WithoutNextCli
  $windowsMissingNextCliPackage = Join-Path $testRoot "packages\next-start-missing-cli.zip"
  New-ZipFromDirectory -SourceDirectory $windowsMissingNextCliApp -OutputPath $windowsMissingNextCliPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsMissingNextCliPackage -ExpectedText "node_modules/next/dist/bin/next" -Mode "next-start"
  Invoke-ExpectPackagePowerShellFailure -ProjectPath $windowsMissingNextCliApp -OutputPath (Join-Path $testRoot "packages\next-start-helper-missing-cli.zip") -ExpectedText "next-start CLI file" -Mode "next-start"

  $windowsBlockedValidatorRoot = Join-Path $testRoot "windows-validator-blocked-private-file"
  New-StandaloneLayout -AppDirectory $windowsBlockedValidatorRoot
  Write-Utf8NoBom -Path (Join-Path $windowsBlockedValidatorRoot ".env.production") -Text "SECRET_VALUE=placeholder`n"
  $windowsBlockedValidatorPackage = Join-Path $testRoot "packages\validator-blocked.zip"
  New-ZipFromDirectory -SourceDirectory $windowsBlockedValidatorRoot -OutputPath $windowsBlockedValidatorPackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsBlockedValidatorPackage -ExpectedText "blocked private file"

  $windowsUnsafeTypePackage = Join-Path $testRoot "packages\unsafe-symlink-attribute.zip"
  New-ZipWithUnsafeUnixSymlinkEntry -OutputPath $windowsUnsafeTypePackage
  Invoke-ExpectPackageValidatorPowerShellFailure -PackagePath $windowsUnsafeTypePackage -ExpectedText "Unsafe archive entry type"

  $windowsImportRoot = Join-Path $testRoot "windows-import"
  $windowsImportConfig = Join-Path $windowsImportRoot "app.config.json"
  $windowsImportApp = Join-Path $windowsImportRoot "app"
  New-WindowsConfig -Path $windowsImportConfig -AppDirectory $windowsImportApp -ServiceDirectory (Join-Path $windowsImportRoot "svc") -LogDirectory (Join-Path $windowsImportRoot "logs") -Port 39109 -RequirePackageProvenance
  Invoke-ExpectImportPowerShellSuccess -ConfigPath $windowsImportConfig -PackagePath $windowsPackagePath
  if (-not (Test-Path -LiteralPath (Join-Path $windowsImportApp "server.js") -PathType Leaf)) {
    throw "Windows package import did not place server.js into AppDirectory."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $windowsImportApp ".next\static") -PathType Container)) {
    throw "Windows package import did not place .next/static into AppDirectory."
  }
  if (Test-Path -LiteralPath (Join-Path $windowsImportApp ".node-enterprise-package.json") -PathType Leaf) {
    throw "Windows package provenance marker must not be copied into AppDirectory."
  }
  $windowsImportManifest = Join-Path $windowsImportApp ".node-enterprise-deploy.json"
  if (-not (Test-Path -LiteralPath $windowsImportManifest -PathType Leaf)) {
    throw "Windows package import did not write deployment manifest."
  }
  $windowsImportManifestEvidence = Get-Content -Path $windowsImportManifest -Raw | ConvertFrom-Json
  $windowsPackageSha256 = (Get-FileHash -LiteralPath $windowsPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($windowsImportManifestEvidence.packageName -ne (Split-Path -Leaf $windowsPackagePath)) {
    throw "Windows deployment manifest should store only the package file name."
  }
  if ($windowsImportManifestEvidence.packageSha256 -ne $windowsPackageSha256) {
    throw "Windows deployment manifest package SHA256 does not match imported package."
  }
  if ($windowsImportManifestEvidence.nextBuildId -ne "example-build") {
    throw "Windows deployment manifest should include the imported Next.js build ID."
  }
  if ($windowsImportManifestEvidence.packageProvenance.buildPlatform -ne "windows") {
    throw "Windows deployment manifest should include verified Windows package provenance."
  }
  $currentNodeAbi = (& node -p "process.versions.modules" | Out-String).Trim()
  if ($windowsImportManifestEvidence.packageProvenance.nodeModuleAbi -ne $currentNodeAbi) {
    throw "Windows deployment manifest should include the verified target Node native module ABI."
  }
  Assert-FileDoesNotContainText -Path $windowsImportManifest -UnexpectedText $windowsPackagePath
  Assert-FileDoesNotContainText -Path $windowsImportManifest -UnexpectedText $windowsImportRoot

  $windowsWrongPlatformRoot = Join-Path $testRoot "windows-package-wrong-platform"
  Expand-Archive -LiteralPath $windowsPackagePath -DestinationPath $windowsWrongPlatformRoot -Force
  $windowsWrongPlatformMarker = Join-Path $windowsWrongPlatformRoot ".node-enterprise-package.json"
  $windowsWrongPlatformProvenance = Get-Content -LiteralPath $windowsWrongPlatformMarker -Raw | ConvertFrom-Json
  $windowsWrongPlatformProvenance.buildPlatform = "linux"
  Write-Utf8NoBom -Path $windowsWrongPlatformMarker -Text (($windowsWrongPlatformProvenance | ConvertTo-Json -Depth 10) + "`n")
  $windowsWrongPlatformPackage = Join-Path $testRoot "packages\wrong-platform.zip"
  New-ZipFromDirectory -SourceDirectory $windowsWrongPlatformRoot -OutputPath $windowsWrongPlatformPackage
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsImportConfig -PackagePath $windowsWrongPlatformPackage -ExpectedText "built for 'linux'"

  $windowsWrongNodeAbiRoot = Join-Path $testRoot "windows-package-wrong-node-abi"
  Expand-Archive -LiteralPath $windowsPackagePath -DestinationPath $windowsWrongNodeAbiRoot -Force
  $windowsWrongNodeAbiMarker = Join-Path $windowsWrongNodeAbiRoot ".node-enterprise-package.json"
  $windowsWrongNodeAbiProvenance = Get-Content -LiteralPath $windowsWrongNodeAbiMarker -Raw | ConvertFrom-Json
  $windowsWrongNodeAbiProvenance.nodeModuleAbi = "0"
  Write-Utf8NoBom -Path $windowsWrongNodeAbiMarker -Text (($windowsWrongNodeAbiProvenance | ConvertTo-Json -Depth 10) + "`n")
  $windowsWrongNodeAbiPackage = Join-Path $testRoot "packages\wrong-node-abi.zip"
  New-ZipFromDirectory -SourceDirectory $windowsWrongNodeAbiRoot -OutputPath $windowsWrongNodeAbiPackage
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsImportConfig -PackagePath $windowsWrongNodeAbiPackage -ExpectedText "native module ABI '0' does not match target Node ABI"

  $windowsMissingProvenanceRoot = Join-Path $testRoot "windows-package-missing-provenance"
  New-StandaloneLayout -AppDirectory $windowsMissingProvenanceRoot
  $windowsMissingProvenancePackage = Join-Path $testRoot "packages\missing-provenance.zip"
  New-ZipFromDirectory -SourceDirectory $windowsMissingProvenanceRoot -OutputPath $windowsMissingProvenancePackage
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsImportConfig -PackagePath $windowsMissingProvenancePackage -ExpectedText "package provenance is required"

  if (Test-WindowsStatusSmokeSupported) {
    $windowsImportStatusJson = Join-Path $windowsImportRoot "status-import.json"
    & (Join-Path $RepoRoot "status.ps1") -ConfigPath $windowsImportConfig -HealthTimeoutSeconds 1 -JsonPath $windowsImportStatusJson *>&1 | Out-Null
    $windowsImportStatusEvidence = Get-Content -Path $windowsImportStatusJson -Raw | ConvertFrom-Json
    if (-not $windowsImportStatusEvidence.DeploymentIdentity.ManifestExists) {
      throw "Windows status JSON should prove the deployment manifest exists."
    }
    if ($windowsImportStatusEvidence.DeploymentIdentity.PackageName -ne (Split-Path -Leaf $windowsPackagePath)) {
      throw "Windows status JSON should include the imported package file name."
    }
    if ($windowsImportStatusEvidence.DeploymentIdentity.PackageSha256 -ne $windowsPackageSha256) {
      throw "Windows status JSON should include the imported package SHA256."
    }
    if ($windowsImportStatusEvidence.DeploymentIdentity.PackageProvenance.BuildPlatform -ne "windows") {
      throw "Windows status JSON should include the verified package build platform."
    }
    if ($windowsImportStatusEvidence.DeploymentIdentity.PackageProvenance.NodeModuleAbi -ne $currentNodeAbi) {
      throw "Windows status JSON should include the verified package Node native module ABI."
    }
    Assert-FileDoesNotContainText -Path $windowsImportStatusJson -UnexpectedText $windowsPackagePath
    Assert-FileDoesNotContainText -Path $windowsImportStatusJson -UnexpectedText $windowsImportRoot
  } else {
    Write-Host "Skipping Windows import status JSON smoke; Windows CIM/networking cmdlets are unavailable."
  }

  $windowsNextStartImportRoot = Join-Path $testRoot "windows-next-start-import"
  $windowsNextStartImportConfig = Join-Path $windowsNextStartImportRoot "app.config.json"
  $windowsNextStartImportApp = Join-Path $windowsNextStartImportRoot "app"
  New-WindowsConfig -Path $windowsNextStartImportConfig -AppDirectory $windowsNextStartImportApp -ServiceDirectory (Join-Path $windowsNextStartImportRoot "svc") -LogDirectory (Join-Path $windowsNextStartImportRoot "logs") -Port 39113 -NextjsDeploymentMode "next-start" -StartCommand "node_modules/next/dist/bin/next"
  Invoke-ExpectImportPowerShellSuccess -ConfigPath $windowsNextStartImportConfig -PackagePath $windowsNextStartPackage
  if (-not (Test-Path -LiteralPath (Join-Path $windowsNextStartImportApp "package.json") -PathType Leaf)) {
    throw "Windows next-start import did not place package.json into AppDirectory."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $windowsNextStartImportApp "node_modules\next") -PathType Container)) {
    throw "Windows next-start import did not place node_modules/next into AppDirectory."
  }
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsNextStartImportConfig -PackagePath $windowsBadNextStartPackage -ExpectedText "node_modules/next"

  $windowsBlockedPackageProject = Join-Path $testRoot "windows-package-blocked-private-file"
  New-NextProjectLayout -ProjectDirectory $windowsBlockedPackageProject
  Write-Utf8NoBom -Path (Join-Path $windowsBlockedPackageProject ".next\standalone\.env.production") -Text "SECRET_VALUE=placeholder`n"
  Invoke-ExpectPackagePowerShellFailure -ProjectPath $windowsBlockedPackageProject -OutputPath (Join-Path $testRoot "packages\blocked.zip") -ExpectedText "blocked private file"
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsImportConfig -PackagePath $windowsBlockedValidatorPackage -ExpectedText "blocked private file"
  Invoke-ExpectImportPowerShellFailure -ConfigPath $windowsImportConfig -PackagePath $windowsUnsafeTypePackage -ExpectedText "Unsafe archive entry type"

  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($bash) {
    Push-Location $RepoRoot
    try {
      $unixOkRoot = Join-Path $testRoot "unix-ok"
      $unixOkRel = Get-RepoRelativePath $unixOkRoot
      $unixOkApp = Join-Path $unixOkRoot "app"
      New-StandaloneLayout -AppDirectory $unixOkApp
      $unixOkEnv = Join-Path $unixOkRoot "app.env"
      New-UnixEnv -Path $unixOkEnv -RelativeRoot $unixOkRel -Port 39102
      Invoke-ExpectBashSuccess -BashPath $bash.Source -EnvPath "$unixOkRel/app.env"
      Invoke-ExpectRuntimeLayoutBashSuccess -BashPath $bash.Source -EnvPath "$unixOkRel/app.env"

      $unixBadRoot = Join-Path $testRoot "unix-missing-static"
      $unixBadRel = Get-RepoRelativePath $unixBadRoot
      $unixBadApp = Join-Path $unixBadRoot "app"
      New-StandaloneLayout -AppDirectory $unixBadApp -WithoutStatic
      $unixBadEnv = Join-Path $unixBadRoot "app.env"
      New-UnixEnv -Path $unixBadEnv -RelativeRoot $unixBadRel -Port 39103
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixBadRel/app.env" -ExpectedText ".next/static"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixBadRel/app.env" -ExpectedText ".next/static"

      $unixMissingBuildIdRoot = Join-Path $testRoot "unix-missing-build-id"
      $unixMissingBuildIdRel = Get-RepoRelativePath $unixMissingBuildIdRoot
      $unixMissingBuildIdApp = Join-Path $unixMissingBuildIdRoot "app"
      New-StandaloneLayout -AppDirectory $unixMissingBuildIdApp
      Remove-Item -LiteralPath (Join-Path $unixMissingBuildIdApp ".next\BUILD_ID") -Force
      $unixMissingBuildIdEnv = Join-Path $unixMissingBuildIdRoot "app.env"
      New-UnixEnv -Path $unixMissingBuildIdEnv -RelativeRoot $unixMissingBuildIdRel -Port 39125
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixMissingBuildIdRel/app.env" -ExpectedText "BUILD_ID"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixMissingBuildIdRel/app.env" -ExpectedText "BUILD_ID"

      $unixOldNodeRoot = Join-Path $testRoot "unix-old-node"
      $unixOldNodeRel = Get-RepoRelativePath $unixOldNodeRoot
      $unixOldNodeApp = Join-Path $unixOldNodeRoot "app"
      New-StandaloneLayout -AppDirectory $unixOldNodeApp
      $unixOldNodeEnv = Join-Path $unixOldNodeRoot "app.env"
      New-UnixEnv -Path $unixOldNodeEnv -RelativeRoot $unixOldNodeRel -Port 39126
      Write-Utf8NoBom -Path (Join-Path $unixOldNodeRoot "fake-node.sh") -Text "#!/bin/sh`nif [ ""`${1:-}"" = ""--version"" ]; then`n  echo v18.20.0`n  exit 0`nfi`nexit 0`n"
      & $bash.Source "-lc" "chmod +x '$unixOldNodeRel/fake-node.sh'" | Out-Null
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixOldNodeRel/app.env" -ExpectedText "Node.js >= 20.9.0"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixOldNodeRel/app.env" -ExpectedText "Node.js >= 20.9.0"

      $unixNextStartRoot = Join-Path $testRoot "unix-next-start"
      $unixNextStartRel = Get-RepoRelativePath $unixNextStartRoot
      $unixNextStartApp = Join-Path $unixNextStartRoot "app"
      New-NextStartLayout -AppDirectory $unixNextStartApp
      & $bash.Source "-lc" "mkdir -p '$unixNextStartRel/app/node_modules/.bin' && ln -sf '../next/dist/bin/next' '$unixNextStartRel/app/node_modules/.bin/next' 2>/dev/null || true" | Out-Null
      $unixNextStartEnv = Join-Path $unixNextStartRoot "app.env"
      New-UnixEnv -Path $unixNextStartEnv -RelativeRoot $unixNextStartRel -Port 39107 -NextjsDeploymentMode "next-start" -StartScript "node_modules/next/dist/bin/next"
      Invoke-ExpectBashSuccess -BashPath $bash.Source -EnvPath "$unixNextStartRel/app.env"
      Invoke-ExpectRuntimeLayoutBashSuccess -BashPath $bash.Source -EnvPath "$unixNextStartRel/app.env"
      $unixNextStartStatusJson = Join-Path $unixNextStartRoot "status.json"
      & $bash.Source "scripts/linux/status-node-app.sh" "$unixNextStartRel/app.env" "--skip-service-manager-check" "--skip-port-check" "--skip-health-check" "--json-output" "$unixNextStartRel/status.json" | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Unix next-start status JSON command failed."
      }
      $unixNextStartStatusEvidence = Get-Content -Path $unixNextStartStatusJson -Raw | ConvertFrom-Json
      if ($unixNextStartStatusEvidence.nextJsRuntime.nextStartScriptIsExpectedCli -ne $true) {
        throw "Unix status JSON should prove next-start uses node_modules/next/dist/bin/next."
      }

      $unixWrongNextCliRoot = Join-Path $testRoot "unix-next-start-wrong-cli"
      $unixWrongNextCliRel = Get-RepoRelativePath $unixWrongNextCliRoot
      $unixWrongNextCliApp = Join-Path $unixWrongNextCliRoot "app"
      New-NextStartLayout -AppDirectory $unixWrongNextCliApp
      Write-Utf8NoBom -Path (Join-Path $unixWrongNextCliApp "node_modules\next\dist\bin\not-next") -Text "#!/usr/bin/env node`n"
      $unixWrongNextCliEnv = Join-Path $unixWrongNextCliRoot "app.env"
      New-UnixEnv -Path $unixWrongNextCliEnv -RelativeRoot $unixWrongNextCliRel -Port 39127 -NextjsDeploymentMode "next-start" -StartScript "node_modules/next/dist/bin/not-next"
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixWrongNextCliRel/app.env" -ExpectedText "node_modules/next/dist/bin/next"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixWrongNextCliRel/app.env" -ExpectedText "node_modules/next/dist/bin/next"
      $unixWrongNextCliStatusJson = Join-Path $unixWrongNextCliRoot "status.json"
      & $bash.Source "scripts/linux/status-node-app.sh" "$unixWrongNextCliRel/app.env" "--skip-service-manager-check" "--skip-port-check" "--skip-health-check" "--json-output" "$unixWrongNextCliRel/status.json" | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Unix wrong next-start CLI status JSON command failed."
      }
      $unixWrongNextCliStatusEvidence = Get-Content -Path $unixWrongNextCliStatusJson -Raw | ConvertFrom-Json
      if ($unixWrongNextCliStatusEvidence.nextJsRuntime.status -ne "failed") {
        throw "Unix status JSON should mark wrong next-start CLI path as failed."
      }
      if ($unixWrongNextCliStatusEvidence.nextJsRuntime.nextStartScriptIsExpectedCli -ne $false) {
        throw "Unix status JSON should prove wrong next-start CLI path is not the expected CLI."
      }

      $unixBadNextStartArgsRoot = Join-Path $testRoot "unix-next-start-missing-host-arg"
      $unixBadNextStartArgsRel = Get-RepoRelativePath $unixBadNextStartArgsRoot
      $unixBadNextStartArgsApp = Join-Path $unixBadNextStartArgsRoot "app"
      New-NextStartLayout -AppDirectory $unixBadNextStartArgsApp
      $unixBadNextStartArgsEnv = Join-Path $unixBadNextStartArgsRoot "app.env"
      New-UnixEnv -Path $unixBadNextStartArgsEnv -RelativeRoot $unixBadNextStartArgsRel -Port 39116 -NextjsDeploymentMode "next-start" -StartScript "node_modules/next/dist/bin/next" -NodeArguments "start"
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixBadNextStartArgsRel/app.env" -ExpectedText "requires NODE_ARGUMENTS to include '-H"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixBadNextStartArgsRel/app.env" -ExpectedText "requires NODE_ARGUMENTS to include '-H"

      $unixMissingServerActionsKeyRoot = Join-Path $testRoot "unix-missing-server-actions-key"
      $unixMissingServerActionsKeyRel = Get-RepoRelativePath $unixMissingServerActionsKeyRoot
      $unixMissingServerActionsKeyApp = Join-Path $unixMissingServerActionsKeyRoot "app"
      New-StandaloneLayout -AppDirectory $unixMissingServerActionsKeyApp
      $unixMissingServerActionsKeyEnv = Join-Path $unixMissingServerActionsKeyRoot "app.env"
      New-UnixEnv -Path $unixMissingServerActionsKeyEnv -RelativeRoot $unixMissingServerActionsKeyRel -Port 39122 -RequireServerActionsEncryptionKey
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixMissingServerActionsKeyRel/app.env" -ExpectedText "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"

      $unixMissingDeploymentIdRoot = Join-Path $testRoot "unix-missing-deployment-id"
      $unixMissingDeploymentIdRel = Get-RepoRelativePath $unixMissingDeploymentIdRoot
      $unixMissingDeploymentIdApp = Join-Path $unixMissingDeploymentIdRoot "app"
      New-StandaloneLayout -AppDirectory $unixMissingDeploymentIdApp
      $unixMissingDeploymentIdEnv = Join-Path $unixMissingDeploymentIdRoot "app.env"
      New-UnixEnv -Path $unixMissingDeploymentIdEnv -RelativeRoot $unixMissingDeploymentIdRel -Port 39123 -RequireDeploymentId
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixMissingDeploymentIdRel/app.env" -ExpectedText "NEXT_DEPLOYMENT_ID"

      $unixLaunchdRoot = Join-Path $testRoot "unix-launchd"
      $unixLaunchdRel = Get-RepoRelativePath $unixLaunchdRoot
      $unixLaunchdApp = Join-Path $unixLaunchdRoot "app"
      New-StandaloneLayout -AppDirectory $unixLaunchdApp
      $unixLaunchdEnv = Join-Path $unixLaunchdRoot "app.env"
      New-UnixEnv -Path $unixLaunchdEnv -RelativeRoot $unixLaunchdRel -Port 39111 -ServiceManager "launchd"
      Invoke-ExpectBashSuccess -BashPath $bash.Source -EnvPath "$unixLaunchdRel/app.env" -ExtraArgs @("--skip-service-manager-check")

      $unixBsdRoot = Join-Path $testRoot "unix-bsdrc"
      $unixBsdRel = Get-RepoRelativePath $unixBsdRoot
      $unixBsdApp = Join-Path $unixBsdRoot "app"
      New-StandaloneLayout -AppDirectory $unixBsdApp
      $unixBsdEnv = Join-Path $unixBsdRoot "app.env"
      New-UnixEnv -Path $unixBsdEnv -RelativeRoot $unixBsdRel -Port 39112 -ServiceManager "bsdrc"
      Invoke-ExpectBashSuccess -BashPath $bash.Source -EnvPath "$unixBsdRel/app.env" -ExtraArgs @("--skip-service-manager-check")

      $unixBadNextStartRoot = Join-Path $testRoot "unix-next-start-missing-next"
      $unixBadNextStartRel = Get-RepoRelativePath $unixBadNextStartRoot
      $unixBadNextStartApp = Join-Path $unixBadNextStartRoot "app"
      New-NextStartLayout -AppDirectory $unixBadNextStartApp -WithoutNextPackage
      Write-Utf8NoBom -Path (Join-Path $unixBadNextStartApp "server.js") -Text "console.log('placeholder');`n"
      $unixBadNextStartEnv = Join-Path $unixBadNextStartRoot "app.env"
      New-UnixEnv -Path $unixBadNextStartEnv -RelativeRoot $unixBadNextStartRel -Port 39108 -NextjsDeploymentMode "next-start" -StartScript "server.js"
      Invoke-ExpectBashFailure -BashPath $bash.Source -EnvPath "$unixBadNextStartRel/app.env" -ExpectedText "node_modules/next"
      Invoke-ExpectRuntimeLayoutBashFailure -BashPath $bash.Source -EnvPath "$unixBadNextStartRel/app.env" -ExpectedText "node_modules/next"

      $unixPackageRoot = Join-Path $testRoot "unix-package-project"
      $unixPackageRel = Get-RepoRelativePath $unixPackageRoot
      New-NextProjectLayout -ProjectDirectory $unixPackageRoot -WithPublic
      $unixPackageNode = Join-Path $unixPackageRoot "package-node.sh"
      $unixPackageNodeRel = "$unixPackageRel/package-node.sh"
      Write-Utf8NoBom -Path $unixPackageNode -Text "#!/bin/sh`nif [ ""`${1:-}"" = ""-p"" ] && [ ""`${2:-}"" = ""process.versions.modules"" ]; then`n  echo 115`n  exit 0`nfi`nexit 1`n"
      & $bash.Source "-lc" "chmod +x '$unixPackageNodeRel'" | Out-Null
      $unixPackageOutput = Join-Path $testRoot "packages\example-next.tar.gz"
      $unixPackageOutputRel = Get-RepoRelativePath $unixPackageOutput
      & $bash.Source "scripts/linux/package-nextjs-standalone.sh" "--project-path" $unixPackageRel "--output-path" $unixPackageOutputRel "--node-bin" $unixPackageNodeRel | Out-Null
      Assert-TarContains -BashPath $bash.Source -ArchivePath $unixPackageOutputRel -ExpectedEntries @(
        "server.js",
        ".next/BUILD_ID",
        ".next/static/app.js",
        "node_modules/next/package.json",
        "public/robots.txt"
      )
      Invoke-ExpectPackageValidatorBashSuccess -BashPath $bash.Source -PackagePath $unixPackageOutputRel

      $unixNextStartPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\next-start.tar.gz")
      & $bash.Source "scripts/linux/package-nextjs-standalone.sh" "--project-path" "$unixNextStartRel/app" "--output-path" $unixNextStartPackage "--mode" "next-start" "--node-bin" $unixPackageNodeRel | Out-Null
      Assert-TarContains -BashPath $bash.Source -ArchivePath $unixNextStartPackage -ExpectedEntries @(
        "package.json",
        ".next/BUILD_ID",
        "node_modules/next/package.json",
        "node_modules/next/dist/bin/next"
      )
      & $bash.Source "-lc" "if tar -tzf '$unixNextStartPackage' | grep -Eq '(^|[.]/)node_modules/[.]bin/'; then exit 1; fi" | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Unix next-start package helper should not include node_modules/.bin symlink entries."
      }
      Invoke-ExpectPackageValidatorBashSuccess -BashPath $bash.Source -PackagePath $unixNextStartPackage -Mode "next-start"

      $unixBadNextStartPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\next-start-missing-next.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixBadNextStartRel/app' -czf '$unixBadNextStartPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixBadNextStartPackage -ExpectedText "node_modules/next" -Mode "next-start"

      $unixMissingNextPackageJsonRoot = Join-Path $testRoot "unix-next-start-missing-next-package-json"
      $unixMissingNextPackageJsonRel = Get-RepoRelativePath $unixMissingNextPackageJsonRoot
      New-NextStartLayout -AppDirectory (Join-Path $unixMissingNextPackageJsonRoot "app") -WithoutNextPackageJson
      $unixMissingNextPackageJsonPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\next-start-missing-next-package-json.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixMissingNextPackageJsonRel/app' -czf '$unixMissingNextPackageJsonPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixMissingNextPackageJsonPackage -ExpectedText "node_modules/next/package.json" -Mode "next-start"
      Invoke-ExpectPackageBashFailure -BashPath $bash.Source -ProjectPath "$unixMissingNextPackageJsonRel/app" -OutputPath (Get-RepoRelativePath (Join-Path $testRoot "packages\next-start-helper-missing-next-package-json.tar.gz")) -ExpectedText "package metadata" -Mode "next-start" -NodeBin $unixPackageNodeRel

      $unixMissingNextCliRoot = Join-Path $testRoot "unix-next-start-missing-cli"
      $unixMissingNextCliRel = Get-RepoRelativePath $unixMissingNextCliRoot
      New-NextStartLayout -AppDirectory (Join-Path $unixMissingNextCliRoot "app") -WithoutNextCli
      $unixMissingNextCliPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\next-start-missing-cli.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixMissingNextCliRel/app' -czf '$unixMissingNextCliPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixMissingNextCliPackage -ExpectedText "node_modules/next/dist/bin/next" -Mode "next-start"
      Invoke-ExpectPackageBashFailure -BashPath $bash.Source -ProjectPath "$unixMissingNextCliRel/app" -OutputPath (Get-RepoRelativePath (Join-Path $testRoot "packages\next-start-helper-missing-cli.tar.gz")) -ExpectedText "next-start CLI file" -Mode "next-start" -NodeBin $unixPackageNodeRel

      $unixUnsafeLinkRoot = Join-Path $testRoot "unix-validator-unsafe-link"
      $unixUnsafeLinkRel = Get-RepoRelativePath $unixUnsafeLinkRoot
      New-StandaloneLayout -AppDirectory $unixUnsafeLinkRoot
      $unixUnsafeLinkPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\unsafe-link.tar.gz")
      & $bash.Source "-lc" "ln -s /etc/passwd '$unixUnsafeLinkRel/unsafe-link' 2>/dev/null && test -L '$unixUnsafeLinkRel/unsafe-link'" | Out-Null
      if ($LASTEXITCODE -eq 0) {
        & $bash.Source "-lc" "tar -C '$unixUnsafeLinkRel' -czf '$unixUnsafeLinkPackage' ." | Out-Null
        Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixUnsafeLinkPackage -ExpectedText "Unsafe tar link entry"

        $unixUnsafeHelperRoot = Join-Path $testRoot "unix-package-helper-unsafe-link"
        $unixUnsafeHelperRel = Get-RepoRelativePath $unixUnsafeHelperRoot
        New-NextProjectLayout -ProjectDirectory $unixUnsafeHelperRoot
        & $bash.Source "-lc" "ln -s /etc/passwd '$unixUnsafeHelperRel/.next/standalone/unsafe-link'" | Out-Null
        Invoke-ExpectPackageBashFailure -BashPath $bash.Source -ProjectPath $unixUnsafeHelperRel -OutputPath (Get-RepoRelativePath (Join-Path $testRoot "packages\unsafe-helper.tar.gz")) -ExpectedText "Unsafe tar link entry" -NodeBin $unixPackageNodeRel
      } else {
        Write-Host "Skipping unsafe symlink package check; this shell cannot create real symlinks."
      }

      $unixMissingStaticPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\missing-static.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixBadRel/app' -czf '$unixMissingStaticPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixMissingStaticPackage -ExpectedText ".next/static"

      $unixMissingBuildIdPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\missing-build-id.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixMissingBuildIdRel/app' -czf '$unixMissingBuildIdPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixMissingBuildIdPackage -ExpectedText "BUILD_ID"

      $unixBlockedValidatorRoot = Join-Path $testRoot "unix-validator-blocked-private-file"
      $unixBlockedValidatorRel = Get-RepoRelativePath $unixBlockedValidatorRoot
      New-StandaloneLayout -AppDirectory $unixBlockedValidatorRoot
      Write-Utf8NoBom -Path (Join-Path $unixBlockedValidatorRoot ".env.production") -Text "SECRET_VALUE=placeholder`n"
      $unixBlockedValidatorPackage = Get-RepoRelativePath (Join-Path $testRoot "packages\validator-blocked.tar.gz")
      & $bash.Source "-lc" "tar -C '$unixBlockedValidatorRel' -czf '$unixBlockedValidatorPackage' ." | Out-Null
      Invoke-ExpectPackageValidatorBashFailure -BashPath $bash.Source -PackagePath $unixBlockedValidatorPackage -ExpectedText "blocked private file"

      $unixImportRoot = Join-Path $testRoot "unix-import"
      $unixImportRel = Get-RepoRelativePath $unixImportRoot
      $unixImportEnv = Join-Path $unixImportRoot "app.env"
      New-UnixEnv -Path $unixImportEnv -RelativeRoot $unixImportRel -Port 39110
      Invoke-ExpectImportBashFailure -BashPath $bash.Source -EnvPath "$unixImportRel/app.env" -PackagePath "../packages/validator-blocked.tar.gz" -ExpectedText "blocked private file"

      $unixNextStartImportRoot = Join-Path $testRoot "unix-next-start-import"
      $unixNextStartImportRel = Get-RepoRelativePath $unixNextStartImportRoot
      $unixNextStartImportEnv = Join-Path $unixNextStartImportRoot "app.env"
      New-UnixEnv -Path $unixNextStartImportEnv -RelativeRoot $unixNextStartImportRel -Port 39114 -NextjsDeploymentMode "next-start" -StartScript "node_modules/next/dist/bin/next"
      Invoke-ExpectImportBashFailure -BashPath $bash.Source -EnvPath "$unixNextStartImportRel/app.env" -PackagePath "../packages/next-start-missing-next.tar.gz" -ExpectedText "node_modules/next"

      $unixBlockedPackageRoot = Join-Path $testRoot "unix-package-blocked-private-file"
      $unixBlockedPackageRel = Get-RepoRelativePath $unixBlockedPackageRoot
      New-NextProjectLayout -ProjectDirectory $unixBlockedPackageRoot
      Write-Utf8NoBom -Path (Join-Path $unixBlockedPackageRoot ".next\standalone\.env.production") -Text "SECRET_VALUE=placeholder`n"
      Invoke-ExpectPackageBashFailure -BashPath $bash.Source -ProjectPath $unixBlockedPackageRel -OutputPath (Get-RepoRelativePath (Join-Path $testRoot "packages\blocked.tar.gz")) -ExpectedText "blocked private file" -NodeBin $unixPackageNodeRel
    }
    finally {
      Pop-Location
    }
  } else {
    Write-Host "bash was not found; skipping Unix Next.js preflight smoke checks."
  }

  Write-Host "Next.js support checks OK"
}
finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
