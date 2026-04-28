#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-/etc/node-enterprise-deploy-kit/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/healthcheck.log"
log() { echo "$(date -Is) $*" >> "$LOG_FILE"; }
if ! systemctl is-active --quiet "$APP_NAME"; then
  log "SERVICE_NOT_RUNNING restarting service=$APP_NAME"
  systemctl restart "$APP_NAME" || true
  sleep 5
fi
if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null; then
  log "OK url=$HEALTH_URL"
  exit 0
fi
log "HTTP_FAILED url=$HEALTH_URL restarting service=$APP_NAME"
systemctl restart "$APP_NAME" || true
exit 1
