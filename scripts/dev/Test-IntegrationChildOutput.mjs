#!/usr/bin/env node
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFileSync } from 'node:fs';
import { PassThrough } from 'node:stream';
import vm from 'node:vm';

const source = readFileSync(new URL('./test-real-nextjs-integration.mjs', import.meta.url), 'utf8');
function extractFunction(name, nextFunction) {
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf(`\n${nextFunction}`, start);
  assert.ok(start >= 0 && end > start, `Cannot locate integration function ${name}.`);
  return source.slice(start, end);
}
const functions = [
  extractFunction('getUnixPrimaryGroup', 'async function restoreTestDirectoryOwnership('),
  extractFunction('getApacheBuiltInModules', 'function apacheLoadModuleDirective(')
].join('\n');

function fixture() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const calls = [];
  const context = vm.createContext({
    spawn: (...args) => { calls.push(args); return child; },
    repoRoot: '/integration-fixture',
    process: { env: {}, stderr: new PassThrough() }
  });
  vm.runInContext(functions, context);
  return { child, calls, context };
}

// Reproduce the actual race deterministically: exit arrives before pipe data.
// Attach rejection handlers immediately so the old implementation fails cleanly.
{
  const { child, calls, context } = fixture();
  let settled = false;
  const result = context.getUnixPrimaryGroup('runner').then(
    value => { settled = true; return { value }; },
    error => { settled = true; return { error }; }
  );
  child.emit('exit', 0);
  await Promise.resolve();
  assert.equal(settled, false, 'Group lookup must wait for stdout after process exit.');
  child.stdout.write('sta');
  child.stdout.end('ff\n');
  child.stderr.end();
  child.emit('close', 0);
  const outcome = await result;
  assert.ifError(outcome.error);
  assert.equal(outcome.value, 'staff');
  assert.deepEqual(Array.from(calls[0][1]), ['-gn', 'runner']);
}
{
  const { child, context } = fixture();
  const result = context.getUnixPrimaryGroup('missing');
  const rejected = assert.rejects(result, /id exited with 1/);
  child.stdout.end(); child.stderr.end(); child.emit('close', 1);
  await rejected;
}
{
  const { child, context } = fixture();
  const result = context.getUnixPrimaryGroup();
  const rejected = assert.rejects(result, /id exited with 0/);
  child.stdout.end(); child.stderr.end(); child.emit('close', 0);
  await rejected;
}
for (const functionName of ['getUnixPrimaryGroup', 'getApacheBuiltInModules']) {
  const { child, context } = fixture();
  const result = context[functionName]('missing-executable');
  const rejected = assert.rejects(result, /spawn unavailable/);
  child.emit('error', new Error('spawn unavailable'));
  child.stdout.end(); child.stderr.end(); child.emit('close', -2);
  await rejected;
}
{
  const { child, context } = fixture();
  let settled = false;
  const result = context.getApacheBuiltInModules('httpd').then(
    value => { settled = true; return { value }; },
    error => { settled = true; return { error }; }
  );
  child.emit('exit', 0);
  await Promise.resolve();
  assert.equal(settled, false, 'Apache module lookup must wait for stdout after process exit.');
  child.stdout.write('Compiled in modules:\n  mod_');
  child.stdout.end('core.c\n  mod_so.c\n');
  child.stderr.end(); child.emit('close', 0);
  const outcome = await result;
  assert.ifError(outcome.error);
  assert.deepEqual([...outcome.value], ['core', 'so']);
}
{
  const { child, context } = fixture();
  const result = context.getApacheBuiltInModules('httpd');
  const rejected = assert.rejects(result, /exit code 7: delayed diagnostic/);
  child.emit('exit', 7);
  child.stderr.end('delayed diagnostic\n');
  child.stdout.end(); child.emit('close', 7);
  await rejected;
}
console.log('Integration child output waits for complete stdout/stderr and preserves command failures.');
