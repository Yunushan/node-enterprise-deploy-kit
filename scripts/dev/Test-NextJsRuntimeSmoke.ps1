param(
  [string]$NodeExe = "",
  [int]$TimeoutSeconds = 15
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

Write-Step "Next.js runtime smoke"

$resolvedNode = Resolve-NodeExe $NodeExe
if ([string]::IsNullOrWhiteSpace($resolvedNode)) {
  return
}

$testRoot = Join-Path $RepoRoot (".tmp\nextjs-runtime-smoke-" + [guid]::NewGuid().ToString("N"))
$appRoot = Join-Path $testRoot "app"
$port = New-FreeTcpPort
$process = $null

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $appRoot ".next\static") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $appRoot "node_modules") | Out-Null
  Write-Utf8NoBom -Path (Join-Path $appRoot ".next\static\app.js") -Text "console.log('static');`n"
  Write-Utf8NoBom -Path (Join-Path $appRoot "server.js") -Text @'
const http = require('http');

const host = process.env.HOSTNAME || process.env.HOST || '127.0.0.1';
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

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $resolvedNode
  $startInfo.Arguments = "server.js"
  $startInfo.WorkingDirectory = $appRoot
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Environment["NODE_ENV"] = "production"
  $startInfo.Environment["PORT"] = [string]$port
  $startInfo.Environment["APP_PORT"] = [string]$port
  $startInfo.Environment["APP_NAME"] = "ExampleNextRuntimeSmoke"
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
      throw "Runtime smoke process exited early with code $($process.ExitCode). stdout=$stdout stderr=$stderr"
    }

    try {
      $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
      break
    } catch {
      $lastError = $_.Exception.Message
      Start-Sleep -Milliseconds 250
    }
  }

  if ($null -eq $response) {
    throw "Runtime smoke health check did not succeed within $TimeoutSeconds second(s). Last error: $lastError"
  }
  if ([int]$response.StatusCode -ne 200) {
    throw "Runtime smoke health check returned HTTP $($response.StatusCode)."
  }

  $body = $response.Content | ConvertFrom-Json
  if ([string]$body.appName -ne "ExampleNextRuntimeSmoke") {
    throw "Runtime smoke appName mismatch."
  }
  if ([string]$body.envPort -ne [string]$port) {
    throw "Runtime smoke PORT mismatch. Expected $port, got $($body.envPort)."
  }
  if ([string]$body.envHostname -ne "127.0.0.1") {
    throw "Runtime smoke HOSTNAME mismatch. Expected 127.0.0.1, got $($body.envHostname)."
  }

  Write-Host "Next.js runtime smoke OK on 127.0.0.1:$port"
}
finally {
  Stop-ProcessTree $process
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
