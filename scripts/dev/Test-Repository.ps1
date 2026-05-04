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

Test-PowerShellSyntax
Test-LineEndings
Test-ShellSyntax
Test-SampleConfigsAndTemplates
Test-NoObviousSecrets
Test-GitDiffCheck

Write-Host ""
Write-Host "Repository verification OK"
