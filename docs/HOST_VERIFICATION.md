# Host Verification Evidence

Repository checks prove that scripts, templates, and examples are internally
consistent. Real deployment support is stronger only after the same release has
safe status evidence from the target host families you claim to support.

Do not commit real evidence files. Keep them in a local `evidence/` directory
or in your private release/change record.

## Collect Evidence

Windows:

```powershell
.\status.ps1 `
  -ConfigPath .\config\windows\app.config.json `
  -MinimumUptimeHours 72 `
  -JsonPath .\evidence\windows-server-2022\status.json `
  -FailOnCritical
```

Linux:

```bash
sudo bash scripts/linux/status-node-app.sh \
  config/linux/app.env \
  --minimum-uptime-hours 72 \
  --json-output ./evidence/ubuntu-24.04/status.json \
  --fail-on-critical
```

macOS:

```bash
sudo bash scripts/linux/status-node-app.sh \
  config/linux/app.env \
  --minimum-uptime-hours 72 \
  --json-output ./evidence/macos-launchd/status.json \
  --fail-on-critical
```

BSD:

```bash
sudo bash scripts/linux/status-node-app.sh \
  config/linux/app.env \
  --minimum-uptime-hours 72 \
  --json-output ./evidence/freebsd-rc/status.json \
  --fail-on-critical
```

The evidence JSON contains safe operational metadata only: app name, service
name, verdict, finding counts, sanitized health URL, deployment/build identity,
path basenames, platform metadata, normalized `supportTargetId`, safe Node.js
runtime and Next.js package version strings when available, safe runtime
platform facts such as Windows build, Unix kernel release, libc version, OS
version, and architecture, live collector
metadata in `evidenceCollection`, the collector SHA256 digest when available,
managed service-definition proof for Windows and Unix-like service managers,
Windows scheduled-task action proof, explicit `synthetic: false`, `mock: false`,
and `sample: false` provenance markers, optional safe CI collection provenance,
and redacted finding messages.
CI collection provenance is limited to provider, workflow name, run ID, run
attempt, event name, ref name, and commit SHA; it does not include runtime
environment values, raw host identity, full filesystem paths, raw logs, HTTP
response bodies, secrets, or runner hostnames.

### Self-Hosted Runner Collection

The manual `host-evidence` GitHub Actions workflow can collect evidence from an
already deployed Windows, Linux, or macOS self-hosted runner and upload the safe
`status.json` as a workflow artifact. The dispatch validator also accepts BSD
target dimensions for compatible self-hosted runner environments, but generated
BSD evidence-plan rows are local-command-only by default. Use runner labels that
point at the real target host, set `platform` to `windows` or `unix`, and set
`config_path` to the deployed app config on that runner. The workflow accepts
only a safe relative workspace path such as `config/windows/app.config.json` or
`config/linux/app.env`; do not put absolute server paths, hostnames, customer
names, or secrets in workflow inputs.

The workflow validates `runner_labels` and expected collection dimensions before
collection. Labels must be a JSON array containing `self-hosted` and the exact
`expected_target_id` label. GitHub-hosted labels such as `ubuntu-latest`,
`ubuntu-24.04`, `windows-latest`, `windows-2022`, `windows-2025`,
`macos-latest`, and `macos-15` are rejected because they cannot prove real-host
support.

The local config files `config/windows/app.config.json` and
`config/linux/app.env` are ignored by git. On self-hosted runners, create the
target-specific private config in the runner workspace before dispatching the
workflow. The collection job checks out the repository with `clean: false` so
those ignored local config files are preserved, then it fails early if the
selected `config_path` is missing.
Set `upload_retention_days` between 1 and 90 days.

For matrix-level support claims, set all expected collection dimensions:
`expected_target_id`, `expected_nextjs_mode`, `expected_service_manager`, and
`expected_reverse_proxy`. The validation job passes those values to
`Test-HostEvidence.ps1` and rejects evidence that was collected from the wrong
target, Next.js mode, service manager, or reverse-proxy mode. Use
`expected_reverse_proxy=none` for service-only entries; the validator treats
that as an explicit service-only claim instead of a missing proxy check. The
workflow allow-lists expected Next.js modes, service managers, and reverse
proxies to the support-matrix vocabulary, validates the exact target row in
`config/support-matrix.example.json`, and rejects platform/category mismatches
before evidence collection starts. The `evidence_name` input must match the
generated `target-mode-service-proxy` artifact name, with `-fallback` for
fallback service managers.

The workflow is `workflow_dispatch` only. It is for release evidence collection
from real hosts, not for replacing the normal push/PR CI checks. BSD evidence
should still be collected with the local command above unless you operate a
compatible self-hosted runner environment.

## Validate Evidence

Validate the collected files from a workstation:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-server,linux,macos,freebsd,openbsd,netbsd `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity
```

Use [Support Matrix](SUPPORT_MATRIX.md) for exact target IDs such as
`windows-10`, `windows-11`, `windows-server-2022`, `ubuntu`, `rhel`, `alpine`,
and `macos`.

Before collecting release evidence, generate the checklist from the current
support matrix:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\support-evidence-plan.md `
  -Format Markdown
```

Each generated plan entry includes the local collection command and exact
single-row validation command for that target/mode/service/proxy row. Windows,
Linux, and macOS entries also include
`workflowInputs` for the manual `host-evidence` workflow, including
`runner_labels`, `platform`, `config_path`, `evidence_name`, and the expected
target/mode/service/proxy values. `evidence_name` is derived from those
dimensions and is validated before collection starts. BSD entries are
local-command-only unless you operate a compatible runner environment. Use
`-TargetId`, `-Category`, or `-ProductionRecommendedOnly` to scope the plan
before dispatch, and add
`-FailOnWarnings` when collection commands and workflow inputs should reject
warning-only status evidence.

To generate reviewable GitHub CLI dispatch commands from the same matrix for
workflow-capable targets:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\host-evidence-dispatch.md `
  -Format DispatchMarkdown
```

For a guarded PowerShell dispatcher, generate a script and review the printed
commands first. The generated script only dispatches workflows when run with
`-Run`.

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\Invoke-HostEvidenceDispatch.ps1 `
  -Format DispatchPowerShell
.\evidence\Invoke-HostEvidenceDispatch.ps1
```

After downloading `host-evidence` workflow artifacts into a local folder,
validate and import them into the canonical evidence tree. `ArtifactPath` can
be an extracted artifact folder, a single `.zip` artifact, or a folder
containing downloaded `.zip` artifacts:

```powershell
.\scripts\dev\Import-HostEvidenceArtifacts.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence
```

The importer validates each downloaded `status.json` against the support matrix
and `Test-HostEvidence.ps1`, requires controlled `host-evidence` /
`workflow_dispatch` provenance by default, derives the target/mode/service/proxy
key, requires the declared target to be corroborated by platform metadata,
writes the canonical evidence filename, and refuses changed overwrites unless
`-Force` is supplied. Use `-AllowLocalCollection` only for explicitly
local-command evidence.

After collecting evidence, audit the folder against the full matrix to see
which expected host/service/proxy combinations are still missing:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -EvidencePath .\evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

For a saved release evidence bundle, audit the zip directly and write a
reviewable Markdown report. `-ReportOnly` keeps the report command from failing
when gaps are expected during evidence collection:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -ReportOnly `
  -Format Markdown `
  -OutputPath .\release-evidence\coverage-report.md
```

Missing rows in Markdown, JSON, and CSV output include the expected evidence
file plus the local collector command, the exact single-row validation command,
and, where supported, the exact manual
`gh workflow run host-evidence.yml` command to collect that evidence. These
commands fail on warning-only status evidence by default; add `-AllowWarnings`
when the missing-coverage report should generate warning-tolerant collection
commands instead. Coverage counts only evidence whose declared
`supportTargetId` is corroborated by collected OS/platform metadata and, for
Next.js rows, still proves the required runtime platform floor.
The default table output prints the first missing collect/validate command
pairs; use Markdown, JSON, or CSV for the complete command list.

For a single operator command after artifacts are downloaded, use the combined
release workflow. It imports optional artifacts, writes coverage reports, fails
when declared evidence is still missing, creates and verifies the evidence
bundle, and writes release readiness JSON. The generated
`release-readiness.json` preserves the covered and missing coverage rows with
their local collection, workflow dispatch, and single-row validation commands
so the final handoff can reproduce every claimed support tuple:

```powershell
.\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

Use `-StrictCiRelease` only for final CI-controlled release signoff from a
clean committed revision.

Create a private evidence bundle for the release record after validation:

```powershell
.\scripts\dev\New-SupportEvidenceBundle.ps1 `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -ValidateSupportClaim `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies `
  -RequireCoverageComplete `
  -IncludeServiceOnly `
  -IncludeFallback
```

The bundle contains the safe evidence JSON files plus
`support-evidence-manifest.json`, which records SHA256, size, target ID,
Next.js mode, service manager, reverse proxy, deployment ID, build ID, and
package SHA256 for each evidence file. It also records the matrix Node runtime
support tier, safe Node.js runtime and Next.js package version strings when
available, the status collector, collector version, collector SHA256 digest,
live-host flag, and explicit
synthetic/mock/sample flags so archived evidence cannot silently lose
provenance. The manifest also records the support
matrix SHA256 and safe source-control provenance, including
repository name, commit SHA when git metadata is available, branch name, and
whether tracked files were dirty when the bundle was created. When the bundle
is created in CI, it also records safe CI provenance such as provider, workflow
name, run ID, run attempt, event name, ref name, and commit SHA. If both CI SHA
and source-control commit SHA are present, they must match. Each manifest row
also records safe collection CI provenance when it exists in the source evidence
file, so workflow-collected evidence keeps its collection run identity after
bundling.

Verify a saved bundle before using it in a support review:

```powershell
.\scripts\dev\Test-SupportEvidenceBundle.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip
```

Run the release readiness gate before using a full-matrix bundle for a release
support claim:

```powershell
.\scripts\dev\Test-ReleaseSupportReadiness.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -StrictCiRelease
```

The verifier recalculates every evidence file hash, checks manifest byte sizes,
proves manifest fields still match the JSON content, verifies live collector
provenance, requires explicit non-synthetic/non-mock/non-sample evidence
markers, verifies source-control and support-matrix provenance, and rejects
unlisted evidence files inside the bundle. It also rejects evidence whose
declared `supportTargetId` is not corroborated by collected OS/platform
metadata, even when the manifest hashes match. It also validates CI provenance
when present, including CI/source commit consistency. The release readiness gate
also rejects bundles whose recorded support matrix SHA256 does not match the
current support matrix. Use `-StrictCiRelease` for CI-controlled final release
signoff.
It enables the clean-source, current-commit, bundle CI, collection CI,
collection source commit, controlled `host-evidence` workflow for
workflow-capable rows, and runtime version plus collector SHA256 evidence
checks, with the matrix-required minimum uptime window, so
bundles created from uncommitted tracked source changes, a different source
commit, a non-CI bundle path, evidence files without CI/workflow collection
provenance for workflow-capable rows, evidence collected from a different
source commit, evidence collected outside the controlled `host-evidence`
workflow dispatch where that workflow route is supported, or evidence without
safe Node.js, minimum Node.js, compatible Node.js, and Next.js version strings,
collector SHA256 digests, or the required minimum uptime proof are rejected;
omit it only for explicitly provisional evidence reviews. The example support
matrix sets `requiredMinimumUptimeHours` to 72 hours.

For a production-runtime-only support decision, add
`-ProductionRecommendedOnly` to scope readiness coverage and support-claim
checks to matrix rows whose Node runtime is production-recommended. Add
`-RequireProductionRecommendedRuntime` when the bundle itself must not contain
experimental or community-package runtime rows.
When bundle creation is run with target, category, or production filters, only
matching evidence files are archived in the bundle.

For release signoff, prefer the support-claim gate because it derives the
required evidence aliases from the support matrix:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 `
  -EvidencePath .\evidence `
  -TargetId windows-11,windows-server-2022,ubuntu,macos `
  -MaxEvidenceAgeDays 30 `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies
```

For a stricter support claim across the expanded matrix:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-server-2019,windows-server-2022,ubuntu,debian,rhel,oracle-linux,centos-stream,fedora,linux-mint,macos,freebsd,openbsd,netbsd `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity `
  -RequireCollectorSha256 `
  -RequireMinimumUptimeHours 72 `
  -MaxEvidenceAgeDays 30 `
  -FailOnWarnings
```

Use `-FailOnWarnings` only when the release gate requires fully clean evidence.
For early smoke deployments, warnings may be acceptable when they are explained
and do not affect service, port ownership, HTTP health, or Next.js runtime
layout.

## What Counts As Good Evidence

Evidence is acceptable when:

- The JSON parses successfully.
- The verdict is `Healthy` or an accepted `Warning`.
- `critical` / `Critical` is `0`.
- `supportTargetId` / `SupportTargetId` is present and matches the support
  matrix target being claimed, such as `windows-server-2022`, `ubuntu`,
  `macos`, or `freebsd`.
- The platform metadata independently corroborates the target being claimed;
  a declared `supportTargetId` by itself is not enough to prove a matrix row.
- For strict Next.js support claims, the platform metadata also proves the
  Node.js runtime platform floor: Windows build number, Linux kernel and glibc
  versions, or macOS product version and architecture where those floors apply.
- Saved bundle verification and coverage reports enforce the same Next.js
  runtime platform floor so stale archived evidence cannot keep a matrix row
  covered.
- The app had enough uptime for the verification window.
- Service process uptime is present. When a minimum uptime window was requested
  by the status command, the evidence proves the window was satisfied.
- The service is active and enabled for boot through the target service
  manager, such as Windows SCM, systemd, OpenRC, launchd, or BSD rc.
- The configured app port was checked, is listening, has readable owner
  process evidence, and is owned by the configured service process.
- The HTTP health probe was checked and returned a successful 2xx/3xx status.
- Recurring health monitor evidence is present: the monitor has run recently,
  the state file exists, consecutive failures are `0`, the recent log summary
  exists, and the recent log summary has `0` failures and `0` service restarts.
  On Windows, the scheduled health-check task must also exist with a successful
  last result and no missed runs. On systemd Unix-like hosts, the healthcheck
  timer must also exist, be active, and be enabled for boot. On macOS, the
  launchd healthcheck job must exist, be active, and be enabled. On cron-based
  Unix-like hosts, the managed cron entry must exist and cron daemon activity
  must be detected.
- For Next.js support claims, `-RequireNextJs` proves `AppFramework=nextjs`, a
  valid deployment mode, safe Node.js and Next.js runtime versions, a Node.js
  runtime that satisfies the configured minimum, and a successful runtime
  layout check.
- For reverse-proxy deployments, `-RequireReverseProxy` proves the proxy health
  route returned a successful HTTP status.
- For Windows IIS reverse-proxy deployments, `-RequireReverseProxy` also proves
  the configured IIS site exists, is started, its physical path matches the
  configured deployment path, it owns the expected public binding, and no other
  IIS site has the same binding.
- For Unix-like Nginx, Apache, HAProxy, and Traefik deployments,
  `-RequireReverseProxy` also proves the expected proxy config file exists and
  contains this kit's managed marker for the app. Evidence records only safe
  file and directory names, not full paths.
- `-RequireDeploymentIdentity` proves the status output includes either a
  target-local deployment ID, the Next.js `.next/BUILD_ID`, or the package
  SHA256 from `.node-enterprise-deploy.json`, so the evidence identifies the
  release/build that is actually running.
- The evidence is recent enough for the release or support decision.

Evidence is not enough when:

- It comes from only local CI or WSL while claiming real Windows Server, macOS,
  or BSD support.
- It does not include normalized `supportTargetId` metadata for the matrix
  target being claimed.
- The declared `supportTargetId` conflicts with OS/platform metadata, such as
  Ubuntu evidence claiming `windows-server-2022`.
- A strict Next.js claim omits the relevant runtime platform floor, such as
  Linux kernel/glibc facts or macOS product version and architecture.
- The service or port checks were skipped for a production support claim.
- The service is currently active but not enabled to start after reboot.
- Service process uptime is missing, unknown, or below the requested minimum
  uptime window.
- The configured app port is missing, owned by an unknown process, or could not
  be tied back to the configured service process.
- The health endpoint is missing or points at the wrong route.
- The HTTP health check was skipped, failed, or returned a non-successful
  status code.
- The recurring health monitor has not run yet, its state or log summary is
  missing, the last success is stale, consecutive failures are non-zero, recent
  health-check failures/restarts are present, or the Windows scheduled task has
  not completed successfully.
- A systemd deployment has health-check state/log history, but the
  `<app-name>-healthcheck.timer` unit is missing, inactive, or not enabled.
- A macOS or cron-based deployment has health-check state/log history, but the
  recurring launchd job or managed cron entry cannot be proved.
- The Next.js runtime layout was not validated for the selected mode.
- The reverse proxy was not probed, was skipped, or returned a non-successful
  health status.
- A Windows IIS deployment has a healthy Node service but IIS still points to an
  old release folder, the configured IIS site is stopped, a different site owns
  the public binding, or duplicate IIS sites share the same public binding.
- A Unix-like reverse-proxy deployment has a healthy backend health endpoint
  but the expected Nginx, Apache, HAProxy, or Traefik config file is missing or
  does not carry this kit's managed marker for the app.
- The evidence cannot identify the running release/build through a deployment
  ID, Next.js build ID, or package SHA256.
- The file contains private hostnames, raw machine names, full filesystem
  paths, customer names, credentials, raw logs, or application response bodies.

## Release Gate Pattern

Use this gate before saying a release is proven on a host family:

1. Run repository verification.
2. Deploy the same release artifact to the target host.
3. Reboot once for new service installs.
4. Run status evidence immediately after reboot.
5. Run status evidence again after the required uptime window.
6. Validate the evidence folder with `Test-HostEvidence.ps1`.
7. Run `Test-SupportEvidenceCoverage.ps1` to find any missing matrix entries.
8. Keep the JSON files with the private release record.

This kit can provide templates and validators for many platforms. A platform is
only proven for a given release after the real-host evidence exists and passes
the evidence validator.
