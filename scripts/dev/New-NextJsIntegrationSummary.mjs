#!/usr/bin/env node

import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { validateIntegrationResult } from './Test-NextJsIntegrationResult.mjs';

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function parseArguments(args) {
  const values = { inputPath: '', outputPath: '', summaryPath: '' };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--input') {
      values.inputPath = args[++index] || '';
    } else if (argument === '--output') {
      values.outputPath = args[++index] || '';
    } else if (argument === '--validate-summary') {
      values.summaryPath = args[++index] || '';
    } else if (argument === '--self-test') {
      values.selfTest = true;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return values;
}

async function findJsonFiles(directory) {
  try {
    const entries = await readdir(directory, { withFileTypes: true });
    const files = await Promise.all(entries.map(async (entry) => {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        return findJsonFiles(entryPath);
      }
      return entry.isFile() && entry.name.endsWith('.json') ? [entryPath] : [];
    }));
    return files.flat();
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

function getNeedsSummary() {
  if (!process.env.NEXTJS_INTEGRATION_NEEDS_JSON) {
    return [];
  }
  try {
    const needs = JSON.parse(process.env.NEXTJS_INTEGRATION_NEEDS_JSON);
    if (!needs || typeof needs !== 'object' || Array.isArray(needs)) {
      return [];
    }
    return Object.entries(needs)
      .map(([job, value]) => ({ job, result: value && typeof value.result === 'string' ? value.result : 'unknown' }))
      .sort((left, right) => left.job.localeCompare(right.job));
  } catch {
    return [];
  }
}

function toRecord(result) {
  return {
    status: result.status,
    platform: result.platform.os,
    arch: result.platform.arch,
    execution: result.execution.kind,
    runnerEnvironment: result.execution.runnerEnvironment,
    target: result.execution.target || '-',
    serviceManager: result.verification.serviceManager,
    reverseProxy: result.verification.reverseProxy,
    job: result.ci.job || '-',
    nodeVersion: result.node.version,
    nextVersion: result.nextJs.installedVersion || '-'
  };
}

function validateHostedIntegrationResult(result) {
  validateIntegrationResult(result);
  assert(result.ci.provider === 'github-actions', 'Hosted integration summary only accepts GitHub Actions result artifacts.');
  assert(result.execution.runnerEnvironment === 'github-hosted', 'Hosted integration summary only accepts GitHub-hosted result artifacts.');
}

function findCoverageGaps(records, upstreamJobs) {
  if (upstreamJobs.length === 0) {
    return { missingSuccessfulJobs: [], unexpectedResultJobs: [] };
  }
  const observedJobs = new Set(records.map((record) => record.job).filter((job) => job !== '-'));
  const upstreamJobNames = new Set(upstreamJobs.map((job) => job.job));
  return {
    missingSuccessfulJobs: upstreamJobs
      .filter((job) => job.result === 'success' && !observedJobs.has(job.job))
      .map((job) => job.job),
    unexpectedResultJobs: [...observedJobs]
      .filter((job) => !upstreamJobNames.has(job))
      .sort()
  };
}

function createMarkdown(summary) {
  const lines = [
    '# Hosted Next.js Integration Summary',
    '',
    'This summarizes observed GitHub-hosted integration artifacts. It is not self-hosted deployment evidence and does not establish a release support claim.',
    '',
    `- Observed result artifacts: ${summary.observedResultCount}`,
    `- Passed: ${summary.passedCount}`,
    `- Failed: ${summary.failedCount}`,
    `- Invalid: ${summary.invalidCount}`,
    `- Missing results from successful jobs: ${summary.missingSuccessfulJobs.length}`,
    ''
  ];

  if (summary.records.length > 0) {
    lines.push('| Status | Platform | Execution | Runner | Target | Job | Service | Proxy | Node | Next.js |');
    lines.push('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
    for (const record of summary.records) {
      lines.push(`| ${record.status} | ${record.platform}/${record.arch} | ${record.execution} | ${record.runnerEnvironment} | ${record.target} | ${record.job} | ${record.serviceManager} | ${record.reverseProxy} | ${record.nodeVersion} | ${record.nextVersion} |`);
    }
    lines.push('');
  } else {
    lines.push('_No result artifacts were available. Review the upstream job outcomes below._', '');
  }

  if (summary.invalidArtifacts.length > 0) {
    lines.push('## Invalid Artifacts', '');
    for (const artifact of summary.invalidArtifacts) {
      lines.push(`- \`${artifact.name}\`: ${artifact.error}`);
    }
    lines.push('');
  }

  if (summary.missingSuccessfulJobs.length > 0) {
    lines.push('## Missing Results From Successful Jobs', '');
    for (const job of summary.missingSuccessfulJobs) {
      lines.push(`- \`${job}\``);
    }
    lines.push('');
  }

  if (summary.unexpectedResultJobs.length > 0) {
    lines.push('## Results Outside The Current Job Set', '');
    for (const job of summary.unexpectedResultJobs) {
      lines.push(`- \`${job}\``);
    }
    lines.push('');
  }

  if (summary.upstreamJobs.length > 0) {
    lines.push('## Upstream Jobs', '', '| Job | Outcome |', '| --- | --- |');
    for (const job of summary.upstreamJobs) {
      lines.push(`| ${job.job} | ${job.result} |`);
    }
    lines.push('');
  }
  return `${lines.join('\n')}\n`;
}

export async function buildSummary(inputPath) {
  const files = (await findJsonFiles(inputPath)).sort();
  const records = [];
  const invalidArtifacts = [];
  for (const filePath of files) {
    try {
      const result = JSON.parse(await readFile(filePath, 'utf8'));
      validateHostedIntegrationResult(result);
      records.push(toRecord(result));
    } catch (error) {
      invalidArtifacts.push({ name: path.basename(filePath), error: error.message });
    }
  }
  records.sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  const upstreamJobs = getNeedsSummary();
  const coverage = findCoverageGaps(records, upstreamJobs);
  return {
    schemaVersion: 1,
    kind: 'hosted-nextjs-integration-summary',
    generatedAt: new Date().toISOString(),
    observedResultCount: records.length,
    passedCount: records.filter((record) => record.status === 'passed').length,
    failedCount: records.filter((record) => record.status === 'failed').length,
    invalidCount: invalidArtifacts.length,
    records,
    invalidArtifacts,
    upstreamJobs,
    ...coverage
  };
}

async function validateSummary(summaryPath) {
  const summary = JSON.parse(await readFile(summaryPath, 'utf8'));
  assert(summary && typeof summary === 'object' && !Array.isArray(summary), 'Summary must be a JSON object.');
  assert(Array.isArray(summary.missingSuccessfulJobs), 'Summary is missing missingSuccessfulJobs.');
  if (summary.missingSuccessfulJobs.length > 0) {
    throw new Error(`Successful hosted Next.js job(s) did not upload a valid integration result: ${summary.missingSuccessfulJobs.join(', ')}`);
  }
  console.log('Hosted Next.js integration result coverage OK');
}

function selfTestResult(status) {
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
      expectedModes: ['standalone', 'next-start'],
      verifiedModes: passed ? ['standalone', 'next-start'] : []
    },
    verification: { serviceManager: 'systemd', reverseProxy: 'nginx', packageImport: passed, loopbackHttp: passed, forwardedHeaders: passed },
    execution: { kind: 'container', target: 'ubuntu', runnerEnvironment: 'github-hosted' },
    ci: { provider: 'github-actions', workflow: 'ci', job: status === 'passed' ? 'passed-job' : 'failed-job', runId: '123', runAttempt: '1', sha: 'a'.repeat(40) }
  };
}

async function runSelfTest() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'nextjs-integration-summary-'));
  const previousNeeds = process.env.NEXTJS_INTEGRATION_NEEDS_JSON;
  try {
    process.env.NEXTJS_INTEGRATION_NEEDS_JSON = JSON.stringify({
      'passed-job': { result: 'success' },
      'missing-job': { result: 'success' },
      'failed-job': { result: 'failure' }
    });
    await writeFile(path.join(root, 'passed.json'), JSON.stringify(selfTestResult('passed')));
    await writeFile(path.join(root, 'failed.json'), JSON.stringify(selfTestResult('failed')));
    await writeFile(path.join(root, 'invalid.json'), '{invalid json');
    const summary = await buildSummary(root);
    assert(summary.observedResultCount === 2, 'Summary self-test did not count valid artifacts.');
    assert(summary.passedCount === 1 && summary.failedCount === 1, 'Summary self-test did not preserve result status counts.');
    assert(summary.invalidCount === 1, 'Summary self-test did not report malformed artifacts.');
    assert(summary.missingSuccessfulJobs.length === 1 && summary.missingSuccessfulJobs[0] === 'missing-job', 'Summary self-test did not detect a missing successful job result.');
    const localResult = selfTestResult('passed');
    localResult.execution.runnerEnvironment = 'local';
    await writeFile(path.join(root, 'local.json'), JSON.stringify(localResult));
    const withLocalArtifact = await buildSummary(root);
    assert(withLocalArtifact.invalidCount === 2, 'Summary self-test accepted a local result as GitHub-hosted evidence.');
  } finally {
    if (previousNeeds === undefined) {
      delete process.env.NEXTJS_INTEGRATION_NEEDS_JSON;
    } else {
      process.env.NEXTJS_INTEGRATION_NEEDS_JSON = previousNeeds;
    }
    await rm(root, { recursive: true, force: true });
  }
  console.log('Next.js integration summary OK');
}

const options = parseArguments(process.argv.slice(2));
if (options.selfTest) {
  await runSelfTest();
} else if (options.summaryPath) {
  await validateSummary(options.summaryPath);
} else {
  assert(options.inputPath, '--input is required.');
  assert(options.outputPath, '--output is required.');
  const summary = await buildSummary(options.inputPath);
  await mkdir(options.outputPath, { recursive: true });
  await writeFile(path.join(options.outputPath, 'nextjs-integration-summary.json'), JSON.stringify(summary, null, 2) + '\n');
  await writeFile(path.join(options.outputPath, 'nextjs-integration-summary.md'), createMarkdown(summary));
  console.log(`Next.js integration summary written: ${options.outputPath}`);
}
