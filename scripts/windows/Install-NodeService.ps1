<#
.SYNOPSIS
  Install a Node.js / Next.js app as a Windows Service using WinSW.
.PARAMETER ConfigPath
  Path to config/windows/app.config.json.
.PARAMETER WinSWPath
  Optional path to a WinSW executable. If omitted, the script looks under tools/winsw/winsw-x64.exe.
.NOTES
  Run as Administrator.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $WinSWPath = "tools\winsw\winsw-x64.exe"
)

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}
function Read-Config($Path) {
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    return Get-Content $Path -Raw | ConvertFrom-Json
}
function Replace-Token([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace("{{$k}}", [string]$Values[$k]) }
    return $Text
}

Assert-Admin
$config = Read-Config $ConfigPath
if ($config.ServiceManager -ne "winsw") {
    throw "This installer supports ServiceManager='winsw'. For NSSM/PM2, use fallback scripts."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$winswCandidate = Join-Path $repoRoot $WinSWPath
if (-not (Test-Path $winswCandidate)) {
    throw "WinSW executable not found at '$winswCandidate'. Download WinSW separately and place it there, or pass -WinSWPath. No binaries are bundled in this repository."
}

New-Item -ItemType Directory -Force -Path $config.ServiceDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null

$serviceExe = Join-Path $config.ServiceDirectory "$($config.AppName).exe"
$serviceXml = Join-Path $config.ServiceDirectory "$($config.AppName).xml"
Copy-Item $winswCandidate $serviceExe -Force

$envBlock = ""
if ($config.Environment) {
    $config.Environment.PSObject.Properties | ForEach-Object {
        $name = $_.Name
        $value = [string]$_.Value
        $envBlock += "  <env name=`"$name`" value=`"$value`"/>`r`n"
    }
}

$templatePath = Join-Path $repoRoot "templates\windows\winsw-service.xml.tpl"
$template = Get-Content $templatePath -Raw
$values = @{
    "APP_NAME" = $config.AppName
    "DISPLAY_NAME" = $config.DisplayName
    "DESCRIPTION" = $config.Description
    "NODE_EXE" = $config.NodeExe
    "START_COMMAND" = $config.StartCommand
    "NODE_ARGUMENTS" = $config.NodeArguments
    "APP_DIRECTORY" = $config.AppDirectory
    "LOG_DIRECTORY" = $config.LogDirectory
    "ENVIRONMENT_BLOCK" = $envBlock.TrimEnd()
}
$xml = Replace-Token $template $values
$xml | Set-Content -Path $serviceXml -Encoding UTF8

if ($PSCmdlet.ShouldProcess($config.AppName, "Install Windows Service")) {
    & $serviceExe install
    sc.exe failure $config.AppName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
    sc.exe failureflag $config.AppName 1 | Out-Null
    & $serviceExe start
}

Write-Host "Installed service: $($config.AppName)" -ForegroundColor Green
Write-Host "Service XML: $serviceXml"
Write-Host "Logs: $($config.LogDirectory)"
