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

The matrix validator checks target IDs, required Next.js modes, CI/static
verification references, platform-family mappings, evidence target names, and
the concrete installer/template artifacts for each declared service manager,
fallback manager, and reverse proxy.

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
can stay precise.

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
live status collector provenance, and explicit non-synthetic/non-mock/non-sample
markers so later release reviews can prove exactly which files supported the
claim.

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

The full repository verifier runs the matrix check automatically:

```powershell
.\scripts\dev\Test-Repository.ps1
```

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

## Current Target Families

| Target group | Matrix IDs | Service manager | Reverse proxy options |
|---|---|---|---|
| Windows clients | `windows-10`, `windows-11` | WinSW, NSSM; PM2 fallback outside strict real-host service claims | IIS or none |
| Windows Server | `windows-server-2012`, `windows-server-2012-r2`, `windows-server-2016`, `windows-server-2019`, `windows-server-2022`, `windows-server-2025` | WinSW, NSSM | IIS or none |
| Debian family | `ubuntu`, `debian`, `linux-mint` | systemd or System V | Nginx, Apache, HAProxy, Traefik, or none |
| RHEL family | `rhel`, `oracle-linux`, `centos`, `centos-stream`, `rocky`, `almalinux`, `fedora` | systemd or System V where applicable | Nginx, Apache, HAProxy, Traefik, or none |
| Alpine | `alpine` | OpenRC | Nginx, Apache, HAProxy, Traefik, or none |
| macOS | `macos` | launchd | Nginx, Apache, HAProxy, Traefik, or none |
| BSD | `freebsd`, `openbsd`, `netbsd` | bsdrc | Nginx, Apache, HAProxy, Traefik, or none |

## Real Evidence Gate

Collect status JSON from every target you want to claim:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-10,windows-11,windows-server-2019,windows-server-2022,ubuntu,debian,rhel,alpine,macos `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity `
  -MaxEvidenceAgeDays 30 `
  -FailOnWarnings
```

Use additional `windows-server-*` and Linux distribution IDs from the support
matrix when the release claim names those exact targets.
