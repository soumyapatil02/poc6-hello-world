const express = require('express');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.json({
    message: 'Hello World from Soumya',
    hostname: os.hostname(),
    version: process.env.APP_VERSION || '1.0.0',
    timestamp: new Date().toISOString(),
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

app.get('/metrics', (req, res) => {
  res.set('Content-Type', 'text/plain');
  res.send(
    `# HELP http_requests_total Total HTTP requests\n` +
    `# TYPE http_requests_total counter\n` +
    `http_requests_total{method="GET",path="/"} 1\n`
  );
});

const server = app.listen(PORT, () => {
  console.log(`Hello World app running on port ${PORT}`);
});

module.exports = { app, server };
