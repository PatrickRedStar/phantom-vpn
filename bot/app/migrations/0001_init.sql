CREATE TABLE IF NOT EXISTS tg_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tg_user_id BIGINT NOT NULL UNIQUE,
    username VARCHAR(255),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id VARCHAR(36) PRIMARY KEY,
    tg_user_id BIGINT NOT NULL,
    client_name VARCHAR(128) NOT NULL UNIQUE,
    plan_days INTEGER NOT NULL,
    expires_at TIMESTAMP NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'active',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions (tg_user_id);

CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    telegram_charge_id VARCHAR(255) NOT NULL UNIQUE,
    provider_charge_id VARCHAR(255),
    invoice_payload TEXT NOT NULL,
    amount_xtr INTEGER NOT NULL,
    currency VARCHAR(16) NOT NULL DEFAULT 'XTR',
    status VARCHAR(32) NOT NULL DEFAULT 'succeeded',
    tg_user_id BIGINT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_payments_user ON payments (tg_user_id);

CREATE TABLE IF NOT EXISTS subscription_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_subscription_events_subscription ON subscription_events (subscription_id);

CREATE TABLE IF NOT EXISTS client_bindings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tg_user_id BIGINT NOT NULL,
    server_id VARCHAR(64) NOT NULL,
    client_name VARCHAR(128) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_client_bindings_user ON client_bindings (tg_user_id);
CREATE INDEX IF NOT EXISTS idx_client_bindings_server_client ON client_bindings (server_id, client_name);

