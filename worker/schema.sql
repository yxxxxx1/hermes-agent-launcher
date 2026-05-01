-- Hermes Launcher Telemetry — D1 Schema
-- Created: 2026-05-01
-- Apply with: wrangler d1 execute hermes-telemetry --file=worker/schema.sql

CREATE TABLE IF NOT EXISTS events (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    event_name        TEXT    NOT NULL,
    anonymous_id      TEXT    NOT NULL,
    version           TEXT,
    os_version        TEXT,
    memory_category   TEXT,
    ip_hash           TEXT,
    client_timestamp  INTEGER,
    server_timestamp  INTEGER NOT NULL,
    properties        TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_name_time ON events(event_name, server_timestamp);
CREATE INDEX IF NOT EXISTS idx_events_user_time ON events(anonymous_id, server_timestamp);
CREATE INDEX IF NOT EXISTS idx_events_time      ON events(server_timestamp);
