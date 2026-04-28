# Backup and Restore

This project deploys applications, services, and proxy configs. It does not know your application database. Back up databases separately.

## Back Up

- Application release directory.
- Environment/config files.
- IIS/Nginx/Apache configuration.
- Service wrapper XML, systemd unit, or init script.
- Logs if needed for audit.
- External database.

## Restore

1. Restore app directory or deploy previous artifact.
2. Restore config/env file.
3. Reinstall service using this kit.
4. Reinstall reverse proxy if needed.
5. Start service.
6. Verify health.
