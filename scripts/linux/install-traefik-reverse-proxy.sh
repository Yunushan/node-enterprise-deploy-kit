#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-config/linux/app.env}"
CONFIG_FILE="$(resolve_config_path "$REPO_ROOT" "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
if ! command -v traefik >/dev/null 2>&1; then echo "Traefik is not installed. Install traefik first, then rerun this script." >&2; exit 1; fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-traefik}"
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"
TRAEFIK_DYNAMIC_FILE="${TRAEFIK_DYNAMIC_FILE:-${TRAEFIK_DYNAMIC_DIR}/${APP_NAME}.yml}"
TRAEFIK_ENTRYPOINT="${TRAEFIK_ENTRYPOINT:-web}"
TRAEFIK_ROUTER_NAME="${TRAEFIK_ROUTER_NAME:-${APP_NAME}-router}"
TRAEFIK_SERVICE_NAME="${TRAEFIK_SERVICE_NAME:-${APP_NAME}-service}"
HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-/health}"
TEMPLATE="$REPO_ROOT/templates/linux/traefik-dynamic.yml.tpl"

mkdir -p "$LOG_DIR" "$TRAEFIK_DYNAMIC_DIR"
render_template_file "$TEMPLATE" "$TRAEFIK_DYNAMIC_FILE" \
  PUBLIC_HOSTNAME "$PUBLIC_HOSTNAME" \
  APP_PORT "$APP_PORT" \
  TRAEFIK_ENTRYPOINT "$TRAEFIK_ENTRYPOINT" \
  TRAEFIK_ROUTER_NAME "$TRAEFIK_ROUTER_NAME" \
  TRAEFIK_SERVICE_NAME "$TRAEFIK_SERVICE_NAME" \
  HEALTHCHECK_PATH "$HEALTHCHECK_PATH"

if [[ -n "${TRAEFIK_STATIC_CONFIG:-}" && -f "$TRAEFIK_STATIC_CONFIG" ]]; then
  traefik check --configFile="$TRAEFIK_STATIC_CONFIG" || true
fi

reload_or_restart_service "$TRAEFIK_SERVICE" "Traefik"
echo "Installed Traefik dynamic config: $TRAEFIK_DYNAMIC_FILE"
