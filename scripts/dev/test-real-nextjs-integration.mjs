#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const nextVersion = process.env.NEXTJS_INTEGRATION_NEXT_VERSION || 'latest';
const keepTestRoot = process.env.KEEP_REAL_NEXTJS_INTEGRATION === 'true';
const runWindowsServiceIntegration = process.env.RUN_WINSW_SERVICE_INTEGRATION === 'true';
const testRootBase = process.env.NEXTJS_INTEGRATION_TEMP_ROOT
  || (process.platform === 'win32' ? path.join(repoRoot, '.tmp') : os.tmpdir());
const testRoot = path.join(testRootBase, `real-nextjs-integration-${process.platform}-${Date.now()}`);

function usage() {
  console.log('Usage: node scripts/dev/test-real-nextjs-integration.mjs [--help]');
  console.log('Builds a temporary real Next.js project, packages standalone and next-start artifacts, and verifies both serve HTTP.');
}

function run(command, args, options = {}) {
  const { cwd = repoRoot, env = process.env, allowFailure = false } = options;
  const isWindowsCommandShim = process.platform === 'win32' && /\.(cmd|bat)$/i.test(command);
  const executable = isWindowsCommandShim ? (process.env.ComSpec || 'cmd.exe') : command;
  const executableArgs = isWindowsCommandShim
    ? ['/d', '/s', '/c', [command, ...args].join(' ')]
    : args;

  return new Promise((resolve, reject) => {
    const child = spawn(executable, executableArgs, {
      cwd,
      env,
      stdio: 'inherit',
      windowsHide: true
    });
    child.on('error', reject);
    child.on('exit', (code, signal) => {
      const result = { code: code ?? -1, signal };
      if (result.code === 0 || allowFailure) {
        resolve(result);
      } else {
        reject(new Error(`${command} ${args.join(' ')} failed with exit code ${result.code}${signal ? ` (${signal})` : ''}.`));
      }
    });
  });
}

function start(command, args, options = {}) {
  const { cwd = repoRoot, env = process.env } = options;
  const child = spawn(command, args, { cwd, env, stdio: 'inherit', windowsHide: true });
  return child;
}

async function assertExists(filePath, label) {
  try {
    await fs.access(filePath);
  } catch {
    throw new Error(`${label} was not created: ${filePath}`);
  }
}

async function getFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function waitForPage(url, expectedText, child) {
  const deadline = Date.now() + 45000;
  let lastError = 'server did not respond';

  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Runtime process exited before serving ${url} with code ${child.exitCode}.`);
    }

    try {
      const response = await new Promise((resolve, reject) => {
        const request = http.get(url, (result) => {
          let body = '';
          result.setEncoding('utf8');
          result.on('data', (chunk) => { body += chunk; });
          result.on('end', () => resolve({ statusCode: result.statusCode, body }));
        });
        request.setTimeout(3000, () => request.destroy(new Error('request timed out')));
        request.on('error', reject);
      });

      if (response.statusCode === 200 && response.body.includes(expectedText)) {
        return;
      }
      lastError = `received HTTP ${response.statusCode}`;
    } catch (error) {
      lastError = error.message;
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  throw new Error(`Timed out waiting for ${url}: ${lastError}`);
}

async function stopProcess(child) {
  if (!child || child.exitCode !== null || !child.pid) {
    return;
  }

  if (process.platform === 'win32') {
    await run('taskkill', ['/pid', String(child.pid), '/t', '/f'], { allowFailure: true });
    return;
  }

  child.kill('SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, 1000));
  if (child.exitCode === null) {
    child.kill('SIGKILL');
  }
}

async function writeFixture(projectPath, standalone) {
  await fs.mkdir(path.join(projectPath, 'app'), { recursive: true });
  await fs.mkdir(path.join(projectPath, 'public'), { recursive: true });
  await fs.writeFile(path.join(projectPath, 'package.json'), JSON.stringify({
    name: 'node-enterprise-deploy-kit-real-nextjs-integration',
    private: true,
    scripts: { build: 'next build' }
  }, null, 2));
  if (standalone) {
    await fs.writeFile(path.join(projectPath, 'next.config.mjs'), "export default { output: 'standalone' };\n");
  }
  await fs.writeFile(path.join(projectPath, 'app', 'layout.js'), "export default function RootLayout({ children }) { return <html><body>{children}</body></html>; }\n");
  await fs.writeFile(path.join(projectPath, 'app', 'page.js'), "export default function Page() { return <main>node-enterprise-deploy-kit real-nextjs-integration</main>; }\n");
  await fs.writeFile(path.join(projectPath, 'public', 'integration.txt'), 'node-enterprise-deploy-kit\n');
}

async function buildProject(projectPath, standalone) {
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const env = { ...process.env, NEXT_TELEMETRY_DISABLED: '1', npm_config_fund: 'false', npm_config_audit: 'false' };

  await run(npm, ['install', '--save-exact', '--no-audit', '--no-fund', `next@${nextVersion}`, 'react@latest', 'react-dom@latest'], { cwd: projectPath, env });
  await run(npm, ['run', 'build'], { cwd: projectPath, env });

  await assertExists(path.join(projectPath, '.next', 'BUILD_ID'), 'Next.js build ID');
  await assertExists(path.join(projectPath, '.next', 'static'), 'Next.js static assets');
  await assertExists(path.join(projectPath, 'node_modules', 'next', 'package.json'), 'Next.js package metadata');

  if (standalone) {
    await assertExists(path.join(projectPath, '.next', 'standalone', 'server.js'), 'Next.js standalone server');
    await fs.cp(path.join(projectPath, '.next', 'static'), path.join(projectPath, '.next', 'standalone', '.next', 'static'), { recursive: true });
    await fs.cp(path.join(projectPath, 'public'), path.join(projectPath, '.next', 'standalone', 'public'), { recursive: true });
  }
}

async function packageProject(projectPath, mode, outputPath) {
  if (process.platform === 'win32') {
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'New-NextJsStandalonePackage.ps1'),
      '-ProjectPath', projectPath,
      '-Mode', mode,
      '-OutputPath', outputPath
    ]);
    return;
  }

  await run('bash', [
    path.join(repoRoot, 'scripts', 'linux', 'package-nextjs-standalone.sh'),
    '--project-path', projectPath,
    '--mode', mode,
    '--output-path', outputPath
  ]);
}

async function extractPackage(packagePath, destination) {
  await fs.mkdir(destination, { recursive: true });
  if (process.platform === 'win32') {
    await run('pwsh', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${packagePath.replace(/'/g, "''")}' -DestinationPath '${destination.replace(/'/g, "''")}' -Force`]);
  } else {
    await run('tar', ['-xzf', packagePath, '-C', destination]);
  }
}

async function verifyUnixManagedRunner(runtimePath, mode, port) {
  const runnerTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'launchd-runner.sh.tpl'), 'utf8');
  const runnerPath = path.join(runtimePath, '.node-enterprise-deploy-runner.sh');
  const envPath = path.join(runtimePath, '.node-enterprise-deploy-runtime.env');
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const runner = runnerTemplate
    .replaceAll('{{APP_DIR}}', runtimePath)
    .replaceAll('{{ENV_FILE}}', envPath)
    .replaceAll('{{NODE_BIN}}', process.execPath)
    .replaceAll('{{START_SCRIPT}}', startScript)
    .replaceAll('{{NODE_ARGUMENTS}}', nodeArguments);

  await fs.writeFile(envPath, [
    'NODE_ENV=production',
    `PORT=${port}`,
    `APP_PORT=${port}`,
    'BIND_ADDRESS=127.0.0.1',
    'HOST=127.0.0.1',
    'HOSTNAME=127.0.0.1',
    'NEXT_TELEMETRY_DISABLED=1'
  ].join('\n') + '\n');
  await fs.writeFile(runnerPath, runner, { mode: 0o755 });
  const child = start('bash', [runnerPath], { cwd: runtimePath, env: process.env });

  try {
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', child);
  } finally {
    await stopProcess(child);
  }
}

async function verifyWindowsWinSwService(runtimePath, mode, port) {
  const serviceName = `NodeDeployKitRealNext${Date.now()}${mode === 'standalone' ? 'Standalone' : 'NextStart'}`;
  const serviceRoot = path.join(testRoot, `winsw-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.config.json');
  const serviceDirectory = path.join(serviceRoot, 'service');
  const logDirectory = path.join(serviceRoot, 'logs');
  const backupDirectory = path.join(serviceRoot, 'backups');
  const winSwPath = path.join(serviceRoot, 'winsw', 'WinSW-x64.exe');
  const startCommand = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const config = {
    AppName: serviceName,
    DisplayName: serviceName,
    Description: 'Temporary real Next.js WinSW CI integration service',
    DeploymentMode: 'service_only',
    AppFramework: 'nextjs',
    NextjsDeploymentMode: mode,
    NextjsRequireStaticAssets: true,
    NextjsMinimumNodeVersion: '20.9.0',
    ServiceManager: 'winsw',
    ReverseProxy: 'none',
    ServiceAccount: 'LocalSystem',
    AppDirectory: runtimePath,
    ServiceDirectory: serviceDirectory,
    LogDirectory: logDirectory,
    BackupDirectory: backupDirectory,
    NodeExe: process.execPath,
    StartCommand: startCommand,
    NodeArguments: nodeArguments,
    Port: port,
    BindAddress: '127.0.0.1',
    HealthUrl: `http://127.0.0.1:${port}/`,
    Environment: {
      NODE_ENV: 'production',
      PORT: String(port),
      APP_PORT: String(port),
      HOST: '127.0.0.1',
      HOSTNAME: '127.0.0.1',
      NEXT_TELEMETRY_DISABLED: '1'
    }
  };

  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, JSON.stringify(config, null, 2));

  try {
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Install-NodeService.ps1'),
      '-ConfigPath', configPath,
      '-WinSWPath', winSwPath,
      '-WinSWDownloadUrl', 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe',
      '-WinSWDownloadSha256', '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA'
    ]);
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
  } finally {
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Uninstall-NodeService.ps1'),
      '-ConfigPath', configPath
    ], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyRuntime(runtimePath, mode) {
  const port = await getFreePort();
  if (process.platform !== 'win32') {
    await verifyUnixManagedRunner(runtimePath, mode, port);
    return;
  }
  if (runWindowsServiceIntegration) {
    await verifyWindowsWinSwService(runtimePath, mode, port);
    return;
  }

  const args = mode === 'standalone'
    ? ['server.js']
    : [path.join('node_modules', 'next', 'dist', 'bin', 'next'), 'start', '-H', '127.0.0.1', '-p', String(port)];
  const env = { ...process.env, NODE_ENV: 'production', PORT: String(port), HOST: '127.0.0.1', HOSTNAME: '127.0.0.1', NEXT_TELEMETRY_DISABLED: '1' };
  const child = start(process.execPath, args, { cwd: runtimePath, env });

  try {
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', child);
  } finally {
    await stopProcess(child);
  }
}

async function verifyMode(projectPath, mode) {
  const extension = process.platform === 'win32' ? 'zip' : 'tar.gz';
  const packagePath = path.join(testRoot, `real-next-${mode}.${extension}`);
  const extractedPath = path.join(testRoot, `extracted-${mode}`);

  await packageProject(projectPath, mode, packagePath);
  await extractPackage(packagePath, extractedPath);
  await assertExists(path.join(extractedPath, 'node_modules', 'next', 'package.json'), `${mode} packaged Next.js metadata`);
  await verifyRuntime(extractedPath, mode);
  console.log(`Real Next.js ${mode} package/runtime integration OK.`);
}

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  usage();
  process.exit(0);
}

await fs.mkdir(testRoot, { recursive: true });
const standaloneProjectPath = path.join(testRoot, 'standalone-project');
const nextStartProjectPath = path.join(testRoot, 'next-start-project');

try {
  console.log(`==> Real Next.js integration (${process.platform}, Next.js ${nextVersion})`);
  await writeFixture(standaloneProjectPath, true);
  await buildProject(standaloneProjectPath, true);
  const installedVersion = JSON.parse(await fs.readFile(path.join(standaloneProjectPath, 'node_modules', 'next', 'package.json'), 'utf8')).version;
  console.log(`Built real Next.js ${installedVersion}.`);
  await verifyMode(standaloneProjectPath, 'standalone');

  await writeFixture(nextStartProjectPath, false);
  await buildProject(nextStartProjectPath, false);
  await verifyMode(nextStartProjectPath, 'next-start');
  console.log('Real Next.js integration checks OK.');
} finally {
  if (!keepTestRoot) {
    await fs.rm(testRoot, { recursive: true, force: true });
  } else {
    console.log(`Kept integration test root: ${testRoot}`);
  }
}
