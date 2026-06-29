#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck was not found. Install ShellCheck or run this in CI after installing CI tooling." >&2
  exit 127
fi

shellcheck --severity=warning deploy.sh scripts/dev/*.sh scripts/linux/*.sh
