CREATE TABLE recovery_records_v2 (
    id INTEGER PRIMARY KEY NOT NULL,
    operation_id INTEGER NOT NULL UNIQUE,
    original_path BLOB NOT NULL,
    recovery_path BLOB NOT NULL,
    content_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')),
    retained_at INTEGER CHECK (
        retained_at IS NULL OR (status = 'completed' AND retained_at >= 0)
    )
) STRICT;

INSERT INTO recovery_records_v2(
    id,
    operation_id,
    original_path,
    recovery_path,
    content_json,
    status,
    retained_at
)
SELECT
    recovery_records.id,
    recovery_records.operation_id,
    recovery_records.original_path,
    recovery_records.recovery_path,
    recovery_records.content_json,
    recovery_records.status,
    CASE
        WHEN recovery_records.status = 'completed'
         AND operations.status = 'completed'
         AND plans.status = 'completed'
        THEN unixepoch()
        ELSE NULL
    END
FROM recovery_records
JOIN operations ON operations.id = recovery_records.operation_id
JOIN plans ON plans.id = operations.plan_id;

DROP TABLE recovery_records;
ALTER TABLE recovery_records_v2 RENAME TO recovery_records;

CREATE TABLE operations_v2 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    operation_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')),
    UNIQUE (plan_id, ordinal)
) STRICT;

INSERT INTO operations_v2(
    id,
    plan_id,
    ordinal,
    operation_json,
    status
)
SELECT
    id,
    plan_id,
    ordinal,
    operation_json,
    status
FROM operations;

DROP TABLE operations;
ALTER TABLE operations_v2 RENAME TO operations;

CREATE INDEX operations_by_plan
    ON operations(plan_id, ordinal);

CREATE TABLE local_root_binding (
    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
    canonical_path BLOB NOT NULL,
    device BLOB NOT NULL,
    inode BLOB NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 1)
) STRICT;

DELETE FROM baselines WHERE baseline_json = '"Absent"';

PRAGMA user_version = 2;
