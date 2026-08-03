[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$githubRoot = Join-Path $RepoRoot ".github"
$workflowRoot = Join-Path $githubRoot "workflows"
$actionRoot = Join-Path $githubRoot "actions"

$expectedActions = [ordered]@{
  "actions/checkout" = [pscustomobject]@{
    Sha = "3d3c42e5aac5ba805825da76410c181273ba90b1"
    Version = "v7"
  }
  "actions/setup-node" = [pscustomobject]@{
    Sha = "820762786026740c76f36085b0efc47a31fe5020"
    Version = "v7"
  }
  "actions/upload-artifact" = [pscustomobject]@{
    Sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
    Version = "v7"
  }
  "actions/download-artifact" = [pscustomobject]@{
    Sha = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
    Version = "v8"
  }
}

$workflowFiles = @(
  Get-ChildItem -LiteralPath $workflowRoot -File |
    Where-Object { $_.Extension -in @(".yml", ".yaml") }
)
if ($workflowFiles.Count -eq 0) {
  throw "No GitHub Actions workflow files were found."
}

$yamlFiles = @($workflowFiles)
if (Test-Path -LiteralPath $actionRoot) {
  $yamlFiles += @(
    Get-ChildItem -LiteralPath $actionRoot -Recurse -File |
      Where-Object { $_.Extension -in @(".yml", ".yaml") }
  )
}

$seenActions = @{}
foreach ($actionName in $expectedActions.Keys) {
  $seenActions[$actionName] = 0
}

foreach ($file in $workflowFiles) {
  $text = [System.IO.File]::ReadAllText($file.FullName)
  $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart([char[]]"\/")

  if ($text -notmatch '(?m)^permissions:\s*(?:#.*)?$') {
    throw "$relativePath must define explicit top-level permissions."
  }
  if ($text -match '(?mi)^permissions:\s*write-all\s*(?:#.*)?$') {
    throw "$relativePath grants write-all permissions."
  }
  if ($text -match '(?mi)^\s+(actions|checks|contents|deployments|id-token|issues|packages|pull-requests|security-events|statuses):\s*write\s*(?:#.*)?$') {
    throw "$relativePath grants '$($Matches[1]): write'. Add a narrowly reviewed exception before enabling write access."
  }
}

foreach ($file in $yamlFiles) {
  $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart([char[]]"\/")
  $lineNumber = 0
  foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
    $lineNumber++
    if ($line -notmatch '^\s*uses:\s*(?<target>[^#\s]+)(?:\s*#\s*(?<comment>.+?))?\s*$') {
      continue
    }

    $target = $Matches.target
    $versionComment = if ($Matches.ContainsKey("comment") -and $Matches["comment"]) {
      $Matches["comment"].Trim()
    } else {
      ""
    }
    if ($target.StartsWith("./", [System.StringComparison]::Ordinal)) {
      continue
    }
    if ($target.StartsWith("docker://", [System.StringComparison]::OrdinalIgnoreCase)) {
      if ($target -notmatch '@sha256:[0-9a-fA-F]{64}$') {
        throw "${relativePath}:$lineNumber uses an unpinned container action: $target"
      }
      continue
    }
    if ($target -notmatch '^(?<action>[^@]+)@(?<reference>[^@]+)$') {
      throw "${relativePath}:$lineNumber has an invalid external action reference: $target"
    }

    $actionName = $Matches.action
    $reference = $Matches.reference
    if (-not $expectedActions.Contains($actionName)) {
      throw "${relativePath}:$lineNumber uses unreviewed external action '$actionName'. Add its verified SHA to Test-GitHubActionsSecurity.ps1."
    }

    $expected = $expectedActions[$actionName]
    if ($reference -cne $expected.Sha) {
      throw "${relativePath}:$lineNumber must pin $actionName to $($expected.Sha), not '$reference'."
    }
    if ($versionComment -cne $expected.Version) {
      throw "${relativePath}:$lineNumber must retain the readable '# $($expected.Version)' version comment."
    }
    $seenActions[$actionName] = [int]$seenActions[$actionName] + 1
  }
}

foreach ($actionName in $expectedActions.Keys) {
  if ([int]$seenActions[$actionName] -eq 0) {
    throw "Pinned action policy entry '$actionName' is unused. Remove or update the stale policy entry."
  }
}

$dependabotPath = Join-Path $githubRoot "dependabot.yml"
if (-not (Test-Path -LiteralPath $dependabotPath -PathType Leaf)) {
  throw ".github/dependabot.yml is required to keep pinned action SHAs current."
}
$dependabot = [System.IO.File]::ReadAllText($dependabotPath)
if ($dependabot -notmatch '(?m)^version:\s*2\s*$' -or
    $dependabot -notmatch '(?m)^\s*-\s*package-ecosystem:\s*["'']?github-actions["'']?\s*$' -or
    $dependabot -notmatch '(?m)^\s+directory:\s*["'']?/["'']?\s*$' -or
    $dependabot -notmatch '(?m)^\s+interval:\s*["'']?weekly["'']?\s*$') {
  throw ".github/dependabot.yml must configure weekly GitHub Actions updates from repository root."
}

$totalReferences = ($seenActions.Values | Measure-Object -Sum).Sum
Write-Host "GitHub Actions security checks OK ($totalReferences pinned external reference(s))."
