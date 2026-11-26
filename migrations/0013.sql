-- A Dropbox entry whose path_lower part beneath the root, lower, is not
-- the fold canonical_path it has: it holds that key unsupported, and
-- path is the spelling the held key's record shows.
CREATE TABLE remote_mismatches (
    lower BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    path BLOB NOT NULL
) STRICT;

CREATE INDEX remote_mismatches_by_canonical_path
    ON remote_mismatches(canonical_path);

-- The remote record a held key had, hidden while it is held.
CREATE TABLE remote_shadows (
    canonical_path BLOB PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    kind INTEGER NOT NULL,
    content TEXT,
    revision TEXT,
    CHECK ((kind = 0 AND content IS NOT NULL AND revision IS NOT NULL)
        OR ((kind = 1 OR kind BETWEEN 3 AND 8)
            AND content IS NULL AND revision IS NULL))
) STRICT;

PRAGMA user_version = 13;
