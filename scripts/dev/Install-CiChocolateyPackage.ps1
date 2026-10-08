[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$Name,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9][a-zA-Z0-9_.-]*$')][string]$Version,
    [ValidateRange(1,5)][int]$Attempts = 3,
    [ValidateRange(0,60)][int]$RetryDelaySeconds = 10
)
$ErrorActionPreference = 'Stop'
# Capture native exit codes ourselves so an opt-in PowerShell 7 native-error
# preference cannot bypass the bounded retry loop. This is script-local.
$PSNativeCommandUseErrorActionPreference = $false
for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    & choco install $Name "--version=$Version" --yes --no-progress
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -eq 0) { return }
    if ($attempt -eq $Attempts) {
        throw "Chocolatey install of $Name $Version failed after $Attempts attempt(s), exit code $installExitCode."
    }
    Write-Warning "Chocolatey install of $Name failed with exit code $installExitCode; retrying ($attempt/$Attempts)."
    Start-Sleep -Seconds ([Math]::Min(60, $RetryDelaySeconds * $attempt))
}
