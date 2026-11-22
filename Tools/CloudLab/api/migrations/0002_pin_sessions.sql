ALTER TABLE users ADD COLUMN pin_hash TEXT;
ALTER TABLE sessions ADD COLUMN session_id TEXT;
ALTER TABLE sessions ADD COLUMN refresh_hash TEXT;
ALTER TABLE sessions ADD COLUMN refresh_expires_at INTEGER;
ALTER TABLE sessions ADD COLUMN previous_refresh_hash TEXT;
ALTER TABLE sessions ADD COLUMN rotation_id TEXT;
ALTER TABLE sessions ADD COLUMN rotated_at INTEGER;
CREATE UNIQUE INDEX sessions_refresh ON sessions(refresh_hash);
CREATE UNIQUE INDEX sessions_previous_refresh ON sessions(previous_refresh_hash);

CREATE TABLE auth_rate (
    scope TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL,
    count INTEGER NOT NULL
);
CREATE INDEX auth_rate_expiry ON auth_rate(expires_at);

CREATE TABLE access_requests (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('alta', 'restablecer')),
    requested_at INTEGER NOT NULL,
    UNIQUE (email, kind)
);

ALTER TABLE nodes ADD COLUMN rack_units INTEGER CHECK (rack_units IS NULL OR (kind = 2 AND rack_units IN (12, 24, 42)));
ALTER TABLE releases ADD COLUMN demo INTEGER NOT NULL DEFAULT 0 CHECK (demo IN (0, 1));
