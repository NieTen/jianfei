ALTER TABLE users ADD COLUMN email TEXT;
ALTER TABLE users ADD COLUMN email_verified_at TEXT;
CREATE UNIQUE INDEX idx_users_email ON users(email) WHERE email IS NOT NULL;
ALTER TABLE sessions ADD COLUMN family_id TEXT;
ALTER TABLE sessions ADD COLUMN parent_id TEXT;
ALTER TABLE sessions ADD COLUMN revoked_reason TEXT;
UPDATE sessions SET family_id = id WHERE family_id IS NULL;
CREATE INDEX idx_sessions_family ON sessions(family_id, revoked_at);
CREATE TABLE email_challenges (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    email TEXT NOT NULL,
    purpose TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_email_challenges_lookup ON email_challenges(email, purpose, created_at);
CREATE TABLE email_deliveries (
    id TEXT PRIMARY KEY,
    challenge_id TEXT NOT NULL REFERENCES email_challenges(id) ON DELETE CASCADE,
    encrypted_payload TEXT NOT NULL,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    retry_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX idx_email_deliveries_pending ON email_deliveries(status, retry_at);
CREATE TABLE auth_rate_limits (
    id TEXT PRIMARY KEY,
    attempts INTEGER NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE TABLE entitlement_grants (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    entitlement_key TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    valid_until TEXT NOT NULL,
    source TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    revoked_at TEXT,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(source, source_ref)
);
CREATE INDEX idx_entitlement_user ON entitlement_grants(user_id, entitlement_key, revoked_at, valid_until);
CREATE TABLE entitlement_events (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    grant_id TEXT NOT NULL,
    action TEXT NOT NULL,
    operator TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE cloud_ai_provider (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    encrypted_key TEXT NOT NULL,
    models TEXT NOT NULL,
    external INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1,
    max_output_tokens INTEGER NOT NULL DEFAULT 4096,
    revision INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE cloud_ai_preferences (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    model_id TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE cloud_ai_consents (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    allowed INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 0,
    provider_revision INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
CREATE TABLE ai_usage (
    task_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    request_key TEXT NOT NULL,
    usage_day TEXT NOT NULL,
    status TEXT NOT NULL,
    provider_calls INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(user_id, request_key)
);
CREATE INDEX idx_ai_usage_day ON ai_usage(user_id, usage_day, status);
ALTER TABLE media ADD COLUMN consent_revision INTEGER;
ALTER TABLE media ADD COLUMN provider_revision INTEGER;
