#!/usr/bin/env node

import { access } from 'node:fs/promises';
import { constants } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const supportedManagers = new Set(['winsw', 'nssm', 'systemd', 'systemv', 'openrc', 'launchd']);
const supportedProxies = new Set(['iis', 'nginx', 'apache', 'haproxy', 'traefik', 'none']);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseArguments(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--self-test') {
      values.selfTest = true;
    } else if (['--platform', '--manager', '--proxy'].includes(argument)) {
      values[argument.slice(2)] = args[++index] || '';
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return values;
}

function parseNodeVersion(version) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(version);
  assert(match, `Unable to parse Node.js version: ${version}`);
  return match.slice(1).map(Number);
}

function isNodeVersionAtLeast(version, major, minor) {
  const [actualMajor, actualMinor] = parseNodeVersion(version);
  return actualMajor > major || (actualMajor === major && actualMinor >= minor);
}

export function validateRequest(request, platform = process.platform) {
  const { manager, proxy } = request;
  assert(request.platform === 'windows' || request.platform === 'unix', '--platform must be windows or unix.');
  assert(supportedManagers.has(manager), '--manager is not supported by the self-hosted integration workflow.');
  assert(supportedProxies.has(proxy), '--proxy is not supported by the self-hosted integration workflow.');
  if (request.platform === 'windows') {
    assert(platform === 'win32', 'Windows self-hosted integration prerequisites must run on Windows.');
    assert(manager === 'winsw' || manager === 'nssm', 'Windows self-hosted integration requires WinSW or NSSM.');
    assert(proxy === 'iis' || proxy === 'none', 'Windows self-hosted integration supports IIS or no reverse proxy.');
    return;
  }
  assert(platform === 'linux' || platform === 'darwin', 'Unix self-hosted integration prerequisites must run on Linux or macOS.');
  assert(!(platform === 'linux' && manager === 'launchd'), 'launchd integration requires macOS.');
  assert(!(platform === 'darwin' && manager !== 'launchd'), 'macOS integration requires launchd.');
  assert(proxy !== 'iis', 'IIS integration requires Windows.');
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true });
    let output = '';
    let errorOutput = '';
    child.stdout?.on('data', (chunk) => { output += chunk; });
    child.stderr?.on('data', (chunk) => { errorOutput += chunk; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}: ${errorOutput.trim() || output.trim()}`));
    });
  });
}

async function assertUnixCommand(command, purpose) {
  await run('sh', ['-lc', `command -v ${command} >/dev/null`]);
  console.log(`Prerequisite available: ${purpose}.`);
}

async function assertAnyUnixCommand(commands, purpose) {
  for (const command of commands) {
    try {
      await assertUnixCommand(command, purpose);
      return;
    } catch {
      // Continue with the next conventional executable name.
    }
  }
  throw new Error(`Missing prerequisite for ${purpose}: expected one of ${commands.join(', ')}.`);
}

async function assertWindowsCommand(command, purpose) {
  const shell = path.join(process.env.SystemRoot || process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  await run(shell, ['-NoProfile', '-NonInteractive', '-Command', `$ErrorActionPreference = 'Stop'; Get-Command '${command}' | Out-Null`]);
  console.log(`Prerequisite available: ${purpose}.`);
}

async function assertWindowsAdministrator() {
  const shell = path.join(process.env.SystemRoot || process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const command = [
    "$ErrorActionPreference = 'Stop'",
    '$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())',
    "if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Current Windows runner process is not elevated. Run the GitHub Actions runner service as Administrator before native service integration.' }"
  ].join('; ');
  await run(shell, ['-NoProfile', '-NonInteractive', '-Command', command]);
  console.log('Prerequisite available: Windows Administrator token.');
}

async function assertNssm() {
  const nssmPath = process.env.NSSM_PATH || 'C:\\ProgramData\\chocolatey\\bin\\nssm.exe';
  try {
    await access(nssmPath, constants.R_OK);
  } catch {
    throw new Error(`Missing prerequisite for NSSM: set NSSM_PATH or install NSSM at ${nssmPath}.`);
  }
  console.log('Prerequisite available: NSSM.');
}

async function assertWindowsIis() {
  const shell = path.join(process.env.SystemRoot || process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const command = [
    "$ErrorActionPreference = 'Stop'",
    'Import-Module WebAdministration',
    "foreach ($moduleName in @('RewriteModule', 'ApplicationRequestRouting')) { if (-not (Get-WebGlobalModule | Where-Object { $_.Name -eq $moduleName })) { throw \"IIS global module '$moduleName' was not detected. Install URL Rewrite and Application Request Routing before using ReverseProxy=iis.\" } }",
    'Get-Website | Out-Null'
  ].join('; ');
  await run(shell, ['-NoProfile', '-NonInteractive', '-Command', command]);
  console.log('Prerequisite available: IIS WebAdministration, URL Rewrite, and Application Request Routing.');
}

async function assertUnixManager(manager) {
  if (manager === 'systemd') {
    await assertUnixCommand('systemctl', 'systemd');
    await run('sudo', ['--non-interactive', 'systemctl', 'show-environment']);
  } else if (manager === 'systemv') {
    await assertUnixCommand('service', 'System V service command');
  } else if (manager === 'openrc') {
    await assertUnixCommand('rc-service', 'OpenRC service command');
    await assertUnixCommand('rc-update', 'OpenRC runlevel command');
  } else if (manager === 'launchd') {
    await assertUnixCommand('launchctl', 'launchd');
    await run('sudo', ['--non-interactive', 'launchctl', 'print', 'system']);
  } else {
    throw new Error(`Unsupported Unix service manager: ${manager}.`);
  }
}

async function assertUnixProxy(proxy) {
  if (proxy === 'none') return;
  const commands = {
    nginx: ['nginx'],
    apache: ['apache2', 'httpd'],
    haproxy: ['haproxy'],
    traefik: ['traefik']
  };
  await assertAnyUnixCommand(commands[proxy], `${proxy} reverse proxy`);
}

export async function verifyPrerequisites(request) {
  validateRequest(request);
  assert(isNodeVersionAtLeast(process.version, 20, 9), `Node.js ${process.version} is below the required 20.9.0 runtime floor.`);
  console.log(`Prerequisite available: Node.js ${process.version}.`);
  if (request.platform === 'windows') {
    await assertWindowsAdministrator();
    await assertWindowsCommand('sc.exe', 'Windows Service Control Manager');
    if (request.manager === 'nssm') await assertNssm();
    if (request.proxy === 'iis') await assertWindowsIis();
    return;
  }
  await run('sudo', ['--non-interactive', 'true']);
  console.log('Prerequisite available: passwordless sudo.');
  await assertUnixManager(request.manager);
  await assertUnixProxy(request.proxy);
}

function expectFailure(action, expectedMessage) {
  try {
    action();
  } catch (error) {
    if (error.message.includes(expectedMessage)) return;
    throw error;
  }
  throw new Error(`Self-test accepted invalid request: ${expectedMessage}`);
}

const isMainModule = process.argv[1]
  && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMainModule) {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    assert(isNodeVersionAtLeast('v20.9.0', 20, 9), 'Expected Node 20.9.0 to meet the floor.');
    assert(!isNodeVersionAtLeast('v20.8.0', 20, 9), 'Expected Node 20.8.0 to miss the floor.');
    validateRequest({ platform: 'unix', manager: 'systemd', proxy: 'nginx' }, 'linux');
    validateRequest({ platform: 'windows', manager: 'winsw', proxy: 'iis' }, 'win32');
    expectFailure(() => validateRequest({ platform: 'windows', manager: 'systemd', proxy: 'nginx' }, 'win32'), 'requires WinSW or NSSM');
    expectFailure(() => validateRequest({ platform: 'unix', manager: 'openrc', proxy: 'iis' }, 'linux'), 'IIS integration requires Windows');
    expectFailure(() => validateRequest({ platform: 'unix', manager: 'launchd', proxy: 'nginx' }, 'linux'), 'launchd integration requires macOS');
    console.log('Next.js host integration prerequisite validator OK');
  } else {
    for (const key of ['platform', 'manager', 'proxy']) {
      assert(typeof options[key] === 'string' && options[key], `--${key} is required.`);
    }
    await verifyPrerequisites(options);
    console.log(`Next.js host integration prerequisites OK: ${options.platform}/${options.manager}/${options.proxy}.`);
  }
}
