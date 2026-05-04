#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-config/linux/app.env}"
CONFIG_FILE="$(resolve_config_path "$REPO_ROOT" "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config file not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

PLATFORM_FAMILY="$(detect_platform_family)"
SERVICE_MANAGER="${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}"
APP_DESCRIPTION="${APP_DESCRIPTION:-$APP_DISPLAY_NAME}"
NODE_ARGUMENTS="${NODE_ARGUMENTS:-}"
FAILURE_RESTART_DELAY="${FAILURE_RESTART_DELAY:-60}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/usr/local/sbin/${APP_NAME}-runner.sh}"
INSTALL_COMMAND="${INSTALL_COMMAND:-}"
BUILD_COMMAND="${BUILD_COMMAND:-}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
RUNTIME_ENV_KEYS="${RUNTIME_ENV_KEYS:-}"

require_root() { if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi; }
write_env_value() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value" >> "$ENV_FILE"
}
write_runtime_env_file() {
  local tmp
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  ENV_FILE="$tmp" write_env_value "NODE_ENV" "$NODE_ENV"
  ENV_FILE="$tmp" write_env_value "PORT" "$APP_PORT"
  ENV_FILE="$tmp" write_env_value "APP_NAME" "$APP_NAME"
  ENV_FILE="$tmp" write_env_value "BIND_ADDRESS" "$BIND_ADDRESS"

  for key in $RUNTIME_ENV_KEYS; do
    case "$key" in
      NODE_ENV|PORT|APP_PORT|APP_NAME|BIND_ADDRESS|"") continue ;;
    esac
    if [[ -n "${!key+x}" ]]; then
      ENV_FILE="$tmp" write_env_value "$key" "${!key}"
    fi
  done
  replace_file_with_backup "$tmp" "$ENV_FILE" "$BACKUP_DIR"
}
run_as_service_user() {
  local command_text="$1" label="$2"
  if [[ -z "$command_text" ]]; then
    echo "$label skipped; no command configured."
    return
  fi
  echo "Running $label..."
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$SERVICE_USER" -- bash -lc "cd \"$APP_DIR\" && $command_text"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh "$SERVICE_USER" -c "cd \"$APP_DIR\" && $command_text"
  else
    echo "Cannot run $label as $SERVICE_USER; install runuser/su or run the command manually." >&2
    exit 1
  fi
}
render_template() {
  local template="$1" output="$2"
  render_template_file "$template" "$output" \
    APP_NAME "$APP_NAME" \
    APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
    APP_DESCRIPTION "$APP_DESCRIPTION" \
    SERVICE_USER "$SERVICE_USER" \
    SERVICE_GROUP "$SERVICE_GROUP" \
    APP_DIR "$APP_DIR" \
    ENV_FILE "$ENV_FILE" \
    NODE_BIN "$NODE_BIN" \
    START_SCRIPT "$START_SCRIPT" \
    NODE_ARGUMENTS "$NODE_ARGUMENTS" \
    FAILURE_RESTART_DELAY "$FAILURE_RESTART_DELAY" \
    LOG_DIR "$LOG_DIR" \
    RUNNER_SCRIPT "$RUNNER_SCRIPT"
}

ensure_group() {
  if getent group "$SERVICE_GROUP" >/dev/null 2>&1 || dscl . -read "/Groups/$SERVICE_GROUP" >/dev/null 2>&1 || pw groupshow "$SERVICE_GROUP" >/dev/null 2>&1; then
    return
  fi
  if [[ "$PLATFORM_FAMILY" == "macos" ]]; then
    echo "Group $SERVICE_GROUP does not exist on macOS. Create it first or set SERVICE_GROUP to an existing group." >&2
    exit 1
  elif command -v groupadd >/dev/null 2>&1; then
    groupadd --system "$SERVICE_GROUP" 2>/dev/null || groupadd "$SERVICE_GROUP"
  elif command -v pw >/dev/null 2>&1; then
    pw groupadd "$SERVICE_GROUP"
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
  if [[ "$PLATFORM_FAMILY" == "macos" ]]; then
    echo "User $SERVICE_USER does not exist on macOS. Create it first or set SERVICE_USER to an existing user." >&2
    exit 1
  fi
  local nologin_shell="/usr/sbin/nologin"
  if [[ ! -x "$nologin_shell" ]]; then nologin_shell="/sbin/nologin"; fi
  if [[ ! -x "$nologin_shell" ]]; then nologin_shell="/bin/false"; fi
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_GROUP" --home-dir "$APP_DIR" --shell "$nologin_shell" "$SERVICE_USER" 2>/dev/null \
      || useradd -g "$SERVICE_GROUP" -d "$APP_DIR" -s "$nologin_shell" "$SERVICE_USER" 2>/dev/null \
      || useradd -g "$SERVICE_GROUP" -d "$APP_DIR" -s "$nologin_shell" -m "$SERVICE_USER"
  elif command -v pw >/dev/null 2>&1; then
    pw useradd "$SERVICE_USER" -g "$SERVICE_GROUP" -d "$APP_DIR" -s "$nologin_shell" -w no
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
  write_runtime_env_file
  chmod 0640 "$ENV_FILE"
  chown root:"$SERVICE_GROUP" "$ENV_FILE" || true
}
prepare_app() {
  if [[ "$SKIP_INSTALL" != "true" ]]; then
    run_as_service_user "$INSTALL_COMMAND" "INSTALL_COMMAND"
  fi
  if [[ "$SKIP_BUILD" != "true" ]]; then
    run_as_service_user "$BUILD_COMMAND" "BUILD_COMMAND"
  fi
}

install_systemd_service() {
  require_command systemctl "Install systemd or set SERVICE_MANAGER to systemv or openrc."
  local service_file="/etc/systemd/system/${APP_NAME}.service"
  render_template "$REPO_ROOT/templates/linux/systemd-node-app.service.tpl" "$service_file"
  chmod 0644 "$service_file"
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

install_launchd_service() {
  require_command launchctl "launchd is required on macOS."
  mkdir -p "$(dirname "$RUNNER_SCRIPT")" "$LOG_DIR"
  render_template "$REPO_ROOT/templates/linux/launchd-runner.sh.tpl" "$RUNNER_SCRIPT"
  chmod 0755 "$RUNNER_SCRIPT"
  chown root:wheel "$RUNNER_SCRIPT" 2>/dev/null || true

  local plist_file="/Library/LaunchDaemons/${APP_NAME}.plist"
  render_template "$REPO_ROOT/templates/linux/launchd-node-app.plist.tpl" "$plist_file"
  chmod 0644 "$plist_file"
  chown root:wheel "$plist_file" 2>/dev/null || true

  launchctl bootout system "$plist_file" >/dev/null 2>&1 || true
  launchctl bootstrap system "$plist_file"
  launchctl enable "system/${APP_NAME}" 2>/dev/null || true
  launchctl kickstart -k "system/${APP_NAME}" 2>/dev/null || true
  launchctl print "system/${APP_NAME}" >/dev/null 2>&1 || true
  echo "Installed launchd service: $APP_NAME"
}

install_bsdrc_service() {
  local init_dir="/usr/local/etc/rc.d"
  if [[ ! -d "$init_dir" ]]; then
    init_dir="/etc/rc.d"
  fi
  mkdir -p "$init_dir"
  local init_file="${init_dir}/${APP_NAME}"
  render_template "$REPO_ROOT/templates/linux/bsdrc-node-app.init.tpl" "$init_file"
  chmod 0755 "$init_file"

  case "$PLATFORM_FAMILY" in
    freebsd)
      if command -v sysrc >/dev/null 2>&1; then
        sysrc "${APP_NAME}_enable=YES" >/dev/null || true
      else
        echo "${APP_NAME}_enable=\"YES\"" >> /etc/rc.conf
      fi
      ;;
    openbsd)
      if command -v rcctl >/dev/null 2>&1; then
        rcctl enable "$APP_NAME" 2>/dev/null || true
      fi
      ;;
    netbsd)
      if ! grep -q "^${APP_NAME}=YES" /etc/rc.conf 2>/dev/null; then
        echo "${APP_NAME}=YES" >> /etc/rc.conf
      fi
      ;;
  esac

  if command -v service >/dev/null 2>&1; then
    service "$APP_NAME" restart || "$init_file" restart
    service "$APP_NAME" status || "$init_file" status || true
  elif command -v rcctl >/dev/null 2>&1; then
    rcctl restart "$APP_NAME" 2>/dev/null || "$init_file" restart
    rcctl check "$APP_NAME" 2>/dev/null || "$init_file" status || true
  else
    "$init_file" restart
    "$init_file" status || true
  fi
  echo "Installed BSD rc service: $APP_NAME"
}

require_root
prepare_runtime
prepare_app

SERVICE_MANAGER_NORMALIZED="$(normalize_name "$SERVICE_MANAGER")"
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
  launchd)
    install_launchd_service
    ;;
  bsdrc|bsd-rc|rcd|rc.d)
    install_bsdrc_service
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER. Use systemd, systemv, openrc, launchd, or bsdrc." >&2
    exit 1
    ;;
esac

echo "Logs: $LOG_DIR"
