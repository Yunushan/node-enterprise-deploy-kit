#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config file not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
APP_DESCRIPTION="${APP_DESCRIPTION:-$APP_DISPLAY_NAME}"
NODE_ARGUMENTS="${NODE_ARGUMENTS:-}"
FAILURE_RESTART_DELAY="${FAILURE_RESTART_DELAY:-60}"

require_root() { if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi; }
require_command() {
  local command_name="$1" help_text="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required. $help_text" >&2
    exit 1
  fi
}
render_template() {
  local template="$1" output="$2"
  sed \
    -e "s|{{APP_NAME}}|${APP_NAME}|g" \
    -e "s|{{APP_DISPLAY_NAME}}|${APP_DISPLAY_NAME}|g" \
    -e "s|{{APP_DESCRIPTION}}|${APP_DESCRIPTION}|g" \
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

ensure_group() {
  if getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    return
  fi
  if command -v groupadd >/dev/null 2>&1; then
    groupadd --system "$SERVICE_GROUP" 2>/dev/null || groupadd "$SERVICE_GROUP"
  elif command -v addgroup >/dev/null 2>&1; then
    addgroup -S "$SERVICE_GROUP" 2>/dev/null || addgroup "$SERVICE_GROUP"
  else
    echo "Cannot create group $SERVICE_GROUP; install user management tools or create it manually." >&2
    exit 1
  fi
}

ensure_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    return
  fi
  local nologin_shell="/usr/sbin/nologin"
  if [[ ! -x "$nologin_shell" ]]; then nologin_shell="/sbin/nologin"; fi
  if [[ ! -x "$nologin_shell" ]]; then nologin_shell="/bin/false"; fi
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_GROUP" --home-dir "$APP_DIR" --shell "$nologin_shell" "$SERVICE_USER" 2>/dev/null \
      || useradd -g "$SERVICE_GROUP" -d "$APP_DIR" -s "$nologin_shell" "$SERVICE_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -D -H -h "$APP_DIR" -s "$nologin_shell" -G "$SERVICE_GROUP" "$SERVICE_USER" 2>/dev/null \
      || adduser -D -h "$APP_DIR" -s "$nologin_shell" -G "$SERVICE_GROUP" "$SERVICE_USER"
  else
    echo "Cannot create user $SERVICE_USER; install user management tools or create it manually." >&2
    exit 1
  fi
}

prepare_runtime() {
  ensure_group
  ensure_user
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
}

install_systemd_service() {
  require_command systemctl "Install systemd or set SERVICE_MANAGER to systemv or openrc."
  local service_file="/etc/systemd/system/${APP_NAME}.service"
  render_template "$REPO_ROOT/templates/linux/systemd-node-app.service.tpl" "$service_file"
  systemctl daemon-reload
  systemctl enable "$APP_NAME"
  systemctl restart "$APP_NAME"
  systemctl --no-pager status "$APP_NAME" || true
  echo "Installed systemd service: $APP_NAME"
}

install_systemv_service() {
  local init_file="/etc/init.d/${APP_NAME}"
  render_template "$REPO_ROOT/templates/linux/sysv-node-app.init.tpl" "$init_file"
  chmod 0755 "$init_file"
  if command -v update-rc.d >/dev/null 2>&1; then
    update-rc.d "$APP_NAME" defaults
  elif command -v chkconfig >/dev/null 2>&1; then
    chkconfig --add "$APP_NAME"
    chkconfig "$APP_NAME" on
  else
    echo "No System V service registration tool found; start $init_file manually or register it with your distro." >&2
  fi
  if command -v service >/dev/null 2>&1; then
    service "$APP_NAME" restart
    service "$APP_NAME" status || true
  else
    "$init_file" restart
    "$init_file" status || true
  fi
  echo "Installed System V service: $APP_NAME"
}

install_openrc_service() {
  require_command rc-update "Install OpenRC or set SERVICE_MANAGER to systemd or systemv."
  require_command rc-service "Install OpenRC service tools."
  local init_file="/etc/init.d/${APP_NAME}"
  render_template "$REPO_ROOT/templates/linux/openrc-node-app.init.tpl" "$init_file"
  chmod 0755 "$init_file"
  rc-update add "$APP_NAME" default
  rc-service "$APP_NAME" restart
  rc-service "$APP_NAME" status || true
  echo "Installed OpenRC service: $APP_NAME"
}

require_root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
prepare_runtime

SERVICE_MANAGER_NORMALIZED="$(echo "$SERVICE_MANAGER" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    install_systemd_service
    ;;
  systemv|sysv|sysvinit|initd|init-d)
    install_systemv_service
    ;;
  openrc)
    install_openrc_service
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER. Use systemd, systemv, or openrc." >&2
    exit 1
    ;;
esac

echo "Logs: $LOG_DIR"
