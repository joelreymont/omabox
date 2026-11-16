# The Dropbox vocabulary in Habu

Package `DROPBOX`, in `src/dropbox.f`. It has one word for each Dropbox route
omabox calls, and it speaks Dropbox's own terms: entry, rev, content hash,
cursor and upload session. The signatures below are not checked yet.

## What a call answers

```forth
\ Dropbox's 409 error tags that omabox decides on; any other tag
\ is `other`, and its text goes in the log line. `path-mismatch`
\ is no tag: an entry whose path_lower is not the path's full lowercase.
\ Nor is `unverified`: a download whose answer fails its checks or does
\ not parse.
ENUM error
   not-found not-file not-folder malformed-path disallowed-name
   conflict no-write-permission restricted-content
   access-restricted team-folder operation-suppressed
   insufficient-space locked reset invalid-root
   content-hash-mismatch unsupported-file path-mismatch unverified
   other ;ENUM

ENUM reply
   VARIANT done ;VARIANT                    \ the client holds the answer
   VARIANT refused FIELD why error ;VARIANT \ Dropbox said no, and why
   VARIANT retry FIELD ms n ;VARIANT        \ ms Dropbox asked to wait, else 0
   VARIANT unlinked ;VARIANT                \ refused until the user acts
;ENUM
```

- `retry` covers 429, 5xx, 408, `too_many_write_operations`, a timeout or a
  lost connection. Its wait is `Retry-After`, in seconds (any number of
  digits) or as an HTTP date (a passed date asks for none); on a 429, the
  larger of that and the body's `error.retry_after`; else 0. No wait is over
  15 minutes. A 408 is retried as HTTP lets a client repeat a request the
  server timed out; the Rust version stops on one as an unexpected status.
- `unlinked` is logged once, where it is decided: a 403, a refreshed token
  refused, or `invalid_grant` on the refresh. A confirmation that answers
  `unlinked` answers it in its call's place. A code exchange's `unlinked`
  means the code is dead and logs nothing.
- A refreshed token refused, or `invalid_grant`, also rejects the client:
  every later call that carries a token answers `unlinked` without sending
  anything or logging again. Only a new login restores access: an
  `EXCHANGE`, or a new client.
- Anything else throws a `DROPBOX:E-` code after one log line, because it
  means a bug on one side of the wire. That includes 400, a 3xx (redirects are
  never followed), an answer that does not parse (a download's answers
  `refused unverified`), and a cursor that did not advance.
- `E-NOT-STORED` is not such a bug: the config's store refused a rotated
  refresh token (below). The cause is local and may clear, as when a keyring
  is locked, so the caller waits and calls again; the next call retries the
  store.
- Mapping a tag to what sync does (block the path, wait, show the user) is
  sync policy, not the vocabulary's job.

## The words

```forth
\ One client per task, opened on a config (below). A file hash
\ or path in an answer is borrowed until the next call.
: OPEN   ( ^config ^ARENA:arena -- ^client )
: CLOSE  ( ^client -- )

\ oauth2/token
: EXCHANGE      ( ^u8 n ^u8 n ^client -- reply )  \ code, PKCE verifier
: REFRESH-TOKEN ( ^client -- ^u8 n )

\ users/get_current_account
: ACCOUNT        ( ^client -- reply )
: ACCOUNT-ID     ( ^client -- ^u8 n )
: ROOT-NAMESPACE ( ^client -- ^u8 n )

\ files/list_folder (recursive) and list_folder/continue, every
\ page, each entry handed to the quotation, a file Dropbox
\ described incompletely too, which COMPLETE? tells; `reset`
\ mid-way means nothing seen may be published
: LIST    ( ^u8 n ^client [ ^entry -- ] -- reply )  \ path
: CHANGES ( ^u8 n ^client [ ^entry -- ] -- reply )  \ cursor
: CURSOR  ( ^client -- ^u8 n )

\ files/list_folder/longpoll
: WAIT     ( ^u8 n n ^client -- reply )  \ cursor, seconds
: CHANGED? ( ^client -- bool )
: BACKOFF  ( ^client -- n )                 \ seconds

\ files/get_metadata, download, upload (+ session), delete_v2,
\ create_folder_v2; each answers the entry Dropbox reports, but a
\ download a 416 completes; READ-BODY reads a download's body
: METADATA      ( ^u8 n ^client -- reply )  \ path
                \ an entry at another path: refused path-mismatch;
                \ a file described incompletely: done, COMPLETE? tells
: DOWNLOAD      ( ^u8 n n ^client [ n n ^fetch -- ] -- reply )
                \ rev, offset; the body: its offset, the size, the fetch
: READ-BODY     ( ^u8 n ^fetch -- n )       \ bytes read, 0 at the end
: UPLOAD        ( ^upload ^client [ n -- ] -- reply )  \ bytes accepted
: DELETE        ( ^u8 n ^u8 n ^client -- reply )  \ path, rev
: CREATE-FOLDER ( ^u8 n ^client -- reply )  \ path
: ENTRY         ( ^client -- ^entry )
: COMPLETE?     ( ^entry -- bool )  \ a downloadable file with a
                \ rev and a 64-lowercase-hex-digit content hash

ENUM kind file folder deleted ;ENUM

STRUCTURE entry
   FIELD kind kind
   FIELD lower ...         \ path_lower
   FIELD display ...       \ path_display
   FIELD rev ...           \ files only
   FIELD content-hash ...  \ files only
   FIELD size n            \ files only
   FIELD downloadable bool \ is_downloadable, false with symlink_info;
                           \ true for a folder or deleted entry
;STRUCTURE

STRUCTURE upload
   FIELD fd fd          \ the verified stage, read from 0
   FIELD size n
   FIELD hash ...       \ its Dropbox content hash
   FIELD path ...
   FIELD rev ...        \ empty: add only if absent
;STRUCTURE

\ Dropbox's content hash: SHA-256 over the joined SHA-256 digests
\ of each 4 MiB block
STRUCTURE hasher ... ;STRUCTURE
: HASH-BEGIN ( ^hasher -- )
: HASH-FEED  ( ^u8 n ^hasher -- )
: HASH-END   ( ^hasher -- ^u8 n )   \ 64 lowercase hex digits
```

```forth
\ What OPEN copies into the client.
STRUCTURE config
   FIELD key ...        \ the app key, Dropbox's client_id
   FIELD token ...      \ the refresh token; empty until EXCHANGE
   FIELD store [ ^u8 n -- ]  \ keeps a rotated refresh token
   FIELD root ...       \ root namespace; empty means the account's home
   FIELD api ...        \ origins, which tests point at the fake
   FIELD content ...
   FIELD notify ...
;STRUCTURE
: PRODUCTION ( ^config -- )   \ sets the three origins to Dropbox's
```

- **`store`** keeps a refresh token that Dropbox rotates, where `token` came
  from, and throws when it cannot. When a refresh answers a new
  `refresh_token`, the client hands it to the store before the new access
  token goes out. The client keeps both new tokens either way. If the store
  throws, the call that refreshed throws `E-NOT-STORED`. The rotation is then
  pending: each later call that carries a token first hands the rotated one
  to the store again, and throws the same way until the store takes it. A
  refresh that answers no `refresh_token`, or the same one, never runs the
  store. The store runs inside the call that refreshed, so it must not use
  the client.
- **`root`** goes in a `Dropbox-API-Path-Root` header,
  `{".tag": "root", "root": "<id>"}`, on every call but the token calls. Every
  path is then relative to that namespace, which the journal binds. An empty
  root sends no header, which only linking needs before it knows the root.
- **`DOWNLOAD`** fetches `rev:<rev>`, which is that exact revision, from
  `offset` with a Range header. It checks the answer's status, Content-Range
  and metadata before any byte reaches the quotation. On a done answer it
  then calls the quotation once with the file offset the body starts at, the
  file's size and the download's `fetch`, an opaque record that lives until
  the quotation returns. `READ-BODY` copies the body's next bytes into the
  buffer it is given, at most the rest of the chunk it holds, and answers how
  many, 0 at the body's end, as Rust's `impl Read` does; the caller wraps it
  as `[: f READ-BODY ;]` for a word that takes a reader, and writes and hashes
  what it reads. A reader that reads a local cannot be handed to a quotation,
  which might keep it, so the fetch is handed instead. On any other answer the
  quotation is not called; an empty body calls it with a fetch at its end.
  - The body's length is checked once `READ-BODY` reached its end. A body the
    quotation leaves unread is cancelled as a throw cancels it, and the
    answer is done without that check.
  - A transfer lost inside the body throws a code of DROPBOX's own from
    `READ-BODY`, never an early 0, which the caller would take for the body's
    end. `DOWNLOAD` ends that code and answers as a transfer lost before the
    body does, retry 0 for a lost connection, even when the quotation caught
    it.
  - A 416 from a nonzero offset whose Content-Range is `bytes */<offset>`
    says the bytes before the offset are the whole file: the quotation gets
    that offset, that size and a fetch at its end, and the answer is done.
    That answer carries no Dropbox-API-Result, so `ENTRY` is not its entry.
    Any other 416 from a nonzero offset starts over once from 0, as the Rust
    version does, so the quotation sees offset 0. Every other `done`
    carries the entry Dropbox reported.
  - An answer whose rev, Content-Range or length is not the one asked, a
    whole file for a range or a range nobody asked for, a 416 from 0, and
    an answer whose Dropbox-API-Result or error does not parse answer
    `refused unverified`, logged once with its reason, so the caller can
    block that plan alone, as the Rust version's
    `DownloadVerificationFailed` does. The client stays usable for its
    next call.
  - A throw while the transfer is in flight, from a failed check, the
    quotation, `READ-BODY` or an allocation, ends it in one place: the client
    cancels the transfer and reads it to its end into a region laid out at
    `OPEN`, so ending it allocates nothing. A failed check then answers
    `refused unverified`; any other code is rethrown. The client's handle is
    then free for its next call. A throw after the read that ended the
    transfer, such as the quotation's once `READ-BODY` reached the body's
    end, cancels nothing; the header capture after the transfer may throw,
    and its checks answer `refused unverified`, with the handle already free.
- **`DELETE`** sends the rev as `parent_rev`. With an empty rev it deletes
  unconditionally, which sync uses only for a folder it has just seen empty.
- **A mutation confirms an answer it cannot trust.** libcurl resends a POST
  on a new connection when a reused one closes before any answer byte, so a
  mutation Dropbox applied can come back lost or refused. `UPLOAD`, `DELETE`
  and `CREATE-FOLDER` then ask `get_metadata` whether Dropbox holds the
  intended result: the same content hash, no entry, or a folder.
  - A lost answer, or a `done` whose entry's `path_lower` is not the
    path's full Unicode lowercase: `done` if it holds, else `retry`.
    `DELETE` given a rev treats a `done` whose entry is not a file at that
    rev the same way.
  - A `conflict` refusal: `done` if it holds, else the refusal stands.
  - `DELETE` refused `not-found` is `done` without asking: the path is
    absent, which is what a delete intends.
  - A confirmation whose entry's `path_lower` is not the path's full
    Unicode lowercase answers `refused path-mismatch`, for that path alone.
  - A confirmation that must wait answers its `retry`, with its wait.
  - Every other refusal stands. A mutation never answers "unknown".
- **`UPLOAD` checks what Dropbox committed.** An entry at another path is
  confirmed, as above. Its content hash must be the upload's, else it
  answers `refused content-hash-mismatch`, the tag Dropbox gives a single
  upload whose bytes do not match.

## The upload, as a state machine

Files up to 32 MiB go in one `upload` call; larger ones go through a session.

```forth
FSM:DEFINE SESSION ( ^run ) upload-step send-event
   IN single  SEND-SENSE
      committed  ANSWER-DONE   >ended
      elsewhere  DISTRUST      >confirming   \ at another path
      lost       -             >confirming
      conflict   -             >confirming
      failed     ANSWER-REPLY  >ended
   IN starting  START-SENSE ( start-event )
      opened  -             >appending
      lost    ANSWER-RETRY  >ended
      failed  ANSWER-REPLY  >ended
   IN appending  APPEND-SENSE ( append-event )
      stored    CHUNK-ADVANCE  >appending
      complete  CHUNK-ADVANCE  >finishing
      lost      -              >appending    \ resent once
      cut       ANSWER-RETRY   >ended        \ lost twice
      gone      -              >restarting
      failed    ANSWER-REPLY   >ended
   IN finishing  FINISH-SENSE ( finish-event )
      committed  ANSWER-DONE   >ended
      elsewhere  DISTRUST      >confirming
      lost       -             >confirming
      conflict   -             >confirming
      gone       -             >verifying
      failed     ANSWER-REPLY  >ended
   IN confirming  CONFIRM-SENSE ( confirm-event )
      same       ANSWER-DONE      >ended
      elsewhere  ANSWER-MISMATCH  >ended
      wait       ANSWER-REPLY     >ended      \ get_metadata's retry
      other      ANSWER-REPLY     >ended
      unlinked   ANSWER-UNLINKED  >ended
   IN verifying  CONFIRM-SENSE ( confirm-event )
      same       ANSWER-DONE      >ended
      elsewhere  ANSWER-MISMATCH  >ended
      wait       ANSWER-REPLY     >ended
      other      -                >restarting
      unlinked   ANSWER-UNLINKED  >ended
   IN restarting  RESTART-SENSE ( restart-event )
      once   REWIND        >starting     \ once per UPLOAD
      twice  ANSWER-RETRY  >ended
   FINAL ended  -
;DEFINE
```

- **`stored`** also covers `incorrect_offset` whose correct offset equals
  the chunk's end: a resent chunk Dropbox already had. Any other correct
  offset, or a closed or missing session, is **`gone`**, and the upload starts
  over once.
- **A finish whose session is gone is verified first.** A resent finish
  Dropbox already applied answers `lookup_failed/not_found`, so the upload
  asks `get_metadata` and starts over only when Dropbox does not hold the
  upload's content hash.
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
  answers any 401, then resends the request once; a second 401, like a 403
  or `invalid_grant`, answers `unlinked`, as Rust reports them as needing
  the user, and a second 401 or `invalid_grant` rejects the client as
  Rust's token does. The Rust version shares one token across tasks behind a
  single-flight refresh. Dropbox tokens last four hours, so a few workers
  each refreshing on their own costs a few extra calls a day.
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
- **`net/curl.f`:** `HEADERS` answering a streamed transfer's headers from its
  first chunk on. Today it refuses a transfer in flight, so `DOWNLOAD` could
  check the status and Content-Range only after the body had reached the
  caller.

A call's deadlines need nothing new: `CURL:LOW-SPEED!` bounds the connect by
the same seconds as a stalled body, so a call has `TIMEOUT!` for the whole
call and `LOW-SPEED!` for a stall. A long poll, whose body is silent until it
answers, sets `LOW-SPEED!` to zero and only `TIMEOUT!`. So does
`upload_session/finish`, silent while Dropbox commits: 3600 s, as the Rust
version's `SESSION_FINISH_SECONDS`.

A client reads every answer through curl's streaming words, so no buffer caps
its size. A program that uses `DROPBOX` therefore starts the CURL loop first
(`AIO:START CURL:LOOP-START`) and stops it last.

## How it is tested

The tests run against a fake Dropbox on `net/http.f`, in the style of
`net/test-model.f`, with scenarios ported from the wire-level cases in
`tests/dropbox_fake.rs` on the `rust` branch:
- **listing:** many pages, a reset mid-listing, and a cursor that does not
  advance;
- **long poll:** changes, a timeout and a backoff;
- **metadata:** found and not found;
- **download:** a resume by range, a Content-Range mismatch, and a 416;
- **content hash:** empty, one byte, exactly 4 MiB, and 4 MiB plus one;
- **single upload:** add, an update that conflicts, and an upload Dropbox
  already holds, refused as a conflict and confirmed;
- **session upload:**
  - a lost append, resent;
  - `incorrect_offset` at the chunk's end;
  - a closed session, restarted once;
  - a lost finish, confirmed;
  - a finish whose session is gone: confirmed when Dropbox holds it, else
    restarted;
- **delete and create-folder:** a conflict, not found, and a conflict whose
  path is already gone;
- **auth and transport:**
  - an expired token, refreshed and resent;
  - a revoked token, refreshed and resent once, which answers `unlinked`,
    and again with no request;
  - a refreshed token refused again, and a 403, which answer `unlinked`;
  - a lost delete, a lost upload, and a create-folder conflict whose
    confirmation is refused 403, which answer `unlinked`;
  - `invalid_grant`, which answers `unlinked`, and again with no request;
  - a rotated refresh token, stored before its access token goes out; one
    the store refuses, which stays usable and is stored by the next call;
    and a refresh with no new token, which never runs the store;
  - 429 with `Retry-After`, and 5xx;
  - a 3xx, which is not followed;
  - a non-ASCII path in `Dropbox-API-Arg`.

The fake cuts an answer two ways: after the call takes effect (`LOSE`) and
before (`DROP`). Either way it sends part of a status line and closes, so
libcurl reports a failed transfer instead of resending the request.
