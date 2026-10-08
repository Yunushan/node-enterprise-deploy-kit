import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const scanner = process.argv[2];
assert(scanner, 'Pass the checksum-verified Gitleaks executable.');
const fixture = await fs.mkdtemp(path.join(os.tmpdir(), 'kit-secret-policy-'));
const knownFixture = Buffer.from('0123456789abcdef0123456789abcdef').toString('base64');
function scan() {
  const result = spawnSync(scanner, ['dir', '--config', path.join(repo, '.gitleaks.toml'), '--no-banner', '--redact=100', fixture], { encoding: 'utf8' });
  if (result.error) throw result.error;
  return result;
}
try {
  const fixtureFile = path.join(fixture, 'scripts/dev/Test-NextJsSupport.ps1');
  await fs.mkdir(path.dirname(fixtureFile), { recursive: true });
  await fs.writeFile(fixtureFile, `ServerActionsEncryptionKey = "${knownFixture}"\n`);
  assert.equal(scan().status, 0, 'Known deterministic fixture should be allowed in its reviewed file.');
  await fs.appendFile(fixtureFile, `api_key = "${crypto.randomBytes(32).toString('hex')}"\n`);
  assert.equal(scan().status, 1, 'A different key in the fixture file must remain detectable.');
  await fs.rm(fixtureFile);
  await fs.writeFile(path.join(fixture, 'application.env'), `ServerActionsEncryptionKey = "${knownFixture}"\n`);
  assert.equal(scan().status, 1, 'The deterministic key must remain detectable outside its reviewed test file.');
  console.log('Secret scanner allowlist is limited to the exact deterministic test fixture.');
} finally {
  assert(path.resolve(fixture).startsWith(path.resolve(os.tmpdir()) + path.sep), 'Refusing cleanup outside temporary directory.');
  await fs.rm(fixture, { recursive: true, force: true });
}
