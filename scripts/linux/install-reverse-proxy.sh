#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/install-reverse-proxy.sh [config.env] [--dry-run]

Install the reverse proxy selected by REVERSE_PROXY in the config file.

Supported REVERSE_PROXY values:
  nginx, apache, haproxy, traefik, none

Options:
  --dry-run   Print the selected installer without requiring root or changing files.
  -h, --help  Show this help.
USAGE
}

CONFIG_FILE=""
DRY_RUN="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${CONFIG_FILE:-config/linux/app.env}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

REVERSE_PROXY_NORMALIZED="$(normalize_name "${REVERSE_PROXY:-none}")"
installer=""
label=""

case "$REVERSE_PROXY_NORMALIZED" in
  nginx)
    installer="$REPO_ROOT/scripts/linux/install-nginx-reverse-proxy.sh"
    label="Nginx"
    ;;
  apache|httpd)
    installer="$REPO_ROOT/scripts/linux/install-apache-reverse-proxy.sh"
    label="Apache"
    ;;
  haproxy)
    installer="$REPO_ROOT/scripts/linux/install-haproxy-reverse-proxy.sh"
    label="HAProxy"
    ;;
  traefik)
    installer="$REPO_ROOT/scripts/linux/install-traefik-reverse-proxy.sh"
    label="Traefik"
    ;;
  none|"")
    echo "REVERSE_PROXY=none; skipping reverse proxy install."
    exit 0
    ;;
  *)
    echo "Unsupported REVERSE_PROXY: ${REVERSE_PROXY:-}. Use nginx, apache, haproxy, traefik, or none." >&2
    exit 1
    ;;
esac

if [[ "$DRY_RUN" == "true" ]]; then
  printf 'Would install %s reverse proxy with: bash %s %s\n' "$label" "$installer" "$CONFIG_FILE"
  exit 0
fi

if [[ "${EUID}" -eq 0 ]]; then
  exec bash "$installer" "$CONFIG_FILE"
fi

if command -v sudo >/dev/null 2>&1; then
  exec sudo bash "$installer" "$CONFIG_FILE"
fi

echo "Run as root or install sudo to run $label reverse proxy installer." >&2
exit 1
