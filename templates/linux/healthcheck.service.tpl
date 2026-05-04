[Unit]
Description=Health check for {{APP_DISPLAY_NAME}}

[Service]
Type=oneshot
ExecStart={{HEALTHCHECK_COMMAND}}
