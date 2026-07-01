#!/usr/bin/env bash
set -euo pipefail

shellcheck_bin="${SHELLCHECK_BIN:-}"

if [[ -z "$shellcheck_bin" ]] && command -v shellcheck >/dev/null 2>&1; then
  shellcheck_bin="$(command -v shellcheck)"
fi

if [[ -z "$shellcheck_bin" ]]; then
  for candidate in "$PWD"/.tmp/tools/shellcheck-*/shellcheck "$PWD"/tools/shellcheck/shellcheck; do
    if [[ -x "$candidate" ]]; then
      shellcheck_bin="$candidate"
      break
    fi
  done
fi

if [[ -z "$shellcheck_bin" || ! -x "$shellcheck_bin" ]]; then
  echo "shellcheck was not found. Install ShellCheck or run this in CI after installing CI tooling." >&2
  exit 127
fi

"$shellcheck_bin" --severity=warning deploy.sh scripts/dev/*.sh scripts/linux/*.sh
