#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="."
OUTPUT_PATH=""
STAGE_DIR=""
REQUIRE_PUBLIC_DIR="false"
NO_PUBLIC="false"
KEEP_STAGE="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/package-nextjs-standalone.sh [options]

Build a deployable Next.js standalone .tar.gz package.

Options:
  --project-path PATH       Next.js project root. Defaults to current directory.
  --output-path PATH        Output .tar.gz path. Defaults to release/<project>-nextjs-standalone.tar.gz.
  --stage-dir PATH          Temporary staging directory. Defaults to .tmp/nextjs-standalone-package.
  --require-public          Fail when public/ is missing.
  --no-public               Do not copy public/ even when it exists.
  --keep-stage              Keep the staging directory after packaging.
  -h, --help                Show this help.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --project-path)
      PROJECT_PATH="${2:?--project-path requires a value}"
      shift 2
      ;;
    --output-path)
      OUTPUT_PATH="${2:?--output-path requires a value}"
      shift 2
      ;;
    --stage-dir)
      STAGE_DIR="${2:?--stage-dir requires a value}"
      shift 2
      ;;
    --require-public)
      REQUIRE_PUBLIC_DIR="true"
      shift
      ;;
    --no-public)
      NO_PUBLIC="true"
      shift
      ;;
    --keep-stage)
      KEEP_STAGE="true"
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

abs_existing_dir() {
  local path="$1"
  [[ -d "$path" ]] || {
    echo "Directory not found: $path" >&2
    exit 1
  }
  (cd "$path" && pwd)
}

abs_new_path() {
  local path="$1" dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$dir"
  (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
}

is_true() {
  case "${1:-false}" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
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

assert_no_blocked_artifact_files() {
  local root="$1" file rel blocked=()
  while IFS= read -r -d '' file; do
    rel="${file#"$root"/}"
    if blocked_artifact_path "$rel"; then
      blocked+=("$rel")
    fi
  done < <(find "$root" -type f -print0)

  if [[ "${#blocked[@]}" -gt 0 ]]; then
    printf 'Next.js package stage contains blocked private file(s):\n' >&2
    printf '  %s\n' "${blocked[@]}" >&2
    exit 1
  fi
}

PROJECT_ROOT="$(abs_existing_dir "$PROJECT_PATH")"
STANDALONE_ROOT="$PROJECT_ROOT/.next/standalone"
STATIC_ROOT="$PROJECT_ROOT/.next/static"
BUILD_ID_PATH="$PROJECT_ROOT/.next/BUILD_ID"
PUBLIC_ROOT="$PROJECT_ROOT/public"

[[ -f "$STANDALONE_ROOT/server.js" ]] || {
  echo "Next.js standalone server was not found: $STANDALONE_ROOT/server.js. Build with output: 'standalone' before packaging." >&2
  exit 1
}
[[ -d "$STATIC_ROOT" ]] || {
  echo "Next.js static assets were not found: $STATIC_ROOT" >&2
  exit 1
}
[[ -f "$BUILD_ID_PATH" ]] || {
  echo "Next.js BUILD_ID was not found: $BUILD_ID_PATH. Build the app before packaging so runtime evidence can identify the deployed build." >&2
  exit 1
}
if is_true "$REQUIRE_PUBLIC_DIR" && [[ ! -d "$PUBLIC_ROOT" ]]; then
  echo "RequirePublicDirectory was set, but public directory was not found: $PUBLIC_ROOT" >&2
  exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_ROOT")"
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$PROJECT_ROOT/release/$PROJECT_NAME-nextjs-standalone.tar.gz"
fi
if [[ -z "$STAGE_DIR" ]]; then
  STAGE_DIR="$PROJECT_ROOT/.tmp/nextjs-standalone-package"
fi

OUTPUT_FULL="$(abs_new_path "$OUTPUT_PATH")"
STAGE_FULL="$(abs_new_path "$STAGE_DIR")"

rm -rf "$STAGE_FULL"
mkdir -p "$STAGE_FULL"

(cd "$STANDALONE_ROOT" && tar -cf - .) | (cd "$STAGE_FULL" && tar -xf -)

rm -rf "$STAGE_FULL/.next/static"
mkdir -p "$STAGE_FULL/.next"
cp -R "$STATIC_ROOT" "$STAGE_FULL/.next/static"
cp "$BUILD_ID_PATH" "$STAGE_FULL/.next/BUILD_ID"

if ! is_true "$NO_PUBLIC" && [[ -d "$PUBLIC_ROOT" ]]; then
  rm -rf "$STAGE_FULL/public"
  cp -R "$PUBLIC_ROOT" "$STAGE_FULL/public"
fi

assert_no_blocked_artifact_files "$STAGE_FULL"

mkdir -p "$(dirname "$OUTPUT_FULL")"
rm -f "$OUTPUT_FULL"
tar -C "$STAGE_FULL" -czf "$OUTPUT_FULL" .

validator_args=("--package-path" "$OUTPUT_FULL")
if is_true "$REQUIRE_PUBLIC_DIR"; then
  validator_args+=("--require-public")
fi
bash "$SCRIPT_DIR/validate-nextjs-standalone-package.sh" "${validator_args[@]}" >/dev/null

if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)server[.]js$'; then
  echo "Package archive is missing server.js at the archive root." >&2
  exit 1
fi
if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)[.]next/static/.+'; then
  echo "Package archive is missing .next/static content." >&2
  exit 1
fi
if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)[.]next/BUILD_ID$'; then
  echo "Package archive is missing .next/BUILD_ID at the archive root." >&2
  exit 1
fi

if ! is_true "$KEEP_STAGE"; then
  rm -rf "$STAGE_FULL"
fi

echo "Next.js standalone package: $OUTPUT_FULL"
