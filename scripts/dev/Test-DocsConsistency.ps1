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

function Resolve-RepoPath {
  param(
    [string]$BaseDirectory,
    [string]$Target
  )

  $targetPath = $Target -replace '/', '\'
  if ([System.IO.Path]::IsPathRooted($targetPath)) {
    return $targetPath
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $targetPath))
}

function Test-ExternalOrSpecialLink {
  param([string]$Target)

  return (
    $Target -match '^(https?|mailto):' -or
    $Target.StartsWith("#") -or
    $Target.StartsWith("data:") -or
    $Target.StartsWith("javascript:")
  )
}

function ConvertTo-GitHubAnchor {
  param([string]$Heading)

  $text = $Heading -replace '<[^>]+>', ''
  $text = $text -replace '`', ''
  $text = $text.Trim().ToLowerInvariant()
  $text = $text -replace '&amp;', 'and'
  $text = $text -replace '[^a-z0-9 _-]', ''
  $text = $text -replace '\s+', '-'
  $text = $text -replace '-+', '-'
  return $text.Trim('-')
}

function Get-MarkdownAnchors {
  param([string]$Text)

  $anchors = New-Object System.Collections.Generic.HashSet[string]
  foreach ($match in [regex]::Matches($Text, '(?m)^(#{1,6})\s+(.+?)\s*$')) {
    $anchor = ConvertTo-GitHubAnchor $match.Groups[2].Value
    if ($anchor) { [void]$anchors.Add($anchor) }
  }
  foreach ($match in [regex]::Matches($Text, '(?is)<h[1-6][^>]*>(.*?)</h[1-6]>')) {
    $anchor = ConvertTo-GitHubAnchor $match.Groups[1].Value
    if ($anchor) { [void]$anchors.Add($anchor) }
  }
  return $anchors
}

function Split-LinkTarget {
  param([string]$Target)

  $path = $Target
  $anchor = ""
  $hashIndex = $Target.IndexOf("#")
  if ($hashIndex -ge 0) {
    $path = $Target.Substring(0, $hashIndex)
    $anchor = $Target.Substring($hashIndex + 1)
  }
  return [pscustomobject]@{
    Path = $path
    Anchor = $anchor
  }
}

function Get-DocFiles {
  Get-ChildItem -Path $RepoRoot -Recurse -File -Include "*.md" |
    Where-Object {
      $relative = Get-RelativePath $_.FullName
      $relative -notmatch '(^|/)(\.git|\.tmp|node_modules|\.next|dist|build|coverage)(/|$)'
    }
}

Write-Step "Docs consistency"
$failures = New-Object System.Collections.Generic.List[string]
$docFiles = @(Get-DocFiles)
$requiredFiles = @(
  "README.md",
  "SECURITY.md",
  "CONTRIBUTING.md",
  "docs/ARCHITECTURE.md",
  "docs/WINDOWS_DEPLOYMENT.md",
  "docs/LINUX_DEPLOYMENT.md",
  "docs/HEALTH_CHECKS.md",
  "docs/BACKUP_RESTORE.md",
  "docs/RUNBOOK.md",
  "docs/TROUBLESHOOTING.md",
  "docs/HARDENING.md",
  "docs/RELEASE.md",
  "docs/VARIABLES.md",
  "docs/ANSIBLE.md",
  "docs/assets/logo.svg",
  "rollback.ps1",
  "scripts/dev/Test-ReleasePackage.ps1",
  "scripts/dev/New-ReleasePackage.ps1",
  "scripts/windows/Restore-ManagedBackup.ps1"
)

foreach ($required in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($required -replace '/', '\')))) {
    $failures.Add("Missing documented repository file: $required") | Out-Null
  }
}

foreach ($file in $docFiles) {
  $relative = Get-RelativePath $file.FullName
  $baseDirectory = Split-Path -Parent $file.FullName
  $text = Get-Content -Path $file.FullName -Raw
  $anchors = Get-MarkdownAnchors $text
  $targets = New-Object System.Collections.Generic.List[string]

  foreach ($match in [regex]::Matches($text, '(?<!\!)\[[^\]]+\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
    $targets.Add($match.Groups[1].Value) | Out-Null
  }
  foreach ($match in [regex]::Matches($text, '!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
    $targets.Add($match.Groups[1].Value) | Out-Null
  }
  foreach ($match in [regex]::Matches($text, '(?i)\b(?:href|src)="([^"]+)"')) {
    $targets.Add($match.Groups[1].Value) | Out-Null
  }

  foreach ($target in @($targets | Sort-Object -Unique)) {
    if (Test-ExternalOrSpecialLink $target) {
      if ($target.StartsWith("#")) {
        $anchor = $target.Substring(1)
        if ($anchor -and -not $anchors.Contains($anchor)) {
          $failures.Add("$relative references missing anchor: $target") | Out-Null
        }
      }
      continue
    }

    $parts = Split-LinkTarget $target
    if ([string]::IsNullOrWhiteSpace($parts.Path)) {
      continue
    }
    $resolved = Resolve-RepoPath -BaseDirectory $baseDirectory -Target $parts.Path
    if (-not (Test-Path -LiteralPath $resolved)) {
      $failures.Add("$relative references missing path: $target") | Out-Null
      continue
    }
    if ($parts.Anchor -and [System.IO.Path]::GetExtension($resolved).ToLowerInvariant() -eq ".md") {
      $targetText = Get-Content -Path $resolved -Raw
      $targetAnchors = Get-MarkdownAnchors $targetText
      if (-not $targetAnchors.Contains($parts.Anchor)) {
        $failures.Add("$relative references missing anchor in $($parts.Path): #$($parts.Anchor)") | Out-Null
      }
    }
  }
}

if ($failures.Count -gt 0) {
  $failures | ForEach-Object { Write-Host "  $_" }
  throw "Docs consistency check failed."
}

Write-Host "Docs consistency OK"
