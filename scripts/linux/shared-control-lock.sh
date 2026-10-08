#!/usr/bin/env bash
# Serialize native global registries and shared proxy reloads across apps. A
# child may reuse a parent's protected owner token, but never releases that lock.
SHARED_CONTROL_LOCK_HELD=false
shared_control_lock_acquire() {
  local root="${SHARED_CONTROL_LOCK_ROOT:-$(hardening_default_lock_root)}" deadline
  local timeout="${SHARED_CONTROL_LOCK_TIMEOUT_SECONDS:-60}" token
  [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -le 3600 ]] || return 1
  deployment_lock_run_privileged bash -c 'source "$1"; hardening_prepare_control_directory "$2"' _ "$DEPLOYMENT_LOCK_HARDENING_HELPER" "$root" || return 1
  SHARED_CONTROL_LOCK_PATH="${root%/}/shared-control.lock"
  if [[ "${NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH:-}" == "$SHARED_CONTROL_LOCK_PATH" && -n "${NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN:-}" ]] &&
    deployment_lock_run_privileged grep -Fxq "Token=$NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN" "$SHARED_CONTROL_LOCK_PATH/owner" 2>/dev/null; then
    return 0
  fi
  deadline=$(( $(date +%s) + timeout ))
  while ! deployment_lock_run_privileged mkdir "$SHARED_CONTROL_LOCK_PATH" 2>/dev/null; do
    [[ "$(date +%s)" -lt "$deadline" ]] || { echo "Another operation holds the shared service/proxy configuration lock." >&2; return 1; }
    sleep 1
  done
  token="$$.$RANDOM.$(date +%s)"
  if ! deployment_lock_run_privileged chmod 0700 "$SHARED_CONTROL_LOCK_PATH"; then
    deployment_lock_run_privileged rmdir "$SHARED_CONTROL_LOCK_PATH" || true
    return 1
  fi
  if ! printf 'Token=%s\nProcessId=%s\n' "$token" "$$" | deployment_lock_run_privileged tee "$SHARED_CONTROL_LOCK_PATH/owner" >/dev/null; then
    deployment_lock_run_privileged rm -f "$SHARED_CONTROL_LOCK_PATH/owner"
    deployment_lock_run_privileged rmdir "$SHARED_CONTROL_LOCK_PATH"
    return 1
  fi
  if ! deployment_lock_run_privileged chmod 0600 "$SHARED_CONTROL_LOCK_PATH/owner"; then
    deployment_lock_run_privileged rm -f "$SHARED_CONTROL_LOCK_PATH/owner"
    deployment_lock_run_privileged rmdir "$SHARED_CONTROL_LOCK_PATH" || true
    return 1
  fi
  NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH="$SHARED_CONTROL_LOCK_PATH"
  NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN="$token"
  export SHARED_CONTROL_LOCK_ROOT NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN
  SHARED_CONTROL_LOCK_HELD=true
}
shared_control_lock_release() {
  [[ "$SHARED_CONTROL_LOCK_HELD" == true ]] || return 0
  deployment_lock_run_privileged grep -Fxq "Token=${NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN:-}" "$SHARED_CONTROL_LOCK_PATH/owner" || {
    echo "Refusing to release a shared lock whose ownership changed." >&2; return 1;
  }
  deployment_lock_run_privileged rm -f "$SHARED_CONTROL_LOCK_PATH/owner" && deployment_lock_run_privileged rmdir "$SHARED_CONTROL_LOCK_PATH" || return 1
  SHARED_CONTROL_LOCK_HELD=false
  unset NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN
}
mutation_locks_acquire() {
  deployment_lock_acquire "$APP_NAME" || return 1
  deployment_transaction_prepare_root || { deployment_lock_release; return 1; }
  shared_control_lock_acquire || { deployment_lock_release; return 1; }
}
mutation_locks_release() {
  local result=0
  shared_control_lock_release || result=1
  deployment_lock_release || result=1
  return "$result"
}
