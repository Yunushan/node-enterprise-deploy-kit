<#
.SYNOPSIS
  Validate Windows deployment configuration before installing services.
.DESCRIPTION
  Performs safe local checks only. It does not print environment values from
  the config and does not create, stop, start, or modify services.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe",
    [switch] $SkipReverseProxy,
    [switch] $SkipHealthCheck,
    [switch] $AllowPortInUse
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) { $errors.Add($Message) | Out-Null }
function Add-Warning([string]$Message) { $warnings.Add($Message) | Out-Null }
function Test-RequiredString($Object, [string]$Name) {
    if (-not $Object.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        Add-Error "Missing required config value: $Name"
    }
}
function Resolve-ToolPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}
function Get-ConfigString($Object, [string]$Name, [string]$Default = "") {
    if ($Object.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        return [string]$Object.$Name
    }
    return $Default
}
function Get-ConfigBool($Object, [string]$Name, [bool]$Default) {
    if (-not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) {
        return $Default
    }
    if ($Object.$Name -is [bool]) {
        return [bool]$Object.$Name
    }

    $text = ([string]$Object.$Name).Trim().ToLowerInvariant()
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
function Test-WebGlobalModule([string]$Name) {
    if (-not (Get-Command Get-WebGlobalModule -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        return $null -ne (Get-WebGlobalModule -Name $Name -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}
function Test-UrlRewriteServerVariableAllowed([string]$Name) {
    if (-not (Get-Command Get-WebConfigurationProperty -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        $filter = "system.webServer/rewrite/allowedServerVariables/add[@name='$Name']"
        return $null -ne (Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $filter -Name "name" -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}
function Get-NormalizedRelativePath([string]$Path, [string]$Default) {
    $value = $Path
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
    }

    $value = $value.Trim() -replace "\\", "/"
    $value = $value.Trim("/")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
    }
    if ($value -match '(^|/)\.\.($|/)' -or $value -notmatch '^[A-Za-z0-9._~/-]+$') {
        throw "IisHealthProxyPath must be a relative URL path using letters, numbers, dot, underscore, dash, tilde, or slash."
    }
    return $value
}
function Test-BuiltInServiceAccount([string]$Account) {
    $normalized = $Account.Trim().ToLowerInvariant()
    return $normalized -in @(
        "localsystem",
        "localservice",
        "networkservice",
        "nt authority\localservice",
        "nt authority\networkservice"
    )
}
function Get-ServiceProcessTreeIds([string]$Name) {
    $ids = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrWhiteSpace($Name)) { return @() }
    $escaped = $Name.Replace("'", "''")
    $svc = Get-CimInstance Win32_Service -Filter "Name='$escaped'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.ProcessId -and $svc.ProcessId -gt 0) {
        $ids.Add([int]$svc.ProcessId) | Out-Null
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.ProcessId)" -ErrorAction SilentlyContinue
        foreach ($child in @($children)) {
            if ($child.ProcessId) { $ids.Add([int]$child.ProcessId) | Out-Null }
        }
    }
    return @($ids | Sort-Object -Unique)
}
function Test-LoopbackHost([string]$HostName) {
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $normalized = $HostName.Trim().ToLowerInvariant()
    return $normalized -in @("localhost", "127.0.0.1", "::1") -or $normalized.StartsWith("127.")
}
function Test-SensitiveConfigName([string]$Name) {
    return $Name -match '(?i)(password|secret|token|api[_-]?key|credential|connectionstring|database_url|jwt|private)'
}
function Get-SensitiveEnvironmentNames($Object) {
    $names = New-Object System.Collections.Generic.List[string]
    if (-not $Object.Environment) { return @() }
    foreach ($property in $Object.Environment.PSObject.Properties) {
        if (Test-SensitiveConfigName $property.Name) {
            $names.Add($property.Name) | Out-Null
        }
    }
    return @($names | Sort-Object -Unique)
}
function Test-UserProfilePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $Path -match '^[A-Za-z]:\\Users\\[^\\]+\\(Desktop|Downloads|Documents)(\\|$)'
}

@(
    "AppName",
    "DisplayName",
    "AppDirectory",
    "StartCommand",
    "NodeExe",
    "Port",
    "HealthUrl",
    "ServiceManager",
    "ReverseProxy",
    "ServiceDirectory",
    "LogDirectory"
) | ForEach-Object { Test-RequiredString $config $_ }

if ($config.AppName -and ([string]$config.AppName -notmatch '^[A-Za-z0-9_.-]+$')) {
    Add-Error "AppName should contain only letters, numbers, dot, underscore, or dash for service compatibility."
}

if ($config.NodeExe -and -not (Test-Path $config.NodeExe)) {
    Add-Error "NodeExe not found: $($config.NodeExe)"
}
if ($config.NodeExe -and -not [System.IO.Path]::IsPathRooted([string]$config.NodeExe)) {
    Add-Warning "NodeExe is not an absolute path. Use an explicit trusted Node.js path in production."
}

if ($config.AppDirectory -and -not (Test-Path $config.AppDirectory)) {
    Add-Error "AppDirectory not found: $($config.AppDirectory)"
}
foreach ($pathCheck in @("AppDirectory", "ServiceDirectory", "LogDirectory", "BackupDirectory")) {
    if ($config.PSObject.Properties[$pathCheck] -and (Test-UserProfilePath ([string]$config.$pathCheck))) {
        Add-Warning "$pathCheck is under a user profile desktop/downloads/documents path. Use a service-owned production directory."
    }
}

if ($config.AppDirectory -and $config.StartCommand -and (Test-Path $config.AppDirectory)) {
    $startCommand = [string]$config.StartCommand
    if (-not [System.IO.Path]::IsPathRooted($startCommand)) {
        $startCommandPath = Join-Path $config.AppDirectory $startCommand
        if ($startCommand -notmatch '\s' -and -not (Test-Path $startCommandPath)) {
            Add-Error "StartCommand file not found under AppDirectory: $startCommandPath"
        }
    } elseif (-not (Test-Path $startCommand)) {
        Add-Error "StartCommand file not found: $startCommand"
    }
}

$port = 0
if (-not [int]::TryParse([string]$config.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    Add-Error "Port must be an integer between 1 and 65535."
}

if ($config.Environment -and $config.Environment.PSObject.Properties["PORT"]) {
    $envPort = [string]$config.Environment.PORT
    if ($envPort -and $envPort -ne [string]$config.Port) {
        Add-Warning "Environment.PORT does not match Port. The service may listen on an unexpected port."
    }
}

$healthUri = $null
try {
    $healthUri = [Uri][string]$config.HealthUrl
    if ($healthUri.Scheme -notin @("http", "https")) {
        Add-Error "HealthUrl must use http or https."
    }
    if ($healthUri.Port -gt 0 -and $port -gt 0 -and $healthUri.Port -ne $port) {
        Add-Warning "HealthUrl port ($($healthUri.Port)) does not match Port ($port)."
    }
} catch {
    Add-Error "HealthUrl is not a valid URI: $($config.HealthUrl)"
}

$sensitiveEnvironmentNames = @(Get-SensitiveEnvironmentNames $config)
if ($sensitiveEnvironmentNames.Count -gt 0) {
    Add-Warning "Environment contains secret-like key name(s): $($sensitiveEnvironmentNames -join ', '). Keep values out of committed config and prefer a secret manager or target-local private config."
}

$serviceManager = ([string]$config.ServiceManager).ToLowerInvariant()
switch ($serviceManager) {
    "winsw" {
        $winswCandidate = Resolve-ToolPath $WinSWPath
        if (-not (Test-Path $winswCandidate)) {
            Add-Error "WinSW executable not found: $winswCandidate"
        }
        $serviceAccount = Get-ConfigString $config "ServiceAccount" "LocalSystem"
        $serviceAccountCredential = Get-ConfigString $config "ServiceAccountPassword" ""
        if (-not (Test-BuiltInServiceAccount $serviceAccount) -and -not $serviceAccount.Trim().EndsWith('$') -and [string]::IsNullOrWhiteSpace($serviceAccountCredential)) {
            Add-Error "ServiceAccount '$serviceAccount' needs ServiceAccountPassword unless it is LocalSystem, LocalService, NetworkService, or a gMSA ending in '$'."
        }
        if ($serviceAccount.Trim().ToLowerInvariant() -eq "localsystem") {
            Add-Warning "ServiceAccount is LocalSystem. Prefer NetworkService or a gMSA/dedicated least-privilege account for production."
        }
        if (-not [string]::IsNullOrWhiteSpace($serviceAccountCredential)) {
            Add-Warning "ServiceAccountPassword is configured. Prefer a gMSA for production so passwords are not stored in deployment config."
        }
    }
    "nssm" {
        $nssmCandidate = Resolve-ToolPath "tools\nssm\nssm.exe"
        if (-not (Test-Path $nssmCandidate)) {
            Add-Warning "NSSM selected, but default nssm.exe was not found: $nssmCandidate"
        }
    }
    "pm2" {
        if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
            Add-Error "PM2 selected, but pm2 was not found in PATH."
        }
    }
    default {
        Add-Error "Unsupported ServiceManager: $($config.ServiceManager). Use winsw, nssm, or pm2."
    }
}

$reverseProxy = ([string]$config.ReverseProxy).ToLowerInvariant()
$bindAddress = Get-ConfigString $config "BindAddress" "127.0.0.1"
if ($reverseProxy -ne "none" -and $reverseProxy -ne "" -and -not (Test-LoopbackHost $bindAddress)) {
    Add-Warning "BindAddress is '$bindAddress' while ReverseProxy is '$($config.ReverseProxy)'. Bind Node.js to 127.0.0.1 unless direct exposure is intentional."
}
if ($healthUri -and $reverseProxy -ne "none" -and $reverseProxy -ne "" -and -not (Test-LoopbackHost $healthUri.Host)) {
    Add-Warning "HealthUrl host is '$($healthUri.Host)'. For reverse-proxy deployments, health checks should normally target localhost/127.0.0.1."
}
foreach ($envBindName in @("BIND_ADDRESS", "HOST", "HOSTNAME")) {
    if ($config.Environment -and $config.Environment.PSObject.Properties[$envBindName]) {
        $envBindValue = [string]$config.Environment.$envBindName
        if ($reverseProxy -ne "none" -and $reverseProxy -ne "" -and -not (Test-LoopbackHost $envBindValue)) {
            Add-Warning "Environment.$envBindName is '$envBindValue'. For reverse-proxy deployments, prefer 127.0.0.1."
        }
    }
}
if (-not $SkipReverseProxy) {
    switch ($reverseProxy) {
        "iis" {
            Test-RequiredString $config "IisSitePath"
            if ($config.PSObject.Properties["PublicPort"] -and $config.PublicPort) {
                $publicPort = 0
                if (-not [int]::TryParse([string]$config.PublicPort, [ref]$publicPort) -or $publicPort -lt 1 -or $publicPort -gt 65535) {
                    Add-Error "PublicPort must be an integer between 1 and 65535."
                }
            }
            $iisEnableArrProxy = $true
            $iisSetForwardedHeaders = $true
            $iisWebSocketSupport = $true
            try { $iisEnableArrProxy = Get-ConfigBool $config "IisEnableArrProxy" $true } catch { Add-Error $_.Exception.Message }
            try { $iisSetForwardedHeaders = Get-ConfigBool $config "IisSetForwardedHeaders" $true } catch { Add-Error $_.Exception.Message }
            try { $iisWebSocketSupport = Get-ConfigBool $config "IisWebSocketSupport" $true } catch { Add-Error $_.Exception.Message }
            try {
                [void](Get-NormalizedRelativePath (Get-ConfigString $config "IisHealthProxyPath" "health") "health")
            } catch {
                Add-Error $_.Exception.Message
            }
            if ($config.PSObject.Properties["IisProxyTimeoutSeconds"] -and -not [string]::IsNullOrWhiteSpace([string]$config.IisProxyTimeoutSeconds)) {
                $iisProxyTimeoutSeconds = 0
                if (-not [int]::TryParse([string]$config.IisProxyTimeoutSeconds, [ref]$iisProxyTimeoutSeconds) -or $iisProxyTimeoutSeconds -lt 1) {
                    Add-Error "IisProxyTimeoutSeconds must be an integer >= 1."
                }
            }

            $webAdminAvailable = $false
            if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
                Add-Warning "IIS WebAdministration module was not found. IIS site/app-pool automation may not be available."
            } else {
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $webAdminAvailable = $true
                } catch {
                    Add-Warning "IIS WebAdministration module could not be loaded. IIS module checks were skipped. $($_.Exception.Message)"
                }
            }
            if ($webAdminAvailable) {
                if (-not (Test-WebGlobalModule "RewriteModule")) {
                    Add-Warning "IIS URL Rewrite module was not detected. Install URL Rewrite before using ReverseProxy=iis."
                }
                if ($iisEnableArrProxy -and -not (Test-WebGlobalModule "ApplicationRequestRouting")) {
                    Add-Warning "IisEnableArrProxy is true, but IIS ARR was not detected. Install Application Request Routing or manage ARR proxy settings manually."
                }
                if ($iisWebSocketSupport -and -not (Test-WebGlobalModule "WebSocketModule")) {
                    Add-Warning "IisWebSocketSupport is true, but the IIS WebSocket module was not detected. Install the WebSocket Protocol feature if the app uses WebSockets."
                }
                if ($iisSetForwardedHeaders) {
                    $missingServerVariables = @(@(
                        "HTTP_X_FORWARDED_HOST",
                        "HTTP_X_FORWARDED_PROTO",
                        "HTTP_X_FORWARDED_PORT",
                        "HTTP_X_FORWARDED_FOR"
                    ) | Where-Object { -not (Test-UrlRewriteServerVariableAllowed $_) })
                    if ($missingServerVariables.Count -gt 0) {
                        Add-Warning "IisSetForwardedHeaders is true, but these URL Rewrite server variables are not currently allowed: $($missingServerVariables -join ', '). The IIS installer will try to configure them when run as Administrator."
                    }
                }
            }
            if ($config.PSObject.Properties["TlsEnabled"] -and [bool]$config.TlsEnabled) {
                if (-not $config.PSObject.Properties["IisCertificateThumbprint"] -or [string]::IsNullOrWhiteSpace([string]$config.IisCertificateThumbprint)) {
                    Add-Warning "TlsEnabled is true but IisCertificateThumbprint is empty. The IIS script will warn and leave certificate binding for manual setup."
                }
                if (-not $config.PSObject.Properties["PublicHostName"] -or [string]::IsNullOrWhiteSpace([string]$config.PublicHostName)) {
                    Add-Warning "TlsEnabled is true but PublicHostName is empty. Host-scoped HTTPS/SNI bindings may need manual review."
                }
            } elseif (-not $config.PSObject.Properties["TlsEnabled"] -or -not [bool]$config.TlsEnabled) {
                Add-Warning "TlsEnabled is false for IIS reverse proxy. Use TLS at IIS or a documented upstream load balancer in production."
            }
        }
        "none" {}
        "" {}
        default {
            Add-Error "Unsupported ReverseProxy: $($config.ReverseProxy). Use iis or none on Windows."
        }
    }
}

if (-not $SkipHealthCheck) {
    $interval = 0
    if (-not [int]::TryParse([string]$config.HealthCheckIntervalMinutes, [ref]$interval) -or $interval -lt 1) {
        Add-Warning "HealthCheckIntervalMinutes is missing or below 1. The installer will use 1 minute."
    }
    foreach ($check in @(
        @{ Name = "HealthCheckFailureThreshold"; Default = 2 },
        @{ Name = "HealthCheckRestartCooldownMinutes"; Default = 5 },
        @{ Name = "HealthCheckTimeoutSeconds"; Default = 10 }
    )) {
        $property = $config.PSObject.Properties[$check.Name]
        if ($property -and $property.Value) {
            $value = 0
            if (-not [int]::TryParse([string]$property.Value, [ref]$value) -or $value -lt 1) {
                Add-Warning "$($check.Name) should be an integer >= 1. Default will be used by health checks if invalid."
            }
        }
    }
}

if ($port -gt 0 -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listeners) {
        $ownerIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
        $owners = $ownerIds -join ", "
        $serviceProcessIds = Get-ServiceProcessTreeIds ([string]$config.AppName)
        $matchingOwnerCount = @($ownerIds | Where-Object { $serviceProcessIds -contains $_ }).Count
        $ownedByConfiguredService = ($serviceProcessIds.Count -gt 0) -and ($matchingOwnerCount -eq $ownerIds.Count)
        if ($AllowPortInUse) {
            Add-Warning "Port $port is already listening. Owning process ID(s): $owners"
        } elseif ($ownedByConfiguredService) {
            Add-Warning "Port $port is already listening by the configured service. This is normal for service updates."
        } else {
            Add-Error "Port $port is already listening. Owning process ID(s): $owners. Stop the conflicting service or pass -AllowPortInUse for updates."
        }
    }
}

Write-Host "Preflight checked: $($config.AppName)" -ForegroundColor Cyan
if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Warning $_ }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Errors" -ForegroundColor Red
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Preflight failed with $($errors.Count) error(s)."
}

Write-Host "Preflight passed." -ForegroundColor Green
