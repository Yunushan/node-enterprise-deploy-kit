param(
  [switch]$SkipShellRenderedSyntax,
  [switch]$SkipAnsibleSyntax
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Get-RelativePath {
  param([string]$Path)
  return $Path.Substring($RepoRoot.Length + 1).Replace("\", "/")
}

function Assert-RequiredValue {
  param(
    [hashtable]$Values,
    [string[]]$Keys,
    [string]$Source
  )

  foreach ($key in $Keys) {
    if (-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
      throw "$Source is missing required value: $key"
    }
  }
}

function ConvertTo-StringMap {
  param([object]$Object)

  $map = @{}
  foreach ($property in $Object.PSObject.Properties) {
    $map[$property.Name] = [string]$property.Value
  }
  return $map
}

function Read-EnvExample {
  param([string]$Path)

  $values = @{}
  $lineNumber = 0
  foreach ($line in Get-Content -Path $Path) {
    $lineNumber++
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
    if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      throw "$(Get-RelativePath $Path):$lineNumber is not KEY=value syntax."
    }

    $key = $Matches[1]
    $value = $Matches[2].Trim()
    if ($values.ContainsKey($key)) {
      throw "$(Get-RelativePath $Path):$lineNumber duplicates $key."
    }

    if (
      ($value.StartsWith('"') -and $value.EndsWith('"')) -or
      ($value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $values[$key] = $value
  }

  return $values
}

function Assert-Port {
  param(
    [string]$Value,
    [string]$Name
  )

  $port = 0
  if (-not [int]::TryParse($Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    throw "$Name must be an integer between 1 and 65535."
  }
}

function Assert-IntegerAtLeast {
  param(
    [string]$Value,
    [string]$Name,
    [int]$Minimum = 1
  )

  $number = 0
  if (-not [int]::TryParse($Value, [ref]$number) -or $number -lt $Minimum) {
    throw "$Name must be an integer >= $Minimum."
  }
}

function Assert-BoolString {
  param(
    [string]$Value,
    [string]$Name
  )

  if ($Value -notin @("true", "false")) {
    throw "$Name must be true or false."
  }
}

function Test-WindowsExampleConfig {
  param(
    [string]$RelativePath = "config/windows/app.config.example.json",
    [string]$Label = "Windows example config",
    [string]$ExpectedNextjsMode = "",
    [string]$ExpectedStartCommand = "",
    [string]$ExpectedNodeArguments = ""
  )

  Write-Step $Label
  $path = Join-Path $RepoRoot $RelativePath
  $relativePathForMessage = Get-RelativePath $path
  $config = Get-Content -Path $path -Raw | ConvertFrom-Json
  $values = ConvertTo-StringMap $config

  Assert-RequiredValue $values @(
    "AppName",
    "DisplayName",
    "Description",
    "DeploymentMode",
    "AppFramework",
    "NextjsDeploymentMode",
    "ReactDocumentRoot",
    "NextjsRequireStaticAssets",
    "NextjsRequirePublicDirectory",
    "NextjsRequireServerActionsEncryptionKey",
    "NextjsRequireDeploymentId",
    "NextjsMinimumNodeVersion",
    "ServiceManager",
    "ReverseProxy",
    "AutoDownloadWinSW",
    "WinSWDownloadUrl",
    "RequireWinSWDownloadSha256",
    "AppDirectory",
    "StartCommand",
    "NodeExe",
    "Port",
    "BindAddress",
    "HealthUrl",
    "ServiceDirectory",
    "LogDirectory",
    "BackupDirectory",
    "IisEnableArrProxy",
    "IisRequireUrlRewrite",
    "IisRequireArrProxy",
    "IisSetForwardedHeaders",
    "IisHealthProxyPath",
    "IisWebSocketSupport",
    "IisProxyTimeoutSeconds",
    "ServiceAccount"
  ) $relativePathForMessage
  if (-not $config.PSObject.Properties["ServiceAccountPassword"]) {
    throw "$relativePathForMessage is missing ServiceAccountPassword."
  }
  if (-not $config.PSObject.Properties["PreparationEnvironment"] -or $null -eq $config.PreparationEnvironment) {
    throw "$relativePathForMessage is missing PreparationEnvironment."
  }
  foreach ($property in @($config.PreparationEnvironment.PSObject.Properties)) {
    if ([string]$property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      throw "$relativePathForMessage PreparationEnvironment contains an invalid environment variable name."
    }
    if ($null -eq $property.Value) {
      throw "$relativePathForMessage PreparationEnvironment contains a missing value."
    }
  }
  foreach ($name in @("PackagePath", "PackageExpectedFiles", "PackageStripSingleTopLevelDirectory")) {
    if (-not $config.PSObject.Properties[$name]) {
      throw "$relativePathForMessage is missing $name."
    }
  }
  if (-not $config.PSObject.Properties["WinSWDownloadSha256"]) {
    throw "$relativePathForMessage is missing WinSWDownloadSha256."
  }

  Assert-Port ([string]$config.Port) "Windows Port"
  Assert-Port ([string]$config.PublicPort) "Windows PublicPort"
  Assert-IntegerAtLeast ([string]$config.HealthCheckIntervalMinutes) "HealthCheckIntervalMinutes"
  Assert-IntegerAtLeast ([string]$config.FailureRestartDelaySeconds) "FailureRestartDelaySeconds"
  Assert-IntegerAtLeast ([string]$config.HealthCheckFailureThreshold) "HealthCheckFailureThreshold"
  Assert-IntegerAtLeast ([string]$config.HealthCheckRestartCooldownMinutes) "HealthCheckRestartCooldownMinutes"
  Assert-IntegerAtLeast ([string]$config.HealthCheckTimeoutSeconds) "HealthCheckTimeoutSeconds"
  Assert-IntegerAtLeast ([string]$config.LogRetentionDays) "LogRetentionDays"
  Assert-IntegerAtLeast ([string]$config.BackupRetentionDays) "BackupRetentionDays"
  Assert-IntegerAtLeast ([string]$config.DiagnosticRetentionDays) "DiagnosticRetentionDays"
  Assert-IntegerAtLeast ([string]$config.IisProxyTimeoutSeconds) "IisProxyTimeoutSeconds"
  foreach ($name in @("TlsEnabled", "IisEnableArrProxy", "IisRequireUrlRewrite", "IisRequireArrProxy", "IisSetForwardedHeaders", "IisWebSocketSupport", "NextjsRequireStaticAssets", "NextjsRequirePublicDirectory", "NextjsRequireServerActionsEncryptionKey", "NextjsRequireDeploymentId", "RequireWinSWDownloadSha256")) {
    Assert-BoolString ([string]$config.$name) $name
  }
  if ([string]$config.AppFramework -notin @("node", "nextjs", "reactjs")) {
    throw "Windows AppFramework must be node, nextjs, or reactjs."
  }
  if ([string]$config.NextjsDeploymentMode -notin @("standalone", "next-start")) {
    throw "Windows NextjsDeploymentMode must be standalone or next-start."
  }
  if ([string]$config.NextjsMinimumNodeVersion -notmatch '^\d+\.\d+\.\d+') {
    throw "Windows NextjsMinimumNodeVersion must be a semantic version like 20.9.0."
  }
  if ([string]::IsNullOrWhiteSpace([string]$config.ReactDocumentRoot) -or [string]$config.ReactDocumentRoot -match '(^|[\\/])\.\.($|[\\/])' -or [System.IO.Path]::IsPathRooted([string]$config.ReactDocumentRoot)) {
    throw "Windows ReactDocumentRoot must be a safe relative directory path."
  }
  Assert-BoolString ([string]$config.AutoDownloadWinSW) "AutoDownloadWinSW"
  $winswUri = [Uri][string]$config.WinSWDownloadUrl
  if ($winswUri.Scheme -ne "https") {
    throw "Windows WinSWDownloadUrl must use https."
  }
  $winswSha256 = [string]$config.WinSWDownloadSha256
  if ([string]::IsNullOrWhiteSpace($winswSha256)) {
    if ([bool]$config.AutoDownloadWinSW -and [bool]$config.RequireWinSWDownloadSha256) {
      throw "Windows WinSWDownloadSha256 must be configured when AutoDownloadWinSW and RequireWinSWDownloadSha256 are true."
    }
  } elseif ($winswSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Windows WinSWDownloadSha256 must be empty or a 64-character SHA256 hex digest."
  }
  Assert-BoolString ([string]$config.PackageStripSingleTopLevelDirectory) "PackageStripSingleTopLevelDirectory"
  $iisHealthProxyPath = ([string]$config.IisHealthProxyPath).Trim() -replace "\\", "/"
  $iisHealthProxyPath = $iisHealthProxyPath.Trim("/")
  if ([string]::IsNullOrWhiteSpace($iisHealthProxyPath) -or $iisHealthProxyPath -match '(^|/)\.\.($|/)' -or $iisHealthProxyPath -notmatch '^[A-Za-z0-9._~/-]+$') {
    throw "Windows IisHealthProxyPath must be a safe relative URL path."
  }

  $healthUri = [Uri][string]$config.HealthUrl
  if ($healthUri.Scheme -notin @("http", "https")) {
    throw "Windows HealthUrl must use http or https."
  }
  if ($healthUri.Host -notin @("127.0.0.1", "localhost")) {
    throw "Windows HealthUrl should default to localhost/127.0.0.1."
  }
  if ($config.Environment -and $config.Environment.PSObject.Properties["PORT"]) {
    if ([string]$config.Environment.PORT -ne [string]$config.Port) {
      throw "Windows Environment.PORT must match Port in the example config."
    }
  }
  foreach ($name in @("APP_PORT", "APP_NAME", "BIND_ADDRESS", "HOST", "HOSTNAME")) {
    if (-not $config.Environment.PSObject.Properties[$name]) {
      throw "Windows example Environment is missing $name."
    }
  }
  if ([string]$config.Environment.APP_PORT -ne [string]$config.Port) {
    throw "Windows Environment.APP_PORT must match Port in the example config."
  }
  if ([string]$config.BindAddress -ne "127.0.0.1") {
    throw "Windows BindAddress should default to 127.0.0.1."
  }
  if ([string]$config.ServiceAccount -eq "LocalSystem") {
    throw "Windows ServiceAccount example should not default to LocalSystem."
  }
  foreach ($name in @("BIND_ADDRESS", "HOST", "HOSTNAME")) {
    if ([string]$config.Environment.$name -ne [string]$config.BindAddress) {
      throw "Windows Environment.$name must match BindAddress in the example config."
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedNextjsMode) -and [string]$config.NextjsDeploymentMode -ne $ExpectedNextjsMode) {
    throw "$relativePathForMessage NextjsDeploymentMode must be $ExpectedNextjsMode."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedStartCommand) -and [string]$config.StartCommand -ne $ExpectedStartCommand) {
    throw "$relativePathForMessage StartCommand must be $ExpectedStartCommand."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedNodeArguments) -and [string]$config.NodeArguments -ne $ExpectedNodeArguments) {
    throw "$relativePathForMessage NodeArguments must be $ExpectedNodeArguments."
  }
  $packageExpectedFiles = @($config.PackageExpectedFiles | ForEach-Object { [string]$_ })
  if ([string]$config.NextjsDeploymentMode -eq "standalone") {
    foreach ($expected in @("server.js", ".next/BUILD_ID", ".next/static")) {
      if ($packageExpectedFiles -notcontains $expected) {
        throw "$relativePathForMessage standalone PackageExpectedFiles is missing $expected."
      }
    }
  } elseif ([string]$config.NextjsDeploymentMode -eq "next-start") {
    foreach ($expected in @("package.json", ".next", ".next/BUILD_ID", "node_modules/next/dist/bin/next")) {
      if ($packageExpectedFiles -notcontains $expected) {
        throw "$relativePathForMessage next-start PackageExpectedFiles is missing $expected."
      }
    }
    if (([string]$config.StartCommand).Replace("\", "/") -ne "node_modules/next/dist/bin/next") {
      throw "$relativePathForMessage next-start StartCommand must point to node_modules/next/dist/bin/next."
    }
    if ([string]$config.NodeArguments -ne "start -H $($config.BindAddress)") {
      throw "$relativePathForMessage next-start NodeArguments must be 'start -H $($config.BindAddress)'."
    }
  }

  Write-Host "$Label OK"
  return $config
}

function Test-WindowsExampleConfigs {
  $windowsConfig = Test-WindowsExampleConfig `
    -RelativePath "config/windows/app.config.example.json" `
    -Label "Windows example config" `
    -ExpectedNextjsMode "standalone" `
    -ExpectedStartCommand "server.js"

  Test-WindowsExampleConfig `
    -RelativePath "config/windows/next-start.app.config.example.json" `
    -Label "Windows next-start example config" `
    -ExpectedNextjsMode "next-start" `
    -ExpectedStartCommand "node_modules\next\dist\bin\next" `
    -ExpectedNodeArguments "start -H 127.0.0.1" | Out-Null

  return $windowsConfig
}

function Test-WindowsStaticIisExampleConfig {
  Write-Step "Windows static IIS example config"
  $path = Join-Path $RepoRoot "config/windows/static-iis.app.config.example.json"
  $config = Get-Content -Path $path -Raw | ConvertFrom-Json
  $values = ConvertTo-StringMap $config

  Assert-RequiredValue $values @(
    "AppName",
    "DisplayName",
    "Description",
    "DeploymentMode",
    "AppFramework",
    "StaticOutputDirectory",
    "SpaShellFile",
    "AppDirectory",
    "PackageExpectedFiles",
    "PackageStripSingleTopLevelDirectory",
    "InstallCommand",
    "BuildCommand",
    "ServiceManager",
    "ReverseProxy",
    "IisSitePath",
    "IisSiteName",
    "IisAppPoolName",
    "PublicHostName",
    "PublicPort",
    "TlsEnabled",
    "IisRequireUrlRewrite",
    "IisRequireArrProxy",
    "IisStaticAllowUrlRewrite",
    "BackupDirectory"
  ) "config/windows/static-iis.app.config.example.json"

  if ([string]$config.AppName -ne "ExampleStaticSpa") {
    throw "static_iis example AppName must use the neutral ExampleStaticSpa placeholder."
  }
  if ([string]$config.DeploymentMode -ne "static_iis") {
    throw "static_iis example must set DeploymentMode to static_iis."
  }
  if ([string]$config.AppFramework -notin @("tanstack-start", "vite-spa")) {
    throw "static_iis example AppFramework must be tanstack-start or vite-spa."
  }
  if ([string]$config.StaticOutputDirectory -ne "dist/client") {
    throw "static_iis example StaticOutputDirectory must be dist/client."
  }
  if ([string]$config.SpaShellFile -ne "_shell.html") {
    throw "static_iis example SpaShellFile must be _shell.html."
  }
  if ([string]$config.InstallCommand -ne "npm ci --include=dev") {
    throw "static_iis example InstallCommand must use npm ci --include=dev."
  }
  if ([string]$config.BuildCommand -ne "npm run build") {
    throw "static_iis example BuildCommand must use npm run build."
  }
  if (-not $config.PSObject.Properties["PreparationEnvironment"] -or $null -eq $config.PreparationEnvironment) {
    throw "static_iis example PreparationEnvironment must be an object."
  }
  if (@($config.PreparationEnvironment.PSObject.Properties).Count -ne 0) {
    throw "static_iis example PreparationEnvironment must be empty."
  }
  if ([string]$config.ServiceManager -ne "none") {
    throw "static_iis example must not configure a Node service manager."
  }
  if ([string]$config.IisSiteName -ne "ExampleStaticSpa") {
    throw "static_iis example IIS site name must use ExampleStaticSpa."
  }
  if ([string]$config.IisSitePath -ne "C:\inetpub\ExampleStaticSpa") {
    throw "static_iis example deploy path must use C:\inetpub\ExampleStaticSpa."
  }
  if ([string]$config.PublicHostName -ne "app.example.local") {
    throw "static_iis example public host must use app.example.local."
  }
  Assert-Port ([string]$config.PublicPort) "Static IIS PublicPort"
  foreach ($name in @("TlsEnabled", "IisRequireUrlRewrite", "IisRequireArrProxy", "IisStaticAllowUrlRewrite", "PackageStripSingleTopLevelDirectory")) {
    Assert-BoolString ([string]$config.$name) $name
  }
  if ($config.IisRequireUrlRewrite -ne $false -or $config.IisRequireArrProxy -ne $false) {
    throw "static_iis example must not require URL Rewrite or ARR."
  }
  if ($config.IisStaticAllowUrlRewrite -ne $false) {
    throw "static_iis example must block rewrite rules by default."
  }

  $expectedFiles = @($config.PackageExpectedFiles | ForEach-Object { [string]$_ })
  foreach ($expected in @("dist/client/_shell.html", "dist/client/assets", "dist/client/web.config")) {
    if ($expectedFiles -notcontains $expected) {
      throw "static_iis PackageExpectedFiles is missing $expected."
    }
  }
  foreach ($forbidden in @("server.js", "node_modules", ".next/standalone/server.js")) {
    if ($expectedFiles -contains $forbidden) {
      throw "static_iis PackageExpectedFiles must not require $forbidden."
    }
  }

  Write-Host "Windows static IIS example config OK"
}

function Test-LinuxExampleConfig {
  param(
    [string]$RelativePath = "config/linux/app.env.example",
    [string]$Label = "Linux example env",
    [string]$ExpectedServiceManager = "",
    [string]$ExpectedHealthcheckStatePrefix = "",
    [string]$ExpectedNodeBin = ""
  )

  Write-Step $Label
  $path = Join-Path $RepoRoot $RelativePath
  $relativePathForMessage = Get-RelativePath $path
  $env = Read-EnvExample $path

  Assert-RequiredValue $env @(
    "APP_NAME",
    "APP_DISPLAY_NAME",
    "APP_DESCRIPTION",
    "DEPLOYMENT_MODE",
    "APP_FRAMEWORK",
    "NEXTJS_DEPLOYMENT_MODE",
    "REACT_DOCUMENT_ROOT",
    "NEXTJS_REQUIRE_STATIC_ASSETS",
    "NEXTJS_REQUIRE_PUBLIC_DIR",
    "NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY",
    "NEXTJS_REQUIRE_DEPLOYMENT_ID",
    "NEXTJS_MINIMUM_NODE_VERSION",
    "APP_RUNTIME",
    "SERVICE_MANAGER",
    "REVERSE_PROXY",
    "APP_DIR",
    "PACKAGE_EXPECTED_FILES",
    "PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR",
    "SKIP_PACKAGE_IMPORT",
    "NODE_BIN",
    "START_SCRIPT",
    "APP_PORT",
    "BIND_ADDRESS",
    "HEALTH_URL",
    "SERVICE_USER",
    "SERVICE_GROUP",
    "LOG_DIR",
    "ENV_FILE",
    "BACKUP_DIR",
    "PUBLIC_PORT",
    "PROXY_LISTEN_PORT",
    "FORWARDED_PROTO",
    "FORWARDED_PORT",
    "HAPROXY_ALLOW_MAIN_CONFIG_REPLACE",
    "HEALTHCHECK_STATE_DIR"
  ) $relativePathForMessage

  Assert-Port $env.APP_PORT "Linux APP_PORT"
  Assert-Port $env.PUBLIC_PORT "Linux PUBLIC_PORT"
  Assert-Port $env.PROXY_LISTEN_PORT "Linux PROXY_LISTEN_PORT"
  Assert-Port $env.FORWARDED_PORT "Linux FORWARDED_PORT"
  foreach ($name in @("HEALTHCHECK_INTERVAL", "HEALTHCHECK_FAILURE_THRESHOLD", "HEALTHCHECK_RESTART_COOLDOWN", "HEALTHCHECK_TIMEOUT", "FAILURE_RESTART_DELAY", "LOG_RETENTION_DAYS", "BACKUP_RETENTION_DAYS", "DIAGNOSTIC_RETENTION_DAYS")) {
    Assert-IntegerAtLeast $env[$name] $name
  }
  if (-not $env.ContainsKey("PACKAGE_PATH")) {
    throw "$relativePathForMessage is missing PACKAGE_PATH."
  }
  foreach ($name in @("SKIP_PREFLIGHT", "ALLOW_PORT_IN_USE", "SKIP_PACKAGE_IMPORT", "PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR", "SKIP_REVERSE_PROXY", "SKIP_HEALTH_CHECK", "SKIP_INSTALL", "SKIP_BUILD", "TLS_ENABLED", "NEXTJS_REQUIRE_STATIC_ASSETS", "NEXTJS_REQUIRE_PUBLIC_DIR", "NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY", "NEXTJS_REQUIRE_DEPLOYMENT_ID", "HAPROXY_ALLOW_MAIN_CONFIG_REPLACE", "TOMCAT_RESTART")) {
    Assert-BoolString $env[$name] $name
  }
  if ($env.APP_FRAMEWORK -notin @("node", "nextjs", "reactjs")) {
    throw "Linux APP_FRAMEWORK must be node, nextjs, or reactjs."
  }
  if ($env.NEXTJS_DEPLOYMENT_MODE -notin @("standalone", "next-start")) {
    throw "Linux NEXTJS_DEPLOYMENT_MODE must be standalone or next-start."
  }
  if ($env.NEXTJS_MINIMUM_NODE_VERSION -notmatch '^\d+\.\d+\.\d+') {
    throw "Linux NEXTJS_MINIMUM_NODE_VERSION must be a semantic version like 20.9.0."
  }
  if ([string]::IsNullOrWhiteSpace($env.REACT_DOCUMENT_ROOT) -or $env.REACT_DOCUMENT_ROOT -match '(^|[\\/])\.\.($|[\\/])' -or [System.IO.Path]::IsPathRooted($env.REACT_DOCUMENT_ROOT)) {
    throw "Linux REACT_DOCUMENT_ROOT must be a safe relative directory path."
  }
  if ($env.FORWARDED_PROTO -notin @("http", "https")) {
    throw "Linux FORWARDED_PROTO must be http or https."
  }
  if ($env.APP_RUNTIME -notin @("node", "tomcat")) {
    throw "Linux APP_RUNTIME must be node or tomcat."
  }
  if ($env.SERVICE_MANAGER -notin @("systemd", "systemv", "openrc", "launchd", "bsdrc")) {
    throw "Linux SERVICE_MANAGER must be systemd, systemv, openrc, launchd, or bsdrc."
  }
  if ($env.REVERSE_PROXY -notin @("nginx", "apache", "haproxy", "traefik", "none")) {
    throw "Linux REVERSE_PROXY must be nginx, apache, haproxy, traefik, or none."
  }

  $healthUri = [Uri]$env.HEALTH_URL
  if ($healthUri.Scheme -notin @("http", "https")) {
    throw "Linux HEALTH_URL must use http or https."
  }
  if ($healthUri.Host -notin @("127.0.0.1", "localhost")) {
    throw "Linux HEALTH_URL should default to localhost/127.0.0.1."
  }
  if ($healthUri.Port -ne [int]$env.APP_PORT) {
    throw "Linux HEALTH_URL port must match APP_PORT in the example env."
  }
  if ($env.BIND_ADDRESS -ne "127.0.0.1") {
    throw "Linux BIND_ADDRESS should default to 127.0.0.1."
  }
  if ($env.SERVICE_USER -eq "root" -or $env.SERVICE_GROUP -eq "root") {
    throw "Linux SERVICE_USER/SERVICE_GROUP examples should not default to root."
  }
  if (-not $env.HEALTHCHECK_STATE_DIR.StartsWith("/")) {
    throw "Linux HEALTHCHECK_STATE_DIR should be an absolute root-owned state path."
  }
  if ($env.HEALTHCHECK_STATE_DIR.TrimEnd("/") -eq $env.LOG_DIR.TrimEnd("/") -or $env.HEALTHCHECK_STATE_DIR.StartsWith($env.LOG_DIR.TrimEnd("/") + "/")) {
    throw "Linux HEALTHCHECK_STATE_DIR must not be inside LOG_DIR."
  }
  if ($env.TLS_ENABLED -ne "true") {
    throw "Linux TLS_ENABLED should default to true."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedServiceManager) -and $env.SERVICE_MANAGER -ne $ExpectedServiceManager) {
    throw "$relativePathForMessage SERVICE_MANAGER must be $ExpectedServiceManager."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedHealthcheckStatePrefix) -and -not $env.HEALTHCHECK_STATE_DIR.StartsWith($ExpectedHealthcheckStatePrefix)) {
    throw "$relativePathForMessage HEALTHCHECK_STATE_DIR should start with $ExpectedHealthcheckStatePrefix."
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedNodeBin) -and $env.NODE_BIN -ne $ExpectedNodeBin) {
    throw "$relativePathForMessage NODE_BIN should be $ExpectedNodeBin."
  }
  $packageExpectedFiles = @([string]$env.PACKAGE_EXPECTED_FILES -split '\s+' | Where-Object { $_ })
  if ($env.NEXTJS_DEPLOYMENT_MODE -eq "standalone") {
    foreach ($expected in @("server.js", ".next/BUILD_ID", ".next/static")) {
      if ($packageExpectedFiles -notcontains $expected) {
        throw "$relativePathForMessage standalone PACKAGE_EXPECTED_FILES is missing $expected."
      }
    }
    if ($env.START_SCRIPT -ne "server.js") {
      throw "$relativePathForMessage standalone START_SCRIPT must be server.js."
    }
  } elseif ($env.NEXTJS_DEPLOYMENT_MODE -eq "next-start") {
    foreach ($expected in @("package.json", ".next", ".next/BUILD_ID", "node_modules/next/dist/bin/next")) {
      if ($packageExpectedFiles -notcontains $expected) {
        throw "$relativePathForMessage next-start PACKAGE_EXPECTED_FILES is missing $expected."
      }
    }
    if ($env.START_SCRIPT -ne "node_modules/next/dist/bin/next") {
      throw "$relativePathForMessage next-start START_SCRIPT must point to node_modules/next/dist/bin/next."
    }
    if ($env.NODE_ARGUMENTS -ne "start -H $($env.BIND_ADDRESS)") {
      throw "$relativePathForMessage next-start NODE_ARGUMENTS must be 'start -H $($env.BIND_ADDRESS)'."
    }
  }

  Write-Host "$Label OK"
  return $env
}

function Test-UnixExampleConfigs {
  $linuxEnv = Test-LinuxExampleConfig `
    -RelativePath "config/linux/app.env.example" `
    -Label "Linux example env" `
    -ExpectedServiceManager "systemd" `
    -ExpectedHealthcheckStatePrefix "/var/lib/"

  Test-LinuxExampleConfig `
    -RelativePath "config/linux/app.env.next-start.example" `
    -Label "Linux next-start example env" `
    -ExpectedServiceManager "systemd" `
    -ExpectedHealthcheckStatePrefix "/var/lib/" | Out-Null

  Test-LinuxExampleConfig `
    -RelativePath "config/linux/app.env.macos.example" `
    -Label "macOS example env" `
    -ExpectedServiceManager "launchd" `
    -ExpectedHealthcheckStatePrefix "/usr/local/var/lib/" `
    -ExpectedNodeBin "/opt/homebrew/bin/node" | Out-Null

  Test-LinuxExampleConfig `
    -RelativePath "config/linux/app.env.bsd.example" `
    -Label "BSD example env" `
    -ExpectedServiceManager "bsdrc" `
    -ExpectedHealthcheckStatePrefix "/var/db/" `
    -ExpectedNodeBin "/usr/local/bin/node" | Out-Null

  return $linuxEnv
}

function Test-AnsibleDefaults {
  Write-Step "Ansible example variables"
  $path = Join-Path $RepoRoot "config/ansible/group_vars_all.example.yml"
  $text = Get-Content -Path $path -Raw
  $requiredNames = @(
    "node_deploy_project_name",
    "node_deploy_display_name",
    "node_deploy_description",
    "node_deploy_mode",
    "node_deploy_app_framework",
    "node_deploy_nextjs_deployment_mode",
    "node_deploy_react_document_root",
    "node_deploy_nextjs_require_static_assets",
    "node_deploy_nextjs_require_public_directory",
    "node_deploy_nextjs_require_server_actions_encryption_key",
    "node_deploy_nextjs_require_deployment_id",
    "node_deploy_nextjs_minimum_node_version",
    "node_deploy_app_runtime",
    "node_deploy_package_path_windows",
    "node_deploy_package_path_linux",
    "node_deploy_package_expected_files",
    "node_deploy_package_strip_single_top_level_directory",
    "node_deploy_skip_package_import",
    "node_deploy_skip_preflight",
    "node_deploy_allow_port_in_use",
    "node_deploy_skip_install",
    "node_deploy_skip_build",
    "node_deploy_skip_reverse_proxy",
    "node_deploy_skip_health_check",
    "node_deploy_windows_winsw_source",
    "node_deploy_windows_iis_enable_arr_proxy",
    "node_deploy_windows_iis_set_forwarded_headers",
    "node_deploy_windows_iis_health_proxy_path",
    "node_deploy_windows_iis_websocket_support",
    "node_deploy_windows_iis_proxy_timeout_seconds",
    "node_deploy_windows_service_account_password",
    "node_deploy_windows_auto_download_winsw",
    "node_deploy_windows_winsw_download_url",
    "node_deploy_windows_require_winsw_download_sha256",
    "node_deploy_windows_winsw_download_sha256",
    "node_deploy_windows_backup_dir",
    "node_deploy_linux_deploy_dir",
    "node_deploy_linux_config_path",
    "node_deploy_linux_env_file",
    "node_deploy_linux_backup_dir",
    "node_deploy_linux_nginx_config_dir",
    "node_deploy_linux_nginx_service",
    "node_deploy_linux_apache_config_dir",
    "node_deploy_linux_apache_service",
    "node_deploy_linux_haproxy_config_file",
    "node_deploy_linux_haproxy_allow_main_config_replace",
    "node_deploy_linux_haproxy_bind",
    "node_deploy_linux_haproxy_frontend_name",
    "node_deploy_linux_haproxy_backend_name",
    "node_deploy_linux_haproxy_service",
    "node_deploy_linux_traefik_dynamic_dir",
    "node_deploy_linux_traefik_dynamic_file",
    "node_deploy_linux_traefik_entrypoint",
    "node_deploy_linux_traefik_router_name",
    "node_deploy_linux_traefik_service_name",
    "node_deploy_linux_traefik_service",
    "node_deploy_linux_healthcheck_path",
    "node_deploy_linux_healthcheck_state_dir",
    "node_deploy_tomcat_package",
    "node_deploy_tomcat_service",
    "node_deploy_tomcat_webapps_dir",
    "node_deploy_tomcat_war_file",
    "node_deploy_tomcat_context_path",
    "node_deploy_tomcat_restart",
    "node_deploy_linux_proxy_listen_port",
    "node_deploy_linux_forwarded_proto",
    "node_deploy_linux_forwarded_port",
    "node_deploy_linux_nginx_package",
    "node_deploy_linux_apache_package",
    "node_deploy_linux_haproxy_package",
    "node_deploy_linux_traefik_package",
    "node_deploy_healthcheck_failure_threshold",
    "node_deploy_healthcheck_restart_cooldown_seconds",
    "node_deploy_healthcheck_timeout_seconds",
    "node_deploy_log_retention_days",
    "node_deploy_backup_retention_days",
    "node_deploy_diagnostic_retention_days"
  )

  foreach ($name in $requiredNames) {
    if ($text -notmatch "(?m)^$([regex]::Escape($name))\s*:") {
      throw "config/ansible/group_vars_all.example.yml is missing $name."
    }
  }

  if ($text -notmatch "(?m)^node_deploy_package_expected_files:\s*\[\]\s*$") {
    throw "config/ansible/group_vars_all.example.yml should leave node_deploy_package_expected_files empty so templates use framework-aware defaults."
  }

  $windowsTemplate = Get-Content -Path (Join-Path $RepoRoot "ansible/roles/windows_node_service/templates/app.config.json.j2") -Raw
  $linuxTemplate = Get-Content -Path (Join-Path $RepoRoot "ansible/roles/linux_node_service/templates/deploy.env.j2") -Raw
  foreach ($template in @(
      @{ Name = "Windows Ansible app config"; Text = $windowsTemplate },
      @{ Name = "Linux Ansible deploy env"; Text = $linuxTemplate }
    )) {
    foreach ($expected in @(
        "default_package_expected_files",
        "react_package_expected_files",
        "react_document_root",
        "node_modules/next/dist/bin/next",
        "configured_package_expected_files",
        "package_expected_files",
        "default_node_arguments",
        "node_arguments",
        "start -H"
      )) {
      if (-not $template.Text.Contains($expected)) {
        throw "$($template.Name) is missing mode-aware package expected file handling: $expected"
      }
    }
  }

  $windowsTasks = Get-Content -Path (Join-Path $RepoRoot "ansible/roles/windows_node_service/tasks/main.yml") -Raw
  $linuxTasks = Get-Content -Path (Join-Path $RepoRoot "ansible/roles/linux_node_service/tasks/main.yml") -Raw
  foreach ($taskFile in @(
      @{ Name = "Windows Ansible tasks"; Text = $windowsTasks },
      @{ Name = "Linux Ansible tasks"; Text = $linuxTasks }
    )) {
    foreach ($expected in @(
        "application framework",
        "Next.js deployment mode",
        "standalone",
        "next-start"
      )) {
      if (-not $taskFile.Text.Contains($expected)) {
        throw "$($taskFile.Name) is missing Next.js validation text: $expected"
      }
    }
  }
  if (-not $linuxTasks.Contains("APP_FRAMEWORK=nextjs requires node_deploy_app_runtime=node.")) {
    throw "Linux Ansible tasks should reject Next.js deployments that are not APP_RUNTIME=node."
  }
  if (-not $windowsTasks.Contains("reactjs")) {
    throw "Windows Ansible tasks should accept React.js deployments."
  }
  if (-not $linuxTasks.Contains("APP_FRAMEWORK=reactjs requires node_deploy_app_runtime=node.")) {
    throw "Linux Ansible tasks should reject React deployments that are not APP_RUNTIME=node."
  }

  Write-Host "Ansible example variables OK"
}

function Get-TemplateTokens {
  param([string]$Text)

  $tokens = New-Object System.Collections.Generic.HashSet[string]
  foreach ($match in [regex]::Matches($Text, '\{\{([A-Z][A-Z0-9_]*)\}\}')) {
    [void]$tokens.Add($match.Groups[1].Value)
  }
  return @($tokens | Sort-Object)
}

function Render-TokenTemplate {
  param(
    [string]$Text,
    [hashtable]$Values,
    [string]$Source
  )

  foreach ($token in Get-TemplateTokens $Text) {
    if (-not $Values.ContainsKey($token)) {
      throw "$Source references unknown template token: $token"
    }
    $escapedToken = [regex]::Escape("{{$token}}")
    $Text = [regex]::Replace($Text, $escapedToken, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) [string]$Values[$token] })
  }

  if ($Text -match '\{\{[A-Z][A-Z0-9_]*\}\}') {
    throw "$Source still contains unresolved template tokens."
  }
  return $Text
}

function Test-JinjaDelimiters {
  Write-Step "Ansible template delimiters"
  $files = Get-ChildItem -Path (Join-Path $RepoRoot "ansible/roles") -Recurse -File -Filter "*.j2"
  foreach ($file in $files) {
    $text = Get-Content -Path $file.FullName -Raw
    foreach ($pair in @(
      @{ Open = "{{"; Close = "}}" },
      @{ Open = "{%"; Close = "%}" },
      @{ Open = "{#"; Close = "#}" }
    )) {
      $openCount = [regex]::Matches($text, [regex]::Escape($pair.Open)).Count
      $closeCount = [regex]::Matches($text, [regex]::Escape($pair.Close)).Count
      if ($openCount -ne $closeCount) {
        throw "$(Get-RelativePath $file.FullName) has mismatched $($pair.Open) / $($pair.Close) delimiters."
      }
    }
  }
  Write-Host "Ansible template delimiters OK"
}

function Convert-ToBashPath {
  param([string]$Path)

  $resolved = (Resolve-Path $Path).Path
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    return ("/" + $Matches[1].ToLowerInvariant() + "/" + ($Matches[2] -replace '\\', '/'))
  }
  return ($resolved -replace '\\', '/')
}

function Test-RenderedTemplates {
  param(
    [object]$WindowsConfig,
    [hashtable]$LinuxEnv
  )

  Write-Step "Rendered token templates"
  $values = @{
    APP_NAME = $LinuxEnv.APP_NAME
    APP_DISPLAY_NAME = $LinuxEnv.APP_DISPLAY_NAME
    APP_DESCRIPTION = $LinuxEnv.APP_DESCRIPTION
    SERVICE_USER = $LinuxEnv.SERVICE_USER
    SERVICE_GROUP = $LinuxEnv.SERVICE_GROUP
    APP_DIR = $LinuxEnv.APP_DIR
    ENV_FILE = $LinuxEnv.ENV_FILE
    NODE_BIN = $LinuxEnv.NODE_BIN
    START_SCRIPT = $LinuxEnv.START_SCRIPT
    NODE_ARGUMENTS = $LinuxEnv.NODE_ARGUMENTS
    FAILURE_RESTART_DELAY = $LinuxEnv.FAILURE_RESTART_DELAY
    LOG_DIR = $LinuxEnv.LOG_DIR
    BACKUP_DIR = $LinuxEnv.BACKUP_DIR
    APP_PORT = $LinuxEnv.APP_PORT
    PUBLIC_HOSTNAME = $LinuxEnv.PUBLIC_HOSTNAME
    PROXY_LISTEN_PORT = $LinuxEnv.PROXY_LISTEN_PORT
    FORWARDED_PROTO = $LinuxEnv.FORWARDED_PROTO
    FORWARDED_PORT = $LinuxEnv.FORWARDED_PORT
    HEALTH_URL = $LinuxEnv.HEALTH_URL
    HEALTHCHECK_INTERVAL = $LinuxEnv.HEALTHCHECK_INTERVAL
    HEALTHCHECK_SCRIPT = "/usr/local/sbin/$($LinuxEnv.APP_NAME)-healthcheck.sh"
    HEALTHCHECK_CONFIG = "/etc/node-enterprise-deploy-kit/$($LinuxEnv.APP_NAME).env"
    HEALTHCHECK_COMMAND = "/usr/local/sbin/$($LinuxEnv.APP_NAME)-healthcheck.sh /etc/node-enterprise-deploy-kit/$($LinuxEnv.APP_NAME).env"
    RUNNER_SCRIPT = "/usr/local/sbin/$($LinuxEnv.APP_NAME)-runner.sh"
    HAPROXY_BIND = $LinuxEnv.HAPROXY_BIND
    HAPROXY_FRONTEND_NAME = $LinuxEnv.HAPROXY_FRONTEND_NAME
    HAPROXY_BACKEND_NAME = $LinuxEnv.HAPROXY_BACKEND_NAME
    HEALTHCHECK_PATH = $LinuxEnv.HEALTHCHECK_PATH
    HEALTHCHECK_STATE_DIR = $LinuxEnv.HEALTHCHECK_STATE_DIR
    TRAEFIK_ENTRYPOINT = $LinuxEnv.TRAEFIK_ENTRYPOINT
    TRAEFIK_ROUTER_NAME = $LinuxEnv.TRAEFIK_ROUTER_NAME
    TRAEFIK_SERVICE_NAME = $LinuxEnv.TRAEFIK_SERVICE_NAME
    HEALTH_PROXY_PATH = [string]$WindowsConfig.IisHealthProxyPath
    FORWARDED_SERVER_VARIABLES = @"
          <serverVariables>
            <set name="HTTP_X_FORWARDED_HOST" value="{HTTP_HOST}" />
            <set name="HTTP_X_FORWARDED_PROTO" value="https" />
            <set name="HTTP_X_FORWARDED_PORT" value="443" />
            <set name="HTTP_X_FORWARDED_FOR" value="{REMOTE_ADDR}" />
          </serverVariables>
"@
    DISPLAY_NAME = [string]$WindowsConfig.DisplayName
    DESCRIPTION = [string]$WindowsConfig.Description
    NODE_EXE = [string]$WindowsConfig.NodeExe
    START_COMMAND = [string]$WindowsConfig.StartCommand
    APP_DIRECTORY = [string]$WindowsConfig.AppDirectory
    LOG_DIRECTORY = [string]$WindowsConfig.LogDirectory
    ENVIRONMENT_BLOCK = '<env name="NODE_ENV" value="production" />'
  }

  $tempDir = Join-Path $RepoRoot (".tmp/template-validation-" + [guid]::NewGuid().ToString("N"))
  New-Item -Path $tempDir -ItemType Directory | Out-Null

  try {
    $templateFiles = Get-ChildItem -Path (Join-Path $RepoRoot "templates") -Recurse -File -Filter "*.tpl"
    foreach ($file in $templateFiles) {
      $source = Get-RelativePath $file.FullName
      $rendered = Render-TokenTemplate (Get-Content -Path $file.FullName -Raw) $values $source

      if ($source -like "templates/windows/*.tpl" -or $source -match 'launchd-(node-app|healthcheck)\.plist\.tpl$') {
        try {
          [xml]$null = $rendered
        }
        catch {
          throw "$source did not render as valid XML. $($_.Exception.Message)"
        }
      }

      if ($source -match 'sysv-node-app\.init\.tpl$|openrc-node-app\.init\.tpl$|bsdrc-node-app\.init\.tpl$|launchd-runner\.sh\.tpl$') {
        if (-not $SkipShellRenderedSyntax) {
          $renderedPath = Join-Path $tempDir ([System.IO.Path]::GetFileName($file.FullName))
          [System.IO.File]::WriteAllText($renderedPath, $rendered, [System.Text.UTF8Encoding]::new($false))

          Push-Location $RepoRoot
          try {
            $bash = Get-Command bash -ErrorAction SilentlyContinue
            if ($bash) {
              & $bash.Source -n (Get-RelativePath $renderedPath)
              if ($LASTEXITCODE -ne 0) {
                throw "$source rendered bash syntax check failed."
              }
            }

            if ($source -match 'sysv-node-app\.init\.tpl$|openrc-node-app\.init\.tpl$|bsdrc-node-app\.init\.tpl$') {
              $sh = Get-Command sh -ErrorAction SilentlyContinue
              if ($sh) {
                & $sh.Source -n (Get-RelativePath $renderedPath)
                if ($LASTEXITCODE -ne 0) {
                  throw "$source rendered POSIX sh syntax check failed."
                }
              }
            }
          }
          finally {
            Pop-Location
          }
        }
      }
    }
  }
  finally {
    if (Test-Path $tempDir) {
      Remove-Item -Path $tempDir -Recurse -Force
    }
  }

  Write-Host "Rendered token templates OK"
}

function Test-AnsibleCollectionAvailable {
  param([string]$Name)

  $galaxy = Get-Command ansible-galaxy -ErrorAction SilentlyContinue
  if (-not $galaxy) {
    return $false
  }

  $previousAnsibleConfig = $env:ANSIBLE_CONFIG
  $previousAnsibleRolesPath = $env:ANSIBLE_ROLES_PATH
  Push-Location $RepoRoot
  try {
    $env:ANSIBLE_CONFIG = Join-Path $RepoRoot "ansible.cfg"
    $env:ANSIBLE_ROLES_PATH = Join-Path $RepoRoot "ansible/roles"
    $output = @(& $galaxy.Source collection list $Name 2>$null)
    return ($LASTEXITCODE -eq 0 -and ($output -match [regex]::Escape($Name)))
  }
  finally {
    $env:ANSIBLE_CONFIG = $previousAnsibleConfig
    $env:ANSIBLE_ROLES_PATH = $previousAnsibleRolesPath
    Pop-Location
  }
}

function Test-AnsibleSyntaxIfAvailable {
  if ($SkipAnsibleSyntax) {
    Write-Host "Skipping Ansible syntax check."
    return
  }

  Write-Step "Ansible syntax"
  $ansible = Get-Command ansible-playbook -ErrorAction SilentlyContinue
  if (-not $ansible) {
    Write-Host "ansible-playbook was not found; skipping optional Ansible syntax check."
    return
  }

  if (-not (Test-AnsibleCollectionAvailable "ansible.windows")) {
    Write-Host "ansible.windows collection was not found; skipping optional Ansible syntax check. Install it with: ansible-galaxy collection install -r ansible/requirements.yml"
    return
  }

  $previousAnsibleConfig = $env:ANSIBLE_CONFIG
  $previousAnsibleRolesPath = $env:ANSIBLE_ROLES_PATH
  Push-Location $RepoRoot
  try {
    $env:ANSIBLE_CONFIG = Join-Path $RepoRoot "ansible.cfg"
    $env:ANSIBLE_ROLES_PATH = Join-Path $RepoRoot "ansible/roles"
    & $ansible.Source --syntax-check -i "ansible/inventory.example.yml" "ansible/playbooks/site.yml"
    if ($LASTEXITCODE -ne 0) {
      throw "Ansible syntax check failed."
    }
  }
  finally {
    $env:ANSIBLE_CONFIG = $previousAnsibleConfig
    $env:ANSIBLE_ROLES_PATH = $previousAnsibleRolesPath
    Pop-Location
  }
}

$windowsConfig = Test-WindowsExampleConfigs
Test-WindowsStaticIisExampleConfig
$linuxEnv = Test-UnixExampleConfigs
Test-AnsibleDefaults
Test-JinjaDelimiters
Test-RenderedTemplates -WindowsConfig $windowsConfig -LinuxEnv $linuxEnv
Test-AnsibleSyntaxIfAvailable

Write-Host ""
Write-Host "Sample config and template validation OK"
