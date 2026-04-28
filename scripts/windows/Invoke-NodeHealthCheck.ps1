[CmdletBinding()]
param([Parameter(Mandatory=$true)] [string] $ConfigPath)
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $config.LogDirectory | Out-Null
$logFile = Join-Path $config.LogDirectory "healthcheck.log"
function Write-HealthLog([string]$Message) { "$(Get-Date -Format o) $Message" | Out-File $logFile -Append -Encoding UTF8 }
try {
    $svc = Get-Service -Name $config.AppName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Write-HealthLog "SERVICE_NOT_RUNNING status=$($svc.Status); starting service"
        Start-Service -Name $config.AppName
        Start-Sleep -Seconds 5
    }
    $response = Invoke-WebRequest -Uri $config.HealthUrl -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
        Write-HealthLog "OK status=$($response.StatusCode) url=$($config.HealthUrl)"
        exit 0
    }
    Write-HealthLog "BAD_STATUS status=$($response.StatusCode); restarting service"
    Restart-Service -Name $config.AppName -Force
    exit 2
} catch {
    Write-HealthLog "FAILED message='$($_.Exception.Message)'; restarting service"
    try { Restart-Service -Name $config.AppName -Force -ErrorAction Stop } catch { Write-HealthLog "RESTART_FAILED message='$($_.Exception.Message)'" }
    exit 1
}
