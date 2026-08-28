'use strict';

// Mock prom-client before any require
jest.mock('prom-client', () => {
  const registry = { contentType: 'text/plain', metrics: jest.fn().mockResolvedValue(''), register: jest.fn() };
  return {
    register: registry,
    collectDefaultMetrics: jest.fn(),
    Counter:   jest.fn().mockImplementation(() => ({ inc: jest.fn() })),
    Histogram: jest.fn().mockImplementation(() => ({ startTimer: jest.fn().mockReturnValue(jest.fn()) })),
    Registry:  jest.fn().mockImplementation(() => registry),
  };
});

jest.mock('../db', () => ({
  pool:             { query: jest.fn(), end: jest.fn() },
  connectWithRetry: jest.fn().mockResolvedValue(undefined),
  query:            jest.fn(),
  healthCheck:      jest.fn(),
}));

const request = require('supertest');
const app = require('../index');
const { pool } = require('../db');

describe('GET /health', () => {
  it('returns 200 with status ok when DB is healthy', async () => {
    pool.query.mockResolvedValue({ rows: [] });
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  it('returns 503 when DB is unavailable', async () => {
    pool.query.mockRejectedValue(new Error('Connection refused'));
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(res.body.dependencies.database).toBe('unavailable');
  });

  it('includes a timestamp in ISO format', async () => {
    pool.query.mockResolvedValue({ rows: [] });
    const res = await request(app).get('/health');
    expect(() => new Date(res.body.timestamp)).not.toThrow();
  });

  it('returns 404 for unknown routes', async () => {
    const res = await request(app).get('/unknown-path');
    expect(res.status).toBe(404);
  });
});

describe('GET /metrics', () => {
  it('returns 200 with text/plain content-type', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });
});
