# Support Matrix

This repository separates three different support levels:

| Level | Meaning |
|---|---|
| `template-ready` | Scripts and templates exist for the platform family. |
| `ci-static-verified` | Repository verification and static platform checks pass in CI. |
| `real-host-verified` | A real host produced passing status JSON and `Test-HostEvidence.ps1` accepted it. |

Do not call a platform fully supported for a release until it reaches
`real-host-verified` for that release artifact.

The machine-readable matrix lives at
[`config/support-matrix.example.json`](../config/support-matrix.example.json).
It is validated by:

```powershell
.\scripts\dev\Test-SupportMatrix.ps1
```

The matrix validator checks target IDs, required Next.js modes, Node.js runtime
support metadata, CI/static verification references, platform-family mappings,
evidence target names, and the concrete installer/template artifacts for each
declared service manager, fallback manager, and reverse proxy.
It also verifies that every declared CI/static verification job exists in
`.github/workflows/ci.yml` and still contains the expected verifier command
fragments, so the matrix cannot point at a job that no longer runs the relevant
checks.

Windows service-manager routing and runtime environment parity are validated by:

```powershell
.\scripts\dev\Test-WindowsServiceManagers.ps1
```

That check proves the WinSW, NSSM, and PM2 paths keep the same Node/Next.js
environment contract and that the deployment wrapper routes only to the
installer matching `ServiceManager`.

To generate the release-specific evidence operator pack from the matrix:

```powershell
.\scripts\dev\New-SupportEvidenceCollectionPack.ps1 `
  -OutputDirectory .\evidence\collection-pack `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

The pack preserves the exact matrix filters in a checklist, workflow dispatch
commands, a guarded dispatcher, a guarded artifact downloader keyed by expected
evidence names, JSON/CSV manifests for expected workflow artifacts and
local-command-only evidence rows, a pre-release staging audit, a guarded
release-gate script, and a generated README. The downloader prints `gh run list`
and exact
`gh run download --name <evidence_name>` commands, then downloads into
per-evidence folders when run with `-RunId ... -Run`. It is a handoff artifact
for collecting real host evidence; run the generated staging audit before the
release script to fail on missing downloaded `status.json` artifacts, missing
local-command-only host evidence, or evidence whose target/mode/service/proxy
identity does not match the matrix row. Add `-ValidateWithHostEvidence` to run
`Test-HostEvidence.ps1` against every staged row before the release gate,
including uptime, Next.js runtime, reverse-proxy, collector SHA256, and workflow
provenance checks. The audit auto-resolves the validator from the repository
root or the default `evidence\collection-pack` location; pass
`-HostEvidenceValidatorPath` if the pack was copied elsewhere. It does not
replace downloaded workflow artifacts, local-command-only host evidence, or the
final readiness gate.

To generate only a release-specific evidence checklist from the matrix:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\support-evidence-plan.md `
  -Format Markdown
```

The generated plan separates strict real-host evidence, service-only
`ReverseProxy=none` evidence, and fallback-manager evidence so release claims
can stay precise. Fallback-manager evidence includes service-only fallback rows
when a target declares both a fallback manager and `ReverseProxy=none`. It also
carries each target's Node runtime support tier so
collection plans make experimental and community-package targets visible before
evidence collection starts. Add `-TargetId`, `-Category`, or
`-ProductionRecommendedOnly` to scope the collection plan, and add
`-FailOnWarnings` when collection commands and workflow dispatches should fail
on warning-only status evidence.

After downloading `host-evidence` workflow artifacts into a local folder,
validate and import them into the canonical evidence tree. `ArtifactPath` can
be an extracted artifact folder, a single `.zip` artifact, or a folder
containing downloaded `.zip` artifacts:

```powershell
.\scripts\dev\Import-HostEvidenceArtifacts.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence
```

The importer validates each downloaded `status.json`, requires controlled
`host-evidence` / `workflow_dispatch` provenance by default, requires
`evidenceCollection.workflowDispatch` to match the exact
target/mode/service/proxy row, derives the key from the evidence and matrix, and
writes the canonical evidence filename. It also requires the declared target to
be corroborated by platform metadata before import. `-AllowLocalCollection` only
bypasses workflow provenance for rows marked `localCommandOnly`; workflow-capable
Windows/Linux/macOS rows still require controlled `host-evidence` collection.

To turn collected artifacts into a release-ready evidence package in one
operator step:

```powershell
.\scripts\dev\Invoke-SupportEvidenceReleaseWorkflow.ps1 `
  -ArtifactPath .\evidence-downloads `
  -EvidencePath .\evidence `
  -OutputDirectory .\release-evidence `
  -BundleName node-enterprise-deploy-kit-1.0.0-evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

The command validates the support matrix, imports optional artifacts, writes
coverage JSON and Markdown reports, fails on missing required evidence, creates
and verifies the bundle, writes detailed release readiness JSON, and writes the
redacted `release-readiness-summary.json` review artifact. The detailed
readiness JSON preserves the covered and missing coverage rows with their local
collection, local-command-only flag, workflow dispatch, and single-row
validation commands so every claimed support tuple has reproducible proof
commands. The summary keeps only aggregate proof and provenance fields for
review. The wrapper
output and `-PassThru` result also surface the readiness review `supportScope`
and the saved bundle's `bundleSupportScope`, so the one-command handoff states
whether the result is full-matrix, filtered, or production-runtime-only. Add
`-StrictCiRelease` only for final CI-controlled signoff; strict signoff refuses
`-AllowWarnings`. Add `-RequireFinalFullMatrixReleaseClaim` when the command
must fail unless readiness proves `releaseClaim.finalFullMatrixReleaseClaim:
true`; that switch requires `-StrictCiRelease`.
For a CI-enforced final gate, first dispatch
`.github/workflows/support-evidence-bundle.yml` on a self-hosted runner that can
read the private evidence workspace. It validates inputs with
`scripts/dev/Test-SupportEvidenceBundleWorkflowInputs.ps1`, runs the strict
release workflow, writes the reviewer-facing GitHub step summary, and uploads
only the redacted `release-readiness-summary.json` artifact by default. It does
not upload the private bundle zip unless `upload_private_bundle` is explicitly
set to `true`; keep that input `false` for public or broadly readable
repositories. Leave `artifact_path` empty when the self-hosted runner already
has canonical `evidence/`; set it only when the workflow should import
downloaded `host-evidence` artifacts before bundling. With the default
`upload_private_bundle=false`, that self-hosted run is the final CI gate and
`release-evidence.yml` cannot download a bundle from it. If you need a separate
GitHub-hosted verifier run, enable `upload_private_bundle`, then dispatch
`.github/workflows/release-evidence.yml` with that source run ID and artifact
name. The verifier workflow validates dispatch inputs with
`scripts/dev/Test-ReleaseEvidenceWorkflowInputs.ps1`, downloads that artifact,
locates the evidence zip with `scripts/dev/Resolve-ReleaseEvidenceBundle.ps1`,
and runs `Test-ReleaseSupportReadiness.ps1` with
`-StrictCiRelease -RequireFinalFullMatrixReleaseClaim`, keeps the detailed
`release-readiness.json` only inside the job workspace, does not re-upload the
private evidence bundle, and uploads only the redacted
`release-readiness-summary.json` result. The summary artifact and workflow
summary include only safe claim requirements, aggregate evidence counts, and
provenance fields such as `releaseClaim.requirements`,
`supportScope.workflowCapableEvidenceCount`,
`supportScope.localCommandOnlyEvidenceCount`,
`coverage.productionRecommendedRuntimeEvidenceCount`,
`coverage.runtimeSupportTiers`,
`sourceControl.commitSha`, and `bundleCi.workflowName`, so reviewers can match
the final claim to the source revision and bundle-producing CI run without
exposing raw host evidence.
They intentionally avoid raw coverage rows, collection commands,
workflow-dispatch commands, and bundle paths.
The redacted summary is produced by
`scripts/dev/New-ReleaseReadinessSummary.ps1`; its self-test verifies that the
summary preserves aggregate proof/provenance while excluding detailed evidence
rows and machine-specific paths.
`scripts/dev/Write-ReleaseReadinessStepSummary.ps1` writes the GitHub step
summary from that redacted summary only, so reviewer-facing Markdown does not
read the detailed readiness JSON.
The bundle resolver self-test verifies the single-zip default path, explicit
bundle filenames, missing bundles, multiple bundles, and unsafe filename
rejections.

`evidence/`, `evidence-downloads/`, and `release-evidence/` are generated,
git-ignored local output. They may contain machine-specific paths from the
collector host, so do not commit them. Publish the redacted
`release-readiness-summary.json` as the normal CI/review artifact. Keep full
evidence bundles in restricted private storage, and upload them to GitHub
Actions only when `upload_private_bundle=true` is needed for a separate
verifier run.

After evidence is collected and validated, create a private evidence bundle:

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

The bundle manifest records each evidence file's SHA256, support dimensions,
Node runtime support tier, live status collector provenance including collector
SHA256 digest, exact collection workflow dispatch dimensions when present, and
explicit non-synthetic/non-mock/non-sample markers so later release reviews can
prove exactly which files supported the claim. It also records top-level
`supportScope` metadata, including scope kind, proof level, selected-vs-matrix
target counts, workflow-capable evidence counts, and local-command-only evidence
counts. Bundle verification recalculates those values from the manifest rows
and current support matrix, and also rejects
evidence whose declared `supportTargetId` is not corroborated by collected
OS/platform metadata, even when the manifest hashes match. It also rejects
saved Next.js evidence that no longer proves the required runtime platform
floor.

Verify a saved bundle with:

```powershell
.\scripts\dev\Test-SupportEvidenceBundle.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip
```

Check strict release readiness from the saved bundle with:

```powershell
.\scripts\dev\Test-ReleaseSupportReadiness.ps1 `
  -BundlePath .\release-evidence\node-enterprise-deploy-kit-1.0.0-evidence.zip `
  -IncludeServiceOnly `
  -IncludeFallback `
  -StrictCiRelease `
  -RequireFinalFullMatrixReleaseClaim
```

Readiness output includes `supportScope.kind`, `supportScope.proofLevel`,
selected target counts, workflow-capable evidence counts, local-command-only
evidence counts, and `releaseClaim.kind` for the active readiness review. It
also preserves the saved bundle's original `bundleSupportScope`.
`releaseClaim.requirements` records the safe checklist behind the final claim,
including full-matrix scope, strict CI release mode, warning-clean evidence,
complete coverage, workflow applicability metadata, runtime support metadata,
provenance requirements, collector SHA256, runtime-version requirements, and
minimum uptime. Treat `Ready: True` as valid only for the
stated review scope: `releaseClaim.finalFullMatrixReleaseClaim` must be `true`
before using the result as a final full-matrix release claim. A filtered,
provisional, production-runtime-only, or incomplete-coverage result is not a
full-matrix release claim.

To audit collected evidence against the matrix and list missing combinations:

```powershell
.\scripts\dev\Test-SupportEvidenceCoverage.ps1 `
  -EvidencePath .\evidence `
  -IncludeServiceOnly `
  -IncludeFallback
```

The same coverage auditor can read a saved bundle directly and write a
Markdown report for release review:

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
file, Node runtime support tier, local collector command, exact single-row
validation command, and, where supported, the exact manual
`gh workflow run host-evidence.yml` command to collect that evidence. These
commands fail on warning-only status evidence by default; add
`-AllowWarnings` when the missing-coverage report should generate
warning-tolerant collection commands instead. Workflow-capable rows include
`-RequireCiCollection` and `-RequireHostEvidenceWorkflowCollection` in the
single-row validation command; local-command-only rows omit those switches.
Coverage counts only evidence whose declared `supportTargetId` is corroborated
by collected OS/platform metadata and, for Next.js rows, still proves the
required runtime platform floor. Reports also include
`summary.coveragePercent` plus breakdowns by evidence kind, target category,
and workflow collection path. With `-ReportOnly`, a missing `EvidencePath` is
treated as zero collected evidence so the same command can produce a 0%
baseline before any host evidence has been imported.
The default table output prints the first missing collect/validate command
pairs; use Markdown, JSON, or CSV for the complete command list.

The full repository verifier runs the matrix check automatically:

```powershell
.\scripts\dev\Test-Repository.ps1
```

Linux targets must reference the `linux-family-static-checks` job and the
`linux-container-smoke` job. The static job checks the declared platform
mapping for every Linux, macOS, and BSD row. The container smoke job runs the
Unix deployment and Next.js checks inside public target or target-family
containers for Ubuntu, Debian, Linux Mint, RHEL/UBI, Oracle Linux,
CentOS/CentOS Stream, Rocky Linux, AlmaLinux, Fedora, and Alpine before any
release evidence is collected.

It also runs `Test-WindowsServiceManagers.ps1` and
`Test-SupportClaim.ps1 -SelfTest`, which validates the strict claim gate
against generated evidence for every target in the matrix across the declared
Next.js modes, service managers, and reverse-proxy implementations.
The verifier also runs `Test-SupportEvidenceCoverage.ps1 -SelfTest`, which
proves the coverage auditor can recognize complete strict, service-only, and
fallback evidence sets generated from the matrix, including fallback
service-only rows when both dimensions are declared.
It also runs `Test-ReleaseSupportReadiness.ps1 -SelfTest`, which proves a saved
full-matrix evidence bundle can pass integrity, support-claim, and coverage
gates before release signoff.

To validate an actual support claim against real host evidence, use:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 `
  -EvidencePath .\evidence `
  -TargetId windows-11,windows-server-2022,ubuntu,macos `
  -MaxEvidenceAgeDays 30
```

To test the support-claim validator itself without real host files:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 -SelfTest
```

For the strictest Next.js claim, require evidence for every declared Next.js
mode, service manager, service-only entry, fallback manager, and reverse-proxy
implementation on every selected primary target:

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

The strict mode check uses the evidence file's primary platform identity, so a
family alias such as `debian` inside Ubuntu metadata cannot satisfy a separate
Debian target claim.
Current status evidence writes `supportTargetId` / `SupportTargetId` and the
claim tools prefer that exact matrix ID before falling back to OS metadata
inference.
`-RequireHostEvidenceWorkflowCollection` applies to workflow-capable targets
such as Windows, Linux, and macOS; local-only BSD evidence is not rejected just
because GitHub Actions cannot collect it through the host-evidence workflow.

`-RequireDeclaredReverseProxies` checks concrete reverse-proxy implementations
such as IIS, Nginx, Apache, HAProxy, and Traefik. Add `-IncludeServiceOnly` to
require explicit `ReverseProxy=none` service-only or external-load-balancer
evidence; without it, `none` is not treated as a concrete reverse-proxy
implementation.

Fallback managers such as Windows PM2 are tracked in the matrix for migration
compatibility. Add `-IncludeFallback` when a release claim must also prove
those fallback service-manager rows. When `-IncludeFallback` and
`-IncludeServiceOnly` are both present, fallback `ReverseProxy=none` rows are
required too; primary strict service coverage still comes from the matrix
`serviceManagers` list.

## Required Next.js Modes

Every target in the matrix must support both:

- `standalone`
- `next-start`

`standalone` remains the recommended production mode. `next-start` is included
for compatibility when deploying a full app runtime is unavoidable.

## Required Minimum Uptime

The matrix field `requiredMinimumUptimeHours` defines the minimum sustained
runtime window required for strict real-host evidence and final
`-StrictCiRelease` signoff. The example matrix sets this to 72 hours. Evidence
plans generated by `New-SupportEvidencePlan.ps1`, coverage reports generated by
`Test-SupportEvidenceCoverage.ps1`, host-evidence workflow input validation,
support-claim self-tests, and release-readiness strict mode all use this matrix
value instead of carrying separate hardcoded release policy. Generated local
collector commands include the matching `-MinimumUptimeHours` or
`--minimum-uptime-hours` flag.

Rows that cannot be dispatched through the GitHub `host-evidence` workflow are
still real-host evidence rows, but the bundle manifest must mark them
`localCommandOnly: true`. `-StrictCiRelease` requires controlled workflow
collection for workflow-capable rows, rejects warning-tolerant signoff, and
accepts local-command-only rows only with the same live/runtime/collector/uptime
evidence checks.
The host-evidence validator also requires the declared `supportTargetId` to be
corroborated by platform metadata derived from the host OS; a JSON file cannot
prove a matrix row by declaring that target ID alone.
For strict Next.js claims, that same validator requires the collected platform
metadata to prove the Node.js runtime platform floor where it applies: Windows
build number, Linux kernel and glibc versions, or macOS product version and
architecture.
Saved bundle verification and coverage reports enforce the same floor so stale
evidence cannot keep a matrix row covered.

## Node Runtime Support Tiers

Current Next.js releases require Node.js `20.9.0` or newer, so every matrix row
also declares `nodeRuntimeSupport`. This is separate from service/reverse-proxy
support: a row can have scripts and real-host evidence while still being a
legacy or community runtime target.

The support tiers are:

- `tier-1`: production-recommended when the host meets the listed Node.js
  platform floor.
- `experimental`: Node.js lists the platform family as Experimental for the
  Node major required by current Next.js.
- `community-package`: the target depends on an OS package or locally
  maintained Node runtime rather than an official Node.js release-platform row.

Windows Server 2012 / 2012 R2, Alpine/musl, and FreeBSD are intentionally
marked `experimental`. OpenBSD and NetBSD are intentionally marked
`community-package`. These rows still require real-host evidence when claimed,
but the example matrix does not mark them production-recommended. Prefer
Windows Server 2016 or newer, GNU/Linux hosts that meet the kernel/glibc floor,
or supported macOS versions for production Next.js support.

Use `Test-ReleaseSupportReadiness.ps1 -ProductionRecommendedOnly` when the
release decision should cover only production-recommended runtime rows. Use
`-RequireProductionRecommendedRuntime` when the evidence bundle itself must not
contain experimental or community-package runtime rows.
When `New-SupportEvidenceBundle.ps1` runs with target, category, or production
filters, only matching evidence files are copied into the archived bundle.

## Current Target Families

| Target group | Matrix IDs | Service manager | Reverse proxy options | Node.js runtime support |
|---|---|---|---|---|
| Windows clients | `windows-10`, `windows-11` | WinSW, NSSM; PM2 fallback outside strict real-host service claims | IIS or none | Tier 1 for Node.js 20.x |
| Windows Server | `windows-server-2016`, `windows-server-2019`, `windows-server-2022`, `windows-server-2025` | WinSW, NSSM | IIS or none | Tier 1 for Node.js 20.x |
| Legacy Windows Server | `windows-server-2012`, `windows-server-2012-r2` | WinSW, NSSM | IIS or none | Experimental for Node.js 20.x; not production-recommended |
| Debian family | `ubuntu`, `debian`, `linux-mint` | systemd or System V | Nginx, Apache, HAProxy, Traefik, or none | Tier 1 when kernel/glibc floors are met |
| RHEL family | `rhel`, `oracle-linux`, `centos`, `centos-stream`, `rocky`, `almalinux`, `fedora` | systemd or System V where applicable | Nginx, Apache, HAProxy, Traefik, or none | Tier 1 when kernel/glibc floors are met |
| Alpine | `alpine` | OpenRC | Nginx, Apache, HAProxy, Traefik, or none | Experimental musl runtime; not production-recommended |
| macOS | `macos` | launchd | Nginx, Apache, HAProxy, Traefik, or none | Tier 1 when macOS architecture/version floor is met |
| BSD | `freebsd`, `openbsd`, `netbsd` | bsdrc | Nginx, Apache, HAProxy, Traefik, or none | FreeBSD experimental; OpenBSD/NetBSD community-package |

## Real Evidence Gate

Collect status JSON from every target you want to claim:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-10,windows-11,windows-server-2019,windows-server-2022,ubuntu,debian,rhel,alpine,macos `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity `
  -RequireCollectorSha256 `
  -RequireMinimumUptimeHours 72 `
  -MaxEvidenceAgeDays 30 `
  -FailOnWarnings
```

Use additional `windows-server-*` and Linux distribution IDs from the support
matrix when the release claim names those exact targets.
