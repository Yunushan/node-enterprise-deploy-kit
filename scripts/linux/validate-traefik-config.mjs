#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';

const [binary, dynamicFile, entrypoint, routerName, serviceName] = process.argv.slice(2);
if (!binary || !dynamicFile || !entrypoint || !routerName || !serviceName) {
  console.error('Usage: validate-traefik-config.mjs BINARY DYNAMIC_FILE ENTRYPOINT ROUTER SERVICE');
  process.exit(2);
}
if (entrypoint === 'traefik') {
  console.error('The application entrypoint must differ from the validation API entrypoint traefik.');
  process.exit(2);
}

const reserve = createServer();
await new Promise((resolve, reject) => { reserve.once('error', reject); reserve.listen(0, '127.0.0.1', resolve); });
const apiPort = reserve.address().port;
await new Promise(resolve => reserve.close(resolve));
const directory = await mkdtemp(path.join(tmpdir(), 'node-edk-traefik-validation-'));
const staticFile = path.join(directory, 'traefik.yml');
let child;
let childExited = false;
let childExit;
let output = '';
let spawnError;
try {
  await writeFile(staticFile, [
    'global:', '  checkNewVersion: false', '  sendAnonymousUsage: false',
    'entryPoints:', `  ${JSON.stringify(entrypoint)}:`, '    address: "127.0.0.1:0"',
    '  traefik:', `    address: "127.0.0.1:${apiPort}"`,
    'api:', '  insecure: true',
    'providers:', '  file:', `    filename: ${JSON.stringify(path.resolve(dynamicFile))}`, '    watch: false',
    'log:', '  level: ERROR', '  format: json', ''
  ].join('\n'), { mode: 0o600 });
  // There is no `traefik check` CLI command. Validate with a disposable actual
  // Traefik instance on loopback/ephemeral ports, then inspect its loaded routes.
  child = spawn(binary, [`--configFile=${staticFile}`], { stdio: ['ignore', 'pipe', 'pipe'] });
  childExit = new Promise(resolve => child.once('exit', () => { childExited = true; resolve(); }));
  child.on('error', error => { spawnError = error; });
  for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output = (output + chunk).slice(-65536); });
  let valid = false;
  for (let attempt = 0; attempt < 60; attempt++) {
    if (spawnError) throw spawnError;
    if (childExited) throw new Error(`Traefik exited with ${child.exitCode ?? child.signalCode}: ${output}`);
    try {
      const response = await fetch(`http://127.0.0.1:${apiPort}/api/rawdata`, { signal: AbortSignal.timeout(500), redirect: 'error' });
      const data = await response.json();
      const router = data.routers?.[`${routerName}@file`];
      const service = data.services?.[`${serviceName}@file`];
      if (router?.status === 'enabled' && service?.status === 'enabled' && !router.error && !service.error) {
        valid = true;
        break;
      }
      if (router?.status === 'disabled' || router?.error || service?.error) throw new Error('Traefik rejected the managed router or service.');
    } catch (error) {
      if (error.message === 'Traefik rejected the managed router or service.') throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!valid) throw new Error(`Traefik did not load the managed route within six seconds: ${output}`);
  if (output.split('\n').some(line => { try { return JSON.parse(line).level === 'error'; } catch { return false; } })) {
    throw new Error(`Traefik reported configuration errors: ${output}`);
  }
  console.log('Traefik loaded the managed router and service successfully.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (child && !childExited && !spawnError) {
    child.kill('SIGTERM');
    let graceTimer;
    await Promise.race([childExit, new Promise(resolve => { graceTimer = setTimeout(resolve, 3000); })]);
    clearTimeout(graceTimer);
    if (!childExited) {
      child.kill('SIGKILL');
      await childExit;
    }
  }
  await rm(directory, { recursive: true, force: true });
}
