CREATE TABLE IF NOT EXISTS notification_sends (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tg_user_id BIGINT NOT NULL,
    notification_type VARCHAR(64) NOT NULL,
    scope_key VARCHAR(255) NOT NULL,
    client_name VARCHAR(128),
    sent_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_sends_scope
    ON notification_sends (tg_user_id, notification_type, scope_key);

CREATE INDEX IF NOT EXISTS idx_notification_sends_type_sent_at
    ON notification_sends (tg_user_id, notification_type, sent_at);
