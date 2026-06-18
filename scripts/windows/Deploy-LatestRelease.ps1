<#
.SYNOPSIS
  Deploy the newest timestamped Windows release folder without moving the current live folder.
.DESCRIPTION
  This helper is intended for live-server RDP/VPN deployments where each release
  is extracted to a new folder, for example:

    C:\inetpub\wwwroot\example-node-app-IIS-deploy-20260617-1251

  The script reads a stable base config, creates a generated runtime config that
  points AppDirectory and IisSitePath at the newest matching release folder, then
  calls install.ps1 with package import, install, and build disabled by default.

  The current live folder is not moved or deleted. IIS is switched to the new
  folder by the normal IIS deployment step after the service update path is
  prepared.
.EXAMPLE
  .\scripts\windows\Deploy-LatestRelease.ps1 `
    -ConfigPath .\config\windows\app.config.json `
    -ReleaseRoot C:\inetpub\wwwroot `
    -ReleasePattern "example-node-app-IIS-deploy-*" `
    -HealthPath "/" `
    -TakeOverPublicPortBinding `
    -SkipWinSWDownload
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $ReleaseRoot = "C:\inetpub\wwwroot",
    [string] $ReleasePattern = "",
    [string] $ReleasePath = "",
    [string] $GeneratedConfigPath = "",
    [string] $HealthPath = "",
    [switch] $TakeOverPublicPortBinding,
    [switch] $SkipWinSWDownload,
    [switch] $SkipStatus,
    [switch] $KeepGeneratedConfig,
    [int] $StatusMinimumUptimeHours = 0
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}

function Get-ConfigValue($Config, [string]$Name, $Default) {
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Config.$Name
    }
    return $Default
}

function Get-ReleaseSortTime($Directory) {
    $name = [System.IO.Path]::GetFileName($Directory.FullName)
    if ($name -match '(\d{8})-(\d{4}|\d{6})$') {
        $stamp = $Matches[1] + $Matches[2]
        $format = if ($Matches[2].Length -eq 4) { "yyyyMMddHHmm" } else { "yyyyMMddHHmmss" }
        try {
            return [DateTime]::ParseExact($stamp, $format, [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $Directory.LastWriteTime
        }
    }
    return $Directory.LastWriteTime
}

function Resolve-LatestReleasePath([string]$Root, [string]$Pattern, [string]$ExplicitPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "ReleasePath was not found or is not a directory: $resolved"
        }
        return $resolved
    }

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        throw "ReleasePattern is required when ReleasePath is not provided."
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "ReleaseRoot was not found: $Root"
    }

    $candidates = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop |
        Where-Object { $_.Name -like $Pattern } |
        Sort-Object @{ Expression = { Get-ReleaseSortTime $_ } }, Name -Descending)

    if ($candidates.Count -eq 0) {
        throw "No release folders matching '$Pattern' were found under $Root"
    }
    return $candidates[0].FullName
}

function Assert-ReleaseLooksDeployable($Config, [string]$Path) {
    $startCommand = [string](Get-ConfigValue $Config "StartCommand" "server.js")
    if (-not [System.IO.Path]::IsPathRooted($startCommand)) {
        $startCommand = Join-Path $Path $startCommand
    }
    if (-not (Test-Path -LiteralPath $startCommand -PathType Leaf)) {
        throw "Selected release does not contain StartCommand: $startCommand"
    }
}

function Set-ConfigValue($Config, [string]$Name, $Value) {
    if ($Config.PSObject.Properties[$Name]) {
        $Config.$Name = $Value
    } else {
        $Config | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-NormalizedHealthPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $value = $Path.Trim()
    if (-not $value.StartsWith("/")) {
        $value = "/" + $value
    }
    if ($value -match '(^|/)\.\.($|/)') {
        throw "HealthPath must not contain '..' segments."
    }
    return $value
}

function Write-GeneratedConfig($Config, [string]$Path) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Config | ConvertTo-Json -Depth 40 | Set-Content -Path $Path -Encoding UTF8
}

function Get-ServiceXmlPath($Config) {
    if (-not $Config.PSObject.Properties["ServiceDirectory"] -or [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return ""
    }
    return (Join-Path ([string]$Config.ServiceDirectory) "$($Config.AppName).xml")
}

function Get-CurrentIisSiteState($Config) {
    $siteName = [string](Get-ConfigValue $Config "IisSiteName" $Config.AppName)
    if ([string]::IsNullOrWhiteSpace($siteName)) { return $null }
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $site = Get-Item "IIS:\Sites\$siteName" -ErrorAction SilentlyContinue
        if (-not $site) { return $null }
        return [pscustomobject]@{
            Name = $siteName
            PhysicalPath = [string]$site.PhysicalPath
            ApplicationPool = [string]$site.ApplicationPool
        }
    } catch {
        Write-Warning "Could not snapshot IIS site state for rollback. $($_.Exception.Message)"
        return $null
    }
}

function Restore-IisSiteState($State) {
    if (-not $State) { return }
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path "IIS:\Sites\$($State.Name)") {
            if (-not [string]::IsNullOrWhiteSpace($State.PhysicalPath)) {
                Set-ItemProperty "IIS:\Sites\$($State.Name)" -Name physicalPath -Value $State.PhysicalPath
            }
            if (-not [string]::IsNullOrWhiteSpace($State.ApplicationPool)) {
                Set-ItemProperty "IIS:\Sites\$($State.Name)" -Name applicationPool -Value $State.ApplicationPool
            }
            Write-Warning "Restored IIS site '$($State.Name)' to previous physical path."
        }
    } catch {
        Write-Warning "Could not restore IIS site state. $($_.Exception.Message)"
    }
}

function Get-ExistingPublicPortBindings($Config) {
    $siteName = [string](Get-ConfigValue $Config "IisSiteName" $Config.AppName)
    $publicPort = [int](Get-ConfigValue $Config "PublicPort" 80)
    try {
        Import-Module WebAdministration -ErrorAction Stop
        return @(Get-ChildItem IIS:\Sites | ForEach-Object {
            $site = $_
            $site.Bindings.Collection |
                Where-Object { $_.protocol -eq "http" -and $_.bindingInformation -like "*:${publicPort}:*" } |
                ForEach-Object {
                    [pscustomobject]@{
                        SiteName = $site.Name
                        BindingInformation = $_.bindingInformation
                        Protocol = $_.protocol
                        IsConfiguredSite = ($site.Name -eq $siteName)
                    }
                }
        })
    } catch {
        Write-Warning "Could not inspect IIS bindings. $($_.Exception.Message)"
        return @()
    }
}

function Remove-ConflictingPublicPortBindings($Config) {
    $bindings = @(Get-ExistingPublicPortBindings $Config | Where-Object { -not $_.IsConfiguredSite })
    foreach ($binding in $bindings) {
        $parts = $binding.BindingInformation.Split(":")
        $port = [int]$parts[1]
        $hostHeader = if ($parts.Count -ge 3) { $parts[2] } else { "" }
        Write-Warning "Removing conflicting IIS binding $($binding.Protocol) $($binding.BindingInformation) from site $($binding.SiteName)."
        if ($PSCmdlet.ShouldProcess($binding.SiteName, "Remove conflicting IIS binding $($binding.Protocol) $($binding.BindingInformation)")) {
            Remove-WebBinding -Name $binding.SiteName -Protocol $binding.Protocol -Port $port -HostHeader $hostHeader -ErrorAction Stop
        }
    }
}

function Assert-NoConflictingPublicPortBinding($Config) {
    $conflicts = @(Get-ExistingPublicPortBindings $Config | Where-Object { -not $_.IsConfiguredSite })
    if ($conflicts.Count -eq 0) { return }
    $summary = ($conflicts | ForEach-Object { "$($_.SiteName) [$($_.BindingInformation)]" }) -join "; "
    throw "PublicPort is already bound by another IIS site: $summary. Re-run with -TakeOverPublicPortBinding only when this is intentional."
}

Assert-Admin
$ConfigPath = Resolve-RepoPath $ConfigPath
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$baseConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$selectedReleasePath = Resolve-LatestReleasePath -Root $ReleaseRoot -Pattern $ReleasePattern -ExplicitPath $ReleasePath
Assert-ReleaseLooksDeployable -Config $baseConfig -Path $selectedReleasePath

$serviceXmlPath = Get-ServiceXmlPath $baseConfig
$serviceXmlSnapshot = if ($serviceXmlPath -and (Test-Path -LiteralPath $serviceXmlPath -PathType Leaf)) {
    Get-Content -LiteralPath $serviceXmlPath -Raw
} else {
    $null
}
$iisSnapshot = Get-CurrentIisSiteState $baseConfig

$runtimeConfig = $baseConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json
Set-ConfigValue -Config $runtimeConfig -Name "AppDirectory" -Value $selectedReleasePath
Set-ConfigValue -Config $runtimeConfig -Name "IisSitePath" -Value $selectedReleasePath
Set-ConfigValue -Config $runtimeConfig -Name "PackagePath" -Value ""

$normalizedHealthPath = Get-NormalizedHealthPath $HealthPath
if (-not [string]::IsNullOrWhiteSpace($normalizedHealthPath)) {
    Set-ConfigValue -Config $runtimeConfig -Name "HealthUrl" -Value ("http://127.0.0.1:{0}{1}" -f $runtimeConfig.Port, $normalizedHealthPath)
    $iisHealthProxyPath = $normalizedHealthPath.Trim("/")
    if ([string]::IsNullOrWhiteSpace($iisHealthProxyPath)) {
        $iisHealthProxyPath = "health"
    }
    Set-ConfigValue -Config $runtimeConfig -Name "IisHealthProxyPath" -Value $iisHealthProxyPath
}

if ([string]::IsNullOrWhiteSpace($GeneratedConfigPath)) {
    $safeName = ([string]$runtimeConfig.AppName) -replace '[^A-Za-z0-9_.-]', '_'
    $GeneratedConfigPath = Join-Path $repoRoot ".tmp\windows-live-deploy\$safeName.generated.json"
} else {
    $GeneratedConfigPath = Resolve-RepoPath $GeneratedConfigPath
}
Write-GeneratedConfig -Config $runtimeConfig -Path $GeneratedConfigPath

Write-Host "Selected release folder: $selectedReleasePath" -ForegroundColor Cyan
Write-Host "Generated config: $GeneratedConfigPath"
Write-Host "Service: $($runtimeConfig.AppName)"
Write-Host "IIS site: $($runtimeConfig.IisSiteName)"
Write-Host "IIS path: $($runtimeConfig.IisSitePath)"
Write-Host "Public port: $($runtimeConfig.PublicPort)"
Write-Host "Node port: $($runtimeConfig.Port)"

if ($TakeOverPublicPortBinding) {
    Remove-ConflictingPublicPortBindings $runtimeConfig
} else {
    Assert-NoConflictingPublicPortBinding $runtimeConfig
}

$installArgs = @{
    ConfigPath = $GeneratedConfigPath
    SkipPackageImport = $true
    SkipInstall = $true
    SkipBuild = $true
    AllowPortInUse = $true
}
if ($SkipWinSWDownload) {
    $installArgs.SkipWinSWDownload = $true
}

try {
    if ($PSCmdlet.ShouldProcess($selectedReleasePath, "Deploy latest Windows release folder")) {
        & (Join-Path $repoRoot "install.ps1") @installArgs
        if (-not $SkipStatus) {
            $statusArgs = @{
                ConfigPath = $GeneratedConfigPath
                FailOnCritical = $true
            }
            if ($StatusMinimumUptimeHours -gt 0) {
                $statusArgs.MinimumUptimeHours = $StatusMinimumUptimeHours
            }
            & (Join-Path $repoRoot "status.ps1") @statusArgs
        }
    }
} catch {
    Write-Error "Deployment failed. $($_.Exception.Message)" -ErrorAction Continue
    Restore-IisSiteState $iisSnapshot
    if ($serviceXmlSnapshot -and $serviceXmlPath) {
        try {
            [System.IO.File]::WriteAllText($serviceXmlPath, $serviceXmlSnapshot, [System.Text.UTF8Encoding]::new($false))
            Restart-Service -Name $baseConfig.AppName -Force -ErrorAction SilentlyContinue
            Write-Warning "Restored previous WinSW XML and attempted to restart service '$($baseConfig.AppName)'."
        } catch {
            Write-Warning "Could not restore previous WinSW XML/service state. $($_.Exception.Message)"
        }
    }
    throw
} finally {
    if (-not $KeepGeneratedConfig -and (Test-Path -LiteralPath $GeneratedConfigPath -PathType Leaf)) {
        Remove-Item -LiteralPath $GeneratedConfigPath -Force
    }
}
