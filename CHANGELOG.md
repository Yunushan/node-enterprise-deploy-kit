# Changelog

## Unreleased

- Hardened WinSW service environment defaults and Windows service account handling.
- Hardened IIS reverse proxy rendering with ARR proxy setup, forwarded headers, health proxy path, WebSocket checks, and timeout validation.
- Improved Windows status and diagnostics with host uptime, service uptime thresholds, port ownership proof, health latency, health-check freshness, and operational verdicts.
- Added Windows managed-backup listing and rollback helpers for WinSW files, IIS web.config, and scheduled health-check task exports.
- Added release package hygiene checks, sanitized release zip builder, deterministic Ansible syntax settings, CI Ansible tooling setup, and Ansible collection requirements.
- Added Windows and Linux preflight hardening warnings for public bind addresses, plaintext proxy paths, broad service accounts, user-profile runtime paths, and secret-like runtime key names.
- Added documentation consistency checks for local Markdown links, README anchors, and documented release entrypoints.
- Added Linux Apache reverse proxy installer and virtual host template.
- Added HAProxy and Traefik reverse proxy installers and templates.
- Added Apache Tomcat WAR deployment mode.
- Added Linux System V and OpenRC service templates.
- Added launchd and BSD rc service templates for macOS and BSD targets.
- Added Linux service manager selection for scripts and Ansible.
- Expanded Unix-like support notes for Oracle Linux, CentOS, CentOS Stream, Fedora, Linux Mint, FreeBSD, OpenBSD, NetBSD, and macOS.
- Hardened Linux health-check state handling with a root-owned state directory and non-executable state parsing.
- Made Linux diagnostics summary-only by default with explicit raw-detail opt-in.
- Added a Turkish companion README while keeping the English README as the default project entry point.
- Made Linux reverse proxy templates use explicit forwarded scheme/port variables for upstream TLS truthfulness.
- Added a safety opt-in before replacing an existing main HAProxy config.
- Centralized Linux config loading and aligned runtime environment key parsing across preflight and install flows.
- Added Traefik dynamic config validation through a temporary file-provider config.
- Expanded CI with a Windows verification job and optional ShellCheck step.
- Hardened Ansible sample config defaults by keeping SSH host key checking enabled.
- Clarified that Windows reverse proxy automation supports IIS or none, while Apache, HAProxy, and Traefik installers are Linux/Unix helpers.
- Added safe application package import before deployment: `.zip` on Windows and `.zip`, `.tar.gz`, `.tgz`, or `.tar` on Linux/Unix.

## v1.0.0

Initial GitHub-ready release.

- Windows WinSW service deployment.
- Windows IIS reverse proxy template.
- Windows scheduled health check.
- Linux systemd service deployment.
- Linux Nginx reverse proxy template.
- Linux systemd timer health check.
- Diagnostics and redaction scripts.
- Optional Ansible roles.
- MIT license.
