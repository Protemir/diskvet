-- Queries that try to hide a read of product data (or of query texts) from
-- tests/check_sql.sh. Each one must be reported by name: tests/replay.sh
-- checks that every "-- @query" id below appears in a FAIL line.
-- @query comment_in_string
SELECT 'comment_in_string', '--' AS x, (SELECT count() FROM customer.orders) AS n FROM system.disks;
-- @query escaped_quote
SELECT 'escaped_quote', 'a\'' AS x, (SELECT count() FROM customer.orders) AS n, 'z' FROM system.disks;
-- @query comma_join
SELECT 'comma_join', count() FROM system.parts AS p, customer.orders AS o;
-- @query comma_join_subquery
SELECT 'comma_join_subquery', count() FROM (SELECT 1 FROM system.parts) AS p, customer.orders;
-- @query in_table
SELECT 'in_table', count() FROM system.parts WHERE name IN customer.orders;
-- @query dict_get
SELECT 'dict_get', dictGet('customer.users_dict', 'email', toUInt64(1)) FROM system.disks;
-- @query join_get
SELECT 'join_get', joinGet('customer.orders_join', 'email', 1) FROM system.disks;
-- @query heredoc
SELECT 'heredoc', $$'$$ AS a, (SELECT count() FROM customer.orders) AS b, 'c' FROM system.disks;
-- @query hash_comment
SELECT 'hash_comment' # it's a comment for ClickHouse
    , (SELECT count() FROM customer.orders) AS n, 'x' FROM system.disks;
-- @query quoted_identifier
SELECT 'quoted_identifier', count() FROM "customer"."orders";
-- @query query_parameter
SELECT 'query_parameter', count() FROM {t:Identifier};
-- @query query_texts
SELECT 'query_texts', query FROM system.query_log;
-- @query host_names
SELECT 'host_names', host_name FROM system.clusters;
-- @query identity
SELECT 'identity', hostName(), currentUser() FROM system.disks;
