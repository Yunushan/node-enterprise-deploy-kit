# Release Checklist

Use this checklist before deploying the kit changes to a real host.

## Repository Verification

Run the same verification script used by CI:

```powershell
.\scripts\dev\Test-Repository.ps1
```

The verifier checks:

- PowerShell parser errors in `.ps1` files
- Bash syntax for Linux and dev shell scripts
- Unix shell portability patterns for macOS/BSD-compatible Bash and date usage
- Platform-family mapping checks for Ubuntu, Debian, Linux Mint, RHEL, Oracle Linux, CentOS, CentOS Stream, Rocky Linux, AlmaLinux, Fedora, Alpine, macOS, FreeBSD, OpenBSD, and NetBSD
- LF-only line endings for Linux scripts, Linux env examples, and Linux templates
- Windows JSON example config shapes, including standalone, `next-start`, and static IIS examples
- Unix-like env example shapes, including Linux standalone, Linux `next-start`, macOS `launchd`, and BSD `bsdrc` examples
- Ansible example variable coverage
- plain token template rendering with unresolved-token detection
- rendered XML validity for Windows templates
- rendered shell syntax for Linux init templates with `bash`, plus POSIX `sh` checks for System V, OpenRC, and BSD rc templates when available
- Next.js standalone and `next-start` package-helper output plus standalone/next-start preflight success/failure behavior on Windows and Unix-like configs
- React static package validation plus Windows/Unix preflight success/failure behavior
- Bash-only Unix Next.js smoke coverage for macOS-friendly packaging, runtime layout, POSIX-compatible runtime env files, rendered service templates, rendered Nginx/Apache/HAProxy/Traefik reverse-proxy templates, and systemd/System V/OpenRC/launchd/BSD rc static preflight/status evidence paths
- Local Node.js runtime smoke coverage for standalone and next-start Next.js services using the managed `PORT`, `APP_PORT`, `HOST`, and `HOSTNAME` contract
- release package hygiene and required release files, including the validated Windows/Unix `next-start`, macOS, and BSD examples
- host evidence validator self-test for Windows, Linux, macOS, and BSD status JSON shapes
- machine-readable support matrix coverage for Windows clients, Windows Server, Linux, and macOS targets
- hosted Windows static verification on pinned Windows Server runner images (`windows-2022` and `windows-2025`)
- support-claim gate self-test for strict Next.js mode, service-manager, and reverse-proxy evidence coverage
- support evidence collection pack, plan, and workflow dispatch command generation from the machine-readable matrix
- support evidence bundle generation with per-file SHA256, source-control provenance, CI provenance, support matrix SHA256, and collector provenance manifest
- support evidence coverage auditing against strict, service-only, and fallback matrix entries
- full-matrix release support readiness validation from a saved evidence bundle
- normalized `supportTargetId` metadata in real host evidence for exact matrix target matching
- manual self-hosted host evidence workflow guardrails
- local docs links, README anchors, and documented entrypoint presence
- obvious committed secret patterns
- `git diff --check` whitespace problems

On Windows, install Git Bash or another `bash` executable for the shell syntax
and Unix smoke-test steps. If you are only checking Windows scripts on a
restricted machine, use:

```powershell
.\scripts\dev\Test-Repository.ps1 -SkipShellSyntax
```

To run only the Next.js deployment checks:

```powershell
.\scripts\dev\Test-NextJsSupport.ps1
```

To run only the React deployment checks:

```powershell
.\scripts\dev\Test-ReactSupport.ps1
```

To validate the declared support targets:

```powershell
.\scripts\dev\Test-SupportMatrix.ps1
```

To generate the full real-host evidence operator pack:

```powershell
.\scripts\dev\New-SupportEvidenceCollectionPack.ps1 `
  -OutputDirectory .\evidence\collection-pack `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

The pack writes `support-evidence-plan.md`, `support-evidence-plan.json`,
`host-evidence-dispatch.md`, a guarded `Invoke-HostEvidenceDispatch.ps1`, a
guarded `Invoke-HostEvidenceArtifactDownload.ps1`,
`expected-workflow-artifacts.json/csv`, `local-command-only-evidence.json/csv`,
a pre-release `Test-HostEvidenceCollectionStaging.ps1`, a guarded
`Invoke-SupportEvidenceRelease.ps1`, and a generated README with the artifact
download/import/bundle sequence. Review the dispatcher and downloader output
before running either script with `-Run`. The downloader prints
`gh run list` and exact `gh run download --name <evidence_name>` commands, then
downloads into per-evidence folders when run with `-RunId ... -Run`. Use
the generated staging audit before the release script to fail on missing
downloaded `status.json` artifacts, local-only evidence files, or evidence whose
target/mode/service/proxy identity does not match the matrix row. Use
`-StrictCiRelease` on the generated release script only from a clean, committed
CI-controlled final signoff path.

To generate only the real-host evidence collection checklist:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\support-evidence-plan.md `
  -Format Markdown
```

The generated plan includes the local collection command and exact single-row
validation command for each target/mode/service/proxy combination. Windows,
Linux, and macOS rows also include manual `host-evidence` workflow inputs so
uploaded artifacts can be validated against the exact support matrix dimensions
they are meant to prove.
BSD rows are local-command-only unless you operate a compatible runner
environment. Use `-TargetId`, `-Category`, or `-ProductionRecommendedOnly` to
scope the plan before dispatching real hosts, and add `-FailOnWarnings` when
collection itself must reject warning-only status evidence.

To generate reviewable GitHub CLI dispatch commands for the manual
`host-evidence` workflow on workflow-capable targets:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\host-evidence-dispatch.md `
  -Format DispatchMarkdown
```

To generate a guarded dispatcher script, review its print-only output first,
then run it with `-Run` only after the runner labels match your real hosts:

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
`workflow_dispatch` provenance by default, and requires
`evidenceCollection.workflowDispatch` to match the exact
target/mode/service/proxy row. It derives the key, requires the declared target
to be corroborated by platform metadata, writes the canonical evidence filename,
and refuses changed overwrites unless `-Force` is supplied.
`-AllowLocalCollection` only bypasses workflow provenance for support matrix
rows marked `localCommandOnly`; workflow-capable Windows/Linux/macOS rows still
require controlled `host-evidence` collection.

To audit the evidence folder for missing matrix combinations:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -EvidencePath .\evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

To audit an archived evidence bundle and produce a human review report:

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
Next.js rows, still proves the required runtime platform floor. JSON and
Markdown reports include `summary.coveragePercent` plus breakdowns by evidence
kind, target category, and workflow collection path so readiness percentages
come from the collected evidence. With `-ReportOnly`, a missing `EvidencePath`
is treated as zero collected evidence so the same command can produce a 0%
baseline before any host evidence has been imported.
The default table output prints the first missing collect/validate command
pairs; use Markdown, JSON, or CSV for the complete command list.

`evidence/`, `evidence-downloads/`, and `release-evidence/` are generated,
git-ignored local output. They may contain machine-specific paths from the
collector host, so do not commit them. Publish final bundles as CI artifacts or
release attachments instead of source files.

To run the complete release evidence workflow in one operator command, import
optional downloaded artifacts, write coverage reports, fail on missing coverage,
create and verify the bundle, and emit release readiness JSON. The generated
`release-readiness.json` preserves the covered and missing coverage rows with
their local collection, local-command-only flag, workflow dispatch, and
single-row validation commands so the final handoff can reproduce every claimed
support tuple:

```powershell
.\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

Use `-StrictCiRelease` only from the clean, committed, CI-controlled final
signoff path. Strict release signoff refuses `-AllowWarnings`; final support
evidence must be warning-clean.

To create a private release evidence bundle:

```powershell
.\scripts\dev\New-SupportEvidenceBundle.ps1 `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -ValidateSupportClaim `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies `
  -RequireCollectorSha256 `
  -RequireMinimumUptimeHours 72 `
  -RequireHostEvidenceWorkflowCollection `
  -RequireCoverageComplete `
  -IncludeServiceOnly `
  -IncludeFallback
```

The bundle manifest records each evidence file hash plus the matrix Node
runtime support tier, safe Node.js runtime and Next.js package version strings
when available, the collector SHA256 digest, the support matrix SHA256, and safe
source-control provenance for the repository revision that created the bundle.
When built in CI, it also records safe workflow/run/ref provenance.
When source evidence files contain safe collection CI provenance, the manifest
records and verifies it per file, and each manifest row preserves the exact
collection workflow dispatch dimensions for row-level release review. The
bundle verifier rejects
internally inconsistent CI/source commit SHAs and evidence whose declared
`supportTargetId` is not corroborated by collected OS/platform metadata, even
when the manifest hashes match. It also rejects saved Next.js evidence that no
longer proves the required runtime platform floor. Release readiness rejects
bundles whose recorded
support matrix SHA256 does not match the current
`config/support-matrix.example.json`.
Bundle switches that require target-aware support-claim logic, such as
`-RequireHostEvidenceWorkflowCollection`, must be used with
`-ValidateSupportClaim`.
For final
CI-controlled release signoff, pass `-StrictCiRelease`; it cannot be combined
with `-AllowWarnings`. It enables the
clean-source, current-commit, bundle CI, collection CI, collection source
commit, controlled `host-evidence` workflow for workflow-capable rows, and
runtime version plus collector SHA256 evidence checks, with the
matrix-required minimum uptime window, so
bundles created from uncommitted tracked source changes, a different source
commit, a non-CI bundle path, evidence files without CI/workflow collection
provenance for workflow-capable rows, evidence collected from a different
source commit, evidence collected outside the controlled `host-evidence`
workflow dispatch where that workflow route is supported, or evidence without
safe Node.js, minimum Node.js, compatible Node.js, and Next.js version strings,
collector SHA256 digests, or the required minimum uptime proof fail. Local-command-only rows, such as BSD rows,
must be explicitly marked local-only in the bundle manifest and still pass the
runtime, collector, and uptime checks. The example support matrix sets
`requiredMinimumUptimeHours` to 72 hours.

To verify a saved evidence bundle before signoff:

```powershell
.\scripts\dev\Test-SupportEvidenceBundle.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip
```

To decide whether the saved full-matrix evidence bundle is ready for a release
support claim:

```powershell
.\scripts\dev\Test-ReleaseSupportReadiness.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -StrictCiRelease
```

Readiness output includes `supportScope.kind`, `supportScope.proofLevel`,
selected target counts, workflow-capable evidence counts, and local-command-only
evidence counts. Treat `Ready: True` as valid only for that stated scope: a
filtered or production-runtime-only result is not a full-matrix release claim.

For a production-runtime-only release decision, add `-ProductionRecommendedOnly`
to scope coverage and support-claim checks to matrix rows whose Node runtime is
production-recommended. Add `-RequireProductionRecommendedRuntime` when the
bundle itself must not contain experimental or community-package runtime rows.
When bundle creation is run with target, category, or production filters, only
matching evidence files are archived in the bundle.

To collect evidence through GitHub Actions, manually run the `host-evidence`
workflow against a self-hosted runner label for the deployed target host. The
workflow uploads safe `status.json` evidence and validates it with
`Test-HostEvidence.ps1` on a clean Ubuntu runner. Set the expected target,
Next.js mode, service manager, and reverse proxy inputs from the support
evidence plan or generated dispatch commands; mismatched evidence is rejected.
That workflow validation requires `-RequireCiCollection` and
`-RequireHostEvidenceWorkflowCollection`, so workflow-capable evidence must
prove it came from the controlled `host-evidence` / `workflow_dispatch` path.
The workflow refuses GitHub-hosted labels and requires `runner_labels` to include
`self-hosted` plus the expected target label before evidence collection starts.
Hosted labels such as `ubuntu-latest`, `ubuntu-24.04`, `windows-2022`,
`windows-2025`, and `macos-15` are blocked for real-host evidence collection.
Those expected target/mode/service/proxy inputs are required for dispatch.
The workflow accepts only declared matrix values for expected Next.js mode,
service manager, and reverse proxy, then validates the full combination against
the exact support matrix target row. The `evidence_name` input must match the
generated `target-mode-service-proxy` artifact name, with `-fallback` for
fallback service managers, including service-only fallback rows such as
`target-mode-pm2-none-fallback`. Use a relative workspace `config_path`,
such as `config/windows/app.config.json` or `config/linux/app.env`; those local
private config files are git-ignored and preserved by the collection checkout
with `clean: false`. The workflow rejects absolute paths, traversal, unsafe
characters, missing config files, and artifact retention outside 1-90 days.
It is not triggered by push or pull request events.

To validate a release support claim against real host evidence:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 `
  -EvidencePath .\evidence `
  -TargetId windows-11,windows-server-2022,ubuntu,macos `
  -MaxEvidenceAgeDays 30 `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies `
  -IncludeServiceOnly `
  -IncludeFallback `
  -RequireHostEvidenceWorkflowCollection
```

For support-claim validation, `-RequireHostEvidenceWorkflowCollection` is
applied only to workflow-capable matrix targets. BSD/local-only evidence is
still accepted because the support matrix marks that target category as
local-command-only for workflow collection.

For Unix-like hosts without PowerShell, run:

```bash
bash scripts/dev/test-unix-nextjs-support.sh
```

On GitHub-hosted Ubuntu runners, the CI workflow also runs target or
target-family Linux userland smoke checks for Ubuntu, Debian, Linux Mint,
RHEL/UBI, Oracle Linux, CentOS/CentOS Stream, Rocky Linux, AlmaLinux, Fedora,
and Alpine:

```bash
bash scripts/dev/test-linux-container-smoke.sh --platform ubuntu
```

The wrapper has a no-Docker self-test for local repository verification:

```bash
bash scripts/dev/test-linux-container-smoke.sh --self-test
```

That job catches shell, package-manager, archive, and Node.js runtime
differences in public target or target-family containers. It does not replace
the real-host evidence bundle required for a final support claim.

To build application artifacts for a Next.js standalone app, use the package
helpers from a build workspace after `npm run build`:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip
```

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz
```

For full-app `next-start` artifacts, add `-Mode next-start` on Windows or
`--mode next-start` on Unix to the same package helpers. Unix `next-start`
helper output intentionally excludes `node_modules/.bin` symlink shims; the
service starts Next from `node_modules/next/dist/bin/next`, and release
archives must stay free of symlink and hardlink entries.

For React build artifacts, validate the archive against the configured document
root before handing it to a server:

```powershell
.\scripts\windows\Test-ReactStaticPackage.ps1 `
  -PackagePath C:\deploy\example-react-app.zip `
  -ReactDocumentRoot build `
  -StripSingleTopLevelDirectory
```

```bash
bash scripts/linux/validate-react-static-package.sh \
  --package-path /opt/releases/example-react-app.tar.gz \
  --react-document-root build \
  --strip-single-top-level
```

After importing or copying a live runtime folder, validate the deployed
directory itself:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

```bash
bash scripts/linux/test-nextjs-runtime-layout.sh config/linux/app.env
```

Ansible playbook syntax is checked automatically when `ansible-playbook` is
available. If Ansible or the required collections are not installed on the
validation machine, that optional check is skipped. CI installs `ansible-core`
and `ansible/requirements.yml` before repository verification so the playbook
syntax check runs deterministically in GitHub Actions.

ShellCheck is a required GitHub Actions gate for Bash deployment scripts. The
main repository verifier runs ShellCheck when it is installed and reports a
local skip when it is not installed. CI installs ShellCheck before running:

```bash
bash scripts/dev/lint-shellcheck.sh
```

Run the same command locally after installing ShellCheck to catch portability
warnings before pushing.

## Release Package

Build a sanitized source package from tracked and non-ignored release files:

```powershell
.\scripts\dev\Test-ReleasePackage.ps1
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0
```

The package builder writes output under `.tmp/release` and creates a manifest
next to the zip. It blocks private configs, local environment files, logs,
build output, external service-wrapper binaries, certificates, and key files.

Use `-NoZip` when you only want a staging directory for inspection:

```powershell
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0 -NoZip
```

## Private Config Safety

Keep these files local to the target environment:

```text
config/windows/app.config.json
config/linux/app.env
.env
.env.*
*.key
*.pem
*.pfx
*.p12
```

The repository only includes example config files. Do not put real hostnames,
customer names, tokens, database URLs, certificates, or private keys into
committed examples.

## Target Preflight

Run target-specific preflight checks on the server before installing:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
```

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
```

If the configured port is already owned by the current service during an
intentional update, use the Windows `-AllowPortInUse` switch or Linux
`ALLOW_PORT_IN_USE="true"`.

For Next.js standalone releases, verify the built archive before handing it to
the server. The archive root should contain `server.js`, `.next/BUILD_ID`, and
`.next/static`, and
should contain `public` when the app serves files from `public`. Configure
`PackageExpectedFiles` or `PACKAGE_EXPECTED_FILES` with files or directories
that must exist after extraction:

```json
"PackageExpectedFiles": [
  "server.js",
  ".next/BUILD_ID",
  ".next/static"
]
```

```bash
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
```

See [Next.js Deployment](NEXTJS_DEPLOYMENT.md) for the full standalone build
and packaging flow.

For React releases, verify that the archive contains the configured Node
entrypoint and `<ReactDocumentRoot>/index.html`; see
[React Deployment](REACT_DEPLOYMENT.md).

## Deploy

Windows:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

Linux:

```bash
bash deploy.sh config/linux/app.env
```

Ansible:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml
```

## Post-Deploy Checks

Windows:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -JsonPath .\evidence\windows-status.json -FailOnCritical
Get-Service <AppName>
```

Linux:

```bash
bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --fail-on-critical
bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --json-output ./evidence/unix-status.json --fail-on-critical
systemctl status <app-name>
curl -fsS http://127.0.0.1:3000/health
```

Also confirm the public reverse proxy endpoint, recent logs, and reboot
behavior for new service installs.
Keep the JSON status file with the release evidence when the change requires an
audit trail. It records the verdict and findings without dumping runtime
environment values, raw host identity, full filesystem paths, or raw logs.
When deployment used a package import, the JSON `DeploymentIdentity` /
`deploymentIdentity` section also records the package file name, package
SHA256, import timestamp, and Next.js build ID from
`.node-enterprise-deploy.json`, so the release evidence can prove which
artifact is running.

For updates, confirm the backup directory contains any changed managed files
before deleting old release artifacts.

## Real Host Evidence

When a release needs a support claim for specific operating systems, collect
status JSON from those actual hosts and validate it:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-server,linux,macos,freebsd,openbsd,netbsd `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity `
  -RequireCollectorSha256 `
  -RequireMinimumUptimeHours 72
```

For stricter release gates, add `-MaxEvidenceAgeDays` and `-FailOnWarnings`.
For individual workflow-collected files, also add `-RequireCiCollection` and
`-RequireHostEvidenceWorkflowCollection`; do not add those switches for
local-command-only evidence such as BSD rows.
Run `Test-SupportEvidenceCoverage.ps1` when you need a missing-coverage report
before making the final support claim.
`Test-HostEvidence.ps1` rejects evidence whose declared `supportTargetId` is
not independently corroborated by the collected OS/platform metadata. With
`-RequireNextJs`, it also rejects evidence that does not prove the relevant
Node.js runtime platform floor, such as Windows build, Linux kernel/glibc, or
macOS version/architecture.
See [Host Verification Evidence](HOST_VERIFICATION.md) for the full workflow.
Use [Support Matrix](SUPPORT_MATRIX.md) to choose the exact target IDs required
for a platform-specific release claim.
