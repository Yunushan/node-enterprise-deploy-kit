#!/usr/bin/env bash
# Lifecycle state is consumed by scripts that source this helper.
# shellcheck disable=SC2034

PACKAGE_APP_SERVICE_WAS_RUNNING=false
PACKAGE_APP_SERVICE_EXISTED=false
PACKAGE_APP_BACKUP_PATH=""
PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED=true

package_app_service_exists() {
  local manager="$1" name="$2"
  case "$manager" in
    systemd) service_exists_systemd "$name" ;;
    systemv|sysv|sysvinit|initd|init-d) [[ -x "/etc/init.d/$name" ]] ;;
    openrc) [[ -x "/etc/init.d/$name" ]] ;;
    launchd) [[ -f "/Library/LaunchDaemons/${name}.plist" ]] ;;
    bsdrc|bsd-rc|rcd|rc.d) [[ -x "/usr/local/etc/rc.d/$name" || -x "/etc/rc.d/$name" ]] ;;
    none) return 1 ;;
    *) echo "Unsupported SERVICE_MANAGER for package lifecycle: $manager" >&2; return 2 ;;
  esac
}

package_app_service_is_running() {
  local manager="$1" name="$2"
  case "$manager" in
    systemd)
      service_exists_systemd "$name" && systemctl is-active --quiet "$name"
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then
        service "$name" status >/dev/null 2>&1
      elif [[ -x "/etc/init.d/$name" ]]; then
        "/etc/init.d/$name" status >/dev/null 2>&1
      else
        return 1
      fi
      ;;
    openrc)
      command -v rc-service >/dev/null 2>&1 && rc-service "$name" status >/dev/null 2>&1
      ;;
    launchd)
      command -v launchctl >/dev/null 2>&1 && launchctl print "system/$name" >/dev/null 2>&1
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v rcctl >/dev/null 2>&1; then
        rcctl check "$name" >/dev/null 2>&1
      elif command -v service >/dev/null 2>&1; then
        service "$name" onestatus >/dev/null 2>&1 || service "$name" status >/dev/null 2>&1
    else
      return 1
    fi
    ;;
    none) return 1 ;;
    *)
      echo "Unsupported SERVICE_MANAGER for package lifecycle: $manager" >&2
      return 2
      ;;
  esac
}

package_stop_app_service() {
  local manager="$1" name="$2" state_result
  PACKAGE_APP_SERVICE_WAS_RUNNING=false
  PACKAGE_APP_SERVICE_EXISTED=false
  if package_app_service_exists "$manager" "$name"; then
    PACKAGE_APP_SERVICE_EXISTED=true
  else
    state_result=$?
    [[ "$state_result" -ne 2 ]] || return "$state_result"
  fi
  if package_app_service_is_running "$manager" "$name"; then
    PACKAGE_APP_SERVICE_WAS_RUNNING=true
  else
    state_result=$?
    if [[ "$state_result" -eq 2 ]]; then
      return "$state_result"
    fi
    return 0
  fi

  echo "Stopping service before package import: $name"
  case "$manager" in
    systemd) systemctl stop "$name" ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$name" stop; else "/etc/init.d/$name" stop; fi
      ;;
    openrc) rc-service "$name" stop ;;
    launchd) launchctl bootout "system/$name" ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v rcctl >/dev/null 2>&1; then rcctl stop "$name"; else service "$name" stop; fi
      ;;
  esac || {
    echo "Failed to stop service before package import: $name" >&2
    return 1
  }

  if package_app_service_is_running "$manager" "$name"; then
    echo "Service is still running after the stop command: $name" >&2
    return 1
  fi
  return 0
}

package_remove_new_service_after_failure() {
  local manager="$1" name="$2" state_result
  case "$manager" in
    systemd)
      systemctl disable --now "$name" >/dev/null 2>&1 || true
      rm -f -- "/etc/systemd/system/${name}.service"
      systemctl daemon-reload
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v update-rc.d >/dev/null 2>&1; then update-rc.d -f "$name" remove; fi
      if command -v chkconfig >/dev/null 2>&1; then chkconfig --del "$name"; fi
      rm -f -- "/etc/init.d/$name"
      ;;
    openrc)
      rc-update del "$name" default >/dev/null 2>&1 || true
      rm -f -- "/etc/init.d/$name"
      ;;
    launchd)
      launchctl bootout system "/Library/LaunchDaemons/${name}.plist" >/dev/null 2>&1 || true
      rm -f -- "/Library/LaunchDaemons/${name}.plist" "/usr/local/libexec/${name}-runner.sh"
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v rcctl >/dev/null 2>&1; then rcctl disable "$name"; fi
      rm -f -- "/usr/local/etc/rc.d/$name" "/etc/rc.d/$name"
      ;;
    none) ;;
    *)
      echo "Unsupported SERVICE_MANAGER for rollback: $manager" >&2
      return 1
      ;;
  esac

  if package_app_service_is_running "$manager" "$name"; then
    echo "New service is still running after deployment rollback: $name" >&2
    return 1
  else
    state_result=$?
    [[ "$state_result" -ne 2 ]] || return "$state_result"
  fi
  if package_app_service_exists "$manager" "$name"; then
    echo "New service is still registered after deployment rollback: $name" >&2
    return 1
  else
    state_result=$?
    [[ "$state_result" -ne 2 ]] || return "$state_result"
  fi
}

package_rollback_deployment_transaction() {
  local app_dir="$1" backup_path="$2" previous_app_existed="$3"
  local manager="$4" name="$5" service_existed="$6" service_was_running="$7"
  local current_running=false

  if package_app_service_is_running "$manager" "$name"; then
    current_running=true
  else
    local state_result=$?
    [[ "$state_result" -ne 2 ]] || return "$state_result"
  fi
  if [[ "$current_running" == "true" ]]; then
    PACKAGE_APP_SERVICE_WAS_RUNNING=true
    package_stop_app_service "$manager" "$name"
  fi

  if [[ "$previous_app_existed" == "true" ]]; then
    [[ -n "$backup_path" && -e "$backup_path" ]] || {
      echo "Previous APP_DIR backup is missing; the failed deployment was left stopped." >&2
      return 1
    }
  fi
  package_restore_previous_app_directory "$app_dir" "$backup_path"

  if [[ "$service_existed" == "true" ]]; then
    if [[ "$service_was_running" == "true" ]]; then
      PACKAGE_APP_SERVICE_WAS_RUNNING=true
      package_restart_app_service_after_failure "$manager" "$name"
    fi
  else
    package_remove_new_service_after_failure "$manager" "$name"
  fi
  echo "Rolled back the application package after a downstream deployment failure." >&2
}

package_restart_app_service_after_failure() {
  local manager="$1" name="$2"
  [[ "$PACKAGE_APP_SERVICE_WAS_RUNNING" == "true" ]] || return 0
  [[ "$manager" == "none" ]] && return 0

  echo "Restarting previous service after package import failure: $name" >&2
  case "$manager" in
    systemd) systemctl start "$name" ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$name" start; else "/etc/init.d/$name" start; fi
      ;;
    openrc) rc-service "$name" start ;;
    launchd) launchctl bootstrap system "/Library/LaunchDaemons/${name}.plist" ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v rcctl >/dev/null 2>&1; then rcctl start "$name"; else service "$name" start; fi
      ;;
  esac || return 1

  if ! package_app_service_is_running "$manager" "$name"; then
    echo "Previous service did not return to a running state: $name" >&2
    return 1
  fi
  return 0
}

package_restore_previous_app_directory() {
  local app_dir="$1" backup_path="$2"
  if [[ -e "$app_dir" ]] && ! rm -rf -- "$app_dir"; then
    echo "Could not remove the partial application directory during rollback: $app_dir" >&2
    return 1
  fi
  if [[ -n "$backup_path" && -e "$backup_path" ]]; then
    if ! mv "$backup_path" "$app_dir"; then
      echo "Could not restore the previous application directory from: $backup_path" >&2
      return 1
    fi
    echo "Restored previous APP_DIR after package import failure." >&2
  fi
  return 0
}

package_replace_app_directory() {
  local source_root="$1" app_dir="$2" backup_dir="$3" manifest_callback="$4"
  local backup_path="" had_previous=false
  PACKAGE_APP_BACKUP_PATH=""
  PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED=true

  if [[ -z "$app_dir" || "$app_dir" != /* || "$app_dir" == "/" ]]; then
    echo "APP_DIR must be a non-root absolute path before package import." >&2
    return 1
  fi
  if [[ "$backup_dir" == "$app_dir" || "$backup_dir" == "$app_dir"/* ]]; then
    echo "BACKUP_DIR must not be inside APP_DIR when importing packages." >&2
    return 1
  fi
  if ! mkdir -p "$backup_dir" "$(dirname "$app_dir")" || ! chmod 0750 "$backup_dir"; then
    echo "Could not prepare package backup or application parent directories." >&2
    return 1
  fi

  if [[ -e "$app_dir" ]]; then
    had_previous=true
    backup_path="$backup_dir/app.$(timestamp_utc).$$.bak"
    if ! mv "$app_dir" "$backup_path"; then
      echo "Could not back up the existing APP_DIR before package replacement." >&2
      return 1
    fi
    PACKAGE_APP_BACKUP_PATH="$backup_path"
    echo "Backed up existing APP_DIR to: $backup_path"
  fi

  if ! mkdir -p "$app_dir"; then
    if ! package_restore_previous_app_directory "$app_dir" "$backup_path"; then
      PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED=false
    fi
    return 1
  fi
  if ! (cd "$source_root" && tar -cf - .) | (cd "$app_dir" && tar -xf -); then
    if ! package_restore_previous_app_directory "$app_dir" "$backup_path"; then
      PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED=false
    fi
    return 1
  fi
  if ! "$manifest_callback"; then
    echo "Could not write the deployment manifest; rolling back package replacement." >&2
    if ! package_restore_previous_app_directory "$app_dir" "$backup_path"; then
      PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED=false
    fi
    return 1
  fi

  if [[ "$had_previous" != "true" ]]; then
    PACKAGE_APP_BACKUP_PATH=""
  fi
  return 0
}
