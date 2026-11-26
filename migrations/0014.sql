-- A remote conflict copy's verified stage that may be on disk: target the
-- copy's path, content what was staged, canonical_path the key of the
-- conflicted path whose live plan or conflict block may install it.
CREATE TABLE copy_stages (
    target BLOB NOT NULL,
    content TEXT NOT NULL,
    canonical_path BLOB NOT NULL,
    PRIMARY KEY (target, content)
) STRICT;

PRAGMA user_version = 14;
