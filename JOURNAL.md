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
