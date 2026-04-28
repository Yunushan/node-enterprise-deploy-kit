#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE. Copy config/linux/app.env.example first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

sudo ./scripts/linux/install-node-service.sh "$CONFIG_FILE"

if [[ "${REVERSE_PROXY}" == "nginx" ]]; then
  sudo ./scripts/linux/install-nginx-reverse-proxy.sh "$CONFIG_FILE"
fi

sudo ./scripts/linux/install-healthcheck-timer.sh "$CONFIG_FILE"

echo "Deployment finished for ${APP_NAME}."
