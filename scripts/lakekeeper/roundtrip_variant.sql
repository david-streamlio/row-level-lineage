-- after channel (initial-default 'web', write-default 'mobile') exists
ALTER TABLE __C__.rt.customers ADD COLUMN raw_payload VARIANT;
INSERT INTO __C__.rt.customers (customer_id, total_amount, last_event_id, updated_ts, channel, raw_payload)
VALUES (5, 50.00, 'e7', TIMESTAMP '2026-01-05 00:00:00', DEFAULT, parse_json('{"utm_source":"newsletter","clicks":3}'));
