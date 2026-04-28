[Unit]
Description=Run {{APP_DISPLAY_NAME}} health check every minute

[Timer]
OnBootSec=60
OnUnitActiveSec={{HEALTHCHECK_INTERVAL}}
AccuracySec=5
Unit={{APP_NAME}}-healthcheck.service

[Install]
WantedBy=timers.target
