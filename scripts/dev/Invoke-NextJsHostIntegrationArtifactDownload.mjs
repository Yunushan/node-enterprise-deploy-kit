#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseRunIds(value) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error('--run-ids must be a JSON array of GitHub Actions run IDs.');
  }
  assert(Array.isArray(parsed) && parsed.length > 0, '--run-ids must be a non-empty JSON array of GitHub Actions run IDs.');
  const runIds = parsed.map((entry) => String(entry));
  for (const runId of runIds) {
    assert(/^\d+$/.test(runId) && Number(runId) > 0, '--run-ids must contain only positive GitHub Actions run IDs.');
  }
  assert(new Set(runIds).size === runIds.length, '--run-ids must not contain duplicate GitHub Actions run IDs.');
  return runIds;
}

function assertRepository(value) {
  assert(typeof value === 'string' && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value), '--repository must be an owner/repository identifier.');
  return value;
}

function parseArguments(args) {
  const options = { runIds: '', repository: '', output: '', validateOnly: false, selfTest: false };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--run-ids') options.runIds = args[++index] || '';
    else if (argument === '--repository') options.repository = args[++index] || '';
    else if (argument === '--output') options.output = args[++index] || '';
    else if (argument === '--validate') options.validateOnly = true;
    else if (argument === '--self-test') options.selfTest = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return options;
}

function validateOptions(options, requireOutput) {
  const runIds = parseRunIds(options.runIds);
  const repository = assertRepository(options.repository);
  if (requireOutput) {
    assert(typeof options.output === 'string' && options.output.trim(), '--output is required.');
  }
  return { runIds, repository };
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: 'inherit', windowsHide: true });
    child.once('error', (error) => reject(new Error(`Unable to start ${command}: ${error.message}`)));
    child.once('exit', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} ${args.join(' ')} failed with ${signal || `exit code ${code}`}.`));
    });
  });
}

export async function downloadArtifacts({ runIds, repository, output }) {
  await mkdir(output, { recursive: true });
  for (const runId of runIds) {
    await run('gh', ['run', 'download', runId, '--repo', repository, '--dir', path.join(output, runId)]);
  }
}

const isMainModule = process.argv[1]
  && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMainModule) {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    const valid = validateOptions({ runIds: '["123","456"]', repository: 'Yunushan/node-enterprise-deploy-kit', output: 'ignored' }, true);
    assert(valid.runIds.length === 2, 'Self-test did not parse source run IDs.');
    try {
      parseRunIds('["123","123"]');
      throw new Error('Self-test accepted duplicate source run IDs.');
    } catch (error) {
      if (error.message.includes('Self-test accepted')) throw error;
    }
    console.log('Next.js host integration artifact downloader OK');
  } else {
    const validated = validateOptions(options, !options.validateOnly);
    if (options.validateOnly) {
      console.log(`Next.js host integration source run IDs OK: ${validated.runIds.join(', ')}`);
    } else {
      await downloadArtifacts({ ...validated, output: path.resolve(options.output) });
    }
  }
}
