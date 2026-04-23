const express = require('express');

const app = express();
const port = process.env.PORT || 3000;
const appName = process.env.APP_NAME || 'k8s-simple-app';
const appEnv = process.env.APP_ENV || 'development';

app.use(express.json());

let ready = false;
setTimeout(() => { ready = true; }, 3000);

app.get('/', (req, res) => {
  res.json({
    message: `Hello from ${appName}`,
    env: appEnv,
    hostname: require('os').hostname(),
  });
});

app.get('/api/items', (req, res) => {
  res.json({
    items: [
      { id: 1, name: 'item-one' },
      { id: 2, name: 'item-two' },
    ],
  });
});

app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/readyz', (req, res) => {
  if (!ready) return res.status(503).json({ status: 'starting' });
  res.status(200).json({ status: 'ready' });
});

const server = app.listen(port, () => {
  console.log(`${appName} listening on port ${port} (${appEnv})`);
});

const shutdown = (signal) => {
  console.log(`Received ${signal}, shutting down`);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
