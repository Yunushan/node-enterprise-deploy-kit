#!/usr/bin/env bash

DEPLOYMENT_LOCK_PATH=""
DEPLOYMENT_LOCK_HELD=false

deployment_lock_run_privileged() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || {
      echo "sudo is required to manage the deployment lock." >&2
      return 1
    }
    sudo "$@"
  fi
}

deployment_lock_validate_timeout() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -le 3600 ]]
}

deployment_lock_acquire() {
  local app_name="$1"
  local lock_root="${DEPLOYMENT_LOCK_ROOT:-/var/run/node-enterprise-deploy-kit}"
  local timeout_seconds="${DEPLOYMENT_LOCK_TIMEOUT_SECONDS:-0}"
  local safe_name deadline now owner_file

  [[ -n "$app_name" ]] || { echo "APP_NAME is required for deployment locking." >&2; return 1; }
  deployment_lock_validate_timeout "$timeout_seconds" || {
    echo "DEPLOYMENT_LOCK_TIMEOUT_SECONDS must be an integer from 0 through 3600." >&2
    return 1
  }
  [[ "$lock_root" == /* && "$lock_root" != "/" ]] || {
    echo "DEPLOYMENT_LOCK_ROOT must be a non-root absolute path." >&2
    return 1
  }

  safe_name="$(printf '%s' "$app_name" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  [[ -n "$safe_name" && "$safe_name" != "." && "$safe_name" != ".." ]] || {
    echo "APP_NAME does not produce a safe deployment lock name." >&2
    return 1
  }
  DEPLOYMENT_LOCK_PATH="${lock_root%/}/${safe_name}.lock"
  deadline=$(( $(date +%s) + timeout_seconds ))

  deployment_lock_run_privileged mkdir -p "$lock_root"
  deployment_lock_run_privileged chmod 0750 "$lock_root"
  while ! deployment_lock_run_privileged mkdir "$DEPLOYMENT_LOCK_PATH" 2>/dev/null; do
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      echo "Another deployment is already active for '$app_name'. Lock: $DEPLOYMENT_LOCK_PATH" >&2
      DEPLOYMENT_LOCK_PATH=""
      return 1
    fi
    sleep 1
  done

  owner_file="$DEPLOYMENT_LOCK_PATH/owner"
  if ! printf 'AppName=%s\nProcessId=%s\nAcquiredAtUtc=%s\n' "$app_name" "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" |
    deployment_lock_run_privileged tee "$owner_file" >/dev/null; then
    deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH" 2>/dev/null || true
    DEPLOYMENT_LOCK_PATH=""
    return 1
  fi
  deployment_lock_run_privileged chmod 0640 "$owner_file"
  DEPLOYMENT_LOCK_HELD=true
  echo "Acquired deployment lock for: $app_name"
}

deployment_lock_release() {
  if [[ "$DEPLOYMENT_LOCK_HELD" != "true" || -z "$DEPLOYMENT_LOCK_PATH" ]]; then
    return 0
  fi

  deployment_lock_run_privileged rm -f "$DEPLOYMENT_LOCK_PATH/owner"
  if ! deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH"; then
    echo "WARNING: Could not remove deployment lock directory: $DEPLOYMENT_LOCK_PATH" >&2
    return 1
  fi
  DEPLOYMENT_LOCK_HELD=false
  DEPLOYMENT_LOCK_PATH=""
  echo "Released deployment lock."
}
