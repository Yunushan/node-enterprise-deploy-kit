const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok', uptime: process.uptime() });
});

app.get('/', (req, res) => {
  res.send('Example app is running');
});

app.listen(port, '127.0.0.1', () => {
  console.log(`Example app listening on http://127.0.0.1:${port}`);
});
