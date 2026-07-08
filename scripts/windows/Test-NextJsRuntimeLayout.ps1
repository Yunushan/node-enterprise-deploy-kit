<#
.SYNOPSIS
  Validate a deployed Next.js runtime directory.
.DESCRIPTION
  Read-only structural check for a live Next.js app folder. It does not read
  environment values, HTTP responses, logs, or secrets.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $AppDirectory = "",
    [string] $Mode = "standalone",
    [string] $StartCommand = "server.js",
    [string] $NodeExe = "",
    [string] $NodeArguments = "",
    [string] $BindAddress = "127.0.0.1",
    [string] $MinimumNodeVersion = "20.9.0",
    [bool] $RequireStaticAssets = $true,
    [bool] $RequirePublicDirectory = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) { $errors.Add($Message) | Out-Null }
function Add-Warning([string]$Message) { $warnings.Add($Message) | Out-Null }
function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}
function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}
function Get-ConfigBool($Config, [string]$Name, [bool]$Default) {
    if (-not $Config.PSObject.Properties[$Name]) { return $Default }
    $value = $Config.$Name
    if ($value -is [bool]) { return [bool]$value }
    switch -Regex ([string]$value) {
        '^(true|1|yes)$' { return $true }
        '^(false|0|no)$' { return $false }
        default { return $Default }
    }
}
function Test-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = $Path.Replace("\", "/")
    foreach ($part in $normalized.Split("/")) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq ".") { continue }
        if ($part -eq "..") { return $false }
    }
    return $true
}
function Get-NormalizedPathForCompare([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try {
        return ([System.IO.Path]::GetFullPath($expanded)).TrimEnd([char[]]@('\', '/')).Replace("\", "/").ToLowerInvariant()
    } catch {
        return $expanded.TrimEnd([char[]]@('\', '/')).Replace("\", "/").ToLowerInvariant()
    }
}
function Split-ArgumentTokens([string]$Arguments) {
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return @() }
    return @($Arguments -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function Get-HostnameArgumentValue([string[]]$Tokens) {
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token -eq "-H" -or $token -eq "--hostname") {
            if (($i + 1) -lt $Tokens.Count) { return $Tokens[$i + 1] }
            return ""
        }
        if ($token -like "--hostname=*") {
            return $token.Substring("--hostname=".Length)
        }
        if ($token -like "-H=*") {
            return $token.Substring("-H=".Length)
        }
    }
    return ""
}
function Get-SemverParts([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value.Trim(), '^v?(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
    }
}
function Test-SemverAtLeast([string]$Actual, [string]$Minimum) {
    $actualParts = Get-SemverParts $Actual
    $minimumParts = Get-SemverParts $Minimum
    if ($null -eq $actualParts -or $null -eq $minimumParts) { return $null }
    if ($actualParts.Major -ne $minimumParts.Major) { return $actualParts.Major -gt $minimumParts.Major }
    if ($actualParts.Minor -ne $minimumParts.Minor) { return $actualParts.Minor -gt $minimumParts.Minor }
    return $actualParts.Patch -ge $minimumParts.Patch
}
function Get-NodeRuntimeVersion([string]$NodeExe) {
    $candidate = if ([string]::IsNullOrWhiteSpace($NodeExe)) { "node" } else { $NodeExe }
    try {
        $output = & $candidate --version 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        return ([string](@($output)[0])).Trim()
    } catch {
        return ""
    }
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
        $ConfigPath = Join-Path $repoRoot $ConfigPath
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config not found: $ConfigPath"
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $framework = Normalize-Name (Get-ConfigString $config "AppFramework" "node")
    if ($framework -notin @("next", "nextjs", "next-js")) {
        Write-Host "AppFramework is '$framework'; Next.js runtime layout check is not applicable."
        exit 0
    }

    $AppDirectory = Get-ConfigString $config "AppDirectory" $AppDirectory
    $Mode = Get-ConfigString $config "NextjsDeploymentMode" $Mode
    $StartCommand = Get-ConfigString $config "StartCommand" $StartCommand
    $NodeExe = Get-ConfigString $config "NodeExe" $NodeExe
    $NodeArguments = Get-ConfigString $config "NodeArguments" $NodeArguments
    $BindAddress = Get-ConfigString $config "BindAddress" $BindAddress
    $MinimumNodeVersion = Get-ConfigString $config "NextjsMinimumNodeVersion" $MinimumNodeVersion
    $RequireStaticAssets = Get-ConfigBool $config "NextjsRequireStaticAssets" $RequireStaticAssets
    $RequirePublicDirectory = Get-ConfigBool $config "NextjsRequirePublicDirectory" $RequirePublicDirectory
}

$modeNormalized = Normalize-Name $Mode
if ($modeNormalized -notin @("standalone", "next-start")) {
    Add-Error "NextjsDeploymentMode must be standalone or next-start."
}
if ([string]::IsNullOrWhiteSpace($AppDirectory)) {
    Add-Error "AppDirectory is required."
}

$nodeVersion = ""
$nodeVersionSatisfied = $false
if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -or -not [string]::IsNullOrWhiteSpace($NodeExe)) {
    if ($null -eq (Get-SemverParts $MinimumNodeVersion)) {
        Add-Error "NextjsMinimumNodeVersion must be a semantic version like 20.9.0."
    } else {
        $nodeVersion = Get-NodeRuntimeVersion $NodeExe
        if ([string]::IsNullOrWhiteSpace($nodeVersion)) {
            Add-Error "Next.js requires Node.js >= $MinimumNodeVersion, but NodeExe did not return a version with --version: $NodeExe"
        } else {
            $nodeVersionSatisfiedResult = Test-SemverAtLeast -Actual $nodeVersion -Minimum $MinimumNodeVersion
            if ($null -eq $nodeVersionSatisfiedResult) {
                Add-Error "Next.js requires Node.js >= $MinimumNodeVersion, but NodeExe returned an unrecognized version: $nodeVersion"
            } elseif (-not $nodeVersionSatisfiedResult) {
                Add-Error "Next.js requires Node.js >= $MinimumNodeVersion; configured NodeExe reports $nodeVersion."
            } else {
                $nodeVersionSatisfied = $true
            }
        }
    }
}

$runtimeRoot = $AppDirectory
$startPath = ""
if (-not [string]::IsNullOrWhiteSpace($AppDirectory) -and $modeNormalized -eq "standalone") {
    if ([string]::IsNullOrWhiteSpace($StartCommand) -or $StartCommand -match '\s') {
        Add-Error "StartCommand must be a single file path for standalone runtime layout validation."
    } elseif ([System.IO.Path]::IsPathRooted($StartCommand)) {
        $startPath = $StartCommand
    } elseif (Test-SafeRelativePath $StartCommand) {
        $startPath = Join-Path $AppDirectory $StartCommand
    } else {
        Add-Error "StartCommand must be a safe relative file path."
    }
    if ($startPath) {
        $runtimeRoot = Split-Path -Parent $startPath
    }
}

$serverPath = if ($startPath) { $startPath } else { Join-Path $runtimeRoot "server.js" }
$nextPath = Join-Path $runtimeRoot ".next"
$buildIdPath = Join-Path $nextPath "BUILD_ID"
$staticPath = Join-Path $nextPath "static"
$publicPath = Join-Path $runtimeRoot "public"
$nodeModulesPath = Join-Path $runtimeRoot "node_modules"
$packageJsonPath = Join-Path $AppDirectory "package.json"
$nextPackagePath = if ($modeNormalized -eq "standalone") { Join-Path $runtimeRoot "node_modules\next" } else { Join-Path $AppDirectory "node_modules\next" }
$nextPackageJsonPath = Join-Path $nextPackagePath "package.json"

[pscustomobject]@{
    Mode = $modeNormalized
    AppDirectory = $AppDirectory
    AppDirectoryExists = (-not [string]::IsNullOrWhiteSpace($AppDirectory) -and (Test-Path -LiteralPath $AppDirectory -PathType Container))
    RuntimeRoot = $runtimeRoot
    StartCommand = $StartCommand
    NodeExe = $NodeExe
    NodeVersion = $nodeVersion
    MinimumNodeVersion = $MinimumNodeVersion
    NodeVersionSatisfied = $nodeVersionSatisfied
    NodeArguments = $NodeArguments
    BindAddress = $BindAddress
    RequiresStaticAssets = $RequireStaticAssets
    RequiresPublicDirectory = $RequirePublicDirectory
    ServerJsExists = (Test-Path -LiteralPath $serverPath -PathType Leaf)
    DotNextExists = (Test-Path -LiteralPath $nextPath -PathType Container)
    BuildIdExists = (Test-Path -LiteralPath $buildIdPath -PathType Leaf)
    StaticAssetsExist = (Test-Path -LiteralPath $staticPath -PathType Container)
    PublicDirectoryExists = (Test-Path -LiteralPath $publicPath -PathType Container)
    NodeModulesExists = (Test-Path -LiteralPath $nodeModulesPath -PathType Container)
    PackageJsonExists = (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)
    NextPackageExists = (Test-Path -LiteralPath $nextPackagePath -PathType Container)
    NextPackageJsonExists = (Test-Path -LiteralPath $nextPackageJsonPath -PathType Leaf)
} | Format-List

if (-not [string]::IsNullOrWhiteSpace($AppDirectory) -and -not (Test-Path -LiteralPath $AppDirectory -PathType Container)) {
    Add-Error "AppDirectory was not found: $AppDirectory"
}

if ($modeNormalized -eq "standalone") {
    if ($startPath -and (Split-Path -Leaf $startPath) -ne "server.js") {
        Add-Warning "Next.js standalone deployments normally start the generated server.js file."
    }
    if ($startPath -and -not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        Add-Error "Next.js standalone server.js was not found at: $serverPath"
    }
    if (-not (Test-Path -LiteralPath $nextPath -PathType Container)) {
        Add-Error "Next.js standalone runtime root is missing .next: $nextPath"
    }
    if (-not (Test-Path -LiteralPath $buildIdPath -PathType Leaf)) {
        Add-Error "Next.js standalone runtime root is missing .next\BUILD_ID: $buildIdPath"
    }
    if ($RequireStaticAssets -and -not (Test-Path -LiteralPath $staticPath -PathType Container)) {
        Add-Error "Next.js standalone runtime root is missing .next/static: $staticPath"
    }
    if ($RequirePublicDirectory -and -not (Test-Path -LiteralPath $publicPath -PathType Container)) {
        Add-Error "Next.js standalone runtime root is missing public directory: $publicPath"
    }
    if (-not (Test-Path -LiteralPath $nextPackageJsonPath -PathType Leaf)) {
        Add-Error "Next.js standalone runtime root is missing node_modules/next/package.json. Keep Next.js package metadata with the deployed artifact so status evidence can prove the installed Next.js version."
    }
} elseif ($modeNormalized -eq "next-start") {
    if ([string]::IsNullOrWhiteSpace($StartCommand) -or $StartCommand -match '\s') {
        Add-Error "StartCommand must be a single file path for next-start runtime layout validation."
    } else {
        $nextStartCommandPath = if ([System.IO.Path]::IsPathRooted($StartCommand)) { $StartCommand } elseif (Test-SafeRelativePath $StartCommand) { Join-Path $AppDirectory $StartCommand } else { "" }
        if ([string]::IsNullOrWhiteSpace($nextStartCommandPath)) {
            Add-Error "StartCommand must be a safe relative file path for Next.js next-start validation."
        } else {
            $expectedNextStartCommandPath = Join-Path $AppDirectory "node_modules\next\dist\bin\next"
            if (-not (Test-Path -LiteralPath $nextStartCommandPath -PathType Leaf)) {
                Add-Error "Next.js next-start StartCommand file was not found: $nextStartCommandPath"
            }
            if ((Get-NormalizedPathForCompare $nextStartCommandPath) -ine (Get-NormalizedPathForCompare $expectedNextStartCommandPath)) {
                Add-Error "Next.js next-start StartCommand must point to node_modules/next/dist/bin/next under AppDirectory."
            }
        }
    }
    $argumentTokens = @(Split-ArgumentTokens $NodeArguments)
    if ($argumentTokens.Count -eq 0 -or $argumentTokens[0] -ne "start") {
        Add-Error "Next.js next-start mode requires NodeArguments to start with 'start'. Example: start -H $BindAddress"
    }
    $hostnameArgument = Get-HostnameArgumentValue $argumentTokens
    if ([string]::IsNullOrWhiteSpace($hostnameArgument)) {
        Add-Error "Next.js next-start mode requires NodeArguments to include '-H $BindAddress' or '--hostname $BindAddress'."
    } elseif ($hostnameArgument -ne $BindAddress) {
        Add-Error "Next.js next-start hostname argument '$hostnameArgument' must match BindAddress '$BindAddress'."
    }
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        Add-Error "Next.js next-start mode is missing package.json under AppDirectory."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $AppDirectory ".next") -PathType Container)) {
        Add-Error "Next.js next-start mode is missing .next under AppDirectory."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $AppDirectory ".next\BUILD_ID") -PathType Leaf)) {
        Add-Error "Next.js next-start mode is missing .next\BUILD_ID under AppDirectory."
    }
    if (-not (Test-Path -LiteralPath $nextPackagePath -PathType Container)) {
        Add-Error "Next.js next-start mode is missing node_modules/next under AppDirectory."
    }
    if (-not (Test-Path -LiteralPath $nextPackageJsonPath -PathType Leaf)) {
        Add-Error "Next.js next-start mode is missing node_modules/next/package.json under AppDirectory."
    }
}

if ($warnings.Count -gt 0) {
    Write-Host "Warnings" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Warning $_ }
}
if ($errors.Count -gt 0) {
    Write-Host "Errors" -ForegroundColor Red
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Next.js runtime layout check failed with $($errors.Count) error(s)."
}

Write-Host "Next.js runtime layout OK." -ForegroundColor Green
