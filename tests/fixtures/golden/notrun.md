diskvet 0.2.2 · ClickHouse unknown · detected: other
Nothing was changed. Nothing was sent anywhere. Rendered from saved query results (--replay).

| # | Check | Status |
|---|---|---|
| 1 | System logs without TTL | NOT_RUN |
| 2 | Disk space not in ClickHouse table parts | NOT_RUN |
| 3 | Disk usage and rough forecast | NOT_RUN |
| 4 | Growth per day | NOT_RUN |
| 5 | Too many parts | NOT_RUN |
| 6 | Inactive and detached parts | NOT_RUN |
| 7 | Deleted rows and stuck mutations | NOT_RUN |

Server passport could not be read: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

### How to run the fixes
Nothing below runs by itself: read each command, then run it yourself.
SQL goes into `clickhouse-client` as a user that may change tables (a read-only user can't). Shell commands run on the ClickHouse server.

## 1. System logs without TTL: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

## 2. Disk space not in ClickHouse table parts: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

## 3. Disk usage and rough forecast: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

## 4. Growth per day: NOT_RUN

Could not run: Code: 60. Table system.part_log does not exist. (UNKNOWN_TABLE)

## 5. Too many parts: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

## 6. Inactive and detached parts: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

## 7. Deleted rows and stuck mutations: NOT_RUN

Could not run: Code: 497. diskvet: Not enough privileges. (ACCESS_DENIED)

---
This is a snapshot. It can't tell when the disk will really run out, or whether your trace_log is normal for a ClickHouse of your size.
Want an email before the disk fills? Join early access (free beta): https://github.com/Protemir/diskvet#early-access
