#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${1:-config/linux/app.env}"
PACKAGE_OVERRIDE="${2:-}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

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
APP_FRAMEWORK_NORMALIZED="$(normalize_name "${APP_FRAMEWORK:-node}")"
NEXTJS_DEPLOYMENT_MODE_NORMALIZED="$(normalize_name "${NEXTJS_DEPLOYMENT_MODE:-standalone}")"
REACT_DOCUMENT_ROOT_NORMALIZED="${REACT_DOCUMENT_ROOT:-build}"

safe_relative_path() {
  local path="${1//\\//}"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  case "$path" in
    [A-Za-z]:*) return 1 ;;
  esac
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

validate_tar_has_no_links() {
  local archive_path="$1" entry_type line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    entry_type="${line:0:1}"
    case "$entry_type" in
      l|h)
        echo "Unsafe tar link entry detected. Symlinks and hardlinks are intentionally unsupported in deployment archives: $line" >&2
        exit 1
        ;;
    esac
  done < <(tar -tvf "$archive_path")
}

validate_extracted_tree_has_no_links() {
  local root_path="$1" link_path
  while IFS= read -r link_path; do
    echo "Unsafe extracted link entry detected. Symlinks are intentionally unsupported in deployment archives: $link_path" >&2
    exit 1
  done < <(find "$root_path" -type l -print)
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

validate_nextjs_package_if_needed() {
  if [[ "$APP_FRAMEWORK_NORMALIZED" != "next" && "$APP_FRAMEWORK_NORMALIZED" != "nextjs" && "$APP_FRAMEWORK_NORMALIZED" != "next-js" ]]; then
    return 0
  fi
  case "$NEXTJS_DEPLOYMENT_MODE_NORMALIZED" in
    standalone|next-start) ;;
    *)
      echo "NEXTJS_DEPLOYMENT_MODE must be standalone or next-start." >&2
      exit 1
      ;;
  esac

  local args=("--package-path" "$PACKAGE_PATH" "--mode" "$NEXTJS_DEPLOYMENT_MODE_NORMALIZED")
  if is_true "$PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR"; then
    args+=("--strip-single-top-level")
  fi
  if is_true "${NEXTJS_REQUIRE_PUBLIC_DIR:-false}"; then
    args+=("--require-public")
  fi
  bash "$SCRIPT_DIR/validate-nextjs-standalone-package.sh" "${args[@]}"
}

validate_react_package_if_needed() {
  if [[ "$APP_FRAMEWORK_NORMALIZED" != "react" && "$APP_FRAMEWORK_NORMALIZED" != "reactjs" && "$APP_FRAMEWORK_NORMALIZED" != "react-js" ]]; then
    return 0
  fi

  local args=("--package-path" "$PACKAGE_PATH" "--react-document-root" "$REACT_DOCUMENT_ROOT_NORMALIZED")
  if is_true "$PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR"; then
    args+=("--strip-single-top-level")
  fi
  bash "$SCRIPT_DIR/validate-react-static-package.sh" "${args[@]}"
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

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

package_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print tolower($1) }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print tolower($1) }'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$path" | awk '{ print tolower($1) }'
  else
    echo ""
  fi
}

next_build_id_from_app_dir() {
  local build_id_path="${APP_DIR%/}/.next/BUILD_ID" value
  [[ -f "$build_id_path" ]] || return 1
  IFS= read -r value < "$build_id_path" || return 1
  printf '%s\n' "$value"
}

write_deployment_manifest() {
  local manifest_path package_name package_hash deployment_id next_build_id generated_at
  manifest_path="${APP_DIR%/}/.node-enterprise-deploy.json"
  package_name="$(basename "$PACKAGE_PATH")"
  package_hash="$(package_sha256 "$PACKAGE_PATH")"
  deployment_id="${NEXT_DEPLOYMENT_ID:-${DEPLOYMENT_ID:-}}"
  next_build_id="$(next_build_id_from_app_dir 2>/dev/null || echo "")"
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  {
    printf '{\n'
    printf '  "schema": "node-enterprise-deploy-kit/import-manifest/v1",\n'
    printf '  "generatedAtUtc": "%s",\n' "$(json_escape "$generated_at")"
    printf '  "appName": "%s",\n' "$(json_escape "${APP_NAME:-}")"
    printf '  "appFramework": "%s",\n' "$(json_escape "$APP_FRAMEWORK_NORMALIZED")"
    printf '  "nextjsMode": "%s",\n' "$(json_escape "$NEXTJS_DEPLOYMENT_MODE_NORMALIZED")"
    printf '  "reactDocumentRoot": "%s",\n' "$(json_escape "$REACT_DOCUMENT_ROOT_NORMALIZED")"
    printf '  "packageName": "%s",\n' "$(json_escape "$package_name")"
    printf '  "packageSha256": "%s",\n' "$(json_escape "$package_hash")"
    printf '  "deploymentId": "%s",\n' "$(json_escape "$deployment_id")"
    printf '  "nextBuildId": "%s"\n' "$(json_escape "$next_build_id")"
    printf '}\n'
  } > "$manifest_path"
  chmod 0644 "$manifest_path" 2>/dev/null || true
  echo "Deployment manifest written: $manifest_path"
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
validate_nextjs_package_if_needed
validate_react_package_if_needed
case "$kind" in
  tar)
    require_command tar "Install tar before importing tar packages."
    validate_archive_member_paths tar -tf "$PACKAGE_PATH"
    validate_tar_has_no_links "$PACKAGE_PATH"
    tar -xf "$PACKAGE_PATH" -C "$extract_root"
    ;;
  zip)
    require_command unzip "Install unzip before importing zip packages on Linux/Unix."
    validate_archive_member_paths unzip -Z -1 "$PACKAGE_PATH"
    unzip -q "$PACKAGE_PATH" -d "$extract_root"
    ;;
esac

validate_extracted_tree_has_no_links "$extract_root"

source_root="$extract_root"
if is_true "$PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR"; then
  top_entries=()
  while IFS= read -r entry; do
    top_entries+=("$entry")
  done < <(find "$extract_root" -mindepth 1 -maxdepth 1 -print)
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
  if [[ ! -e "$source_root/$expected" ]]; then
    echo "Imported package is missing expected path: $expected" >&2
    exit 1
  fi
done < <(runtime_env_key_list "$PACKAGE_EXPECTED_FILES")

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

stop_app_service_if_present
safe_replace_app_dir "$source_root"
write_deployment_manifest

echo "Imported package into APP_DIR: $APP_DIR"
