CREATE TABLE share_grants (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id),
    recipient_id TEXT NOT NULL REFERENCES users(id),
    scopes TEXT NOT NULL,
    from_day TEXT NOT NULL,
    through_day TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    version INTEGER NOT NULL,
    revoked_at TEXT,
    CHECK (owner_id <> recipient_id)
);
CREATE INDEX idx_share_grants_owner ON share_grants(owner_id, id);
CREATE INDEX idx_share_grants_recipient ON share_grants(recipient_id, id);
