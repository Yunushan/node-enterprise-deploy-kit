<#
.SYNOPSIS
  Ensure the WinSW service wrapper executable is available for Windows service deployments.
.DESCRIPTION
  Downloads a pinned stable WinSW executable only when it is missing and auto-download
  is enabled. Existing files are left untouched unless -Force is used.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $ConfigPath = "",
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe",
    [string] $DownloadUrl = "",
    [string] $ExpectedSha256 = "",
    [switch] $SkipDownload,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$DefaultWinSWDownloadUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}

function Get-ConfigString($Config, [string]$Name, [string]$Default = "") {
    if ($Config -and $Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return [string]$Config.$Name
    }
    return $Default
}

function Get-ConfigBool($Config, [string]$Name, [bool]$Default) {
    if (-not $Config -or -not $Config.PSObject.Properties[$Name] -or $null -eq $Config.$Name) {
        return $Default
    }
    if ($Config.$Name -is [bool]) {
        return [bool]$Config.$Name
    }

    $text = ([string]$Config.$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }
    switch ($text) {
        "true" { return $true }
        "1" { return $true }
        "yes" { return $true }
        "false" { return $false }
        "0" { return $false }
        "no" { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Assert-ValidHttpsUrl([string]$Url) {
    try {
        $uri = [Uri]$Url
    } catch {
        throw "WinSWDownloadUrl is not a valid URI: $Url"
    }

    if ($uri.Scheme -ne "https") {
        throw "WinSWDownloadUrl must use https: $Url"
    }
}

function Assert-ValidSha256([string]$Hash) {
    if ([string]::IsNullOrWhiteSpace($Hash)) { return }
    if ($Hash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "WinSWDownloadSha256 must be a 64-character SHA256 hex digest."
    }
}

function Test-FileHashMatches([string]$Path, [string]$ExpectedHash) {
    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return $true }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -ieq $ExpectedHash)
}

$config = $null
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
        $ConfigPath = Join-Path $repoRoot $ConfigPath
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

$autoDownload = Get-ConfigBool $config "AutoDownloadWinSW" $true
if ($SkipDownload) {
    $autoDownload = $false
}
$requireSha256 = Get-ConfigBool $config "RequireWinSWDownloadSha256" $true

if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    $DownloadUrl = Get-ConfigString $config "WinSWDownloadUrl" $DefaultWinSWDownloadUrl
}
if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    $ExpectedSha256 = Get-ConfigString $config "WinSWDownloadSha256" ""
}

Assert-ValidSha256 $ExpectedSha256
if ($requireSha256 -and [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    throw "WinSWDownloadSha256 is required when RequireWinSWDownloadSha256 is true. Provide the pinned SHA256 digest or set RequireWinSWDownloadSha256=false only when WinSW is supplied and verified by an approved internal channel."
}

$winswCandidate = Resolve-RepoPath $WinSWPath
$winswDirectory = Split-Path -Parent $winswCandidate

if ((Test-Path -LiteralPath $winswCandidate -PathType Leaf) -and -not $Force) {
    if (-not (Test-FileHashMatches -Path $winswCandidate -ExpectedHash $ExpectedSha256)) {
        throw "Existing WinSW executable failed SHA256 verification: $winswCandidate"
    }
    Write-Host "WinSW executable already exists: $winswCandidate"
    return
}

if (-not $autoDownload) {
    throw "WinSW executable not found: $winswCandidate. AutoDownloadWinSW is disabled; place the executable there or enable auto-download."
}

Assert-ValidHttpsUrl $DownloadUrl
New-Item -ItemType Directory -Force -Path $winswDirectory | Out-Null
$tempPath = Join-Path $winswDirectory ("{0}.download-{1}.tmp" -f ([System.IO.Path]::GetFileName($winswCandidate)), [guid]::NewGuid().ToString("N"))

try {
    if ($PSCmdlet.ShouldProcess($winswCandidate, "Download WinSW from $DownloadUrl")) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempPath -UseBasicParsing

        if (-not (Test-FileHashMatches -Path $tempPath -ExpectedHash $ExpectedSha256)) {
            throw "Downloaded WinSW executable failed SHA256 verification."
        }

        Move-Item -LiteralPath $tempPath -Destination $winswCandidate -Force
        try {
            Unblock-File -LiteralPath $winswCandidate -ErrorAction Stop
        } catch {
            Write-Warning "Downloaded WinSW, but could not clear the Windows Mark-of-the-Web flag. $($_.Exception.Message)"
        }
        Write-Host "Downloaded WinSW executable: $winswCandidate" -ForegroundColor Green
    }
} finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempPath -Force
    }
}
