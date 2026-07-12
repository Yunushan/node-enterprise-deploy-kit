#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const nextVersion = process.env.NEXTJS_INTEGRATION_NEXT_VERSION || 'latest';
const keepTestRoot = process.env.KEEP_REAL_NEXTJS_INTEGRATION === 'true';
const testRoot = path.join(repoRoot, '.tmp', `real-nextjs-integration-${process.platform}-${Date.now()}`);

function usage() {
  console.log('Usage: node scripts/dev/test-real-nextjs-integration.mjs [--help]');
  console.log('Builds a temporary real Next.js project, packages standalone and next-start artifacts, and verifies both serve HTTP.');
}

function run(command, args, options = {}) {
  const { cwd = repoRoot, env = process.env, allowFailure = false } = options;
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: 'inherit', windowsHide: true });
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

async function writeFixture(projectPath) {
  await fs.mkdir(path.join(projectPath, 'app'), { recursive: true });
  await fs.mkdir(path.join(projectPath, 'public'), { recursive: true });
  await fs.writeFile(path.join(projectPath, 'package.json'), JSON.stringify({
    name: 'node-enterprise-deploy-kit-real-nextjs-integration',
    private: true,
    scripts: { build: 'next build' }
  }, null, 2));
  await fs.writeFile(path.join(projectPath, 'next.config.mjs'), "export default { output: 'standalone' };\n");
  await fs.writeFile(path.join(projectPath, 'app', 'layout.js'), "export default function RootLayout({ children }) { return <html><body>{children}</body></html>; }\n");
  await fs.writeFile(path.join(projectPath, 'app', 'page.js'), "export default function Page() { return <main>node-enterprise-deploy-kit real-nextjs-integration</main>; }\n");
  await fs.writeFile(path.join(projectPath, 'public', 'integration.txt'), 'node-enterprise-deploy-kit\n');
}

async function buildProject(projectPath) {
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const env = { ...process.env, NEXT_TELEMETRY_DISABLED: '1', npm_config_fund: 'false', npm_config_audit: 'false' };

  await run(npm, ['install', '--save-exact', '--no-audit', '--no-fund', `next@${nextVersion}`, 'react@latest', 'react-dom@latest'], { cwd: projectPath, env });
  await run(npm, ['run', 'build'], { cwd: projectPath, env });

  await assertExists(path.join(projectPath, '.next', 'BUILD_ID'), 'Next.js build ID');
  await assertExists(path.join(projectPath, '.next', 'static'), 'Next.js static assets');
  await assertExists(path.join(projectPath, '.next', 'standalone', 'server.js'), 'Next.js standalone server');
  await assertExists(path.join(projectPath, 'node_modules', 'next', 'package.json'), 'Next.js package metadata');

  await fs.cp(path.join(projectPath, '.next', 'static'), path.join(projectPath, '.next', 'standalone', '.next', 'static'), { recursive: true });
  await fs.cp(path.join(projectPath, 'public'), path.join(projectPath, '.next', 'standalone', 'public'), { recursive: true });
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

async function verifyRuntime(runtimePath, mode) {
  const port = await getFreePort();
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
const projectPath = path.join(testRoot, 'project');

try {
  console.log(`==> Real Next.js integration (${process.platform}, Next.js ${nextVersion})`);
  await writeFixture(projectPath);
  await buildProject(projectPath);
  const installedVersion = JSON.parse(await fs.readFile(path.join(projectPath, 'node_modules', 'next', 'package.json'), 'utf8')).version;
  console.log(`Built real Next.js ${installedVersion}.`);
  await verifyMode(projectPath, 'standalone');
  await verifyMode(projectPath, 'next-start');
  console.log('Real Next.js integration checks OK.');
} finally {
  if (!keepTestRoot) {
    await fs.rm(testRoot, { recursive: true, force: true });
  } else {
    console.log(`Kept integration test root: ${testRoot}`);
  }
}
