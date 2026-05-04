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
Copy-Item C:\services\ExampleNodeApp\backups\ExampleNodeApp.xml.<timestamp>.bak C:\services\ExampleNodeApp\ExampleNodeApp.xml -Force
Copy-Item C:\services\ExampleNodeApp\backups\web.config.<timestamp>.bak C:\inetpub\wwwroot\ExampleNodeApp\web.config -Force
Restart-Service ExampleNodeApp
```

Linux example:

```bash
sudo cp -p /var/backups/example-node-app/example-node-app.service.<timestamp>.bak /etc/systemd/system/example-node-app.service
sudo systemctl daemon-reload
sudo systemctl restart example-node-app
```

For Nginx or Apache rollback, restore the backed-up proxy config, run the
native config test, then reload the proxy service.
