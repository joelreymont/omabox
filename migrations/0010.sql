-- Baselines and remote observations hold their kind, content and revision
-- in typed columns. A kind is the number MODEL gives an observation's form:
-- present 0, directory 1, absent 2, unknown 3 plus its reason's index. Each
-- converted_ table holds its version-nine rows converted, the kind NULL
-- where MODEL's JSON reader refuses the text; the program refuses the
-- migration on such a row, then drops both tables and sets the version.
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
