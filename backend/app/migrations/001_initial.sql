CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    recovery_hash TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    name TEXT NOT NULL,
    platform TEXT NOT NULL DEFAULT 'ios',
    revoked_at TEXT,
    push_token TEXT,
    push_enabled INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS enrollments (
    code_hash TEXT PRIMARY KEY,
    expires_at TEXT NOT NULL,
    used_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id, revoked_at);
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    access_hash TEXT NOT NULL UNIQUE,
    refresh_hash TEXT NOT NULL UNIQUE,
    access_expires_at TEXT NOT NULL,
    refresh_expires_at TEXT NOT NULL,
    generation INTEGER NOT NULL,
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id, device_id);
CREATE TABLE IF NOT EXISTS bindings (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    local_user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(local_user_id, user_id)
);
CREATE TABLE IF NOT EXISTS entities (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id),
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    business_date TEXT NOT NULL,
    source_id TEXT,
    version INTEGER NOT NULL,
    deleted_at TEXT,
    updated_at TEXT NOT NULL,
    device_id TEXT NOT NULL,
    PRIMARY KEY(user_id, id)
);
CREATE INDEX IF NOT EXISTS idx_entities_date ON entities(user_id, kind, business_date, deleted_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_entities_source ON entities(user_id, kind, source_id) WHERE source_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS changes (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    version INTEGER NOT NULL,
    deleted_at TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_changes_user ON changes(user_id, sequence);
CREATE TABLE IF NOT EXISTS receipts (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    payload_hash TEXT NOT NULL,
    result TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(user_id, generation, id)
);
CREATE TABLE IF NOT EXISTS entity_ledger (
    user_id TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_change_id TEXT NOT NULL,
    PRIMARY KEY(user_id, generation, entity_id)
);
CREATE TABLE IF NOT EXISTS snapshots (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    epoch TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS snapshot_rows (
    snapshot_id TEXT NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
    entity_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY(snapshot_id, entity_id)
);
CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    meal_id TEXT NOT NULL,
    expected_size INTEGER NOT NULL,
    expected_hash TEXT NOT NULL,
    received_size INTEGER NOT NULL DEFAULT 0,
    temporary INTEGER NOT NULL DEFAULT 0,
    mime_type TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_media_user ON media(user_id, meal_id, status);
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    request_key TEXT NOT NULL,
    payload TEXT NOT NULL,
    result TEXT,
    error TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    lease_until TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(user_id, kind, request_key)
);
CREATE INDEX IF NOT EXISTS idx_tasks_pending ON tasks(status, kind, created_at);
CREATE TABLE IF NOT EXISTS pairs (
    id TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS challenges (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    pair_id TEXT REFERENCES pairs(id),
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    timezone TEXT NOT NULL,
    day_start_minutes INTEGER NOT NULL DEFAULT 0,
    start_at TEXT,
    end_at TEXT,
    duration_days INTEGER NOT NULL,
    max_members INTEGER NOT NULL,
    rules_version TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    paused_at TEXT,
    pause_periods TEXT NOT NULL DEFAULT '[]',
    finalized_at TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
    challenge_id TEXT NOT NULL REFERENCES challenges(id),
    user_id TEXT NOT NULL REFERENCES users(id),
    status TEXT NOT NULL,
    confirmed INTEGER NOT NULL DEFAULT 0,
    resume_confirmed INTEGER NOT NULL DEFAULT 0,
    goal TEXT NOT NULL,
    baseline TEXT,
    joined_at TEXT NOT NULL,
    PRIMARY KEY(challenge_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_members_user ON members(user_id, status);
CREATE TABLE IF NOT EXISTS active_members (
    user_id TEXT PRIMARY KEY,
    challenge_id TEXT NOT NULL REFERENCES challenges(id)
);
CREATE TABLE IF NOT EXISTS invites (
    id TEXT PRIMARY KEY,
    challenge_id TEXT NOT NULL REFERENCES challenges(id),
    code_hash TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    used_by TEXT,
    revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS consents (
    challenge_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    recipient_id TEXT NOT NULL,
    scopes TEXT NOT NULL,
    history_from TEXT NOT NULL,
    version INTEGER NOT NULL,
    revoked_at TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(challenge_id, owner_id, recipient_id)
);
CREATE INDEX IF NOT EXISTS idx_consents_recipient ON consents(recipient_id, challenge_id, revoked_at);
CREATE TABLE IF NOT EXISTS scores (
    challenge_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    business_date TEXT NOT NULL,
    payload TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(challenge_id, user_id, business_date)
);
CREATE TABLE IF NOT EXISTS score_events (
    id TEXT PRIMARY KEY,
    challenge_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    business_date TEXT NOT NULL,
    before_value TEXT NOT NULL,
    after_value TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS encouragements (
    id TEXT PRIMARY KEY,
    challenge_id TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_encouragements_challenge ON encouragements(challenge_id, created_at);
CREATE TABLE IF NOT EXISTS audit (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    action TEXT NOT NULL,
    target_id TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_user ON audit(user_id, created_at);
CREATE TABLE IF NOT EXISTS deletion_ledger (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_id TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL
);
