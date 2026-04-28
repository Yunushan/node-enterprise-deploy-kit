<#
.SYNOPSIS
  Collect safe diagnostics for a Node app without exposing environment secret values.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $OutputDirectory = ""
)
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $config.LogDirectory "diagnostics" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $OutputDirectory "diagnostics-$stamp.txt"
function Add-Section([string]$Title) { "`r`n===== $Title =====" | Out-File $out -Append -Encoding UTF8 }
"Diagnostics generated $(Get-Date -Format o)" | Out-File $out -Encoding UTF8
"AppName=$($config.AppName)" | Out-File $out -Append -Encoding UTF8
"AppDirectory=$($config.AppDirectory)" | Out-File $out -Append -Encoding UTF8
"Port=$($config.Port)" | Out-File $out -Append -Encoding UTF8
"HealthUrl=$($config.HealthUrl)" | Out-File $out -Append -Encoding UTF8
Add-Section "Service"
Get-Service -Name $config.AppName -ErrorAction SilentlyContinue | Format-List * | Out-File $out -Append -Encoding UTF8
Add-Section "Node Processes"
Get-Process node -ErrorAction SilentlyContinue | Select-Object Id, CPU, PM, WS, StartTime, Path | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Port Check"
Get-NetTCPConnection -LocalPort $config.Port -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
Add-Section "HTTP Health"
try { Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec 10 | Select-Object StatusCode, StatusDescription | Format-List | Out-File $out -Append -Encoding UTF8 } catch { "HTTP probe failed: $($_.Exception.Message)" | Out-File $out -Append -Encoding UTF8 }
Add-Section "Recent Application Events"
Get-WinEvent -LogName Application -MaxEvents 80 -ErrorAction SilentlyContinue |
Where-Object { $_.Message -like "*node*" -or $_.Message -like "*$($config.AppName)*" -or $_.Message -like "*iis*" -or $_.Message -like "*w3wp*" } |
Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Recent Reboot Events"
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005,6006,6008,1074} -MaxEvents 30 -ErrorAction SilentlyContinue |
Select-Object TimeCreated, Id, ProviderName, Message | Format-List | Out-File $out -Append -Encoding UTF8
Add-Section "Logs Tail"
Get-ChildItem $config.LogDirectory -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName, Length, LastWriteTime | Format-Table -AutoSize | Out-File $out -Append -Encoding UTF8
Write-Host "Diagnostics written to: $out" -ForegroundColor Green
