// ════════════════════════════════════════════════════════════════
// HuggingMes — Health Server
// ════════════════════════════════════════════════════════════════

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 9080;
const HERMES_HOME = process.env.HERMES_HOME || '/opt/data';

// ── Health endpoint ──
async function handleHealth(req, res) {
  // Check gateway
  let gwStatus = 'unknown';
  try {
    const gwPidFile = path.join(HERMES_HOME, 'gateway.pid');
    if (fs.existsSync(gwPidFile)) {
      const pid = fs.readFileSync(gwPidFile, 'utf-8').trim();
      gwStatus = fs.existsSync(`/proc/${pid}`) ? 'running' : 'stopped';
    } else {
      gwStatus = 'not-started';
    }
  } catch { gwStatus = 'error'; }

  // Check dashboard
  let dbStatus = 'unknown';
  try {
    const dbPidFile = path.join(HERMES_HOME, 'dashboard.pid');
    if (fs.existsSync(dbPidFile)) {
      const pid = fs.readFileSync(dbPidFile, 'utf-8').trim();
      dbStatus = fs.existsSync(`/proc/${pid}`) ? 'running' : 'stopped';
    } else {
      dbStatus = 'not-started';
    }
  } catch { dbStatus = 'error'; }

  // Uptime
  let uptime = 'unknown';
  try {
    uptime = fs.readFileSync('/proc/uptime', 'utf-8').trim().split(' ')[0];
    uptime = `${parseFloat(uptime).toFixed(0)}s`;
  } catch {}

  const allOk = gwStatus === 'running' && dbStatus === 'running';
  const statusCode = allOk ? 200 : 503;

  const data = {
    status: allOk ? 'healthy' : 'degraded',
    timestamp: new Date().toISOString(),
    uptime,
    services: { gateway: gwStatus, dashboard: dbStatus },
  };

  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(JSON.stringify(data, null, 2));
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') return handleHealth(req, res);
  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[health] Server on http://0.0.0.0:${PORT}`);
});
