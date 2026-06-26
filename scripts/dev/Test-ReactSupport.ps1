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

function Convert-ToBashPath {
  param([string]$Path)

  $resolved = (Resolve-Path $Path).Path
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    return ("/" + $Matches[1].ToLowerInvariant() + "/" + ($Matches[2] -replace '\\', '/'))
  }
  return ($resolved -replace '\\', '/')
}

function Get-BashPathCandidates {
  param([string]$Path)

  $resolved = (Resolve-Path $Path).Path
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $tail = $Matches[2] -replace '\\', '/'
    return @(
      "/$drive/$tail",
      "/mnt/$drive/$tail",
      "$($Matches[1].ToUpperInvariant()):/$tail"
    )
  }
  return @(($resolved -replace '\\', '/'))
}

function Resolve-BashVisiblePath {
  param(
    [System.Management.Automation.CommandInfo]$Bash,
    [string]$Path
  )

  foreach ($candidate in Get-BashPathCandidates $Path) {
    $quoted = Escape-BashSingleQuoted $candidate
    & $Bash.Source -lc "test -e $quoted" *> $null
    if ($LASTEXITCODE -eq 0) {
      return $candidate
    }
  }
  return Convert-ToBashPath $Path
}

function Escape-BashSingleQuoted {
  param([string]$Value)
  return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Invoke-ExpectFailure {
  param(
    [scriptblock]$Script,
    [string]$ExpectedText
  )

  $outputItems = New-Object System.Collections.Generic.List[object]
  $failed = $false
  $global:LASTEXITCODE = 0
  try {
    & $Script *>&1 | ForEach-Object { $outputItems.Add($_) | Out-Null }
  }
  catch {
    $failed = $true
    $outputItems.Add($_) | Out-Null
  }

  if (-not $failed -and $global:LASTEXITCODE -ne 0) {
    $failed = $true
  }

  $output = $outputItems | Out-String
  if ($failed) {
    if ($output -notmatch [regex]::Escape($ExpectedText)) {
      throw "Expected failure containing '$ExpectedText', got: $output"
    }
    return
  }
  throw "Expected command to fail containing '$ExpectedText', but it succeeded. Output: $output"
}

function New-ReactLayout {
  param(
    [string]$AppDirectory,
    [switch]$WithoutIndex
  )

  New-Directory $AppDirectory
  New-Directory (Join-Path $AppDirectory "build\assets")
  Write-Utf8NoBom -Path (Join-Path $AppDirectory "server.js") -Text "console.log('react server');`n"
  if (-not $WithoutIndex) {
    Write-Utf8NoBom -Path (Join-Path $AppDirectory "build\index.html") -Text "<!doctype html><div id=`"root`"></div>`n"
  }
  Write-Utf8NoBom -Path (Join-Path $AppDirectory "build\assets\app.js") -Text "console.log('react');`n"
}

function New-WindowsReactConfig {
  param(
    [string]$Path,
    [string]$AppDirectory,
    [string]$ServiceDirectory,
    [string]$LogDirectory,
    [int]$Port,
    [string]$PackagePath = ""
  )

  $nodeCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $nodeCommand) { $nodeCommand = Get-Command pwsh -ErrorAction SilentlyContinue }
  if (-not $nodeCommand) { $nodeCommand = Get-Command sh -ErrorAction SilentlyContinue }
  if (-not $nodeCommand) { throw "No verifier-safe NodeExe placeholder command was found." }

  $config = [ordered]@{
    AppName = "ExampleReactSmoke"
    DisplayName = "Example React Smoke"
    Description = "Example React Smoke"
    DeploymentMode = "reverse_proxy"
    AppFramework = "reactjs"
    NextjsDeploymentMode = "standalone"
    ReactDocumentRoot = "build"
    NextjsRequireStaticAssets = $true
    NextjsRequirePublicDirectory = $false
    NextjsRequireServerActionsEncryptionKey = $false
    NextjsRequireDeploymentId = $false
    AutoDownloadWinSW = $true
    WinSWDownloadUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
    RequireWinSWDownloadSha256 = $false
    WinSWDownloadSha256 = ""
    AppDirectory = $AppDirectory
    PackagePath = $PackagePath
    PackageExpectedFiles = @("server.js", "build/index.html")
    PackageStripSingleTopLevelDirectory = $true
    StartCommand = "server.js"
    NodeExe = $nodeCommand.Source
    NodeArguments = ""
    Port = $Port
    BindAddress = "127.0.0.1"
    HealthUrl = "http://127.0.0.1:$Port/health"
    ServiceManager = "nssm"
    ReverseProxy = "none"
    ServiceDirectory = $ServiceDirectory
    LogDirectory = $LogDirectory
    BackupDirectory = (Join-Path $ServiceDirectory "backups")
    IisSitePath = $AppDirectory
    IisSiteName = "ExampleReactSmoke"
    IisAppPoolName = "ExampleReactSmoke-AppPool"
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
    Environment = [ordered]@{
      NODE_ENV = "production"
      PORT = [string]$Port
      APP_PORT = [string]$Port
      APP_NAME = "ExampleReactSmoke"
      BIND_ADDRESS = "127.0.0.1"
      HOST = "127.0.0.1"
      HOSTNAME = "127.0.0.1"
    }
  }

  Write-Utf8NoBom -Path $Path -Text (($config | ConvertTo-Json -Depth 20) + "`n")
}

function New-UnixReactEnv {
  param(
    [string]$Path,
    [string]$RelativeRoot,
    [int]$Port
  )

  $relativeRoot = ConvertTo-ForwardSlashPath $RelativeRoot
  $text = @"
APP_NAME="example-react-smoke"
APP_DISPLAY_NAME="Example React Smoke"
APP_RUNTIME="node"
APP_FRAMEWORK="reactjs"
NEXTJS_DEPLOYMENT_MODE="standalone"
REACT_DOCUMENT_ROOT="build"
APP_DIR="$relativeRoot/app"
NODE_BIN="/usr/bin/bash"
START_SCRIPT="server.js"
NODE_ARGUMENTS=""
APP_PORT="$Port"
BIND_ADDRESS="127.0.0.1"
HEALTH_URL="http://127.0.0.1:$Port/health"
LOG_DIR="$relativeRoot/logs"
SERVICE_MANAGER="bsdrc"
REVERSE_PROXY="none"
SERVICE_USER="nodeapp"
SERVICE_GROUP="nodeapp"
ENV_FILE="$relativeRoot/etc/example-react-smoke.env"
HEALTHCHECK_STATE_DIR="$relativeRoot/state"
PACKAGE_EXPECTED_FILES="server.js build/index.html"
"@

  Write-Utf8NoBom -Path $Path -Text (($text -replace "`r`n", "`n").Trim() + "`n")
}

function New-ReactZipPackage {
  param(
    [string]$RootDirectory,
    [string]$ZipPath,
    [switch]$WithoutIndex
  )

  $wrapper = Join-Path $RootDirectory "react-app"
  New-ReactLayout -AppDirectory $wrapper -WithoutIndex:$WithoutIndex
  if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -Path $wrapper -DestinationPath $ZipPath -Force
}

$tempRoot = Join-Path $RepoRoot (".tmp/react-support-" + [guid]::NewGuid().ToString("N"))
New-Directory $tempRoot

try {
  Write-Step "Windows React preflight"
  $windowsRoot = Join-Path $tempRoot "windows"
  $windowsApp = Join-Path $windowsRoot "app"
  New-ReactLayout -AppDirectory $windowsApp
  $windowsConfig = Join-Path $windowsRoot "app.config.json"
  New-WindowsReactConfig -Path $windowsConfig -AppDirectory $windowsApp -ServiceDirectory (Join-Path $windowsRoot "svc") -LogDirectory (Join-Path $windowsRoot "logs") -Port 39201
  & (Join-Path $RepoRoot "scripts/windows/Test-DeploymentPreflight.ps1") -ConfigPath $windowsConfig -SkipReverseProxy -SkipHealthCheck -AllowPortInUse

  $windowsBadRoot = Join-Path $tempRoot "windows-bad"
  $windowsBadApp = Join-Path $windowsBadRoot "app"
  New-ReactLayout -AppDirectory $windowsBadApp -WithoutIndex
  $windowsBadConfig = Join-Path $windowsBadRoot "app.config.json"
  New-WindowsReactConfig -Path $windowsBadConfig -AppDirectory $windowsBadApp -ServiceDirectory (Join-Path $windowsBadRoot "svc") -LogDirectory (Join-Path $windowsBadRoot "logs") -Port 39202
  Invoke-ExpectFailure -ExpectedText "React deployment root is missing index.html" -Script {
    & (Join-Path $RepoRoot "scripts/windows/Test-DeploymentPreflight.ps1") -ConfigPath $windowsBadConfig -SkipReverseProxy -SkipHealthCheck -AllowPortInUse
  }

  Write-Step "Windows React package import"
  $packageRoot = Join-Path $tempRoot "package"
  New-Directory $packageRoot
  $reactZip = Join-Path $packageRoot "react-app.zip"
  New-ReactZipPackage -RootDirectory $packageRoot -ZipPath $reactZip
  & (Join-Path $RepoRoot "scripts/windows/Test-ReactStaticPackage.ps1") -PackagePath $reactZip -ReactDocumentRoot "build" -StripSingleTopLevelDirectory
  $importRoot = Join-Path $tempRoot "import"
  $importConfig = Join-Path $importRoot "app.config.json"
  New-WindowsReactConfig -Path $importConfig -AppDirectory (Join-Path $importRoot "app") -ServiceDirectory (Join-Path $importRoot "svc") -LogDirectory (Join-Path $importRoot "logs") -Port 39203 -PackagePath $reactZip
  & (Join-Path $RepoRoot "scripts/windows/Import-AppPackage.ps1") -ConfigPath $importConfig
  $manifest = Get-Content -LiteralPath (Join-Path $importRoot "app\.node-enterprise-deploy.json") -Raw | ConvertFrom-Json
  if ([string]$manifest.appFramework -ne "reactjs" -or [string]$manifest.reactDocumentRoot -ne "build") {
    throw "React package import manifest did not record React framework metadata."
  }

  $badReactZip = Join-Path $packageRoot "react-app-missing-index.zip"
  New-ReactZipPackage -RootDirectory (Join-Path $tempRoot "bad-package") -ZipPath $badReactZip -WithoutIndex
  Invoke-ExpectFailure -ExpectedText "Package is missing React index.html" -Script {
    & (Join-Path $RepoRoot "scripts/windows/Test-ReactStaticPackage.ps1") -PackagePath $badReactZip -ReactDocumentRoot "build" -StripSingleTopLevelDirectory
  }

  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($bash) {
    Write-Step "Unix React preflight and package validation"
    $unixRoot = Join-Path $tempRoot "unix"
    $unixApp = Join-Path $unixRoot "app"
    New-ReactLayout -AppDirectory $unixApp
    $unixEnv = Join-Path $unixRoot "app.env"
    $unixRootBash = Resolve-BashVisiblePath -Bash $bash -Path $unixRoot
    New-UnixReactEnv -Path $unixEnv -RelativeRoot $unixRootBash -Port 39204
    $unixEnvBash = Resolve-BashVisiblePath -Bash $bash -Path $unixEnv
    Push-Location $RepoRoot
    try {
      & $bash.Source "scripts/linux/test-deployment-preflight.sh" $unixEnvBash --skip-reverse-proxy --skip-health-check --skip-service-manager-check
      if ($LASTEXITCODE -ne 0) {
        throw "Unix React preflight failed."
      }
    }
    finally {
      Pop-Location
    }

    $unixBadRoot = Join-Path $tempRoot "unix-bad"
    $unixBadApp = Join-Path $unixBadRoot "app"
    New-ReactLayout -AppDirectory $unixBadApp -WithoutIndex
    $unixBadEnv = Join-Path $unixBadRoot "app.env"
    $unixBadRootBash = Resolve-BashVisiblePath -Bash $bash -Path $unixBadRoot
    New-UnixReactEnv -Path $unixBadEnv -RelativeRoot $unixBadRootBash -Port 39205
    $unixBadEnvBash = Resolve-BashVisiblePath -Bash $bash -Path $unixBadEnv
    Push-Location $RepoRoot
    try {
      Invoke-ExpectFailure -ExpectedText "React deployment root is missing index.html" -Script {
        & $bash.Source "scripts/linux/test-deployment-preflight.sh" $unixBadEnvBash --skip-reverse-proxy --skip-health-check --skip-service-manager-check
      }
    }
    finally {
      Pop-Location
    }

    $tarParent = Join-Path $tempRoot "tar"
    $tarApp = Join-Path $tarParent "react-app"
    New-ReactLayout -AppDirectory $tarApp
    $tarPath = Join-Path $tarParent "react-app.tar"
    New-Directory $tarParent
    $tarParentBash = Escape-BashSingleQuoted (Resolve-BashVisiblePath -Bash $bash -Path $tarParent)
    & $bash.Source -lc "cd $tarParentBash && tar -cf react-app.tar react-app"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create React tar package."
    }
    Push-Location $RepoRoot
    try {
      & $bash.Source "scripts/linux/validate-react-static-package.sh" --package-path (Resolve-BashVisiblePath -Bash $bash -Path $tarPath) --react-document-root build --strip-single-top-level
      if ($LASTEXITCODE -ne 0) {
        throw "Unix React package validator failed."
      }
    }
    finally {
      Pop-Location
    }
  } else {
    Write-Host "bash was not found; skipping Unix React smoke checks."
  }
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host ""
Write-Host "React deployment support OK"
