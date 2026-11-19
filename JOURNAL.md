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

A role is Haskell's `newtype`: the same bytes under a type of their own.

```forth
NEWTYPE path str   \ only DROPBOX makes one
DEFTYPE REV str    \ anyone converts: >REV, REV>STR
```

Making one emits no code, and the checker refuses a rev where a path goes.
The first design wrapped a string in a one-field record instead, because
Habu's `NEWTYPE` wrapped only one-cell values. The user asked why a role was
a record, and the answer showed the workaround: a role over a number and a
role over a string would have been spelled two ways. `NEWTYPE` and `DEFTYPE`
now get to wrap a value of any width.

Observation for the blog: in Rust, `struct Rev(String)` is one line and the
compiler already knows strings. Here the language learns what a string is
before the application can say which one it holds. And again a person
reading the notation found what the agents had settled around.


## 2026-11-15: What a fake hides

Three of the five Dropbox lanes found something only because a test or a
review pushed past the happy path, and one found something no test could:
- **A shape the fake never sends.** Dropbox answers `upload` and
  `download` with a file's metadata and no `.tag`, because the route's result
  is a plain record, not a union. The fake always sent `.tag`, so the core's
  entry reader, which refuses an entry without one, passed every scenario.
  The upload lane noticed only because it read the route's documentation for
  its own reader. A fake written from the client's point of view agrees with
  the client.
- **A server that cut the body.** A 32 MiB session append reached Habu's
  HTTP server slower than its 1 s body deadline, so the server closed without
  answering. libcurl then resent the append by itself, which the test read as
  an append Dropbox had stored twice. Raising the fake's deadline fixed the
  test. libcurl's quiet resend had already cost a lane once that day.
- **A rule copied from the wrong side.** Habu's curl wrapper decided where a
  header block ends by its own rule (a blank line), libcurl by another (any
  line whose first byte is CR). The reviewer checked libcurl with the curl
  CLI against a raw server and found the reply that both accept and Habu
  throws on. Rust never met this, because Rust's HTTP stack parses its own
  headers.
- **A race the tests won by luck.** The review measured `HEADERS` throwing
  after the first chunk of a stream that failed early, in 29 of 30 runs. The
  loop reaped a finished transfer before it serviced the chunk, so the
  stream's early headers were already gone. The test that should have caught
  it passed, because its first transfer on a fresh loop was the one in 30
  that won the race.

Observation for the blog: the Rust version leaned on crates that had met
these cases before it did. Each Habu library meets them for the first time,
in the application that needs them.

## 2026-11-15: The language gaps a port finds

Porting the content hasher hit a gap in Habu itself. Dropbox's content hash
runs two SHA-256 contexts at once, and Habu's SHA-256 runs in a context
span the caller owns, 784 bytes. A record cannot hold 784 bytes: a field is
a scalar, a pointer or another record. The worker padded the hasher with
nested records of eight cells each and cast them to bytes. It works, and it
is a workaround, so Habu gets fixed-size inline fields instead. The same need
is waiting in statx results, sqlite and openat2 buffers, and path buffers.

Smaller collisions came from names:
- `hash`, `at` and `again` are reserved inside a record or a machine, so a
  field became `content-hash` and an input became `once`.
- A word named `DROP` in the fake's package shadowed `drop` there, so the
  fake's way to cut an answer before it takes effect is called `CUT`.

## 2026-11-15: Master moves while you work

Habu's master moved 41 commits while the `^T` change was in flight, through
the same checker files. The user's answer was a rule: rebase every open line
onto master periodically. Moving the work showed what drift costs here:
- the installed `hb` could no longer build master, and neither could the
  engine built that morning;
- master held two changes that each needed a staged host, so reaching it
  took two intermediate engines before the `^T` stage could build at all;
- the 21,000-line respell was not rebased but redone, because rerunning a
  mechanical rewrite over the new tree is cheaper and surer than resolving
  its conflicts.

The same day the Rust version left master for a `rust` branch. Master now
holds only what the Habu daemon is built from, and the port docs cite the
branch where they compare.

## 2026-11-15: Stopped all at once

Three times today running lanes stopped mid-brief at the same moment: once a
network outage ended ten of them, twice the five-hour usage limit ended them
all. The second time the reviews moved to Codex, a reviewer from another
vendor, so the review queue kept moving while the lanes waited.
Earlier a weekly limit stopped a Rust-era worker for days. Each lane resumed
from its own transcript on one message ("continue from where you stopped;
check your workspace first"), because its state was in a jj workspace and
its instructions in a brief file, not in anyone's memory.

Observation for the blog: parallel agents fail together. The cost of an
outage is set by how much of a lane's state lives outside the agent.

## 2026-11-15: Three lanes, three log helpers

Three lanes that each needed to check a log line each wrote their own way to
capture stderr: LOGGED, LOGGING/SAID? and a LOGGED buffer. Two fault lanes
each added a fake fault called SHORTEN, meaning different things. The merge
found them; one LOGGED/LOGGED? pair and the name CUT-BODY replaced them.

Observation for the blog: a brief that names the words to change keeps lanes
apart, but it cannot see a helper two lanes will both invent. Merges are
where duplicates surface; Rust's crates would have had one already.

## 2026-11-15: A flag that became a machine

The download's "draining" flag, set in one place and tested in another, was
what the review asked to become a named machine, and it did. Later every
transfer interrupted by a throw got one owner (ABANDONED, READ-OUT), and the
machine lost its own draining and thrown states. The machine got smaller
once the concern that cut across it had a single home.

## 2026-11-15: What the fake hid, again

The fake Dropbox runs in its own task. A scripted answer meant for an API
call could be taken by a token request, so a test could pass on the wrong
exchange; scripts now go to API calls only. A fixture word ran in the test's
task and overwrote the test's task-local string builder while a test was
building in it.

## 2026-11-15: The checker holds no constants

Habu records gain inline byte runs (`BUFFER name N`) for the content hasher's
SHA-256 contexts. N must be a literal, where C accepts a constant expression:
replay builds a record's MAKE and UNMAKE from its text, and the verifier
holds no constant values. Three more things a C programmer never sees:
- MAKE carries a buffer as one cell per eight bytes, and nothing counted
  them, so `BUFFER b $1000000000` used 2 GB before anything refused it. The
  limit MAKE always had is now refused at the clause that passes it.
- An accessor that answers a span needed a new kind of compiled body: none
  of the existing kinds pushes a second constant cell.
- span.f loaded after sha256.f, so SHA-256's own records could not use the
  span type until the boot order changed.

## 2026-11-15: An example that contradicted its rule

My brief for the HTTP date parser stated RFC 9110's 50-year rule for RFC 850
years and then gave an example that broke it (in 2026, `70` means 2070, not
1970). The worker followed the rule. The review then found the rule itself
applied to years, not timestamps, so from 2050 on `20` would read as 2020
instead of 2120.

Observation for the blog: an example in a brief is code that nothing runs.

## 2026-11-15: A decision kept in a test

Habu's CURL:LOST? left out TLS handshake failures (libcurl's 35) on purpose,
and a test asserted it. omabox retries what LOST? accepts, so a connection
reset during the handshake would not be retried, where the Rust version's
reqwest retried every connect error. A failed handshake sends no request,
so retrying it is always safe; LOST? now takes 35 and the test says why.

## 2026-11-15: Where the interpreter meets the checker

At top level a word that carries a record value now runs, but `drop` was
still the engine's one-cell drop, and the checker could only allow or refuse
a word before it ran. Dropping a whole value needed a new word between them
that tells the interpreter how many cells the value takes. A refusal of
`?dup` set a flag that nothing read, so its message named no reason.

## 2026-11-15: Two green lanes, one red merge

Two Habu lanes built the record byte run in parallel. One reserved the word
`buffer` in declarations, so a field cannot be named after the clause. The
other, finding `span` taken, named its new compiler body kind `buffer`. Each
lane's tests passed. Merged, the engine still built, because the host that
built it did not yet reserve the word. The engine it built then refused its
own compiler source, and the test that rebuilds from a cached object caught it.

Observation for the blog: a language that checks names against its own
grammar turns a naming clash between lanes into a build failure, but only
one stage later. A self-build is the check that sees it.

## 2026-11-15: A flake that was libcurl's

One run in about 44 of Habu's curl tests failed a low-speed case: a body
arriving at 64 bytes every 100 ms was ended as slower than 10 bytes a second.
The rules forbid calling that a flake, so a hunt followed. libcurl 8.23 times a
one-second low-speed window in milliseconds rounded toward zero, before its
first once-a-second speed record exists, so a check at 999.x ms sees a speed of
0 and ends a transfer receiving 48 times the limit. The plain curl command line
fails 6 of 6 times with a one-second window and passes with two.

Observation for the blog: the cause sat below both languages. The Rust
version, on ureq, never met it; the Habu version inherits libcurl's defects
along with its features.

## 2026-11-15: Lowercase is not casefold

The upload checks that Dropbox committed the entry at the upload's path. The
port compared paths by case folding; the Rust version compares `path_lower`
with `to_lowercase`. They differ: Straße and STRASSE fold equal but lowercase
apart. Habu's LOWER writes into caller storage, and at that point the client
had none it could grow without moving spans it had already handed out. The
fix was a library word, `UNICODE:LOWERS-TO?`, which lowers, compares and frees
in one place.

Observation for the blog: a port finds where a library's shape falls short,
not only where it lacks a feature. Rust's `String` hides the allocation that
made this a question in Habu.

## 2026-11-15: Halfway: better or worse?

Asked midway whether Habu beats Rust, the answer was: slower for shipping
omabox, because most of the time went into Habu itself (streaming HTTP, HTTP
dates, byte fields in records, `^T`, top-level stack rules, lowercasing),
each a lane and a review where Rust had a crate. The checker and exhaustive
`MATCH` push the code into explicit state machines, and the defects that
pass the checker are the same kind that passed Rust's compiler: getting the
spec wrong, as with Retry-After rules or case comparison. Agents write Rust
from memory; in Habu they lean on the card, slip on Forth details, and
reinvent helpers they cannot find.

## 2026-11-15: Step 2's shape, and Rust as the oracle

Step 2 is seven Habu libraries (SQLite, operations on names under a directory
descriptor, descriptor words, xattr, statx, secret writing, lossy UTF-8)
before any omabox package that needs them. In Rust each was a crate or a
`std` call. The design settled three departures from the plan's wording:
SQLite failures throw one of three codes rather than return a result,
because every journal call passes a failure up and the daemon tells only
corrupt, full and other apart; the anchored calls use `O_NOFOLLOW` on one
checked name instead of openat2, which gives the same property; and there is
no secret erase, because nothing in the Rust version erases the credential.

The planner's table, the JSON of every stored value and the case folding of
paths now come from the Rust version itself: a test-only generator on the
`rust` branch prints them, and the Habu tests read the output in
`src/oracle/`. Hand-written expectations could not show byte identity with
serde. One fold result was a surprise worth a test: `ΟΔΟΣ.txt` lowers to
`οδοσ.txt`, since a sigma followed by `.txt` is not final.

Observation for the blog: porting to a young language makes the old program
the specification, and the cheapest way to read that specification is to
run it.

## 2026-11-15: An undefined word that was defined

On the first engine with `str`, a definition calling `>str` failed with
"undefined word", while `' >str` found it. Two hunts and about 90 tool calls
found the cause far from the symptom. A primitive's row pushed a `str` as one
cell, but the signature parser lays it out as its two. The build checks each
row by writing it out as text and reading it back. The two rows differed, so
the build silently dropped the text, and the run that loads it had no row.
The fix is five lines: a row lays a layout type out as a signature does.

Observation for the blog: Rust's errors point near their cause; here a
silent consistency check turned a type-layout mismatch into a missing word.
A check that drops data on a mismatch should say so.

## 2026-11-15: Seven libraries landed

All seven of step 2's Habu libraries are on Habu's master, each after one
review and one or two rounds of fixes. The reviews caught things the lanes'
own tests passed over:
- once secret writing worked on Linux, the old secret test would have left
  four dummy items in the user's real keyring when run by hand;
- SQLite's statement finalizer dropped its result, but an `INSERT ...
  RETURNING` commits there, so a caller could hold the id of a row SQLite had
  rolled back;
- two suites were gated on a target predicate that is false on x86-64 Linux,
  so they would never have run there.

The lanes kept copying private facts from `fs.f`: errno numbers, the stat
layout fix-up, directory open flags, a file mode. A sealed package cannot
reach another's private words, and the names were not public, so each lane
grew its own copy. The fix was to publish them once in `FS` and swap every
lane onto them, which cost a second round per lane. Rust's `libc` crate has
every errno; nobody writes `17 constant EEXIST`.

One port turned up a hazard in Habu's FFI. A foreign function's symbol is
resolved at its first call, which happens after the caller has cleared errno
and before the C call runs. Habu's own FFI notes that the loader may set
errno even when it succeeds, so code that reads a failure from errno could
misread a successful first call. The fix keeps errno across the lookup.
This machine's glibc never set it, so no test here can fail without the
fix. Rust binds its symbols when the program loads, so it has no such
window.

A build-tool bug showed up the same way. When a build died while its link
was opening, hb-build reported "the build ended the process before its
first file" and named no stage. That was filed as a bug, and within the hour
the first staged `str` build printed exactly that line. The cause was an
engine that did not yet know the new type: the commit has to be built in
two stages.

## 2026-11-15: Rows first, landed as a stack

The `str` plan above changed in two places. Its step 6 moved files over
callees first. Instead, one mechanical commit flips every signature,
literal and string keyword to `str`, and marks every file with `split-str`.
Then any file can move in any order, in parallel, because a move changes no
signature. Its step 7 said nothing on master ever carried the marker. The
user chose to land the line as a stack, each commit built by the engine of
the one before it, so the marker appears in master's history but never at
its tip. A pair that is a buffer and its capacity stays `^u8 n`, and so do C
bindings. The `str` type and the wide `NEWTYPE`, `DEFTYPE` and `CAST:` land
first, on their own.

## 2026-11-15: Wide types, and where a file ends

`NEWTYPE path str` reads its base from the rest of the name's line. Eight
test lines already put a statement after a `NEWTYPE` name, so each got a
line break. Reading a base needs the structure declarer's field code, which
loads after the file that held `NEWTYPE`, so the word moved files. A Forth
word sees only what loaded before it; Rust resolves a module's names in any
order. `DEFTYPE REV str` makes `>REV` and `REV>STR`; the buffer that spells
those names was 512 bytes, which a long name over a base would overrun, so
its size now comes from the name limit.

The `split-str` marker was to last "to the end of the file". The engine had
no such unit: the linker runs a file in parts, and a file can evaluate a
string that loads another. Saving the marker per evaluated frame lost it
between parts and let a nested load clear its caller's. The rule now reads
it from the file's first line, for every part, and an evaluated string reads
with its file's marker. The verifier, which scans sources rather than loading
them, does the same.

Making `str` a type broke one test in the `str` commit itself: `NEWTYPE
str<a>` now meets a duplicate rather than a reserved name. That lane ran
only the suites its brief named, so the next lane found it.

Observation for the blog: in Rust a wrapper over a string is `struct
Path(String)`. Here it took four commits (the type, a cast of any width,
`NEWTYPE` and `DEFTYPE` over a base) and a marker so that code written for
the old pair still checks. Each lane took five to eight minutes.

## 2026-11-15: Lanes in parallel, and names that collide

omabox had been waiting for the `str` stack to land. Now its lanes run on
that stack's engine before it lands: MODEL, CONFIG, STATUS and the Rust
journal sample ran at once, then JOURNAL and MODEL's JSON. The STATUS lane
took 12.5 minutes, MODEL 10, and the journal sample 5.

Building the rebased stack failed with `E-EXPORT-UNDEFINED`: master's new
`export` rule needed an engine that already had it. Habu builds itself, so
a language change needs a staged host: an engine for the export change, one
for `str`, then the tip. Cargo builds any tree with the pinned compiler.

Habu refused three of MODEL's names. A `VARIANT` may not share a name with
a type, and Rust's `Decision::Conflict(Conflict)` and
`Observation::Unknown(UnknownReason)` do just that, since Rust keeps types
and variants apart. The types became `unknown-reason` and `blocked-reason`,
after Rust's, and the decision's variants `conflicted` and `collided`. Two
`ENUM`s may share a variant name.

`DERIVE eq` refuses a record holding a `str`. A derived equality compares
cells, and a `str`'s cells are an address and a length, so it would compare
identity, not bytes. Rust's `#[derive(PartialEq)]` on a `String` compares
bytes. MODEL writes its six `=` words by hand.

An independent review of the `str` stack found no unsound case. It found
comments that told history, a marker saved and restored twice, a test that
read an internal cell rather than behaviour, and two limits of `split-str`:
a marked file's diagnostics print a `str` as `^u8 n`, and a file read from
stdin cannot carry the marker.

## 2026-11-15: Baked libraries, borrowed flags and stored JSON

The JSON lane stopped at its first `JSON:WRITE-U64`. The word was on
Habu master, but `json.f` is built into the engine, and a `require`
of a file the engine already holds loads nothing. The words were in the
source tree but missing from the running engine, until the engine was
rebuilt (8 s). In Rust, a new library function is available once the
crate builds; here the library and the engine are released together.

Rust's integers come in widths; Habu's cell is one signed 64-bit word.
A file's inode is a `u64`, and serde writes one at or above 2^63 as a
20-digit number. Habu's JSON gained `WRITE-U64` and `READ-U64`. The
review of that lane found the reader's overflow check used a signed
compare, so a total above 2^63 wrapped; a failing test showed it before
the fix.

Habu refused `block-reason` as a name: `block-` is a reserved prefix.
Rust's BlockReason became `blockage`. In CONFIG the type `lock` collided
with a private variant `lock`, renamed `daemon-lock`. Three lanes so far
have renamed something because Habu has one namespace for types, variants
and words, where Rust has several.

The JSON readers need a seed value and a typed `drop` for each type. A
checked `catch` must leave the stack the same shape whether the code
threw or not, so each reader is given a placeholder value of the type it
reads. Rust's `?` returns early instead and needs no placeholder.

Rust's file code gets its flags from the standard library
(`OpenOptions::create_new`, `custom_flags(O_NOFOLLOW)`). Habu's file
words do not yet cover everything the daemon needs, so the CONFIG lane
bound `open`, `mkdir`, `chmod` and `flock` from libc itself. Those
bindings belong in Habu's library; the review decides where.

Habu's anchored path walk opened every directory on the way for reading,
so a parent the user could enter but not list stopped the journal's
root check; the kernel's own lookup needs only search permission. The
walk now opens the directories in between with `O_PATH`. Habu also
refuses a symlink anywhere in an anchored path. Rust's status file
follows one in `$XDG_RUNTIME_DIR`; its sync root, opened with
`RESOLVE_NO_SYMLINKS`, does not. I first kept the stricter rule for both;
the STATUS review showed that a runtime directory reached through a link
(`/var/run` links to `/run`) would then publish no status at all. Habu now
does as Rust does: the runtime directory opens through its links, and the
sync root and every path inside it refuse them.

Lane times: STATUS fold 5.5 min, CONFIG lock 8.5 min, MODEL JSON 16 min
(stalled on the engine), the anchored walk 3.5 min.

## 2026-11-16: Workers that read the source, and one namespace again

Briefs name the Rust lines to port and the Habu words to use. Twice the
worker found the brief wrong before writing code. A Habu lane sent to
widen a stat field found the field already as wide as the kernel gives
it, and stopped; the lane was retired unchanged. The rotation lane found
its brief had no room in the fake Dropbox server for a rotated token,
and stopped to ask. Stopping costs a round trip; guessing would have
cost a review.

Rust's `str::to_lowercase` applies Unicode's Final_Sigma rule: a capital
sigma at the end of a word lowers to `ς`, elsewhere to `σ`. The C library
Habu lowers with, libunistring 1.4.2, picks the wrong one after an
apostrophe, so `ΓΙΑΝΝΗΣ'S.doc` got a different journal key than the
Rust daemon stored. Habu's `UNICODE:LOWER` now applies Rust's rule
itself. The MODEL review found it by reading the journal's keys against
Rust's, not by a failing test.

Habu folds case in names, so `FD:DUP` was the same name as the
primitive `dup`; it became `FD:DUPLICATE`. JOURNAL's five lanes then
merged into one file with three private words defined twice
(`ENCODED`, `DIRECTORY?`, `HOLDS?`), two JSON encoders and two
decoders. Rust would have kept both encoders apart in separate modules
or as methods on different types, and the duplication would have stayed
hidden. Habu refuses a second definition in one wordlist, so the merge
did not load until one encoder and one decoder were chosen. That is
the fourth rename forced by Habu's single namespace, and the first time
it caught duplicated logic.

The rotation review compared the Habu state machine against Rust's,
transition by transition. Rust ends `Rejected` only by building a new
`TokenState` at a new login, so Habu's code exchange now resets the
phase to ready. A token store that calls back into its own client
deadlocks on Rust's mutex; in Habu it read a buffer the inner call had
regrown and died with a memory fault. Neither daemon does that, and the
doc now says the store must not use the client.

Habu's file words leave errno for the caller to log; its xattr, statx
and SQLite words log the failure themselves, as the card says. LOCAL
logs what FS hands it, so an xattr failure was logged twice.

Lane times: FD errno 4 min, the directory open 2 min, the lock file 5.6
min, final sigma 4.8 min, STATUS fold 2.6 min, JOURNAL parts 4 and 5
6.8 and 6.4 min, MODEL fold 1.5 min, LOCAL stage 9.8 min, AUTH 8.7 min,
CONFIG fold 8.6 min, the JOURNAL merge 11 min over two rounds. Reviews
take longer than lanes: CONFIG 16 min, MODEL 17 min, rotation 14.6 min.

## 2026-11-16: Option payloads, error codes and one lock fewer

Rust's `InstallOutcome::PreconditionChanged { actual: Option<ContentIdentity> }`
could not be written. A Habu STRUCTURE field takes `option<DROPBOX:hash>`,
but an ENUM payload does not: its declaration parser resolves only bare
names, while STRUCTURE has a full parser for applied types. Two LOCAL
lanes hit this within minutes of each other. Both stopped to report it
and offered the same three workarounds: wrap the option in a structure,
add a type parameter with only one use, or split the variant in two.
Instead, Habu now lets ENUM call STRUCTURE's type parser, so the outcome
stays one variant with an option payload, as in Rust. The first worker
on that change also stopped. The parser it was told to reuse was
private, and it read STRUCTURE's own declaration state, so reusing it
needed an entry point nobody had named. Rust never hits this, because
an enum variant takes any type a struct field takes.

Rust's reconcile asks `upload_source_changed(&error, path)`. That
function matches the error's variant, its path and the name of the
operation that failed, and it decides whether a failure means "look
again" or "report it". A Habu throw carries only a number. Two stage
races share E-CHANGED with a source race, so no test on the code could
tell them apart. In Habu the throw site decides: the source's open and
the race checks on the source now throw E-SOURCE-CHANGED, and the
caller compares that one code. Rust reconstructs the classification
after the fact from data carried in the error. Habu picks it where the
failure happens, so the classifier function goes away.

Habu's card says the library that sees an external failure logs it
once, just before it throws. Rust logs at the boundary, so a race the
caller handles leaves no trace. In Habu the same race leaves one error
line before the caller treats it as routine. The two daemons'
journalctl output differs here, by design on each side.

`SyncRootAccess` is an `RwLock` that keeps Rust's parallel download
workers out of the way of a scan or a root mutation. Habu syncs on one
task, so nothing can run beside a mutation, and the lock was not
ported. Its six `_with_access` functions became the plain ones, and two
Rust tests of the lock have nothing left to test.

Rust marks test-only journal methods `#[cfg(test)]`. The Habu port put
two of them in production code, because a Forth file has no such mark.
They now live in `src/test-journal.f`, beside the fake Dropbox server
in `src/test-dropbox.f`, and REPLAY's tests will share them.

MODEL and AUTH each built serde's struct read: an object's member must
be present exactly once, and unknown members, repeated ones included,
are skipped. Habu's JSON library had two of the three pieces, but its
repeated-key check refuses unknown repeats, which serde accepts. That
whole rule is now one JSON word, and both packages call it.

Five LOCAL lanes started from one base and ran in parallel. Each one
wrote its own private JOIN for paths, so there were five definitions
with four behaviours. One of them, borrowed from a Habu file-system
word, turned an empty parent into an absolute path. Two lanes also
named two unrelated words STAGE-IN. Each lane loaded and passed its
tests alone. The merge is where it showed: a package has one wordlist,
so a second definition of a name is refused. The merge worker stopped
with seven such names. In Rust, `Path::join` comes from the standard
library, so no lane writes one. The two STAGE-IN words were helpers the
workers named; the Rust functions they serve, stage_upload_at and
stage_download_at, already had distinct names.

## 2026-11-16: JOURNAL lands, and a refusal that was right

JOURNAL landed as a stack: five lanes, their merge, the recoveries and
four review folds. It ports fifty-one of journal.rs's tests and two of
daemon.rs's under their Rust names. One fold dropped a plan's delete
from RETIRE, and no test noticed. The next fold added checks of the
live plan rows, and a run with the delete removed showed they fail.
A passing suite said nothing about that line until a test looked at it.

Habu's jj config marks no commit immutable. Retiring a workspace
abandoned its working-copy commit, which had already landed, and jj
rewrote fourteen commits, master among them, in the local repository.
Nothing had been pushed, and `jj op revert` undid it. Now a workspace's
commit is abandoned only after `jj log -r '<ws>@ & ::master@origin'`
comes back empty.

A Habu test had to wrap `OPTION:NONE` in a word declared
`( -- option<edapw> )` before passing it where a two-cell payload's
option was wanted; inline, the checker refused it. A worker traced the
refusal and found it sound. Habu fixes a value's width where the value
is built, and `none` has no payload to size it, so only the enclosing
word's declared output can. Binding the type later only moved the
refusal to a stack underflow. Rust sizes `None` from the whole
function's inference, and the question never comes up. The fix belongs
to Habu's one-pass compiler work, whose dot now holds the trace. Until
then a one-line typed word is the way to write it.

Rust's exclusions are thirty lines in their own module. The scan lane
ported them as private LOCAL words. REPLAY and RECONCILE need them on
plan paths, so they moved to MODEL ahead of LOCAL's landing, and REPLAY
could start without waiting for LOCAL.

Lane times: the LOCAL merge 9.6 min with its decisions in the brief
(the first merge worker, without them, stopped on seven names); the
checker hunt 7.3 min.

## 2026-11-16: An answer at another path, and a body pulled

Dropbox can answer an upload with an entry whose `path_lower` is not
the path's lowercase. Rust reads that as an answer it cannot trust. It
asks get_metadata, and if the path still differs it rejects that one
path with PathMismatch. The Habu port threw E-ANSWER, which ends the
sync pass. The next pass meets the same plan, so one such file would
stop all unrelated work. It is now confirmed the way a lost answer is,
and a mismatch refuses only that path. The review of that fix found a
hole in the machine. A `done` at another path moved to `confirming`
through a row with no action, so the run's last reply was still
`done`. When the confirmation then failed to find the file, the upload
answered done. One action that sets the reply to retry closed it. In
a table the gap shows as a `-` where an action belongs. In Rust the
same mistake would be a match arm returning a stale variable.

Rust's DROPBOX answers a mutation with MutationOutcome: applied,
precondition changed, pending or rejected, each with the remote path's
state. Habu's DROPBOX answers a reply (done, refused, retry,
unlinked), and the design document leaves mapping a Dropbox tag to
sync behaviour to the sync code. So REPLAY owns Rust's mutation
vocabulary and builds it from DROPBOX's reply and its last entry. The
client knows nothing of plans.

Habu's DOWNLOAD pushed each chunk to a sink. LOCAL's stage words pull,
through a reader `[ ^u8 n -- n ]`, as Rust's do through `Read`. LOCAL's
words had four other callers and DOWNLOAD's sink had one, so DOWNLOAD
now pulls too. Two things surfaced. The body now runs inside the
transfer, so it can throw after the read that ended it. The one place
that cancels a transfer on a throw would then cancel a finished one,
and curl answers that with E-STATE in place of the body's code. It now
cancels only a transfer still in flight. The second is a transfer lost
mid-body. A Rust `read` returns `Err`, and the stage words keep that
apart from end of file. A Habu reader answers a count, and 0 means the
end. A lost transfer answered as 0 would reach LOCAL as a short file
and fail its hash check, logged as a content mismatch. So the reader
throws a private code, LOCAL's cleanup passes it through, and DOWNLOAD
answers a lost transfer, as Rust's DownloadBody does.

The pulled body then met the checker. DOWNLOAD handed its body
quotation a reader quotation that read the fetch from a local. Habu
refuses to pass such a quotation into a quotation parameter that is
executed, because it cannot know the callee will not keep it. Passing
one to a named word is allowed, because a word's use of its input is
inferred. So the body now receives the fetch itself. The reader is a
public word, READ-BODY, and the caller wraps it in a quotation in its
own named word. That is Rust's shape too, where the body is a value
that implements `Read`. The language has no way to declare a callback's
quotation input borrowed, and that is what cost the extra public type.

The stage-name fold hit the same limit as `upload_source_changed`
before it. LOCAL threw E-OCCUPIED both for an object at a stage's name
and for one at the destination. A Habu throw carries only its code, so
the caller could not tell which was blocked. Rust's plan blocks the
stage alone and goes on. The stage name's case is now an outcome,
destination-occupied, and no longer a throw.

LOCAL's review found tests the port had weakened or never ported, and
two lanes restored them in parallel with the five code folds. One
restored the weakened checks (eighteen), and the other ported nine
scan tests Rust has. Seven lanes ran at once from one base; their merge
is a separate lane, with the interactions each pair has written into
its brief.

Lane times: the path-mismatch fold 4.2 min; REPLAY's local conflict
copy 4.8 min; REPLAY's local replay 6.6 min; the pull lane's first
worker 3.9 min before it stopped on the cancel question.

## 2026-11-16: A state the machine did not have, and decisions made low

A review of the pulled download reproduced a defect with a fake fault:
the server sends the head and 10 of 26 bytes, then holds the
connection. A body that returns without reading made DOWNLOAD throw
curl's E-STATE where it should answer done. The body's caller had
cancelled the transfer, but the machine stayed at `streaming`, so the
receive step went on to capture the headers of a transfer the cancel
had released. The answer step then inferred "cancelled" from
`streaming`. The existing test passed only because its whole body had
already arrived inside curl. The fix is one final state, `cancelled`,
and one row. The inferred state was the smell CLAUDE.md names, a flag
read in one place and set in another. Once the table named it, the
fix was obvious. No test had sent a body in two chunks, so a mutant
that dropped a reset of the bytes taken survived every case; a fault
that pauses after 10 bytes now kills it.

A download that fails its range, length or result checks used to
throw E-ANSWER, the code every other unparseable answer throws. Rust
maps those to DownloadVerificationFailed, which the caller turns into
a block on that path. A Habu throw carries only its code, so a private
code, E-UNVERIFIED, marks this case. DOWNLOAD catches only that code
and answers `refused unverified`, a reply the caller can match. This is
the third time the code-only throw has turned a Rust error variant into
an outcome. The stage name in LOCAL and the upload source were the
first two.

The same limit stopped the lane that binds LOCAL's scan to the active
root. Rust's root_stood_in takes JOURNAL's missing-birth-time error
late and compares the inode it carries. Habu's JOURNAL logs that
refusal before it throws, and the throw holds no inode. Porting the
Rust shape would have logged an error for every stand-in that LOCAL
then calls a root change. JOURNAL now has a descriptor form of its root
inspection that decides the stand-in before anything logs, so LOCAL
asks one question and gets an option. Rust passes structured errors up
and decides late. Habu's rule that only failures nobody converts get
logged pushes each decision down to where the data is. The API came
out smaller.

Testing every failure turned up a gap the Rust version has too: its
prune of expired recovery payloads skips a corrupt payload but stops on
an unreadable one, and it runs inside every reconcile pass, so one
unreadable file would end every pass. The Habu port keeps it like a
corrupt one. This is a deliberate departure, and AGENTS.md's rule
requires it.

Lane times: the cancelled state 8.8 min; downloadability and the path
check 5.1 min; case-variant renames 5.4 min; root binding 1.4 min to
its stop, then 5.6 min; LOCAL's failure tests 9.1 min.

## 2026-11-16: 41 ms of Nagle, and a file Dropbox describes in part

A review of the download cancel noticed that every call to the fake
Dropbox after the first took about 41 ms. A worker given only the
measurement and a hypothesis found the cause in Habu's HTTP server,
not in omabox. It writes a reply's head and body as two writes, and it
never sets TCP_NODELAY. The body then waits for the client's delayed
ACK of the head: the classic write-write-read stall. The first request
on a connection escapes it because Linux ACKs at once at first. The
worker had no strace or tcpdump, so it proved the cause three ways.
Patching only NODELAY took a call to 0.2 ms, and so did sending head
and body in one write. The kernel's delayed-ACK counter rose once per
slow request and stayed flat under either patch. The report and a
40-line reproducer went to Habu's owner. A suite that takes 41 ms per
call hides this well: it looks like a slow test, not a bug.

The same review found that Habu's listing throws when Dropbox lists a
downloadable file with no content hash. Rust records that file as
"incomplete" and goes on. In Habu, one such file would have ended every
pass. DROPBOX now hands the file to the caller as it came, and a public
COMPLETE? says whether it is whole. Deciding what an incomplete file
means is sync's job.

Two lead slips are worth recording, because jj caught both. A script
that folded review comments into four commits passed `-q`, which jj
does not take. Every `jj new` failed, so all the edits landed in one
working copy; `jj diff --stat` showed it before anything moved, and
`jj restore` undid it. Then a rebase of REPLAY's line started one
commit too high. REPLAY's base commit had never reached master, and
every commit came back with "2-sided conflict including 1 deletion".
`jj op revert` of that one operation put the graph back, and the rebase
from the right root had no conflicts.

Lane times: the renames review's fold-ins 1.4 min; the Nagle hunt
4.5 min; the three-commit DROPBOX review 13.1 min; the renames review
8.4 min.

## 2026-11-16: A clean rebase that was wrong

REPLAY's line, fourteen commits, was rebased onto master. Master had
gained seven commits in the meantime. The rebase had no conflicts, and
all 474 of REPLAY's checks passed. It was still wrong. One of master's
commits had DROPBOX hand an incomplete file to the caller, so METADATA
now answers `done` for a file without a rev or a well-formed hash.
REPLAY's state read took that entry as a whole file. Neither the checker
nor a test said so. The lead found it by reading the doc lines that
commit changed and then each REPLAY word that reads an entry.

Rust puts the same fact in a type. complete_remote_file answers
`Option<RemoteFile>`, so every caller handles `None`, and a change in
what may be missing shows up as a compile error at each caller. In
Habu, the entry is a record of spans, and COMPLETE? is a predicate the
caller has to remember to ask. The fix is two checks. A read-back
incomplete file blocks only its plan; Rust ends the pass there, which
under this repository's rule would meet the same entry on every pass.
An incomplete upload answer is read back, as Rust does.

The rebase itself ran while a worker was still building on the old
line. `jj duplicate` put a copy of the fourteen commits onto master
without touching the originals. The copy was checked and taken as the
new base. The worker's one commit then moves onto it when it reports.

Merging REPLAY's five lanes also brought back the namespace collisions
of earlier days. Lanes wrote private helpers with short, generic names:
SAMPLE, STATUS-OF, FINISHED, NO-STAGE, HELD. Two of them collided in
one package. Each was renamed at the merge (FETCH-SAMPLE,
NO-UPLOAD-STAGE, BLOCK-OF). Rust scopes a private function to its
module. Habu scopes one to its package, and REPLAY's package is 2,100
lines long.

## 2026-11-16: One example outweighed the rule

The user asked why a line read `DROPBOX-ERROR:reset`. Habu's guide
says that generated words are uppercase, and the engine itself spells
a variant's constructor `PKG-FAMILY:MEMBER`. But the guide's only
worked example spelled one `TCP4-READ--RESULT:data`. Every agent
copied the example instead of the rule. Omabox had 353 lowercase
constructors on master and more in every open commit; Habu's own
library had 478. Nothing flagged them: Habu folds case when it looks a
word up, so both spellings compile. Rust's compiler warns on a
lowercase type or variant name, so the rule enforces itself there.

The fix was a rule stated once in the guide, the example corrected,
and a script. The script uppercases a `PREFIX:tail` whose prefix is a
declared family's constructor namespace and not a package. A package
prefix such as `DROPBOX:reply` is a type and stays lowercase, as do
locals and stack effects. jj made the 41 unlanded commits cheap to
fix: each was rebased onto the swept master, and its tree was set to
the script's output on its original tree. That took 11 seconds, with
no conflicts beyond one JOURNAL merge, and the open lines of work
never noticed.

## 2026-11-16: a rate-limit stall, merge clashes, and what 403 means

A usage limit stopped every agent mid-round. Nothing was lost: each
worker's state was its jj workspace, so the round restarted from the
same commits once the limit reset. The cost was wall time, not work.

Two lanes wrote RECONCILE's first words at once, the known-path merge
and the case-collision rename. Each named its private helpers well on
its own, and the merge then refused to load: Habu keeps one namespace
for a package's private words and refuses a second definition
(E-DUPLICATE-DEFINITION, the first at `PATH$`). Rust would have
accepted both as items of two modules. The fix was mechanical (drop
the true duplicates, rename the rest), but it is a cost of parallel
lanes in one Habu file that Rust's module system hides.

A brief of mine asked for a test of a download Dropbox answers 403.
The worker found that DROPBOX maps 403 to `unlinked` on every route,
so it can never be a path's failure, and tested 404 instead. Habu's
total MATCH over the reply made the mapping easy to read off; the
mistake was the brief's, written from memory of HTTP rather than from
the code.

The checker refused a generic `observation<a>` word over local and
remote observations, so the lanes wrote one word per side. That is
more text than Rust's generic function, and the price of a checker
that does not yet instantiate generic words.

The user settled what a denied local write does: "it should rca and
troubleshoot. then probably stop the whole thing, yes." The pass ends,
as Rust's does, but only after Omabox says which directory refuses
the write and why. Rust ends the pass with the errno alone.

Porting Rust's tests under their own names, one assertion for one,
found two gaps in DROPBOX's downloads that its own tests had missed.
Rust checks a download's content hash against the plan's; Habu's
DOWNLOAD was never told the hash, so a resume answered with another
file's hash was staged. And DROPBOX checked a body's length only after
the reader returned, so a short body reached LOCAL as an early end of
input (a read error with errno 0) and a long one as a local change.
I had guessed that DROPBOX threw while reading the body. A worker
traced the throws and showed the guess was wrong: the early 0 came
from `READ-BODY`. Each gap was a whole class of answer that Habu's own
tests never sent. Rust's test suite was a better specification than
the Rust code's comments, and porting it name by name is what found
these gaps.

## 2026-11-16: a check the port's timing dropped

Rust's replay step hands each download to a background pool and
installs it at the next step, after that step has checked that the
configured root is still the one the journal knows. The port runs each
download inside the step and installs it at once, which the design
chose so that nothing is in flight between passes. That choice
silently dropped the check: the root was checked once, before the
downloads, and a download can run for minutes. I found it while
reading Rust's root-swap test to brief its port, before any test had
run. In Rust the check lives in the timing of the control flow; in the
port it had to become explicit, and the fix was two rows of the
download machine's table: a staged state that senses the root, and a
final state for a root that changed.

Porting tests written for a background pool to one task needs a new
form for each, not a translation. Rust's `drive_replay` polls until
the pool settles; one REPLAY-STEP call does the same work. A download
held open by a gated fake becomes a plan whose binding is still live.
A root swapped while the gate is held needs the fake to run the swap
on its own task during the download.

The six-input limit on a word shaped a data structure. The worker
could not build one record per download (seven fields), so it built
one record per step and set the plan and operation before each run.
Rust's struct literal has no such limit; Habu's rule pushed the code
toward one mutable context, which the machine then owns.

The private namespace clashed again, this time between the code and
its test file: the test file reopens the package, so a new `PATH-OF`
in reconcile.f met one already in reconcile-test.f. And a brief I
wrote from the design left out an export the design had settled; the
worker got the addition mid-lane. Briefs written from memory keep
costing a round.

Refreshing the shared engine to Habu master took 9 seconds to reach a
fixpoint (generation 2 matched generation 1), then 114 seconds for
Habu's 285 suites to qualify it.

## 2026-11-16: a denied write explains itself

A denied local write now ends the pass with one line that names the
call, the path and the errno's text. It also gives the mode, owner and
attributes of the directory and of the entry, and the uid Omabox runs
as. A user reading it can see why the write was refused without
running `ls -l` or `id`. Rust's line gives the errno alone. Habu had no
words for any of these facts, so the work began in Habu's library:
statx's permission fields, the effective uid, the path behind a
descriptor, and an octal number of fixed width. Omabox then used them
at each call in LOCAL that makes, links, renames or removes a name, and
at REPLAY's payload removal.

The checker cannot see that a quotation always throws. MOVE-FAILED
answers a stage outcome and ends by running its `fail` quotation,
which throws. Because the quotation is typed `[ -- ]`, the word looked
as if it answered nothing, so a throw that never runs follows it. A
word whose body ends in `throw` is already known not to return; a
quotation is not. Rust has `!` for this.

The feature review mutated the code and found four behaviours that
every test would still pass with the code wrong. One was a failure the
caller converts, which must log nothing; another was the order of the
two directories in a refused rename. Each fix was a test that fails
under a named mutation, and the worker ran each mutation to show it.
The review also found a directory open on a write path still giving
the old line, which made the file's header sentence false. My brief
for one test put a download slot in the wrong directory. The worker
probed the real line, found the slot and the stage in different
directories, and stopped. That made a better test, because the order
of two different directories can be checked.

Name clashes cost three more rounds in one day:
- Names are case-insensitive, so a planning word called `HOLD` hid
  Forth's `hold` inside the package.
- An enum variant cannot share a structure's name, so the pass state
  `planning` had to become `deciding`.
- The test file reopens the package, so `RECORD` and `RECORDED?`
  were already taken.

None of these is a defect. They are what one flat namespace per
package costs, where Rust has modules, scoping and case.


## 2026-11-16: ten test lanes, and the four defects they found

RECONCILE's pass is one word, PASS. A machine of six states runs it:
settle, recover, observe, list, decide and apply. Rust's evidence for
the pass is its tests that run `reconcile_once` against a fake Dropbox
server. I split them by theme into ten lanes, and ran them all at
once. Each lane took 7 to 12 minutes. Seven came back green. Three
stopped, each on a defect in code that had already landed with its
own tests. Sixty tests came across under their Rust names. One has no
port: it checks that a download still in flight does not stop the
next poll, and in Habu no download is in flight between passes.

The four defects were in DROPBOX and REPLAY, not in RECONCILE:
- Before deleting a folder, REPLAY listed it recursively, with no
  limit, reading every page. Rust lists one entry and stops.
- get_metadata never asked for deleted entries, where Rust's
  verification does.
- A refused conflict was verified twice, once in each layer. Rust
  verifies it once.
- An upload answer that did not parse threw out of the upload. Rust
  takes such an answer as an upload that may have applied, and checks
  it.

DROPBOX's and REPLAY's own tests passed throughout. They check what
each word answers. Rust's fake-server tests check the requests
themselves: each body, and how many of each. The port kept those
asserts, so the defects showed. When a rewrite splits one Rust module
into two layers, each layer's tests can pass while the two together
send what Rust never sent.

Merging was the cost. Habu gives each package one flat namespace, and
the test file reopens the package. So every lane's helpers met every
other lane's at the merge:
- Rust's `seed_baseline` came back four times, under four names.
- REOPENED came back three times, PLANNED-OPERATIONS twice.
- The fake gained seven overlapping recorders of request bodies.

In Rust these helpers sit once at the top of the test file, and every
test shares them. Here, the lanes could not see one another's
helpers. Identical copies were deleted, and copies of a different
shape were renamed within their lane. A cleanup lane will fold what
remains.

Two clashes compiled without a word. One lane's DELETE-SENT, a word
that records a request, met another lane's DELETE-SENT, a buffer.
Habu takes the later definition for every word compiled after it and
keeps the earlier one for the words before, so the fake ran
correctly with two meanings for one name. Only a script that lists
every name defined twice caught it. Rust would have refused to
compile.

The merges were scripted, and the script had its own bug. jj writes
the same kind of conflict in two marker orders, so the script had to
read both. Its test for SERVED's list of cases matched any block
holding "PASS-CASES" and a quotation. One block held a whole lane's
section, and the script swapped 2,600 lines for six. The file's line
count gave it away before a run did; the run would have stopped on
the first group of cases that no longer existed.

Departure 2 (a download installs within the step that plans it)
changed what one Rust assert could see. Rust holds the download open
and reads the pending plan's operation. Here the plan has already run
by the time the pass returns, so the port asserts what it did instead:
it downloaded rev-new, then installed over the kept bytes without a
conflict.

## 2026-11-16: the feature review, and a one-second stall

One Fable review read all 3,870 lines of RECONCILE against Rust and the
design. It found nothing critical: no deletion inferred from uncertain
state, no conflict payload dropped, no crash window that loses data. It
found six low issues, and they show what this port's mistakes look like:

- **Two comments were Rust's, copied word for word.** One praised a
  "bounded batch" shared by startup and replay. Habu has no pool, so it
  has no batch. A port can carry over the explanation without the
  thing it explains.
- **Two layers classified the same answer.** DROPBOX confirmed an
  upload answer it could not trust with its own get_metadata. When that
  check failed, it answered `retry`, and REPLAY then stopped the whole
  pass. Rust verifies once and classifies that one path. So one path
  whose answers kept failing that check would stop every pass, against
  the rule that bad input must not stop unrelated work. The fix deletes
  DROPBOX's confirmation (GONE, MADE and the `confirming` state) and
  lets REPLAY read the path back once, as it already did for a
  conflict.
- **Each lane wrote its own tie-break.** Five sort comparators each
  spelled out "then by index", although a word for it already existed
  2,700 lines further down the file. That is the same thing the test
  lanes did, here in production code.
- **A lookup grew with the square of the account.** Every download
  scanned every pending plan, which costs nothing in the tests and
  everything on a first sync. Rust used a map. The Habu version now
  sorts once and searches.

The slowest suite, dropbox-test, took 27 s where every other suite takes
1 to 4 s. A worker hunted the cause with timers instead of guesses:
- the client read its stage in 7 ms;
- the fake hashed a 32 MiB chunk in 25 ms;
- the server took 1,207 ms to read the body, and one wait inside that
  took exactly 1,000 ms.

libcurl sends `Expect: 100-continue` on any body over 1 MiB, then waits
up to a second for the server's `100 Continue`. Habu's HTTP server never
sent one. Rust never saw this: its HTTP client never sends Expect, and
its fake ran on a server that answers it.

The fix belongs in Habu: answer the expectation when the handler first
asks for the body, as RFC 9110 says. A 32 MiB POST went from 1,180 ms
to 153 ms. The same measurement turned up a second cost. The server
parked on its event loop before every 8 KiB read, even with data
already waiting. Reading first cut a call from about 125 ms to about
47 ms.

With both fixes in Habu, dropbox-test fell from 26.7 s to 2.9 s.

Habu's review of the read-first change found one cost. The server used
to wait before every read, and each wait was also the point where a
halted worker stopped. Reading first skipped those waits, and with them
the stop. A peer that kept the socket full could then hold a halted
worker until its body deadline. The fix checks for a pending halt after
each read that finds data. Remove a wait, and you may remove a place
where the program stops.

Rewriting onto your own HTTP stack finds the corners a mature one
already covers. Here the find came from a timer, not from a
stack trace.

The review's classifier finding came back twice more. Once DROPBOX
stopped confirming a lost answer, the worker noticed a 5xx was still
`retry`. Rust counts every failed mutation but a rate limit as maybe
applied, and reads the path back. So did a lost session start, an append
lost twice and a session gone twice. Each stopped every pass. One rule
now covers them all: a mutation answers `retry` only when Dropbox asks
it to wait. A rule that names its exceptions is easier to port than
a list of cases.

The fix's review then showed the rule was still too narrow. A 503 can
carry Retry-After, and Rust sleeps that wait out before it reads the
path back. The first version of the rule counted only a 429 as a
request to wait, so the 503 dropped its wait. Habu's DROPBOX never
sleeps, so a wait Dropbox asks for now answers `retry`. The daemon
waits between passes, and the next pass's conditional replay finds
whatever Dropbox applied. The same review found a third path to a
stopped pass: a delete answered 200 with a body that does not parse.
Three reviews in, the rule has its final form: count every answer
Dropbox might have acted on.

The same review found a deleted check whose premise one path broke.
REPLAY had dropped its test for an incomplete entry, because DROPBOX
answers `done` only for the upload's complete entry. But a finish whose
session was gone was confirmed by content hash alone, so a file with
that hash and no rev passed. Deleting a check hands its job to a
premise, and the premise then needs a test of its own.

The collision lane also showed what a departure from Rust costs. Rust
ends the whole pass when a collision's copy fails. Habu holds that one
path, so the rest of the pass can go on. But a hold is one key, and
the directory had children. Their decisions assumed the collision was
resolved, so the pass tried to create a folder over Dropbox's file and
parked a file's upload for an hour. Rust never met this, because
ending the pass also ended the subtree. A departure must carry every
consequence of the behaviour it replaces.

## 2026-11-16: the daemon's failure table, and helpers written twice

Three small lanes moved every test helper with more than one copy into
one shared file, `src/test-client.f`. The last lane listed copies that sat
outside its brief, and the lead folded those by hand. Minutes later, the
first DAEMON lane wrote `COPIED` again in a new test file. The shared file
already exports that word, but nothing in that lane's brief named it.
A shared helper saves nothing if the next agent does not know it exists.
Rust has the same problem in principle. In practice, an editor or
`rust-analyzer` finds the helper as you type, and a Forth file shows no
such completion.

The DAEMON's failure table shows how the two languages carry failures.
Rust's daemon sorts the variants of nine error enums, 115 in all, into
four dispositions. The Habu table has 46 rows, and Habu's production
packages define 57 codes in all. Many of Rust's variants have no Habu
code, because Habu returns that answer as a value:
- UnverifiedMutation, RetriedTransport and DownloadBody are `reply`
  arms that DROPBOX returns, and DAEMON maps a reply in four lines.
- The remote-root errors are an `account-check` arm.

Rust's error channel carries the expected outcomes along with the
exceptional ones, so its policy must name each of them. Habu throws only
the exceptional, and the table shrinks to match.

The two DAEMON lanes ran at once and wrote their tests in the repository's
two test styles:
- One wrote its cases inside the reopened DAEMON package, as
  `reconcile-test.f` does.
- The other exported DAEMON's private words to a separate DAEMON-TEST
  package, as `replay-test.f` and `dropbox-test.f` do.

Both compiled, so the merge had to choose between them. The in-package
style had a defect that only the next lane would have hit: its test
runner was a word called `RUN` inside DAEMON, and the next lane adds
`DAEMON:RUN`. The test's `RUN` would have shadowed the daemon's without
a warning. Rust has one convention, `mod tests` with `use super::*`, and
a duplicate name would not compile.

Reading the account answer, one lane noticed that Habu takes the root
namespace from any tag of Dropbox's `root_info` union. Rust takes it only
from `user` or `team`, and treats any other tag as a changed binding.
No test covers this, and Dropbox sends no third tag today. It would
still have stopped the daemon with the wrong message. A port has to read
the original's `_ =>` arms as closely as its named ones.

The libunistring defect found during the MODEL work went upstream as a
bug report, with a C reproducer that checks its output against Python's
and Rust's lowercasing.

The review of the DAEMON stack found where one Habu code stood for two
Rust errors. DROPBOX threw `E-ANSWER` both for an answer that does not
parse and for a list page whose cursor did not advance. Rust calls the
first an invariant and the second environmental, so the Habu table could
give the pair only one disposition. One odd page would have stopped sync
with an exit code systemd does not restart. A port that merges two errors
into one code must check that both had the same disposition.

The same review found a leak Rust cannot have. The daemon's preparing and
configuring steps allocated in the process's arena, which nothing resets,
so each failed attempt kept a few KB until the process ended. In Rust,
each attempt's values drop at the end of its scope. In Habu, a lifetime
is an arena someone chose, and a retry loop needs one of its own.

The omaboxd lane ported the startup tests, which run the built program
as a child. The brief's build command failed twice: hb reads a `--load`
path from the directory it runs in, not from Habu's tree, and hb-build
does not make its output directory. Cargo builds from anywhere in the
tree. The lane also wrote `COPIED` and `INSIDE` again, an hour after the
previous copy was removed.

Its test could not load Habu's `signal.f`, and I reported that to Habu's
owner as a library defect. It was not one: the engine carries some
libraries built in, and those win over the source tree. Our `bin/hb`
was built nine minutes before `at-exit.f` gained the word `signal.f`
needs, so a current `signal.f` met an old `at-exit.f`. Cargo rebuilds
whatever is stale; an hb binary must be rebuilt by hand whenever its
tree moves. Rebuilding it was not one command either. Habu master had
moved 115 commits, and the old engine could not compile a tree that
uses the new section word `global`, so we seeded the build with the hb
installed on another machine of the same architecture, as Habu's
bootstrap guide says. rustup never asks this of anyone. The test now
sends SIGKILL from `PROCESS`, as Rust's `Child::kill` does.

Moving to Habu master cost two renames. Keywords such as `create` and
`private` can no longer name a word or an enum variant, so CONFIG's
`PRIVATE` became `PRIVATE-PATH` and REPLAY's `file-mutation create
replace` became `add replace`. The compiler stopped at the first such
name, and an agent renamed each by hand. Rust reserves words too, at an
edition, and `cargo fix --edition` rewrites the code for you.

The review also traced a full disk through a sync pass. Rust's error
value carries its errno to the daemon's policy, which checks for ENOSPC.
A Habu throw carries only its code, and the errno waits in `FS:ERRNO`, a
global. Cleanup on the way up (closing a directory, publishing the
status) clears that global before the policy reads it, so a full disk
during a download would have reported the sync folder as unavailable.
No test caught it because no test fills a disk. The fix puts the fact
in the code: LOCAL, JOURNAL and CONFIG throw `E-DISK-FULL` where the
errno is ENOSPC, as SQLITE already throws `E-FULL`, and the policy reads
no global. In Rust the error and its cause travel together by
construction; in Habu, anything the catch needs has to be in the code.

Rust's `OAuthClient::begin` could not keep its name. Habu refuses `: BEGIN`
as a definition, because it is the `begin` keyword in capitals, so the port
says `AUTH:START`, taken from Rust's own doc line "Start one authorization
attempt". The same lane found the second percent encoder in the tree:
DROPBOX had written its token bodies with RFC 3986's unreserved set since
the first port, while the SDK writes them form-urlencoded. No real token or
key contains a byte where the two differ, so no test could have caught it.
Two lanes wrote the same encoder because the library had none. In Rust,
`url::form_urlencoded` is one `use` away.

Moving the link into DROPBOX turned up a borrow that Habu does not check.
ACCOUNT-ID and ROOT-NAMESPACE are spans into the client's answer buffer,
and LINK's next request, the root's metadata, clears that buffer. Read
after LINK, the account id would have been the folder's JSON. The worker
caught it by reading, and copied both into the caller's arena before the
second call. Rust's borrow checker refuses this program: a `&str` into a
buffer cannot outlive a `&mut self` call that clears it. In Habu the rule
is a comment ("the answer buffer, which the next call clears"), so the
test that pins it down is the only check.

## 2026-11-17: the omabox command, and what Rust does unasked

The CLI port met the first write that can fail where Rust panics.
Rust's `println!` panics when stdout is gone, so `omaboxd --version`
piped into a closed reader fails. Habu's `type` writes and ignores the
result: a closed pipe with SIGPIPE held off and a full disk both leave
the program at exit status 0, and the forth-card does not say the write
is unchecked. The port writes through `FD:WRITE-FULL`, which throws, and
the report went to Habu's owners. Every Rust test that compared output
passed against `type`, because a test's pipe never closes early.

Rust compares a parsed command with `assert_eq!`, because `#[derive
(PartialEq)]` reaches through `String`, `bool` and `Option`. Habu's
`DERIVE eq` refuses a record with a `str`, `bool` or `option` field, so
the command enum derives no equality. The parser tests compare commands
by their printed text, and the setup options with a hand-written
`OPTIONS=`. Forty-four lines of test code stand in for one derive.

A public enum's constructors take a name the source never writes. In
SERVICE, `ENUM action ... stop ...` makes `SERVICE-ACTION:STOP` for other
packages, and `construct SERVICE:action stop` is refused. Rust's
`ServiceAction::Stop` reads the way it is declared.

Habu's string builder holds 1024 bytes and throws past that. The CLI
built five texts in it that hold a path, the app key or the login URL,
so a sync root over about a thousand bytes would have failed `omabox
settings`, `set-root` and `setup`. Every test passed, because no
fixture path is that long; I found it by reading the set-root diff. Rust
cannot have this bug: `format!` makes a `String` that grows. The fix
builds those texts in the run's arena. It needed a join word, and
Omabox now has its sixth, because the library has no join into an
arena. That gap went to Habu's owners.

Two of the step's review findings are defaults Rust sets before `main`
runs. Rust ignores SIGPIPE at startup, so a write to a closed stderr
fails and the program goes on; Habu holds it off only inside
`FD:WITH-NOSIGPIPE`, and SERVICE's one stderr write outside a hold
could have killed `omabox` between a unit's stop and its start. Rust's
`Command::spawn` leaves a child in the parent's process group; Habu's
PROCESS puts it in one of its own and keeps the word that would choose
another private, so Ctrl-C reaches `omabox` but not the `systemctl` or
`journalctl` it waits on. Neither shows in a test; both came from
reading the port against the Rust it replaced. The group went to Habu's
owners as the fourth report of the step.

Getting a value out of a `catch` shows where Habu's checker and Rust's
`Result` part. `catch` takes its seed as a cell, and an enum value is
not one, so the setup code that reads a journal's prior binding keeps
it in a one-slot arena to carry it past the catch; the reviewer's
simpler seed did not check. And a word that always throws cannot say
so: the shared existence check needs an unreachable `code throw` after
calling its failure word, or the checker reports a stale read. Rust's
`?` and its `!` type cover both without a line.

One review finding was wrong about Rust. It read the deleted-root rule
from Rust's listing code, which maps a deleted root to "unavailable",
and asked the root check to do the same. Rust's root check asks Dropbox
for no deleted entries, so Dropbox answers `not_found` and the check
fails like a missing root; the Habu port had sent `include_deleted`
true from a word shared with replay. The fix was the request, not the
mapping, and the lane's version was corrected before it landed.

The fold-in round lost one edit of mine. I corrected a lane's file in
its workspace after the lane reported, then rebased its commit from
another workspace and retired the first. jj records a workspace's files
only when a command runs there, so the commit I moved was the worker's,
and the cleanup deleted my change. The full suite run caught it: the
Dropbox suite counted three checks fewer than my run. The jj skill
already says to run `jj st` in a workspace before moving its commits
from another; I skipped it.

## 2026-11-17: binary size and build time, measured twice

Built from the same machine (aarch64, 12 cores), the Rust code from the
`rust` branch and the Habu code from master at a46cb741:

| Build | `omaboxd` | `omabox` |
|---|---|---|
| Rust, release as installed | 99.0 MB | 100.6 MB |
| Rust, release, stripped | 4.8 MB | 4.1 MB |
| Rust, opt-level z, fat LTO, one codegen unit, panic=abort, stripped | 2.69 MB | 2.36 MB |
| Habu | 1.05 MB | 0.66 MB |

The installed 99 MB is debug information: the shell exports
`CARGO_PROFILE_RELEASE_DEBUG=true`, so every Rust release build carried
it. Against the smallest Rust build, Habu's programs are 2.6 and 3.6
times smaller. They do not hold the same code. Rust compiles in its
HTTP client and TLS (ureq, rustls) and Unicode tables (std), loads
SQLite, and reaches Secret Service by running `/usr/bin/secret-tool`.
Habu's program loads libcurl with OpenSSL, libsecret, libsystemd,
libunistring and SQLite. The running Habu daemon maps 40 libraries,
27.8 MB on disk, that the Rust daemon does not: the distribution's curl
alone brings Kerberos, SSH, HTTP/3, brotli and zstd. Part of that the
Rust daemon also loads, in the `secret-tool` child it starts.

Build times, Rust release without debug information against Habu's
`hb-build`, each Habu cold build into an empty out root:

| Build | Rust, both programs | Habu `omaboxd` | Habu `omabox` |
|---|---|---|---|
| Clean | 12.2 s | 7.5 s | 6.8 s |
| No change | 0.05 s | 0.55 s | 0.49 s |
| One file touched (daemon, Dropbox client) | 4.6-4.7 s | 0.65-0.70 s | not measured |

Cargo builds both programs and 138 crates at once across the cores;
Habu builds one program per process. Clean, both programs take 12.2 s
in Rust and 14.3 s in Habu one after the other; the loop an agent runs,
edit and rebuild, is about seven times faster in Habu. A size-tuned Rust
build took 26 s clean.

My first Habu number was 3 s against Rust's 15-25 s, and it was wrong.
Habu keeps compiled objects in the tree's `.out`, and earlier test runs
had already filled part of it, so the 3 s was a half-warm build timed as
a clean one. Timing three builds in a row showed 2.85, 0.53 and 0.55 s,
and that jump led to the cache; the numbers above set `HABU_OUT` to an
empty directory for each clean build.

## 2026-11-17: a table held to its model, and a package without a Habu release

Rust's state machines are `match` arms spread over functions; the TLA+
models beside them were checked against nothing. Habu's `FSM:DEFINE`
tables are data the language reads, so a test can read one too. Habu had
no public reader, and I filed a request with Habu's owners and waited. The
user's answer: "why are you waiting for any owner? you have access to
habu". The missing word was one commit away, in a language this project
owns. Rust's version of that gap is a crate to find or a parser to write.

The reader, `FSM:LINES`, takes a table's text and hands back each line's
state, input and next state, through DEFINE's own grammar. Habu's
checker shaped it. A word whose body reaches `parse-name`, `create` or a
`defer` is treated as a possible top-level parser, so pointing DEFINE's
token source at a string through a deferred word would have marked every
caller as unverifiable. Instead DEFINE now gathers its tokens first and
LINES gathers them from the text with a scanner that splits on bytes up
to 32, as `parse-name` does, and one grammar reads both. The review
found two things. DEFINE now ends a table at a `;DEFINE` in its header,
where before it read past it; that is what the checker's
`parses-through` row already assumed, so the run now agrees with the
checker, but the docs and tests had to say so. And the test's table used
single spaces, so a scanner that missed newlines and tabs passed it.

The check itself, in `reconcile-test.f`, holds a TLA+ copy of the
listing table's lines to the table byte for byte, then runs TLC on a
module that maps the model's phases onto the table's states and states
that every step between them is a line and every line such a step. Both
deliberate breaks failed it: a changed table line fails the byte
comparison and, once copied, stops TLC on a line the module does not
name; a changed model step fails `Follows`. The whole reconcile test,
TLC's JVM included, takes 3.6 s.

Packaging met Habu's bootstrap: nothing builds `hb` without an `hb`, and
Habu has no release. The PKGBUILD clones Habu at a pinned commit and
seeds its build with the builder's own `hb`, the route Habu's recovery
docs give. makepkg builds Habu's engine and both programs in about 30 s.
A Rust package needs only cargo, which pacman installs.

One stale-build trap: after rebasing the Habu workspace onto a newer
master, its `bin/hb` still carried the old engine's libraries, and the
new library source failed with an undefined error word. Rebuilding the
engine took 8 s.

## 2026-11-17: every table under its model

The listing check proved the mechanism on one table. The user then asked
for a model of every table, with the tests running TLC themselves. Seven
tables had none. Six got one in parallel lanes, each designed, built and
checked; the seventh, the upload session, waits for its model. TLC
checks each new model in about a second, over 17 to 145 distinct states.

The check reads a line as state, input and next state. That rule did more
than check: it found every place where code outside a table moved the
machine, and each one had to become a line.

- The daemon parked every failure in a `waiting` state and stored the
  state to return to; a line picked its next state at run time, which no
  reader can see. Each state now has its own retry line back to itself
  and its own stop line, which is how Rust's loop already read.
- The service drive's steps wrote their own next state through `TO-*`
  words and a `failed` phase. Now each line names its next state, and a
  step that throws leaves the machine, as Rust's `break Err` does.
  `service.f` came out shorter.
- The download's transfer entered three of its final states from code
  that wrote the state field directly. As lines, they showed a gap: a
  read after a caught length failure answered 0, which a reader takes as
  the end of the file.

An older model was wrong in a quieter way. `SyncBehavior` passed TLC,
and it recorded an upload's plan before staging it and a conflict before
making its copies. The code, and Rust before it, do the reverse: a stage is private, and a conflict is recorded only once its
copies exist, so a crash cannot lose a payload. The model was a green
proof of a different program. Its invariants all still hold in the code's
order.

Writing the pass's model turned up a defect too: conflict copies opened
the sync root by its path, while every other write in a pass checks that
the directory there is still the journal's root. A directory swapped in
after the pass's root check would have received the copies, and the
conflict would have been recorded as done. Rust has the same defect. The
first fix put the check in the copy words, which replay shares, and so
handed replay an answer it can never meet; the review moved it to the
pass, which now opens the root once per conflict, as it already did for
directory collisions.

The check has a limit, which a test fix made concrete. It sees where a
line goes, not what it runs. A stop line changed to wait before stopping
passed the model check; only the test that counts the daemon's naps
failed. A table check replaces no test of a line's action.

## 2026-11-17: the switch, and the upload Rust never finished

At 11:19 the installed Rust `omaboxd` gave way to the Habu one, over the
same journal. Before the switch, the Rust and Habu CLIs printed that
journal's status byte for byte alike, 670,911 bytes each. A script saved
the Rust binary, stopped the service, copied the journal aside, installed
the Habu binary with a rename, ran its self-check and started the service.
The way back was the same swap in reverse; it was not needed. A swap was
enough because the rewrite kept Rust's journal schema, its upload stages
and its download slots, down to the extended attribute names.

The Rust daemon had failed one upload 333 times, from 2026-11-15 10:07 to
the switch: a 201,752,253-byte file sent as an upload session, whose
finish answered "The content received by the Dropbox server in this call
does not match the provided content hash." Rust retried it as a passing
failure, so every pass tried it again and none got past it. Its journal
shows no scan published since: at the switch it still listed as present
a file deleted locally on 2026-11-15.

Dropbox's answer names the check: the content received in this call.
Rust's finish carried the whole file's hash and no bytes, as the
2026-11-15 entry found; Habu's finish carries no hash. Over the same
staged bytes and the same account, the Habu daemon's upload went through,
and Dropbox's listing records the file at a content hash equal to the
stage's. The cause the 2026-11-15 entry inferred is the one.

That file was the deleted one. Its upload was recorded intent, so the
Habu daemon finished it, and its next pass carried the local deletion to
Dropbox. Nothing was lost: everything the archive held was already in the
local tree, 240 files byte for byte and four PDFs with the same text and
images under a new title.

In its first six and a half hours the Habu daemon completed 10,540 plans;
5,049 wait, and one is blocked, because Dropbox rejects a name that ends
in a space; that plan waits for its retry time and the rest go on.
Dropbox answered three deletes with 429; each ended the pass, and the
daemon tried again 10 or 20 seconds later.

Observation for the blog: one misread field stopped the whole sync for
two days, because the failure was classed as passing. Habu blocks a plan
Dropbox rejects for its content, so the other paths go on, but records it
under a generic tag; the cause still needs a name of its own.

## 2026-11-18: the daemon's memory, and a Habu that moved on

systemd reported the service peaking at 822 MB. Most of that was page
cache, which the cgroup charges for the files the daemon reads; the
process's own private memory, from smaps_rollup, was 92 MB, against
about 4 MB of anonymous memory for a daemon that has not uploaded.

The cause was one option. `CURL:BODY!` sets CURLOPT_COPYPOSTFIELDS, so
libcurl copied every upload chunk into a malloc of its own. A malloc above
glibc's mmap threshold raises that threshold, so the next chunk's copy
came from the heap, and the heap kept the freed copies. A reproducer that
uploads through the fake Dropbox showed a 50,688 kB heap with under
0.5 MB in use. Habu gained `CURL:BORROW-BODY!` (CURLOPT_POSTFIELDS), which
lets libcurl read the chunk where it lies, in a buffer Omabox maps and
unmaps itself. On the same reproducer the heap stays at or below 592 kB
and the peak resident size falls from 127,520 kB to 44,592 kB. What still
grows is glibc's per-thread cache of small freed chunks: about 35 kB, flat
after some 16 uploads, and flat from the first with the cache turned off.

Shipping that one word meant moving Omabox onto Habu master, whose own
changes had piled up since the pinned commit:
- **Deleted words:** Habu had deleted the anchored file-system words
  (`FS:OPEN-DIR`, `FS:TRY-RENAME-AT` and the rest) because, it judged, no
  program called them. Omabox calls 16 of them; Habu could not see a
  client outside its tree.
- **Staged build:** putting the file back meant a staged build. hb builds
  with its own list of the files it carries, so an hb whose list lacks a
  file cannot build one that has it. The package build now runs Habu's
  convergence check after the seed, rather than trusting the first
  generation.
- **Strings:** Habu had respelled its strings as `str` and marked its own
  files with a transitional `split-str`. I assumed Omabox needed the
  marker too, but Omabox had been on one-item `str` for days and the marker
  broke it. The client was ahead of the library. The real port changed
  582 lines in 34 source files, so that each call meets Habu's row as it
  is now, mostly with a `>str` or `str>` at the call.

Observation for the blog: Cargo pins a crate's version and semver tells
the client what a bump will cost. Habu has no versions, so the client pins
a commit and pays for every change since in one go. A library's "nothing
calls this" holds only for the code it can see.

## 2026-11-18: the memory a pass left behind

With the upload copies gone, the daemon still held 63 MB of anonymous
memory, flat from pass to pass. Most of it was one 57,344 kB mapping:
the 8, 16 and 32 MB chunks of the pass's arena, which doubles each new
chunk. The daemon reset that arena when a pass started, so between passes
it kept the whole of the last one. Emptying it as the pass ends took the
idle daemon to 8.6 MB.

The chunks were that large because a pass reads whole inventories into
vectors that grow by doubling. In an arena, a resize that moves a block
leaves the old copy where it was: 16 MB of the 63 MB a no-op pass over
16,400 entries allocates are dead copies. A pass still peaks at about
70 MB, 2.9 to 3.9 kB per entry; that is the next fix.

Observation for the blog: a Rust value is freed when its owner goes out
of scope, so memory follows the code that uses it. An arena's memory
lives until someone resets it, and here the reset was in the right step
but at the wrong end of it. A test cannot tell the two apart; only the
idle daemon's memory can.

## 2026-11-18: an error that depended on the scheduler

Omabox runs secret-tool and systemctl with its own spawn, pipe and wait
code, two copies of what Habu's process library already does. Moving to
the library showed two gaps. A capture that could not even start threw
the same code as one whose read failed later, and a child that stopped
reading its input looked like success. The first fix stands: a capture
that cannot start now throws E-PROC-SPAWN.

The second fix added an error for input the child left unread, and every
test passed. The review then ran `true` with one byte of input: pinned to
one CPU, it threw in 299 of 300 runs; on all CPUs, in none. A pipe takes
bytes before the child reads them, so the parent can never tell whether
the child read them. Whether the error fired depended on who ran first.
The tests passed because they fed more than a pipe holds. Go settled the
same question in 2014 (issue 9173) by ignoring a broken pipe on stdin, and
Python's `communicate()` does the same. Habu now does too: the capture
reads both streams to their end and the exit status decides.

Observation for the blog: Rust's standard library leaves this to the
caller; `write_all` on a child's stdin answers `BrokenPipe` and the caller
chooses. A library that runs the whole exchange for its caller has to
choose for everyone, and a choice that tests confirm can still be wrong.
Only a run that changed the scheduling showed it.

## 2026-11-18: a statement that cannot be dropped

Publishing a scan row by row was slower than reading the whole inventory
back: 159 ms against 103 at 4,000 files. Each row prepared its own SQL
statement and opened its own buffer and arena. The plan was a scan record
holding both prepared inserts, passed to each call like any other value.

Habu refused it when the file loaded, before any test ran. An SQLite
statement is a linear value: the word that prepares it must get it back
to finalize it, so code may move it but never copy or drop it. A record
holding two statements is linear too. So the scan words now take the scan
and hand it back, and the body that runs a scan returns it.

Observation for the blog: in Rust each call would borrow the scan
(`&mut Scan`), and dropping the scan would finalize its statements. Habu
has no borrows and no destructors: passing the scan moves it, and dropping
it is an error, so every call hands it back. The loader caught the
design's mistake before any test ran, as Rust's compiler catches a bad
borrow; the price is a scan in the stack effect of every word it passes
through.

## 2026-11-19: a statement a catch cannot hold

The scan record from the last entry met the walk's error handling. The
walk caught each entry's failure, published the entry as unknown and went
on, and the first plan ran each entry inside a catch with the scan on the
stack beneath it. The worker stopped before writing it: Habu's manual
says a linear value cannot cross a catch, because a throw restores the
stack's depth but not its contents. After a throw the slot may hold a
statement the caught code already finalized.

So the walk changed shape. Only the filesystem steps, which never touch
the scan, run inside a catch; each answers 0 or an error code, and the
word that writes the scan decides from that value. The root's own failure
still throws, because reconcile waits for it by name.

Checking that rule turned up a gap in Habu. Its checker accepts a word
that reads a handle after a catch whose body consumed it, both directly
and through a helper that wraps the catch; the manual says both are
refused. That is now a Habu dot with a root-cause lane.

Observation for the blog: this is the shape the Rust original had all
along. Each step returned a `Result`, `?` passed errors up, and an error
dropped what it held on the way out. The Habu port first reached for
throw and catch, Forth's habit, and the linear type pushed it back to
errors as values. The difference is in what checks it: Rust's borrow
checker has no gap here, while Habu's rule was written down before its
checker enforced every case of it.

## 2026-11-19: a compiler that could not build its own master

Habu's master moved its Linux layout constants into a package. The hb
binary the lanes were using could not build that master: hb carries the
list of files its boot loads, and the old list loaded the new package
without the file that gives its names their old, bare spelling. The
build died on the first bare name.

Habu's bootstrap notes describe the remedy, a stage: build, with the old
hb, a revision that adds the new boot list but does not need it yet, then
build master with that stage. Here that meant a throwaway revision with
two added rows and an empty file. The master built with the stage then
rebuilt itself byte for byte.

Observation for the blog: Rust bootstraps the same way (stage0 builds
stage1, stage1 builds stage2), but rustup ships stage0 prebuilt and pinned,
so a contributor rarely sees it. A self-hosting Habu that agents rebuild
many times a day meets it whenever a change alters what the compiler
carries, and the agent has to recognize the failure as a bootstrap order
and not a bug in the change.
