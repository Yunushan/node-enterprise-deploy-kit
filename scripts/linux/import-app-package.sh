#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${1:-config/linux/app.env}"
PACKAGE_OVERRIDE="${2:-}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

PACKAGE_PATH="${PACKAGE_OVERRIDE:-${PACKAGE_PATH:-}}"
if [[ -z "$PACKAGE_PATH" ]]; then
  echo "No PACKAGE_PATH configured; skipping package import."
  exit 0
fi
if [[ "$PACKAGE_PATH" != /* ]]; then
  PACKAGE_PATH="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$PACKAGE_PATH"
fi
if [[ ! -f "$PACKAGE_PATH" ]]; then
  echo "PACKAGE_PATH not found: $PACKAGE_PATH" >&2
  exit 1
fi

APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"
if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
  echo "PACKAGE_PATH imports are for APP_RUNTIME=node. Use TOMCAT_WAR_FILE for Tomcat deployments." >&2
  exit 1
fi

PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR="${PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR:-true}"
PACKAGE_EXPECTED_FILES="${PACKAGE_EXPECTED_FILES:-${START_SCRIPT:-server.js}}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
SERVICE_MANAGER="${SERVICE_MANAGER:-$(default_service_manager "$(detect_platform_family)")}"

safe_relative_path() {
  local path="${1//\\//}"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *$'\0'* ]] || return 1
  IFS='/' read -r -a parts <<< "$path"
  local part
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    [[ "$part" != ".." ]] || return 1
  done
  return 0
}

validate_archive_member_paths() {
  local list_command=("$@")
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if ! safe_relative_path "$entry"; then
      echo "Unsafe archive entry path detected: $entry" >&2
      exit 1
    fi
  done < <("${list_command[@]}")
}

archive_kind() {
  case "$PACKAGE_PATH" in
    *.tar.gz|*.tgz) echo "tar" ;;
    *.tar) echo "tar" ;;
    *.zip) echo "zip" ;;
    *.rar|*.7z)
      echo "Unsupported archive format: $PACKAGE_PATH. Use .zip, .tar.gz, .tgz, or .tar. .rar/.7z require external tooling and are intentionally unsupported." >&2
      exit 1
      ;;
    *)
      echo "Unsupported archive format: $PACKAGE_PATH. Use .zip, .tar.gz, .tgz, or .tar." >&2
      exit 1
      ;;
  esac
}

stop_app_service_if_present() {
  local manager
  manager="$(normalize_name "$SERVICE_MANAGER")"
  case "$manager" in
    systemd)
      if service_exists_systemd "$APP_NAME"; then systemctl stop "$APP_NAME" || true; fi
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$APP_NAME" stop || true; elif [[ -x "/etc/init.d/$APP_NAME" ]]; then "/etc/init.d/$APP_NAME" stop || true; fi
      ;;
    openrc)
      if command -v rc-service >/dev/null 2>&1; then rc-service "$APP_NAME" stop || true; fi
      ;;
    launchd)
      if command -v launchctl >/dev/null 2>&1; then launchctl bootout "system/${APP_NAME}" >/dev/null 2>&1 || true; fi
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then service "$APP_NAME" stop || true; elif command -v rcctl >/dev/null 2>&1; then rcctl stop "$APP_NAME" || true; fi
      ;;
  esac
}

safe_replace_app_dir() {
  local source_root="$1" backup_path=""
  if [[ -z "${APP_DIR:-}" || "$APP_DIR" != /* || "$APP_DIR" == "/" ]]; then
    echo "APP_DIR must be a non-root absolute path before package import." >&2
    exit 1
  fi
  if [[ "$BACKUP_DIR" == "$APP_DIR" || "$BACKUP_DIR" == "$APP_DIR"/* ]]; then
    echo "BACKUP_DIR must not be inside APP_DIR when importing packages." >&2
    exit 1
  fi

  mkdir -p "$BACKUP_DIR" "$(dirname "$APP_DIR")"
  if [[ -e "$APP_DIR" ]]; then
    backup_path="$BACKUP_DIR/app.$(timestamp_utc).$$.bak"
    mv "$APP_DIR" "$backup_path"
    echo "Backed up existing APP_DIR to: $backup_path"
  fi

  mkdir -p "$APP_DIR"
  if ! (cd "$source_root" && tar -cf - .) | (cd "$APP_DIR" && tar -xf -); then
    rm -rf -- "$APP_DIR"
    if [[ -n "$backup_path" && -e "$backup_path" ]]; then
      mv "$backup_path" "$APP_DIR"
      echo "Restored previous APP_DIR after package import failure." >&2
    fi
    exit 1
  fi
}

extract_root="$(mktemp -d)"
cleanup() { rm -rf -- "$extract_root"; }
trap cleanup EXIT

kind="$(archive_kind)"
case "$kind" in
  tar)
    require_command tar "Install tar before importing tar packages."
    validate_archive_member_paths tar -tf "$PACKAGE_PATH"
    tar -xf "$PACKAGE_PATH" -C "$extract_root"
    ;;
  zip)
    require_command unzip "Install unzip before importing zip packages on Linux/Unix."
    validate_archive_member_paths unzip -Z -1 "$PACKAGE_PATH"
    unzip -q "$PACKAGE_PATH" -d "$extract_root"
    ;;
esac

source_root="$extract_root"
if is_true "$PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR"; then
  mapfile -t top_entries < <(find "$extract_root" -mindepth 1 -maxdepth 1 -print)
  if [[ "${#top_entries[@]}" -eq 1 && -d "${top_entries[0]}" ]]; then
    source_root="${top_entries[0]}"
  fi
fi

while IFS= read -r expected; do
  [[ -z "$expected" ]] && continue
  if ! safe_relative_path "$expected"; then
    echo "PACKAGE_EXPECTED_FILES contains an unsafe relative path: $expected" >&2
    exit 1
  fi
  if [[ ! -f "$source_root/$expected" ]]; then
    echo "Imported package is missing expected file: $expected" >&2
    exit 1
  fi
done < <(runtime_env_key_list "$PACKAGE_EXPECTED_FILES")

stop_app_service_if_present
safe_replace_app_dir "$source_root"

echo "Imported package into APP_DIR: $APP_DIR"
