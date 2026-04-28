# Linux Deployment

## Supported Linux Families

- Ubuntu
- Debian
- RHEL
- Fedora
- AlmaLinux
- Rocky Linux

## Recommended Production Pattern

```text
Nginx HTTPS frontend -> 127.0.0.1:3000 -> systemd service -> Node.js app
```

## Steps

1. Copy config:

```bash
cp config/linux/app.env.example config/linux/app.env
```

2. Edit variables:

```bash
nano config/linux/app.env
```

3. Install the systemd service:

```bash
sudo ./scripts/linux/install-node-service.sh config/linux/app.env
```

4. Optional Nginx reverse proxy:

```bash
sudo ./scripts/linux/install-nginx-reverse-proxy.sh config/linux/app.env
```

5. Optional health check timer:

```bash
sudo ./scripts/linux/install-healthcheck-timer.sh config/linux/app.env
```

6. Verify:

```bash
systemctl status example-node-app
ss -ltnp | grep :3000
curl -fsS http://127.0.0.1:3000/health
```
