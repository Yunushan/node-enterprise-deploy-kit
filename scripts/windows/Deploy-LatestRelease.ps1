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
. (Join-Path $PSScriptRoot 'WindowsDeploymentIdentity.ps1')

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

function Get-IisPublicProtocol($Config) {
    if (Get-ConfigBool $Config "TlsEnabled" $false) { return "https" }
    return "http"
}

function Get-IisPublicPort($Config) {
    $tlsEnabled = Get-ConfigBool $Config "TlsEnabled" $false
    $defaultPort = if ($tlsEnabled) { 443 } else { 80 }
    return [int](Get-ConfigValue $Config "PublicPort" $defaultPort)
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
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    Assert-WindowsServiceSecurityNoReparse -Path $Path
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    try {
        # Protect the empty file before writing service-account and environment secrets.
        Set-WindowsProtectedFileSecurity -Path $Path
        [IO.File]::WriteAllText($Path, ($Config | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    } catch {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        throw
    }
}

function Get-DefaultGeneratedConfigPath($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    $safeName = ([string]$Config.AppName) -creplace '[^A-Za-z0-9_.-]', '_'
    $serviceDirectory = [string](Get-ConfigValue $Config "ServiceDirectory" "")
    $nonce = [Guid]::NewGuid().ToString("N")
    if (-not [string]::IsNullOrWhiteSpace($serviceDirectory)) {
        return (Join-Path (Get-DeploymentLockDirectory $Config) "$safeName.latest-release.$nonce.json")
    }
    return (Join-Path $repoRoot ".tmp\windows-live-deploy\$safeName.latest-release.$nonce.json")
}

function Get-ServiceXmlPath($Config) {
    Assert-WindowsDeploymentConfigIdentity -Config $Config
    if (-not $Config.PSObject.Properties["ServiceDirectory"] -or [string]::IsNullOrWhiteSpace([string]$Config.ServiceDirectory)) {
        return ""
    }
    return (Join-Path ([string]$Config.ServiceDirectory) "$($Config.AppName).xml")
}

function Get-CurrentIisSiteState($Config) {
    $siteName = [string](Get-ConfigValue $Config "IisSiteName" $Config.AppName)
    if ([string]::IsNullOrWhiteSpace($siteName)) { return $null }
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Item "IIS:\Sites\$siteName" -ErrorAction SilentlyContinue
    $protocol = Get-IisPublicProtocol $Config
    $port = Get-IisPublicPort $Config
    $hostHeader = [string](Get-ConfigValue $Config "PublicHostName" "")
    $bindings = @(Get-ExistingPublicPortBindings $Config | Where-Object { $_.IsConfiguredSite })
    return [pscustomobject]@{
        Name = $siteName
        SiteExisted = ($null -ne $site)
        PhysicalPath = if ($site) { [string]$site.PhysicalPath } else { "" }
        ApplicationPool = if ($site) { [string]$site.ApplicationPool } else { "" }
        State = if ($site) { [string]$site.State } else { "" }
        BindingProtocol = $protocol
        BindingInformation = "*:${port}:$hostHeader"
        Bindings = $bindings
    }
}

function Restore-IisSiteState($State) {
    if (-not $State) { return }
    Import-Module WebAdministration -ErrorAction Stop
    if (Test-Path "IIS:\Sites\$($State.Name)") {
        if (-not $State.SiteExisted) {
            Remove-Website -Name $State.Name -ErrorAction Stop
        } else {
            if (@($State.Bindings).Count -eq 0) {
                $createdBinding = @(Get-WebBinding -Name $State.Name -Protocol $State.BindingProtocol -ErrorAction Stop |
                    Where-Object { [string]$_.bindingInformation -ieq $State.BindingInformation })
                if ($createdBinding.Count -gt 0) {
                    $parts = ConvertFrom-IisPublicBindingInformation $State.BindingInformation
                    Remove-WebBinding -Name $State.Name -Protocol $State.BindingProtocol -IPAddress $parts.IPAddress -Port $parts.Port -HostHeader $parts.HostHeader -ErrorAction Stop
                }
            } else {
                $bindingSnapshots = [System.Collections.Generic.List[object]]::new()
                foreach ($binding in @($State.Bindings)) { $bindingSnapshots.Add($binding) }
                Restore-RemovedPublicPortBindings -RemovedBindings $bindingSnapshots
            }
            if (-not [string]::IsNullOrWhiteSpace($State.PhysicalPath)) {
                Set-ItemProperty "IIS:\Sites\$($State.Name)" -Name physicalPath -Value $State.PhysicalPath
            }
            if (-not [string]::IsNullOrWhiteSpace($State.ApplicationPool)) {
                Set-ItemProperty "IIS:\Sites\$($State.Name)" -Name applicationPool -Value $State.ApplicationPool
            }
            if ([string]$State.State -eq "Started") {
                Start-Website -Name $State.Name -ErrorAction Stop | Out-Null
            } elseif ([string]$State.State -eq "Stopped") {
                Stop-Website -Name $State.Name -ErrorAction Stop | Out-Null
            }
            Write-Warning "Restored IIS site '$($State.Name)' to previous physical path."
        }
    }
}

function Get-ExistingPublicPortBindings($Config) {
    $siteName = [string](Get-ConfigValue $Config "IisSiteName" $Config.AppName)
    $protocol = Get-IisPublicProtocol $Config
    $publicPort = Get-IisPublicPort $Config
    $hostHeader = [string](Get-ConfigValue $Config "PublicHostName" "")
    # The normal IIS installer creates wildcard-IP bindings. Other hosts or
    # IP-specific bindings on the same port belong to independent IIS sites.
    $expectedBinding = "*:${publicPort}:$hostHeader"
    Import-Module WebAdministration -ErrorAction Stop
    return @(Get-ChildItem IIS:\Sites -ErrorAction Stop | ForEach-Object {
        $site = $_
        foreach ($binding in @($site.Bindings.Collection)) {
            if ([string]$binding.protocol -ne $protocol -or [string]$binding.bindingInformation -ine $expectedBinding) { continue }
            $parts = ConvertFrom-IisPublicBindingInformation ([string]$binding.bindingInformation)
            [pscustomobject]@{
                SiteName = [string]$site.Name
                BindingInformation = [string]$binding.bindingInformation
                Protocol = [string]$binding.protocol
                IPAddress = $parts.IPAddress
                Port = $parts.Port
                HostHeader = $parts.HostHeader
                SslFlags = if ($binding.PSObject.Properties["sslFlags"]) { [int]$binding.sslFlags } else { 0 }
                CertificateHash = if ($binding.PSObject.Properties["certificateHash"]) { ConvertTo-IisCertificateHash $binding.certificateHash } else { "" }
                CertificateStoreName = if ($binding.PSObject.Properties["certificateStoreName"]) { [string]$binding.certificateStoreName } else { "" }
                IsConfiguredSite = ([string]$site.Name -eq $siteName)
            }
        }
    })
}

function ConvertFrom-IisPublicBindingInformation([string]$BindingInformation) {
    if ($BindingInformation -notmatch '^(?<ip>.*):(?<port>[0-9]+):(?<host>[^:]*)$') {
        throw "IIS binding information is invalid: $BindingInformation"
    }
    return [pscustomobject]@{ IPAddress = $Matches.ip; Port = [int]$Matches.port; HostHeader = $Matches.host }
}

function ConvertTo-IisCertificateHash($Hash) {
    if ($Hash -is [byte[]]) { return [BitConverter]::ToString($Hash).Replace("-", "") }
    return ([string]$Hash).Replace(" ", "").Replace("-", "").ToUpperInvariant()
}

function Remove-ConflictingPublicPortBindings {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param($Config, [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$RemovedBindings)

    $bindings = @(Get-ExistingPublicPortBindings $Config | Where-Object { -not $_.IsConfiguredSite })
    foreach ($binding in $bindings) {
        Write-Warning "Removing conflicting IIS binding $($binding.Protocol) $($binding.BindingInformation) from site $($binding.SiteName)."
        if ($PSCmdlet.ShouldProcess($binding.SiteName, "Remove conflicting IIS binding $($binding.Protocol) $($binding.BindingInformation)")) {
            # Record first: a cmdlet failure may follow a partially committed IIS write.
            $RemovedBindings.Add($binding)
            Remove-WebBinding -Name $binding.SiteName -Protocol $binding.Protocol -IPAddress $binding.IPAddress -Port $binding.Port -HostHeader $binding.HostHeader -ErrorAction Stop
        }
    }
}

function Restore-RemovedPublicPortBindings {
    param([System.Collections.Generic.List[object]]$RemovedBindings)

    if ($null -eq $RemovedBindings -or $RemovedBindings.Count -eq 0) { return }
    Import-Module WebAdministration -ErrorAction Stop
    foreach ($snapshot in $RemovedBindings) {
        $current = @(Get-WebBinding -Name $snapshot.SiteName -Protocol $snapshot.Protocol -ErrorAction Stop |
            Where-Object { [string]$_.bindingInformation -ieq $snapshot.BindingInformation })
        if ($current.Count -eq 0) {
            $bindingArgs = @{
                Name = $snapshot.SiteName; Protocol = $snapshot.Protocol
                IPAddress = $snapshot.IPAddress; Port = $snapshot.Port; HostHeader = $snapshot.HostHeader
                ErrorAction = "Stop"
            }
            if ($snapshot.Protocol -eq "https") { $bindingArgs.SslFlags = $snapshot.SslFlags }
            New-WebBinding @bindingArgs | Out-Null
            $current = @(Get-WebBinding -Name $snapshot.SiteName -Protocol $snapshot.Protocol -ErrorAction Stop |
                Where-Object { [string]$_.bindingInformation -ieq $snapshot.BindingInformation })
        }
        if ($current.Count -ne 1) { throw "Could not restore removed IIS binding: $($snapshot.SiteName) [$($snapshot.BindingInformation)]" }
        if ($snapshot.Protocol -eq "https") {
            if ([int]$current[0].sslFlags -ne [int]$snapshot.SslFlags) {
                Set-WebBinding -Name $snapshot.SiteName -BindingInformation $snapshot.BindingInformation -PropertyName sslFlags -Value $snapshot.SslFlags -ErrorAction Stop
            }
            if ($snapshot.CertificateHash) {
                $store = if ($snapshot.CertificateStoreName) { $snapshot.CertificateStoreName } else { "My" }
                $current[0].AddSslCertificate($snapshot.CertificateHash, $store)
            }
        }
        Write-Warning "Restored removed IIS binding: $($snapshot.SiteName) [$($snapshot.BindingInformation)]"
    }
}

function Assert-NoConflictingPublicPortBinding($Config) {
    $conflicts = @(Get-ExistingPublicPortBindings $Config | Where-Object { -not $_.IsConfiguredSite })
    if ($conflicts.Count -eq 0) { return }
    $summary = ($conflicts | ForEach-Object { "$($_.SiteName) [$($_.BindingInformation)]" }) -join "; "
    throw "PublicPort is already bound by another IIS site: $summary. Re-run with -TakeOverPublicPortBinding only when this is intentional."
}

function Get-LatestReleaseNativePowerShellArguments {
    param([string]$ScriptPath, [System.Collections.IDictionary]$BoundParameters, [switch]$WhatIf)

    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath)
    foreach ($name in $BoundParameters.Keys) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            $arguments += "-${name}:$([bool]$value)"
        } else {
            $arguments += @("-$name", [string]$value)
        }
    }
    if ($WhatIf -and -not $BoundParameters.ContainsKey("WhatIf")) { $arguments += "-WhatIf" }
    return $arguments
}

if ($PSVersionTable.PSEdition -eq "Core") {
    $nativeWindowsPowerShell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $nativeWindowsPowerShell -PathType Leaf)) {
        throw "Latest-release IIS deployment requires Windows PowerShell, but powershell.exe was not found."
    }
    $nativeArguments = @(Get-LatestReleaseNativePowerShellArguments -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -WhatIf:$WhatIfPreference)
    & $nativeWindowsPowerShell @nativeArguments
    if ($LASTEXITCODE -ne 0) { throw "Native Windows PowerShell failed while deploying the latest release." }
    return
}

Assert-Admin
$ConfigPath = Resolve-RepoPath $ConfigPath
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config not found: $ConfigPath"
}

$baseConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-WindowsDeploymentConfigIdentity -Config $baseConfig
$selectedReleasePath = Resolve-LatestReleasePath -Root $ReleaseRoot -Pattern $ReleasePattern -ExplicitPath $ReleasePath
Assert-ReleaseLooksDeployable -Config $baseConfig -Path $selectedReleasePath

. (Join-Path $repoRoot "scripts\windows\DeploymentLock.ps1")
. (Join-Path $repoRoot "scripts\windows\DeploymentTransaction.ps1")
. (Join-Path $repoRoot "scripts\windows\WindowsServiceSecurity.ps1")
$latestReleaseLock = $null
$generatedConfigCreated = $false
$deploymentStarted = $false
$removedPublicBindings = [System.Collections.Generic.List[object]]::new()
$managedTransaction = $null
try {
if (-not $WhatIfPreference) {
    Assert-ManagedDeploymentManagerTransition -Config $baseConfig
    $latestReleaseLock = Enter-DeploymentLock -Config $baseConfig
}
$usesIis = ([string](Get-ConfigValue $baseConfig "ReverseProxy" "none") -eq "iis")

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
    $GeneratedConfigPath = Get-DefaultGeneratedConfigPath $runtimeConfig
} else {
    $GeneratedConfigPath = Resolve-RepoPath $GeneratedConfigPath
}
$GeneratedConfigPath = [System.IO.Path]::GetFullPath($GeneratedConfigPath)
if ($GeneratedConfigPath -ieq [System.IO.Path]::GetFullPath($ConfigPath)) {
    throw "GeneratedConfigPath must not be the source deployment config path."
}
if (Test-Path -LiteralPath $GeneratedConfigPath) {
    throw "Refusing to overwrite an existing generated config path: $GeneratedConfigPath"
}
if (-not $WhatIfPreference) {
    Write-GeneratedConfig -Config $runtimeConfig -Path $GeneratedConfigPath
    $generatedConfigCreated = $true
}

Write-Host "Selected release folder: $selectedReleasePath" -ForegroundColor Cyan
Write-Host "Generated config: $GeneratedConfigPath"
Write-Host "Generated config is temporary unless -KeepGeneratedConfig is specified."
Write-Host "Service: $($runtimeConfig.AppName)"
Write-Host "IIS site: $($runtimeConfig.IisSiteName)"
Write-Host "IIS path: $($runtimeConfig.IisSitePath)"
Write-Host "Public port: $($runtimeConfig.PublicPort)"
Write-Host "Node port: $($runtimeConfig.Port)"

$installArgs = @{
    ConfigPath = $GeneratedConfigPath
    SkipPackageImport = $true
    SkipInstall = $true
    SkipBuild = $true
    AllowPortInUse = $true
}
if ($latestReleaseLock) { $installArgs.ExistingDeploymentLock = $latestReleaseLock }
if ($SkipWinSWDownload) {
    $installArgs.SkipWinSWDownload = $true
}

    if ($PSCmdlet.ShouldProcess($selectedReleasePath, "Deploy latest Windows release folder")) {
        $managedTransaction = Start-ManagedDeploymentTransaction -Config $runtimeConfig -Lock $latestReleaseLock
        $installArgs.ExistingManagedDeploymentTransaction = $managedTransaction
        $deploymentStarted = $true
        if ($usesIis) {
            if ($TakeOverPublicPortBinding) {
                Remove-ConflictingPublicPortBindings -Config $runtimeConfig -RemovedBindings $removedPublicBindings
            } else {
                Assert-NoConflictingPublicPortBinding $runtimeConfig
            }
        }
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
        Complete-ManagedDeploymentTransaction -Config $runtimeConfig -Transaction $managedTransaction
        $managedTransaction = $null
    }
} catch {
    $deploymentFailure = $_
    $rollbackFailures = [System.Collections.Generic.List[string]]::new()
    if ($deploymentStarted) {
        try { Restore-ManagedDeploymentTransaction -Config $runtimeConfig -Transaction $managedTransaction }
        catch { $rollbackFailures.Add("managed service/control state: $($_.Exception.Message)") }
        try { Restore-RemovedPublicPortBindings -RemovedBindings $removedPublicBindings }
        catch { $rollbackFailures.Add("removed bindings: $($_.Exception.Message)") }
        if ($rollbackFailures.Count -eq 0) {
            try {
                Resume-ManagedDeploymentServiceState -Config $runtimeConfig -Transaction $managedTransaction
                Complete-ManagedDeploymentTransaction -Config $runtimeConfig -Transaction $managedTransaction
                $managedTransaction = $null
            } catch { $rollbackFailures.Add("previous service resume: $($_.Exception.Message)") }
        }
    }
    if ($rollbackFailures.Count -gt 0) {
        throw "Deployment failed: $($deploymentFailure.Exception.Message) Rollback also failed: $($rollbackFailures -join '; ') Recovery journal retained: $($managedTransaction.Directory)"
    }
    throw $deploymentFailure
} finally {
    try {
        if ($generatedConfigCreated -and -not $KeepGeneratedConfig -and (Test-Path -LiteralPath $GeneratedConfigPath -PathType Leaf)) {
            Remove-Item -LiteralPath $GeneratedConfigPath -Force
            Write-Host "Removed temporary generated config: $GeneratedConfigPath"
        } elseif ($generatedConfigCreated -and (Test-Path -LiteralPath $GeneratedConfigPath -PathType Leaf)) {
            Write-Host "Generated config retained: $GeneratedConfigPath"
        }
    } finally {
        Release-ManagedIisDeploymentLock -Transaction $managedTransaction
        Exit-DeploymentLock -Lock $latestReleaseLock
    }
}
