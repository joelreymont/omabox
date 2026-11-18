-- Local observations carry their canonical path; the program copies each
-- version-eight row with its path folded, then drops the old table. Also
-- drops the unused remote_directories index.
ALTER TABLE local_observations RENAME TO local_observations_8;

CREATE TABLE local_observations (
    path BLOB PRIMARY KEY NOT NULL,
    observation_json TEXT NOT NULL,
    canonical_path BLOB NOT NULL
) STRICT;

CREATE INDEX local_observations_by_canonical_path
    ON local_observations(canonical_path, path);

DROP INDEX remote_directories;
