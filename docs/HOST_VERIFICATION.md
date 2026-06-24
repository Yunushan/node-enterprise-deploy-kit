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
path basenames, platform metadata, and redacted finding messages. It does not
include runtime environment values, raw host identity, full filesystem paths,
raw logs, or HTTP response bodies.

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

For a stricter support claim across the expanded matrix:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 `
  -EvidencePath .\evidence `
  -RequiredTargets windows-server-2019,windows-server-2022,ubuntu,debian,rhel,oracle-linux,centos-stream,fedora,linux-mint,macos,freebsd,openbsd,netbsd `
  -RequireNextJs `
  -RequireReverseProxy `
  -RequireDeploymentIdentity `
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
- The platform metadata matches the target being claimed.
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
  valid deployment mode, and a successful runtime layout check.
- For reverse-proxy deployments, `-RequireReverseProxy` proves the proxy health
  route returned a successful HTTP status.
- For Windows IIS reverse-proxy deployments, `-RequireReverseProxy` also proves
  the configured IIS site exists, its physical path matches the configured
  deployment path, it owns the expected public binding, and no other IIS site
  has the same binding.
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
  old release folder, a different site owns the public binding, or duplicate
  IIS sites share the same public binding.
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
7. Keep the JSON files with the private release record.

This kit can provide templates and validators for many platforms. A platform is
only proven for a given release after the real-host evidence exists and passes
the evidence validator.
