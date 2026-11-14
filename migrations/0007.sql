-- The device number is not a durable identity: btrfs assigns each subvolume a
-- new anonymous device at every mount, so a binding that records one names a
-- different root after a reboot. Version seven binds the root by inode, birth
-- time and subvolume, which live on disk. A version-six binding has no birth
-- time; it is copied with none and upgraded in place by the next activation
-- whose path and inode match it.
CREATE TABLE local_root_binding_v7 (
    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
    canonical_path BLOB NOT NULL,
    inode BLOB NOT NULL,
    birth_seconds INTEGER,
    birth_nanoseconds INTEGER,
    subvolume BLOB,
    generation INTEGER NOT NULL CHECK (generation >= 1),
    CHECK ((birth_seconds IS NULL) = (birth_nanoseconds IS NULL)),
    CHECK (birth_nanoseconds IS NULL OR birth_nanoseconds BETWEEN 0 AND 999999999),
    CHECK (birth_seconds IS NOT NULL OR subvolume IS NULL)
) STRICT;

INSERT INTO local_root_binding_v7(singleton, canonical_path, inode, generation)
SELECT singleton, canonical_path, inode, generation FROM local_root_binding;

DROP TABLE local_root_binding;
ALTER TABLE local_root_binding_v7 RENAME TO local_root_binding;

PRAGMA user_version = 7;
