#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const expectedModes = ['standalone', 'next-start'];
const serviceManagers = new Set(['direct', 'winsw', 'nssm', 'systemd', 'systemv', 'openrc', 'launchd']);
const reverseProxies = new Set(['none', 'iis', 'apache', 'nginx', 'haproxy', 'traefik']);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertString(value, label) {
  assert(typeof value === 'string' && value.trim() !== '', `${label} must be a non-empty string.`);
}

function assertIsoTimestamp(value, label) {
  assertString(value, label);
  assert(!Number.isNaN(Date.parse(value)), `${label} must be an ISO-8601 timestamp.`);
}

function assertModes(value, label) {
  assert(Array.isArray(value), `${label} must be an array.`);
  assert(JSON.stringify(value) === JSON.stringify(expectedModes), `${label} must equal standalone and next-start in order.`);
}

function assertEmptyModes(value, label) {
  assert(Array.isArray(value) && value.length === 0, `${label} must be empty for a failed run.`);
}

export function validateIntegrationResult(result) {
  assert(isRecord(result), 'Integration result must be a JSON object.');
  assert(result.schemaVersion === 1, 'schemaVersion must be 1.');
  assert(result.kind === 'hosted-nextjs-integration', 'kind must be hosted-nextjs-integration.');
  assert(['passed', 'failed'].includes(result.status), 'status must be passed or failed.');
  assertIsoTimestamp(result.startedAt, 'startedAt');
  assertIsoTimestamp(result.completedAt, 'completedAt');
  assert(Date.parse(result.completedAt) >= Date.parse(result.startedAt), 'completedAt must not be before startedAt.');

  assert(isRecord(result.platform), 'platform must be an object.');
  assertString(result.platform.os, 'platform.os');
  assertString(result.platform.arch, 'platform.arch');
  assertString(result.platform.release, 'platform.release');
  assert(isRecord(result.platform.identity), 'platform.identity must be an object.');
  assert(['windows', 'linux', 'macos', 'freebsd', 'openbsd', 'netbsd', 'unknown'].includes(result.platform.identity.family), 'platform.identity.family is invalid.');
  for (const key of ['id', 'version', 'variant']) {
    assert(result.platform.identity[key] === null || typeof result.platform.identity[key] === 'string', `platform.identity.${key} must be a string or null.`);
  }

  assert(isRecord(result.node), 'node must be an object.');
  assert(/^v\d+\.\d+\.\d+/.test(result.node.version || ''), 'node.version must be a Node.js version.');

  assert(isRecord(result.nextJs), 'nextJs must be an object.');
  assertString(result.nextJs.requestedVersion, 'nextJs.requestedVersion');
  assertModes(result.nextJs.expectedModes, 'nextJs.expectedModes');
  if (result.status === 'passed') {
    assertString(result.nextJs.installedVersion, 'nextJs.installedVersion');
    assertModes(result.nextJs.verifiedModes, 'nextJs.verifiedModes');
  } else {
    assert(result.nextJs.installedVersion === null || typeof result.nextJs.installedVersion === 'string', 'nextJs.installedVersion must be a string or null.');
    assertEmptyModes(result.nextJs.verifiedModes, 'nextJs.verifiedModes');
  }

  assert(isRecord(result.verification), 'verification must be an object.');
  assert(serviceManagers.has(result.verification.serviceManager), 'verification.serviceManager is not supported.');
  assert(reverseProxies.has(result.verification.reverseProxy), 'verification.reverseProxy is not supported.');
  for (const key of ['packageImport', 'loopbackHttp', 'forwardedHeaders']) {
    assert(typeof result.verification[key] === 'boolean', `verification.${key} must be boolean.`);
    assert(result.verification[key] === (result.status === 'passed'), `verification.${key} must match the overall result status.`);
  }

  assert(isRecord(result.execution), 'execution must be an object.');
  assert(['native', 'container'].includes(result.execution.kind), 'execution.kind must be native or container.');
  assert(result.execution.target === null || /^[a-z0-9][a-z0-9-]*$/.test(result.execution.target), 'execution.target must be null or a normalized target identifier.');
  assert(['local', 'github-hosted', 'self-hosted'].includes(result.execution.runnerEnvironment), 'execution.runnerEnvironment must be local, github-hosted, or self-hosted.');

  assert(isRecord(result.ci), 'ci must be an object.');
  assert(['local', 'github-actions'].includes(result.ci.provider), 'ci.provider must be local or github-actions.');
  for (const key of ['workflow', 'job', 'runId', 'runAttempt', 'sha']) {
    assert(result.ci[key] === null || typeof result.ci[key] === 'string', `ci.${key} must be a string or null.`);
  }
  if (result.ci.provider === 'github-actions') {
    for (const key of ['workflow', 'job', 'runId', 'runAttempt', 'sha']) {
      assertString(result.ci[key], `ci.${key}`);
    }
    assert(/^\d+$/.test(result.ci.runId), 'ci.runId must be a GitHub Actions numeric run ID.');
    assert(/^[1-9]\d*$/.test(result.ci.runAttempt), 'ci.runAttempt must be a positive GitHub Actions attempt number.');
    assert(/^[0-9a-f]{40}$/i.test(result.ci.sha), 'ci.sha must be a 40-character Git commit SHA.');
  }
}

function createSelfTestResult(status) {
  const passed = status === 'passed';
  return {
    schemaVersion: 1,
    kind: 'hosted-nextjs-integration',
    status,
    startedAt: '2026-01-01T00:00:00.000Z',
    completedAt: '2026-01-01T00:01:00.000Z',
    platform: { os: 'linux', arch: 'x64', release: '6.8.0', identity: { family: 'linux', id: 'ubuntu', version: '24.04', variant: null } },
    node: { version: 'v24.17.0' },
    nextJs: {
      requestedVersion: 'latest',
      installedVersion: passed ? '16.2.10' : null,
      expectedModes: [...expectedModes],
      verifiedModes: passed ? [...expectedModes] : []
    },
    verification: {
      serviceManager: 'systemd',
      reverseProxy: 'nginx',
      packageImport: passed,
      loopbackHttp: passed,
      forwardedHeaders: passed
    },
    execution: { kind: 'container', target: 'ubuntu', runnerEnvironment: 'github-hosted' },
    ci: { provider: 'github-actions', workflow: 'ci', job: 'real-nextjs-integration', runId: '123', runAttempt: '1', sha: 'a'.repeat(40) }
  };
}

const isMainModule = process.argv[1]
  && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMainModule) {
  if (process.argv.includes('--self-test')) {
    validateIntegrationResult(createSelfTestResult('passed'));
    validateIntegrationResult(createSelfTestResult('failed'));
    const malformed = createSelfTestResult('failed');
    malformed.verification.loopbackHttp = true;
    try {
      validateIntegrationResult(malformed);
      throw new Error('Self-test accepted a failed result that claimed a completed check.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const malformedSha = createSelfTestResult('passed');
    malformedSha.ci.sha = 'not-a-commit';
    try {
      validateIntegrationResult(malformedSha);
      throw new Error('Self-test accepted an invalid Git commit SHA.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    console.log('Next.js integration result validator OK');
  } else {
    const resultPath = process.argv[2];
    if (!resultPath) {
      throw new Error('Usage: node scripts/dev/Test-NextJsIntegrationResult.mjs <result.json> | --self-test');
    }
    const parsed = JSON.parse(await readFile(resultPath, 'utf8'));
    validateIntegrationResult(parsed);
    console.log(`Next.js integration result OK: ${resultPath}`);
  }
}
