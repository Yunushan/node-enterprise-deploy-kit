#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config file not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

require_root() { if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi; }
render_template() {
  local template="$1" output="$2"
  sed \
    -e "s|{{APP_NAME}}|${APP_NAME}|g" \
    -e "s|{{APP_DISPLAY_NAME}}|${APP_DISPLAY_NAME}|g" \
    -e "s|{{SERVICE_USER}}|${SERVICE_USER}|g" \
    -e "s|{{SERVICE_GROUP}}|${SERVICE_GROUP}|g" \
    -e "s|{{APP_DIR}}|${APP_DIR}|g" \
    -e "s|{{ENV_FILE}}|${ENV_FILE}|g" \
    -e "s|{{NODE_BIN}}|${NODE_BIN}|g" \
    -e "s|{{START_SCRIPT}}|${START_SCRIPT}|g" \
    -e "s|{{NODE_ARGUMENTS}}|${NODE_ARGUMENTS}|g" \
    -e "s|{{FAILURE_RESTART_DELAY}}|${FAILURE_RESTART_DELAY}|g" \
    -e "s|{{LOG_DIR}}|${LOG_DIR}|g" \
    "$template" > "$output"
}
require_root
if ! id "$SERVICE_USER" >/dev/null 2>&1; then useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"; fi
mkdir -p "$APP_DIR" "$LOG_DIR" "$(dirname "$ENV_FILE")"
touch "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$APP_DIR" "$LOG_DIR" || true
chmod 0750 "$LOG_DIR"
cat > "$ENV_FILE" <<EOF
NODE_ENV=${NODE_ENV}
PORT=${APP_PORT}
APP_NAME=${APP_NAME}
BIND_ADDRESS=${BIND_ADDRESS}
EOF
chmod 0640 "$ENV_FILE"
chown root:"$SERVICE_GROUP" "$ENV_FILE" || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
render_template "$REPO_ROOT/templates/linux/systemd-node-app.service.tpl" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl restart "$APP_NAME"
systemctl --no-pager status "$APP_NAME" || true
echo "Installed systemd service: $APP_NAME"
echo "Logs: $LOG_DIR"
