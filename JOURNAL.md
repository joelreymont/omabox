# Rewriting Omabox in Habu: journal

Notes written while the rewrite happens, as material for a blog series on
agentic development in Rust versus Habu. Each entry keeps what was observed
apart from what was inferred.

## 2026-11-15: The starting point

**What the Rust version is** (measured):

- 20,273 lines of production Rust (non-blank, non-comment) in 21 files.
- 15,011 lines of unit tests in those files, and 11,637 lines of integration
  tests, most of them against a fake Dropbox server.
- 2,000 lines of TLA+ in 7 models (`formal/`), checked with TLC.
- Largest modules: `local.rs` 3,964 (filesystem scanning and staging),
  `journal.rs` 3,190 (the SQLite journal), `dropbox.rs` 2,201, `reconcile.rs`
  1,965, `recovery.rs` 1,617, `transport.rs` 1,465 and `install.rs` 1,151.
- Dependencies that do real work: `dropbox-sdk` (types and routes generated
  from Dropbox's API spec), `ureq` with rustls, `rusqlite`, `sha2`, `rustix`,
  `serde_json` and `tracing`.

**How much of Dropbox omabox uses** (counted from the calls in `src/`): 12
routes and one OAuth endpoint.

- account: `users/get_current_account`
- listing: `files/list_folder`, `list_folder/continue`, `list_folder/longpoll`,
  `get_metadata`
- transfer: `download`, `upload`, `upload_session/start`, `append_v2`, `finish`
- changes: `delete_v2`, `create_folder_v2`
- auth: `oauth2/token` for both the code exchange and refresh; the authorize
  URL is built, never called.

Rust gets these routes from a generated SDK that covers all of Dropbox. In Habu
the plan is the reverse: a small vocabulary written for exactly these routes.

**What Habu already has for the job** (read from each library's header):

- HTTPS: `net/curl.f`, libcurl's easy and multi interfaces, with streamed
  bodies.
- JSON: `json.f`, a strict pull reader and an emit-only writer.
- State machines: `fsm.f`, which builds checked words from a table, so a missing
  input or an unknown next state fails at load time.
- A fake Dropbox for tests: `net/http.f`, an HTTP/1.1 server.
- Filesystem safety: descriptor-anchored lookup (`fs-anchored.f`), rename
  without replacing, and file locks.
- `systemd.f` (readiness), `task.f` (threads), `spawn.f`, `signal.f` and
  `log.f`.
- `pg.f` binds libpq through the FFI, which sets the pattern for a database
  binding.

**What Habu lacks** (searched for and not found):

- SQLite, which holds omabox's journal.
- Anchored mutations: `fs-anchored.f` only opens and reads, and omabox also
  creates, renames, unlinks and links through a directory descriptor.
- Extended attributes, which mark omabox's download stages.
- Writing to the Secret Service. `secret.f` on Linux only reads; the Rust
  version runs `secret-tool` as a child process to write. The user's direction
  is to extend Habu instead.

The decision is that these become Habu libraries, not omabox code.

Corrected later: SHA-256 is in Habu's core (`src/core/sha256.f`), and inotify
is not needed, because the Rust daemon rescans after each long poll.

## 2026-11-15: A rule that blocked the work before it began

Habu's `AGENTS.md` said that work which did not help three named applications
"waits", and that any issue those applications met went "before any other
work". Under that rule, every library this rewrite needs would have waited.
The user removed the rule and asked that `AGENTS.md` name no application at all,
since it "guides agents that work on habu" and "should be precise and
concise".

Observation for the blog: agent rule files collect priority rules that made
sense for one campaign. Later they block new work without anyone noticing,
because an agent follows a rule rather than question it.

## 2026-11-15: A bug found by reading the API before porting it

The Rust daemon has failed to upload one 201,752,253-byte file every time since
08:07 UTC. Six of its attempts got as far as the final call of a chunked
upload, and all six failed with "content hash mismatch". Logging showed no
resent chunk and no corrected offset in the last two failures, which rules out
the first explanation tried: a delayed chunk that landed out of order.

- **Observed:** for chunked uploads (files over 32 MiB), the final
  `upload_session/finish` call sends no bytes, yet carries the whole file's
  content hash (`src/dropbox.rs:1191-1196`).
- **Observed:** the generated SDK documents that field as "a hash of the file
  content uploaded in this call".
- **Inferred, not yet confirmed:** Dropbox compares the hash with the bytes of
  that call, which here are none, so every chunked upload fails.

Observation for the blog: the generated SDK gave the Rust code a field that
type-checks and reads naturally, and its meaning sat in a doc comment nobody
read. Writing the Habu vocabulary by hand forces that line to be read.

## 2026-11-15: The vocabulary first

The user's direction was to start with "a tight habu vocabulary, a DSL for
dropbox. this is THE way to start, prove me wrong!" The first attempt got the
order wrong: the whole rewrite went to a design agent, with the vocabulary as
one of its outputs. The user caught it ("did you design the vocabulary first
and give it to the design agent?"). The vocabulary was then written by hand,
shown, approved, and became fixed input for everything after it
(`docs/habu-dropbox.md`).

**What came out** (counted from the design and the Rust source):

- One word per route: 19 words, two structures, one error enum and a reply of
  four cases: `done`, `refused`, `retry`, `unlinked`.
- The Rust side reaches the same routes through 13 public types in
  `src/dropbox.rs` and a 10-case `ApiOutcome`, on top of the generated SDK and
  a 3,680-line `src/transport.rs`.
- The chunked upload is a 6-state table in `fsm.f`. In Rust the same flow is a
  correction flag, an optional transport failure and branches on offsets that
  Dropbox reports, spread over two functions.

**What writing it by hand turned up:**

- The upload bug in the previous entry. The vocabulary leaves the content hash
  off `upload_session/finish`, and checks the committed entry's hash instead.
- A prerequisite that was not one. The draft asked Habu for a connect-timeout
  setter; reading `net/curl.f` showed `LOW-SPEED!` already bounds the connect
  by the stall limit. One Habu change dropped before it was briefed.
- A shared single-flight token refresh, which Rust needs because every task
  shares one token, becomes "each client refreshes its own token and resends
  once". That costs a few extra token calls a day.

**Inferred, not yet shown:** that the small vocabulary makes the sync layer
smaller too. The test is whether `reconcile` and `daemon` can be written
against these 19 words without reaching under them.

Observation for the blog: an agent asked to "plan the rewrite" plans
everything at once, because that is what the words say. The user's
instinct, a vocabulary first and on its own, gave a smaller, checkable
artifact that a person could approve in one reading. Everything downstream
now has a fixed surface to aim at.

## 2026-11-15: What the first two lanes hit

Two workers started at once: the Dropbox client core in omabox, and the JSON
writer mode in Habu. Both stopped within minutes, and neither for a bug in its
own code.

- **A curl handle remembers.** The core's worker stopped before writing a
  line. Habu's `net/curl.f` adds request headers to a list kept on the handle,
  and no word empties it. A client that reuses its handle, to keep its
  connection to Dropbox, would resend every earlier request's headers,
  including an expired bearer token beside the new one. Rust's `ureq` builds
  each request from nothing, so the Rust code never met this. The fix goes into
  Habu as `CURL:RESET`, libcurl's `curl_easy_reset`.
- **A library that is not a library.** Habu's JSON package is compiled into
  the `hb` engine, because Habu's own tools use it. Loading the workspace's
  `json.f` silently loaded nothing, and the tests ran the engine's old copy.
  The brief had said the opposite, from a check that looked in the wrong list.
- **An engine that cannot build its own master.** This machine's installed
  `hb` is 326 commits behind master. A script walked the history: it built
  revision 31 and stopped at 32, a commit that moves a file the build itself
  loads. Habu's bootstrap doc names that case: no revision can stage it, and
  the host needs an engine built elsewhere.

**Observed:** in the worker's own words, the curl handle was "harder than
Rust", while curl's failure classes (`LOST?`, `UNAVAILABLE?`) were easier.

Observation for the blog: in Rust the toolchain is someone else's problem.
`cargo` is current, and a crate is a crate. With Habu, the agent works on the
language's own build chain too. The first hours of an application rewrite
went into the platform under it. That cost falls once per platform gap, and
it lands in the platform, where the next application gets it free.

## 2026-11-15: A person reading the signatures

The user read the vocabulary's signatures and found three faults in Habu's
type notation that the agents had not raised:

- `( ptr upload ptr client -- reply )` reads as four arguments. It takes two.
- In `METADATA ( ptr u8 n ptr client -- reply )` nothing says whether the
  bytes are a string or a buffer, or which string. The checker accepts
  `DELETE`'s path and rev swapped. The Rust code has newtypes for exactly
  these: `CanonicalPath`, `DropboxRevision`, `ContentIdentity`, `AccessToken`
  and `RefreshToken`.
- "The n after pointers smells strongly." A Rust `&str` is one value that
  carries its length.

Decided: a pointer is `^T`, and a string is one stack item whose type carries
its role, so the vocabulary reads `DELETE ( path rev ^client -- reply )`. That
is a change to Habu's type language across about 17,000 `ptr` tokens, and it
is designed before more omabox code is written.

Observation for the blog: writing the vocabulary first put the language's
notation in front of a person before any code. In Rust the type notation is
settled, and the agent's job is to use it. In Habu, the rewrite changes the
notation.

## 2026-11-15: Engines, and checking less often

- **An engine from another machine.** This machine's engine could not build
  Habu's master, so the build started from the spark's engine. Built again
  from master, the engine reproduced the spark's byte for byte (gen1 = gen2).
- **A candidate engine instead of an install.** The two Habu lanes are merged
  into one tree, and an engine built there runs omabox's tests. Habu's suite
  and install run once, at the end.
- **The user cut the checks.** A worker ran a test ten times hunting a flaky
  low-speed timeout. The user's rule since: run only the one check that shows
  the goal moved, and the rest once at the end. The flake is parked in a dot.
- **Reviews found what the tests missed.** The JSON review ran every Unicode
  scalar against Python's `json.dumps` and found a mutant at U+FFFF that the
  tests let through. The `RESET` review found two guards with no test, and a
  comment that left out what libcurl keeps (the cookies).

## 2026-11-15: The request libcurl sent twice

The delete lane's fake dropped the connection after applying a delete, to
test a lost answer. The test still saw an answer: `refused not-found`.
libcurl had sent the same POST again on a new connection, because the reused
one closed before any answer byte. The second delete found nothing to delete.

The Rust version already handles that outcome in `resolve_mutation_error`
(`src/dropbox.rs:1300`): a conflict is checked against `get_metadata`, and a
delete answered "not found" counts as done. The Habu port copied the
confirmation of a lost answer but not of a refused one, because its design
doc said only "lost". The fix follows Rust, and the fake now sends half a
status line before it closes, so libcurl reports the failure instead of
hiding it.

Observation for the blog: the Rust code knew this; the port's design doc did not.
Porting from the doc instead of the code dropped a behaviour that only a test
of a lost answer could show.

The upload lane stopped with six questions before writing code: how to read
the file, what the session table does with other replies, how the fake loses
an answer, where the content hash lives, how to check what Dropbox committed,
and whether a conflict is confirmed. The brief settled none of them. The
answers came from the Rust code (the hash, the commit check, the conflict),
from Habu's libraries (the read) and from the lead (the table, the fake).

## 2026-11-15: The size of `^T`

The type change the user asked for, measured across Habu's tree: 16,678
`ptr` tokens in the sources and tools, 4,263 in the tests, and 12,092
`ptr u8 n` string pairs in 696 files. Every top-level string literal (3,406
lines) needs the interpreter to accept a two-cell value, which it refuses
today.

The plan runs in steps, each built by the engine of the step before:
1. an engine that reads both `ptr T` and `^T` and writes `^T`;
2. one rewrite of the tree to `^T`;
3. two-cell values at top level;
4. an engine that adds `str`, a string as one item;
5. string literals and primitives turn to `str`, with a marker on every file
   that still reads a `str` as two cells;
6. the files move over callees first, each dropping its marker;
7. the marker goes, and nothing on master ever carried it.

A role is a one-field record over `str`: `STRUCTURE rev FIELD text str
;STRUCTURE`. Making one is a cast that emits no code, so the role costs
nothing at run time, and the checker refuses a rev where a path goes.

Observation for the blog: in Rust, `struct Rev(String)` is one line and the
compiler already knows strings. Here the language learns what a string is
before the application can say which one it holds.

