param(
  [switch]$SkipShellSyntax,
  [switch]$SkipGitDiffCheck
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

function Test-BytesContainCrLf {
  param([byte[]]$Bytes)

  for ($i = 0; $i -lt ($Bytes.Length - 1); $i++) {
    if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10) {
      return $true
    }
  }
  return $false
}

function Test-PowerShellSyntax {
  Write-Step "PowerShell syntax"
  $failed = $false
  $files = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "*.ps1" |
    Where-Object { $_.FullName -notmatch "\\\.git\\" }

  foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $file.FullName,
      [ref]$tokens,
      [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
      $failed = $true
      Write-Host "Syntax errors in $($file.FullName)"
      $errors | ForEach-Object { Write-Host "  $($_.Message)" }
    }
  }

  if ($failed) { throw "PowerShell syntax check failed." }
  Write-Host "PowerShell syntax OK"
}

function Test-LineEndings {
  Write-Step "LF-only files"
  $patterns = @(
    "deploy.sh",
    "scripts/dev/*.sh",
    "scripts/linux/*.sh",
    "config/linux/*.env.example",
    "templates/linux/*",
    "ansible/roles/linux_node_service/templates/*"
  )
  $failed = @()

  foreach ($pattern in $patterns) {
    Get-ChildItem -Path (Join-Path $RepoRoot $pattern) -File -ErrorAction SilentlyContinue |
      ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        if (Test-BytesContainCrLf -Bytes $bytes) {
          $failed += $_.FullName.Substring($RepoRoot.Length + 1)
        }
      }
  }

  if ($failed.Count -gt 0) {
    Write-Host "CRLF line endings found in LF-only files:"
    $failed | ForEach-Object { Write-Host "  $_" }
    throw "Line ending check failed."
  }

  Write-Host "Line endings OK"
}

function Test-ShellSyntax {
  if ($SkipShellSyntax) {
    Write-Host "Skipping shell syntax check."
    return
  }

  Write-Step "Shell syntax"
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if (-not $bash) {
    throw "bash was not found. Install Git Bash, WSL, or run with -SkipShellSyntax."
  }

  Push-Location $RepoRoot
  try {
    & $bash.Source "scripts/dev/lint-shell-basic.sh"
    if ($LASTEXITCODE -ne 0) {
      throw "Shell syntax check failed."
    }
  }
  finally {
    Pop-Location
  }
}

function Test-UnixShellPortabilityPatterns {
  Write-Step "Unix shell portability patterns"
  $patterns = @(
    @{ Regex = 'date\s+-I'; Description = "GNU date -I is not portable to macOS/BSD; use a POSIX date format helper." },
    @{ Regex = 'date\s+-r\s+[^`r`n]*\s+-I'; Description = "date -r <file> -I is not portable to macOS/BSD; use stat fallback helpers." },
    @{ Regex = '\$\{[^}`r`n]+,,\}'; Description = "Bash 4 lowercase expansion is not portable to macOS Bash 3." },
    @{ Regex = '\bmapfile\b|\breadarray\b'; Description = "mapfile/readarray are not portable to macOS Bash 3." },
    @{ Regex = '\bdeclare\s+-A\b'; Description = "Associative arrays are not portable to macOS Bash 3." }
  )
  $paths = @(
    "deploy.sh",
    "scripts/dev/*.sh",
    "scripts/linux/*.sh",
    "templates/linux/*.tpl"
  )
  $failed = $false

  foreach ($path in $paths) {
    Get-ChildItem -Path (Join-Path $RepoRoot $path) -File -ErrorAction SilentlyContinue |
      ForEach-Object {
        $relativePath = $_.FullName.Substring($RepoRoot.Length + 1)
        $lineNumber = 0
        foreach ($line in Get-Content -Path $_.FullName) {
          $lineNumber++
          foreach ($pattern in $patterns) {
            if ($line -match $pattern.Regex) {
              Write-Host "$relativePath`:$lineNumber $($pattern.Description)"
              $failed = $true
            }
          }
        }
      }
  }

  if ($failed) { throw "Unix shell portability pattern check failed." }
  Write-Host "Unix shell portability patterns OK"
}

function Test-PlatformMatrix {
  if ($SkipShellSyntax) {
    Write-Host "Skipping platform matrix check."
    return
  }

  Write-Step "Platform matrix"
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if (-not $bash) {
    throw "bash was not found. Install Git Bash, WSL, or run with -SkipShellSyntax."
  }

  Push-Location $RepoRoot
  try {
    & $bash.Source "scripts/dev/test-platform-matrix.sh"
    if ($LASTEXITCODE -ne 0) {
      throw "Platform matrix check failed."
    }
  }
  finally {
    Pop-Location
  }
}

function Test-NoObviousSecrets {
  Write-Step "Obvious secret patterns"
  $patterns = @(
    "(?i)(password|secret|token|apikey|api_key)\s*[:=]\s*['""]?[A-Za-z0-9_\-]{12,}",
    "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"
  )
  $ignoreDirs = @(".git", ".tmp", "node_modules", ".next", "dist", "build")
  $binaryExt = @(".png", ".jpg", ".jpeg", ".gif", ".zip", ".exe")
  $failed = $false

  Get-ChildItem -Path $RepoRoot -Recurse -File |
    Where-Object {
      $path = $_.FullName
      -not ($ignoreDirs | Where-Object { $path -like "*\$_\*" }) -and
      $binaryExt -notcontains $_.Extension.ToLowerInvariant()
    } |
    ForEach-Object {
      $text = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
      foreach ($pattern in $patterns) {
        if ($text -match $pattern) {
          Write-Host "Potential secret pattern in $($_.FullName.Substring($RepoRoot.Length + 1))"
          $failed = $true
          break
        }
      }
    }

  if ($failed) { throw "Secret pattern check failed." }
  Write-Host "No obvious secrets found."
}

function Test-GitDiffCheck {
  if ($SkipGitDiffCheck) {
    Write-Host "Skipping git diff --check."
    return
  }

  Write-Step "Git whitespace"
  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) {
    Write-Host "git was not found; skipping git diff --check."
    return
  }

  Push-Location $RepoRoot
  try {
    & $git.Source -c core.autocrlf=false -c core.safecrlf=false diff --check
    if ($LASTEXITCODE -ne 0) {
      throw "git diff --check failed."
    }
  }
  finally {
    Pop-Location
  }
}

function Test-SampleConfigsAndTemplates {
  Write-Step "Sample configs and templates"
  & (Join-Path $ScriptDir "Test-SampleConfigs.ps1")
}

function Test-NextJsSupport {
  & (Join-Path $ScriptDir "Test-NextJsSupport.ps1")
}

function Test-ReactSupport {
  & (Join-Path $ScriptDir "Test-ReactSupport.ps1")
}

function Test-NextJsRuntimeSmoke {
  & (Join-Path $ScriptDir "Test-NextJsRuntimeSmoke.ps1")
}

function Test-ReleasePackageHygiene {
  & (Join-Path $ScriptDir "Test-ReleasePackage.ps1")
}

function Test-HostEvidenceSelfTest {
  & (Join-Path $ScriptDir "Test-HostEvidence.ps1") -SelfTest -RequireNextJs -RequireReverseProxy -RequireDeploymentIdentity
}

function Test-SupportMatrix {
  & (Join-Path $ScriptDir "Test-SupportMatrix.ps1")
}

function Test-WindowsServiceManagers {
  & (Join-Path $ScriptDir "Test-WindowsServiceManagers.ps1")
}

function Test-HostEvidenceWorkflow {
  & (Join-Path $ScriptDir "Test-HostEvidenceWorkflow.ps1")
}

function Test-SupportClaimSelfTest {
  & (Join-Path $ScriptDir "Test-SupportClaim.ps1") -SelfTest
}

function Test-SupportEvidencePlanSelfTest {
  & (Join-Path $ScriptDir "New-SupportEvidencePlan.ps1") -SelfTest
}

function Test-SupportEvidenceBundleSelfTest {
  & (Join-Path $ScriptDir "New-SupportEvidenceBundle.ps1") -SelfTest
}

function Test-SupportEvidenceBundleVerifierSelfTest {
  & (Join-Path $ScriptDir "Test-SupportEvidenceBundle.ps1") -SelfTest
}

function Test-SupportEvidenceCoverageSelfTest {
  & (Join-Path $ScriptDir "Test-SupportEvidenceCoverage.ps1") -SelfTest
}

function Test-HostEvidenceArtifactImportSelfTest {
  & (Join-Path $ScriptDir "Import-HostEvidenceArtifacts.ps1") -SelfTest
}

function Test-SupportEvidenceReleaseWorkflowSelfTest {
  & (Join-Path $ScriptDir "Invoke-SupportEvidenceReleaseWorkflow.ps1") -SelfTest
}

function Test-ReleaseSupportReadinessSelfTest {
  & (Join-Path $ScriptDir "Test-ReleaseSupportReadiness.ps1") -SelfTest
}

function Test-DocsConsistency {
  & (Join-Path $ScriptDir "Test-DocsConsistency.ps1")
}

Test-PowerShellSyntax
Test-LineEndings
Test-ShellSyntax
Test-UnixShellPortabilityPatterns
Test-PlatformMatrix
Test-SampleConfigsAndTemplates
Test-NextJsSupport
Test-ReactSupport
Test-NextJsRuntimeSmoke
Test-ReleasePackageHygiene
Test-HostEvidenceSelfTest
Test-SupportMatrix
Test-WindowsServiceManagers
Test-HostEvidenceWorkflow
Test-SupportClaimSelfTest
Test-SupportEvidencePlanSelfTest
Test-SupportEvidenceBundleSelfTest
Test-SupportEvidenceBundleVerifierSelfTest
Test-SupportEvidenceCoverageSelfTest
Test-HostEvidenceArtifactImportSelfTest
Test-SupportEvidenceReleaseWorkflowSelfTest
Test-ReleaseSupportReadinessSelfTest
Test-DocsConsistency
Test-NoObviousSecrets
Test-GitDiffCheck

Write-Host ""
Write-Host "Repository verification OK"
