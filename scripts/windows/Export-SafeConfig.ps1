[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [string] $OutputPath = "safe-config.redacted.json"
)
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sensitivePatterns = 'password|secret|token|key|connection|string|dsn|credential|private'
function Redact-Object($obj) {
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Name -match $sensitivePatterns) { $copy[$p.Name] = "REDACTED" }
            else { $copy[$p.Name] = Redact-Object $p.Value }
        }
        return [pscustomobject]$copy
    }
    return $obj
}
Redact-Object $config | ConvertTo-Json -Depth 20 | Set-Content $OutputPath -Encoding UTF8
Write-Host "Wrote redacted config: $OutputPath"
