CREATE TABLE local_hash_cache (
    root_generation INTEGER NOT NULL CHECK (root_generation >= 1),
    path BLOB NOT NULL,
    hash_json TEXT NOT NULL,
    PRIMARY KEY (root_generation, path)
) STRICT;

PRAGMA user_version = 3;
