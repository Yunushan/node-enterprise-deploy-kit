#!/usr/bin/env node
import fs from 'node:fs';

// The deployment gate and release gate read the same reviewed schedule. Merely
// satisfying a framework's minimum version does not establish vendor support.
const [policyPath, reportedVersion, platform = '', macosVersion = '', architecture = ''] = process.argv.slice(2);
try {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  if (policy.schemaVersion !== 1 || !Array.isArray(policy.releaseLines)) throw new Error('Invalid Node runtime policy schema.');
  if (!/^v?\d+\.\d+\.\d+$/.test(reportedVersion || '')) throw new Error(`Unrecognized Node.js version: ${reportedVersion || '(empty)'}.`);
  const major = Number(reportedVersion.replace(/^v/, '').split('.')[0]);
  const release = policy.releaseLines.find(line => line.major === major);
  if (!release) throw new Error(`Node.js ${major} is absent from the reviewed runtime policy; review its support schedule before deployment.`);
  const today = new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(release.start) || !/^\d{4}-\d{2}-\d{2}$/.test(release.end)) throw new Error('Invalid Node release dates.');
  if (today < release.start || today >= release.end) throw new Error(`Node.js ${major} is outside its supported release window (${release.start} through ${release.end}); use a supported release line.`);
  if (platform === 'Darwin') {
    const minimum = architecture === 'arm64' ? release.macosArm64Minimum : release.macosMinimum;
    if (!/^\d+(\.\d+){1,2}$/.test(macosVersion) || !/^\d+(\.\d+){1,2}$/.test(minimum || '')) throw new Error('Could not verify the macOS version against the Node platform policy.');
    const current = macosVersion.split('.').map(Number);
    const needed = minimum.split('.').map(Number);
    for (let index = 0; index < 3; index++) {
      if ((current[index] || 0) < (needed[index] || 0)) throw new Error(`Node.js ${major} requires macOS ${minimum} or newer for ${architecture || 'this architecture'}.`);
      if ((current[index] || 0) > (needed[index] || 0)) break;
    }
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
