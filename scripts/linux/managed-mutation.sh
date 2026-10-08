#!/usr/bin/env bash
# Standalone installers receive the same recovery protection as deploy.sh.
# Child installers reuse the outer journal and leave its recovery to the parent.
MANAGED_MUTATION_OWNS_JOURNAL=false
managed_mutation_begin() {
  mutation_locks_acquire || return 1
  trap 'managed_mutation_exit $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -z "${NODE_DEPLOY_TRANSACTION_DIR:-}" ]]; then
    NODE_DEPLOY_TRANSACTION_DIR="${DEPLOYMENT_TRANSACTION_PREFIX}.managed-transaction.local.$$"
    export NODE_DEPLOY_TRANSACTION_DIR
    bash "$(dirname "$DEPLOYMENT_LOCK_HARDENING_HELPER")/manage-deployment-transaction.sh" begin "$CONFIG_FILE" "$NODE_DEPLOY_TRANSACTION_DIR" || return 1
    MANAGED_MUTATION_OWNS_JOURNAL=true
    bash "$(dirname "$DEPLOYMENT_LOCK_HARDENING_HELPER")/manage-deployment-transaction.sh" quiesce-health "$CONFIG_FILE" "$NODE_DEPLOY_TRANSACTION_DIR" || return 1
  else
    transaction_assert_journal || return 1
    deployment_assert_no_pending_transactions "$NODE_DEPLOY_TRANSACTION_DIR" || return 1
  fi
}
managed_mutation_exit() {
  local result="$1" recovery_failed=false
  trap - EXIT
  if [[ "$MANAGED_MUTATION_OWNS_JOURNAL" == true ]]; then
    if [[ "$result" -eq 0 && "${MANAGED_MUTATION_REPLACES_HEALTH_SCHEDULER:-false}" != true ]]; then
      bash "$(dirname "$DEPLOYMENT_LOCK_HARDENING_HELPER")/manage-deployment-transaction.sh" resume-health "$CONFIG_FILE" "$NODE_DEPLOY_TRANSACTION_DIR" || result=1
    fi
    if [[ "$result" -ne 0 ]]; then
      if ! bash "$(dirname "$DEPLOYMENT_LOCK_HARDENING_HELPER")/manage-deployment-transaction.sh" restore "$CONFIG_FILE" "$NODE_DEPLOY_TRANSACTION_DIR"; then
        echo "CRITICAL: Installer recovery failed; journal retained at $NODE_DEPLOY_TRANSACTION_DIR" >&2
        recovery_failed=true
      fi
    fi
    if [[ "$recovery_failed" != true ]]; then transaction_finish || result=1; fi
  fi
  mutation_locks_release || result=1
  exit "$result"
}
