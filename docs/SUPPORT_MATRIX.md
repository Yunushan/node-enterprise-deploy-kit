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

To generate a release-specific evidence checklist from the matrix:

```powershell
.\scripts\dev\New-SupportEvidencePlan.ps1 `
  -OutputPath .\evidence\support-evidence-plan.md `
  -Format Markdown
```

The generated plan separates strict real-host evidence, service-only
`ReverseProxy=none` evidence, and fallback-manager evidence so release claims
can stay precise. It also carries each target's Node runtime support tier so
collection plans make experimental and community-package targets visible before
evidence collection starts.

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
`host-evidence` / `workflow_dispatch` provenance by default, derives the
target/mode/service/proxy key from the evidence and matrix, and writes the
canonical evidence filename. Use `-AllowLocalCollection` only for explicitly
local-command evidence.

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
and verifies the bundle, and writes release readiness JSON. Add
`-StrictCiRelease` only for final CI-controlled signoff.

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
  -RequireCoverageComplete `
  -IncludeServiceOnly `
  -IncludeFallback
```

The bundle manifest records each evidence file's SHA256, support dimensions,
Node runtime support tier, live status collector provenance including collector
SHA256 digest, and explicit non-synthetic/non-mock/non-sample markers so later
release reviews can prove exactly which files supported the claim.

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
  -IncludeFallback
```

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
file, Node runtime support tier, local collector command, and, where supported,
the exact manual `gh workflow run host-evidence.yml` command to collect that
evidence.

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
fallback evidence sets generated from the matrix.
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
mode, service manager, and reverse-proxy implementation on every selected
primary target:

```powershell
.\scripts\dev\Test-SupportClaim.ps1 `
  -EvidencePath .\evidence `
  -TargetId windows-11,windows-server-2022,ubuntu,macos `
  -MaxEvidenceAgeDays 30 `
  -RequireBothNextJsModes `
  -RequireDeclaredServiceManagers `
  -RequireDeclaredReverseProxies
```

The strict mode check uses the evidence file's primary platform identity, so a
family alias such as `debian` inside Ubuntu metadata cannot satisfy a separate
Debian target claim.
Current status evidence writes `supportTargetId` / `SupportTargetId` and the
claim tools prefer that exact matrix ID before falling back to OS metadata
inference.

`-RequireDeclaredReverseProxies` checks concrete reverse-proxy implementations
such as IIS, Nginx, Apache, HAProxy, and Traefik. The matrix value `none` is a
service-only or external-load-balancer marker and is not treated as a
reverse-proxy implementation.

Fallback managers such as Windows PM2 are tracked in the matrix for migration
compatibility, but they are not service-manager coverage for strict
`real-host-verified` claims because the status evidence gate proves operating
system service state and boot enablement.

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
collection for workflow-capable rows and accepts local-command-only rows only
with the same live/runtime/collector/uptime evidence checks.

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
