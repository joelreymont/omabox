-- Baselines, remote and local observations hold their kind, content and
-- revision, which a local observation lacks, in typed columns, and the
-- hash cache its fingerprint and content hash. A kind is
-- the number MODEL gives an observation's form: present 0, directory 1,
-- absent 2, unknown 3 plus its reason's index. Each converted_ table holds
-- its version-nine rows converted, the kind NULL where MODEL's JSON reader
-- refuses the text; the program refuses the migration on such a row, then
-- drops both tables and sets the version. A local row MODEL cannot read is
-- kept as unknown instead, and a hash cache row that does not convert is
-- dropped: the next scan hashes its file again.
CREATE TABLE converted_baselines (
    path BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    kind INTEGER,
    content TEXT,
    revision TEXT
) STRICT;

-- Every JSON function but json_valid reads JSON5 and throws on malformed
-- text, so json_valid's RFC 8259 check guards the rest. A present value is
-- an object of one member, Present, whose object holds content and revision
-- once each, as strings; other members of that object are skipped.
INSERT INTO converted_baselines(path, canonical_path, kind, content, revision)
SELECT path, canonical_path, kind,
    CASE kind WHEN 0 THEN baseline_json ->> '$.Present.content' END,
    CASE kind WHEN 0 THEN baseline_json ->> '$.Present.revision' END
FROM (
    SELECT path, canonical_path, baseline_json, CASE
        WHEN NOT json_valid(baseline_json) THEN NULL
        WHEN json_type(baseline_json) = 'text' THEN
            CASE baseline_json ->> '$'
                WHEN 'Directory' THEN 1
                WHEN 'Absent' THEN 2
            END
        WHEN json_type(baseline_json) = 'object'
            AND (SELECT count(*) FROM json_each(baseline_json)) = 1
            AND json_type(baseline_json, '$.Present') = 'object'
            AND (SELECT sum(key = 'content') = 1 AND sum(key = 'revision') = 1
                FROM json_each(baseline_json, '$.Present'))
            AND json_type(baseline_json, '$.Present.content') = 'text'
            AND json_type(baseline_json, '$.Present.revision') = 'text'
        THEN 0
    END AS kind
    FROM baselines
);

DROP TABLE baselines;

CREATE TABLE baselines (
    path BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    kind INTEGER NOT NULL,
    content TEXT,
    revision TEXT,
    CHECK ((kind = 0 AND content IS NOT NULL AND revision IS NOT NULL)
        OR (kind = 1 AND content IS NULL AND revision IS NULL))
) STRICT;

CREATE UNIQUE INDEX baselines_by_canonical_path
    ON baselines(canonical_path);

-- An absent baseline reads as none, so its row is not kept.
INSERT INTO baselines(path, canonical_path, kind, content, revision)
SELECT path, canonical_path, kind, content, revision
FROM converted_baselines WHERE kind IN (0, 1);

CREATE TABLE converted_remote_observations (
    path BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    kind INTEGER,
    content TEXT,
    revision TEXT
) STRICT;

-- A present value reads as a baseline's. An unknown one is an object of one
-- member, Unknown, whose value is a reason's name as a string.
INSERT INTO converted_remote_observations(
    path, canonical_path, kind, content, revision)
SELECT path, canonical_path, kind,
    CASE kind WHEN 0 THEN observation_json ->> '$.Present.content' END,
    CASE kind WHEN 0 THEN observation_json ->> '$.Present.revision' END
FROM (
    SELECT path, canonical_path, observation_json, CASE
        WHEN NOT json_valid(observation_json) THEN NULL
        WHEN json_type(observation_json) = 'text' THEN
            CASE observation_json ->> '$'
                WHEN 'Directory' THEN 1
                WHEN 'ConfirmedAbsent' THEN 2
            END
        WHEN json_type(observation_json) = 'object'
            AND (SELECT count(*) FROM json_each(observation_json)) = 1
        THEN CASE
            WHEN json_type(observation_json, '$.Present') = 'object'
                AND (SELECT sum(key = 'content') = 1
                        AND sum(key = 'revision') = 1
                    FROM json_each(observation_json, '$.Present'))
                AND json_type(observation_json, '$.Present.content') = 'text'
                AND json_type(observation_json, '$.Present.revision') = 'text'
            THEN 0
            WHEN json_type(observation_json, '$.Unknown') = 'text' THEN
                CASE observation_json ->> '$.Unknown'
                    WHEN 'Incomplete' THEN 3
                    WHEN 'Inaccessible' THEN 4
                    WHEN 'Unavailable' THEN 5
                    WHEN 'Stale' THEN 6
                    WHEN 'CursorReset' THEN 7
                    WHEN 'Unsupported' THEN 8
                END
        END
    END AS kind
    FROM remote_observations
);

DROP TABLE remote_observations;

CREATE TABLE remote_observations (
    path BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    kind INTEGER NOT NULL,
    content TEXT,
    revision TEXT,
    CHECK ((kind = 0 AND content IS NOT NULL AND revision IS NOT NULL)
        OR ((kind = 1 OR kind BETWEEN 3 AND 8)
            AND content IS NULL AND revision IS NULL))
) STRICT;

CREATE UNIQUE INDEX remote_observations_by_canonical_path
    ON remote_observations(canonical_path);

-- An absent observation reads as none, so its row is not kept.
INSERT INTO remote_observations(path, canonical_path, kind, content, revision)
SELECT path, canonical_path, kind, content, revision
FROM converted_remote_observations WHERE kind IN (0, 1, 3, 4, 5, 6, 7, 8);

-- A local present value is an object of one member, Present, whose object
-- holds content once, as a string. Any other text is kept as unknown,
-- Incomplete, kind 3: a missing row beside a baseline reads as a local
-- deletion. An absent observation reads as none, so its row is not kept.
DROP INDEX local_observations_by_canonical_path;

ALTER TABLE local_observations RENAME TO local_observations_9;

CREATE TABLE local_observations (
    path BLOB PRIMARY KEY NOT NULL,
    canonical_path BLOB NOT NULL,
    kind INTEGER NOT NULL,
    content TEXT,
    CHECK ((kind = 0 AND content IS NOT NULL)
        OR ((kind = 1 OR kind BETWEEN 3 AND 8) AND content IS NULL))
) STRICT;

CREATE INDEX local_observations_by_canonical_path
    ON local_observations(canonical_path, path);

INSERT INTO local_observations(path, canonical_path, kind, content)
SELECT path, canonical_path, kind,
    CASE kind WHEN 0 THEN observation_json ->> '$.Present.content' END
FROM (
    SELECT path, canonical_path, observation_json, coalesce(CASE
        WHEN NOT json_valid(observation_json) THEN NULL
        WHEN json_type(observation_json) = 'text' THEN
            CASE observation_json ->> '$'
                WHEN 'Directory' THEN 1
                WHEN 'ConfirmedAbsent' THEN 2
            END
        WHEN json_type(observation_json) = 'object'
            AND (SELECT count(*) FROM json_each(observation_json)) = 1
        THEN CASE
            WHEN json_type(observation_json, '$.Present') = 'object'
                AND (SELECT sum(key = 'content') = 1
                    FROM json_each(observation_json, '$.Present'))
                AND json_type(observation_json, '$.Present.content') = 'text'
            THEN 0
            WHEN json_type(observation_json, '$.Unknown') = 'text' THEN
                CASE observation_json ->> '$.Unknown'
                    WHEN 'Incomplete' THEN 3
                    WHEN 'Inaccessible' THEN 4
                    WHEN 'Unavailable' THEN 5
                    WHEN 'Stale' THEN 6
                    WHEN 'CursorReset' THEN 7
                    WHEN 'Unsupported' THEN 8
                END
        END
    END, 3) AS kind
    FROM local_observations_9
)
WHERE kind != 2;

DROP TABLE local_observations_9;

-- A hash cache value is an object holding fingerprint, an object, and
-- content, a string, once each; the fingerprint holds its six members
-- once each, as integers, and inode, size and both nanoseconds are not
-- negative. Other members are skipped. A u64 above SQLite's largest
-- integer reads as a real, so its row is dropped. The content is 64
-- lowercase hex digits; length counts characters to the first NUL, so
-- the content's bytes are counted too.
ALTER TABLE local_hash_cache RENAME TO local_hash_cache_9;

CREATE TABLE local_hash_cache (
    root_generation INTEGER NOT NULL CHECK (root_generation >= 1),
    path BLOB NOT NULL,
    inode INTEGER NOT NULL,
    size INTEGER NOT NULL,
    modified_seconds INTEGER NOT NULL,
    modified_nanoseconds INTEGER NOT NULL,
    changed_seconds INTEGER NOT NULL,
    changed_nanoseconds INTEGER NOT NULL,
    content_hash TEXT NOT NULL CHECK (length(content_hash) = 64
        AND length(CAST(content_hash AS BLOB)) = 64
        AND content_hash NOT GLOB '*[^0-9a-f]*'),
    PRIMARY KEY (root_generation, path)
) STRICT;

INSERT INTO local_hash_cache(root_generation, path, inode, size,
    modified_seconds, modified_nanoseconds, changed_seconds,
    changed_nanoseconds, content_hash)
SELECT root_generation, path,
    hash_json ->> '$.fingerprint.inode',
    hash_json ->> '$.fingerprint.size',
    hash_json ->> '$.fingerprint.modified_seconds',
    hash_json ->> '$.fingerprint.modified_nanoseconds',
    hash_json ->> '$.fingerprint.changed_seconds',
    hash_json ->> '$.fingerprint.changed_nanoseconds',
    hash_json ->> '$.content'
FROM local_hash_cache_9
WHERE CASE WHEN json_valid(hash_json) THEN
    json_type(hash_json) = 'object'
    AND (SELECT count(*) = 2 AND count(DISTINCT key) = 2
            AND sum(key = 'fingerprint' AND type = 'object') = 1
            AND sum(key = 'content' AND type = 'text'
                AND length(atom) = 64
                AND length(CAST(atom AS BLOB)) = 64
                AND atom NOT GLOB '*[^0-9a-f]*') = 1
        FROM json_each(hash_json)
        WHERE key IN ('fingerprint', 'content'))
    AND (SELECT count(*) = 6 AND count(DISTINCT key) = 6
            AND sum(type = 'integer' AND typeof(atom) = 'integer'
                AND (atom >= 0
                    OR key IN ('modified_seconds', 'changed_seconds')))
                = 6
        FROM json_each(hash_json, '$.fingerprint')
        WHERE key IN ('inode', 'size', 'modified_seconds',
            'modified_nanoseconds', 'changed_seconds',
            'changed_nanoseconds'))
END;

DROP TABLE local_hash_cache_9;
