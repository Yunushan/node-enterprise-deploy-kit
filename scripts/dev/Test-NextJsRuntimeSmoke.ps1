param(
  [string]$NodeExe = "",
  [int]$TimeoutSeconds = 45,
  [int]$ProbeTimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

function Resolve-NodeExe {
  param([string]$ConfiguredPath)

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
    if (-not (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
      throw "Configured NodeExe was not found: $ConfiguredPath"
    }
    return (Resolve-Path -LiteralPath $ConfiguredPath).Path
  }

  if (-not [string]::IsNullOrWhiteSpace($env:NODE_EXE)) {
    if (-not (Test-Path -LiteralPath $env:NODE_EXE -PathType Leaf)) {
      throw "NODE_EXE was set but the file was not found: $env:NODE_EXE"
    }
    return (Resolve-Path -LiteralPath $env:NODE_EXE).Path
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) { return $node.Source }

  Write-Warning "Node.js was not found in PATH and NODE_EXE was not set; skipping Next.js runtime smoke."
  return ""
}

function New-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  $listener.Start()
  try {
    return [int]$listener.LocalEndpoint.Port
  }
  finally {
    $listener.Stop()
  }
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Text
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process -or $Process.HasExited) { return }
  try {
    $Process.Kill($true)
  } catch {
    try { $Process.Kill() } catch {}
  }
  try { $Process.WaitForExit(5000) | Out-Null } catch {}
}

function Get-SmokeServerScript {
  return @'
const http = require('http');

const mode = process.env.NEXTJS_DEPLOYMENT_MODE || 'standalone';
const args = process.argv.slice(2);
let cliHost = '';
for (let i = 0; i < args.length; i += 1) {
  if ((args[i] === '-H' || args[i] === '--hostname') && i + 1 < args.length) {
    cliHost = args[i + 1];
  } else if (args[i].startsWith('--hostname=')) {
    cliHost = args[i].slice('--hostname='.length);
  } else if (args[i].startsWith('-H=')) {
    cliHost = args[i].slice('-H='.length);
  }
}

if (mode === 'next-start') {
  if (args[0] !== 'start') {
    console.error(`expected first Next.js CLI argument to be start, got ${args[0] || '<empty>'}`);
    process.exit(2);
  }
  if (cliHost !== (process.env.BIND_ADDRESS || '127.0.0.1')) {
    console.error(`expected Next.js CLI hostname ${process.env.BIND_ADDRESS || '127.0.0.1'}, got ${cliHost || '<empty>'}`);
    process.exit(2);
  }
}

const host = cliHost || process.env.HOSTNAME || process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || process.env.APP_PORT || 3000);
const appName = process.env.APP_NAME || 'unknown-app';

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      appName,
      port: String(port),
      host,
      mode,
      args,
      envPort: process.env.PORT || '',
      envHostname: process.env.HOSTNAME || ''
    }));
    return;
  }

  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('ok');
});

server.on('error', (error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});

server.listen(port, host, () => {
  console.log(JSON.stringify({ listening: true, host, port, appName }));
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
'@
}

function New-SmokeApp {
  param(
    [string]$AppRoot,
    [string]$Mode
  )

  New-Item -ItemType Directory -Force -Path (Join-Path $AppRoot ".next\static") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $AppRoot "node_modules") | Out-Null
  Write-Utf8NoBom -Path (Join-Path $AppRoot ".next\BUILD_ID") -Text "example-build`n"
  Write-Utf8NoBom -Path (Join-Path $AppRoot ".next\static\app.js") -Text "console.log('static');`n"

  if ($Mode -eq "next-start") {
    $nextCliPath = Join-Path $AppRoot "node_modules\next\dist\bin\next"
    Write-Utf8NoBom -Path $nextCliPath -Text (Get-SmokeServerScript)
    Write-Utf8NoBom -Path (Join-Path $AppRoot "package.json") -Text "{`"scripts`":{`"start`":`"next start`"},`"dependencies`":{`"next`":`"0.0.0-smoke`"}}`n"
    return [pscustomobject]@{
      Arguments = "node_modules/next/dist/bin/next start -H 127.0.0.1"
      AppName = "ExampleNextRuntimeSmokeNextStart"
    }
  }

  Write-Utf8NoBom -Path (Join-Path $AppRoot "server.js") -Text (Get-SmokeServerScript)
  return [pscustomobject]@{
    Arguments = "server.js"
    AppName = "ExampleNextRuntimeSmokeStandalone"
  }
}

function Invoke-SmokeCase {
  param(
    [string]$ResolvedNode,
    [string]$Mode
  )

  $testRoot = Join-Path $RepoRoot (".tmp\nextjs-runtime-smoke-$Mode-" + [guid]::NewGuid().ToString("N"))
  $appRoot = Join-Path $testRoot "app"
  $port = New-FreeTcpPort
  $process = $null

  try {
    $smokeApp = New-SmokeApp -AppRoot $appRoot -Mode $Mode

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ResolvedNode
    $startInfo.Arguments = [string]$smokeApp.Arguments
    $startInfo.WorkingDirectory = $appRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment["NODE_ENV"] = "production"
    $startInfo.Environment["PORT"] = [string]$port
    $startInfo.Environment["APP_PORT"] = [string]$port
    $startInfo.Environment["APP_NAME"] = [string]$smokeApp.AppName
    $startInfo.Environment["NEXTJS_DEPLOYMENT_MODE"] = $Mode
    $startInfo.Environment["BIND_ADDRESS"] = "127.0.0.1"
    $startInfo.Environment["HOST"] = "127.0.0.1"
    $startInfo.Environment["HOSTNAME"] = "127.0.0.1"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $response = $null
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
      if ($process.HasExited) {
        $stderr = $process.StandardError.ReadToEnd()
        $stdout = $process.StandardOutput.ReadToEnd()
        throw "Runtime smoke '$Mode' process exited early with code $($process.ExitCode). stdout=$stdout stderr=$stderr"
      }

      try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec $ProbeTimeoutSeconds
        break
      } catch {
        $lastError = $_.Exception.Message
        Start-Sleep -Milliseconds 250
      }
    }

    if ($null -eq $response) {
      throw "Runtime smoke '$Mode' health check did not succeed within $TimeoutSeconds second(s). Last error: $lastError"
    }
    if ([int]$response.StatusCode -ne 200) {
      throw "Runtime smoke '$Mode' health check returned HTTP $($response.StatusCode)."
    }

    $body = $response.Content | ConvertFrom-Json
    if ([string]$body.appName -ne [string]$smokeApp.AppName) {
      throw "Runtime smoke '$Mode' appName mismatch."
    }
    if ([string]$body.mode -ne $Mode) {
      throw "Runtime smoke '$Mode' mode mismatch. Got $($body.mode)."
    }
    if ([string]$body.envPort -ne [string]$port) {
      throw "Runtime smoke '$Mode' PORT mismatch. Expected $port, got $($body.envPort)."
    }
    if ([string]$body.envHostname -ne "127.0.0.1") {
      throw "Runtime smoke '$Mode' HOSTNAME mismatch. Expected 127.0.0.1, got $($body.envHostname)."
    }
    if ([string]$body.host -ne "127.0.0.1") {
      throw "Runtime smoke '$Mode' host mismatch. Expected 127.0.0.1, got $($body.host)."
    }
    if ($Mode -eq "next-start" -and @($body.args)[0] -ne "start") {
      throw "Runtime smoke next-start arguments did not begin with start."
    }

    Write-Host "Next.js $Mode runtime smoke OK on 127.0.0.1:$port"
  }
  finally {
    Stop-ProcessTree $process
    if (Test-Path -LiteralPath $testRoot) {
      Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Step "Next.js runtime smoke"

$resolvedNode = Resolve-NodeExe $NodeExe
if ([string]::IsNullOrWhiteSpace($resolvedNode)) {
  return
}

foreach ($mode in @("standalone", "next-start")) {
  Invoke-SmokeCase -ResolvedNode $resolvedNode -Mode $mode
}
