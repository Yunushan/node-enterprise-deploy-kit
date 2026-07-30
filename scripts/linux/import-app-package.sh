#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
# shellcheck source=scripts/linux/app-package-safety.sh
source "$REPO_ROOT/scripts/linux/app-package-safety.sh"
# shellcheck source=scripts/linux/app-package-lifecycle.sh
source "$REPO_ROOT/scripts/linux/app-package-lifecycle.sh"

CONFIG_FILE="${1:-config/linux/app.env}"
PACKAGE_OVERRIDE="${2:-}"
PACKAGE_EXPECTED_SHA256_OVERRIDE="${3:-}"
PACKAGE_TRANSACTION_STATE_PATH="${4:-}"
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
NEXTJS_REQUIRE_PACKAGE_PROVENANCE="${NEXTJS_REQUIRE_PACKAGE_PROVENANCE:-false}"
REQUIRE_PACKAGE_SHA256="${REQUIRE_PACKAGE_SHA256:-true}"
PACKAGE_EXPECTED_SHA256="${PACKAGE_EXPECTED_SHA256_OVERRIDE:-${PACKAGE_EXPECTED_SHA256:-}}"
PACKAGE_PROVENANCE_FILE_NAME=".node-enterprise-package.json"
PACKAGE_PROVENANCE_SCHEMA="node-enterprise-deploy-kit/nextjs-package-provenance/v2"
PACKAGE_PROVENANCE_SCHEMA_VALUE=""
PACKAGE_PROVENANCE_BUILD_PLATFORM=""
PACKAGE_PROVENANCE_BUILD_ARCHITECTURE=""
PACKAGE_PROVENANCE_BUILD_LIBC=""
PACKAGE_PROVENANCE_NODE_MODULE_ABI=""
PACKAGE_PROVENANCE_NEXT_VERSION=""
PACKAGE_PROVENANCE_NEXT_BUILD_ID=""

if ! package_safety_load_policy; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi

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

canonical_archive_member_path() {
  local path="${1//\\//}" part canonical=""
  local -a parts
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    canonical="${canonical:+$canonical/}$part"
  done
  printf '%s' "$canonical" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

validate_archive_member_paths() {
  local list_command=("$@")
  local entry canonical duplicate entries_file="$work_root/archive-entry-names.txt"
  : > "$entries_file"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if ! safe_relative_path "$entry"; then
      echo "Unsafe archive entry path detected: $entry" >&2
      exit 1
    fi
    canonical="$(canonical_archive_member_path "$entry")"
    [[ -z "$canonical" ]] && continue
    printf '%s\n' "$canonical" >> "$entries_file"
  done < <("${list_command[@]}")

  duplicate="$(LC_ALL=C awk 'seen[$0]++ == 1 { print; exit }' "$entries_file")"
  rm -f -- "$entries_file"
  if [[ -n "$duplicate" ]]; then
    echo "Duplicate or case-colliding archive entry detected: $duplicate" >&2
    exit 1
  fi
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

validate_zip_has_no_special_entries() {
  local archive_path="$1" unsafe_line
  unsafe_line="$(LC_ALL=C unzip -Z -l "$archive_path" 2>/dev/null | awk '$1 ~ /^[bclps]/ { print; exit }')"
  if [[ -n "$unsafe_line" ]]; then
    echo "Unsafe zip entry type detected. Symlinks and special files are intentionally unsupported in deployment archives: $unsafe_line" >&2
    exit 1
  fi
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

target_platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) printf '%s\n' "linux" ;;
    Darwin) printf '%s\n' "macos" ;;
    FreeBSD) printf '%s\n' "freebsd" ;;
    OpenBSD) printf '%s\n' "openbsd" ;;
    NetBSD) printf '%s\n' "netbsd" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

target_architecture() {
  case "$(uname -m 2>/dev/null || echo unknown)" in
    x86_64|amd64) printf '%s\n' "x64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    i386|i486|i586|i686|x86) printf '%s\n' "x86" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

target_libc() {
  [[ "$(target_platform)" == "linux" ]] || {
    printf '%s\n' "not-applicable"
    return 0
  }

  if command -v getconf >/dev/null 2>&1 && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    printf '%s\n' "glibc"
    return 0
  fi
  if command -v ldd >/dev/null 2>&1 && { ldd --version 2>&1 || true; } | grep -qi "musl"; then
    printf '%s\n' "musl"
    return 0
  fi
  # Alpine's ldd can return nonzero for --version; its musl loader is authoritative.
  local musl_loader
  for musl_loader in /lib/ld-musl-*.so.1 /usr/lib/ld-musl-*.so.1; do
    if [[ -e "$musl_loader" ]]; then
      printf '%s\n' "musl"
      return 0
    fi
  done
  printf '%s\n' "unknown"
}

target_node_module_abi() {
  local abi node_bin="${NODE_BIN:-node}"
  abi="$("$node_bin" -p 'process.versions.modules' 2>/dev/null)" || {
    echo "Node.js executable could not report its native module ABI: $node_bin" >&2
    exit 1
  }
  abi="${abi//$'\r'/}"
  [[ "$abi" =~ ^[0-9]+$ ]] || {
    echo "Node.js executable returned an invalid native module ABI: $abi" >&2
    exit 1
  }
  printf '%s\n' "$abi"
}

provenance_json_value() {
  local file="$1" key="$2"
  awk -F'"' -v key="$key" '$2 == key { print $4; exit }' "$file"
}

require_provenance_value() {
  local file="$1" key="$2" value
  value="$(provenance_json_value "$file" "$key")"
  [[ -n "$value" ]] || {
    echo "Next.js package provenance is missing or has an empty $key." >&2
    exit 1
  }
  printf '%s\n' "$value"
}

validate_nextjs_package_provenance_if_needed() {
  if [[ "$APP_FRAMEWORK_NORMALIZED" != "next" && "$APP_FRAMEWORK_NORMALIZED" != "nextjs" && "$APP_FRAMEWORK_NORMALIZED" != "next-js" ]]; then
    return 0
  fi

  local marker_path="$1/$PACKAGE_PROVENANCE_FILE_NAME" required=false
  if is_true "$NEXTJS_REQUIRE_PACKAGE_PROVENANCE"; then
    required=true
  fi
  if [[ ! -f "$marker_path" ]]; then
    if [[ "$required" == true ]]; then
      echo "Next.js package provenance is required, but $PACKAGE_PROVENANCE_FILE_NAME is missing. Package on a compatible target or use the kit packaging helper." >&2
      exit 1
    fi
    return 0
  fi

  local schema source_framework source_mode source_platform source_architecture source_libc source_node_module_abi package_next_version package_next_build_id current_platform current_architecture current_libc current_node_module_abi
  schema="$(require_provenance_value "$marker_path" "schema")"
  source_framework="$(normalize_name "$(require_provenance_value "$marker_path" "appFramework")")"
  source_mode="$(normalize_name "$(require_provenance_value "$marker_path" "nextjsMode")")"
  source_platform="$(normalize_name "$(require_provenance_value "$marker_path" "buildPlatform")")"
  source_architecture="$(normalize_name "$(require_provenance_value "$marker_path" "buildArchitecture")")"
  source_libc="$(normalize_name "$(require_provenance_value "$marker_path" "buildLibc")")"
  source_node_module_abi="$(require_provenance_value "$marker_path" "nodeModuleAbi")"
  package_next_version="$(require_provenance_value "$marker_path" "nextVersion")"
  package_next_build_id="$(require_provenance_value "$marker_path" "nextBuildId")"
  current_platform="$(target_platform)"
  current_architecture="$(target_architecture)"
  current_libc="$(target_libc)"
  current_node_module_abi="$(target_node_module_abi)"

  [[ "$schema" == "$PACKAGE_PROVENANCE_SCHEMA" ]] || { echo "Unsupported Next.js package provenance schema: $schema" >&2; exit 1; }
  [[ "$source_framework" == "nextjs" || "$source_framework" == "next" || "$source_framework" == "next-js" ]] || { echo "Next.js package provenance appFramework must be nextjs." >&2; exit 1; }
  [[ "$source_mode" == "$NEXTJS_DEPLOYMENT_MODE_NORMALIZED" ]] || { echo "Next.js package provenance mode '$source_mode' does not match target mode '$NEXTJS_DEPLOYMENT_MODE_NORMALIZED'." >&2; exit 1; }
  [[ "$source_platform" == "$current_platform" ]] || { echo "Next.js package was built for '$source_platform', but this target is '$current_platform'." >&2; exit 1; }
  [[ "$source_architecture" == "$current_architecture" ]] || { echo "Next.js package architecture '$source_architecture' does not match target architecture '$current_architecture'." >&2; exit 1; }
  if [[ "$current_platform" == "linux" && "$source_libc" != "$current_libc" ]]; then
    echo "Next.js package libc '$source_libc' does not match Linux target libc '$current_libc'." >&2
    exit 1
  fi
  if [[ "$current_platform" != "linux" && "$source_libc" != "not-applicable" ]]; then
    echo "Next.js package provenance buildLibc must be not-applicable on $current_platform." >&2
    exit 1
  fi
  [[ "$source_node_module_abi" =~ ^[0-9]+$ ]] || { echo "Next.js package provenance nodeModuleAbi must be numeric." >&2; exit 1; }
  [[ "$source_node_module_abi" == "$current_node_module_abi" ]] || { echo "Next.js package Node native module ABI '$source_node_module_abi' does not match target Node ABI '$current_node_module_abi'. Rebuild the package with the target Node major version." >&2; exit 1; }
  if [[ "$required" == true && ( "$current_platform" == "unknown" || "$current_architecture" == "unknown" || ( "$current_platform" == "linux" && "$current_libc" == "unknown" ) ) ]]; then
    echo "Cannot enforce Next.js package provenance because target platform, architecture, or Linux libc is unknown." >&2
    exit 1
  fi

  PACKAGE_PROVENANCE_SCHEMA_VALUE="$schema"
  PACKAGE_PROVENANCE_BUILD_PLATFORM="$source_platform"
  PACKAGE_PROVENANCE_BUILD_ARCHITECTURE="$source_architecture"
  PACKAGE_PROVENANCE_BUILD_LIBC="$source_libc"
  PACKAGE_PROVENANCE_NODE_MODULE_ABI="$source_node_module_abi"
  PACKAGE_PROVENANCE_NEXT_VERSION="$package_next_version"
  PACKAGE_PROVENANCE_NEXT_BUILD_ID="$package_next_build_id"
  rm -f -- "$marker_path"
  echo "Next.js package provenance verified: $source_platform/$source_architecture/$source_libc"
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

next_build_id_from_app_dir() {
  local build_id_path="${APP_DIR%/}/.next/BUILD_ID" value
  [[ -f "$build_id_path" ]] || return 1
  IFS= read -r value < "$build_id_path" || return 1
  printf '%s\n' "$value"
}

write_deployment_manifest() {
  local manifest_path package_name package_hash deployment_id next_build_id generated_at
  manifest_path="${APP_DIR%/}/.node-enterprise-deploy.json"
  package_name="$PACKAGE_ORIGINAL_NAME"
  package_hash="$VERIFIED_PACKAGE_SHA256"
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
    if [[ -n "$PACKAGE_PROVENANCE_SCHEMA_VALUE" ]]; then
      printf '  "packageProvenance": {\n'
      printf '    "schema": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_SCHEMA_VALUE")"
      printf '    "buildPlatform": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_BUILD_PLATFORM")"
      printf '    "buildArchitecture": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_BUILD_ARCHITECTURE")"
      printf '    "buildLibc": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_BUILD_LIBC")"
      printf '    "nodeModuleAbi": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_NODE_MODULE_ABI")"
      printf '    "nextVersion": "%s",\n' "$(json_escape "$PACKAGE_PROVENANCE_NEXT_VERSION")"
      printf '    "nextBuildId": "%s"\n' "$(json_escape "$PACKAGE_PROVENANCE_NEXT_BUILD_ID")"
      printf '  },\n'
    else
      printf '  "packageProvenance": null,\n'
    fi
    printf '  "nextBuildId": "%s"\n' "$(json_escape "$next_build_id")"
    printf '}\n'
  } > "$manifest_path"
  chmod 0644 "$manifest_path" 2>/dev/null || true
  echo "Deployment manifest written: $manifest_path"
}

write_package_transaction_state() {
  local state_path="$1" temporary_path
  [[ -n "$state_path" ]] || return 0
  [[ "$state_path" == /* ]] || {
    echo "Package transaction state path must be absolute." >&2
    return 1
  }
  temporary_path="${state_path}.$$.tmp"
  umask 077
  mkdir -p "$(dirname "$state_path")"
  {
    printf '%s\n' "node-enterprise-deploy-kit/package-transaction/v2"
    printf '%s\n' "$APP_DIR"
    printf '%s\n' "$PACKAGE_APP_BACKUP_PATH"
    if [[ -n "$PACKAGE_APP_BACKUP_PATH" ]]; then printf '%s\n' "true"; else printf '%s\n' "false"; fi
    printf '%s\n' "$service_manager_normalized"
    printf '%s\n' "$APP_NAME"
    printf '%s\n' "$PACKAGE_APP_SERVICE_EXISTED"
    printf '%s\n' "$PACKAGE_APP_SERVICE_WAS_RUNNING"
  } > "$temporary_path"
  chmod 0600 "$temporary_path"
  mv -f -- "$temporary_path" "$state_path"
}

PACKAGE_EXPECTED_SHA256="$(printf '%s' "$PACKAGE_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
case "$REQUIRE_PACKAGE_SHA256" in
  true|TRUE|True|1|yes|YES|Yes) package_sha256_required="true" ;;
  false|FALSE|False|0|no|NO|No) package_sha256_required="false" ;;
  *)
    echo "REQUIRE_PACKAGE_SHA256 must be true or false." >&2
    exit 1
    ;;
esac
if [[ "$package_sha256_required" == "true" && -z "$PACKAGE_EXPECTED_SHA256" ]]; then
  echo "PACKAGE_EXPECTED_SHA256 is required when REQUIRE_PACKAGE_SHA256=true." >&2
  exit 1
fi
if [[ -n "$PACKAGE_EXPECTED_SHA256" && ! "$PACKAGE_EXPECTED_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
  echo "PACKAGE_EXPECTED_SHA256 must contain exactly 64 hexadecimal characters." >&2
  exit 1
fi

SOURCE_PACKAGE_PATH="$PACKAGE_PATH"
PACKAGE_ORIGINAL_NAME="$(basename "$SOURCE_PACKAGE_PATH")"
if [[ -z "${APP_DIR:-}" || "$APP_DIR" != /* || "$APP_DIR" == "/" ]]; then
  echo "APP_DIR must be a non-root absolute path before package import." >&2
  exit 1
fi
kind="$(archive_kind)"
case "$kind" in
  tar) require_command tar "Install tar before importing tar packages." ;;
  zip) require_command unzip "Install unzip before importing zip packages on Linux/Unix." ;;
esac
if ! package_safety_inspect_archive "$kind" "$SOURCE_PACKAGE_PATH"; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi
if ! package_safety_assert_capacity "${TMPDIR:-/tmp}" "$APP_DIR" "$BACKUP_DIR" false; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi

work_root="$(mktemp -d)"
extract_root="$work_root/extract"
cleanup() { rm -rf -- "$work_root"; }
trap cleanup EXIT
mkdir -p "$extract_root"

PACKAGE_PATH="$work_root/$PACKAGE_ORIGINAL_NAME"
cp "$SOURCE_PACKAGE_PATH" "$PACKAGE_PATH"
if ! VERIFIED_PACKAGE_SHA256="$(sha256_file "$PACKAGE_PATH")"; then
  echo "Unable to calculate the application package SHA-256. Install sha256sum, shasum, or openssl." >&2
  exit 1
fi
if [[ -n "$PACKAGE_EXPECTED_SHA256" && "$VERIFIED_PACKAGE_SHA256" != "$PACKAGE_EXPECTED_SHA256" ]]; then
  echo "Application package SHA-256 does not match PACKAGE_EXPECTED_SHA256." >&2
  exit 1
fi

kind="$(archive_kind)"
if ! package_safety_inspect_archive "$kind" "$PACKAGE_PATH"; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi
if ! package_safety_assert_capacity "$work_root" "$APP_DIR" "$BACKUP_DIR" true; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi
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
    validate_zip_has_no_special_entries "$PACKAGE_PATH"
    unzip -q "$PACKAGE_PATH" -d "$extract_root"
    ;;
esac

validate_extracted_tree_has_no_links "$extract_root"
if ! package_safety_assert_extracted_tree "$extract_root"; then
  echo "$PACKAGE_SAFETY_ERROR" >&2
  exit 1
fi

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

validate_nextjs_package_provenance_if_needed "$source_root"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

service_manager_normalized="$(normalize_name "$SERVICE_MANAGER")"
if package_stop_app_service "$service_manager_normalized" "$APP_NAME"; then
  :
else
  package_stop_exit=$?
  if ! package_restart_app_service_after_failure "$service_manager_normalized" "$APP_NAME"; then
    echo "CRITICAL: The previous service could not be restarted after its stop operation failed." >&2
  fi
  exit "$package_stop_exit"
fi

if package_replace_app_directory "$source_root" "$APP_DIR" "$BACKUP_DIR" write_deployment_manifest; then
  if write_package_transaction_state "$PACKAGE_TRANSACTION_STATE_PATH"; then
    :
  else
    state_exit=$?
    if package_restore_previous_app_directory "$APP_DIR" "$PACKAGE_APP_BACKUP_PATH"; then
      if ! package_restart_app_service_after_failure "$service_manager_normalized" "$APP_NAME"; then
        echo "CRITICAL: Previous service recovery failed after transaction-state write failure." >&2
      fi
    else
      echo "CRITICAL: APP_DIR recovery failed after transaction-state write failure; service remains stopped." >&2
    fi
    exit "$state_exit"
  fi
else
  package_replace_exit=$?
  if [[ "$PACKAGE_APP_DIRECTORY_RECOVERY_SUCCEEDED" == "true" ]]; then
    if ! package_restart_app_service_after_failure "$service_manager_normalized" "$APP_NAME"; then
      echo "CRITICAL: The previous service could not be restarted after package replacement failed." >&2
    fi
  elif [[ "$PACKAGE_APP_SERVICE_WAS_RUNNING" == "true" ]]; then
    echo "CRITICAL: The previous APP_DIR could not be restored, so the service was intentionally left stopped." >&2
  fi
  exit "$package_replace_exit"
fi

echo "Imported package into APP_DIR: $APP_DIR"
