# The Dropbox vocabulary in Habu

Package `DROPBOX`, in `src/dropbox.f` beside `src/dropbox.rs`. It has one word
for each Dropbox route omabox calls, and it speaks Dropbox's own terms:
entry, rev, content hash, cursor and upload session. The signatures below are
not checked yet.

## What a call answers

```forth
\ Dropbox's 409 error tags that omabox decides on; any other tag
\ is `other`, and its text goes in the log line.
ENUM error
   not-found not-file not-folder malformed-path disallowed-name
   conflict no-write-permission restricted-content
   insufficient-space locked reset invalid-root
   content-hash-mismatch unsupported-file other ;ENUM

SUMTYPE reply
   VARIANT done ;VARIANT          \ the client holds the answer
   VARIANT refused error ;VARIANT \ Dropbox said no, and why
   VARIANT retry n ;VARIANT       \ ms Dropbox asked to wait, else 0
   VARIANT unlinked ;VARIANT      \ the refresh token is dead
;SUMTYPE
```

- `retry` covers 429, 5xx, 408, `too_many_write_operations`, a timeout or a
  lost connection.
- Anything else throws a `DROPBOX:E-` code after one log line, because it
  means a bug on one side of the wire. That includes 400, a 3xx (redirects are
  never followed), an answer that does not parse, and a cursor that did not
  advance.
- Mapping a tag to what sync does (block the path, wait, show the user) is
  sync policy, not the vocabulary's job.

## The words

```forth
\ One client per task, opened on a config (below). A file hash
\ or path in an answer is borrowed until the next call.
: OPEN   ( ptr config ptr ARENA:arena -- ptr client )
: CLOSE  ( ptr client -- )

\ oauth2/token
: EXCHANGE      ( ptr u8 n ptr u8 n ptr client -- reply )  \ code, PKCE verifier
: REFRESH-TOKEN ( ptr client -- ptr u8 n )

\ users/get_current_account
: ACCOUNT        ( ptr client -- reply )
: ACCOUNT-ID     ( ptr client -- ptr u8 n )
: ROOT-NAMESPACE ( ptr client -- ptr u8 n )

\ files/list_folder (recursive) and list_folder/continue, every
\ page, each entry handed to the quotation; `reset` mid-way
\ means nothing seen may be published
: LIST    ( ptr u8 n ptr client [ ptr entry -- ] -- reply )  \ path
: CHANGES ( ptr u8 n ptr client [ ptr entry -- ] -- reply )  \ cursor
: CURSOR  ( ptr client -- ptr u8 n )

\ files/list_folder/longpoll
: WAIT     ( ptr u8 n n ptr client -- reply )  \ cursor, seconds
: CHANGED? ( ptr client -- bool )
: BACKOFF  ( ptr client -- n )                 \ seconds

\ files/get_metadata, download, upload (+ session), delete_v2,
\ create_folder_v2; each answers the entry Dropbox reports
: METADATA      ( ptr u8 n ptr client -- reply )
: DOWNLOAD      ( ptr u8 n n ptr client [ ptr u8 n -- ] -- reply )  \ rev, offset, bytes
: UPLOAD        ( ptr upload ptr client [ n -- ] -- reply )  \ bytes accepted
: DELETE        ( ptr u8 n ptr u8 n ptr client -- reply )  \ path, rev
: CREATE-FOLDER ( ptr u8 n ptr client -- reply )
: ENTRY         ( ptr client -- ptr entry )

STRUCTURE entry
   FIELD kind ...       \ file, folder or deleted
   FIELD lower ...      \ path_lower
   FIELD display ...    \ path_display
   FIELD rev ...        \ files only
   FIELD hash ...       \ content_hash, files only
   FIELD size n         \ files only
;STRUCTURE

STRUCTURE upload
   FIELD fd fd          \ the verified stage, read from 0
   FIELD size n
   FIELD hash ...       \ its Dropbox content hash
   FIELD path ...
   FIELD rev ...        \ empty: add only if absent
;STRUCTURE
```

```forth
\ What OPEN copies into the client.
STRUCTURE config
   FIELD key ...        \ the app key, Dropbox's client_id
   FIELD token ...      \ the refresh token; empty until EXCHANGE
   FIELD root ...       \ root namespace; empty means the account's home
   FIELD api ...        \ origins, which tests point at the fake
   FIELD content ...
   FIELD notify ...
;STRUCTURE
: PRODUCTION ( ptr config -- )   \ sets the three origins to Dropbox's
```

- **`root`** goes in a `Dropbox-API-Path-Root` header,
  `{".tag": "root", "root": "<id>"}`, on every call but the token calls. Every
  path is then relative to that namespace, which the journal binds. An empty
  root sends no header, which only linking needs before it knows the root.
- **`DOWNLOAD`** fetches `rev:<rev>`, which is that exact revision, from
  `offset` with a Range header. It checks the answer's Content-Range and
  metadata, and hands each body chunk to the quotation. The caller writes and
  hashes the chunks.
- **`DELETE`** sends the rev as `parent_rev`. With an empty rev it deletes
  unconditionally, which sync uses only for a folder it has just seen empty.
- **A mutation whose answer is lost is confirmed before it answers.**
  `UPLOAD`, `DELETE` and `CREATE-FOLDER` then ask `get_metadata`. They answer
  `done` only if Dropbox now holds the intended result: the same content hash,
  no entry, or a folder. Otherwise they answer `retry`. A mutation never
  answers "unknown".

## The upload, as a state machine

Files up to 32 MiB go in one `upload` call; larger ones go through a session.

```forth
FSM:DEFINE SESSION ( ptr upload ) upload-step
   IN single      SEND-SENSE ( send-event )
      committed   ANSWER-DONE     >ended
      lost        -               >confirming
      refused     ANSWER-REFUSED  >ended
   IN starting    START-SENSE ( start-event )
      opened      -               >appending
      lost        ANSWER-RETRY    >ended
      refused     ANSWER-REFUSED  >ended
   IN appending   APPEND-SENSE ( append-event )
      stored      ADVANCE         >appending
      complete    ADVANCE         >finishing
      lost        -               >appending   \ resent once
      cut         ANSWER-RETRY    >ended       \ lost twice
      gone        -               >restarting
      refused     ANSWER-REFUSED  >ended
   IN finishing   FINISH-SENSE ( finish-event )
      committed   ANSWER-DONE     >ended
      lost        -               >confirming
      gone        -               >restarting
      refused     ANSWER-REFUSED  >ended
   IN confirming  CONFIRM-SENSE ( confirm-event )
      same        ANSWER-DONE     >ended
      other       ANSWER-RETRY    >ended
   IN restarting  RESTART-SENSE ( restart-event )
      again       REWIND          >starting    \ once per UPLOAD
      twice       ANSWER-RETRY    >ended
   FINAL ended  -
;DEFINE
```

- **`stored`** also covers `incorrect_offset` whose correct offset equals
  the chunk's end: a resent chunk Dropbox already had. Any other correct
  offset, or a closed or missing session, is **`gone`**, and the upload starts
  over once.
- **`finish` carries no content hash.** It sends no bytes, and Dropbox
  checks that field against the bytes of the call. The upload is checked
  instead by the content hash of the entry Dropbox commits. The Rust version
  sends the whole file's hash here, and every upload over 32 MiB fails (a
  hypothesis, consistent with 6 of 6 failures).
- An upload does not resume across calls. A `retry` starts over on the next
  pass.

## Kept out of it

The sync code builds these from the words above:
- mapping Dropbox paths to local paths, and checks that differ only in case;
- collecting a listing and publishing it only once complete;
- checking that a folder is empty before deleting it;
- backoff policy;
- checking that the account and root still match the journal.

## Simplified from the Rust version

- **Token refresh.** Each client refreshes its own access token when Dropbox
  answers `expired_access_token`, then resends the request once. The Rust
  version shares one token across tasks behind a single-flight refresh.
  Dropbox tokens last four hours, so a few workers each refreshing on their
  own costs a few extra calls a day.
- **No SDK.** The generated `dropbox-sdk` and the `ureq` adapter give way to
  `net/curl.f` and `json.f` directly.

## What it needs from Habu

- **`json.f`:** a writer mode that escapes DEL and every non-ASCII character
  as `\uXXXX`. `Dropbox-API-Arg` is a header, and Dropbox requires those
  escapes in it.
- **`net/curl.f`:** `RESET`, which sets a handle back to the options `INIT`
  gives it, as `curl_easy_reset` does, and keeps its connections. A handle
  keeps every option from one request to the next, and nothing clears its
  headers, so without it a client's one handle would resend every earlier
  request's headers, old tokens included.

A call's deadlines need nothing new: `CURL:LOW-SPEED!` bounds the connect by
the same seconds as a stalled body, so a call has `TIMEOUT!` for the whole
call and `LOW-SPEED!` for a stall. A long poll, whose body is silent until it
answers, sets `LOW-SPEED!` to zero and only `TIMEOUT!`.

A client reads every answer through curl's streaming words, so no buffer caps
its size. A program that uses `DROPBOX` therefore starts the CURL loop first
(`AIO:START CURL:LOOP-START`) and stops it last.

## How it is tested

The tests run against a fake Dropbox on `net/http.f`, in the style of
`net/test-model.f`, with scenarios ported from the wire-level cases in
`tests/dropbox_fake.rs`:
- **listing:** many pages, a reset mid-listing, and a cursor that does not
  advance;
- **long poll:** changes, a timeout and a backoff;
- **metadata:** found and not found;
- **download:** a resume by range, and a Content-Range mismatch;
- **single upload:** add, and an update that conflicts;
- **session upload:**
  - a lost append, resent;
  - `incorrect_offset` at the chunk's end;
  - a closed session, restarted once;
  - a lost finish, confirmed;
- **delete and create-folder:** a conflict, and not found;
- **auth and transport:**
  - an expired token, refreshed and resent;
  - `invalid_grant`, which answers `unlinked`;
  - 429 with `Retry-After`, and 5xx;
  - a 3xx, which is not followed;
  - a non-ASCII path in `Dropbox-API-Arg`.
