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

function Get-RelativePath {
  param([string]$Path)
  return $Path.Substring($RepoRoot.Length + 1).Replace("\", "/")
}

function Get-TrackedOrCandidateFiles {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    Push-Location $RepoRoot
    try {
      $files = @(& $git.Source ls-files --cached --others --exclude-standard)
      if ($LASTEXITCODE -eq 0 -and $files.Count -gt 0) {
        return @($files | ForEach-Object { $_ -replace "\\", "/" })
      }
    }
    finally {
      Pop-Location
    }
  }

  return @(Get-ChildItem -Path $RepoRoot -Recurse -File |
    Where-Object { $_.FullName -notmatch "\\\.git\\" } |
    ForEach-Object { Get-RelativePath $_.FullName })
}

function Test-BlockedReleasePath {
  param([string]$Path)

  $normalized = $Path -replace "\\", "/"
  if ($normalized -match '(^|/)(node_modules|\.next|dist|build|coverage|logs|\.tmp)/') { return $true }
  if ($normalized -in @("config/windows/app.config.json", "config/linux/app.env", ".env")) { return $true }
  if ($normalized -like ".env.*" -and $normalized -ne ".env.example") { return $true }
  if ($normalized -match '\.(key|pem|pfx|p12|crt|csr)$') { return $true }
  if ($normalized -match '^tools/(winsw|nssm)/.+\.exe$') { return $true }
  if ($normalized -match '\.(log|out|err)$') { return $true }
  return $false
}

Write-Step "Release package hygiene"
$files = @(Get-TrackedOrCandidateFiles)
$requiredFiles = @(
  ".gitattributes",
  ".github/workflows/ci.yml",
  "LICENSE",
  "README.md",
  "README.tr.md",
  "docs/NEXTJS_DEPLOYMENT.md",
  "docs/HOST_VERIFICATION.md",
  "docs/SUPPORT_MATRIX.md",
  "docs/RELEASE.md",
  "docs/BACKUP_RESTORE.md",
  ".github/workflows/host-evidence.yml",
  "config/support-matrix.example.json",
  "config/windows/app.config.example.json",
  "config/linux/app.env.example",
  "deploy.ps1",
  "install.ps1",
  "status.ps1",
  "restart.ps1",
  "rollback.ps1",
  "uninstall.ps1",
  "deploy.sh",
  "scripts/dev/Test-Repository.ps1",
  "scripts/dev/Test-SampleConfigs.ps1",
  "scripts/dev/Test-DocsConsistency.ps1",
  "scripts/dev/Test-ReleasePackage.ps1",
  "scripts/dev/Test-HostEvidence.ps1",
  "scripts/dev/New-SupportEvidencePlan.ps1",
  "scripts/dev/New-SupportEvidenceBundle.ps1",
  "scripts/dev/Test-SupportEvidenceBundle.ps1",
  "scripts/dev/Test-SupportClaim.ps1",
  "scripts/dev/Test-SupportEvidenceCoverage.ps1",
  "scripts/dev/Test-ReleaseSupportReadiness.ps1",
  "scripts/dev/Test-SupportMatrix.ps1",
  "scripts/dev/Test-WindowsServiceManagers.ps1",
  "scripts/dev/Test-HostEvidenceWorkflow.ps1",
  "scripts/dev/Test-NextJsSupport.ps1",
  "scripts/dev/test-unix-nextjs-support.sh",
  "scripts/dev/New-ReleasePackage.ps1",
  "scripts/windows/Ensure-WinSW.ps1",
  "scripts/windows/Deploy-LatestRelease.ps1",
  "scripts/windows/New-NextJsStandalonePackage.ps1",
  "scripts/windows/Test-NextJsStandalonePackage.ps1",
  "scripts/windows/Test-NextJsRuntimeLayout.ps1",
  "scripts/windows/Import-AppPackage.ps1",
  "scripts/linux/package-nextjs-standalone.sh",
  "scripts/linux/validate-nextjs-standalone-package.sh",
  "scripts/linux/test-nextjs-runtime-layout.sh",
  "scripts/linux/status-node-app.sh",
  "scripts/linux/import-app-package.sh",
  "scripts/linux/install-healthcheck-scheduler.sh",
  "scripts/windows/Restore-ManagedBackup.ps1",
  "ansible.cfg",
  "ansible/requirements.yml",
  "ansible/inventory.example.yml",
  "ansible/playbooks/site.yml"
)

foreach ($required in $requiredFiles) {
  if ($files -notcontains $required) {
    throw "Release package is missing required file: $required"
  }
}

$blocked = @($files | Where-Object { Test-BlockedReleasePath $_ })
if ($blocked.Count -gt 0) {
  Write-Host "Blocked paths found in release candidate:"
  $blocked | ForEach-Object { Write-Host "  $_" }
  throw "Release package hygiene check failed."
}

$attributesPath = Join-Path $RepoRoot ".gitattributes"
$attributes = Get-Content -Path $attributesPath -Raw
foreach ($pattern in @(
  "config/windows/app.config.json export-ignore",
  "config/linux/app.env export-ignore",
  "tools/winsw/*.exe export-ignore",
  "tools/nssm/*.exe export-ignore",
  "evidence/ export-ignore",
  ".tmp/ export-ignore"
)) {
  if ($attributes -notmatch [regex]::Escape($pattern)) {
    throw ".gitattributes is missing release export-ignore pattern: $pattern"
  }
}

Write-Host "Release package hygiene OK"
