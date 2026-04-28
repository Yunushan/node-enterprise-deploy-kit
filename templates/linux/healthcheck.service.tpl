[Unit]
Description=Health check for {{APP_DISPLAY_NAME}}

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/{{APP_NAME}}-healthcheck.sh
