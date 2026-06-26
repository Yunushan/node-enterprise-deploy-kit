param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$PinnedWinSWSha256 = "05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Get-RepoRelativePath {
  param([string]$Path)
  return $Path.Substring($RepoRoot.Length + 1).Replace("\", "/")
}

function Resolve-RepoFile {
  param([string]$Path)
  return Join-Path $RepoRoot ($Path -replace '/', '\')
}

function Read-RepoText {
  param([string]$Path)
  return Get-Content -Path (Resolve-RepoFile $Path) -Raw
}

function Assert-FileContainsText {
  param(
    [string]$Path,
    [string]$ExpectedText
  )

  $fullPath = Resolve-RepoFile $Path
  $text = Get-Content -Path $fullPath -Raw
  if (-not $text.Contains($ExpectedText)) {
    throw "$(Get-RepoRelativePath $fullPath) is missing expected text: $ExpectedText"
  }
}

function Assert-TextOrder {
  param(
    [string]$Path,
    [string]$FirstText,
    [string]$SecondText
  )

  $fullPath = Resolve-RepoFile $Path
  $text = Get-Content -Path $fullPath -Raw
  $firstIndex = $text.IndexOf($FirstText, [System.StringComparison]::Ordinal)
  $secondIndex = $text.IndexOf($SecondText, [System.StringComparison]::Ordinal)
  if ($firstIndex -lt 0) {
    throw "$(Get-RepoRelativePath $fullPath) is missing expected text: $FirstText"
  }
  if ($secondIndex -lt 0) {
    throw "$(Get-RepoRelativePath $fullPath) is missing expected text: $SecondText"
  }
  if ($firstIndex -gt $secondIndex) {
    throw "$(Get-RepoRelativePath $fullPath) should contain '$FirstText' before '$SecondText'."
  }
}

function Assert-ArrayContains {
  param(
    [object[]]$Values,
    [string]$Expected,
    [string]$Context
  )

  $normalized = @($Values | ForEach-Object { [string]$_ })
  if ($normalized -notcontains $Expected) {
    throw "$Context is missing '$Expected'."
  }
}

function Assert-DeployRouting {
  Write-Step "Windows deploy service-manager routing"

  foreach ($expected in @(
      'if ([string]$config.ServiceManager -eq "winsw")',
      'scripts\windows\Ensure-WinSW.ps1',
      'switch ($config.ServiceManager)',
      '"winsw" {',
      'scripts\windows\Install-NodeService.ps1',
      '"nssm"  { & (Join-Path $repoRoot "scripts\windows\Install-NSSMService.ps1") -ConfigPath $ConfigPath }',
      '"pm2"   { & (Join-Path $repoRoot "scripts\windows\Install-PM2Fallback.ps1") -ConfigPath $ConfigPath }',
      'Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2.',
      'scripts\windows\Install-ReverseProxy.ps1'
    )) {
    Assert-FileContainsText -Path "deploy.ps1" -ExpectedText $expected
  }
  Assert-FileContainsText -Path "deploy.ps1" -ExpectedText 'if (-not [string]::IsNullOrWhiteSpace($effectivePackagePath)) { $preflightArgs.PackagePath = $effectivePackagePath }'
  Assert-FileContainsText -Path "deploy.ps1" -ExpectedText 'if ($SkipPackageImport) { $preflightArgs.SkipPackageImport = $true }'
  Assert-TextOrder -Path "deploy.ps1" -FirstText 'scripts\windows\Test-DeploymentPreflight.ps1' -SecondText 'scripts\windows\Import-AppPackage.ps1'

  foreach ($expected in @(
      '$serviceManager = ([string]$config.ServiceManager).ToLowerInvariant()',
      '[string] $PackagePath = ""',
      '[switch] $SkipPackageImport',
      '$effectivePackagePath = $PackagePath',
      'if ($SkipPackageImport)',
      '"winsw" {',
      '"nssm" {',
      '"pm2" {',
      'Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2.'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Test-DeploymentPreflight.ps1" -ExpectedText $expected
  }
}

function Assert-WindowsReverseProxyRouting {
  Write-Step "Windows reverse-proxy routing"

  foreach ($expected in @(
      '[CmdletBinding(SupportsShouldProcess=$true)]',
      'switch ($reverseProxy)',
      '"iis" {',
      'scripts\windows\Install-IISReverseProxy.ps1',
      'ReverseProxy=none; skipping Windows reverse proxy install.',
      'Unsupported Windows ReverseProxy: $($config.ReverseProxy). Use iis or none.'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Install-ReverseProxy.ps1" -ExpectedText $expected
  }

  foreach ($expected in @(
      'Get-ConfigBool $config "IisRequireUrlRewrite" $true',
      'Get-ConfigBool $config "IisRequireArrProxy" $true',
      'IIS URL Rewrite module was not detected. Install URL Rewrite before using ReverseProxy=iis',
      'IIS Application Request Routing module was not detected. Install ARR before using ReverseProxy=iis'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Test-DeploymentPreflight.ps1" -ExpectedText $expected
    Assert-FileContainsText -Path "scripts/windows/Install-IISReverseProxy.ps1" -ExpectedText $expected
  }

  $tempRoot = Join-Path $RepoRoot ".tmp\windows-reverse-proxy-dispatcher"
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  $baseConfig = Get-Content -Path (Resolve-RepoFile "config/windows/app.config.example.json") -Raw | ConvertFrom-Json

  $iisConfig = $baseConfig.PSObject.Copy()
  $iisConfig.ReverseProxy = "iis"
  $iisConfigPath = Join-Path $tempRoot "iis.json"
  $iisConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $iisConfigPath -Encoding UTF8
  $iisOutput = & (Resolve-RepoFile "scripts/windows/Install-ReverseProxy.ps1") -ConfigPath $iisConfigPath -DryRun 2>&1 | Out-String
  if ($iisOutput -notmatch "Install-IISReverseProxy\.ps1") {
    throw "Install-ReverseProxy.ps1 dry-run did not route ReverseProxy=iis to Install-IISReverseProxy.ps1."
  }

  $noneConfig = $baseConfig.PSObject.Copy()
  $noneConfig.ReverseProxy = "none"
  $noneConfigPath = Join-Path $tempRoot "none.json"
  $noneConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $noneConfigPath -Encoding UTF8
  $noneOutput = & (Resolve-RepoFile "scripts/windows/Install-ReverseProxy.ps1") -ConfigPath $noneConfigPath -DryRun 2>&1 | Out-String
  if ($noneOutput -notmatch "ReverseProxy=none; skipping Windows reverse proxy install.") {
    throw "Install-ReverseProxy.ps1 dry-run did not skip ReverseProxy=none."
  }

  $badConfig = $baseConfig.PSObject.Copy()
  $badConfig.ReverseProxy = "apache"
  $badConfigPath = Join-Path $tempRoot "bad.json"
  $badConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $badConfigPath -Encoding UTF8
  try {
    & (Resolve-RepoFile "scripts/windows/Install-ReverseProxy.ps1") -ConfigPath $badConfigPath -DryRun 2>&1 | Out-Null
    throw "Install-ReverseProxy.ps1 accepted unsupported Windows ReverseProxy=apache."
  } catch {
    if ($_.Exception.Message -notmatch "Unsupported Windows ReverseProxy") {
      throw
    }
  }
}

function Assert-WindowsServiceEnvironmentContract {
  Write-Step "Windows service-manager runtime environment contract"

  $envTokens = @(
    '$map["NODE_ENV"] = "production"',
    '$map["PORT"] = [string]$Config.Port',
    '$map["APP_PORT"] = [string]$Config.Port',
    '$map["APP_NAME"] = [string]$Config.AppName',
    '$map["BIND_ADDRESS"] = $bindAddress',
    '$map["HOST"] = $bindAddress',
    '$map["HOSTNAME"] = $bindAddress'
  )

  foreach ($installer in @(
      "scripts/windows/Install-NodeService.ps1",
      "scripts/windows/Install-NSSMService.ps1",
      "scripts/windows/Install-PM2Fallback.ps1"
    )) {
    Assert-FileContainsText -Path $installer -ExpectedText "ConvertTo-ServiceEnvironmentMap"
    foreach ($token in $envTokens) {
      Assert-FileContainsText -Path $installer -ExpectedText $token
    }
  }

  foreach ($expected in @(
      "This installer supports ServiceManager='winsw'",
      'scripts\windows\Ensure-WinSW.ps1',
      'Assert-ServicePathCompatible',
      'Set-ServiceAccount $config',
      'sc.exe" @("failure", $config.AppName',
      '<executable>{{NODE_EXE}}</executable>',
      '<arguments>{{START_COMMAND}} {{NODE_ARGUMENTS}}</arguments>',
      '<workingdirectory>{{APP_DIRECTORY}}</workingdirectory>',
      '{{ENVIRONMENT_BLOCK}}',
      '<startmode>Automatic</startmode>',
      '<onfailure action="restart"'
    )) {
    $path = if ($expected.StartsWith("<") -or $expected.StartsWith("{{")) { "templates/windows/winsw-service.xml.tpl" } else { "scripts/windows/Install-NodeService.ps1" }
    Assert-FileContainsText -Path $path -ExpectedText $expected
  }

  foreach ($expected in @(
      "This installer supports ServiceManager='nssm'",
      '& $nssm install $config.AppName $config.NodeExe',
      '& $nssm set $config.AppName AppDirectory $config.AppDirectory',
      '& $nssm set $config.AppName AppParameters "$($config.StartCommand) $($config.NodeArguments)"',
      '& $nssm set $config.AppName AppEnvironmentExtra @environmentEntries',
      'sc.exe config $config.AppName start= auto',
      'sc.exe failure $config.AppName reset= 86400 actions= restart/60000/restart/60000/restart/300000'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Install-NSSMService.ps1" -ExpectedText $expected
  }

  foreach ($expected in @(
      "This installer supports ServiceManager='pm2'",
      'script = [string]$Config.StartCommand',
      'interpreter = [string]$Config.NodeExe',
      'args = Get-ConfigString $Config "NodeArguments" ""',
      'pm2 start $ecosystemPath --only $config.AppName --update-env',
      'PM2 fallback selected. For Windows enterprise production, WinSW is recommended.'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Install-PM2Fallback.ps1" -ExpectedText $expected
  }
}

function Assert-WindowsUninstallRouting {
  Write-Step "Windows uninstall service-manager routing"

  foreach ($expected in @(
      '[string] $NssmPath = "tools\nssm\nssm.exe"',
      'switch ($serviceManager)',
      '"winsw" { Uninstall-WinSWService $config }',
      '"nssm"  { Uninstall-NssmService $config $resolvedNssmPath }',
      '"pm2"   { Uninstall-Pm2Process $config }',
      'Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2.',
      'Invoke-NativeCommand $ResolvedNssmPath @("remove", $Config.AppName, "confirm") "NSSM remove" -IgnoreExitCode',
      'Falling back to sc.exe stop/delete',
      'Invoke-NativeCommand "pm2" @("delete", $Config.AppName) "pm2 delete" -IgnoreExitCode',
      'Remove-Item -LiteralPath $ecosystemPath -Force -ErrorAction SilentlyContinue',
      'Unregister-ScheduledTask -TaskName $taskName'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Uninstall-NodeService.ps1" -ExpectedText $expected
  }

  foreach ($expected in @(
      '[string] $NssmPath = "tools\nssm\nssm.exe"',
      'NssmPath = $NssmPath',
      '$uninstallArgs.RemoveHealthCheckTask = $true'
    )) {
    Assert-FileContainsText -Path "uninstall.ps1" -ExpectedText $expected
  }
}

function Assert-WindowsStatusEvidenceContract {
  Write-Step "Windows status evidence service-manager contract"

  foreach ($expected in @(
      '$supportTargetId = Get-WindowsSupportTargetId',
      'SupportTargetId = $supportTargetId',
      'ServiceManager = Get-ConfigString $config "ServiceManager" "winsw"',
      'ReverseProxy = Get-ConfigString $config "ReverseProxy" ""',
      'NextjsDeploymentMode = Get-ConfigString $config "NextjsDeploymentMode" ""'
    )) {
    Assert-FileContainsText -Path "status.ps1" -ExpectedText $expected
  }

  foreach ($expected in @(
      'ServiceManager = "winsw"',
      'SupportTargetId = "windows-11"',
      'Get-StringValue -Object $Evidence -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")',
      'Get-StringValue -Object $platform -Names @("SupportTargetId", "supportTargetId", "TargetId", "targetId")',
      'missing supportTargetId metadata required for matrix-level support claims'
    )) {
    Assert-FileContainsText -Path "scripts/dev/Test-HostEvidence.ps1" -ExpectedText $expected
  }
}

function Assert-WindowsSupportMatrixContract {
  Write-Step "Windows support matrix service-manager contract"

  $matrix = Get-Content -Path (Resolve-RepoFile "config/support-matrix.example.json") -Raw | ConvertFrom-Json
  $windowsTargets = @($matrix.targets | Where-Object { [string]$_.category -like "windows-*" })
  if ($windowsTargets.Count -lt 8) {
    throw "Support matrix should include Windows client and Windows Server targets."
  }

  foreach ($target in $windowsTargets) {
    $context = "support target '$($target.id)'"
    Assert-ArrayContains -Values @($target.serviceManagers) -Expected "winsw" -Context $context
    Assert-ArrayContains -Values @($target.serviceManagers) -Expected "nssm" -Context $context
    Assert-ArrayContains -Values @($target.reverseProxies) -Expected "iis" -Context $context
    Assert-ArrayContains -Values @($target.reverseProxies) -Expected "none" -Context $context
    Assert-ArrayContains -Values @($target.nextjsModes) -Expected "standalone" -Context $context
    Assert-ArrayContains -Values @($target.nextjsModes) -Expected "next-start" -Context $context
    Assert-ArrayContains -Values @($target.staticVerification) -Expected "windows-checks" -Context $context

    if ([string]$target.minimumClaimLevel -ne "real-host-verified") {
      throw "$context must require real-host-verified evidence."
    }
  }

  $windowsClients = @($windowsTargets | Where-Object { [string]$_.category -eq "windows-client" })
  foreach ($target in $windowsClients) {
    Assert-ArrayContains -Values @($target.fallbackManagers) -Expected "pm2" -Context "support target '$($target.id)' fallback managers"
  }
}

function Assert-WindowsExampleConfigContract {
  Write-Step "Windows example config service-manager defaults"

  $config = Get-Content -Path (Resolve-RepoFile "config/windows/app.config.example.json") -Raw | ConvertFrom-Json
  if ([string]$config.ServiceManager -ne "winsw") {
    throw "config/windows/app.config.example.json should default ServiceManager to winsw."
  }
  if ([string]$config.ReverseProxy -ne "iis") {
    throw "config/windows/app.config.example.json should default ReverseProxy to iis."
  }
  if ($config.IisRequireUrlRewrite -ne $true) {
    throw "config/windows/app.config.example.json should require IIS URL Rewrite by default."
  }
  if ($config.IisRequireArrProxy -ne $true) {
    throw "config/windows/app.config.example.json should require IIS ARR by default."
  }
  if ($config.RequireWinSWDownloadSha256 -ne $true) {
    throw "config/windows/app.config.example.json should require WinSW SHA256 verification by default."
  }
  if ([string]$config.WinSWDownloadSha256 -ne $PinnedWinSWSha256) {
    throw "config/windows/app.config.example.json should pin the official WinSW v2.12.0 x64 SHA256."
  }
  if ([string]$config.NextjsDeploymentMode -ne "standalone") {
    throw "config/windows/app.config.example.json should default NextjsDeploymentMode to standalone."
  }

  foreach ($expected in @(
      'Get-ConfigBool $config "RequireWinSWDownloadSha256" $true',
      'WinSWDownloadSha256 is required when RequireWinSWDownloadSha256 is true'
    )) {
    Assert-FileContainsText -Path "scripts/windows/Ensure-WinSW.ps1" -ExpectedText $expected
    Assert-FileContainsText -Path "scripts/windows/Test-DeploymentPreflight.ps1" -ExpectedText $expected
  }

  Assert-FileContainsText -Path "config/ansible/group_vars_all.example.yml" -ExpectedText "node_deploy_windows_require_winsw_download_sha256: true"
  Assert-FileContainsText -Path "config/ansible/group_vars_all.example.yml" -ExpectedText "node_deploy_windows_winsw_download_sha256: $PinnedWinSWSha256"
  Assert-FileContainsText -Path "ansible/roles/windows_node_service/templates/app.config.json.j2" -ExpectedText '"RequireWinSWDownloadSha256": {{ node_deploy_windows_require_winsw_download_sha256 | default(true) | bool | to_json }}'
  Assert-FileContainsText -Path "ansible/roles/windows_node_service/templates/app.config.json.j2" -ExpectedText $PinnedWinSWSha256
}

Assert-DeployRouting
Assert-WindowsReverseProxyRouting
Assert-WindowsServiceEnvironmentContract
Assert-WindowsUninstallRouting
Assert-WindowsStatusEvidenceContract
Assert-WindowsSupportMatrixContract
Assert-WindowsExampleConfigContract

Write-Host ""
Write-Host "Windows service-manager checks OK"
