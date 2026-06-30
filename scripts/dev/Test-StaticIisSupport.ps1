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

function New-StaticIisWebConfigText {
  param([switch]$WithRewrite)

  if ($WithRewrite) {
    return @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="UnsupportedRewrite" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="/_shell.html" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@
  }

  return @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <remove fileExtension=".json" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
    </staticContent>
    <defaultDocument enabled="true">
      <files>
        <clear />
        <add value="_shell.html" />
        <add value="index.html" />
      </files>
    </defaultDocument>
    <httpErrors errorMode="Custom" existingResponse="Replace">
      <remove statusCode="404" subStatusCode="-1" />
      <error statusCode="404" path="/_shell.html" responseMode="ExecuteURL" />
    </httpErrors>
  </system.webServer>
</configuration>
"@
}

function New-StaticIisLayout {
  param(
    [string]$AppDirectory,
    [switch]$WithoutShell,
    [switch]$WithRewriteConfig
  )

  $staticRoot = Join-Path $AppDirectory "dist\client"
  New-Directory (Join-Path $staticRoot "assets")
  if (-not $WithoutShell) {
    Write-Utf8NoBom -Path (Join-Path $staticRoot "_shell.html") -Text "<!doctype html><div id=`"root`"></div>`n"
  }
  Write-Utf8NoBom -Path (Join-Path $staticRoot "assets\app.js") -Text "console.log('static spa');`n"
  Write-Utf8NoBom -Path (Join-Path $staticRoot "web.config") -Text (New-StaticIisWebConfigText -WithRewrite:$WithRewriteConfig)
}

function New-WindowsStaticIisConfig {
  param(
    [string]$Path,
    [string]$AppDirectory,
    [string]$SitePath,
    [string]$BackupDirectory,
    [string]$PackagePath = ""
  )

  $config = [ordered]@{
    AppName = "ExampleStaticSpa"
    DisplayName = "Example Static SPA"
    Description = "Example static SPA smoke config"
    DeploymentMode = "static_iis"
    AppFramework = "tanstack-start"
    StaticOutputDirectory = "dist/client"
    SpaShellFile = "_shell.html"
    AppDirectory = $AppDirectory
    PackagePath = $PackagePath
    PackageExpectedFiles = @("dist/client/_shell.html", "dist/client/assets", "dist/client/web.config")
    PackageStripSingleTopLevelDirectory = $true
    InstallCommand = "npm ci --include=dev"
    BuildCommand = "npm run build"
    ServiceManager = "none"
    ReverseProxy = "iis"
    IisSitePath = $SitePath
    IisSiteName = "ExampleStaticSpa"
    IisAppPoolName = "ExampleStaticSpa-AppPool"
    PublicHostName = "app.example.local"
    PublicPort = 80
    TlsEnabled = $false
    IisCertificateThumbprint = ""
    IisRequireUrlRewrite = $false
    IisRequireArrProxy = $false
    IisStaticAllowUrlRewrite = $false
    BackupDirectory = $BackupDirectory
  }

  Write-Utf8NoBom -Path $Path -Text (($config | ConvertTo-Json -Depth 20) + "`n")
}

function New-StaticIisZipPackage {
  param(
    [string]$RootDirectory,
    [string]$ZipPath,
    [switch]$WithoutShell,
    [switch]$WithRewriteConfig
  )

  $wrapper = Join-Path $RootDirectory "static-spa"
  New-StaticIisLayout -AppDirectory $wrapper -WithoutShell:$WithoutShell -WithRewriteConfig:$WithRewriteConfig
  if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -Path $wrapper -DestinationPath $ZipPath -Force
}

$tempRoot = Join-Path $RepoRoot (".tmp/static-iis-support-" + [guid]::NewGuid().ToString("N"))
New-Directory $tempRoot

try {
  Write-Step "Windows static_iis preflight without IIS checks"
  $windowsRoot = Join-Path $tempRoot "windows"
  $windowsApp = Join-Path $windowsRoot "app"
  New-StaticIisLayout -AppDirectory $windowsApp
  $windowsConfig = Join-Path $windowsRoot "app.config.json"
  New-WindowsStaticIisConfig -Path $windowsConfig -AppDirectory $windowsApp -SitePath (Join-Path $windowsRoot "site") -BackupDirectory (Join-Path $windowsRoot "backups")
  & (Join-Path $RepoRoot "scripts/windows/Test-DeploymentPreflight.ps1") -ConfigPath $windowsConfig -SkipReverseProxy -SkipHealthCheck

  $windowsBadRoot = Join-Path $tempRoot "windows-bad"
  $windowsBadApp = Join-Path $windowsBadRoot "app"
  New-StaticIisLayout -AppDirectory $windowsBadApp -WithoutShell
  $windowsBadConfig = Join-Path $windowsBadRoot "app.config.json"
  New-WindowsStaticIisConfig -Path $windowsBadConfig -AppDirectory $windowsBadApp -SitePath (Join-Path $windowsBadRoot "site") -BackupDirectory (Join-Path $windowsBadRoot "backups")
  Invoke-ExpectFailure -ExpectedText "Static output directory is missing SPA shell file" -Script {
    & (Join-Path $RepoRoot "scripts/windows/Test-DeploymentPreflight.ps1") -ConfigPath $windowsBadConfig -SkipReverseProxy -SkipHealthCheck
  }

  Write-Step "Windows static_iis package validation and import"
  $packageRoot = Join-Path $tempRoot "package"
  New-Directory $packageRoot
  $staticZip = Join-Path $packageRoot "static-spa.zip"
  New-StaticIisZipPackage -RootDirectory $packageRoot -ZipPath $staticZip
  & (Join-Path $RepoRoot "scripts/windows/Test-StaticIisPackage.ps1") -PackagePath $staticZip -StaticOutputDirectory "dist/client" -SpaShellFile "_shell.html" -StripSingleTopLevelDirectory 6>$null

  $importRoot = Join-Path $tempRoot "import"
  $importConfig = Join-Path $importRoot "app.config.json"
  New-WindowsStaticIisConfig -Path $importConfig -AppDirectory (Join-Path $importRoot "app") -SitePath (Join-Path $importRoot "site") -BackupDirectory (Join-Path $importRoot "backups") -PackagePath $staticZip
  & (Join-Path $RepoRoot "scripts/windows/Import-AppPackage.ps1") -ConfigPath $importConfig | Out-Null
  foreach ($expected in @("dist\client\_shell.html", "dist\client\assets\app.js", "dist\client\web.config")) {
    if (-not (Test-Path -LiteralPath (Join-Path $importRoot "app\$expected"))) {
      throw "Static IIS package import missed expected path: $expected"
    }
  }
  $manifest = Get-Content -LiteralPath (Join-Path $importRoot "app\.node-enterprise-deploy.json") -Raw | ConvertFrom-Json
  if ([string]$manifest.deploymentMode -ne "static-iis" -or [string]$manifest.staticOutputDirectory -ne "dist/client" -or [string]$manifest.spaShellFile -ne "_shell.html") {
    throw "Static IIS package import manifest did not record static_iis metadata."
  }

  $missingShellZip = Join-Path $packageRoot "static-spa-missing-shell.zip"
  New-StaticIisZipPackage -RootDirectory (Join-Path $tempRoot "missing-shell-package") -ZipPath $missingShellZip -WithoutShell
  Invoke-ExpectFailure -ExpectedText "Package is missing static_iis SPA shell file" -Script {
    & (Join-Path $RepoRoot "scripts/windows/Test-StaticIisPackage.ps1") -PackagePath $missingShellZip -StaticOutputDirectory "dist/client" -SpaShellFile "_shell.html" -StripSingleTopLevelDirectory
  }

  $rewriteZip = Join-Path $packageRoot "static-spa-rewrite.zip"
  New-StaticIisZipPackage -RootDirectory (Join-Path $tempRoot "rewrite-package") -ZipPath $rewriteZip -WithRewriteConfig
  Invoke-ExpectFailure -ExpectedText "unsupported <rewrite> section" -Script {
    & (Join-Path $RepoRoot "scripts/windows/Test-StaticIisPackage.ps1") -PackagePath $rewriteZip -StaticOutputDirectory "dist/client" -SpaShellFile "_shell.html" -StripSingleTopLevelDirectory
  }

  Write-Step "Windows static_iis generated web.config and dispatcher"
  $renderedWebConfig = (& (Join-Path $RepoRoot "scripts/windows/Install-IISStaticSite.ps1") -ConfigPath $windowsConfig -RenderWebConfigOnly | Out-String)
  if ($renderedWebConfig -match "<rewrite>") {
    throw "Generated static_iis web.config must not contain rewrite rules."
  }
  [xml]$renderedXml = $renderedWebConfig
  $defaultDocuments = @($renderedXml.SelectNodes("//*[local-name()='defaultDocument']/*[local-name()='files']/*[local-name()='add']") | ForEach-Object { [string]$_.value })
  if ($defaultDocuments -notcontains "_shell.html") {
    throw "Generated static_iis web.config is missing _shell.html defaultDocument."
  }
  $fallbacks = @($renderedXml.SelectNodes("//*[local-name()='httpErrors']/*[local-name()='error']") | Where-Object {
      [string]$_.statusCode -eq "404" -and
      [string]$_.path -eq "/_shell.html" -and
      [string]$_.responseMode -eq "ExecuteURL"
    })
  if ($fallbacks.Count -eq 0) {
    throw "Generated static_iis web.config is missing 404 ExecuteURL fallback."
  }

  $dispatcherOutput = & (Join-Path $RepoRoot "scripts/windows/Install-ReverseProxy.ps1") -ConfigPath $windowsConfig -DryRun 2>&1 | Out-String
  if ($dispatcherOutput -notmatch "Install-IISStaticSite\.ps1") {
    throw "Install-ReverseProxy.ps1 dry-run did not route DeploymentMode=static_iis to Install-IISStaticSite.ps1."
  }
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

Write-Host ""
Write-Host "Static IIS support checks OK"
