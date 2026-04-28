#!/usr/bin/env bash
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
source /etc/os-release || true
ID_LIKE_LOWER="${ID_LIKE:-} ${ID:-}"
ID_LIKE_LOWER="$(echo "$ID_LIKE_LOWER" | tr '[:upper:]' '[:lower:]')"
if echo "$ID_LIKE_LOWER" | grep -Eq 'debian|ubuntu'; then
  apt-get update
  apt-get install -y curl ca-certificates nginx
elif echo "$ID_LIKE_LOWER" | grep -Eq 'rhel|fedora|centos|rocky|almalinux'; then
  if command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates nginx; else yum install -y curl ca-certificates nginx; fi
else
  echo "Unsupported/unknown distro family. Install curl, ca-certificates, nginx, and Node.js manually." >&2
fi
echo "Dependency bootstrap finished. Install Node.js using your company-approved source or package repository."
