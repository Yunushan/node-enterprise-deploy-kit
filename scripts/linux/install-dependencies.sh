#!/usr/bin/env bash
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
CONFIG_FILE="${1:-}"
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
REVERSE_PROXY="${REVERSE_PROXY:-nginx}"
REVERSE_PROXY_NORMALIZED="$(echo "$REVERSE_PROXY" | tr '[:upper:]' '[:lower:]')"
source /etc/os-release || true
ID_LIKE_LOWER="${ID_LIKE:-} ${ID:-}"
ID_LIKE_LOWER="$(echo "$ID_LIKE_LOWER" | tr '[:upper:]' '[:lower:]')"
if echo "$ID_LIKE_LOWER" | grep -Eq 'debian|ubuntu'; then
  apt-get update
  packages=(curl ca-certificates)
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx) packages+=(nginx) ;;
    apache|httpd) packages+=(apache2) ;;
    none|"") ;;
    *) echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, or none." >&2; exit 1 ;;
  esac
  apt-get install -y "${packages[@]}"
elif echo "$ID_LIKE_LOWER" | grep -Eq 'rhel|fedora|centos|rocky|almalinux'; then
  packages=(curl ca-certificates)
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx) packages+=(nginx) ;;
    apache|httpd) packages+=(httpd) ;;
    none|"") ;;
    *) echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, or none." >&2; exit 1 ;;
  esac
  if command -v dnf >/dev/null 2>&1; then dnf install -y "${packages[@]}"; else yum install -y "${packages[@]}"; fi
elif echo "$ID_LIKE_LOWER" | grep -Eq 'alpine'; then
  packages=(curl ca-certificates)
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx) packages+=(nginx) ;;
    apache|httpd) packages+=(apache2) ;;
    none|"") ;;
    *) echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, or none." >&2; exit 1 ;;
  esac
  apk add --no-cache "${packages[@]}"
else
  echo "Unsupported/unknown distro family. Install curl, ca-certificates, ${REVERSE_PROXY}, and Node.js manually." >&2
fi
echo "Dependency bootstrap finished. Install Node.js using your company-approved source or package repository."
