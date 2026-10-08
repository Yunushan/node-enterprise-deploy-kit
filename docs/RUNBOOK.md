# Operations Runbook

## Normal Deployment

1. Run repository verification before release.
2. Pull or copy release artifact.
3. Run target preflight checks.
4. Install dependencies or unpack built artifact.
5. Run build command if needed.
6. Install/update service.
7. Restart service.
8. Verify health endpoint.
9. Verify reverse proxy response.
10. Confirm logs and monitoring.

Repository verification:

```powershell
.\scripts\dev\Test-Repository.ps1
```

## Windows Commands

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
.\install.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
.\scripts\windows\Diagnose-NodeApp.ps1 -ConfigPath .\config\windows\app.config.json
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
Get-ScheduledTaskInfo -TaskName <AppName>-HealthCheck
Get-Service <AppName>
Restart-Service <AppName>
Get-EventLog Application -Newest 50
```

Windows PM2 fallback commands must run as the daemon's unelevated owner. The
PM2 app name must not be `all`, begin with `-`, or be a JavaScript numeric
selector such as `123`, `1e2`, `0x10` or `Infinity`; PM2 can apply these to other
processes. A name such as `1api` is supported. Windows app names also reject
trailing dots and reserved device names (including extensions), so lock and
monitor directories identify the same application on both PowerShell editions.
The kit checks the caller's Windows token before each command, including status
queries that could otherwise start a daemon. An existing `PM2Home\pm2.pid`
must identify a readable, unelevated process owned by that account; a stale,
unknown-owner or elevated daemon fails closed. Stop an old elevated daemon and
migrate it to a dedicated unprivileged owner before retrying. Use WinSW/NSSM
for the administrative `install.ps1`/`deploy.ps1` workflow. PM2's Limited
monitor does not grant access to an elevated daemon's IPC. Protected monitor
registration/removal remains an administrator task; PM2 process uninstall runs
separately as its unelevated owner without `-RemoveHealthCheckTask`.

## Linux Commands

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
bash deploy.sh config/linux/app.env
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --json-output ./evidence/unix-status.json --fail-on-critical
sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env
systemctl status <app-name>
systemctl restart <app-name>
journalctl -u <app-name> -n 200 --no-pager
service <app-name> restart
rc-service <app-name> restart
launchctl print system/<app-name>
sudo launchctl kickstart -k system/<app-name>
rcctl check <app-name>
rcctl restart <app-name>
```

Reverse proxy checks:

```bash
nginx -t
apache2ctl configtest || httpd -t
haproxy -c -f /etc/haproxy/haproxy.cfg
node scripts/linux/validate-traefik-config.mjs "$(command -v traefik)" \
  /etc/traefik/dynamic/<app-name>.yml web <app-name>-router <app-name>-service
```

Use the configured Traefik entrypoint, router and service names in that command.
It validates the managed dynamic route with a disposable loopback Traefik
instance; verify the production proxy response separately.

Linux diagnostics are summary-only by default. For deep incident response, run
`sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env --include-raw-details`
and treat the generated file as sensitive because it may include logs, process
arguments, and HTTP response bodies.

Windows diagnostics also omit raw event messages, service command lines, Node
arguments, HTTP exception text, and URL credentials/query values by default.
Use `Diagnose-NodeApp.ps1 -IncludeRawDetails` only when those sensitive incident
details are needed, and keep the resulting file private. Default diagnostics
still contain operational host names and paths; review them before sharing.
Default Windows reports are private under
`%ProgramData%\node-enterprise-deploy-kit\healthchecks\<app>\diagnostics` and
require administrative access. `-OutputDirectory` selects a private incident
directory owned by the caller. Reparse paths are rejected. Reports have unique
names and are published as `.txt` only when complete; retention preserves open
reports and active `.tmp` files. A Limited PM2 monitor cannot prune administrator
reports; administrators must clean those reports under the configured retention
policy.

## Emergency Recovery

### Interrupted Deployment or Retained Recovery Journal

A caught deployment error restores the managed files and service state. A
deployment process termination, power loss, or machine crash can interrupt that
restoration. The kit does not automatically replay a journal after a reboot or
from a new process. Application-process restart is a separate service-manager
feature and does not prove deployment-process crash recovery.

If a deployment leaves a managed journal or package transaction state, keep its
service and health task stopped. New deployments and health monitoring refuse
to proceed while this app's recovery state remains. Do not delete the lock
directory, journal, or backup to bypass that refusal.

1. Preserve a private copy of the journal, original config, and recorded backup.
   They can contain environment values and other secrets.
2. Confirm no deployment is running. Inspect the recorded app path, service
   definition, monitor task, proxy configuration, and ACL snapshots; a partially
   written package state may require inspecting the timestamped app backup.
   For IIS recovery, pause all deployments on that host and hold the global IIS
   configuration mutex while restoring ARR or global-header values. Managed
   recovery journals block their own app; another app may have deployed since
   the interruption. Inspect those later changes before applying an older
   global snapshot. Direct IIS installer journals block new IIS installers
   until the retained state has been recovered.
3. With the service stopped, restore the previous application directory and
   managed configuration, permissions, service identity and startup policy,
   proxy configuration, and scheduler definition. Use the recorded pre-change
   values rather than the replacement configuration. Windows custom-account
   and Password-logon task restoration require the previous credentials.
4. Start the previous service only if it was previously running. Verify its
   previous HTTP endpoint and proxy route, then collect a clean status report.
5. Archive the recovered state outside the deployment lock directory, retain it
   with the incident record, and enable the restored monitor. A new deployment
   can then acquire the app lock normally.

The existing rollback commands below restore specific configuration backups;
they are not a complete restart-safe journal recovery command. Rehearse manual
recovery on the target host before making a crash-recovery support claim.

If the application is unresponsive:

1. Run diagnostics.
2. Restart service.
3. Check port and health URL.
4. Check reverse proxy logs.
5. Roll back to previous release if new deployment caused the issue.

Rollback helpers:

```powershell
Get-ChildItem C:\services\<AppName>\backups | Sort-Object LastWriteTime -Descending | Select-Object -First 10
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest -RecycleIisAppPool
.\status.ps1 -ConfigPath .\config\windows\app.config.json -FailOnCritical
```

```bash
sudo find /var/backups/<app-name> -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' | sort -r | head
```

Long-running health checks:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -FailOnCritical
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
```

For Windows, treat the deployment as healthy only when the operational verdict
has no critical findings, the service is running with automatic startup, the
configured port is owned by the configured service process tree, the HTTP health
probe succeeds, and the scheduled health check has a recent successful run.
Keep the `-JsonPath` output with the release record when you need proof for a
change window or uptime review. It is designed to avoid environment values,
raw logs, raw host identity, and full filesystem paths.

```bash
sudo cat /var/lib/node-enterprise-deploy-kit/<app-name>/healthcheck.state
sudo grep -Ec ' OK |FAILED|RESTARTING_SERVICE|RESTART_SUPPRESSED' /var/lib/node-enterprise-deploy-kit/<app-name>/logs/healthcheck.log
```

For Linux, macOS, and BSD service modes, treat the deployment as healthy only
when `status-node-app.sh --fail-on-critical` reports no critical findings,
the service manager sees the service as active and boot-enabled, the configured
port is listening, the HTTP health check succeeds, and the Next.js runtime
layout matches the configured deployment mode.
Use `--json-output` for the same kind of release evidence on Linux, macOS, and
BSD hosts; it follows the same privacy-safe evidence shape.

## Final Support Evidence Checklist

Before making a final support claim for a release, keep the raw evidence in a
private release record and publish only redacted readiness summaries.

1. Confirm the repository verification is green on the exact committed revision
   being released.
2. Deploy the release artifact to each claimed target host or self-hosted runner
   environment.
3. Wait for the required uptime window when the release requires uptime proof,
   such as 72 hours for strict support evidence.
4. Collect status JSON from each target with the expected target ID, Next.js
   deployment mode, service manager, and reverse proxy.
5. Run `Test-HostEvidence.ps1` or the generated collection-pack staging audit
   before bundling evidence.
6. Run `Invoke-SupportEvidenceReleaseWorkflow.ps1` with `-StrictCiRelease` and
   `-RequireFinalFullMatrixReleaseClaim` only from a clean, committed,
   CI-controlled final signoff path.
7. Review the redacted `release-readiness-summary.json`; it must report
   `ready: true`, a valid `generatedAtUtc`, `supportScope.kind: full-matrix`, and
   `releaseClaim.finalFullMatrixReleaseClaim: true` for a final full-matrix
   claim. Also check `releaseClaim.requirements.coverageComplete: true`,
   `bundleSupportScope.proofLevel: hardened-real-host-evidence`,
   `releaseClaim.requirements.nonSyntheticEvidenceRequired: true`,
   `releaseClaim.requirements.uniqueEvidencePayloadsRequired: true`,
   `releaseClaim.requirements.maxEvidenceAgeDaysRequired: >0`,
   `releaseClaim.requirements.workflowApplicabilityKnown: true`,
    `releaseClaim.requirements.runtimeSupportMetadataKnown: true`,
    `releaseClaim.requirements.strictCiRelease: true`,
    `releaseClaim.requirements.warningClean: true`, and
    `supportMatrix.sha256`, `supportMatrix.targetCount`,
    `supportMatrix.requiredMinimumUptimeHours`, and
    `supportMatrix.runtimeSupportTiers` matching the support matrix file used
    for review.
   The final summary verifier also requires `sourceControl.isGitRepository=true`,
   `sourceControl.commitSha` to be a lowercase 40-character git SHA, and
   `bundleCi.provider=github-actions`,
   `bundleCi.workflowName=support-evidence-bundle`,
   `bundleCi.eventName=workflow_dispatch`,
   numeric `bundleCi.runId`, numeric `bundleCi.runAttempt`, and
   `bundleCi.sha` matching `sourceControl.commitSha`.
8. Keep `evidence/`, `evidence-downloads/`, `release-evidence/`, and full
   support evidence bundles out of git. Store them only in restricted private
   release/change records.
9. If using `.github/workflows/support-evidence-bundle.yml`, leave
   `upload_private_bundle=false` unless a separate verifier workflow is
   explicitly required and the repository/artifact visibility is acceptable.
   Keep `matrix_path` set to the committed support matrix used for the release;
   workflow input validation requires it to be a tracked repository `.json`
   file.
10. Record the final commit SHA, CI run URL, redacted readiness summary, and
    private evidence bundle location in the release/change record.
