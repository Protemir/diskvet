-- Variant B from the README: a dedicated read-only user with narrow grants.
-- Runs as an admin user. The password is replaced by tests/run.sh.
CREATE SETTINGS PROFILE IF NOT EXISTS diskvet_profile SETTINGS
    readonly = 1, max_execution_time = 30, max_result_rows = 10000,
    result_overflow_mode = 'break', max_threads = 2, max_memory_usage = 500000000;

CREATE USER IF NOT EXISTS diskvet
    IDENTIFIED WITH sha256_password BY '__PASSWORD__'
    HOST LOCAL
    SETTINGS PROFILE 'diskvet_profile';

GRANT SHOW TABLES ON *.* TO diskvet;
GRANT SELECT ON system.parts TO diskvet;
GRANT SELECT ON system.disks TO diskvet;
GRANT SELECT ON system.merge_tree_settings TO diskvet;
GRANT SELECT ON system.mutations TO diskvet;
GRANT SELECT ON system.detached_parts TO diskvet;
GRANT SELECT ON system.part_log TO diskvet;
GRANT SELECT ON system.asynchronous_metric_log TO diskvet;
GRANT SELECT ON system.asynchronous_metrics TO diskvet;
GRANT SELECT ON system.events TO diskvet;
