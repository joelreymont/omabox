-- Baselines hold their kind, content and revision in typed columns. A kind
-- is the number MODEL gives an observation's form: present 0, directory 1,
-- absent 2. converted_baselines holds each version-nine row converted, its
-- kind NULL where MODEL's JSON reader refuses the text; the program refuses
-- the migration on such a row, then drops the table and sets the version.
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
