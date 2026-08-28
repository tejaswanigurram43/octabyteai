'use strict';

const express = require('express');
const Joi = require('joi');
const { query } = require('../db');

const router = express.Router();

const userSchema = Joi.object({
  name:  Joi.string().min(1).max(100).required(),
  email: Joi.string().email().required(),
});

// GET /api/users — paginated list
router.get('/', async (req, res, next) => {
  try {
    const page  = Math.max(1, parseInt(req.query.page  || '1',  10));
    const limit = Math.min(100, Math.max(1, parseInt(req.query.limit || '20', 10)));

    if (isNaN(page) || isNaN(limit)) {
      return res.status(400).json({ error: 'Invalid pagination parameters' });
    }

    const offset = (page - 1) * limit;
    const { rows: data }  = await query('SELECT id, name, email, created_at FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2', [limit, offset]);
    const { rows: [{ count }] } = await query('SELECT COUNT(*) FROM users', []);

    res.json({
      data,
      meta: { page, limit, total: parseInt(count, 10), pages: Math.ceil(count / limit) },
    });
  } catch (err) {
    next(err);
  }
});

// GET /api/users/:id
router.get('/:id', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (!id || id <= 0) return res.status(400).json({ error: 'Invalid user ID' });

    const { rows } = await query('SELECT id, name, email, created_at FROM users WHERE id = $1', [id]);
    if (!rows.length) return res.status(404).json({ error: 'User not found' });

    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

// POST /api/users
router.post('/', async (req, res, next) => {
  try {
    const { error, value } = userSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    // Explicit duplicate check
    const { rows: existing } = await query('SELECT id FROM users WHERE LOWER(email) = LOWER($1)', [value.email]);
    if (existing.length) return res.status(409).json({ error: 'Email already registered' });

    const { rows } = await query(
      'INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id, name, email, created_at',
      [value.name, value.email]
    );

    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') {
      return res.status(409).json({ error: 'Email already registered' });
    }
    next(err);
  }
});

module.exports = router;
