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
  $ignoredDirectoryNames = @(".git", ".tmp", "node_modules", ".next", "dist", "build", "coverage")
  $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
  $pending.Push((Get-Item -LiteralPath $RepoRoot))

  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue) {
      if ($item.PSIsContainer) {
        if ($ignoredDirectoryNames -notcontains $item.Name) {
          $pending.Push($item)
        }
        continue
      }
      if ($item.Extension -ieq ".md") {
        $item
      }
    }
  }
}

Write-Step "Docs consistency"
$failures = New-Object System.Collections.Generic.List[string]
$docFiles = @(Get-DocFiles)
$requiredFiles = @(
  "README.md",
  "README.tr.md",
  "SECURITY.md",
  "CONTRIBUTING.md",
  "docs/ARCHITECTURE.md",
  "docs/NEXTJS_DEPLOYMENT.md",
  "docs/REACT_DEPLOYMENT.md",
  "docs/WINDOWS_DEPLOYMENT.md",
  "docs/LINUX_DEPLOYMENT.md",
  "docs/HEALTH_CHECKS.md",
  "docs/HOST_VERIFICATION.md",
  "docs/SUPPORT_MATRIX.md",
  "docs/BACKUP_RESTORE.md",
  "docs/RUNBOOK.md",
  "docs/TROUBLESHOOTING.md",
  "docs/HARDENING.md",
  "docs/RELEASE.md",
  "docs/VARIABLES.md",
  "docs/ANSIBLE.md",
  "docs/assets/logo.svg",
  ".github/workflows/host-evidence.yml",
  "config/support-matrix.example.json",
  "config/linux/app.env.next-start.example",
  "config/linux/app.env.macos.example",
  "config/linux/app.env.bsd.example",
  "config/windows/next-start.app.config.example.json",
  "config/windows/static-iis.app.config.example.json",
  "rollback.ps1",
  "scripts/windows/Ensure-WinSW.ps1",
  "scripts/windows/Deploy-LatestRelease.ps1",
  "scripts/windows/New-NextJsStandalonePackage.ps1",
  "scripts/windows/Test-NextJsStandalonePackage.ps1",
  "scripts/windows/Test-NextJsRuntimeLayout.ps1",
  "scripts/windows/Test-ReactStaticPackage.ps1",
  "scripts/windows/Test-StaticIisPackage.ps1",
  "scripts/windows/Install-IISStaticSite.ps1",
  "scripts/windows/Import-AppPackage.ps1",
  "scripts/windows/Install-ReverseProxy.ps1",
  "scripts/linux/package-nextjs-standalone.sh",
  "scripts/linux/validate-nextjs-standalone-package.sh",
  "scripts/linux/validate-react-static-package.sh",
  "scripts/linux/test-nextjs-runtime-layout.sh",
  "scripts/linux/status-node-app.sh",
  "scripts/linux/import-app-package.sh",
  "scripts/dev/Test-ReleasePackage.ps1",
  "scripts/dev/Test-HostEvidence.ps1",
  "scripts/dev/New-SupportEvidencePlan.ps1",
  "scripts/dev/New-SupportEvidenceCollectionPack.ps1",
  "scripts/dev/Import-HostEvidenceArtifacts.ps1",
  "scripts/dev/Invoke-SupportEvidenceReleaseWorkflow.ps1",
  "scripts/dev/New-SupportEvidenceBundle.ps1",
  "scripts/dev/Test-SupportEvidenceBundle.ps1",
  "scripts/dev/Test-SupportClaim.ps1",
  "scripts/dev/Test-SupportEvidenceCoverage.ps1",
  "scripts/dev/Test-ReleaseSupportReadiness.ps1",
  "scripts/dev/Test-SupportMatrix.ps1",
  "scripts/dev/Test-WindowsServiceManagers.ps1",
  "scripts/dev/Test-HostEvidenceWorkflow.ps1",
  "scripts/dev/Test-HostEvidenceWorkflowInputs.ps1",
  "scripts/dev/Test-NextJsSupport.ps1",
  "scripts/dev/Test-ReactSupport.ps1",
  "scripts/dev/Test-StaticIisSupport.ps1",
  "scripts/dev/lint-shellcheck.sh",
  "scripts/dev/test-linux-container-smoke.sh",
  "scripts/dev/test-unix-nextjs-support.sh",
  "scripts/dev/New-ReleasePackage.ps1",
  "scripts/windows/Restore-ManagedBackup.ps1"
)

foreach ($required in $requiredFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($required -replace '/', '\')))) {
    $failures.Add("Missing documented repository file: $required") | Out-Null
  }
}

$requiredDocSnippets = @(
  @{ Path = "README.md"; Snippets = @("supportScope.kind", "supportScope.proofLevel", "filtered or production-runtime-only result is not a full-matrix release claim") },
  @{ Path = "docs/HOST_VERIFICATION.md"; Snippets = @("supportScope.kind", "supportScope.proofLevel", "filtered or production-runtime-only result is not a full-matrix release claim") },
  @{ Path = "docs/RELEASE.md"; Snippets = @("supportScope.kind", "supportScope.proofLevel", "filtered or production-runtime-only result is not a full-matrix release claim") },
  @{ Path = "docs/SUPPORT_MATRIX.md"; Snippets = @("supportScope.kind", "supportScope.proofLevel", "filtered or production-runtime-only result is not a full-matrix release claim") }
)

foreach ($expectation in $requiredDocSnippets) {
  $docPath = Join-Path $RepoRoot (($expectation.Path) -replace '/', '\')
  if (-not (Test-Path -LiteralPath $docPath -PathType Leaf)) {
    continue
  }
  $docText = Get-Content -LiteralPath $docPath -Raw
  foreach ($snippet in @($expectation.Snippets)) {
    if (-not $docText.Contains($snippet)) {
      $failures.Add("$($expectation.Path) is missing required release-readiness text: $snippet") | Out-Null
    }
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
