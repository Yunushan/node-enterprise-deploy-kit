#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-}"
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
REVERSE_PROXY="${REVERSE_PROXY:-nginx}"
REVERSE_PROXY_NORMALIZED="$(normalize_name "$REVERSE_PROXY")"
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"
PLATFORM_FAMILY="$(detect_platform_family)"
if [[ "$PLATFORM_FAMILY" != "macos" && "${EUID}" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi
if [[ "$PLATFORM_FAMILY" == "macos" && "${EUID}" -eq 0 ]]; then
  echo "Run macOS dependency bootstrap without sudo so Homebrew can manage packages safely." >&2
  exit 1
fi
NGINX_PACKAGE="${NGINX_PACKAGE:-nginx}"
APACHE_PACKAGE="${APACHE_PACKAGE:-}"
HAPROXY_PACKAGE="${HAPROXY_PACKAGE:-haproxy}"
TRAEFIK_PACKAGE="${TRAEFIK_PACKAGE:-traefik}"
TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-}"

case "$PLATFORM_FAMILY" in
  debian)
    APACHE_PACKAGE="${APACHE_PACKAGE:-apache2}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat9}"
    ;;
  rhel)
    APACHE_PACKAGE="${APACHE_PACKAGE:-httpd}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat}"
    ;;
  alpine)
    APACHE_PACKAGE="${APACHE_PACKAGE:-apache2}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat10}"
    ;;
  freebsd)
    APACHE_PACKAGE="${APACHE_PACKAGE:-apache24}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat10}"
    ;;
  openbsd)
    APACHE_PACKAGE="${APACHE_PACKAGE:-apache-httpd}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat}"
    ;;
  netbsd)
    APACHE_PACKAGE="${APACHE_PACKAGE:-apache}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-apache-tomcat}"
    ;;
  macos)
    APACHE_PACKAGE="${APACHE_PACKAGE:-httpd}"
    TOMCAT_PACKAGE="${TOMCAT_PACKAGE:-tomcat}"
    ;;
esac

add_reverse_proxy_package() {
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx) packages+=("$NGINX_PACKAGE") ;;
    apache|httpd) packages+=("$APACHE_PACKAGE") ;;
    haproxy) packages+=("$HAPROXY_PACKAGE") ;;
    traefik) packages+=("$TRAEFIK_PACKAGE") ;;
    none|"") ;;
    *) echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, haproxy, traefik, or none." >&2; exit 1 ;;
  esac
}

add_runtime_package() {
  case "$APP_RUNTIME_NORMALIZED" in
    node) ;;
    tomcat|apache-tomcat)
      if [[ -n "$TOMCAT_PACKAGE" ]]; then
        packages+=("$TOMCAT_PACKAGE")
      else
        echo "APP_RUNTIME=tomcat selected, but TOMCAT_PACKAGE is not configured for this platform. Install Tomcat manually." >&2
      fi
      ;;
    *) echo "Unsupported APP_RUNTIME: ${APP_RUNTIME:-node}. Use node or tomcat." >&2; exit 1 ;;
  esac
}

if [[ "$PLATFORM_FAMILY" == "debian" ]]; then
  apt-get update
  packages=(curl ca-certificates)
  add_reverse_proxy_package
  add_runtime_package
  apt-get install -y "${packages[@]}"
elif [[ "$PLATFORM_FAMILY" == "rhel" ]]; then
  packages=(curl ca-certificates)
  add_reverse_proxy_package
  add_runtime_package
  if command -v dnf >/dev/null 2>&1; then dnf install -y "${packages[@]}"; else yum install -y "${packages[@]}"; fi
elif [[ "$PLATFORM_FAMILY" == "alpine" ]]; then
  packages=(curl ca-certificates)
  add_reverse_proxy_package
  add_runtime_package
  apk add --no-cache "${packages[@]}"
elif [[ "$PLATFORM_FAMILY" == "freebsd" ]]; then
  packages=(curl ca_root_nss)
  add_reverse_proxy_package
  add_runtime_package
  pkg install -y "${packages[@]}"
elif [[ "$PLATFORM_FAMILY" == "openbsd" ]]; then
  packages=(curl ca-certificates)
  add_reverse_proxy_package
  add_runtime_package
  pkg_add "${packages[@]}"
elif [[ "$PLATFORM_FAMILY" == "netbsd" ]]; then
  packages=(curl mozilla-rootcerts)
  add_reverse_proxy_package
  add_runtime_package
  if command -v pkgin >/dev/null 2>&1; then
    pkgin -y install "${packages[@]}"
  else
    echo "pkgin was not found. Install packages manually: ${packages[*]}" >&2
  fi
elif [[ "$PLATFORM_FAMILY" == "macos" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew was not found. Install packages manually for macOS: curl ca-certificates ${REVERSE_PROXY} ${TOMCAT_PACKAGE}" >&2
  else
    packages=(curl ca-certificates)
    add_reverse_proxy_package
    add_runtime_package
    brew install "${packages[@]}"
  fi
else
  echo "Unsupported/unknown OS family. Install curl, CA certificates, ${REVERSE_PROXY}, Tomcat if needed, and Node.js manually." >&2
fi
if [[ "$APP_RUNTIME_NORMALIZED" == "tomcat" || "$APP_RUNTIME_NORMALIZED" == "apache-tomcat" ]]; then
  echo "Dependency bootstrap finished. Confirm Tomcat uses your company-approved Java runtime."
else
  echo "Dependency bootstrap finished. Install Node.js using your company-approved source or package repository."
fi
