[Unit]
Description=Health check for {{APP_DISPLAY_NAME}}

[Service]
Type=oneshot
ExecStart={{HEALTHCHECK_COMMAND}}
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths={{LOG_DIR}} {{BACKUP_DIR}} {{HEALTHCHECK_STATE_DIR}}
