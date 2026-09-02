-- Version-six plan queries join their operations, so a legacy plan that never
-- recorded one is invisible while still holding its canonical path's live slot
-- forever. Complete it before the dedup, so it can neither be kept as the
-- lowest surviving identity nor outlive the paths it silently owns.
UPDATE plans SET status = 'completed'
WHERE status = 'pending'
  AND NOT EXISTS (
      SELECT 1 FROM operations WHERE operations.plan_id = plans.id
  );

-- Legacy version-three databases enforced one live plan per display path, so a
-- single canonical path can still own several. Retire every live plan except
-- the lowest identity for its canonical path with supersede semantics: the
-- operations and the plan complete without advancing a baseline, so the
-- reconciler re-plans the path from fresh observations.
CREATE TABLE superseded_plans_v6 (id INTEGER PRIMARY KEY NOT NULL) STRICT;

INSERT INTO superseded_plans_v6(id)
SELECT id FROM plans
WHERE status = 'pending'
  AND id > (
      SELECT MIN(live.id) FROM plans AS live
      WHERE live.status = 'pending'
        AND live.canonical_path = plans.canonical_path
  );

UPDATE recovery_records SET retained_at = unixepoch()
WHERE status = 'completed'
  AND retained_at IS NULL
  AND operation_id IN (
      SELECT id FROM operations
      WHERE plan_id IN (SELECT id FROM superseded_plans_v6)
  );

UPDATE operations SET status = 'completed'
WHERE plan_id IN (SELECT id FROM superseded_plans_v6);

UPDATE plans SET status = 'completed'
WHERE id IN (SELECT id FROM superseded_plans_v6);

DROP TABLE superseded_plans_v6;

-- An ambiguous canonical identity cannot be resolved without a fresh
-- observation, so both claims are discarded exactly as version four does.
DELETE FROM baselines WHERE canonical_path IN (
    SELECT canonical_path FROM baselines
    GROUP BY canonical_path HAVING COUNT(*) > 1
);

CREATE TABLE discarded_remote_v6 (canonical_path BLOB PRIMARY KEY NOT NULL) STRICT;

INSERT INTO discarded_remote_v6(canonical_path)
SELECT canonical_path FROM remote_observations
GROUP BY canonical_path HAVING COUNT(*) > 1;

DELETE FROM remote_observations
WHERE canonical_path IN (SELECT canonical_path FROM discarded_remote_v6);

-- A delta cursor only reports what changes after it, so a discarded row would
-- never be redelivered and the reconciler would read the path as confirmed
-- absent. Retire the cursor with the rows, exactly as versions four and five
-- do, and the next refresh republishes a complete inventory.
DELETE FROM remote_inventory WHERE EXISTS (SELECT 1 FROM discarded_remote_v6);

DROP TABLE discarded_remote_v6;

CREATE TABLE baselines_v6 (
    path BLOB PRIMARY KEY NOT NULL,
    baseline_json TEXT NOT NULL,
    canonical_path BLOB NOT NULL
) STRICT;

INSERT INTO baselines_v6(path, baseline_json, canonical_path)
SELECT path, baseline_json, canonical_path FROM baselines;

DROP TABLE baselines;
ALTER TABLE baselines_v6 RENAME TO baselines;

CREATE UNIQUE INDEX baselines_by_canonical_path
    ON baselines(canonical_path);

CREATE TABLE remote_observations_v6 (
    path BLOB PRIMARY KEY NOT NULL,
    observation_json TEXT NOT NULL,
    canonical_path BLOB NOT NULL
) STRICT;

INSERT INTO remote_observations_v6(path, observation_json, canonical_path)
SELECT path, observation_json, canonical_path FROM remote_observations;

DROP TABLE remote_observations;
ALTER TABLE remote_observations_v6 RENAME TO remote_observations;

CREATE UNIQUE INDEX remote_observations_by_canonical_path
    ON remote_observations(canonical_path);

CREATE INDEX remote_directories
    ON remote_observations(canonical_path)
    WHERE observation_json = '"Directory"';

CREATE TABLE conflicts_v6 (
    id INTEGER PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    conflict_json TEXT NOT NULL,
    canonical_path BLOB NOT NULL
) STRICT;

INSERT INTO conflicts_v6(id, path, conflict_json, canonical_path)
SELECT id, path, conflict_json, canonical_path FROM conflicts;

DROP TABLE conflicts;
ALTER TABLE conflicts_v6 RENAME TO conflicts;

CREATE INDEX conflicts_by_canonical_path
    ON conflicts(canonical_path);

-- `operations.plan_id` restricts deletion of its parent and foreign keys are
-- enabled during migration, so both tables are rebuilt together: the new child
-- references the new parent, the old child is dropped before the old parent,
-- and every identity, ordinal, and status is carried across unchanged.
CREATE TABLE plans_v6 (
    id INTEGER PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    canonical_path BLOB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'blocked', 'completed')),
    blocked_json TEXT,
    retry_at INTEGER,
    CHECK ((status = 'blocked') = (blocked_json IS NOT NULL)),
    CHECK ((status = 'blocked') = (retry_at IS NOT NULL)),
    CHECK (retry_at IS NULL OR retry_at >= 0)
) STRICT;

INSERT INTO plans_v6(id, path, canonical_path, status)
SELECT id, path, canonical_path, status FROM plans;

CREATE TABLE operations_v6 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id INTEGER NOT NULL REFERENCES plans_v6(id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    operation_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed')),
    UNIQUE (plan_id, ordinal)
) STRICT;

INSERT INTO operations_v6(id, plan_id, ordinal, operation_json, status)
SELECT id, plan_id, ordinal, operation_json, status FROM operations;

DROP TABLE operations;
DROP TABLE plans;
ALTER TABLE plans_v6 RENAME TO plans;
ALTER TABLE operations_v6 RENAME TO operations;

CREATE UNIQUE INDEX one_live_plan_per_path
    ON plans(canonical_path) WHERE status IN ('pending', 'blocked');

CREATE INDEX plans_by_canonical_path
    ON plans(canonical_path);

CREATE INDEX operations_by_plan
    ON operations(plan_id, ordinal);
