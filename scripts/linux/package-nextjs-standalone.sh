#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="."
DEPLOYMENT_MODE="standalone"
OUTPUT_PATH=""
STAGE_DIR=""
REQUIRE_PUBLIC_DIR="false"
NO_PUBLIC="false"
KEEP_STAGE="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/package-nextjs-standalone.sh [options]

Build a deployable Next.js .tar.gz package.

Options:
  --project-path PATH       Next.js project root. Defaults to current directory.
  --mode MODE               Next.js mode: standalone or next-start. Defaults to standalone.
  --output-path PATH        Output .tar.gz path. Defaults to release/<project>-nextjs-<mode>.tar.gz.
  --stage-dir PATH          Temporary staging directory. Defaults to .tmp/nextjs-<mode>-package.
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
    --mode|--deployment-mode)
      DEPLOYMENT_MODE="${2:?--mode requires a value}"
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

normalize_name() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_ ' '--'
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
DEPLOYMENT_MODE="$(normalize_name "$DEPLOYMENT_MODE")"
case "$DEPLOYMENT_MODE" in
  standalone|next-start) ;;
  *)
    echo "Next.js deployment mode must be standalone or next-start." >&2
    exit 1
    ;;
esac

STANDALONE_ROOT="$PROJECT_ROOT/.next/standalone"
STATIC_ROOT="$PROJECT_ROOT/.next/static"
STANDALONE_NEXT_PACKAGE_JSON_PATH="$STANDALONE_ROOT/node_modules/next/package.json"
NEXT_ROOT="$PROJECT_ROOT/.next"
BUILD_ID_PATH="$PROJECT_ROOT/.next/BUILD_ID"
PUBLIC_ROOT="$PROJECT_ROOT/public"
PACKAGE_JSON_PATH="$PROJECT_ROOT/package.json"
NODE_MODULES_ROOT="$PROJECT_ROOT/node_modules"
NEXT_PACKAGE_ROOT="$NODE_MODULES_ROOT/next"
NEXT_PACKAGE_JSON_PATH="$NEXT_PACKAGE_ROOT/package.json"
NEXT_CLI_PATH="$NEXT_PACKAGE_ROOT/dist/bin/next"

[[ -f "$BUILD_ID_PATH" ]] || {
  echo "Next.js BUILD_ID was not found: $BUILD_ID_PATH. Build the app before packaging so runtime evidence can identify the deployed build." >&2
  exit 1
}
if is_true "$REQUIRE_PUBLIC_DIR" && [[ ! -d "$PUBLIC_ROOT" ]]; then
  echo "RequirePublicDirectory was set, but public directory was not found: $PUBLIC_ROOT" >&2
  exit 1
fi
if [[ "$DEPLOYMENT_MODE" == "standalone" ]]; then
  [[ -f "$STANDALONE_ROOT/server.js" ]] || {
    echo "Next.js standalone server was not found: $STANDALONE_ROOT/server.js. Build with output: 'standalone' before packaging." >&2
    exit 1
  }
  [[ -d "$STATIC_ROOT" ]] || {
    echo "Next.js static assets were not found: $STATIC_ROOT" >&2
    exit 1
  }
  [[ -f "$STANDALONE_NEXT_PACKAGE_JSON_PATH" ]] || {
    echo "Next.js standalone package metadata was not found: $STANDALONE_NEXT_PACKAGE_JSON_PATH. Build with output: 'standalone' before packaging so runtime evidence can prove the installed Next.js version." >&2
    exit 1
  }
else
  [[ -f "$PACKAGE_JSON_PATH" ]] || {
    echo "Next.js next-start package.json was not found: $PACKAGE_JSON_PATH" >&2
    exit 1
  }
  [[ -d "$NEXT_ROOT" ]] || {
    echo "Next.js next-start .next directory was not found: $NEXT_ROOT" >&2
    exit 1
  }
  [[ -d "$NEXT_PACKAGE_ROOT" ]] || {
    echo "Next.js next-start node_modules/next directory was not found: $NEXT_PACKAGE_ROOT. Run a production install before packaging." >&2
    exit 1
  }
  [[ -f "$NEXT_PACKAGE_JSON_PATH" ]] || {
    echo "Next.js next-start package metadata was not found: $NEXT_PACKAGE_JSON_PATH. Run a production install before packaging so runtime evidence can prove the installed Next.js version." >&2
    exit 1
  }
  [[ -f "$NEXT_CLI_PATH" ]] || {
    echo "Next.js next-start CLI file was not found: $NEXT_CLI_PATH. Run a production install before packaging." >&2
    exit 1
  }
fi

PROJECT_NAME="$(basename "$PROJECT_ROOT")"
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$PROJECT_ROOT/release/$PROJECT_NAME-nextjs-$DEPLOYMENT_MODE.tar.gz"
fi
if [[ -z "$STAGE_DIR" ]]; then
  STAGE_DIR="$PROJECT_ROOT/.tmp/nextjs-$DEPLOYMENT_MODE-package"
fi

OUTPUT_FULL="$(abs_new_path "$OUTPUT_PATH")"
STAGE_FULL="$(abs_new_path "$STAGE_DIR")"

rm -rf "$STAGE_FULL"
mkdir -p "$STAGE_FULL"

if [[ "$DEPLOYMENT_MODE" == "standalone" ]]; then
  (cd "$STANDALONE_ROOT" && tar -cf - .) | (cd "$STAGE_FULL" && tar -xf -)

  rm -rf "$STAGE_FULL/.next/static"
  mkdir -p "$STAGE_FULL/.next"
  cp -R "$STATIC_ROOT" "$STAGE_FULL/.next/static"
  cp "$BUILD_ID_PATH" "$STAGE_FULL/.next/BUILD_ID"
else
  cp "$PACKAGE_JSON_PATH" "$STAGE_FULL/package.json"
  cp -R "$NEXT_ROOT" "$STAGE_FULL/.next"
  cp -R "$NODE_MODULES_ROOT" "$STAGE_FULL/node_modules"
  rm -rf "$STAGE_FULL/node_modules/.bin"
  for optional_file in \
    next.config.js \
    next.config.mjs \
    next.config.cjs \
    next.config.ts \
    package-lock.json \
    npm-shrinkwrap.json \
    yarn.lock \
    pnpm-lock.yaml \
    bun.lock \
    bun.lockb; do
    if [[ -f "$PROJECT_ROOT/$optional_file" ]]; then
      cp "$PROJECT_ROOT/$optional_file" "$STAGE_FULL/$optional_file"
    fi
  done
fi

if ! is_true "$NO_PUBLIC" && [[ -d "$PUBLIC_ROOT" ]]; then
  rm -rf "$STAGE_FULL/public"
  cp -R "$PUBLIC_ROOT" "$STAGE_FULL/public"
fi

assert_no_blocked_artifact_files "$STAGE_FULL"

mkdir -p "$(dirname "$OUTPUT_FULL")"
rm -f "$OUTPUT_FULL"
tar -C "$STAGE_FULL" -czf "$OUTPUT_FULL" .

validator_args=("--package-path" "$OUTPUT_FULL" "--mode" "$DEPLOYMENT_MODE")
if is_true "$REQUIRE_PUBLIC_DIR"; then
  validator_args+=("--require-public")
fi
bash "$SCRIPT_DIR/validate-nextjs-standalone-package.sh" "${validator_args[@]}" >/dev/null

if [[ "$DEPLOYMENT_MODE" == "standalone" ]]; then
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
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)node_modules/next/package[.]json$'; then
    echo "Package archive is missing node_modules/next/package.json at the archive root." >&2
    exit 1
  fi
else
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)package[.]json$'; then
    echo "Package archive is missing package.json at the archive root." >&2
    exit 1
  fi
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)[.]next/BUILD_ID$'; then
    echo "Package archive is missing .next/BUILD_ID at the archive root." >&2
    exit 1
  fi
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)node_modules/next/.+'; then
    echo "Package archive is missing node_modules/next content." >&2
    exit 1
  fi
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)node_modules/next/package[.]json$'; then
    echo "Package archive is missing node_modules/next/package.json at the archive root." >&2
    exit 1
  fi
  if ! tar -tzf "$OUTPUT_FULL" | grep -Eq '(^|[.]/)node_modules/next/dist/bin/next$'; then
    echo "Package archive is missing node_modules/next/dist/bin/next at the archive root." >&2
    exit 1
  fi
fi

if ! is_true "$KEEP_STAGE"; then
  rm -rf "$STAGE_FULL"
fi

echo "Next.js $DEPLOYMENT_MODE package: $OUTPUT_FULL"
