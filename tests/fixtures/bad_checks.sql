-- Deliberately broken checks.sql: tests/check_sql.sh must reject every query here.
-- @query reads_data
SELECT 'reads_data' AS check_id, count() FROM default.payments;
-- @query table_function
SELECT 'table_function', * FROM url('http://example.com/x.csv', CSV);
-- @query with_settings
SELECT 'with_settings', 1 FROM system.one SETTINGS readonly = 0;
-- @query changes_things
TRUNCATE TABLE system.query_log;
-- @query wrong_id
SELECT 'not_the_id', 1 FROM system.one;
-- @query two_statements
SELECT 'two_statements' FROM system.one; SELECT 1 FROM system.one;
-- @query joins_data
SELECT 'joins_data' FROM system.parts AS p JOIN customer.orders AS o ON 1 = 1;
-- @query _target
SELECT '_target' AS check_id FROM system.disks;
