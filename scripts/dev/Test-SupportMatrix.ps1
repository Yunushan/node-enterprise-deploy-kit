param(
  [string]$MatrixPath = ""
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

function Add-Issue {
  param(
    [System.Collections.Generic.List[string]]$Issues,
    [string]$Message
  )
  $Issues.Add($Message) | Out-Null
}

function Get-ArrayValue {
  param($Value)
  if ($null -eq $Value) { return @() }
  return @($Value)
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

function Test-ContainsAll {
  param(
    [string[]]$Actual,
    [string[]]$Expected
  )
  foreach ($item in $Expected) {
    if ($Actual -notcontains $item) {
      return $false
    }
  }
  return $true
}

function Test-DeclaredArtifacts {
  param(
    [System.Collections.Generic.List[string]]$Issues,
    [string]$TargetId,
    [string]$Kind,
    [string[]]$Values,
    [hashtable]$ArtifactMap
  )

  foreach ($value in $Values) {
    if (-not $ArtifactMap.ContainsKey($value)) {
      Add-Issue $Issues "$TargetId has no artifact map for $Kind '$value'."
      continue
    }
    foreach ($artifact in @($ArtifactMap[$value])) {
      if ([string]::IsNullOrWhiteSpace($artifact)) { continue }
      $artifactPath = Join-Path $RepoRoot $artifact
      if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        Add-Issue $Issues "$TargetId $Kind '$value' references missing repo artifact: $artifact."
      }
    }
  }
}

Write-Host ""
Write-Host "==> Support matrix"

if (-not (Test-Path -LiteralPath $MatrixPath -PathType Leaf)) {
  throw "Support matrix not found: $MatrixPath"
}

$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
$issues = New-Object System.Collections.Generic.List[string]

if ($matrix.schemaVersion -ne 1) {
  Add-Issue $issues "schemaVersion must be 1."
}

$requiredModes = @("standalone", "next-start")
$matrixRequiredModes = @(Get-ArrayValue $matrix.requiredNextJsModes)
if (-not (Test-ContainsAll -Actual $matrixRequiredModes -Expected $requiredModes)) {
  Add-Issue $issues "requiredNextJsModes must include standalone and next-start."
}

$requiredMinimumUptimeHours = $null
try {
  $requiredMinimumUptimeHours = [int]$matrix.requiredMinimumUptimeHours
} catch {
  $requiredMinimumUptimeHours = $null
}
if ($null -eq $requiredMinimumUptimeHours -or $requiredMinimumUptimeHours -lt 72) {
  Add-Issue $issues "requiredMinimumUptimeHours must be an integer greater than or equal to 72."
}

$targets = @(Get-ArrayValue $matrix.targets)
if ($targets.Count -eq 0) {
  Add-Issue $issues "targets must not be empty."
}

$requiredTargetIds = @(
  "windows-10",
  "windows-11",
  "windows-server-2012",
  "windows-server-2012-r2",
  "windows-server-2016",
  "windows-server-2019",
  "windows-server-2022",
  "windows-server-2025",
  "ubuntu",
  "debian",
  "linux-mint",
  "rhel",
  "oracle-linux",
  "centos",
  "centos-stream",
  "rocky",
  "almalinux",
  "fedora",
  "alpine",
  "macos",
  "freebsd",
  "openbsd",
  "netbsd"
)
$targetIds = @($targets | ForEach-Object { [string]$_.id })
foreach ($requiredId in $requiredTargetIds) {
  if ($targetIds -notcontains $requiredId) {
    Add-Issue $issues "Missing support matrix target: $requiredId."
  }
}

$duplicateIds = @($targetIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
foreach ($duplicateId in $duplicateIds) {
  Add-Issue $issues "Duplicate support matrix target id: $duplicateId."
}

$allowedCategories = @("windows-client", "windows-server", "linux", "macos", "bsd")
$allowedClaimLevels = @("template-ready", "ci-static-verified", "real-host-verified")
$allowedWindowsManagers = @("winsw", "nssm", "pm2")
$allowedUnixManagers = @("systemd", "systemv", "openrc", "launchd", "bsdrc")
$allowedWindowsProxies = @("iis", "none")
$allowedUnixProxies = @("nginx", "apache", "haproxy", "traefik", "none")
$fallbackManagerArtifacts = @{
  pm2 = @("scripts\windows\Install-PM2Fallback.ps1")
}
$serviceManagerArtifacts = @{
  winsw = @("scripts\windows\Install-NodeService.ps1", "scripts\windows\Ensure-WinSW.ps1", "templates\windows\winsw-service.xml.tpl")
  nssm = @("scripts\windows\Install-NSSMService.ps1")
  systemd = @("scripts\linux\install-node-service.sh", "templates\linux\systemd-node-app.service.tpl")
  systemv = @("scripts\linux\install-node-service.sh", "templates\linux\sysv-node-app.init.tpl")
  openrc = @("scripts\linux\install-node-service.sh", "templates\linux\openrc-node-app.init.tpl")
  launchd = @("scripts\linux\install-node-service.sh", "templates\linux\launchd-node-app.plist.tpl", "templates\linux\launchd-runner.sh.tpl")
  bsdrc = @("scripts\linux\install-node-service.sh", "templates\linux\bsdrc-node-app.init.tpl")
}
$reverseProxyArtifacts = @{
  iis = @("scripts\windows\Install-ReverseProxy.ps1", "scripts\windows\Install-IISReverseProxy.ps1", "templates\windows\iis-web.config.tpl")
  nginx = @("scripts\linux\install-reverse-proxy.sh", "scripts\linux\install-nginx-reverse-proxy.sh", "templates\linux\nginx-site.conf.tpl")
  apache = @("scripts\linux\install-reverse-proxy.sh", "scripts\linux\install-apache-reverse-proxy.sh", "templates\linux\apache-vhost.conf.tpl")
  haproxy = @("scripts\linux\install-reverse-proxy.sh", "scripts\linux\install-haproxy-reverse-proxy.sh", "templates\linux\haproxy.cfg.tpl")
  traefik = @("scripts\linux\install-reverse-proxy.sh", "scripts\linux\install-traefik-reverse-proxy.sh", "templates\linux\traefik-dynamic.yml.tpl")
  none = @()
}
$ciWorkflowText = Get-Content -LiteralPath (Join-Path $RepoRoot ".github\workflows\ci.yml") -Raw
$platformMatrixText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\dev\test-platform-matrix.sh") -Raw

foreach ($target in $targets) {
  $id = [string]$target.id
  if ([string]::IsNullOrWhiteSpace($id)) {
    Add-Issue $issues "A support matrix target is missing id."
    continue
  }
  if ($id -cmatch '[A-Z_\s]') {
    Add-Issue $issues "$id must be lowercase kebab-case."
  }
  if ([string]::IsNullOrWhiteSpace([string]$target.name)) {
    Add-Issue $issues "$id is missing name."
  }
  if ($allowedCategories -notcontains [string]$target.category) {
    Add-Issue $issues "$id has unsupported category: $($target.category)."
  }
  if ($allowedClaimLevels -notcontains [string]$target.minimumClaimLevel) {
    Add-Issue $issues "$id has unsupported minimumClaimLevel: $($target.minimumClaimLevel)."
  }

  $targetModes = @(Get-ArrayValue $target.nextjsModes)
  if (-not (Test-ContainsAll -Actual $targetModes -Expected $requiredModes)) {
    Add-Issue $issues "$id must include both Next.js modes: standalone and next-start."
  }

  $serviceManagers = @(Get-ArrayValue $target.serviceManagers)
  $fallbackManagers = @(Get-ArrayValue (Get-OptionalPropertyValue -Object $target -Name "fallbackManagers"))
  $reverseProxies = @(Get-ArrayValue $target.reverseProxies)
  $staticVerification = @(Get-ArrayValue $target.staticVerification)
  $evidenceTargets = @(Get-ArrayValue $target.evidenceTargets)

  if ($serviceManagers.Count -eq 0) {
    Add-Issue $issues "$id must list at least one service manager."
  }
  if ($reverseProxies.Count -eq 0) {
    Add-Issue $issues "$id must list at least one reverse proxy."
  }
  if ($reverseProxies -notcontains "none") {
    Add-Issue $issues "$id reverseProxies must include none for external load-balancer/service-only deployments."
  }
  if ($staticVerification.Count -eq 0) {
    Add-Issue $issues "$id must list staticVerification jobs."
  }
  if ($evidenceTargets.Count -eq 0) {
    Add-Issue $issues "$id must list evidenceTargets for Test-HostEvidence.ps1."
  }
  Test-DeclaredArtifacts -Issues $issues -TargetId $id -Kind "service manager" -Values ([string[]]$serviceManagers) -ArtifactMap $serviceManagerArtifacts
  Test-DeclaredArtifacts -Issues $issues -TargetId $id -Kind "fallback manager" -Values ([string[]]$fallbackManagers) -ArtifactMap $fallbackManagerArtifacts
  Test-DeclaredArtifacts -Issues $issues -TargetId $id -Kind "reverse proxy" -Values ([string[]]$reverseProxies) -ArtifactMap $reverseProxyArtifacts

  foreach ($job in $staticVerification) {
    if ($ciWorkflowText -notmatch "(?m)^\s*$([regex]::Escape($job)):\s*$") {
      Add-Issue $issues "$id references missing CI job: $job."
    }
  }

  switch ([string]$target.category) {
    "windows-client" {
      foreach ($manager in $serviceManagers) {
        if (@("winsw", "nssm") -notcontains $manager) {
          Add-Issue $issues "$id uses unsupported Windows service manager: $manager."
        }
      }
      foreach ($manager in $fallbackManagers) {
        if ($allowedWindowsManagers -notcontains $manager) {
          Add-Issue $issues "$id uses unsupported Windows fallback manager: $manager."
        }
      }
      foreach ($proxy in $reverseProxies) {
        if ($allowedWindowsProxies -notcontains $proxy) {
          Add-Issue $issues "$id uses unsupported Windows reverse proxy: $proxy."
        }
      }
      if ($evidenceTargets -notcontains $id) {
        Add-Issue $issues "$id evidenceTargets must include $id."
      }
    }
    "windows-server" {
      foreach ($manager in $serviceManagers) {
        if (@("winsw", "nssm") -notcontains $manager) {
          Add-Issue $issues "$id uses unsupported Windows Server service manager: $manager."
        }
      }
      foreach ($manager in $fallbackManagers) {
        Add-Issue $issues "$id should not declare Windows Server fallback manager '$manager' in real-host support claims."
      }
      foreach ($proxy in $reverseProxies) {
        if ($allowedWindowsProxies -notcontains $proxy) {
          Add-Issue $issues "$id uses unsupported Windows Server reverse proxy: $proxy."
        }
      }
      if ($evidenceTargets -notcontains $id) {
        Add-Issue $issues "$id evidenceTargets must include $id."
      }
    }
    "linux" {
      foreach ($manager in $serviceManagers) {
        if ($allowedUnixManagers -notcontains $manager) {
          Add-Issue $issues "$id uses unsupported Linux service manager: $manager."
        }
      }
      foreach ($proxy in $reverseProxies) {
        if ($allowedUnixProxies -notcontains $proxy) {
          Add-Issue $issues "$id uses unsupported Linux reverse proxy: $proxy."
        }
      }
      if ([string]::IsNullOrWhiteSpace([string]$target.platformMatrixCase)) {
        Add-Issue $issues "$id must set platformMatrixCase."
      } elseif ($platformMatrixText -notmatch "(?m)^\s*$([regex]::Escape([string]$target.platformMatrixCase))\)") {
        Add-Issue $issues "$id platformMatrixCase is not handled by test-platform-matrix.sh."
      }
      if ($evidenceTargets -notcontains "linux") {
        Add-Issue $issues "$id evidenceTargets must include linux."
      }
    }
    "macos" {
      if ($serviceManagers -notcontains "launchd") {
        Add-Issue $issues "$id must include launchd service manager."
      }
      foreach ($manager in $serviceManagers) {
        if ($manager -ne "launchd") {
          Add-Issue $issues "$id uses unexpected macOS service manager: $manager."
        }
      }
      foreach ($proxy in $reverseProxies) {
        if ($allowedUnixProxies -notcontains $proxy) {
          Add-Issue $issues "$id uses unsupported macOS reverse proxy: $proxy."
        }
      }
      if ($target.platformMatrixCase -ne "macos") {
        Add-Issue $issues "$id platformMatrixCase must be macos."
      }
      if ($evidenceTargets -notcontains "macos") {
        Add-Issue $issues "$id evidenceTargets must include macos."
      }
    }
    "bsd" {
      if ($serviceManagers -notcontains "bsdrc") {
        Add-Issue $issues "$id must include bsdrc service manager."
      }
      foreach ($manager in $serviceManagers) {
        if ($manager -ne "bsdrc") {
          Add-Issue $issues "$id uses unexpected BSD service manager: $manager."
        }
      }
      foreach ($proxy in $reverseProxies) {
        if ($allowedUnixProxies -notcontains $proxy) {
          Add-Issue $issues "$id uses unsupported BSD reverse proxy: $proxy."
        }
      }
      if ([string]::IsNullOrWhiteSpace([string]$target.platformMatrixCase)) {
        Add-Issue $issues "$id must set platformMatrixCase."
      } elseif ($platformMatrixText -notmatch "(?m)^\s*$([regex]::Escape([string]$target.platformMatrixCase))\)") {
        Add-Issue $issues "$id platformMatrixCase is not handled by test-platform-matrix.sh."
      }
      if ($evidenceTargets -notcontains "bsd") {
        Add-Issue $issues "$id evidenceTargets must include bsd."
      }
      if ($evidenceTargets -notcontains $id) {
        Add-Issue $issues "$id evidenceTargets must include $id."
      }
    }
  }
}

if ($issues.Count -gt 0) {
  $issues | ForEach-Object { Write-Host "  $_" }
  throw "Support matrix validation failed."
}

Write-Host "Support matrix OK"
