# Reviewed runtime policy shared by host, saved-bundle, and coverage validators.
# Framework compatibility and an actively maintained Node release are distinct.
$script:NodeRuntimePolicy = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../config/node-runtime-policy.json") -Raw | ConvertFrom-Json

function Get-NodeRuntimeMajor {
  param([string]$Version)
  if ($Version -notmatch '^v?(\d+)\.\d+\.\d+$') { return $null }
  return [int]$Matches[1]
}

function Get-NodeRuntimeReleaseLine {
  param([string]$Version)
  $major = Get-NodeRuntimeMajor -Version $Version
  if ($null -eq $major) { return $null }
  return $script:NodeRuntimePolicy.releaseLines | Where-Object { [int]$_.major -eq $major } | Select-Object -First 1
}

function Get-NodeRuntimeMacosMinimumVersion {
  param([string]$Version, [string]$Architecture)
  $line = Get-NodeRuntimeReleaseLine -Version $Version
  if ($null -eq $line) { return $null }
  if ($Architecture -in @('arm64', 'aarch64')) { return [string]$line.macosArm64Minimum }
  if ($Architecture -in @('x64', 'x86-64', 'amd64', 'x86_64')) { return [string]$line.macosMinimum }
  return $null
}

function Test-SupportedNodeRuntimeVersion {
  param([string]$Version, [datetime]$AsOfUtc = (Get-Date).ToUniversalTime())
  $line = Get-NodeRuntimeReleaseLine -Version $Version
  if ($null -eq $line) { return $false }
  $day = $AsOfUtc.ToUniversalTime().Date
  $start = [datetime]::ParseExact([string]$line.start, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $end = [datetime]::ParseExact([string]$line.end, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  return ($day -ge $start.Date -and $day -lt $end.Date)
}
