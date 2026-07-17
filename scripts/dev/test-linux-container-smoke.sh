#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/dev/test-linux-container-smoke.sh --platform <name> [--image <image>] [--real-nextjs] [--systemv-service-integration] [--openrc-service-integration] [--apache-proxy-integration] [--nginx-proxy-integration] [--haproxy-integration] [--traefik-proxy-integration] [--dry-run]
       scripts/dev/test-linux-container-smoke.sh --self-test

Runs the Unix deployment and Next.js smoke checks inside a target or
target-family Linux container. This is intended for CI on hosted Ubuntu runners
where Docker is available. --real-nextjs additionally builds, packages, and
runs a temporary real Next.js application in the container.
--systemv-service-integration additionally installs, probes, and removes the
generated System V service; it is currently supported on the Ubuntu container.
--openrc-service-integration additionally installs, probes, and removes the
generated OpenRC service; it is currently supported on the Alpine container.
--apache-proxy-integration additionally runs Apache against the generated vhost
and probes a real Next.js response; it is currently supported on Ubuntu and Alpine.
--nginx-proxy-integration additionally runs Nginx against the generated site
and probes a real Next.js response; it is currently supported on Ubuntu and Alpine.
--haproxy-integration additionally runs HAProxy against the generated config
and probes a real Next.js response; it is currently supported on Ubuntu and Alpine.
--traefik-proxy-integration additionally runs Traefik against the generated
dynamic configuration and probes a real Next.js response; it is supported on Ubuntu and Alpine.
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

install_traefik() {
  local version="${TRAEFIK_VERSION:-v3.7.1}"
  local archive="traefik_${version}_linux_amd64.tar.gz"
  local checksum="${TRAEFIK_SHA256:-e92bcfb03fa1e6a70c4e7ad4eb4f1604967e6fa3c21d8e7605aca5407a40162c}"
  local temp_dir
  temp_dir="$(mktemp -d)"
  curl --fail --silent --show-error --location \
    --output "$temp_dir/$archive" \
    "https://github.com/traefik/traefik/releases/download/${version}/${archive}"
  printf '%s  %s\n' "$checksum" "$temp_dir/$archive" | sha256sum --check --status
  tar -xzf "$temp_dir/$archive" -C "$temp_dir" traefik
  install -m 0755 "$temp_dir/traefik" /usr/local/bin/traefik
  rm -rf "$temp_dir"
  traefik version
}

case "$PLATFORM_CASE" in
  ubuntu|debian|linux-mint)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash nodejs tar gzip zip unzip findutils procps ca-certificates curl xz-utils
    if [ "${RUN_APACHE_PROXY_INTEGRATION:-false}" = "true" ]; then
      apt-get install -y --no-install-recommends apache2
    fi
    if [ "${RUN_NGINX_PROXY_INTEGRATION:-false}" = "true" ]; then
      apt-get install -y --no-install-recommends nginx
    fi
    if [ "${RUN_HAPROXY_INTEGRATION:-false}" = "true" ]; then
      apt-get install -y --no-install-recommends haproxy
    fi
    if [ "${RUN_TRAEFIK_PROXY_INTEGRATION:-false}" = "true" ]; then
      install_traefik
    fi
    ;;
  rhel|oracle-linux|centos|centos-stream|rocky|almalinux|fedora)
    curl_package="curl"
    case "$PLATFORM_CASE" in
      rhel|oracle-linux|centos|centos-stream|rocky|almalinux) curl_package="curl-minimal" ;;
    esac
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates xz
      package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates xz
      package_manager="yum"
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y bash nodejs tar gzip zip unzip findutils procps-ng ca-certificates xz
      package_manager="microdnf"
    else
      echo "No dnf, yum, or microdnf package manager found for $PLATFORM_CASE." >&2
      exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
      "$package_manager" install -y "$curl_package"
    fi
    ;;
  alpine)
    apk add --no-cache bash nodejs npm tar gzip zip unzip coreutils findutils procps ca-certificates curl xz
    if [ "${RUN_OPENRC_SERVICE_INTEGRATION:-false}" = "true" ]; then
      apk add --no-cache openrc
      mkdir -p /run/openrc
      : > /run/openrc/softlevel
    fi
    if [ "${RUN_APACHE_PROXY_INTEGRATION:-false}" = "true" ]; then
      apk add --no-cache apache2 apache2-proxy
    fi
    if [ "${RUN_NGINX_PROXY_INTEGRATION:-false}" = "true" ]; then
      apk add --no-cache nginx
    fi
    if [ "${RUN_HAPROXY_INTEGRATION:-false}" = "true" ]; then
      apk add --no-cache haproxy
    fi
    if [ "${RUN_TRAEFIK_PROXY_INTEGRATION:-false}" = "true" ]; then
      install_traefik
    fi
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

install_real_nextjs_node() {
  local node_version node_platform node_archive node_root checksum_line
  node_version="${REAL_NEXTJS_NODE_VERSION:-24.17.0}"
  case "$node_version" in
    v*) ;;
    *) node_version="v$node_version" ;;
  esac

  if [ "$PLATFORM_CASE" = "alpine" ]; then
    echo "Using the signed Alpine nodejs package for real Next.js coverage."
    node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 20 || (major === 20 && minor < 9)) { console.error(`Alpine nodejs package ${process.versions.node} is below the Next.js minimum of 20.9.0.`); process.exit(1); }'
    return
  fi

  case "$(uname -m)" in
    x86_64|amd64) node_platform="linux-x64" ;;
    *)
      echo "Real Next.js container coverage currently requires an x86_64 Linux runner." >&2
      exit 1
      ;;
  esac

  node_archive="node-${node_version}-${node_platform}.tar.xz"
  node_root="/tmp/node-enterprise-deploy-kit-node-${node_version}-${node_platform}"
  rm -rf "$node_root"
  mkdir -p "$node_root"
  curl --fail --location --retry 3 --silent --show-error \
    "https://nodejs.org/dist/${node_version}/${node_archive}" \
    --output "$node_root/$node_archive"
  curl --fail --location --retry 3 --silent --show-error \
    "https://nodejs.org/dist/${node_version}/SHASUMS256.txt" \
    --output "$node_root/SHASUMS256.txt"
  checksum_line="$(grep -F "  $node_archive" "$node_root/SHASUMS256.txt" || true)"
  if [ -z "$checksum_line" ]; then
    echo "Official Node.js checksum was not found for $node_archive." >&2
    exit 1
  fi
  (
    cd "$node_root"
    printf '%s\n' "$checksum_line" | sha256sum -c -
    tar -xJf "$node_archive"
  )
  export PATH="$node_root/node-${node_version}-${node_platform}/bin:$PATH"
}

if [ "${RUN_REAL_NEXTJS:-false}" = "true" ]; then
  install_real_nextjs_node
  node --version
  export NODE_OPTIONS="--dns-result-order=ipv4first --use-system-ca"
  export NEXTJS_INTEGRATION_TEMP_ROOT="/tmp/node-enterprise-deploy-kit-real-nextjs-$PLATFORM_CASE"
  export NEXTJS_INTEGRATION_EXECUTION="container"
  export NEXTJS_INTEGRATION_TARGET="$PLATFORM_CASE"
  node scripts/dev/test-real-nextjs-integration.mjs
fi
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
  local platform="$1" image_override="$2" dry_run="$3" real_nextjs="$4" systemv_service_integration="$5" openrc_service_integration="$6" apache_proxy_integration="$7" nginx_proxy_integration="$8" haproxy_integration="$9" traefik_proxy_integration="${10}"
  local image container_script docker_bin result_path

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
    if [[ "$real_nextjs" == "true" ]]; then
      require_contains "$container_script" "install_real_nextjs_node" "container script"
      require_contains "$container_script" "node scripts/dev/test-real-nextjs-integration.mjs" "container script"
      require_contains "$container_script" 'curl_package="curl-minimal"' "container script"
      require_contains "$container_script" 'if ! command -v curl >/dev/null 2>&1; then' "container script"
      require_contains "$container_script" "apk add --no-cache bash nodejs npm" "container script"
      require_contains "$container_script" "apk add --no-cache openrc" "container script"
      if [[ "$systemv_service_integration" == "true" && "$platform" != "ubuntu" ]]; then
        echo "System V service integration is only supported for the Ubuntu container." >&2
        return 2
      fi
      if [[ "$openrc_service_integration" == "true" && "$platform" != "alpine" ]]; then
        echo "OpenRC service integration is only supported for the Alpine container." >&2
        return 2
      fi
      if [[ "$apache_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
        echo "Apache proxy integration is only supported for the Ubuntu and Alpine containers." >&2
        return 2
      fi
      if [[ "$nginx_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
        echo "Nginx proxy integration is only supported for the Ubuntu and Alpine containers." >&2
        return 2
      fi
      if [[ "$haproxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
        echo "HAProxy integration is only supported for the Ubuntu and Alpine containers." >&2
        return 2
      fi
      if [[ "$traefik_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
        echo "Traefik proxy integration is only supported for the Ubuntu and Alpine containers." >&2
        return 2
      fi
      echo "Linux container real Next.js dry-run OK: $platform ($image)"
    else
      echo "Linux container smoke dry-run OK: $platform ($image)"
    fi
    return 0
  fi

  docker_bin="${DOCKER_BIN:-docker}"
  result_path="${NEXTJS_INTEGRATION_RESULT_PATH:-}"
  if ! command -v "$docker_bin" >/dev/null 2>&1; then
    echo "Docker was not found. Install Docker or run this check on a GitHub-hosted Ubuntu runner." >&2
    return 1
  fi

  echo "==> Linux container smoke: $platform ($image)"
  if [[ "$systemv_service_integration" == "true" && "$platform" != "ubuntu" ]]; then
    echo "System V service integration is only supported for the Ubuntu container." >&2
    return 2
  fi
  if [[ "$openrc_service_integration" == "true" && "$platform" != "alpine" ]]; then
    echo "OpenRC service integration is only supported for the Alpine container." >&2
    return 2
  fi
  if [[ "$apache_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
    echo "Apache proxy integration is only supported for the Ubuntu and Alpine containers." >&2
    return 2
  fi
  if [[ "$nginx_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
    echo "Nginx proxy integration is only supported for the Ubuntu and Alpine containers." >&2
    return 2
  fi
  if [[ "$haproxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
    echo "HAProxy integration is only supported for the Ubuntu and Alpine containers." >&2
    return 2
  fi
  if [[ "$traefik_proxy_integration" == "true" && "$platform" != "ubuntu" && "$platform" != "alpine" ]]; then
    echo "Traefik proxy integration is only supported for the Ubuntu and Alpine containers." >&2
    return 2
  fi
  local docker_repo_root="$REPO_ROOT"
  local docker_command=()
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    docker_repo_root="$(cygpath -m "$REPO_ROOT")"
    docker_command=(env MSYS_NO_PATHCONV=1)
  fi

  "${docker_command[@]}" "$docker_bin" run --rm \
    -e PLATFORM_CASE="$platform" \
    -e RUN_REAL_NEXTJS="$real_nextjs" \
    -e RUN_SYSTEMV_SERVICE_INTEGRATION="$systemv_service_integration" \
    -e RUN_OPENRC_SERVICE_INTEGRATION="$openrc_service_integration" \
    -e RUN_APACHE_PROXY_INTEGRATION="$apache_proxy_integration" \
    -e RUN_NGINX_PROXY_INTEGRATION="$nginx_proxy_integration" \
    -e RUN_HAPROXY_INTEGRATION="$haproxy_integration" \
    -e RUN_TRAEFIK_PROXY_INTEGRATION="$traefik_proxy_integration" \
    -e NEXTJS_INTEGRATION_RESULT_PATH="$result_path" \
    -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
    -e GITHUB_WORKFLOW="${GITHUB_WORKFLOW:-}" \
    -e GITHUB_JOB="${GITHUB_JOB:-}" \
    -e GITHUB_RUN_ID="${GITHUB_RUN_ID:-}" \
    -e GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}" \
    -e GITHUB_SHA="${GITHUB_SHA:-}" \
    -v "$docker_repo_root:/repo" \
    -w /repo \
    "$image" \
    sh -lc "$container_script"

  if [[ "$real_nextjs" == "true" ]]; then
    if [[ "$systemv_service_integration" == "true" ]]; then
      echo "Linux container real Next.js System V service OK: $platform"
    elif [[ "$openrc_service_integration" == "true" ]]; then
      echo "Linux container real Next.js OpenRC service OK: $platform"
    elif [[ "$apache_proxy_integration" == "true" ]]; then
      echo "Linux container real Next.js Apache proxy OK: $platform"
    elif [[ "$nginx_proxy_integration" == "true" ]]; then
      echo "Linux container real Next.js Nginx proxy OK: $platform"
    elif [[ "$haproxy_integration" == "true" ]]; then
      echo "Linux container real Next.js HAProxy OK: $platform"
    elif [[ "$traefik_proxy_integration" == "true" ]]; then
      echo "Linux container real Next.js Traefik proxy OK: $platform"
    else
      echo "Linux container real Next.js OK: $platform"
    fi
  else
    echo "Linux container smoke OK: $platform"
  fi
}

run_self_test() {
  local platform output status

  for platform in ubuntu debian linux-mint rhel oracle-linux centos centos-stream rocky almalinux fedora alpine; do
    output="$(run_container_smoke "$platform" "" true false false false false false false false)"
    require_contains "$output" "Linux container smoke dry-run OK: $platform" "dry-run output"
  done

  output="$(run_container_smoke "ubuntu" "example/custom:local" true false false false false false false false)"
  require_contains "$output" "example/custom:local" "image override dry-run output"

  set +e
  output="$(run_container_smoke "solaris" "" true false false false false false false false 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "Unsupported platform dry-run succeeded unexpectedly." >&2
    return 1
  fi
  require_contains "$output" "Unsupported Linux container smoke platform: solaris" "unsupported platform output"

  output="$(run_container_smoke "ubuntu" "" true true false false false false false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "real Next.js dry-run output"

  output="$(run_container_smoke "ubuntu" "" true true true false false false false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "System V service integration dry-run output"

  output="$(run_container_smoke "alpine" "" true true false true false false false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: alpine" "OpenRC service integration dry-run output"

  output="$(run_container_smoke "ubuntu" "" true true false false true false false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "Apache proxy integration dry-run output"

  output="$(run_container_smoke "ubuntu" "" true true false false false true false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "Nginx proxy integration dry-run output"

  output="$(run_container_smoke "ubuntu" "" true true false false false false true false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "HAProxy integration dry-run output"

  output="$(run_container_smoke "ubuntu" "" true true false false false false false true)"
  require_contains "$output" "Linux container real Next.js dry-run OK: ubuntu" "Traefik proxy integration dry-run output"

  platform="alpine"
  output="$(run_container_smoke "$platform" "" true true false true true false false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: $platform" "Alpine Apache and OpenRC integration dry-run output"
  output="$(run_container_smoke "$platform" "" true true false true false true false false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: $platform" "Alpine Nginx and OpenRC integration dry-run output"
  output="$(run_container_smoke "$platform" "" true true false true false false true false)"
  require_contains "$output" "Linux container real Next.js dry-run OK: $platform" "Alpine HAProxy and OpenRC integration dry-run output"
  output="$(run_container_smoke "$platform" "" true true false true false false false true)"
  require_contains "$output" "Linux container real Next.js dry-run OK: $platform" "Alpine Traefik and OpenRC integration dry-run output"

  echo "Linux container smoke self-test OK"
}

platform_case=""
image_override=""
dry_run="false"
self_test="false"
real_nextjs="false"
systemv_service_integration="false"
openrc_service_integration="false"
apache_proxy_integration="false"
nginx_proxy_integration="false"
haproxy_integration="false"
traefik_proxy_integration="false"

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
    --real-nextjs)
      real_nextjs="true"
      shift
      ;;
    --systemv-service-integration)
      systemv_service_integration="true"
      shift
      ;;
    --openrc-service-integration)
      openrc_service_integration="true"
      shift
      ;;
    --apache-proxy-integration)
      apache_proxy_integration="true"
      shift
      ;;
    --nginx-proxy-integration)
      nginx_proxy_integration="true"
      shift
      ;;
    --haproxy-integration)
      haproxy_integration="true"
      shift
      ;;
    --traefik-proxy-integration)
      traefik_proxy_integration="true"
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

if [[ ( "$systemv_service_integration" == "true" || "$openrc_service_integration" == "true" || "$apache_proxy_integration" == "true" || "$nginx_proxy_integration" == "true" || "$haproxy_integration" == "true" || "$traefik_proxy_integration" == "true" ) && "$real_nextjs" != "true" ]]; then
  echo "--systemv-service-integration, --openrc-service-integration, --apache-proxy-integration, --nginx-proxy-integration, --haproxy-integration, and --traefik-proxy-integration require --real-nextjs." >&2
  exit 2
fi
service_integration_count=0
proxy_integration_count=0
[[ "$systemv_service_integration" == "true" ]] && service_integration_count=$((service_integration_count + 1))
[[ "$openrc_service_integration" == "true" ]] && service_integration_count=$((service_integration_count + 1))
[[ "$apache_proxy_integration" == "true" ]] && proxy_integration_count=$((proxy_integration_count + 1))
[[ "$nginx_proxy_integration" == "true" ]] && proxy_integration_count=$((proxy_integration_count + 1))
[[ "$haproxy_integration" == "true" ]] && proxy_integration_count=$((proxy_integration_count + 1))
[[ "$traefik_proxy_integration" == "true" ]] && proxy_integration_count=$((proxy_integration_count + 1))
if (( service_integration_count > 1 || proxy_integration_count > 1 )); then
  echo "Use at most one native service integration and one reverse-proxy integration option." >&2
  exit 2
fi

run_container_smoke "$platform_case" "$image_override" "$dry_run" "$real_nextjs" "$systemv_service_integration" "$openrc_service_integration" "$apache_proxy_integration" "$nginx_proxy_integration" "$haproxy_integration" "$traefik_proxy_integration"
