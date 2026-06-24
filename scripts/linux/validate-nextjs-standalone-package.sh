#!/usr/bin/env bash
set -euo pipefail

PACKAGE_PATH=""
DEPLOYMENT_MODE="standalone"
STRIP_SINGLE_TOP_LEVEL_DIR="false"
REQUIRE_PUBLIC_DIR="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/validate-nextjs-standalone-package.sh --package-path PATH [options]

Validate a Next.js deployment archive.

Options:
  --package-path PATH       Package to validate: .tar.gz, .tgz, .tar, or .zip.
  --mode MODE               Next.js mode: standalone or next-start.
  --strip-single-top-level  Validate contents under a single wrapping directory.
  --require-public          Require public/ content in the runtime root.
  -h, --help                Show this help.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --package-path)
      PACKAGE_PATH="${2:?--package-path requires a value}"
      shift 2
      ;;
    --mode|--deployment-mode)
      DEPLOYMENT_MODE="${2:?--mode requires a value}"
      shift 2
      ;;
    --strip-single-top-level)
      STRIP_SINGLE_TOP_LEVEL_DIR="true"
      shift
      ;;
    --require-public)
      REQUIRE_PUBLIC_DIR="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_true() {
  case "${1:-false}" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_name() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_ ' '--'
}

abs_file_path() {
  local path="$1" dir base
  [[ -f "$path" ]] || {
    echo "PackagePath not found: $path" >&2
    exit 1
  }
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
}

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

blocked_artifact_path() {
  local rel="$1" name ext
  name="$(basename "$rel")"
  ext="${name##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  [[ "$name" == ".env" || "$name" == .env.* ]] && return 0
  case "$ext" in
    key|pem|pfx|p12|crt|csr) return 0 ;;
  esac
  return 1
}

archive_kind() {
  case "$PACKAGE_PATH" in
    *.tar.gz|*.tgz|*.tar) echo "tar" ;;
    *.zip) echo "zip" ;;
    *) echo "Unsupported package format. Use .tar.gz, .tgz, .tar, or .zip." >&2; exit 1 ;;
  esac
}

list_entries() {
  case "$(archive_kind)" in
    tar)
      tar -tf "$PACKAGE_PATH"
      ;;
    zip)
      command -v unzip >/dev/null 2>&1 || {
        echo "unzip is required to validate zip packages on Unix-like hosts." >&2
        exit 1
      }
      unzip -Z -1 "$PACKAGE_PATH"
      ;;
  esac
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

strip_wrapping_dir() {
  local entry="$1" top="$2"
  entry="${entry#./}"
  entry="${entry#/}"
  [[ -n "$top" ]] || {
    printf '%s\n' "$entry"
    return
  }
  top="${top%/}"
  if [[ "$entry" == "$top" ]]; then
    printf '\n'
  elif [[ "$entry" == "$top/"* ]]; then
    printf '%s\n' "${entry#"$top/"}"
  else
    printf '%s\n' "$entry"
  fi
}

[[ -n "$PACKAGE_PATH" ]] || {
  echo "--package-path is required." >&2
  usage >&2
  exit 2
}
PACKAGE_PATH="$(abs_file_path "$PACKAGE_PATH")"
DEPLOYMENT_MODE="$(normalize_name "$DEPLOYMENT_MODE")"
case "$DEPLOYMENT_MODE" in
  standalone|next-start) ;;
  *)
    echo "Next.js deployment mode must be standalone or next-start." >&2
    exit 1
    ;;
esac

if [[ "$(archive_kind)" == "tar" ]]; then
  validate_tar_has_no_links "$PACKAGE_PATH"
fi

raw_entries=()
while IFS= read -r entry; do
  raw_entries+=("$entry")
done < <(list_entries)
[[ "${#raw_entries[@]}" -gt 0 ]] || {
  echo "Package archive is empty." >&2
  exit 1
}

for entry in "${raw_entries[@]}"; do
  [[ -z "$entry" ]] && continue
  normalized_entry="${entry#./}"
  normalized_entry="${normalized_entry#/}"
  [[ -z "$normalized_entry" ]] && continue
  if ! safe_relative_path "$normalized_entry"; then
    echo "Unsafe archive entry path detected: $entry" >&2
    exit 1
  fi
done

top_level=""
if is_true "$STRIP_SINGLE_TOP_LEVEL_DIR"; then
  top_levels=()
  for entry in "${raw_entries[@]}"; do
    entry="${entry#./}"
    entry="${entry#/}"
    [[ -z "$entry" ]] && continue
    top="${entry%%/*}"
    top_levels+=("$top")
  done
  unique_top_levels="$(printf '%s\n' "${top_levels[@]}" | sort -u)"
  if [[ "$(printf '%s\n' "$unique_top_levels" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]]; then
    top_level="$(printf '%s\n' "$unique_top_levels" | sed '/^$/d')"
  fi
fi

runtime_entries=()
for entry in "${raw_entries[@]}"; do
  normalized="$(strip_wrapping_dir "$entry" "$top_level")"
  [[ -z "$normalized" ]] && continue
  runtime_entries+=("$normalized")
done

has_server="false"
has_static="false"
has_public="false"
has_package_json="false"
has_build_id="false"
has_next_build="false"
has_next_package="false"
blocked=()
for entry in "${runtime_entries[@]}"; do
  [[ "$entry" == "server.js" ]] && has_server="true"
  [[ "$entry" == .next/static/* ]] && has_static="true"
  [[ "$entry" == .next/BUILD_ID ]] && has_build_id="true"
  [[ "$entry" == public/* ]] && has_public="true"
  [[ "$entry" == "package.json" ]] && has_package_json="true"
  [[ "$entry" == .next/* ]] && has_next_build="true"
  [[ "$entry" == node_modules/next/* ]] && has_next_package="true"
  if blocked_artifact_path "$entry"; then
    blocked+=("$entry")
  fi
done

if [[ "${#blocked[@]}" -gt 0 ]]; then
  printf 'Package contains blocked private file(s):\n' >&2
  printf '  %s\n' "${blocked[@]}" >&2
  exit 1
fi
if [[ "$DEPLOYMENT_MODE" == "standalone" ]]; then
  is_true "$has_server" || {
    echo "Package is missing server.js at the runtime root." >&2
    exit 1
  }
  is_true "$has_build_id" || {
    echo "Package is missing .next/BUILD_ID at the runtime root." >&2
    exit 1
  }
  is_true "$has_static" || {
    echo "Package is missing .next/static content." >&2
    exit 1
  }
elif [[ "$DEPLOYMENT_MODE" == "next-start" ]]; then
  is_true "$has_package_json" || {
    echo "Package is missing package.json at the runtime root." >&2
    exit 1
  }
  is_true "$has_build_id" || {
    echo "Package is missing .next/BUILD_ID at the runtime root." >&2
    exit 1
  }
  is_true "$has_next_build" || {
    echo "Package is missing .next build output." >&2
    exit 1
  }
  is_true "$has_next_package" || {
    echo "Package is missing node_modules/next content." >&2
    exit 1
  }
fi
if is_true "$REQUIRE_PUBLIC_DIR" && ! is_true "$has_public"; then
  echo "Package is missing public content, but --require-public was set." >&2
  exit 1
fi

echo "Next.js $DEPLOYMENT_MODE package OK: $PACKAGE_PATH"
