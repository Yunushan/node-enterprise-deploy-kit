# Health Checks

## Recommended Endpoint

Create a lightweight endpoint in your application:

```js
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    uptime: process.uptime(),
    timestamp: new Date().toISOString()
  });
});
```

For Next.js API route:

```js
export default function handler(req, res) {
  res.status(200).json({ status: 'ok' });
}
```

## Health Check Layers

| Layer | Purpose |
|---|---|
| Service status | Confirms service manager sees the app as running |
| Port check | Confirms process listens on expected port |
| HTTP check | Confirms app can actually respond |

## Windows

Scheduled task runs `scripts/windows/Invoke-NodeHealthCheck.ps1`.

## Linux

systemd timer runs `/usr/local/sbin/<app-name>-healthcheck.sh`.
