[Unit]
Description={{APP_DISPLAY_NAME}}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{SERVICE_USER}}
Group={{SERVICE_GROUP}}
WorkingDirectory={{APP_DIR}}
EnvironmentFile=-{{ENV_FILE}}
ExecStart={{NODE_BIN}} {{START_SCRIPT}} {{NODE_ARGUMENTS}}
Restart=always
RestartSec={{FAILURE_RESTART_DELAY}}
KillSignal=SIGINT
TimeoutStopSec=30
StandardOutput=append:{{LOG_DIR}}/stdout.log
StandardError=append:{{LOG_DIR}}/stderr.log
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths={{APP_DIR}} {{LOG_DIR}}

[Install]
WantedBy=multi-user.target
