#!/usr/bin/env bash
set -euo pipefail

PACKAGE_PATH=""
REACT_DOCUMENT_ROOT="build"
STRIP_SINGLE_TOP_LEVEL_DIR="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/validate-react-static-package.sh --package-path PATH [options]

Validate a React static build archive.

Options:
  --package-path PATH          Package to validate: .tar.gz, .tgz, .tar, or .zip.
  --react-document-root PATH   Relative directory containing index.html, usually build or dist.
  --strip-single-top-level     Validate contents under a single wrapping directory.
  -h, --help                   Show this help.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --package-path)
      PACKAGE_PATH="${2:?--package-path requires a value}"
      shift 2
      ;;
    --react-document-root)
      REACT_DOCUMENT_ROOT="${2:?--react-document-root requires a value}"
      shift 2
      ;;
    --strip-single-top-level)
      STRIP_SINGLE_TOP_LEVEL_DIR="true"
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

react_document_root() {
  local root="${REACT_DOCUMENT_ROOT:-build}"
  root="${root//\\//}"
  root="${root#/}"
  root="${root%/}"
  [[ -n "$root" ]] || root="build"
  printf '%s\n' "$root"
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
DOCUMENT_ROOT="$(react_document_root)"
safe_relative_path "$DOCUMENT_ROOT" || {
  echo "REACT_DOCUMENT_ROOT must be a safe relative directory path." >&2
  exit 1
}

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

if [[ "$DOCUMENT_ROOT" == "." ]]; then
  index_entry="index.html"
  asset_prefix=""
else
  index_entry="$DOCUMENT_ROOT/index.html"
  asset_prefix="$DOCUMENT_ROOT/"
fi
has_index="false"
has_assets="false"
blocked=()
for entry in "${runtime_entries[@]}"; do
  [[ "$entry" == "$index_entry" ]] && has_index="true"
  [[ "$entry" == "${asset_prefix}static/"* || "$entry" == "${asset_prefix}assets/"* ]] && has_assets="true"
  if blocked_artifact_path "$entry"; then
    blocked+=("$entry")
  fi
done

if [[ "${#blocked[@]}" -gt 0 ]]; then
  printf 'Package contains blocked private file(s):\n' >&2
  printf '  %s\n' "${blocked[@]}" >&2
  exit 1
fi
is_true "$has_index" || {
  echo "Package is missing React index.html at $index_entry." >&2
  exit 1
}
if ! is_true "$has_assets"; then
  echo "WARNING: Package has no React static/assets entries under $DOCUMENT_ROOT. This can be valid for tiny apps, but verify browser assets are present." >&2
fi

echo "React static package OK: $PACKAGE_PATH"
