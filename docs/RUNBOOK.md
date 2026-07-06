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
traefik check --configFile=/etc/traefik/traefik.yml
```

Linux diagnostics are summary-only by default. For deep incident response, run
`sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env --include-raw-details`
and treat the generated file as sensitive because it may include logs, process
arguments, and HTTP response bodies.

## Emergency Recovery

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
sudo grep -Ec ' OK |FAILED|RESTARTING_SERVICE|RESTART_SUPPRESSED' /var/log/<app-name>/healthcheck.log
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
   `ready: true`, `supportScope.kind: full-matrix`, and
   `releaseClaim.finalFullMatrixReleaseClaim: true` for a final full-matrix
   claim. Also check `releaseClaim.requirements.coverageComplete: true`,
   `releaseClaim.requirements.workflowApplicabilityKnown: true`,
   `releaseClaim.requirements.runtimeSupportMetadataKnown: true`,
   `releaseClaim.requirements.strictCiRelease: true`, and
   `releaseClaim.requirements.warningClean: true`.
8. Keep `evidence/`, `evidence-downloads/`, `release-evidence/`, and full
   support evidence bundles out of git. Store them only in restricted private
   release/change records.
9. If using `.github/workflows/support-evidence-bundle.yml`, leave
   `upload_private_bundle=false` unless a separate verifier workflow is
   explicitly required and the repository/artifact visibility is acceptable.
10. Record the final commit SHA, CI run URL, redacted readiness summary, and
    private evidence bundle location in the release/change record.
