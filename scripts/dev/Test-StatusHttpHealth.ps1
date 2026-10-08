[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$tokens = $null
$parseErrors = $null
$source = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'status.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Status source failed to parse.' }
foreach ($name in @('Test-HealthyHttpStatusCode', 'Invoke-StatusHealthRequest')) {
    $definitions = @($source.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definitions.Count -ne 1) { throw "Expected exactly one $name function in status.ps1." }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
foreach ($code in @(199, 200, 204, 299, 300, 301, 302, 307, 399, 400, 503)) {
    if ((Test-HealthyHttpStatusCode $code) -ne ($code -ge 200 -and $code -lt 300)) { throw "Incorrect health classification for HTTP $code." }
}
$node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $repository '.tmp'))
$fixture = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('status-http-health-' + [Guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($temporaryParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
New-Item -ItemType Directory -Path $fixture | Out-Null
$server = Join-Path $fixture 'server.cjs'
$readyPath = Join-Path $fixture 'ready.json'
$process = $null
try {
    [IO.File]::WriteAllText($server, @'
const http = require('node:http');
const fs = require('node:fs');
const counters = { healthy: 0, redirect: 0, unhealthy: 0 };
const server = http.createServer((request, response) => {
  if (request.url === '/healthy') { counters.healthy++; response.writeHead(200); response.end('healthy'); }
  else if (request.url === '/redirect') { counters.redirect++; response.writeHead(302, { Location: '/healthy' }); response.end('redirect'); }
  else if (request.url === '/unhealthy') { counters.unhealthy++; response.writeHead(503); response.end('unavailable'); }
  else if (request.url === '/stats') { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(counters)); }
  else { response.writeHead(404); response.end(); }
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], JSON.stringify({ port: server.address().port, pid: process.pid })));
'@, [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $node.Source
    $start.WorkingDirectory = $fixture
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Fixture paths cannot contain quotes on Windows; ArgumentList is unavailable in Windows PowerShell 5.1.
    $start.Arguments = '"' + $server + '" "' + $readyPath + '"'
    $process = [Diagnostics.Process]::Start($start)
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($process.HasExited) { throw ('HTTP fixture exited: ' + $process.StandardError.ReadToEnd()) }
        if ((Get-Date) -ge $deadline) { throw 'HTTP fixture startup timed out.' }
        Start-Sleep -Milliseconds 100
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    if ([int]$ready.pid -ne $process.Id -or [int]$ready.port -le 0) { throw 'HTTP fixture identity mismatch.' }
    $origin = 'http://127.0.0.1:' + $ready.port
    $healthy = Invoke-StatusHealthRequest -Uri ($origin + '/healthy') -TimeoutSeconds 5
    if (-not (Test-HealthyHttpStatusCode ([int]$healthy.StatusCode))) { throw 'Actual HTTP 200 was rejected.' }
    $redirectHealthy = $false
    try {
        $redirect = Invoke-StatusHealthRequest -Uri ($origin + '/redirect') -TimeoutSeconds 5
        $redirectHealthy = Test-HealthyHttpStatusCode ([int]$redirect.StatusCode)
    } catch { $redirectHealthy = $false }
    if ($redirectHealthy) { throw 'Actual HTTP 302 redirect was classified as healthy.' }
    $unhealthyAccepted = $false
    try {
        $unhealthy = Invoke-StatusHealthRequest -Uri ($origin + '/unhealthy') -TimeoutSeconds 5
        $unhealthyAccepted = Test-HealthyHttpStatusCode ([int]$unhealthy.StatusCode)
    } catch { $unhealthyAccepted = $false }
    if ($unhealthyAccepted) { throw 'Actual HTTP 503 was classified as healthy.' }
    $stats = Invoke-RestMethod -Uri ($origin + '/stats') -TimeoutSec 5 -ErrorAction Stop
    if ($stats.healthy -ne 1 -or $stats.redirect -ne 1 -or $stats.unhealthy -ne 1) { throw 'The health probe followed the redirect or failed to reach the negative control endpoints.' }
    Write-Host 'Actual loopback HTTP health tests passed: 200 accepted, 302 not followed, 503 rejected.'
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($temporaryParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the fixture parent.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
