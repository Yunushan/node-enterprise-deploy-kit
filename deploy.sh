#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE. Copy config/linux/app.env.example first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER_NORMALIZED="$(echo "${SERVICE_MANAGER:-systemd}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
REVERSE_PROXY_NORMALIZED="$(echo "${REVERSE_PROXY:-none}" | tr '[:upper:]' '[:lower:]')"

sudo ./scripts/linux/install-node-service.sh "$CONFIG_FILE"

case "$REVERSE_PROXY_NORMALIZED" in
  nginx)
    sudo ./scripts/linux/install-nginx-reverse-proxy.sh "$CONFIG_FILE"
    ;;
  apache|httpd)
    sudo ./scripts/linux/install-apache-reverse-proxy.sh "$CONFIG_FILE"
    ;;
  none|"")
    ;;
  *)
    echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, or none." >&2
    exit 1
    ;;
esac

if [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]]; then
  sudo ./scripts/linux/install-healthcheck-timer.sh "$CONFIG_FILE"
else
  echo "Skipping systemd healthcheck timer for SERVICE_MANAGER=${SERVICE_MANAGER:-systemd}."
fi

echo "Deployment finished for ${APP_NAME}."
