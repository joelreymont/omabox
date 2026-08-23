CREATE TABLE baselines (
    path BLOB PRIMARY KEY NOT NULL,
    baseline_json TEXT NOT NULL
) STRICT;

CREATE TABLE local_observations (
    path BLOB PRIMARY KEY NOT NULL,
    observation_json TEXT NOT NULL
) STRICT;

CREATE TABLE remote_observations (
    path BLOB PRIMARY KEY NOT NULL,
    observation_json TEXT NOT NULL
) STRICT;

CREATE TABLE remote_inventory (
    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
    cursor TEXT NOT NULL
) STRICT;

CREATE TABLE plans (
    id INTEGER PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed'))
) STRICT;

CREATE UNIQUE INDEX one_pending_plan_per_path
    ON plans(path) WHERE status = 'pending';

CREATE TABLE operations (
    id INTEGER PRIMARY KEY NOT NULL,
    plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    operation_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')),
    UNIQUE (plan_id, ordinal)
) STRICT;

CREATE INDEX operations_by_plan
    ON operations(plan_id, ordinal);

CREATE TABLE conflicts (
    id INTEGER PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    conflict_json TEXT NOT NULL
) STRICT;

CREATE TABLE recovery_records (
    id INTEGER PRIMARY KEY NOT NULL,
    operation_id INTEGER NOT NULL UNIQUE
        REFERENCES operations(id) ON DELETE RESTRICT,
    original_path BLOB NOT NULL,
    recovery_path BLOB NOT NULL,
    content_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed'))
) STRICT;

PRAGMA user_version = 1;
