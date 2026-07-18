#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateIntegrationResult } from './Test-NextJsIntegrationResult.mjs';

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function parseArguments(args) {
  const values = {};
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--self-test') {
      values.selfTest = true;
    } else if (['--result', '--target', '--manager', '--proxy', '--sha', '--workflow', '--job', '--run-id', '--run-attempt'].includes(argument)) {
      const key = argument === '--run-id'
        ? 'runId'
        : argument === '--run-attempt'
          ? 'runAttempt'
          : argument.slice(2);
      values[key] = args[++index] || '';
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return values;
}

export function validateHostIntegrationResult(result, expected) {
  validateIntegrationResult(result);
  assert(result.status === 'passed', 'Self-hosted integration result must have passed.');
  assert(result.execution.kind === 'native', 'Self-hosted integration result must use native execution.');
  assert(result.execution.runnerEnvironment === 'self-hosted', 'Self-hosted integration result must retain self-hosted runner provenance.');
  assert(result.execution.target === expected.target, 'Self-hosted integration result target does not match the dispatch target.');
  assert(result.verification.serviceManager === expected.manager, 'Self-hosted integration result service manager does not match the dispatch manager.');
  assert(result.verification.reverseProxy === expected.proxy, 'Self-hosted integration result reverse proxy does not match the dispatch proxy.');
  assert(result.ci.provider === 'github-actions', 'Self-hosted integration result must retain GitHub Actions provenance.');
  if (expected.sha) {
    assert(result.ci.sha.toLowerCase() === expected.sha.toLowerCase(), 'Self-hosted integration result commit SHA does not match the assessed commit.');
  }
  if (expected.workflow) {
    assert(result.ci.workflow === expected.workflow, 'Self-hosted integration result workflow does not match the collecting workflow.');
  }
  if (expected.job) {
    assert(result.ci.job === expected.job, 'Self-hosted integration result job does not match the collecting job.');
  }
  if (expected.runId) {
    assert(result.ci.runId === expected.runId, 'Self-hosted integration result run ID does not match the collecting workflow run.');
  }
  if (expected.runAttempt) {
    assert(result.ci.runAttempt === expected.runAttempt, 'Self-hosted integration result run attempt does not match the collecting workflow attempt.');
  }
  const expectedOs = ['winsw', 'nssm'].includes(expected.manager) ? 'win32' : expected.manager === 'launchd' ? 'darwin' : 'linux';
  assert(result.platform.os === expectedOs, `Self-hosted integration result platform must be ${expectedOs}.`);
  const identity = result.platform.identity;
  assert(identity && typeof identity === 'object', 'Self-hosted integration result must include platform identity.');
  const id = (identity.id || '').toLowerCase();
  const variant = (identity.variant || '').toLowerCase();
  if (expected.target === 'macos') {
    assert(identity.family === 'macos' && id === 'macos', 'Self-hosted macOS result identity is invalid.');
  } else if (expected.target.startsWith('windows-server-')) {
    const version = expected.target.slice('windows-server-'.length).replace(/-/g, ' ');
    assert(identity.family === 'windows' && id.includes('windows server') && id.includes(version), 'Self-hosted Windows Server result identity is invalid.');
  } else if (expected.target === 'windows-10' || expected.target === 'windows-11') {
    const version = expected.target.slice('windows-'.length);
    assert(identity.family === 'windows' && id.includes(`windows ${version}`) && !id.includes('server'), 'Self-hosted Windows client result identity is invalid.');
  } else if (expected.target === 'centos-stream') {
    assert(identity.family === 'linux' && (id === 'centos-stream' || (id === 'centos' && variant.includes('stream'))), 'Self-hosted CentOS Stream result identity is invalid.');
  } else {
    const linuxIds = { ubuntu: ['ubuntu'], debian: ['debian'], 'linux-mint': ['linuxmint'], rhel: ['rhel'], 'oracle-linux': ['ol', 'oracle'], centos: ['centos'], rocky: ['rocky'], almalinux: ['almalinux'], fedora: ['fedora'], alpine: ['alpine'] };
    assert(linuxIds[expected.target], `Self-hosted result target has no identity rule: ${expected.target}.`);
    assert(identity.family === 'linux' && linuxIds[expected.target].includes(id), `Self-hosted ${expected.target} result identity is invalid.`);
  }
}

function selfTestResult() {
  return {
    schemaVersion: 1,
    kind: 'hosted-nextjs-integration',
    status: 'passed',
    startedAt: '2026-01-01T00:00:00.000Z',
    completedAt: '2026-01-01T00:01:00.000Z',
    platform: { os: 'linux', arch: 'x64', release: '6.8.0', identity: { family: 'linux', id: 'ubuntu', version: '24.04', variant: null } },
    node: { version: 'v24.17.0' },
    nextJs: { requestedVersion: 'latest', installedVersion: '16.2.10', expectedModes: ['standalone', 'next-start'], verifiedModes: ['standalone', 'next-start'] },
    verification: { serviceManager: 'systemd', reverseProxy: 'nginx', packageImport: true, loopbackHttp: true, forwardedHeaders: true },
    execution: { kind: 'native', target: 'ubuntu', runnerEnvironment: 'self-hosted' },
    ci: { provider: 'github-actions', workflow: 'Next.js Self-Hosted Integration', job: 'collect', runId: '123', runAttempt: '1', sha: 'a'.repeat(40) }
  };
}

const isMainModule = process.argv[1]
  && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMainModule) {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    const result = selfTestResult();
    validateHostIntegrationResult(result, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', sha: 'a'.repeat(40), workflow: 'Next.js Self-Hosted Integration', job: 'collect', runId: '123', runAttempt: '1' });
    result.execution.target = 'debian';
    try {
      validateHostIntegrationResult(result, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx' });
      throw new Error('Self-test accepted a mismatched target.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongIdentity = selfTestResult();
    wrongIdentity.platform.identity.id = 'fedora';
    try {
      validateHostIntegrationResult(wrongIdentity, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx' });
      throw new Error('Self-test accepted a mismatched platform identity.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongSha = selfTestResult();
    wrongSha.ci.sha = 'b'.repeat(40);
    try {
      validateHostIntegrationResult(wrongSha, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', sha: 'a'.repeat(40) });
      throw new Error('Self-test accepted a mismatched commit SHA.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongWorkflow = selfTestResult();
    wrongWorkflow.ci.workflow = 'another-workflow';
    try {
      validateHostIntegrationResult(wrongWorkflow, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', workflow: 'Next.js Self-Hosted Integration' });
      throw new Error('Self-test accepted a mismatched collecting workflow.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongJob = selfTestResult();
    wrongJob.ci.job = 'another-job';
    try {
      validateHostIntegrationResult(wrongJob, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', job: 'collect' });
      throw new Error('Self-test accepted a mismatched collecting job.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongRunId = selfTestResult();
    wrongRunId.ci.runId = '124';
    try {
      validateHostIntegrationResult(wrongRunId, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', runId: '123' });
      throw new Error('Self-test accepted a mismatched collecting workflow run ID.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    const wrongRunAttempt = selfTestResult();
    wrongRunAttempt.ci.runAttempt = '2';
    try {
      validateHostIntegrationResult(wrongRunAttempt, { target: 'ubuntu', manager: 'systemd', proxy: 'nginx', runAttempt: '1' });
      throw new Error('Self-test accepted a mismatched collecting workflow run attempt.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
    console.log('Next.js host integration result validator OK');
  } else {
    for (const key of ['result', 'target', 'manager', 'proxy', 'sha', 'workflow', 'job', 'runId', 'runAttempt']) {
      assert(typeof options[key] === 'string' && options[key], `--${key} is required.`);
    }
    const result = JSON.parse(await readFile(options.result, 'utf8'));
    validateHostIntegrationResult(result, options);
    console.log(`Next.js host integration result OK: ${options.result}`);
  }
}
