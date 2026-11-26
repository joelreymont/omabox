-- A new conflict whose copy name or staging slot another entry holds: its
-- path, the reason as MODEL's blockage JSON, and retry_at, seconds since
-- the epoch, before which a pass neither stages nor hashes the path.
CREATE TABLE conflict_blocks (
    canonical_path BLOB PRIMARY KEY NOT NULL,
    path BLOB NOT NULL,
    blocked_json TEXT NOT NULL,
    retry_at INTEGER NOT NULL CHECK (retry_at >= 0)
) STRICT;

PRAGMA user_version = 12;
