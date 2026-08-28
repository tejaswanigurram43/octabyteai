'use strict';

const client = require('prom-client');

// Register default Node.js metrics (GC, event loop, heap, etc.)
client.collectDefaultMetrics({ prefix: 'nodejs_' });

const httpRequestsTotal = new client.Counter({
  name: 'request_count',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status'],
});

const httpRequestDuration = new client.Histogram({
  name: 'request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
});

const httpErrorsTotal = new client.Counter({
  name: 'error_count',
  help: 'Total number of HTTP errors (4xx + 5xx)',
  labelNames: ['method', 'route', 'status'],
});

function metricsMiddleware(req, res, next) {
  const excluded = ['/health', '/metrics'];
  if (excluded.includes(req.path)) return next();

  const end = httpRequestDuration.startTimer();

  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : req.path;
    const labels = { method: req.method, route, status: res.statusCode };

    httpRequestsTotal.inc(labels);
    end(labels);

    if (res.statusCode >= 400) {
      httpErrorsTotal.inc(labels);
    }
  });

  next();
}

module.exports = metricsMiddleware;
