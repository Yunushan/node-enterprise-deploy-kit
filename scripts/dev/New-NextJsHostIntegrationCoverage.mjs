#!/usr/bin/env node

import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { validateIntegrationResult } from './Test-NextJsIntegrationResult.mjs';
import { validateHostIntegrationResult } from './Test-NextJsHostIntegrationResult.mjs';

const hostIntegrationWorkflow = 'Next.js Self-Hosted Integration';
const hostIntegrationJob = 'collect';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseArguments(args) {
  const values = { planPath: '', inputPath: '', outputPath: '', summaryPath: '', sha: '', runIds: '' };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--plan') values.planPath = args[++index] || '';
    else if (argument === '--input') values.inputPath = args[++index] || '';
    else if (argument === '--output') values.outputPath = args[++index] || '';
    else if (argument === '--sha') values.sha = args[++index] || '';
    else if (argument === '--run-ids') values.runIds = args[++index] || '';
    else if (argument === '--validate-summary') values.summaryPath = args[++index] || '';
    else if (argument === '--self-test') values.selfTest = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return values;
}

function assertCommitSha(value, label) {
  assert(typeof value === 'string' && /^[0-9a-f]{40}$/i.test(value), `${label} must be a 40-character Git commit SHA.`);
}

function assertNonNegativeInteger(value, label) {
  assert(Number.isInteger(value) && value >= 0, `${label} must be a non-negative integer.`);
}

function parseRunIds(value, label) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`${label} must be a JSON array of GitHub Actions run IDs.`);
  }
  assert(Array.isArray(parsed) && parsed.length > 0, `${label} must be a non-empty JSON array of GitHub Actions run IDs.`);
  const ids = parsed.map((entry) => String(entry));
  for (const id of ids) {
    assert(/^\d+$/.test(id) && Number(id) > 0, `${label} must contain only positive GitHub Actions run IDs.`);
  }
  assert(new Set(ids).size === ids.length, `${label} must not contain duplicate GitHub Actions run IDs.`);
  return ids;
}

function keyFor(target, manager, proxy) {
  return `${target}/${manager}/${proxy}`;
}

function validatePlan(plan) {
  assert(plan && typeof plan === 'object' && !Array.isArray(plan), 'Integration plan must be a JSON object.');
  assert(plan.schemaVersion === 1, 'Integration plan schemaVersion must be 1.');
  assert(plan.kind === 'nextjs-self-hosted-integration-plan', 'Integration plan kind is invalid.');
  assert(Array.isArray(plan.dispatches) && plan.dispatches.length > 0, 'Integration plan must contain dispatches.');
  const expected = new Map();
  for (const dispatch of plan.dispatches) {
    assert(dispatch && typeof dispatch === 'object', 'Integration plan dispatch must be an object.');
    const target = dispatch.targetId;
    const manager = dispatch.serviceManager;
    const proxy = dispatch.reverseProxy;
    for (const [name, value] of Object.entries({ target, manager, proxy })) {
      assert(typeof value === 'string' && /^[a-z0-9][a-z0-9-]*$/.test(value), `Integration plan dispatch ${name} is invalid.`);
    }
    assert(JSON.stringify(dispatch.requiredModes) === JSON.stringify(['standalone', 'next-start']), 'Integration plan dispatch must require standalone and next-start.');
    const key = keyFor(target, manager, proxy);
    assert(!expected.has(key), `Integration plan contains duplicate dispatch: ${key}`);
    expected.set(key, { target, manager, proxy });
  }
  return expected;
}

async function findJsonFiles(directory) {
  try {
    const entries = await readdir(directory, { withFileTypes: true });
    const nested = await Promise.all(entries.map(async (entry) => {
      const filePath = path.join(directory, entry.name);
      if (entry.isDirectory()) return findJsonFiles(filePath);
      return entry.isFile() && entry.name.endsWith('.json') ? [filePath] : [];
    }));
    return nested.flat();
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

function createMarkdown(summary) {
  const lines = [
    '# Self-Hosted Next.js Integration Coverage',
    '',
    'This summary verifies safe native self-hosted integration results against a matrix-derived dispatch plan. It is not deployed-application status evidence and does not establish a release support claim.',
    '',
    `- Expected dispatches: ${summary.expectedCount}`,
    `- Passed dispatches: ${summary.passedCount}`,
    `- Missing dispatches: ${summary.missingCount}`,
    `- Invalid artifacts: ${summary.invalidCount}`,
    `- Duplicate artifacts: ${summary.duplicateCount}`,
    `- Unexpected artifacts: ${summary.unexpectedCount}`,
    `- Assessed commit: ${summary.expectedSha}`,
    `- Complete: ${summary.complete}`,
    ''
  ];
  if (summary.passed.length > 0) {
    lines.push('## Passed', '', '| Target | Service | Proxy | Platform | Node | Next.js | Source Run |', '| --- | --- | --- | --- | --- | --- | --- |');
    for (const record of summary.passed) {
      lines.push(`| ${record.target} | ${record.manager} | ${record.proxy} | ${record.platform} | ${record.nodeVersion} | ${record.nextVersion} | ${record.runId}/${record.runAttempt} |`);
    }
    lines.push('');
  }
  for (const [title, values] of [['Missing', summary.missing], ['Invalid Artifacts', summary.invalid], ['Duplicate Artifacts', summary.duplicates], ['Unexpected Artifacts', summary.unexpected]]) {
    if (values.length > 0) {
      lines.push(`## ${title}`, '');
      for (const value of values) lines.push(`- ${typeof value === 'string' ? `\`${value}\`` : `\`${value.name}\`: ${value.error}`}`);
      lines.push('');
    }
  }
  return `${lines.join('\n')}\n`;
}

export async function buildCoverage(planPath, inputPath, expectedSha, sourceRunIdsJson) {
  assertCommitSha(expectedSha, 'Expected commit SHA');
  const sourceRunIds = parseRunIds(sourceRunIdsJson, 'Source run IDs');
  const sourceRunIdSet = new Set(sourceRunIds);
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  const expected = validatePlan(plan);
  const passed = [];
  const invalid = [];
  const duplicates = [];
  const unexpected = [];
  const seen = new Set();
  for (const filePath of (await findJsonFiles(inputPath)).sort()) {
    try {
      const result = JSON.parse(await readFile(filePath, 'utf8'));
      validateIntegrationResult(result);
      const target = result.execution.target;
      const manager = result.verification.serviceManager;
      const proxy = result.verification.reverseProxy;
      const key = keyFor(target, manager, proxy);
      const expectation = expected.get(key);
      if (!expectation) {
        unexpected.push({ name: path.basename(filePath), error: `No planned dispatch matches ${key}.` });
        continue;
      }
      validateHostIntegrationResult(result, {
        ...expectation,
        sha: expectedSha,
        workflow: hostIntegrationWorkflow,
        job: hostIntegrationJob
      });
      assert(sourceRunIdSet.has(result.ci.runId), `Result run ID ${result.ci.runId} is not in the selected source run IDs.`);
      if (seen.has(key)) {
        duplicates.push({ name: path.basename(filePath), error: `Duplicate result for ${key}.` });
        continue;
      }
      seen.add(key);
      passed.push({
        target,
        manager,
        proxy,
        platform: `${result.platform.os}/${result.platform.arch}`,
        nodeVersion: result.node.version,
        nextVersion: result.nextJs.installedVersion,
        runId: result.ci.runId,
        runAttempt: result.ci.runAttempt
      });
    } catch (error) {
      invalid.push({ name: path.basename(filePath), error: error.message });
    }
  }
  const missing = [...expected.keys()].filter((key) => !seen.has(key)).sort();
  passed.sort((left, right) => keyFor(left.target, left.manager, left.proxy).localeCompare(keyFor(right.target, right.manager, right.proxy)));
  const summary = {
    schemaVersion: 1,
    kind: 'nextjs-self-hosted-integration-coverage',
    generatedAt: new Date().toISOString(),
    expectedSha: expectedSha.toLowerCase(),
    sourceWorkflow: hostIntegrationWorkflow,
    sourceJob: hostIntegrationJob,
    sourceRunIds: [...sourceRunIds].sort((left, right) => Number(left) - Number(right)),
    expectedCount: expected.size,
    passedCount: passed.length,
    missingCount: missing.length,
    invalidCount: invalid.length,
    duplicateCount: duplicates.length,
    unexpectedCount: unexpected.length,
    complete: missing.length === 0 && invalid.length === 0 && duplicates.length === 0 && unexpected.length === 0,
    passed,
    missing,
    invalid,
    duplicates,
    unexpected
  };
  return summary;
}

export function validateCoverageSummary(summary, expectedSha) {
  assert(summary && typeof summary === 'object' && !Array.isArray(summary), 'Coverage summary must be a JSON object.');
  assert(summary.schemaVersion === 1 && summary.kind === 'nextjs-self-hosted-integration-coverage', 'Coverage summary schema is invalid.');
  assert(typeof summary.generatedAt === 'string' && !Number.isNaN(Date.parse(summary.generatedAt)), 'Coverage summary generatedAt must be an ISO-8601 timestamp.');
  assertCommitSha(summary.expectedSha, 'Coverage summary expectedSha');
  assert(summary.sourceWorkflow === hostIntegrationWorkflow, 'Coverage summary sourceWorkflow is invalid.');
  assert(summary.sourceJob === hostIntegrationJob, 'Coverage summary sourceJob is invalid.');
  const sourceRunIds = parseRunIds(JSON.stringify(summary.sourceRunIds), 'Coverage summary sourceRunIds');
  const sourceRunIdSet = new Set(sourceRunIds);
  if (expectedSha) {
    assertCommitSha(expectedSha, 'Expected commit SHA');
    assert(summary.expectedSha.toLowerCase() === expectedSha.toLowerCase(), 'Coverage summary commit SHA does not match the assessed commit.');
  }
  for (const key of ['expectedCount', 'passedCount', 'missingCount', 'invalidCount', 'duplicateCount', 'unexpectedCount']) {
    assertNonNegativeInteger(summary[key], `Coverage summary ${key}`);
  }
  for (const key of ['passed', 'missing', 'invalid', 'duplicates', 'unexpected']) {
    assert(Array.isArray(summary[key]), `Coverage summary ${key} must be an array.`);
  }
  assert(summary.passedCount === summary.passed.length, 'Coverage summary passedCount does not match passed records.');
  assert(summary.missingCount === summary.missing.length, 'Coverage summary missingCount does not match missing records.');
  assert(summary.invalidCount === summary.invalid.length, 'Coverage summary invalidCount does not match invalid records.');
  assert(summary.duplicateCount === summary.duplicates.length, 'Coverage summary duplicateCount does not match duplicate records.');
  assert(summary.unexpectedCount === summary.unexpected.length, 'Coverage summary unexpectedCount does not match unexpected records.');
  assert(summary.expectedCount === summary.passedCount + summary.missingCount, 'Coverage summary expectedCount does not equal passed plus missing dispatches.');
  const passedKeys = new Set();
  for (const record of summary.passed) {
    assert(record && typeof record === 'object' && !Array.isArray(record), 'Coverage summary passed record must be an object.');
    for (const key of ['target', 'manager', 'proxy']) {
      assert(typeof record[key] === 'string' && /^[a-z0-9][a-z0-9-]*$/.test(record[key]), `Coverage summary passed record ${key} is invalid.`);
    }
    assert(typeof record.platform === 'string' && record.platform.trim(), 'Coverage summary passed record platform is required.');
    assert(typeof record.nodeVersion === 'string' && /^v\d+\.\d+\.\d+/.test(record.nodeVersion), 'Coverage summary passed record nodeVersion is invalid.');
    assert(typeof record.nextVersion === 'string' && record.nextVersion.trim(), 'Coverage summary passed record nextVersion is required.');
    assert(typeof record.runId === 'string' && /^\d+$/.test(record.runId), 'Coverage summary passed record runId is invalid.');
    assert(typeof record.runAttempt === 'string' && /^[1-9]\d*$/.test(record.runAttempt), 'Coverage summary passed record runAttempt is invalid.');
    assert(sourceRunIdSet.has(record.runId), 'Coverage summary passed record runId is not selected as a source run.');
    const key = keyFor(record.target, record.manager, record.proxy);
    assert(!passedKeys.has(key), `Coverage summary contains duplicate passed dispatch: ${key}.`);
    passedKeys.add(key);
  }
  const recomputedComplete = summary.missingCount === 0 && summary.invalidCount === 0 && summary.duplicateCount === 0 && summary.unexpectedCount === 0;
  assert(summary.complete === recomputedComplete, 'Coverage summary complete flag does not match its recorded coverage state.');
  assert(summary.complete === true, 'Self-hosted Next.js integration coverage is incomplete.');
  console.log('Self-hosted Next.js integration coverage OK');
}

function selfTestPlan() {
  return {
    schemaVersion: 1,
    kind: 'nextjs-self-hosted-integration-plan',
    dispatches: [
      { targetId: 'ubuntu', serviceManager: 'systemd', reverseProxy: 'nginx', requiredModes: ['standalone', 'next-start'] },
      { targetId: 'windows-server-2022', serviceManager: 'winsw', reverseProxy: 'iis', requiredModes: ['standalone', 'next-start'] }
    ]
  };
}

function selfTestResult(target, manager, proxy, platform) {
  const identity = platform === 'win32'
    ? { family: 'windows', id: 'windows server 2022', version: '10.0.20348', variant: null }
    : platform === 'darwin'
      ? { family: 'macos', id: 'macos', version: '24.0.0', variant: null }
      : { family: 'linux', id: target === 'macos' ? 'ubuntu' : target, version: 'test', variant: target === 'centos-stream' ? 'stream' : null };
  return {
    schemaVersion: 1,
    kind: 'hosted-nextjs-integration',
    status: 'passed',
    startedAt: '2026-01-01T00:00:00.000Z',
    completedAt: '2026-01-01T00:01:00.000Z',
    platform: { os: platform, arch: 'x64', release: 'test', identity },
    node: { version: 'v24.17.0' },
    nextJs: { requestedVersion: 'latest', installedVersion: '16.2.10', expectedModes: ['standalone', 'next-start'], verifiedModes: ['standalone', 'next-start'] },
    verification: { serviceManager: manager, reverseProxy: proxy, packageImport: true, loopbackHttp: true, forwardedHeaders: true },
    execution: { kind: 'native', target, runnerEnvironment: 'self-hosted' },
    ci: { provider: 'github-actions', workflow: hostIntegrationWorkflow, job: hostIntegrationJob, runId: '123', runAttempt: '1', sha: 'a'.repeat(40) }
  };
}

async function runSelfTest() {
  const expectedSha = 'a'.repeat(40);
  const root = await mkdtemp(path.join(os.tmpdir(), 'nextjs-host-integration-coverage-'));
  const inputPath = path.join(root, 'input');
  const planPath = path.join(root, 'plan.json');
  try {
    await mkdir(inputPath);
    await writeFile(planPath, JSON.stringify(selfTestPlan()));
    await writeFile(path.join(inputPath, 'ubuntu.json'), JSON.stringify(selfTestResult('ubuntu', 'systemd', 'nginx', 'linux')));
    await writeFile(path.join(inputPath, 'unexpected.json'), JSON.stringify(selfTestResult('macos', 'launchd', 'none', 'darwin')));
    await writeFile(path.join(inputPath, 'invalid.json'), '{invalid json');
    const partial = await buildCoverage(planPath, inputPath, expectedSha, '["123"]');
    assert(partial.passedCount === 1 && partial.missingCount === 1, 'Coverage self-test did not detect missing planned coverage.');
    assert(partial.invalidCount === 1 && partial.unexpectedCount === 1 && partial.complete === false, 'Coverage self-test did not retain invalid or unexpected artifacts.');
    await rm(inputPath, { recursive: true, force: true });
    await mkdir(inputPath);
    await writeFile(path.join(inputPath, 'ubuntu.json'), JSON.stringify(selfTestResult('ubuntu', 'systemd', 'nginx', 'linux')));
    await writeFile(path.join(inputPath, 'windows.json'), JSON.stringify(selfTestResult('windows-server-2022', 'winsw', 'iis', 'win32')));
    const complete = await buildCoverage(planPath, inputPath, expectedSha, '["123"]');
    assert(complete.complete === true && complete.passedCount === 2, 'Coverage self-test did not recognize complete planned coverage.');
    assert(complete.passed.every((record) => record.runId === '123' && record.runAttempt === '1'), 'Coverage self-test did not retain source run provenance.');
    const wrongWorkflow = selfTestResult('ubuntu', 'systemd', 'nginx', 'linux');
    wrongWorkflow.ci.workflow = 'another-workflow';
    await writeFile(path.join(inputPath, 'wrong-workflow.json'), JSON.stringify(wrongWorkflow));
    const rejectedWorkflow = await buildCoverage(planPath, inputPath, expectedSha, '["123"]');
    assert(rejectedWorkflow.invalidCount === 1 && rejectedWorkflow.complete === false, 'Coverage self-test accepted an artifact from another workflow.');
    validateCoverageSummary(complete, expectedSha);
    const malformedSummary = { ...complete, missingCount: 1 };
    try {
      validateCoverageSummary(malformedSummary, expectedSha);
      throw new Error('Self-test accepted inconsistent coverage summary counters.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) {
        throw error;
      }
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
  console.log('Next.js self-hosted integration coverage OK');
}

const options = parseArguments(process.argv.slice(2));
if (options.selfTest) {
  await runSelfTest();
} else if (options.summaryPath) {
  assertCommitSha(options.sha, '--sha');
  validateCoverageSummary(JSON.parse(await readFile(options.summaryPath, 'utf8')), options.sha);
} else {
  assert(options.planPath, '--plan is required.');
  assert(options.inputPath, '--input is required.');
  assert(options.outputPath, '--output is required.');
  assertCommitSha(options.sha, '--sha');
  assert(options.runIds, '--run-ids is required.');
  const summary = await buildCoverage(options.planPath, options.inputPath, options.sha, options.runIds);
  await mkdir(options.outputPath, { recursive: true });
  await writeFile(path.join(options.outputPath, 'nextjs-host-integration-coverage.json'), JSON.stringify(summary, null, 2) + '\n');
  await writeFile(path.join(options.outputPath, 'nextjs-host-integration-coverage.md'), createMarkdown(summary));
  console.log(`Next.js self-hosted integration coverage written: ${options.outputPath}`);
}
