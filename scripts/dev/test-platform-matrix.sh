#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

case_filter="all"
if [[ "${1:-}" == "--case" ]]; then
  case_filter="${2:-}"
  if [[ -z "$case_filter" ]]; then
    echo "--case requires a value." >&2
    exit 2
  fi
elif [[ "$#" -gt 0 ]]; then
  echo "Usage: $0 [--case <name>]" >&2
  exit 2
fi

case_sample() {
  case "$1" in
    ubuntu) printf '%s\n' "debian ubuntu" ;;
    debian) printf '%s\n' "debian" ;;
    linux-mint) printf '%s\n' "ubuntu debian linuxmint" ;;
    rhel) printf '%s\n' "rhel fedora" ;;
    oracle-linux) printf '%s\n' "rhel fedora ol oracle" ;;
    centos) printf '%s\n' "rhel fedora centos" ;;
    centos-stream) printf '%s\n' "rhel fedora centos stream" ;;
    rocky) printf '%s\n' "rhel fedora rocky" ;;
    almalinux) printf '%s\n' "rhel fedora almalinux" ;;
    fedora) printf '%s\n' "fedora" ;;
    alpine) printf '%s\n' "alpine" ;;
    macos) printf '%s\n' "darwin macos" ;;
    freebsd) printf '%s\n' "freebsd bsd" ;;
    openbsd) printf '%s\n' "openbsd bsd" ;;
    netbsd) printf '%s\n' "netbsd bsd" ;;
    *) return 1 ;;
  esac
}

expected_family() {
  case "$1" in
    ubuntu|debian|linux-mint) printf '%s\n' "debian" ;;
    rhel|oracle-linux|centos|centos-stream|rocky|almalinux|fedora) printf '%s\n' "rhel" ;;
    alpine) printf '%s\n' "alpine" ;;
    macos) printf '%s\n' "macos" ;;
    freebsd) printf '%s\n' "freebsd" ;;
    openbsd) printf '%s\n' "openbsd" ;;
    netbsd) printf '%s\n' "netbsd" ;;
    *) return 1 ;;
  esac
}

expected_manager() {
  case "$1" in
    alpine) printf '%s\n' "openrc" ;;
    macos) printf '%s\n' "launchd" ;;
    freebsd|openbsd|netbsd) printf '%s\n' "bsdrc" ;;
    *) printf '%s\n' "systemd" ;;
  esac
}

run_case() {
  local name="$1" sample family expected expected_service_manager actual_service_manager
  sample="$(case_sample "$name")"
  expected="$(expected_family "$name")"
  family="$(classify_platform_family "$sample")"
  if [[ "$family" != "$expected" ]]; then
    echo "$name classified as $family, expected $expected." >&2
    exit 1
  fi

  expected_service_manager="$(expected_manager "$name")"
  actual_service_manager="$(recommended_service_manager_for_family "$family")"
  if [[ "$actual_service_manager" != "$expected_service_manager" ]]; then
    echo "$name recommended manager was $actual_service_manager, expected $expected_service_manager." >&2
    exit 1
  fi

  echo "$name -> family=$family manager=$actual_service_manager"
}

all_cases="ubuntu debian linux-mint rhel oracle-linux centos centos-stream rocky almalinux fedora alpine macos freebsd openbsd netbsd"

if [[ "$case_filter" == "all" ]]; then
  for item in $all_cases; do
    run_case "$item"
  done
else
  if ! case_sample "$case_filter" >/dev/null; then
    echo "Unknown platform matrix case: $case_filter" >&2
    exit 2
  fi
  run_case "$case_filter"
fi

echo "Platform matrix checks OK"
