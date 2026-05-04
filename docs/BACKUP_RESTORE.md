# Backup and Restore

This project deploys applications, services, and proxy configs. It does not know your application database. Back up databases separately.

## Back Up

- Application release directory.
- Environment/config files.
- IIS/Nginx/Apache configuration.
- Service wrapper XML, systemd unit, or init script.
- Logs if needed for audit.
- External database.

The deployment scripts automatically create timestamped backups before they
replace managed service, proxy, or health-check files. Backups are only created
when the target file exists and the new content differs.
Health checks prune old managed backup files after `BackupRetentionDays` /
`BACKUP_RETENTION_DAYS`.

Default backup locations:

```text
Windows: BackupDirectory from app.config.json, otherwise <ServiceDirectory>\backups
Linux:   BACKUP_DIR from app.env, otherwise /var/backups/<APP_NAME>
```

Managed files include:

- WinSW service executable and XML.
- IIS `web.config`.
- Windows scheduled health-check task export.
- Linux runtime env file.
- Linux systemd unit or init script.
- Nginx/Apache reverse proxy config.
- Linux health-check script, config, service, and timer.

## Restore

1. Restore app directory or deploy previous artifact.
2. Restore config/env file.
3. Reinstall service using this kit.
4. Reinstall reverse proxy if needed.
5. Start service.
6. Verify health.

## Restore Managed Config From Backup

Windows example:

```powershell
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -List
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target ServiceXml -Latest -RestartService
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -Target IisWebConfig -Latest -RecycleIisAppPool
.\status.ps1 -ConfigPath .\config\windows\app.config.json -FailOnCritical
```

You can restore a specific backup file instead of the latest file:

```powershell
.\rollback.ps1 -ConfigPath .\config\windows\app.config.json -BackupPath C:\services\ExampleNodeApp\backups\web.config.20260504120000.1234.bak -RecycleIisAppPool
```

Linux example:

```bash
sudo cp -p /var/backups/example-node-app/example-node-app.service.<timestamp>.bak /etc/systemd/system/example-node-app.service
sudo systemctl daemon-reload
sudo systemctl restart example-node-app
```

For Nginx or Apache rollback, restore the backed-up proxy config, run the
native config test, then reload the proxy service.

## Windows Managed Rollback Targets

`rollback.ps1` and `scripts/windows/Restore-ManagedBackup.ps1` only touch
managed backup types produced by this kit:

| Target | Restores |
|---|---|
| `ServiceExe` | WinSW wrapper executable under `ServiceDirectory` |
| `ServiceXml` | WinSW XML under `ServiceDirectory` |
| `IisWebConfig` | IIS site `web.config` under `IisSitePath` |
| `HealthCheckTask` | Exported Windows scheduled task XML |
| `All` | Latest backup for each available managed target |

Use `-RestartService` when restoring `ServiceExe` or `ServiceXml`. Use
`-RecycleIisAppPool` when restoring `IisWebConfig` and you want IIS to reload
immediately. The helper requires Administrator rights for restore operations,
but listing backups does not.

Rollback does not replace a full release strategy. If the application files
changed, restore or redeploy the previous application artifact first, then
restore managed service/proxy/task config if needed, and finish with
`status.ps1`.
