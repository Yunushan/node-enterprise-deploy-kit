#!/usr/bin/env bash
set -euo pipefail
for f in deploy.sh scripts/linux/*.sh scripts/dev/*.sh; do
  [[ -f "$f" ]] || continue
  bash -n "$f"
done
echo "Shell syntax OK"
