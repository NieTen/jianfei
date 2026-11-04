CREATE TABLE IF NOT EXISTS ai_settings (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    base_url TEXT NOT NULL,
    model TEXT NOT NULL,
    encrypted_key TEXT NOT NULL,
    external INTEGER NOT NULL DEFAULT 1,
    structured_output INTEGER NOT NULL DEFAULT 1,
    max_output_tokens INTEGER NOT NULL DEFAULT 4096,
    version INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL
);
