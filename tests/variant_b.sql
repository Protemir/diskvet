-- Variant B from the README: a dedicated read-only user with narrow grants.
-- Runs as an admin user. The password is replaced by tests/run.sh.
CREATE SETTINGS PROFILE IF NOT EXISTS doctor_profile SETTINGS
    readonly = 1, max_execution_time = 30, max_result_rows = 10000,
    result_overflow_mode = 'break', max_threads = 2, max_memory_usage = 500000000;

CREATE USER IF NOT EXISTS doctor
    IDENTIFIED WITH sha256_password BY '__PASSWORD__'
    HOST LOCAL
    SETTINGS PROFILE 'doctor_profile';

GRANT SHOW TABLES ON *.* TO doctor;
GRANT SELECT ON system.parts TO doctor;
GRANT SELECT ON system.disks TO doctor;
GRANT SELECT ON system.merge_tree_settings TO doctor;
GRANT SELECT ON system.mutations TO doctor;
GRANT SELECT ON system.detached_parts TO doctor;
GRANT SELECT ON system.part_log TO doctor;
GRANT SELECT ON system.asynchronous_metric_log TO doctor;
GRANT SELECT ON system.asynchronous_metrics TO doctor;
GRANT SELECT ON system.events TO doctor;
