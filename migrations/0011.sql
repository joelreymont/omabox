-- Version eleven records the upload session Dropbox holds open for an
-- operation: the session's id, the bytes Dropbox confirmed, the upload's
-- length and the content hash of its bytes. Each accepted append rewrites
-- the row. The transactions that complete, conflict, supersede or purge
-- the operation delete it, and so does the prune that deletes the
-- operation; blocking and unblocking keep it. The operation's row is
-- never deleted from under it.
CREATE TABLE upload_sessions (
    operation_id INTEGER PRIMARY KEY NOT NULL
        REFERENCES operations(id) ON DELETE RESTRICT,
    session_id TEXT NOT NULL CHECK (session_id != ''),
    confirmed_offset INTEGER NOT NULL CHECK (confirmed_offset >= 0),
    length INTEGER NOT NULL CHECK (length >= confirmed_offset),
    content TEXT NOT NULL
) STRICT;

PRAGMA user_version = 11;
