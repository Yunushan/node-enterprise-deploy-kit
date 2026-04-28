<#
.SYNOPSIS
  Generate an IIS web.config reverse proxy to localhost Node.js port.
.NOTES
  Requires IIS URL Rewrite and ARR if using IIS as a reverse proxy.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run this script as Administrator." }
}
function Replace-Token([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace("{{$k}}", [string]$Values[$k]) }
    return $Text
}

Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$templatePath = Join-Path $repoRoot "templates\windows\iis-web.config.tpl"
New-Item -ItemType Directory -Force -Path $config.IisSitePath | Out-Null
$template = Get-Content $templatePath -Raw
$webConfig = Replace-Token $template @{ "APP_PORT" = $config.Port }
$out = Join-Path $config.IisSitePath "web.config"
if ($PSCmdlet.ShouldProcess($out, "Write IIS reverse proxy web.config")) { $webConfig | Set-Content -Path $out -Encoding UTF8 }
Write-Host "IIS web.config created: $out" -ForegroundColor Green
Write-Host "Verify IIS URL Rewrite and ARR are installed/enabled."
