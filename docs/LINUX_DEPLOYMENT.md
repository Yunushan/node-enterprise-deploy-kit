# Linux Deployment

## Supported Linux Families

- Ubuntu
- Debian
- RHEL
- Fedora
- AlmaLinux
- Rocky Linux
- Alpine/OpenRC-style hosts

## Recommended Production Pattern

```text
Nginx or Apache HTTPS frontend -> 127.0.0.1:3000 -> Linux service -> Node.js app
```

Supported Linux service managers:

- `systemd`
- `systemv`
- `openrc`

Supported Linux reverse proxies:

- `nginx`
- `apache`
- `none`

## Steps

1. Copy config:

```bash
cp config/linux/app.env.example config/linux/app.env
```

2. Edit variables:

```bash
nano config/linux/app.env
```

3. Select service manager and reverse proxy:

```bash
SERVICE_MANAGER="systemd"   # systemd, systemv, or openrc
REVERSE_PROXY="nginx"       # nginx, apache, or none
```

4. Optional dependency bootstrap:

```bash
sudo bash scripts/linux/install-dependencies.sh config/linux/app.env
```

5. Install the Linux service:

```bash
sudo bash scripts/linux/install-node-service.sh config/linux/app.env
```

6. Optional Nginx reverse proxy:

```bash
sudo bash scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
```

7. Optional Apache reverse proxy:

```bash
sudo bash scripts/linux/install-apache-reverse-proxy.sh config/linux/app.env
```

On Debian-family hosts, the Apache installer enables `proxy`, `proxy_http`, `proxy_wstunnel`, `headers`, and `rewrite`.

8. Optional systemd health check timer:

```bash
sudo bash scripts/linux/install-healthcheck-timer.sh config/linux/app.env
```

For `systemv` and `openrc`, use `scripts/linux/node-healthcheck.sh` from cron or your external monitoring platform.

9. Verify:

```bash
ss -ltnp | grep :3000
curl -fsS http://127.0.0.1:3000/health
```

Service status examples:

```bash
systemctl status example-node-app
service example-node-app status
rc-service example-node-app status
```
