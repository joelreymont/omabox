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
- inotify, for watching the sync root.
- A SHA-256 digest word. `crypto/evp.f` already binds libcrypto's SHA-256, but
  only for HMAC and signatures. Dropbox's content hash needs SHA-256.
- Writing to the Secret Service. `secret.f` on Linux only reads; the Rust
  version runs `secret-tool` as a child process to write. The user's direction
  is to extend Habu instead.

The decision is that these become Habu libraries, not omabox code.

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
