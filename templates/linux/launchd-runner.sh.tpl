#!/usr/bin/env bash
set -euo pipefail
cd "{{APP_DIR}}"
if [[ -f "{{ENV_FILE}}" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "{{ENV_FILE}}"
  set +a
fi
exec "{{NODE_BIN}}" "{{START_SCRIPT}}" {{NODE_ARGUMENTS}}
