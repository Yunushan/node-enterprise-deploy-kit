#!/usr/bin/env bash

DEPLOYMENT_LOCK_PATH=""
DEPLOYMENT_LOCK_HELD=false
DEPLOYMENT_TRANSACTION_PREFIX=""
DEPLOYMENT_LOCK_HARDENING_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime-hardening.sh"
# shellcheck source=scripts/linux/runtime-hardening.sh
source "$DEPLOYMENT_LOCK_HARDENING_HELPER"

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

deployment_transaction_prepare_root() {
  [[ -n "$DEPLOYMENT_LOCK_PATH" ]] || return 1
  DEPLOYMENT_TRANSACTION_ROOT="${DEPLOYMENT_TRANSACTION_ROOT:-/var/lib/node-enterprise-deploy-kit/deployment-transactions}"
  local runtime_path
  for runtime_path in "${APP_DIR:-}" "${LOG_DIR:-}"; do
    [[ -n "$runtime_path" ]] || continue
    runtime_path="${runtime_path%/}"
    if [[ "${DEPLOYMENT_TRANSACTION_ROOT%/}" == "$runtime_path" || "$DEPLOYMENT_TRANSACTION_ROOT" == "$runtime_path"/* ]]; then
      echo 'DEPLOYMENT_TRANSACTION_ROOT must be outside runtime-owned APP_DIR and LOG_DIR.' >&2
      return 1
    fi
  done
  deployment_lock_run_privileged bash -c 'source "$1"; hardening_prepare_control_directory "$2"' _ \
    "$DEPLOYMENT_LOCK_HARDENING_HELPER" "$DEPLOYMENT_TRANSACTION_ROOT" || return 1
  DEPLOYMENT_TRANSACTION_PREFIX="${DEPLOYMENT_TRANSACTION_ROOT%/}/$(basename "$DEPLOYMENT_LOCK_PATH")"
  export DEPLOYMENT_TRANSACTION_ROOT DEPLOYMENT_TRANSACTION_PREFIX
}

deployment_assert_no_pending_transactions() {
  [[ -n "$DEPLOYMENT_LOCK_PATH" ]] || { echo 'An application lock is required to inspect recovery state.' >&2; return 1; }
  local active_journal="${1:-}" active_package=""
  if [[ -n "$active_journal" ]]; then
    transaction_assert_active_journal || return 1
    if [[ -f "$active_journal/package-state-path" ]]; then active_package="$(cat "$active_journal/package-state-path")"; fi
  fi
  deployment_lock_run_privileged bash -c 'source "$1"; hardening_assert_no_pending_transactions "$2" "${3:-}" "${4:-}" "$5"' _ \
    "$DEPLOYMENT_LOCK_HARDENING_HELPER" "$DEPLOYMENT_LOCK_PATH" "$active_journal" "$active_package" "$DEPLOYMENT_TRANSACTION_ROOT"
}

deployment_lock_acquire() {
  local app_name="$1"
  local lock_root="${DEPLOYMENT_LOCK_ROOT:-$(hardening_default_lock_root)}"
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
  deployment_lock_run_privileged bash -c 'source "$1"; hardening_prepare_control_directory "$2"' _ "$DEPLOYMENT_LOCK_HARDENING_HELPER" "$lock_root" || return 1
  if [[ "${NODE_DEPLOY_APP_LOCK_PATH:-}" == "$DEPLOYMENT_LOCK_PATH" && -n "${NODE_DEPLOY_APP_LOCK_TOKEN:-}" ]] &&
    deployment_lock_run_privileged grep -Fxq "Token=$NODE_DEPLOY_APP_LOCK_TOKEN" "$DEPLOYMENT_LOCK_PATH/owner" 2>/dev/null; then
    return 0
  fi
  deadline=$(( $(date +%s) + timeout_seconds ))

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
  NODE_DEPLOY_APP_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
  if ! deployment_lock_run_privileged chmod 0700 "$DEPLOYMENT_LOCK_PATH"; then
    deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH" || true
    return 1
  fi
  if ! printf 'AppName=%s\nProcessId=%s\nAcquiredAtUtc=%s\nToken=%s\n' "$app_name" "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$NODE_DEPLOY_APP_LOCK_TOKEN" |
    deployment_lock_run_privileged tee "$owner_file" >/dev/null; then
    deployment_lock_run_privileged rm -f "$owner_file"
    deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH" 2>/dev/null || true
    DEPLOYMENT_LOCK_PATH=""
    return 1
  fi
  if ! deployment_lock_run_privileged chmod 0600 "$owner_file"; then
    deployment_lock_run_privileged rm -f "$owner_file"
    deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH" || true
    return 1
  fi
  NODE_DEPLOY_APP_LOCK_PATH="$DEPLOYMENT_LOCK_PATH"
  export NODE_DEPLOY_APP_LOCK_PATH NODE_DEPLOY_APP_LOCK_TOKEN
  DEPLOYMENT_LOCK_HELD=true
  echo "Acquired deployment lock for: $app_name"
}

deployment_lock_release() {
  if [[ "$DEPLOYMENT_LOCK_HELD" != "true" || -z "$DEPLOYMENT_LOCK_PATH" ]]; then
    return 0
  fi
  deployment_lock_run_privileged grep -Fxq "Token=${NODE_DEPLOY_APP_LOCK_TOKEN:-}" "$DEPLOYMENT_LOCK_PATH/owner" || {
    echo "Refusing to release an application lock whose ownership changed." >&2; return 1;
  }

  deployment_lock_run_privileged rm -f "$DEPLOYMENT_LOCK_PATH/owner"
  if ! deployment_lock_run_privileged rmdir "$DEPLOYMENT_LOCK_PATH"; then
    echo "WARNING: Could not remove deployment lock directory: $DEPLOYMENT_LOCK_PATH" >&2
    return 1
  fi
  DEPLOYMENT_LOCK_HELD=false
  DEPLOYMENT_LOCK_PATH=""
  unset NODE_DEPLOY_APP_LOCK_PATH NODE_DEPLOY_APP_LOCK_TOKEN
  echo "Released deployment lock."
}
