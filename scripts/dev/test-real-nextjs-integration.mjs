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
const runWindowsNssmServiceIntegration = process.env.RUN_NSSM_SERVICE_INTEGRATION === 'true';
const runWindowsIisIntegration = process.env.RUN_WINDOWS_IIS_INTEGRATION === 'true';
const runLaunchdServiceIntegration = process.env.RUN_LAUNCHD_SERVICE_INTEGRATION === 'true';
const runLinuxSystemVServiceIntegration = process.env.RUN_SYSTEMV_SERVICE_INTEGRATION === 'true';
const runLinuxOpenRcServiceIntegration = process.env.RUN_OPENRC_SERVICE_INTEGRATION === 'true';
const runLinuxSystemdServiceIntegration = process.env.RUN_SYSTEMD_SERVICE_INTEGRATION === 'true';
const runApacheProxyIntegration = process.env.RUN_APACHE_PROXY_INTEGRATION === 'true';
const runNginxProxyIntegration = process.env.RUN_NGINX_PROXY_INTEGRATION === 'true';
const runHaProxyIntegration = process.env.RUN_HAPROXY_INTEGRATION === 'true';
const runTraefikProxyIntegration = process.env.RUN_TRAEFIK_PROXY_INTEGRATION === 'true';
const testRootBase = process.env.NEXTJS_INTEGRATION_TEMP_ROOT
  || (process.platform === 'linux' && runLinuxSystemdServiceIntegration
    ? '/srv/node-enterprise-deploy-kit-ci'
    : null)
  || (process.platform === 'win32' ? path.join(repoRoot, '.tmp') : os.tmpdir());
const testRoot = path.join(testRootBase, `real-nextjs-integration-${process.platform}-${Date.now()}`);

function usage() {
  console.log('Usage: node scripts/dev/test-real-nextjs-integration.mjs [--help]');
  console.log('Builds a temporary real Next.js project, packages standalone and next-start artifacts, and verifies both serve HTTP.');
  console.log('Set one native service integration flag and optionally one matching reverse-proxy flag to verify a real manager-plus-proxy deployment path.');
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

async function waitForPage(url, expectedText, child, headers = {}) {
  const deadline = Date.now() + 45000;
  let lastError = 'server did not respond';

  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Runtime process exited before serving ${url} with code ${child.exitCode}.`);
    }

    try {
      const response = await new Promise((resolve, reject) => {
        const request = http.get(url, { headers }, (result) => {
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
      lastError = `received HTTP ${response.statusCode}: ${response.body.slice(0, 500)}`;
    } catch (error) {
      lastError = error.message;
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  throw new Error(`Timed out waiting for ${url}: ${lastError}`);
}

async function waitForForwardedProxyHeaders(proxyPort, child, headers = {}, forwardedPort = String(proxyPort)) {
  const expectedHeaders = `"forwardedProto":"http","forwardedPort":"${forwardedPort}"`;
  await waitForPage(
    `http://127.0.0.1:${proxyPort}/api/proxy-evidence`,
    expectedHeaders,
    child,
    headers
  );
}

async function waitForForwardedRuntimeHeaders(port, child) {
  await waitForPage(
    `http://127.0.0.1:${port}/api/proxy-evidence`,
    '"forwardedProto":"https","forwardedPort":"443"',
    child,
    {
      'X-Forwarded-Proto': 'https',
      'X-Forwarded-Port': '443'
    }
  );
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
  await fs.mkdir(path.join(projectPath, 'app', 'api', 'proxy-evidence'), { recursive: true });
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
  await fs.writeFile(path.join(projectPath, 'app', 'api', 'proxy-evidence', 'route.js'), "export function GET(request) { return Response.json({ forwardedProto: request.headers.get('x-forwarded-proto') || '', forwardedPort: request.headers.get('x-forwarded-port') || '' }); }\n");
  await fs.writeFile(path.join(projectPath, 'public', 'integration.txt'), 'node-enterprise-deploy-kit\n');
}

async function buildProject(projectPath, standalone) {
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const env = {
    ...process.env,
    NEXT_TELEMETRY_DISABLED: '1',
    npm_config_fund: 'false',
    npm_config_audit: 'false',
    npm_config_fetch_retries: '1',
    npm_config_fetch_retry_mintimeout: '1000',
    npm_config_fetch_retry_maxtimeout: '5000',
    npm_config_fetch_timeout: '30000'
  };

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

async function verifyNpmRegistryAccess() {
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const env = {
    ...process.env,
    npm_config_fetch_retries: '0',
    npm_config_fetch_timeout: '20000'
  };
  try {
    await run(npm, ['ping', '--fetch-retries=0', '--fetch-timeout=20000'], { env });
  } catch {
    throw new Error('Cannot reach the configured npm registry with a trusted TLS certificate. Check the host CA trust chain, HTTPS inspection policy, or npm registry configuration before running real Next.js integration.');
  }
}

function expectedBuildPlatform() {
  switch (process.platform) {
    case 'win32': return 'windows';
    case 'darwin': return 'macos';
    case 'linux': return 'linux';
    case 'freebsd': return 'freebsd';
    case 'openbsd': return 'openbsd';
    case 'netbsd': return 'netbsd';
    default: return 'unknown';
  }
}

function expectedBuildArchitecture() {
  switch (process.arch) {
    case 'x64': return 'x64';
    case 'arm64': return 'arm64';
    case 'ia32': return 'x86';
    default: return 'unknown';
  }
}

function expectedBuildLibc() {
  if (process.platform !== 'linux') {
    return 'not-applicable';
  }
  const report = process.report?.getReport?.();
  return report?.header?.glibcVersionRuntime ? 'glibc' : 'musl';
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\\"'\\\"'")}'`;
}

async function verifyPackageProvenance(extractedPath, mode, expectedNextVersion) {
  const markerPath = path.join(extractedPath, '.node-enterprise-package.json');
  await assertExists(markerPath, `${mode} package provenance marker`);
  const provenance = JSON.parse(await fs.readFile(markerPath, 'utf8'));
  const buildId = (await fs.readFile(path.join(extractedPath, '.next', 'BUILD_ID'), 'utf8')).trim();
  const expected = {
    schema: 'node-enterprise-deploy-kit/nextjs-package-provenance/v2',
    appFramework: 'nextjs',
    nextjsMode: mode,
    buildPlatform: expectedBuildPlatform(),
    buildArchitecture: expectedBuildArchitecture(),
    buildLibc: expectedBuildLibc(),
    nodeModuleAbi: process.versions.modules,
    nextVersion: expectedNextVersion,
    nextBuildId: buildId
  };
  const expectedKeys = Object.keys(expected).sort();
  const actualKeys = Object.keys(provenance).sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    throw new Error(`${mode} package provenance must contain only safe documented fields.`);
  }
  for (const [key, value] of Object.entries(expected)) {
    if (provenance[key] !== value) {
      throw new Error(`${mode} package provenance ${key} mismatch: expected '${value}', got '${provenance[key]}'.`);
    }
  }
  return provenance;
}

async function runAsRoot(command, args) {
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    await run(command, args);
    return;
  }
  await run('sudo', ['--non-interactive', command, ...args]);
}

async function getUnixPrimaryGroup() {
  const child = spawn('id', ['-gn'], { cwd: repoRoot, env: process.env, windowsHide: true });
  let output = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { output += chunk; });
  child.stderr.pipe(process.stderr);
  return new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', (code) => {
      const group = output.trim();
      if (code !== 0 || !group) {
        reject(new Error('Could not determine the invoking Unix user primary group for launchd integration.'));
        return;
      }
      resolve(group);
    });
  });
}

async function restoreTestDirectoryOwnership(directoryPath) {
  if (process.platform === 'win32' || typeof process.getuid !== 'function' || process.getuid() === 0) {
    return;
  }
  const uid = process.getuid();
  const gid = typeof process.getgid === 'function' ? process.getgid() : uid;
  // The Unix importer correctly requires root; this disposable CI app must then be runnable by the invoking test user.
  await runAsRoot('chown', ['-R', `${uid}:${gid}`, directoryPath]);
}

async function importPackage(packagePath, mode) {
  const importedPath = path.join(testRoot, `imported-${mode}`);
  const backupPath = path.join(testRoot, `imported-${mode}-backups`);
  await fs.rm(importedPath, { recursive: true, force: true });

  if (process.platform === 'win32') {
    const configPath = path.join(testRoot, `import-${mode}.config.json`);
    const expectedFiles = mode === 'standalone'
      ? ['server.js', '.next/BUILD_ID', '.next/static', 'node_modules/next/package.json']
      : ['package.json', '.next/BUILD_ID', '.next', 'node_modules/next/package.json', 'node_modules/next/dist/bin/next'];
    await fs.writeFile(configPath, JSON.stringify({
      AppName: `NodeDeployKitRealNextImport${Date.now()}${mode}`,
      AppFramework: 'nextjs',
      NextjsDeploymentMode: mode,
      NextjsRequirePackageProvenance: true,
      AppDirectory: importedPath,
      BackupDirectory: backupPath,
      PackageExpectedFiles: expectedFiles,
      PackageStripSingleTopLevelDirectory: true,
      StartCommand: mode === 'standalone' ? 'server.js' : path.join('node_modules', 'next', 'dist', 'bin', 'next')
    }, null, 2));
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Import-AppPackage.ps1'),
      '-ConfigPath', configPath,
      '-PackagePath', packagePath
    ]);
  } else {
    const configPath = path.join(testRoot, `import-${mode}.env`);
    const expectedFiles = mode === 'standalone'
      ? 'server.js .next/BUILD_ID .next/static node_modules/next/package.json'
      : 'package.json .next/BUILD_ID .next node_modules/next/package.json node_modules/next/dist/bin/next';
    await fs.writeFile(configPath, [
      `APP_NAME=${shellQuote(`node-deploy-kit-real-next-import-${mode}`)}`,
      'APP_RUNTIME="node"',
      'APP_FRAMEWORK="nextjs"',
      `NEXTJS_DEPLOYMENT_MODE=${shellQuote(mode)}`,
      'NEXTJS_REQUIRE_PACKAGE_PROVENANCE="true"',
      `APP_DIR=${shellQuote(importedPath)}`,
      `BACKUP_DIR=${shellQuote(backupPath)}`,
      `PACKAGE_PATH=${shellQuote(packagePath)}`,
      `PACKAGE_EXPECTED_FILES=${shellQuote(expectedFiles)}`,
      'PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR="true"',
      'SERVICE_MANAGER="none"'
    ].join('\n') + '\n');
    await runAsRoot('bash', [path.join(repoRoot, 'scripts', 'linux', 'import-app-package.sh'), configPath, packagePath]);
    await restoreTestDirectoryOwnership(importedPath);
  }

  await assertExists(path.join(importedPath, '.node-enterprise-deploy.json'), `${mode} imported deployment manifest`);
  try {
    await fs.access(path.join(importedPath, '.node-enterprise-package.json'));
    throw new Error(`${mode} package provenance marker must not remain in the imported app directory.`);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  return importedPath;
}

async function verifyImportedPackageProvenance(importedPath, expectedProvenance, mode) {
  const manifest = JSON.parse(await fs.readFile(path.join(importedPath, '.node-enterprise-deploy.json'), 'utf8'));
  const expectedManifestProvenance = {
    schema: expectedProvenance.schema,
    buildPlatform: expectedProvenance.buildPlatform,
    buildArchitecture: expectedProvenance.buildArchitecture,
    buildLibc: expectedProvenance.buildLibc,
    nodeModuleAbi: expectedProvenance.nodeModuleAbi,
    nextVersion: expectedProvenance.nextVersion,
    nextBuildId: expectedProvenance.nextBuildId
  };
  const expectedKeys = Object.keys(expectedManifestProvenance).sort();
  const actualKeys = Object.keys(manifest.packageProvenance || {}).sort();
  if (
    JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys) ||
    JSON.stringify(manifest.packageProvenance) !== JSON.stringify(expectedManifestProvenance)
  ) {
    throw new Error(`${mode} import manifest does not preserve verified package provenance.`);
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
    await waitForForwardedRuntimeHeaders(port, child);
  } finally {
    await stopProcess(child);
  }
}

function createWindowsServiceConfig({ serviceName, runtimePath, mode, port, publicPort, serviceManager, serviceRoot }) {
  const startCommand = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const iisSiteName = `${serviceName}-Iis`;
  const iisAppPoolName = `${serviceName}-IisAppPool`;
  return {
    AppName: serviceName,
    DisplayName: serviceName,
    Description: `Temporary real Next.js ${serviceManager} CI integration service`,
    DeploymentMode: runWindowsIisIntegration ? 'reverse_proxy' : 'service_only',
    AppFramework: 'nextjs',
    NextjsDeploymentMode: mode,
    NextjsRequireStaticAssets: true,
    NextjsMinimumNodeVersion: '20.9.0',
    ServiceManager: serviceManager,
    ReverseProxy: runWindowsIisIntegration ? 'iis' : 'none',
    ServiceAccount: 'LocalSystem',
    AppDirectory: runtimePath,
    ServiceDirectory: path.join(serviceRoot, 'service'),
    LogDirectory: path.join(serviceRoot, 'logs'),
    BackupDirectory: path.join(serviceRoot, 'backups'),
    NodeExe: process.execPath,
    StartCommand: startCommand,
    NodeArguments: nodeArguments,
    Port: port,
    BindAddress: '127.0.0.1',
    HealthUrl: `http://127.0.0.1:${port}/`,
    IisSitePath: path.join(serviceRoot, 'iis-site'),
    IisSiteName: iisSiteName,
    IisAppPoolName: iisAppPoolName,
    PublicHostName: '',
    PublicPort: publicPort,
    TlsEnabled: false,
    IisEnableArrProxy: true,
    IisSetForwardedHeaders: true,
    IisRequireUrlRewrite: true,
    IisRequireArrProxy: true,
    Environment: {
      NODE_ENV: 'production',
      PORT: String(port),
      APP_PORT: String(port),
      HOST: '127.0.0.1',
      HOSTNAME: '127.0.0.1',
      NEXT_TELEMETRY_DISABLED: '1'
    }
  };
}

async function removeTemporaryWindowsIisSite(config) {
  if (!runWindowsIisIntegration) {
    return;
  }

  const command = [
    '$ErrorActionPreference = "Continue"',
    'Import-Module WebAdministration',
    `if (Test-Path -LiteralPath "IIS:\\Sites\\${config.IisSiteName}") { Stop-Website -Name "${config.IisSiteName}" -ErrorAction SilentlyContinue; Remove-Website -Name "${config.IisSiteName}" -ErrorAction SilentlyContinue }`,
    `if (Test-Path -LiteralPath "IIS:\\AppPools\\${config.IisAppPoolName}") { Remove-WebAppPool -Name "${config.IisAppPoolName}" -ErrorAction SilentlyContinue }`
  ].join('; ');
  await run('pwsh', ['-NoProfile', '-Command', command], { allowFailure: true });
}

async function verifyWindowsIisProxy(config, configPath) {
  if (!runWindowsIisIntegration) {
    return;
  }

  await run('pwsh', [
    '-NoProfile',
    '-File', path.join(repoRoot, 'scripts', 'windows', 'Install-ReverseProxy.ps1'),
    '-ConfigPath', configPath
  ]);
  const publicPort = Number(config.PublicPort);
  await waitForPage(`http://127.0.0.1:${publicPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
  await waitForForwardedProxyHeaders(publicPort, { exitCode: null });
}

async function verifyWindowsWinSwService(runtimePath, mode, port) {
  const serviceName = `NodeDeployKitRealNext${Date.now()}${mode === 'standalone' ? 'Standalone' : 'NextStart'}`;
  const serviceRoot = path.join(testRoot, `winsw-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.config.json');
  const winSwPath = path.join(serviceRoot, 'winsw', 'WinSW-x64.exe');
  const publicPort = await getFreePort();
  const config = createWindowsServiceConfig({ serviceName, runtimePath, mode, port, publicPort, serviceManager: 'winsw', serviceRoot });

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
    await waitForForwardedRuntimeHeaders(port, { exitCode: null });
    await verifyWindowsIisProxy(config, configPath);
  } finally {
    await removeTemporaryWindowsIisSite(config);
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Uninstall-NodeService.ps1'),
      '-ConfigPath', configPath
    ], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyWindowsNssmService(runtimePath, mode, port) {
  const serviceName = `NodeDeployKitRealNextNssm${Date.now()}${mode === 'standalone' ? 'Standalone' : 'NextStart'}`;
  const serviceRoot = path.join(testRoot, `nssm-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.config.json');
  const nssmPath = process.env.NSSM_PATH || 'C:\\ProgramData\\chocolatey\\bin\\nssm.exe';
  const publicPort = await getFreePort();
  const config = createWindowsServiceConfig({ serviceName, runtimePath, mode, port, publicPort, serviceManager: 'nssm', serviceRoot });

  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, JSON.stringify(config, null, 2));

  try {
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Install-NSSMService.ps1'),
      '-ConfigPath', configPath,
      '-NssmPath', nssmPath
    ]);
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
    await waitForForwardedRuntimeHeaders(port, { exitCode: null });
    await verifyWindowsIisProxy(config, configPath);
  } finally {
    await removeTemporaryWindowsIisSite(config);
    await run('pwsh', [
      '-NoProfile',
      '-File', path.join(repoRoot, 'scripts', 'windows', 'Uninstall-NodeService.ps1'),
      '-ConfigPath', configPath,
      '-NssmPath', nssmPath
    ], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyMacosLaunchdService(runtimePath, mode, port, afterServiceReady = null) {
  const serviceName = `node-deploy-kit-real-next-${Date.now()}-${mode}`;
  const serviceRoot = path.join(testRoot, `launchd-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.env');
  const logDirectory = path.join(serviceRoot, 'logs');
  const backupDirectory = path.join(serviceRoot, 'backups');
  const environmentFile = path.join(serviceRoot, 'runtime.env');
  const runnerScript = path.join(serviceRoot, 'runner.sh');
  const serviceUser = os.userInfo().username;
  const serviceGroup = await getUnixPrimaryGroup();
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, [
    `APP_NAME=${shellQuote(serviceName)}`,
    `APP_DISPLAY_NAME=${shellQuote(serviceName)}`,
    `SERVICE_USER=${shellQuote(serviceUser)}`,
    `SERVICE_GROUP=${shellQuote(serviceGroup)}`,
    `APP_DIR=${shellQuote(runtimePath)}`,
    `LOG_DIR=${shellQuote(logDirectory)}`,
    `BACKUP_DIR=${shellQuote(backupDirectory)}`,
    `ENV_FILE=${shellQuote(environmentFile)}`,
    `RUNNER_SCRIPT=${shellQuote(runnerScript)}`,
    `NODE_BIN=${shellQuote(process.execPath)}`,
    `START_SCRIPT=${shellQuote(startScript)}`,
    `NODE_ARGUMENTS=${shellQuote(nodeArguments)}`,
    'APP_FRAMEWORK="nextjs"',
    `NEXTJS_DEPLOYMENT_MODE=${shellQuote(mode)}`,
    'SERVICE_MANAGER="launchd"',
    'SKIP_INSTALL="true"',
    'SKIP_BUILD="true"',
    'NODE_ENV="production"',
    `APP_PORT=${shellQuote(String(port))}`,
    'BIND_ADDRESS="127.0.0.1"',
    'HOST="127.0.0.1"',
    'HOSTNAME="127.0.0.1"'
  ].join('\n') + '\n');

  try {
    await runAsRoot('bash', [path.join(repoRoot, 'scripts', 'linux', 'install-node-service.sh'), configPath]);
    await run('sudo', ['--non-interactive', 'launchctl', 'print', `system/${serviceName}`]);
    try {
      await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
      await waitForForwardedRuntimeHeaders(port, { exitCode: null });
      if (afterServiceReady) {
        await afterServiceReady();
      }
    } catch (error) {
      await run('sudo', ['--non-interactive', 'launchctl', 'print', `system/${serviceName}`], { allowFailure: true });
      await run('sudo', ['--non-interactive', 'cat', path.join(logDirectory, 'stderr.log')], { allowFailure: true });
      throw error;
    }
  } finally {
    await run('sudo', [
      '--non-interactive',
      'bash', path.join(repoRoot, 'scripts', 'linux', 'uninstall-node-service.sh'), configPath
    ], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function startDirectLinuxNextRuntime(runtimePath, mode, appPort, label) {
  const runtimeRoot = path.join(testRoot, `${label}-backend-${mode}-${appPort}`);
  const envPath = path.join(runtimeRoot, 'runtime.env');
  const runnerPath = path.join(runtimeRoot, 'runner.sh');
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const runnerTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'launchd-runner.sh.tpl'), 'utf8');
  const runner = runnerTemplate
    .replaceAll('{{APP_DIR}}', runtimePath)
    .replaceAll('{{ENV_FILE}}', envPath)
    .replaceAll('{{NODE_BIN}}', process.execPath)
    .replaceAll('{{START_SCRIPT}}', startScript)
    .replaceAll('{{NODE_ARGUMENTS}}', nodeArguments);

  await fs.mkdir(runtimeRoot, { recursive: true });
  await fs.writeFile(envPath, [
    'NODE_ENV=production',
    `PORT=${appPort}`,
    `APP_PORT=${appPort}`,
    'BIND_ADDRESS=127.0.0.1',
    'HOST=127.0.0.1',
    'HOSTNAME=127.0.0.1',
    'NEXT_TELEMETRY_DISABLED=1'
  ].join('\n') + '\n');
  await fs.writeFile(runnerPath, runner, { mode: 0o755 });
  const child = start('bash', [runnerPath], { cwd: runtimePath, env: process.env });

  return {
    child,
    async cleanup() {
      await stopProcess(child);
      await fs.rm(runtimeRoot, { recursive: true, force: true });
    }
  };
}

async function withLinuxProxyBackend(runtimePath, mode, appPort, label, backend, verifyProxy) {
  const directRuntime = backend ? null : await startDirectLinuxNextRuntime(runtimePath, mode, appPort, label);
  const child = backend || directRuntime.child;

  try {
    await waitForPage(`http://127.0.0.1:${appPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', child);
    await verifyProxy(child);
  } finally {
    if (directRuntime) {
      await directRuntime.cleanup();
    }
  }
}

async function resolveNginxMimeTypes() {
  for (const candidate of [
    '/etc/nginx/mime.types',
    '/opt/homebrew/etc/nginx/mime.types',
    '/usr/local/etc/nginx/mime.types'
  ]) {
    try {
      await fs.access(candidate);
      return candidate;
    } catch {
      // Try the next platform-specific nginx installation location.
    }
  }
  throw new Error('Could not locate nginx mime.types. Install nginx before running the reverse-proxy integration.');
}

async function resolveLinuxApacheInstallation() {
  const candidates = [
    {
      command: 'apache2',
      moduleDirectory: '/usr/lib/apache2/modules',
      mimeTypesPath: '/etc/mime.types',
      user: 'www-data',
      group: 'www-data'
    },
    {
      command: 'httpd',
      moduleDirectory: '/usr/lib/apache2',
      mimeTypesPath: '/etc/apache2/mime.types',
      user: 'apache',
      group: 'apache'
    }
  ];

  for (const candidate of candidates) {
    try {
      await Promise.all([
        fs.access(candidate.mimeTypesPath),
        fs.access(path.join(candidate.moduleDirectory, 'mod_mpm_event.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_authz_core.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_mime.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_proxy.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_proxy_http.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_proxy_wstunnel.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_headers.so')),
        fs.access(path.join(candidate.moduleDirectory, 'mod_rewrite.so'))
      ]);
      const unixdModulePath = path.join(candidate.moduleDirectory, 'mod_unixd.so');
      try {
        await fs.access(unixdModulePath);
        return { ...candidate, unixdModulePath };
      } catch {
        return candidate;
      }
    } catch {
      // Try the next supported Apache/httpd layout.
    }
  }
  throw new Error('Could not locate a supported Apache/httpd module layout. Install Apache proxy and rewrite modules before running the integration.');
}

async function verifyLinuxApacheProxy(runtimePath, mode, appPort, backend = null) {
  if (process.platform !== 'linux') {
    throw new Error('Apache proxy integration is only supported on Linux.');
  }

  const proxyPort = await getFreePort();
  const apacheRoot = path.join(testRoot, `apache-${mode}-${proxyPort}`);
  const configPath = path.join(apacheRoot, 'httpd.conf');
  const vhostPath = path.join(apacheRoot, 'node-enterprise-deploy-kit.conf');
  const logDirectory = path.join(apacheRoot, 'logs');
  const apacheInstallation = await resolveLinuxApacheInstallation();
  const vhostTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'apache-vhost.conf.tpl'), 'utf8');
  const vhost = vhostTemplate
    .replaceAll('{{APP_NAME}}', 'node-enterprise-deploy-kit-real-next')
    .replaceAll('{{PUBLIC_HOSTNAME}}', 'localhost')
    .replaceAll('{{PROXY_LISTEN_PORT}}', String(proxyPort))
    .replaceAll('{{APP_PORT}}', String(appPort))
    .replaceAll('{{HEALTH_URL}}', `http://127.0.0.1:${appPort}/`)
    .replaceAll('{{LOG_DIR}}', logDirectory)
    .replaceAll('{{FORWARDED_PROTO}}', 'http')
    .replaceAll('{{FORWARDED_PORT}}', String(proxyPort));

  await fs.mkdir(logDirectory, { recursive: true });
  await fs.chmod(logDirectory, 0o777);
  await fs.writeFile(vhostPath, vhost);
  await fs.writeFile(configPath, [
    `ServerRoot "${apacheRoot}"`,
    `DefaultRuntimeDir "${apacheRoot}"`,
    `PidFile "${path.join(apacheRoot, 'httpd.pid')}"`,
    'ServerName localhost',
    `Listen 127.0.0.1:${proxyPort}`,
    `TypesConfig ${apacheInstallation.mimeTypesPath}`,
    `LoadModule mpm_event_module ${path.join(apacheInstallation.moduleDirectory, 'mod_mpm_event.so')}`,
    ...(apacheInstallation.unixdModulePath ? [`LoadModule unixd_module ${apacheInstallation.unixdModulePath}`] : []),
    `LoadModule authz_core_module ${path.join(apacheInstallation.moduleDirectory, 'mod_authz_core.so')}`,
    `LoadModule mime_module ${path.join(apacheInstallation.moduleDirectory, 'mod_mime.so')}`,
    `LoadModule proxy_module ${path.join(apacheInstallation.moduleDirectory, 'mod_proxy.so')}`,
    `LoadModule proxy_http_module ${path.join(apacheInstallation.moduleDirectory, 'mod_proxy_http.so')}`,
    `LoadModule proxy_wstunnel_module ${path.join(apacheInstallation.moduleDirectory, 'mod_proxy_wstunnel.so')}`,
    `LoadModule headers_module ${path.join(apacheInstallation.moduleDirectory, 'mod_headers.so')}`,
    `LoadModule rewrite_module ${path.join(apacheInstallation.moduleDirectory, 'mod_rewrite.so')}`,
    `User ${apacheInstallation.user}`,
    `Group ${apacheInstallation.group}`,
    `ErrorLog "${path.join(logDirectory, 'apache-bootstrap-error.log')}"`,
    `Include "${vhostPath}"`
  ].join('\n') + '\n');
  await run(apacheInstallation.command, ['-t', '-f', configPath]);

  let apache;
  try {
    await withLinuxProxyBackend(runtimePath, mode, appPort, 'apache', backend, async () => {
      apache = start(apacheInstallation.command, ['-f', configPath, '-DFOREGROUND'], { cwd: apacheRoot, env: process.env });
      await waitForPage(`http://127.0.0.1:${proxyPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', apache);
      await waitForForwardedProxyHeaders(proxyPort, apache);
    });
  } catch (error) {
    const diagnostics = await fs.readFile(path.join(logDirectory, 'apache-bootstrap-error.log'), 'utf8')
      .catch(() => 'Apache error log was not created.');
    throw new Error(`${error.message}\nApache diagnostics:\n${diagnostics}`);
  } finally {
    await stopProcess(apache);
    await fs.rm(apacheRoot, { recursive: true, force: true });
  }
}

async function resolveMacosHttpdInstallation() {
  for (const prefix of ['/opt/homebrew/opt/httpd', '/usr/local/opt/httpd']) {
    const binaryPath = path.join(prefix, 'bin', 'httpd');
    const moduleDirectory = path.join(prefix, 'lib', 'httpd', 'modules');
    try {
      await Promise.all([
        fs.access(binaryPath),
        fs.access(path.join(moduleDirectory, 'mod_mpm_event.so')),
        fs.access(path.join(moduleDirectory, 'mod_proxy_http.so'))
      ]);
      return { binaryPath, moduleDirectory };
    } catch {
      // Try the next Homebrew installation prefix.
    }
  }
  throw new Error('Could not locate Homebrew httpd. Install it with "brew install httpd" before running the macOS Apache integration.');
}

async function verifyMacosApacheProxy(runtimePath, mode, appPort, backend = null) {
  if (process.platform !== 'darwin') {
    throw new Error('The macOS Apache proxy integration is only supported on macOS.');
  }

  const { binaryPath, moduleDirectory } = await resolveMacosHttpdInstallation();
  const proxyPort = await getFreePort();
  const apacheRoot = path.join(testRoot, `macos-apache-${mode}-${proxyPort}`);
  const configPath = path.join(apacheRoot, 'httpd.conf');
  const vhostPath = path.join(apacheRoot, 'node-enterprise-deploy-kit.conf');
  const logDirectory = path.join(apacheRoot, 'logs');
  const vhostTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'apache-vhost.conf.tpl'), 'utf8');
  const vhost = vhostTemplate
    .replaceAll('{{APP_NAME}}', 'node-enterprise-deploy-kit-real-next')
    .replaceAll('{{PUBLIC_HOSTNAME}}', 'localhost')
    .replaceAll('{{PROXY_LISTEN_PORT}}', String(proxyPort))
    .replaceAll('{{APP_PORT}}', String(appPort))
    .replaceAll('{{HEALTH_URL}}', `http://127.0.0.1:${appPort}/`)
    .replaceAll('{{LOG_DIR}}', logDirectory)
    .replaceAll('{{FORWARDED_PROTO}}', 'http')
    .replaceAll('{{FORWARDED_PORT}}', String(proxyPort));

  await fs.mkdir(logDirectory, { recursive: true });
  await fs.chmod(logDirectory, 0o777);
  await fs.writeFile(vhostPath, vhost);
  await fs.writeFile(configPath, [
    `ServerRoot "${apacheRoot}"`,
    `DefaultRuntimeDir "${apacheRoot}"`,
    `PidFile "${path.join(apacheRoot, 'httpd.pid')}"`,
    'ServerName localhost',
    `Listen 127.0.0.1:${proxyPort}`,
    `LoadModule mpm_event_module "${path.join(moduleDirectory, 'mod_mpm_event.so')}"`,
    `LoadModule authz_core_module "${path.join(moduleDirectory, 'mod_authz_core.so')}"`,
    `LoadModule authz_host_module "${path.join(moduleDirectory, 'mod_authz_host.so')}"`,
    `LoadModule log_config_module "${path.join(moduleDirectory, 'mod_log_config.so')}"`,
    `LoadModule mime_module "${path.join(moduleDirectory, 'mod_mime.so')}"`,
    `LoadModule proxy_module "${path.join(moduleDirectory, 'mod_proxy.so')}"`,
    `LoadModule proxy_http_module "${path.join(moduleDirectory, 'mod_proxy_http.so')}"`,
    `LoadModule headers_module "${path.join(moduleDirectory, 'mod_headers.so')}"`,
    `LoadModule rewrite_module "${path.join(moduleDirectory, 'mod_rewrite.so')}"`,
    `ErrorLog "${path.join(logDirectory, 'apache-bootstrap-error.log')}"`,
    `Include "${vhostPath}"`
  ].join('\n') + '\n');
  await run(binaryPath, ['-t', '-f', configPath]);

  let apache;
  try {
    await withLinuxProxyBackend(runtimePath, mode, appPort, 'macos-apache', backend, async () => {
      apache = start(binaryPath, ['-f', configPath, '-DFOREGROUND'], { cwd: apacheRoot, env: process.env });
      await waitForPage(`http://127.0.0.1:${proxyPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', apache);
      await waitForForwardedProxyHeaders(proxyPort, apache);
    });
  } catch (error) {
    const diagnostics = await fs.readFile(path.join(logDirectory, 'apache-bootstrap-error.log'), 'utf8')
      .catch(() => 'Apache error log was not created.');
    throw new Error(`${error.message}\nmacOS Apache diagnostics:\n${diagnostics}`);
  } finally {
    await stopProcess(apache);
    await fs.rm(apacheRoot, { recursive: true, force: true });
  }
}

async function verifyLinuxNginxProxy(runtimePath, mode, appPort, backend = null) {
  if (process.platform !== 'linux' && process.platform !== 'darwin') {
    throw new Error('Nginx proxy integration is only supported on Linux and macOS.');
  }

  const proxyPort = await getFreePort();
  const nginxRoot = path.join(testRoot, `nginx-${mode}-${proxyPort}`);
  const configPath = path.join(nginxRoot, 'nginx.conf');
  const sitePath = path.join(nginxRoot, 'node-enterprise-deploy-kit.conf');
  const logDirectory = path.join(nginxRoot, 'logs');
  const mimeTypesPath = await resolveNginxMimeTypes();
  const siteTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'nginx-site.conf.tpl'), 'utf8');
  const site = siteTemplate
    .replaceAll('{{APP_NAME}}', 'node-enterprise-deploy-kit-real-next')
    .replaceAll('{{PUBLIC_HOSTNAME}}', 'localhost')
    .replaceAll('{{PROXY_LISTEN_PORT}}', String(proxyPort))
    .replaceAll('{{APP_PORT}}', String(appPort))
    .replaceAll('{{HEALTH_URL}}', `http://127.0.0.1:${appPort}/`)
    .replaceAll('{{LOG_DIR}}', logDirectory)
    .replaceAll('{{FORWARDED_PROTO}}', 'http')
    .replaceAll('{{FORWARDED_PORT}}', String(proxyPort));

  await fs.mkdir(logDirectory, { recursive: true });
  await fs.writeFile(sitePath, site);
  await fs.writeFile(configPath, [
    'worker_processes 1;',
    `pid ${path.join(nginxRoot, 'nginx.pid')};`,
    `error_log ${path.join(logDirectory, 'nginx-bootstrap-error.log')} warn;`,
    'events { worker_connections 64; }',
    'http {',
    `  include ${mimeTypesPath};`,
    '  default_type application/octet-stream;',
    `  include ${sitePath};`,
    '}'
  ].join('\n') + '\n');

  let nginx;
  try {
    await withLinuxProxyBackend(runtimePath, mode, appPort, 'nginx', backend, async () => {
      nginx = start('nginx', ['-c', configPath, '-p', nginxRoot, '-g', 'daemon off;'], { cwd: nginxRoot, env: process.env });
      await waitForPage(`http://127.0.0.1:${proxyPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', nginx);
      await waitForForwardedProxyHeaders(proxyPort, nginx);
    });
  } finally {
    await stopProcess(nginx);
    await fs.rm(nginxRoot, { recursive: true, force: true });
  }
}

async function verifyLinuxHaProxy(runtimePath, mode, appPort, backend = null) {
  if (process.platform !== 'linux' && process.platform !== 'darwin') {
    throw new Error('HAProxy integration is only supported on Linux and macOS.');
  }

  const proxyPort = await getFreePort();
  const haproxyRoot = path.join(testRoot, `haproxy-${mode}-${proxyPort}`);
  const configPath = path.join(haproxyRoot, 'haproxy.cfg');
  const configTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'haproxy.cfg.tpl'), 'utf8');
  const config = configTemplate
    .replaceAll('{{APP_NAME}}', 'node-enterprise-deploy-kit-real-next')
    .replaceAll('{{HAPROXY_FRONTEND_NAME}}', 'node_enterprise_deploy_kit_frontend')
    .replaceAll('{{HAPROXY_BACKEND_NAME}}', 'node_enterprise_deploy_kit_backend')
    .replaceAll('{{HAPROXY_BIND}}', `127.0.0.1:${proxyPort}`)
    .replaceAll('{{APP_PORT}}', String(appPort))
    .replaceAll('{{HEALTHCHECK_PATH}}', '/')
    .replaceAll('{{FORWARDED_PROTO}}', 'http')
    .replaceAll('{{FORWARDED_PORT}}', String(proxyPort));

  await fs.mkdir(haproxyRoot, { recursive: true });
  await fs.writeFile(configPath, config);

  let haproxy;
  try {
    await withLinuxProxyBackend(runtimePath, mode, appPort, 'haproxy', backend, async () => {
      haproxy = start('haproxy', ['-f', configPath, '-db'], { cwd: haproxyRoot, env: process.env });
      await waitForPage(`http://127.0.0.1:${proxyPort}/`, 'node-enterprise-deploy-kit real-nextjs-integration', haproxy);
      await waitForForwardedProxyHeaders(proxyPort, haproxy);
    });
  } finally {
    await stopProcess(haproxy);
    await fs.rm(haproxyRoot, { recursive: true, force: true });
  }
}

async function verifyLinuxTraefikProxy(runtimePath, mode, appPort, backend = null) {
  if (process.platform !== 'linux' && process.platform !== 'darwin') {
    throw new Error('Traefik integration is only supported on Linux and macOS.');
  }

  const proxyPort = await getFreePort();
  const traefikRoot = path.join(testRoot, `traefik-${mode}-${proxyPort}`);
  const staticConfigPath = path.join(traefikRoot, 'traefik.yml');
  const dynamicConfigPath = path.join(traefikRoot, 'dynamic.yml');
  const dynamicTemplate = await fs.readFile(path.join(repoRoot, 'templates', 'linux', 'traefik-dynamic.yml.tpl'), 'utf8');
  const dynamicConfig = dynamicTemplate
    .replaceAll('{{APP_NAME}}', 'node-enterprise-deploy-kit-real-next')
    .replaceAll('{{PUBLIC_HOSTNAME}}', 'localhost')
    .replaceAll('{{TRAEFIK_ENTRYPOINT}}', 'integration')
    .replaceAll('{{TRAEFIK_ROUTER_NAME}}', 'node-enterprise-deploy-kit-real-next-router')
    .replaceAll('{{TRAEFIK_SERVICE_NAME}}', 'node-enterprise-deploy-kit-real-next-service')
    .replaceAll('{{HEALTHCHECK_PATH}}', '/')
    .replaceAll('{{APP_PORT}}', String(appPort));
  const staticConfig = [
    'entryPoints:',
    '  integration:',
    `    address: "127.0.0.1:${proxyPort}"`,
    'providers:',
    '  file:',
    `    filename: "${dynamicConfigPath}"`,
    '    watch: false',
    'log:',
    '  level: ERROR'
  ].join('\n') + '\n';

  await fs.mkdir(traefikRoot, { recursive: true });
  await fs.writeFile(dynamicConfigPath, dynamicConfig);
  await fs.writeFile(staticConfigPath, staticConfig);

  let traefik;
  try {
    await withLinuxProxyBackend(runtimePath, mode, appPort, 'traefik', backend, async () => {
      traefik = start('traefik', [`--configFile=${staticConfigPath}`], { cwd: traefikRoot, env: process.env });
      await waitForPage(
        `http://127.0.0.1:${proxyPort}/`,
        'node-enterprise-deploy-kit real-nextjs-integration',
        traefik,
        { Host: 'localhost' }
      );
      await waitForForwardedProxyHeaders(proxyPort, traefik, { Host: 'localhost' }, '80');
    });
  } finally {
    await stopProcess(traefik);
    await fs.rm(traefikRoot, { recursive: true, force: true });
  }
}

function shellEnvAssignment(key, value) {
  return `${key}=${shellQuote(String(value))}`;
}

async function verifySelectedLinuxReverseProxy(runtimePath, mode, appPort, backend = null) {
  if (runApacheProxyIntegration) {
    if (process.platform === 'darwin') {
      await verifyMacosApacheProxy(runtimePath, mode, appPort, backend);
      return;
    }
    await verifyLinuxApacheProxy(runtimePath, mode, appPort, backend);
    return;
  }
  if (runNginxProxyIntegration) {
    await verifyLinuxNginxProxy(runtimePath, mode, appPort, backend);
    return;
  }
  if (runHaProxyIntegration) {
    await verifyLinuxHaProxy(runtimePath, mode, appPort, backend);
    return;
  }
  if (runTraefikProxyIntegration) {
    await verifyLinuxTraefikProxy(runtimePath, mode, appPort, backend);
  }
}

function hasLinuxProxyIntegration() {
  return runApacheProxyIntegration
    || runNginxProxyIntegration
    || runHaProxyIntegration
    || runTraefikProxyIntegration;
}

async function verifyLinuxSystemVService(runtimePath, mode, port, afterServiceReady = null) {
  const serviceName = `node-deploy-kit-next-${Date.now()}-${mode === 'standalone' ? 'standalone' : 'next-start'}`;
  const serviceRoot = path.join(testRoot, `systemv-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.env');
  const envPath = path.join(serviceRoot, 'runtime.env');
  const logDirectory = path.join(serviceRoot, 'logs');
  const backupDirectory = path.join(serviceRoot, 'backups');
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const config = {
    APP_NAME: serviceName,
    APP_DISPLAY_NAME: serviceName,
    APP_DESCRIPTION: 'Temporary real Next.js System V CI integration service',
    APP_DIR: runtimePath,
    ENV_FILE: envPath,
    NODE_BIN: process.execPath,
    START_SCRIPT: startScript,
    NODE_ARGUMENTS: nodeArguments,
    APP_PORT: String(port),
    BIND_ADDRESS: '127.0.0.1',
    SERVICE_MANAGER: 'systemv',
    SERVICE_USER: 'root',
    SERVICE_GROUP: 'root',
    LOG_DIR: logDirectory,
    BACKUP_DIR: backupDirectory,
    SKIP_INSTALL: 'true',
    SKIP_BUILD: 'true',
    NODE_ENV: 'production',
    RUNTIME_ENV_KEYS: 'NEXT_TELEMETRY_DISABLED',
    NEXT_TELEMETRY_DISABLED: '1'
  };

  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, Object.entries(config)
    .map(([key, value]) => shellEnvAssignment(key, value))
    .join('\n') + '\n');

  try {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'install-node-service.sh'), configPath]);
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
    await waitForForwardedRuntimeHeaders(port, { exitCode: null });
    if (afterServiceReady) {
      await afterServiceReady();
    }
  } finally {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'uninstall-node-service.sh'), configPath], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyLinuxOpenRcService(runtimePath, mode, port, afterServiceReady = null) {
  const serviceName = `node-deploy-kit-next-${Date.now()}-${mode === 'standalone' ? 'standalone' : 'next-start'}`;
  const serviceRoot = path.join(testRoot, `openrc-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.env');
  const envPath = path.join(serviceRoot, 'runtime.env');
  const logDirectory = path.join(serviceRoot, 'logs');
  const backupDirectory = path.join(serviceRoot, 'backups');
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const config = {
    APP_NAME: serviceName,
    APP_DISPLAY_NAME: serviceName,
    APP_DESCRIPTION: 'Temporary real Next.js OpenRC CI integration service',
    APP_DIR: runtimePath,
    ENV_FILE: envPath,
    NODE_BIN: process.execPath,
    START_SCRIPT: startScript,
    NODE_ARGUMENTS: nodeArguments,
    APP_PORT: String(port),
    BIND_ADDRESS: '127.0.0.1',
    SERVICE_MANAGER: 'openrc',
    SERVICE_USER: 'root',
    SERVICE_GROUP: 'root',
    LOG_DIR: logDirectory,
    BACKUP_DIR: backupDirectory,
    SKIP_INSTALL: 'true',
    SKIP_BUILD: 'true',
    NODE_ENV: 'production',
    RUNTIME_ENV_KEYS: 'NEXT_TELEMETRY_DISABLED',
    NEXT_TELEMETRY_DISABLED: '1'
  };

  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, Object.entries(config)
    .map(([key, value]) => shellEnvAssignment(key, value))
    .join('\n') + '\n');

  try {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'install-node-service.sh'), configPath]);
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
    await waitForForwardedRuntimeHeaders(port, { exitCode: null });
    if (afterServiceReady) {
      await afterServiceReady();
    }
  } finally {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'uninstall-node-service.sh'), configPath], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyLinuxSystemdService(runtimePath, mode, port, afterServiceReady = null) {
  const serviceName = `node-deploy-kit-next-${Date.now()}-${mode === 'standalone' ? 'standalone' : 'next-start'}`;
  const serviceRoot = path.join(testRoot, `systemd-${mode}-${port}`);
  const configPath = path.join(serviceRoot, 'service.env');
  const envPath = path.join(serviceRoot, 'runtime.env');
  const logDirectory = path.join(serviceRoot, 'logs');
  const backupDirectory = path.join(serviceRoot, 'backups');
  const startScript = mode === 'standalone'
    ? 'server.js'
    : path.join('node_modules', 'next', 'dist', 'bin', 'next');
  const nodeArguments = mode === 'standalone' ? '' : 'start -H 127.0.0.1';
  const config = {
    APP_NAME: serviceName,
    APP_DISPLAY_NAME: serviceName,
    APP_DESCRIPTION: 'Temporary real Next.js systemd CI integration service',
    APP_DIR: runtimePath,
    ENV_FILE: envPath,
    NODE_BIN: process.execPath,
    START_SCRIPT: startScript,
    NODE_ARGUMENTS: nodeArguments,
    APP_PORT: String(port),
    BIND_ADDRESS: '127.0.0.1',
    SERVICE_MANAGER: 'systemd',
    SERVICE_USER: 'root',
    SERVICE_GROUP: 'root',
    LOG_DIR: logDirectory,
    BACKUP_DIR: backupDirectory,
    SKIP_INSTALL: 'true',
    SKIP_BUILD: 'true',
    NODE_ENV: 'production',
    RUNTIME_ENV_KEYS: 'NEXT_TELEMETRY_DISABLED',
    NEXT_TELEMETRY_DISABLED: '1'
  };

  await fs.mkdir(serviceRoot, { recursive: true });
  await fs.writeFile(configPath, Object.entries(config)
    .map(([key, value]) => shellEnvAssignment(key, value))
    .join('\n') + '\n');

  try {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'install-node-service.sh'), configPath]);
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', { exitCode: null });
    await waitForForwardedRuntimeHeaders(port, { exitCode: null });
    if (afterServiceReady) {
      await afterServiceReady();
    }
  } finally {
    await run('bash', [path.join(repoRoot, 'scripts', 'linux', 'uninstall-node-service.sh'), configPath], { allowFailure: true });
    await fs.rm(serviceRoot, { recursive: true, force: true });
  }
}

async function verifyRuntime(runtimePath, mode) {
  const port = await getFreePort();
  const verifyServiceProxy = hasLinuxProxyIntegration()
    ? () => verifySelectedLinuxReverseProxy(runtimePath, mode, port, { exitCode: null })
    : null;

  if (process.platform === 'linux' && runLinuxSystemdServiceIntegration) {
    await verifyLinuxSystemdService(runtimePath, mode, port, verifyServiceProxy);
    return;
  }
  if (process.platform === 'linux' && runLinuxOpenRcServiceIntegration) {
    await verifyLinuxOpenRcService(runtimePath, mode, port, verifyServiceProxy);
    return;
  }
  if (process.platform === 'linux' && runLinuxSystemVServiceIntegration) {
    await verifyLinuxSystemVService(runtimePath, mode, port, verifyServiceProxy);
    return;
  }
  if (process.platform === 'darwin' && runLaunchdServiceIntegration) {
    await verifyMacosLaunchdService(runtimePath, mode, port, verifyServiceProxy);
    return;
  }
  if (hasLinuxProxyIntegration()) {
    await verifySelectedLinuxReverseProxy(runtimePath, mode, port);
    return;
  }
  if (process.platform !== 'win32') {
    await verifyUnixManagedRunner(runtimePath, mode, port);
    return;
  }
  if (runWindowsServiceIntegration) {
    await verifyWindowsWinSwService(runtimePath, mode, port);
    return;
  }
  if (runWindowsNssmServiceIntegration) {
    await verifyWindowsNssmService(runtimePath, mode, port);
    return;
  }

  const args = mode === 'standalone'
    ? ['server.js']
    : [path.join('node_modules', 'next', 'dist', 'bin', 'next'), 'start', '-H', '127.0.0.1', '-p', String(port)];
  const env = { ...process.env, NODE_ENV: 'production', PORT: String(port), HOST: '127.0.0.1', HOSTNAME: '127.0.0.1', NEXT_TELEMETRY_DISABLED: '1' };
  const child = start(process.execPath, args, { cwd: runtimePath, env });

  try {
    await waitForPage(`http://127.0.0.1:${port}/`, 'node-enterprise-deploy-kit real-nextjs-integration', child);
    await waitForForwardedRuntimeHeaders(port, child);
  } finally {
    await stopProcess(child);
  }
}

async function verifyMode(projectPath, mode, expectedNextVersion) {
  const extension = process.platform === 'win32' ? 'zip' : 'tar.gz';
  const packagePath = path.join(testRoot, `real-next-${mode}.${extension}`);
  const extractedPath = path.join(testRoot, `extracted-${mode}`);

  await packageProject(projectPath, mode, packagePath);
  await extractPackage(packagePath, extractedPath);
  await assertExists(path.join(extractedPath, 'node_modules', 'next', 'package.json'), `${mode} packaged Next.js metadata`);
  const provenance = await verifyPackageProvenance(extractedPath, mode, expectedNextVersion);
  const importedPath = await importPackage(packagePath, mode);
  await verifyImportedPackageProvenance(importedPath, provenance, mode);
  await verifyRuntime(importedPath, mode);
  console.log(`Real Next.js ${mode} package/import/runtime integration OK.`);
}

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  usage();
  process.exit(0);
}

if ([runLinuxSystemdServiceIntegration, runLinuxSystemVServiceIntegration, runLinuxOpenRcServiceIntegration].filter(Boolean).length > 1) {
  throw new Error('Only one Linux native service-manager integration flag may be true.');
}
if ([runApacheProxyIntegration, runNginxProxyIntegration, runHaProxyIntegration, runTraefikProxyIntegration].filter(Boolean).length > 1) {
  throw new Error('Only one Linux reverse-proxy integration flag may be true.');
}
if ([runWindowsServiceIntegration, runWindowsNssmServiceIntegration].filter(Boolean).length > 1) {
  throw new Error('Only one Windows service-manager integration flag may be true.');
}
if (runWindowsIisIntegration && !runWindowsServiceIntegration && !runWindowsNssmServiceIntegration) {
  throw new Error('RUN_WINDOWS_IIS_INTEGRATION requires RUN_WINSW_SERVICE_INTEGRATION or RUN_NSSM_SERVICE_INTEGRATION.');
}

await fs.mkdir(testRoot, { recursive: true });
const standaloneProjectPath = path.join(testRoot, 'standalone-project');
const nextStartProjectPath = path.join(testRoot, 'next-start-project');

try {
  console.log(`==> Real Next.js integration (${process.platform}, Next.js ${nextVersion})`);
  await verifyNpmRegistryAccess();
  await writeFixture(standaloneProjectPath, true);
  await buildProject(standaloneProjectPath, true);
  const installedVersion = JSON.parse(await fs.readFile(path.join(standaloneProjectPath, 'node_modules', 'next', 'package.json'), 'utf8')).version;
  console.log(`Built real Next.js ${installedVersion}.`);
  await verifyMode(standaloneProjectPath, 'standalone', installedVersion);

  await writeFixture(nextStartProjectPath, false);
  await buildProject(nextStartProjectPath, false);
  await verifyMode(nextStartProjectPath, 'next-start', installedVersion);
  console.log('Real Next.js integration checks OK.');
} finally {
  if (!keepTestRoot) {
    await fs.rm(testRoot, { recursive: true, force: true });
  } else {
    console.log(`Kept integration test root: ${testRoot}`);
  }
}
