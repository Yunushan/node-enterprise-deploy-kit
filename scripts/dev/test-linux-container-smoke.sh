#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/dev/test-linux-container-smoke.sh --platform <name> [--image <image>] [--dry-run]
       scripts/dev/test-linux-container-smoke.sh --self-test

Runs the Unix deployment and Next.js smoke checks inside a target or
target-family Linux container. This is intended for CI on hosted Ubuntu runners
where Docker is available.
EOF
}

image_for_platform() {
  case "$1" in
    ubuntu) printf '%s\n' "ubuntu:24.04" ;;
    debian) printf '%s\n' "debian:stable-slim" ;;
    linux-mint) printf '%s\n' "ubuntu:24.04" ;;
    rhel) printf '%s\n' "registry.access.redhat.com/ubi9/ubi:latest" ;;
    oracle-linux) printf '%s\n' "oraclelinux:9" ;;
    centos) printf '%s\n' "quay.io/centos/centos:stream9" ;;
    centos-stream) printf '%s\n' "quay.io/centos/centos:stream9" ;;
    rocky) printf '%s\n' "rockylinux:9" ;;
    almalinux) printf '%s\n' "almalinux:9" ;;
    fedora) printf '%s\n' "fedora:latest" ;;
    alpine) printf '%s\n' "alpine:latest" ;;
    *)
      return 1
      ;;
  esac
}

build_container_script() {
  cat <<'CONTAINER'
set -eu

case "$PLATFORM_CASE" in
  ubuntu|debian|linux-mint)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash nodejs tar gzip zip unzip findutils procps ca-certificates
    ;;
  rhel|oracle-linux|centos|centos-stream|rocky|almalinux|fedora)
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates
    else
      echo "No dnf, yum, or microdnf package manager found for $PLATFORM_CASE." >&2
      exit 1
    fi
    ;;
  alpine)
    apk add --no-cache bash nodejs tar gzip zip unzip coreutils findutils procps ca-certificates
    ;;
  *)
    echo "Unsupported PLATFORM_CASE=$PLATFORM_CASE" >&2
    exit 2
    ;;
esac

export TEST_ROOT="/tmp/node-enterprise-deploy-kit-unix-nextjs-support-$PLATFORM_CASE"
rm -rf "$TEST_ROOT"

bash scripts/dev/lint-shell-basic.sh
bash scripts/dev/test-platform-matrix.sh --case "$PLATFORM_CASE"
bash scripts/dev/test-unix-nextjs-support.sh
CONTAINER
}

require_contains() {
  local text="$1" expected="$2" label="$3"
  if [[ "$text" != *"$expected"* ]]; then
    echo "$label did not contain expected text: $expected" >&2
    return 1
  fi
}

resolve_image() {
  local platform="$1" image_override="$2"
  if [[ -n "$image_override" ]]; then
    printf '%s\n' "$image_override"
    return 0
  fi
  image_for_platform "$platform"
}

run_container_smoke() {
  local platform="$1" image_override="$2" dry_run="$3"
  local image container_script docker_bin

  if ! image="$(resolve_image "$platform" "$image_override")"; then
    echo "Unsupported Linux container smoke platform: $platform" >&2
    return 2
  fi
  container_script="$(build_container_script)"

  if [[ "$dry_run" == "true" ]]; then
    require_contains "$container_script" "bash scripts/dev/lint-shell-basic.sh" "container script"
    require_contains "$container_script" "bash scripts/dev/test-platform-matrix.sh --case" "container script"
    require_contains "$container_script" "bash scripts/dev/test-unix-nextjs-support.sh" "container script"
    require_contains "$container_script" 'export TEST_ROOT="/tmp/node-enterprise-deploy-kit-unix-nextjs-support-$PLATFORM_CASE"' "container script"
    echo "Linux container smoke dry-run OK: $platform ($image)"
    return 0
  fi

  docker_bin="${DOCKER_BIN:-docker}"
  if ! command -v "$docker_bin" >/dev/null 2>&1; then
    echo "Docker was not found. Install Docker or run this check on a GitHub-hosted Ubuntu runner." >&2
    return 1
  fi

  echo "==> Linux container smoke: $platform ($image)"
  "$docker_bin" run --rm \
    -e PLATFORM_CASE="$platform" \
    -v "$REPO_ROOT:/repo" \
    -w /repo \
    "$image" \
    sh -lc "$container_script"

  echo "Linux container smoke OK: $platform"
}

run_self_test() {
  local platform output status

  for platform in ubuntu debian linux-mint rhel oracle-linux centos centos-stream rocky almalinux fedora alpine; do
    output="$(run_container_smoke "$platform" "" true)"
    require_contains "$output" "Linux container smoke dry-run OK: $platform" "dry-run output"
  done

  output="$(run_container_smoke "ubuntu" "example/custom:local" true)"
  require_contains "$output" "example/custom:local" "image override dry-run output"

  set +e
  output="$(run_container_smoke "solaris" "" true 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "Unsupported platform dry-run succeeded unexpectedly." >&2
    return 1
  fi
  require_contains "$output" "Unsupported Linux container smoke platform: solaris" "unsupported platform output"

  echo "Linux container smoke self-test OK"
}

platform_case=""
image_override=""
dry_run="false"
self_test="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --platform)
      platform_case="${2:-}"
      if [[ -z "$platform_case" ]]; then
        echo "--platform requires a value." >&2
        exit 2
      fi
      shift 2
      ;;
    --image)
      image_override="${2:-}"
      if [[ -z "$image_override" ]]; then
        echo "--image requires a value." >&2
        exit 2
      fi
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --self-test)
      self_test="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$self_test" == "true" ]]; then
  run_self_test
  exit 0
fi

if [[ -z "$platform_case" ]]; then
  echo "--platform is required." >&2
  usage >&2
  exit 2
fi

run_container_smoke "$platform_case" "$image_override" "$dry_run"
