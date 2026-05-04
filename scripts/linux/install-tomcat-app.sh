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

BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
TOMCAT_SERVICE="${TOMCAT_SERVICE:-tomcat}"
if [[ -z "${TOMCAT_WEBAPPS_DIR:-}" ]]; then
  case "$(detect_platform_family)" in
    debian) TOMCAT_WEBAPPS_DIR="/var/lib/tomcat9/webapps" ;;
    freebsd) TOMCAT_WEBAPPS_DIR="/usr/local/apache-tomcat-10.1/webapps" ;;
    macos)
      if [[ -d /opt/homebrew/opt/tomcat/libexec/webapps ]]; then
        TOMCAT_WEBAPPS_DIR="/opt/homebrew/opt/tomcat/libexec/webapps"
      else
        TOMCAT_WEBAPPS_DIR="/usr/local/opt/tomcat/libexec/webapps"
      fi
      ;;
    *) TOMCAT_WEBAPPS_DIR="/var/lib/tomcat/webapps" ;;
  esac
fi
TOMCAT_CONTEXT_PATH="${TOMCAT_CONTEXT_PATH:-/${APP_NAME}}"
TOMCAT_RESTART="${TOMCAT_RESTART:-true}"

if [[ -z "${TOMCAT_WAR_FILE:-}" ]]; then
  echo "TOMCAT_WAR_FILE is required when APP_RUNTIME=tomcat." >&2
  exit 1
fi
if [[ ! -f "$TOMCAT_WAR_FILE" ]]; then
  echo "TOMCAT_WAR_FILE not found: $TOMCAT_WAR_FILE" >&2
  exit 1
fi

context_name="${TOMCAT_CONTEXT_PATH#/}"
if [[ -z "$context_name" ]]; then
  target_war="$TOMCAT_WEBAPPS_DIR/ROOT.war"
else
  target_war="$TOMCAT_WEBAPPS_DIR/${context_name}.war"
fi

mkdir -p "$LOG_DIR" "$TOMCAT_WEBAPPS_DIR"
copy_file_with_backup "$TOMCAT_WAR_FILE" "$target_war" "$BACKUP_DIR"

if is_true "$TOMCAT_RESTART"; then
  reload_or_restart_service "$TOMCAT_SERVICE" "Tomcat"
else
  echo "Tomcat WAR deployed without service restart because TOMCAT_RESTART=false."
fi

echo "Installed Tomcat application: $target_war"
