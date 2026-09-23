-- Problems for tests/run.sh to find. Runs as the default (admin) user of a
-- throw-away test container.

-- A customer's own database with a sensitive name: visible in the local report,
-- hashed in --print-payload.
CREATE DATABASE IF NOT EXISTS customer_acme;

-- Check 7: lightweight DELETE of 20% of the rows.
CREATE TABLE customer_acme.payments_eu (id UInt64, ts DateTime64(3), amount Decimal(18, 2), email String)
ENGINE = MergeTree PARTITION BY toYYYYMM(ts) ORDER BY id;
INSERT INTO customer_acme.payments_eu
SELECT number, now64(3) - number, number / 100, concat('user', toString(number), '@example.com') FROM numbers(200000);
DELETE FROM customer_acme.payments_eu WHERE id % 5 = 0;

-- Check 5: merges stopped, 310 parts in one partition (the inserts come from run.sh).
CREATE TABLE customer_acme.events_eu (id UInt64, d Date DEFAULT today())
ENGINE = MergeTree PARTITION BY d ORDER BY id;
SYSTEM STOP MERGES customer_acme.events_eu;

-- Check 5, CRITICAL: a table whose own parts_to_delay_insert is low.
CREATE TABLE customer_acme.hot_eu (id UInt64)
ENGINE = MergeTree ORDER BY id SETTINGS parts_to_delay_insert = 20, parts_to_throw_insert = 1000;
SYSTEM STOP MERGES customer_acme.hot_eu;

-- Check 7, CRITICAL: a mutation that fails on every attempt.
CREATE TABLE customer_acme.broken_mut (id UInt64, v UInt64) ENGINE = MergeTree ORDER BY id;
INSERT INTO customer_acme.broken_mut SELECT number, number FROM numbers(1000);
ALTER TABLE customer_acme.broken_mut UPDATE v = throwIf(v >= 0, 'test: this mutation always fails') WHERE 1;

-- Check 6: a detached partition.
CREATE TABLE customer_acme.archive_eu (id UInt64, m UInt8) ENGINE = MergeTree PARTITION BY m ORDER BY id;
INSERT INTO customer_acme.archive_eu SELECT number, number % 2 FROM numbers(10000);
ALTER TABLE customer_acme.archive_eu DETACH PARTITION 1;

-- Langfuse-like tables: product detection, public names in the payload,
-- DateTime64 partition keys (plan, point 6).
CREATE TABLE default.traces (id String, timestamp DateTime64(3), project_id String)
ENGINE = ReplacingMergeTree PARTITION BY toYYYYMM(timestamp) ORDER BY (project_id, id);
CREATE TABLE default.observations (id String, start_time DateTime64(3), project_id String)
ENGINE = ReplacingMergeTree PARTITION BY toYYYYMM(start_time) ORDER BY (project_id, id);
CREATE TABLE default.scores (id String, timestamp DateTime64(3), project_id String)
ENGINE = ReplacingMergeTree PARTITION BY toYYYYMM(timestamp) ORDER BY (project_id, id);
INSERT INTO default.observations SELECT toString(number), now64(3) - number, 'p1' FROM numbers(50000);
INSERT INTO default.scores SELECT toString(number), now64(3) - number, 'p1' FROM numbers(1000);
-- Langfuse deletes with lightweight DELETE FROM (plan, point 5).
DELETE FROM default.observations WHERE toUInt64(id) % 10 = 0;
