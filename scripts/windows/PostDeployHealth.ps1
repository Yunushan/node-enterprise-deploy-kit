function Get-PostDeployHealthConfigValue {
    param($Config, [string]$Name, $Default)

    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        return $Config.$Name
    }
    return $Default
}

function ConvertTo-PostDeployHealthBoolean {
    param($Value, [bool]$Default)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        "true" { return $true }
        "1" { return $true }
        "yes" { return $true }
        "false" { return $false }
        "0" { return $false }
        "no" { return $false }
        default { throw "RequirePostDeployHealthCheck must be true or false." }
    }
}

function ConvertTo-PostDeployHealthInteger {
    param(
        $Value,
        [string]$Name,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    $parsed = 0
    if (-not [int]::TryParse([string]$Value, [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "$Name must be an integer from $Minimum through $Maximum."
    }
    return $parsed
}

function Get-PostDeployHealthStatusCode {
    param($Result)

    if ($null -eq $Result) { return 0 }
    if ($Result -is [int]) { return [int]$Result }
    if ($Result.PSObject.Properties["StatusCode"]) { return [int]$Result.StatusCode }
    return 0
}

function Test-PostDeployHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Config,
        [scriptblock] $Probe
    )

    $required = ConvertTo-PostDeployHealthBoolean `
        -Value (Get-PostDeployHealthConfigValue $Config "RequirePostDeployHealthCheck" $true) `
        -Default $true
    if (-not $required) {
        Write-Warning "Post-deploy HTTP health validation is disabled by configuration."
        return
    }

    $healthUrl = [string](Get-PostDeployHealthConfigValue $Config "HealthUrl" "")
    $healthUri = $null
    if ([string]::IsNullOrWhiteSpace($healthUrl) -or
        -not [Uri]::TryCreate($healthUrl, [UriKind]::Absolute, [ref]$healthUri) -or
        $healthUri.Scheme -notin @("http", "https")) {
        throw "A valid HTTP or HTTPS HealthUrl is required for post-deploy validation."
    }
    if (-not $healthUri.IsLoopback) {
        throw "HealthUrl must target a loopback host for privileged post-deploy validation."
    }
    if (-not [string]::IsNullOrWhiteSpace($healthUri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($healthUri.Query) -or
        -not [string]::IsNullOrWhiteSpace($healthUri.Fragment)) {
        throw "HealthUrl must not contain credentials, query text, or a fragment."
    }

    $attempts = ConvertTo-PostDeployHealthInteger `
        -Value (Get-PostDeployHealthConfigValue $Config "PostDeployHealthAttempts" 12) `
        -Name "PostDeployHealthAttempts" -Default 12 -Minimum 1 -Maximum 120
    $delaySeconds = ConvertTo-PostDeployHealthInteger `
        -Value (Get-PostDeployHealthConfigValue $Config "PostDeployHealthDelaySeconds" 5) `
        -Name "PostDeployHealthDelaySeconds" -Default 5 -Minimum 0 -Maximum 300
    $timeoutSeconds = ConvertTo-PostDeployHealthInteger `
        -Value (Get-PostDeployHealthConfigValue $Config "HealthCheckTimeoutSeconds" 10) `
        -Name "HealthCheckTimeoutSeconds" -Default 10 -Minimum 1 -Maximum 300

    if (-not $Probe) {
        $Probe = {
            param([Uri]$Uri, [int]$TimeoutSeconds)
            Invoke-WebRequest `
                -Uri $Uri `
                -UseBasicParsing `
                -TimeoutSec $TimeoutSeconds `
                -MaximumRedirection 0
        }
    }

    $lastResult = "no response"
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $response = & $Probe $healthUri $timeoutSeconds
            $statusCode = Get-PostDeployHealthStatusCode $response
            if ($statusCode -ge 200 -and $statusCode -le 299) {
                Write-Host "Post-deploy health check passed with HTTP $statusCode on attempt $attempt/$attempts." -ForegroundColor Green
                return
            }
            $lastResult = if ($statusCode -gt 0) { "HTTP $statusCode" } else { "a response without an HTTP status" }
        }
        catch {
            $statusCode = 0
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $lastResult = if ($statusCode -gt 0) { "HTTP $statusCode" } else { $_.Exception.GetType().Name }
        }

        if ($attempt -lt $attempts -and $delaySeconds -gt 0) {
            Start-Sleep -Seconds $delaySeconds
        }
    }

    throw "Post-deploy health check failed after $attempts attempt(s); last result: $lastResult."
}
