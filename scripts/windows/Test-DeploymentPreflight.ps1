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
    [string] $WinSWDownloadUrl = "",
    [string] $WinSWDownloadSha256 = "",
    [string] $PackagePath = "",
    [switch] $SkipWinSWDownload,
    [switch] $SkipPackageImport,
    [switch] $SkipReverseProxy,
    [switch] $SkipHealthCheck,
    [switch] $AllowPortInUse
)

$ErrorActionPreference = "Stop"
$DefaultWinSWDownloadUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
$DefaultNextJsMinimumNodeVersion = "20.9.0"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot $ConfigPath
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$effectivePackagePath = $PackagePath
if ([string]::IsNullOrWhiteSpace($effectivePackagePath) -and $config.PSObject.Properties["PackagePath"]) {
    $effectivePackagePath = [string]$config.PackagePath
}
if ($SkipPackageImport) {
    $effectivePackagePath = ""
}
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
function Get-ConfigEnvironmentString($Object, [string]$Name) {
    if (-not $Object.PSObject.Properties["Environment"] -or -not $Object.Environment) { return "" }
    if (-not $Object.Environment.PSObject.Properties[$Name]) { return "" }
    return [string]$Object.Environment.$Name
}
function Test-Base64AesKeyLength([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or ($Value.Length % 4) -ne 0) { return $false }
    try {
        $bytes = [Convert]::FromBase64String($Value)
        return $bytes.Length -in @(16, 24, 32)
    } catch {
        return $false
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
function Get-IisExpectedBindingInformation([string]$Protocol, [int]$Port, [string]$HostHeader) {
    if ([string]::IsNullOrWhiteSpace($HostHeader)) { return "*:${Port}:" }
    return "*:${Port}:$HostHeader"
}
function Get-IisSitesForBinding([string]$Protocol, [string]$BindingInformation) {
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($site in @(Get-ChildItem IIS:\Sites -ErrorAction SilentlyContinue)) {
        foreach ($binding in @($site.Bindings.Collection)) {
            if ([string]$binding.protocol -eq $Protocol -and [string]$binding.bindingInformation -eq $BindingInformation) {
                $matches.Add([pscustomobject]@{
                    SiteName = [string]$site.Name
                    State = [string]$site.State
                    PhysicalPath = [string]$site.PhysicalPath
                }) | Out-Null
            }
        }
    }
    return @($matches)
}
function Get-NormalizedPathForCompare([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    try {
        return ([System.IO.Path]::GetFullPath($expanded)).TrimEnd([char[]]@('\', '/'))
    } catch {
        return $expanded.TrimEnd([char[]]@('\', '/'))
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
    if (-not $Object.PSObject.Properties["Environment"] -or -not $Object.Environment) { return @() }
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
function Test-ValidSha256([string]$Hash) {
    if ([string]::IsNullOrWhiteSpace($Hash)) { return $true }
    return $Hash -match '^[A-Fa-f0-9]{64}$'
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
function Test-NextJsNodeVersion($Config) {
    $minimum = Get-ConfigString $Config "NextjsMinimumNodeVersion" $DefaultNextJsMinimumNodeVersion
    if ($null -eq (Get-SemverParts $minimum)) {
        Add-Error "NextjsMinimumNodeVersion must be a semantic version like 20.9.0."
        return
    }
    $nodeExe = Get-ConfigString $Config "NodeExe" "node"
    $nodeVersion = Get-NodeRuntimeVersion $nodeExe
    if ([string]::IsNullOrWhiteSpace($nodeVersion)) {
        Add-Error "Next.js requires Node.js >= $minimum, but NodeExe did not return a version with --version: $nodeExe"
        return
    }
    $satisfied = Test-SemverAtLeast -Actual $nodeVersion -Minimum $minimum
    if ($null -eq $satisfied) {
        Add-Error "Next.js requires Node.js >= $minimum, but NodeExe returned an unrecognized version: $nodeVersion"
    } elseif (-not $satisfied) {
        Add-Error "Next.js requires Node.js >= $minimum; configured NodeExe reports $nodeVersion."
    }
}
function Test-HttpsUri([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $uri = [Uri]$Url
        return $uri.Scheme -eq "https"
    } catch {
        return $false
    }
}
function Normalize-Name([string]$Value) {
    return ([string]$Value).Trim().ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
}
function Test-SafeRelativeFilePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = $Path -replace "\\", "/"
    foreach ($part in $normalized.Split("/")) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -eq ".") { continue }
        if ($part -eq "..") { return $false }
    }
    return $true
}
function Test-ReactFramework([string]$Framework) {
    return (Normalize-Name $Framework) -in @("react", "reactjs", "react-js")
}
function Get-ReactDocumentRoot($Config) {
    $documentRoot = (Get-ConfigString $Config "ReactDocumentRoot" "build").Trim()
    if ([string]::IsNullOrWhiteSpace($documentRoot)) {
        $documentRoot = "build"
    }
    return ($documentRoot -replace "\\", "/").Trim("/")
}
function Join-AppRelativePath([string]$Root, [string]$RelativePath) {
    $normalized = ($RelativePath -replace "\\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq ".") {
        return $Root
    }
    return (Join-Path $Root ($normalized -replace "/", "\"))
}
function Get-StartCommandPath([string]$AppDirectory, [string]$StartCommand) {
    if ([System.IO.Path]::IsPathRooted($StartCommand)) {
        return $StartCommand
    }
    return (Join-Path $AppDirectory $StartCommand)
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
function Test-NextJsDeploymentLayout($Config) {
    $framework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
    if ($framework -notin @("next", "nextjs", "next-js")) { return }
    Test-NextJsNodeVersion $Config

    $requireServerActionsKey = $false
    $requireDeploymentId = $false
    try { $requireServerActionsKey = Get-ConfigBool $Config "NextjsRequireServerActionsEncryptionKey" $false } catch { Add-Error $_.Exception.Message }
    try { $requireDeploymentId = Get-ConfigBool $Config "NextjsRequireDeploymentId" $false } catch { Add-Error $_.Exception.Message }
    if ($requireServerActionsKey) {
        $serverActionsKey = Get-ConfigEnvironmentString $Config "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"
        if ([string]::IsNullOrWhiteSpace($serverActionsKey)) {
            Add-Error "NextjsRequireServerActionsEncryptionKey is true, but Environment.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY is missing. Put the value in target-local private config, not committed example config."
        } elseif (-not (Test-Base64AesKeyLength $serverActionsKey)) {
            Add-Error "Environment.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY must be base64-encoded with a valid AES key length of 16, 24, or 32 bytes."
        }
    }
    if ($requireDeploymentId) {
        $deploymentId = Get-ConfigEnvironmentString $Config "NEXT_DEPLOYMENT_ID"
        if ([string]::IsNullOrWhiteSpace($deploymentId)) {
            Add-Error "NextjsRequireDeploymentId is true, but Environment.NEXT_DEPLOYMENT_ID is missing. Put the deployment ID in target-local private config or set it during build."
        } elseif ($deploymentId -match '\s') {
            Add-Error "Environment.NEXT_DEPLOYMENT_ID must not contain whitespace."
        }
    }

    $mode = Normalize-Name (Get-ConfigString $Config "NextjsDeploymentMode" "standalone")
    if ($mode -notin @("standalone", "next-start")) {
        Add-Error "NextjsDeploymentMode must be standalone or next-start."
        return
    }

    if (-not (Test-Path -LiteralPath $Config.AppDirectory -PathType Container)) {
        return
    }

    $startCommand = [string](Get-ConfigString $Config "StartCommand" "server.js")
    if ([string]::IsNullOrWhiteSpace($startCommand) -or $startCommand -match '\s') {
        Add-Error "StartCommand must be a single file path for Next.js layout validation. Put script arguments in NodeArguments."
        return
    }

    if ($mode -eq "standalone") {
        if (-not [System.IO.Path]::IsPathRooted($startCommand) -and -not (Test-SafeRelativeFilePath $startCommand)) {
            Add-Error "StartCommand must be a safe relative file path for Next.js standalone validation."
            return
        }
        $startCommandPath = Get-StartCommandPath -AppDirectory $Config.AppDirectory -StartCommand $startCommand
        $standaloneRoot = Split-Path -Parent $startCommandPath
        if ([System.IO.Path]::GetFileName($startCommandPath) -ne "server.js") {
            Add-Warning "Next.js standalone deployments normally start the generated server.js file."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $standaloneRoot ".next") -PathType Container)) {
            Add-Error "Next.js standalone runtime root is missing .next directory: $standaloneRoot"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $standaloneRoot ".next\BUILD_ID") -PathType Leaf)) {
            Add-Error "Next.js standalone runtime root is missing .next\BUILD_ID. Keep BUILD_ID with the deployed artifact so status evidence can identify the running build."
        }
        $requireStatic = $true
        try { $requireStatic = Get-ConfigBool $Config "NextjsRequireStaticAssets" $true } catch { Add-Error $_.Exception.Message }
        if ($requireStatic -and -not (Test-Path -LiteralPath (Join-Path $standaloneRoot ".next\static") -PathType Container)) {
            Add-Error "Next.js standalone runtime root is missing .next/static. Copy .next/static into the standalone .next directory before deployment."
        }
        $requirePublic = $false
        try { $requirePublic = Get-ConfigBool $Config "NextjsRequirePublicDirectory" $false } catch { Add-Error $_.Exception.Message }
        if ($requirePublic -and -not (Test-Path -LiteralPath (Join-Path $standaloneRoot "public") -PathType Container)) {
            Add-Error "Next.js standalone runtime root is missing public directory, but NextjsRequirePublicDirectory is true."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $standaloneRoot "node_modules") -PathType Container)) {
            Add-Warning "Next.js standalone runtime root has no node_modules directory. Confirm the standalone artifact includes traced dependencies."
        }
    } elseif ($mode -eq "next-start") {
        if (-not [System.IO.Path]::IsPathRooted($startCommand) -and -not (Test-SafeRelativeFilePath $startCommand)) {
            Add-Error "StartCommand must be a safe relative file path for Next.js next-start validation."
        } else {
            $startCommandPath = Get-StartCommandPath -AppDirectory $Config.AppDirectory -StartCommand $startCommand
            $normalizedStartCommand = ($startCommandPath -replace "\\", "/").ToLowerInvariant()
            if (-not (Test-Path -LiteralPath $startCommandPath -PathType Leaf)) {
                Add-Error "Next.js next-start StartCommand file was not found: $startCommandPath"
            }
            if ($normalizedStartCommand -notmatch '/node_modules/next/') {
                Add-Error "Next.js next-start StartCommand should point to the Next CLI under node_modules/next, for example node_modules/next/dist/bin/next."
            }
        }
        $nodeArguments = Get-ConfigString $Config "NodeArguments" ""
        $argumentTokens = @(Split-ArgumentTokens $nodeArguments)
        if ($argumentTokens.Count -eq 0 -or $argumentTokens[0] -ne "start") {
            Add-Error "Next.js next-start mode requires NodeArguments to start with 'start'. Example: start -H $((Get-ConfigString $Config "BindAddress" "127.0.0.1"))"
        }
        $bindAddress = Get-ConfigString $Config "BindAddress" "127.0.0.1"
        $hostnameArgument = Get-HostnameArgumentValue $argumentTokens
        if ([string]::IsNullOrWhiteSpace($hostnameArgument)) {
            Add-Error "Next.js next-start mode requires NodeArguments to include '-H $bindAddress' or '--hostname $bindAddress' so next start binds to the configured BindAddress."
        } elseif ($hostnameArgument -ne $bindAddress) {
            Add-Error "Next.js next-start hostname argument '$hostnameArgument' must match BindAddress '$bindAddress'."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Config.AppDirectory "package.json") -PathType Leaf)) {
            Add-Error "Next.js next-start mode requires package.json under AppDirectory."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Config.AppDirectory ".next") -PathType Container)) {
            Add-Error "Next.js next-start mode requires a built .next directory under AppDirectory."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Config.AppDirectory ".next\BUILD_ID") -PathType Leaf)) {
            Add-Error "Next.js next-start mode requires .next\BUILD_ID under AppDirectory so status evidence can identify the running build."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Config.AppDirectory "node_modules\next") -PathType Container)) {
            Add-Error "Next.js next-start mode requires node_modules/next under AppDirectory."
        }
    }
}
function Test-ReactDeploymentLayout($Config) {
    $framework = Normalize-Name (Get-ConfigString $Config "AppFramework" "node")
    if (-not (Test-ReactFramework $framework)) { return }

    $documentRoot = Get-ReactDocumentRoot $Config
    if (-not (Test-SafeRelativeFilePath $documentRoot)) {
        Add-Error "ReactDocumentRoot must be a safe relative directory path."
        return
    }

    if (-not (Test-Path -LiteralPath $Config.AppDirectory -PathType Container)) {
        return
    }

    $reactRoot = Join-AppRelativePath -Root $Config.AppDirectory -RelativePath $documentRoot
    $indexPath = Join-Path $reactRoot "index.html"
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        Add-Error "React deployment root is missing index.html: $indexPath"
    }
    $hasCommonAssetDirectory = (
        (Test-Path -LiteralPath (Join-Path $reactRoot "static") -PathType Container) -or
        (Test-Path -LiteralPath (Join-Path $reactRoot "assets") -PathType Container)
    )
    if (-not $hasCommonAssetDirectory) {
        Add-Warning "React deployment root has no static or assets directory. This can be valid for tiny apps, but verify the built artifact contains browser assets."
    }
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
    if (-not [string]::IsNullOrWhiteSpace($effectivePackagePath)) {
        Add-Warning "AppDirectory does not exist yet, but PackagePath is configured. Package import should create it before app preparation."
    } else {
        Add-Error "AppDirectory not found: $($config.AppDirectory)"
    }
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

Test-NextJsDeploymentLayout $config
Test-ReactDeploymentLayout $config

$port = 0
if (-not [int]::TryParse([string]$config.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    Add-Error "Port must be an integer between 1 and 65535."
}

if ($config.PSObject.Properties["Environment"] -and $config.Environment -and $config.Environment.PSObject.Properties["PORT"]) {
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

if (-not [string]::IsNullOrWhiteSpace($effectivePackagePath)) {
    $packagePath = [string]$effectivePackagePath
    if ([System.IO.Path]::GetExtension($packagePath).ToLowerInvariant() -ne ".zip") {
        Add-Error "PackagePath supports .zip only on Windows. Use .zip; .rar and .7z are intentionally unsupported."
    }
    if ($config.PSObject.Properties["PackageExpectedFiles"]) {
        $expectedValues = @()
        if ($config.PackageExpectedFiles -is [array]) {
            $expectedValues = @($config.PackageExpectedFiles)
        } else {
            $expectedValues = @(([string]$config.PackageExpectedFiles) -split '[,;]')
        }
        if (@($expectedValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
            Add-Warning "PackageExpectedFiles is empty. The package importer will fall back to StartCommand validation."
        }
    }
}

$sensitiveEnvironmentNames = @(Get-SensitiveEnvironmentNames $config)
if ($sensitiveEnvironmentNames.Count -gt 0) {
    Add-Warning "Environment contains secret-like key name(s): $($sensitiveEnvironmentNames -join ', '). Keep values out of committed config and prefer a secret manager or target-local private config."
}

$serviceManager = ([string]$config.ServiceManager).ToLowerInvariant()
switch ($serviceManager) {
    "winsw" {
        $winswCandidate = Resolve-ToolPath $WinSWPath
        $winswAutoDownload = $true
        try {
            $winswAutoDownload = Get-ConfigBool $config "AutoDownloadWinSW" $true
        } catch {
            Add-Error $_.Exception.Message
        }
        if ($SkipWinSWDownload) {
            $winswAutoDownload = $false
        }
        $requireWinSWSha256 = $true
        try {
            $requireWinSWSha256 = Get-ConfigBool $config "RequireWinSWDownloadSha256" $true
        } catch {
            Add-Error $_.Exception.Message
        }

        $effectiveWinSWDownloadUrl = Get-ConfigString $config "WinSWDownloadUrl" $DefaultWinSWDownloadUrl
        if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadUrl)) {
            $effectiveWinSWDownloadUrl = $WinSWDownloadUrl
        }
        $effectiveWinSWDownloadSha256 = Get-ConfigString $config "WinSWDownloadSha256" ""
        if (-not [string]::IsNullOrWhiteSpace($WinSWDownloadSha256)) {
            $effectiveWinSWDownloadSha256 = $WinSWDownloadSha256
        }
        if (-not (Test-ValidSha256 $effectiveWinSWDownloadSha256)) {
            Add-Error "WinSWDownloadSha256 must be a 64-character SHA256 hex digest."
        }
        if ($requireWinSWSha256 -and [string]::IsNullOrWhiteSpace($effectiveWinSWDownloadSha256)) {
            Add-Error "WinSWDownloadSha256 is required when RequireWinSWDownloadSha256 is true."
        }
        if ($winswAutoDownload -and -not (Test-HttpsUri $effectiveWinSWDownloadUrl)) {
            Add-Error "WinSWDownloadUrl must be a valid https URL."
        }
        if (-not (Test-Path $winswCandidate)) {
            if ($winswAutoDownload) {
                Add-Warning "WinSW executable not found locally: $winswCandidate. Deployment will download the configured pinned WinSW release before service install."
            } else {
                Add-Error "WinSW executable not found: $winswCandidate"
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($effectiveWinSWDownloadSha256)) {
            $actualHash = (Get-FileHash -LiteralPath $winswCandidate -Algorithm SHA256).Hash
            if ($actualHash -ine $effectiveWinSWDownloadSha256) {
                Add-Error "Existing WinSW executable failed SHA256 verification: $winswCandidate"
            }
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
    if ($config.PSObject.Properties["Environment"] -and $config.Environment -and $config.Environment.PSObject.Properties[$envBindName]) {
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
            $siteName = Get-ConfigString $config "IisSiteName" ([string]$config.AppName)
            $publicHostName = Get-ConfigString $config "PublicHostName" ""
            $tlsEnabledForIis = $false
            try { $tlsEnabledForIis = Get-ConfigBool $config "TlsEnabled" $false } catch { Add-Error $_.Exception.Message }
            $protocol = if ($tlsEnabledForIis) { "https" } else { "http" }
            $publicPort = if ($tlsEnabledForIis) { 443 } else { 80 }
            if ($config.PSObject.Properties["PublicPort"] -and -not [string]::IsNullOrWhiteSpace([string]$config.PublicPort)) {
                if (-not [int]::TryParse([string]$config.PublicPort, [ref]$publicPort) -or $publicPort -lt 1 -or $publicPort -gt 65535) {
                    Add-Error "PublicPort must be an integer between 1 and 65535."
                    $publicPort = if ($tlsEnabledForIis) { 443 } else { 80 }
                }
            }
            $iisEnableArrProxy = $true
            $iisSetForwardedHeaders = $true
            $iisWebSocketSupport = $true
            $iisRequireUrlRewrite = $true
            $iisRequireArrProxy = $true
            try { $iisEnableArrProxy = Get-ConfigBool $config "IisEnableArrProxy" $true } catch { Add-Error $_.Exception.Message }
            try { $iisSetForwardedHeaders = Get-ConfigBool $config "IisSetForwardedHeaders" $true } catch { Add-Error $_.Exception.Message }
            try { $iisWebSocketSupport = Get-ConfigBool $config "IisWebSocketSupport" $true } catch { Add-Error $_.Exception.Message }
            try { $iisRequireUrlRewrite = Get-ConfigBool $config "IisRequireUrlRewrite" $true } catch { Add-Error $_.Exception.Message }
            try { $iisRequireArrProxy = Get-ConfigBool $config "IisRequireArrProxy" $true } catch { Add-Error $_.Exception.Message }
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
                if ($iisRequireUrlRewrite -or $iisRequireArrProxy) {
                    Add-Error "IIS WebAdministration module was not found. Install IIS management tools or set IisRequireUrlRewrite/IisRequireArrProxy to false only when IIS prerequisites are managed and verified separately."
                } else {
                    Add-Warning "IIS WebAdministration module was not found. IIS site/app-pool automation may not be available."
                }
            } else {
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $webAdminAvailable = $true
                } catch {
                    if ($iisRequireUrlRewrite -or $iisRequireArrProxy) {
                        Add-Error "IIS WebAdministration module could not be loaded, so required IIS module checks were skipped. Run as Administrator or set IisRequireUrlRewrite/IisRequireArrProxy to false only when IIS prerequisites are managed and verified separately. $($_.Exception.Message)"
                    } else {
                        Add-Warning "IIS WebAdministration module could not be loaded. IIS module checks were skipped. $($_.Exception.Message)"
                    }
                }
            }
            if ($webAdminAvailable) {
                if (-not (Test-WebGlobalModule "RewriteModule")) {
                    if ($iisRequireUrlRewrite) {
                        Add-Error "IIS URL Rewrite module was not detected. Install URL Rewrite before using ReverseProxy=iis, or set IisRequireUrlRewrite=false only when rewrite rules are managed and verified separately."
                    } else {
                        Add-Warning "IIS URL Rewrite module was not detected. Reverse proxy rules in web.config will not work until URL Rewrite is installed."
                    }
                }
                if (-not (Test-WebGlobalModule "ApplicationRequestRouting")) {
                    if ($iisRequireArrProxy) {
                        Add-Error "IIS Application Request Routing module was not detected. Install ARR before using ReverseProxy=iis, or set IisRequireArrProxy=false only when proxy support is managed and verified separately."
                    } elseif ($iisEnableArrProxy) {
                        Add-Warning "IisEnableArrProxy is true, but IIS ARR was not detected. Install Application Request Routing or manage ARR proxy settings manually."
                    }
                }
                if ($iisWebSocketSupport -and -not (Test-WebGlobalModule "WebSocketModule")) {
                    Add-Warning "IisWebSocketSupport is true, but the IIS WebSocket module was not detected. Install the WebSocket Protocol feature if the app uses WebSockets."
                }
                $expectedBinding = Get-IisExpectedBindingInformation -Protocol $protocol -Port $publicPort -HostHeader $publicHostName
                $bindingSites = @(Get-IisSitesForBinding -Protocol $protocol -BindingInformation $expectedBinding)
                $conflictingBindingSites = @($bindingSites | Where-Object { $_.SiteName -ne $siteName })
                if ($conflictingBindingSites.Count -gt 0) {
                    $conflictingNames = @($conflictingBindingSites | Select-Object -ExpandProperty SiteName -Unique)
                    Add-Error "IIS $protocol binding on public port $publicPort is already assigned to other site(s): $($conflictingNames -join ', '). Remove the conflicting binding or use a deliberate binding takeover workflow."
                } elseif (@($bindingSites | Where-Object { $_.SiteName -eq $siteName }).Count -gt 0) {
                    Add-Warning "IIS $protocol binding on public port $publicPort already exists on the configured site. This is normal for service updates."
                }
                $existingSite = Get-Website -Name $siteName -ErrorAction SilentlyContinue
                if ($existingSite -and -not [string]::IsNullOrWhiteSpace([string]$config.IisSitePath)) {
                    $actualSitePath = Get-NormalizedPathForCompare ([string]$existingSite.PhysicalPath)
                    $configuredSitePath = Get-NormalizedPathForCompare ([string]$config.IisSitePath)
                    if ($actualSitePath -and $configuredSitePath -and $actualSitePath -ine $configuredSitePath) {
                        Add-Warning "IIS site '$siteName' currently points to a different physical path. The IIS installer will update it to IisSitePath."
                    }
                    if ([string]$existingSite.State -ne "Started") {
                        Add-Warning "IIS site '$siteName' is currently $($existingSite.State). The IIS installer will start it."
                    }
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
            if ($tlsEnabledForIis) {
                if (-not $config.PSObject.Properties["IisCertificateThumbprint"] -or [string]::IsNullOrWhiteSpace([string]$config.IisCertificateThumbprint)) {
                    Add-Warning "TlsEnabled is true but IisCertificateThumbprint is empty. The IIS script will warn and leave certificate binding for manual setup."
                }
                if (-not $config.PSObject.Properties["PublicHostName"] -or [string]::IsNullOrWhiteSpace([string]$config.PublicHostName)) {
                    Add-Warning "TlsEnabled is true but PublicHostName is empty. Host-scoped HTTPS/SNI bindings may need manual review."
                }
            } else {
                Add-Warning "TlsEnabled is false for IIS reverse proxy. Use TLS at IIS or a documented upstream load balancer in production."
            }
        }
        "none" {}
        "" {}
        default {
            Add-Error "Unsupported ReverseProxy: $($config.ReverseProxy). Use iis or none on Windows. Apache, HAProxy, and Traefik installers are Linux/Unix scripts in this kit."
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
