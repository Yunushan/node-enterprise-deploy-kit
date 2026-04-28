# Architecture

## Recommended Topology

```text
Internet / LAN users
        |
        v
TLS reverse proxy
IIS on Windows or Nginx/Apache on Linux
        |
        v
http://127.0.0.1:<app_port>
        |
        v
Node.js app as managed service
WinSW on Windows or systemd/System V/OpenRC on Linux
        |
        v
rotated logs + health check + monitoring
```

## Why not manual Node.js startup?

Manual process startup is not enterprise-grade because it is tied to an interactive session and usually has no reliable restart, logging, startup, or recovery policy.

## Windows Service Design

Recommended Windows components:

- WinSW as service wrapper.
- Windows Service Control Manager recovery policy.
- IIS as TLS/reverse proxy frontend.
- Scheduled Task health check.
- Logs under `C:\logs\<AppName>`.
- Service wrapper under `C:\services\<AppName>`.

## Linux Service Design

Recommended Linux components:

- systemd, System V, or OpenRC service.
- Nginx or Apache as TLS/reverse proxy frontend.
- systemd timer health check on systemd hosts.
- Cron or external monitoring for health checks on System V/OpenRC hosts.
- Logs under `/var/log/<app-name>`.
- App under `/opt/<app-name>`.

## HA Extension

For multi-node deployments, place a load balancer in front of two or more identical app nodes:

```text
Load Balancer
  |---- app-node-1
  |---- app-node-2
  |---- app-node-3
```

Each app node still uses this project locally. HA orchestration is external to this kit.
