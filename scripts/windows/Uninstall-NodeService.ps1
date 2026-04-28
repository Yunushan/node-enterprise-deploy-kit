[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)] [string] $ConfigPath,
    [switch] $RemoveHealthCheckTask
)
function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run as Administrator." }
}
Assert-Admin
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$serviceExe = Join-Path $config.ServiceDirectory "$($config.AppName).exe"
if (Test-Path $serviceExe) {
    if ($PSCmdlet.ShouldProcess($config.AppName, "Stop and uninstall service")) {
        try { & $serviceExe stop } catch {}
        & $serviceExe uninstall
    }
} else { Write-Warning "Service wrapper not found: $serviceExe" }
if ($RemoveHealthCheckTask) {
    $taskName = "$($config.AppName)-HealthCheck"
    if ($PSCmdlet.ShouldProcess($taskName, "Remove scheduled task")) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}
