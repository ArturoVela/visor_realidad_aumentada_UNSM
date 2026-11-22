CREATE TABLE users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL CHECK (role IN ('admin', 'docente', 'estudiante')),
    access_hash TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
);

CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_expiry ON sessions(expires_at);

CREATE TABLE nodes (
    id TEXT PRIMARY KEY,
    parent_id TEXT REFERENCES nodes(id),
    kind INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 3),
    name TEXT NOT NULL,
    code TEXT UNIQUE,
    CHECK ((kind = 0 AND parent_id IS NULL) OR (kind > 0 AND parent_id IS NOT NULL)),
    CHECK ((kind = 3 AND code IS NOT NULL) OR (kind < 3 AND code IS NULL))
);
CREATE UNIQUE INDEX distinct_node ON nodes(COALESCE(parent_id, ''), name COLLATE NOCASE);

CREATE TABLE releases (
    node_id TEXT NOT NULL REFERENCES nodes(id),
    version INTEGER NOT NULL CHECK (version BETWEEN 1 AND 2147483647),
    published_at TEXT NOT NULL,
    author_id TEXT NOT NULL REFERENCES users(id),
    upload_id TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    device_id TEXT NOT NULL,
    object_prefix TEXT NOT NULL UNIQUE,
    PRIMARY KEY (node_id, version),
    UNIQUE (node_id, upload_id)
);
