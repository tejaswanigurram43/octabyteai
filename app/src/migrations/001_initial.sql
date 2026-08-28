-- Initial database schema
-- Migration: 001_initial.sql

BEGIN;

-- ── Users table ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_idx
    ON users (LOWER(email));

-- ── Updated-at trigger ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Audit log table ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id         BIGSERIAL    PRIMARY KEY,
    table_name VARCHAR(64)  NOT NULL,
    operation  VARCHAR(10)  NOT NULL,
    record_id  INTEGER,
    old_data   JSONB,
    new_data   JSONB,
    changed_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    changed_by VARCHAR(100)
);

CREATE INDEX IF NOT EXISTS audit_log_table_record_idx
    ON audit_log (table_name, record_id);

CREATE INDEX IF NOT EXISTS audit_log_changed_at_idx
    ON audit_log (changed_at DESC);

-- ── Audit trigger for users ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION audit_users()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, old_data, new_data)
    VALUES (
        'users',
        TG_OP,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP = 'DELETE'  THEN row_to_json(OLD)::JSONB END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW)::JSONB END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_users_audit ON users;
CREATE TRIGGER trg_users_audit
    AFTER INSERT OR UPDATE OR DELETE ON users
    FOR EACH ROW EXECUTE FUNCTION audit_users();

-- ── Schema migrations tracking ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    VARCHAR(64)  PRIMARY KEY,
    applied_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO schema_migrations (version) VALUES ('001_initial')
    ON CONFLICT DO NOTHING;

COMMIT;
