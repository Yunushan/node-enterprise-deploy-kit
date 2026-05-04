#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CONFIG_FILE="${1:-$REPO_ROOT/config/linux/app.env}"
if [[ "$CONFIG_FILE" != /* ]]; then
  CONFIG_FILE="$REPO_ROOT/$CONFIG_FILE"
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE. Copy config/linux/app.env.example first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER_NORMALIZED="$(echo "${SERVICE_MANAGER:-systemd}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
REVERSE_PROXY_NORMALIZED="$(echo "${REVERSE_PROXY:-none}" | tr '[:upper:]' '[:lower:]')"

sudo bash "$REPO_ROOT/scripts/linux/install-node-service.sh" "$CONFIG_FILE"

case "$REVERSE_PROXY_NORMALIZED" in
  nginx)
    sudo bash "$REPO_ROOT/scripts/linux/install-nginx-reverse-proxy.sh" "$CONFIG_FILE"
    ;;
  apache|httpd)
    sudo bash "$REPO_ROOT/scripts/linux/install-apache-reverse-proxy.sh" "$CONFIG_FILE"
    ;;
  none|"")
    ;;
  *)
    echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, or none." >&2
    exit 1
    ;;
esac

if [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]]; then
  sudo bash "$REPO_ROOT/scripts/linux/install-healthcheck-timer.sh" "$CONFIG_FILE"
else
  echo "Skipping systemd healthcheck timer for SERVICE_MANAGER=${SERVICE_MANAGER:-systemd}."
fi

echo "Deployment finished for ${APP_NAME}."
