#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
[[ "$APP_NAME" =~ ^[A-Za-z0-9_.-]+$ && "$APP_NAME" != . && "$APP_NAME" != .. ]] || {
  echo "Unsafe APP_NAME." >&2; exit 1
}
PLATFORM_FAMILY="$(detect_platform_family)"
SERVICE_MANAGER="${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/usr/local/sbin/${APP_NAME}-runner.sh}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HC_SCRIPT="/usr/local/sbin/${APP_NAME}-healthcheck.sh"
HC_HARDENING_HELPER="/usr/local/sbin/${APP_NAME}-healthcheck-hardening.sh"
HC_CONFIG="/etc/node-enterprise-deploy-kit/${APP_NAME}.env"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
mutation_locks_acquire
uninstall_cleanup() {
  [[ -z "${UNINSTALL_MONITOR_SNAPSHOT:-}" ]] || rm -f -- "$UNINSTALL_MONITOR_SNAPSHOT"
  mutation_locks_release
}
trap uninstall_cleanup EXIT
# Removal must not discard controls or stop the previous runtime while an
# interrupted deployment still requires those controls for manual recovery.
deployment_assert_no_pending_transactions
if [[ -e "$HC_CONFIG" || -L "$HC_CONFIG" ]]; then
  hardening_assert_trusted_directory "$(dirname "$HC_CONFIG")"
  hardening_assert_control_file "$HC_CONFIG"
  previous_transaction_root="$(
    unset DEPLOYMENT_TRANSACTION_ROOT
    # shellcheck disable=SC1090
    source "$HC_CONFIG"
    printf '%s\n' "${DEPLOYMENT_TRANSACTION_ROOT:-/var/lib/node-enterprise-deploy-kit/deployment-transactions}"
  )"
  hardening_assert_no_pending_transactions "$DEPLOYMENT_LOCK_PATH" "" "" "$previous_transaction_root"
  previous_manager="$(
    unset SERVICE_MANAGER
    # shellcheck disable=SC1090
    source "$HC_CONFIG"
    printf '%s\n' "${SERVICE_MANAGER:-}"
  )"
  canonical_manager() {
    case "$(normalize_name "$1")" in
      systemv|sysv|sysvinit|initd|init-d) echo systemv ;;
      bsdrc|bsd-rc|rcd|rc.d) echo bsdrc ;;
      *) normalize_name "$1" ;;
    esac
  }
  if [[ -n "$previous_manager" && "$(canonical_manager "$previous_manager")" != "$(canonical_manager "$SERVICE_MANAGER")" ]]; then
    echo 'Use the previous protected configuration to uninstall its service manager and health scheduler.' >&2
    exit 1
  fi
fi
SERVICE_MANAGER_NORMALIZED="$(normalize_name "$SERVICE_MANAGER")"

remove_cron_healthcheck_scheduler() {
  if ! command -v crontab >/dev/null 2>&1; then
    case "$SERVICE_MANAGER_NORMALIZED" in
      systemd|launchd) ;;
      *) if [[ -e "$HC_CONFIG" || -e "$HC_SCRIPT" ]]; then echo 'crontab is required to remove the managed health scheduler.' >&2; return 1; fi ;;
    esac
    echo "crontab not found; no native cron registration was inspected." >&2
    return
  fi

  local marker_start marker_end current_file new_file backup_path awk_status current_text
  marker_start="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:start"
  marker_end="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:end"
  current_file="$(mktemp)"
  new_file="$(mktemp)"

  if current_text="$(LC_ALL=C crontab -l 2>&1)"; then
    printf '%s\n' "$current_text" > "$current_file"
    set +e
    awk -v start="$marker_start" -v end="$marker_end" '
      $0 == start { if (skipping || changed) malformed=1; skipping=1; changed=1; next }
      $0 == end { if (!skipping) malformed=1; skipping=0; changed=1; next }
      skipping != 1 { print }
      END { if (malformed || skipping) exit 8; if (changed != 1) exit 7 }
    ' "$current_file" > "$new_file"
    awk_status=$?
    set -e
    case "$awk_status" in
      0)
        if ! hardening_prepare_control_directory "$BACKUP_DIR"; then rm -f "$current_file" "$new_file"; return 1; fi
        backup_path="$(mktemp "$BACKUP_DIR/root-crontab.$(timestamp_utc).$$.XXXXXX.bak")" || { rm -f "$current_file" "$new_file"; return 1; }
        if ! cp "$current_file" "$backup_path" || ! crontab "$new_file"; then rm -f "$current_file" "$new_file"; return 1; fi
        echo "Removed managed cron healthcheck entry for $APP_NAME."
        echo "Backed up root crontab to $backup_path"
        ;;
      7)
        echo "Managed cron healthcheck entry was not present for $APP_NAME."
        ;;
      *)
        rm -f "$current_file" "$new_file"
        echo "Failed to process root crontab for $APP_NAME." >&2
        exit 1
        ;;
    esac
  else
    awk_status=$?
    if [[ "$awk_status" -ne 1 || "$current_text" != *'no crontab for '* ]]; then
      rm -f "$current_file" "$new_file"
      echo 'Could not inspect root crontab; scheduler removal stopped.' >&2
      return 1
    fi
    echo "Root crontab was not present; managed cron healthcheck entry was not present."
  fi

  rm -f "$current_file" "$new_file"
}

# Return 0 only for a live runtime, 1 for a known inactive/missing runtime,
# and 2 when its state cannot safely be determined.
uninstall_service_running() {
  local manager="$1" name="$2" state result definition
  case "$manager" in
    systemd)
      command -v systemctl >/dev/null 2>&1 || return 2
      state="$(systemctl show "$name" --property=LoadState --value 2>/dev/null)" || return 2
      [[ "$state" != not-found ]] || return 1
      [[ -n "$state" ]] || return 2
      state="$(systemctl show "$name" --property=ActiveState --value 2>/dev/null)" || return 2
      case "$state" in inactive|failed) return 1 ;; active|activating|reloading|deactivating) return 0 ;; *) return 2 ;; esac
      ;;
    launchd)
      command -v launchctl >/dev/null 2>&1 || return 2
      state="$(launchctl print "system/$name" 2>&1)" && return 0
      result=$?
      # launchctl's absent-service status is 113. Other failures require care.
      [[ "$result" == 113 || "$state" == *'Could not find service'* ]] && return 1
      return 2
      ;;
    systemv|sysv|sysvinit|initd|init-d|openrc|bsdrc|bsd-rc|rcd|rc.d)
      definition="/etc/init.d/$name"
      if [[ "$manager" == bsd* || "$manager" == rcd || "$manager" == rc.d ]]; then
        definition="/usr/local/etc/rc.d/$name"
        [[ -e "$definition" ]] || definition="/etc/rc.d/$name"
      fi
      [[ -e "$definition" ]] || return 1
      [[ -x "$definition" ]] || return 2
      case "$manager" in
        openrc) command -v rc-service >/dev/null 2>&1 || return 2; rc-service "$name" status >/dev/null 2>&1 && return 0 ;;
        bsdrc|bsd-rc|rcd|rc.d)
          if command -v rcctl >/dev/null 2>&1; then rcctl check "$name" >/dev/null 2>&1 && return 0
          else command -v service >/dev/null 2>&1 || return 2; service "$name" onestatus >/dev/null 2>&1 && return 0; fi ;;
        *)
          if command -v service >/dev/null 2>&1; then service "$name" status >/dev/null 2>&1 && return 0
          else "$definition" status >/dev/null 2>&1 && return 0; fi ;;
      esac
      result=$?
      case "$result" in 1|2|3) return 1 ;; *) return 2 ;; esac
      ;;
    *) return 2 ;;
  esac
}

uninstall_assert_inactive() {
  local manager="$1" name="$2" result
  if uninstall_service_running "$manager" "$name"; then
    echo "Runtime is still active; its control files were retained: $name" >&2
    return 1
  else
    result=$?
    [[ "$result" -eq 1 ]] || { echo "Runtime state could not be verified; control files were retained: $name" >&2; return 1; }
  fi
}

uninstall_stop_service() {
  local manager="$1" name="$2" result state
  if uninstall_service_running "$manager" "$name"; then
    :
  else
    result=$?
    [[ "$result" -eq 1 ]] || { echo "Could not inspect runtime before removal: $name" >&2; return 1; }
    # An inactive systemd unit may have a queued restart; always stop loaded units.
    if [[ "$manager" != systemd ]]; then return 0; fi
    state="$(systemctl show "$name" --property=LoadState --value)" || return 1
    [[ "$state" != not-found ]] || return 0
  fi
  case "$manager" in
    systemd) systemctl stop "$name" || return 1 ;;
    launchd) launchctl bootout "system/$name" || return 1 ;;
    openrc) rc-service "$name" stop || return 1 ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v rcctl >/dev/null 2>&1; then rcctl -f stop "$name" || return 1
      else service "$name" onestop || return 1; fi ;;
    *)
      if command -v service >/dev/null 2>&1; then service "$name" stop || return 1
      else "/etc/init.d/$name" stop || return 1; fi ;;
  esac
  uninstall_assert_inactive "$manager" "$name"
}

uninstall_disable_systemd_unit() {
  local name="$1" state
  state="$(systemctl show "$name" --property=LoadState --value)" || return 1
  [[ "$state" != not-found ]] || return 0
  systemctl disable "$name" || return 1
}

quiesce_healthcheck_scheduler() {
  local timeout="${HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS:-30}" deadline pids
  [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -le 300 ]] || { echo 'Invalid HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS.' >&2; return 1; }
  if [[ "$SERVICE_MANAGER_NORMALIZED" == systemd ]]; then
    uninstall_stop_service systemd "$APP_NAME-healthcheck.timer"
    uninstall_disable_systemd_unit "$APP_NAME-healthcheck.timer"
    uninstall_stop_service systemd "$APP_NAME-healthcheck.service"
  elif [[ "$SERVICE_MANAGER_NORMALIZED" == launchd ]]; then
    uninstall_stop_service launchd "$APP_NAME-healthcheck"
  fi
  remove_cron_healthcheck_scheduler
  deadline=$(( $(date +%s) + timeout ))
  UNINSTALL_MONITOR_SNAPSHOT="$(mktemp "$DEPLOYMENT_TRANSACTION_ROOT/uninstall-monitor.XXXXXX")"
  while :; do
    # Inspect only after ps completes. A concurrent awk with both paths in its
    # arguments would otherwise identify the inspection itself as a monitor.
    ps -axww -o pid= -o uid= -o args= > "$UNINSTALL_MONITOR_SNAPSHOT" || return 1
    pids="$(awk -v script="$HC_SCRIPT" -v config="$HC_CONFIG" -v self="$$" \
      '$2 == 0 && $1 != self && index($0, script) && index($0, config) {print $1}' "$UNINSTALL_MONITOR_SNAPSHOT")" || return 1
    [[ -n "$pids" ]] || return 0
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      echo "An existing privileged health monitor has not exited; runtime controls were retained. PIDs: $pids" >&2
      return 1
    fi
    sleep 1
  done
}

remove_healthcheck_files() {
  rm -f "$HC_CONFIG" "$HC_SCRIPT"
  rm -f "$HC_HARDENING_HELPER"
}

case "$SERVICE_MANAGER_NORMALIZED" in
  systemd|systemv|sysv|sysvinit|initd|init-d|openrc|launchd|bsdrc|bsd-rc|rcd|rc.d) ;;
  *) echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER" >&2; exit 1 ;;
esac
quiesce_healthcheck_scheduler
uninstall_stop_service "$SERVICE_MANAGER_NORMALIZED" "$APP_NAME"
case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    uninstall_disable_systemd_unit "$APP_NAME"
    uninstall_assert_inactive systemd "$APP_NAME"
    rm -f "/etc/systemd/system/${APP_NAME}.service"
    rm -f "/etc/systemd/system/${APP_NAME}-healthcheck.service" "/etc/systemd/system/${APP_NAME}-healthcheck.timer"
    systemctl daemon-reload
    echo "Removed systemd service and healthcheck timer for $APP_NAME. App/log directories were not deleted."
    ;;
  systemv|sysv|sysvinit|initd|init-d)
    if [[ -e "/etc/init.d/$APP_NAME" ]]; then
      if command -v update-rc.d >/dev/null 2>&1; then update-rc.d -f "$APP_NAME" remove; fi
      if command -v chkconfig >/dev/null 2>&1; then chkconfig --del "$APP_NAME"; fi
    fi
    uninstall_assert_inactive "$SERVICE_MANAGER_NORMALIZED" "$APP_NAME"
    rm -f "/etc/init.d/${APP_NAME}"
    echo "Removed System V service for $APP_NAME. App/log directories were not deleted."
    ;;
    openrc)
      if [[ -e "/etc/init.d/$APP_NAME" ]]; then
        require_command rc-update 'OpenRC removal requires rc-update.'
        openrc_membership="$(rc-update show default)"
        if printf '%s\n' "$openrc_membership" | awk -v app="$APP_NAME" '$1 == app {found=1} END {exit !found}'; then
          rc-update del "$APP_NAME" default
        fi
    fi
    uninstall_assert_inactive "$SERVICE_MANAGER_NORMALIZED" "$APP_NAME"
    rm -f "/etc/init.d/${APP_NAME}"
    echo "Removed OpenRC service for $APP_NAME. App/log directories were not deleted."
    ;;
  launchd)
    plist_file="/Library/LaunchDaemons/${APP_NAME}.plist"
    uninstall_assert_inactive launchd "$APP_NAME"
    rm -f "$plist_file" "$RUNNER_SCRIPT"
    rm -f "/Library/LaunchDaemons/${APP_NAME}-healthcheck.plist"
    echo "Removed launchd service for $APP_NAME. App/log directories were not deleted."
    ;;
  bsdrc|bsd-rc|rcd|rc.d)
    if [[ -e "/etc/rc.d/$APP_NAME" || -e "/usr/local/etc/rc.d/$APP_NAME" ]]; then
      if command -v rcctl >/dev/null 2>&1; then rcctl disable "$APP_NAME"; fi
    fi
    uninstall_assert_inactive "$SERVICE_MANAGER_NORMALIZED" "$APP_NAME"
    rm -f "/usr/local/etc/rc.d/${APP_NAME}" "/etc/rc.d/${APP_NAME}"
    echo "Removed BSD rc service for $APP_NAME. App/log directories were not deleted."
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER. Use systemd, systemv, openrc, launchd, or bsdrc." >&2
    exit 1
    ;;
esac

remove_healthcheck_files
