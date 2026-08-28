'use strict';

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
const { query } = require('../db');

describe('GET /api/users', () => {
  it('returns paginated users', async () => {
    query
      .mockResolvedValueOnce({ rows: [{ id: 1, name: 'Alice', email: 'alice@test.com', created_at: new Date() }] })
      .mockResolvedValueOnce({ rows: [{ count: '1' }] });

    const res = await request(app).get('/api/users');
    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(1);
    expect(res.body.meta.total).toBe(1);
  });

  it('returns 400 for invalid page param', async () => {
    const res = await request(app).get('/api/users?page=abc');
    expect(res.status).toBe(400);
  });

  it('propagates DB errors as 500', async () => {
    query.mockRejectedValue(new Error('DB error'));
    const res = await request(app).get('/api/users');
    expect(res.status).toBe(500);
  });
});

describe('GET /api/users/:id', () => {
  it('returns user when found', async () => {
    const user = { id: 1, name: 'Alice', email: 'alice@test.com', created_at: new Date() };
    query.mockResolvedValue({ rows: [user] });

    const res = await request(app).get('/api/users/1');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(1);
  });

  it('returns 404 when user not found', async () => {
    query.mockResolvedValue({ rows: [] });
    const res = await request(app).get('/api/users/999');
    expect(res.status).toBe(404);
  });

  it('returns 400 for non-numeric ID', async () => {
    const res = await request(app).get('/api/users/abc');
    expect(res.status).toBe(400);
  });

  it('returns 400 for ID zero', async () => {
    const res = await request(app).get('/api/users/0');
    expect(res.status).toBe(400);
  });
});

describe('POST /api/users', () => {
  it('creates a user and returns 201', async () => {
    const newUser = { id: 2, name: 'Bob', email: 'bob@test.com', created_at: new Date() };
    query
      .mockResolvedValueOnce({ rows: [] })        // duplicate check
      .mockResolvedValueOnce({ rows: [newUser] }); // insert

    const res = await request(app)
      .post('/api/users')
      .send({ name: 'Bob', email: 'bob@test.com' });

    expect(res.status).toBe(201);
    expect(res.body.email).toBe('bob@test.com');
  });

  it('returns 400 when name is missing', async () => {
    const res = await request(app).post('/api/users').send({ email: 'x@test.com' });
    expect(res.status).toBe(400);
  });

  it('returns 400 for invalid email', async () => {
    const res = await request(app).post('/api/users').send({ name: 'Test', email: 'not-an-email' });
    expect(res.status).toBe(400);
  });

  it('returns 400 for empty body', async () => {
    const res = await request(app).post('/api/users').send({});
    expect(res.status).toBe(400);
  });

  it('returns 409 for duplicate email (explicit check)', async () => {
    query.mockResolvedValueOnce({ rows: [{ id: 1 }] }); // duplicate found
    const res = await request(app).post('/api/users').send({ name: 'Alice', email: 'alice@test.com' });
    expect(res.status).toBe(409);
  });

  it('returns 409 for pg unique violation (23505)', async () => {
    query
      .mockResolvedValueOnce({ rows: [] })
      .mockRejectedValueOnce(Object.assign(new Error('duplicate key'), { code: '23505' }));

    const res = await request(app).post('/api/users').send({ name: 'Alice', email: 'alice@test.com' });
    expect(res.status).toBe(409);
  });

  it('propagates unexpected DB errors as 500', async () => {
    query
      .mockResolvedValueOnce({ rows: [] })
      .mockRejectedValueOnce(new Error('Unexpected DB error'));

    const res = await request(app).post('/api/users').send({ name: 'Test', email: 'test@test.com' });
    expect(res.status).toBe(500);
  });
});
