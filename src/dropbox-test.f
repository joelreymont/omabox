\ dropbox-test.f - DROPBOX's client core against the fake Dropbox of
\ test-dropbox.f on a loopback port: the account (one whose root_info
\ carries a tag other than user or team), metadata (of a file that
\ is not downloadable, of a symlink, of a file with no content hash, of
\ an entry at another path and of one whose path_lower keeps U+13A0 among
\ them), the Path-Root header, the token's
\ refresh, its rotation and the store that keeps it, a refresh that fails
\ a download and leaves no status, a rejected grant, a rejected client's
\ delete after a long poll answered 503, a revoked token,
\ access denied, a scripted answer bound to its route, rate limits,
\ outages, a redirect, a malformed request, a write refused
\ access_restricted, team_folder or
\ operation_suppressed, the listing (one of 12 pages, one of them over
\ 64 KiB, one holding a file that is not
\ downloadable, one holding files Dropbox described incompletely, handed
\ on, and one holding restricted folders, among them), COMPLETE? of each
\ kind of entry, the probe of a folder (one a continue page whose cursor
\ did not advance interrupts, one stopped at its first entry), the long
\ poll (one a readable descriptor ends, one answered before it is),
\ downloads, whose body reads through READ-BODY (whole, resumed, a 416
\ at the end, a body that throws before or after its end, one left
\ unread while the server holds the rest, one in two chunks read 7 or
\ 64 bytes a read, one
\ cut mid-body, whether or not its body catches the loss, an empty file,
\ one answered 400 and one 404, each keeping its status, and ones refused
\ unverified: another rev, content hash or range, a resumed body one
\ byte short or long, which fails before READ-BODY answers 0, whether or
\ not its body catches the short one's failure, a held body one byte
\ long whose body catches it in flight, a 416 from 0, a
\ Dropbox-API-Result or an error that does not parse), delete,
\ create-folder, the code exchange, linking a login (of a folder, of
\ an account whose root_info carries a tag other than user or team, one
\ whose get_metadata or get_current_account answers 503, logging the
\ operation, of an invalid root, unsent, a root check asking for no
\ deleted entry, and one answered at another path, unavailable),
\ Dropbox's content hash and uploads,
\ whose stages are written under TMPDIR and removed once open, so no run
\ leaves one; a checkpoint at each accepted append with its session and
\ offset, the restarted session's after a closed one, and none for a
\ single upload; a mutation, session start or finish lost or answered 503
\ with no wait, an append lost twice, a session gone twice, a mutation
\ Dropbox answers at another path, a delete it answers with a file at
\ another rev, a delete's answer that does not parse, and an upload's or
\ finish's that does not parse or carries another content hash, each
\ refused unverified with no get_metadata; a finish whose session is gone
\ and whose get_metadata finds the upload's content hash on a file with no
\ rev, restarted and then unverified; an append answered 503 with no
\ wait, resent; a delete answered 429, and a delete or an append answered
\ 503 with a wait, each answering retry with that wait, not resent; a
\ delete, create-folder or upload conflict answered as refused with no
\ get_metadata, even where Dropbox already holds what it asked for.
\ Tests of tests/dropbox_fake.rs run
\ under their names: a_refused_grant_becomes_a_rejected_token,
\ a_rotated_refresh_token_is_stored_before_the_new_token_is_published,
\ an_unstored_rotation_stays_usable_and_is_retried,
\ an_unrotated_refresh_never_touches_secret_service,
\ sdk_expiry_refresh_reissues_the_route_with_the_same_client,
\ long_poll_exposes_reset_and_rate_limit_outcomes,
\ link_rejects_unavailable_file_and_restricted_roots,
\ oauth_rate_limit_preserves_retry_after_header,
\ oauth_listing_longpoll_and_exact_download_use_documented_protocol and
\ conditional_mutations_use_strict_documented_requests. One server
\ and one main client serve every case; a case that needs another config
\ opens its own client.
\ DROPBOX's log lines go to stderr, but those a case checks, which are
\ captured in TMPDIR, checked and removed. A stub in place of AIO's
\ transfer fails the stage's reads. Each failed assertion prints its
\ label; the run goes on and fails at its end.
\ The tables against their models, through TEST-FORMAL:HOLDS:
\ formal_holds_the_downloading_table, DOWNLOADING and formal/Downloading.tla;
\ formal_holds_the_session_table, SESSION and formal/UploadSession.tla.
\ Run from the repository root: hb --load src/dropbox-test.f </dev/null
require src/lib/aio.f
require src/lib/byte-buffer.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/string.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/test/mapped.f
require src/lib/test/counting-allocator.f
require src/lib/memory.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/test/stderr.f
require src/lib/adt/option.f
require src/lib/fd.f
require src/lib/task.f
require src/lib/heap.f
require src/lib/net/httpc.f
require src/lib/log.f
require src/test-formal.f
require src/dropbox.f
require src/test-dropbox.f
require src/test-client.f
require src/version.f

\ DROPBOX reopened for the throws no answer of the fake reaches: a reader
\ that faults, and an OPEN that fails once its buffers exist.
package DROPBOX
private

TYPED-VARIABLE PROBE config


\ A store that keeps nothing.
: KEEP-NONE ( str -- ) drop ;


\ A client on an arena of its own, with PROBE's root, origins at
\ NOWHERE$ and a store that keeps nothing, as no case sends.
: PROBED ( str ^ARENA:arena -- ^client )
   {: r ar :}
   r str> SPAN:MAKE PROBE DROPBOX-CONFIG:ROOT !
   TEST-CLIENT:NOWHERE$ str> SPAN:MAKE PROBE DROPBOX-CONFIG:API !
   TEST-CLIENT:NOWHERE$ str> SPAN:MAKE PROBE DROPBOX-CONFIG:NOTIFY !
   TEST-CLIENT:NOWHERE$ str> SPAN:MAKE PROBE DROPBOX-CONFIG:CONTENT !
   [: KEEP-NONE ;] PROBE DROPBOX-CONFIG:STORE !
   PROBE ar OPEN ;


\ A member whose read faults on memory.
: FAULTING ( JSON:value JSON:value ^client -- )
   {: k v c :}
   EXIT-STATUS:MEMORY-FAULT throw ;


\ A reader's memory fault reaches PARSE's caller as itself.
: FAULT-CASE ( -- )
   s" a reader's own code" T-LABEL
   ARENA:NEW {: ar :}
   s" " ar PROBED {: c :}
   s\" {\"a\":1}" str> BUF:N>BLEN c CLIENT-ANSWER @ BUF:REPLACE
   [: c [: FAULTING ;] PARSE ;]
   EXIT-STATUS:MEMORY-FAULT TTHROWSQ
   c CLOSE
   ar ARENA:RELEASE ;


\ The xt run with the client's vectors on ALLOC-TEST:COUNTING, its
\ counts cleared; VEC-ALLOC is the heap again however the xt ends.
: COUNTED ( [ -- ] -- )
   0 ALLOC-TEST:TAKEN ! 0 ALLOC-TEST:FREED !
   ALLOC-TEST:COUNTING VEC-ALLOC !
   [: HEAP:ALLOCATOR VEC-ALLOC ! ;] finally ;


\ OPEN's filling of c fails on PROBE's root as a header byte.
: UNDONE-OPEN ( ^client ^ARENA:arena -- )
   {: c ar :}
   [: c PROBE ar FILLED ;] E-JSON-WRITE-BYTE TTHROWSQ ;


\ A root that is not UTF-8 fails the Path-Root line after the buffers
\ and vectors exist; none of them stays live, every vector taken is freed.
: UNDONE-CASE ( -- )
   s" an OPEN that fails" T-LABEL
   ARENA:NEW {: ar :}
   s\" \xFF" str> SPAN:MAKE PROBE DROPBOX-CONFIG:ROOT !
   ar CLIENTS-NEW {: c :}
   [: c ar UNDONE-OPEN ;] COUNTED
   ALLOC-TEST:TAKEN @ {: k:n :}
   k ALLOC-TEST:FREED @ = k 0<> and T-ASSERT
   c CLIENT-TOKEN @ BUF:CAP@ BUF:BLEN>N 0 T=
   c CLIENT-ACCESS @ BUF:CAP@ BUF:BLEN>N 0 T=
   c CLIENT-ANSWER @ BUF:CAP@ BUF:BLEN>N 0 T=
   c CLIENT-SENT @ BUF:CAP@ BUF:BLEN>N 0 T=
   c CLIENT-MARK @ BUF:CAP@ BUF:BLEN>N 0 T=
   ar ARENA:RELEASE ;

public

: THROW-CASES ( -- ) FAULT-CASE UNDONE-CASE ;

;package

package DROPBOX-TEST
public

\ How the stub fails a read of the stage: refused before its entry is
\ written, entered with the entry left to the kernel, or ended by the
\ kernel as timed out or cancelled.
ENUM read-fault full entered timed-out cancelled ;ENUM

;package


\ White-box, as Habu's aio-test.f: package AIO reopened to swap its private
\ HOST-XFER for STAGE-XFER, which fails the reads of FAILING's descriptor
\ and passes every other transfer, the fake's HTTP reads included, to the
\ real URING-XFER. Each name lands in DROPBOX-TEST, so AIO gains none.
package AIO

TYPED-VARIABLE DROPBOX-TEST:READ-FAULT DROPBOX-TEST:read-fault
variable DROPBOX-TEST:FAILING
\ The buffer the failed read was handed.
TYPED-VARIABLE DROPBOX-TEST:OFFERED ^u8
TYPED-VARIABLE DROPBOX-TEST:OFFERED-CAP NUM:alloc-byte-len


\ The record holds the buffer as URING-XFER's does, so AWAIT-XFER gives
\ it back with the record's outcome.
: DROPBOX-TEST:HOLDS ( ^u8 NUM:alloc-byte-len n -- )
   {: buf cap:NUM:alloc-byte-len idx:n :}
   buf idx REC-BUF ! cap idx REC-BUF-LEN!
   1 idx REC REC.HOLD ! ;


\ A timer of ms in the read's place, which the kernel ends as timed out.
: DROPBOX-TEST:TIMED-XFER ( ^u8 NUM:alloc-byte-len n -- n n )
   {: buf cap:NUM:alloc-byte-len ms:n :}
   ms HOST-TIMEOUT {: rc:n idx:n :}
   rc 0<> if rc idx exit then
   buf cap idx DROPBOX-TEST:HOLDS 0 idx ;


\ A minute's timer in the read's place, cancelled at once: the kernel ends
\ it as cancelled. A refused cancel leaves the buffer the caller's.
: DROPBOX-TEST:CANCELLED-XFER ( ^u8 NUM:alloc-byte-len -- n n )
   {: buf cap:NUM:alloc-byte-len :}
   60000 HOST-TIMEOUT {: rc:n idx:n :}
   rc 0<> if rc idx exit then
   idx HOST-CANCEL drop {: refused:n :}
   refused 0<> if refused idx exit then
   buf cap idx DROPBOX-TEST:HOLDS 0 idx ;


\ E-AIO-FULL leaves the buffer the caller's, as a refused claim does.
\ E-AIO-ENTER leaves it with the kernel, which the test plays: it keeps
\ OFFERED and releases it as AIO's loop would at the late completion.
\ Runs under AIO-LOCK, as every HOST-XFER does.
: DROPBOX-TEST:STAGE-XFER ( n ^u8 NUM:alloc-byte-len n n n -- n n )
   {: f:n buf cap:NUM:alloc-byte-len count:n off:n kind:n :}
   f DROPBOX-TEST:FAILING @ <> if
      f buf cap count off kind URING-XFER exit
   then
   buf DROPBOX-TEST:OFFERED ! cap DROPBOX-TEST:OFFERED-CAP !
   DROPBOX-TEST:READ-FAULT @ MATCH DROPBOX-TEST:read-fault
      full OF E-AIO-FULL -1 ENDOF
      entered OF E-AIO-ENTER -1 ENDOF
      timed-out OF buf cap 1 DROPBOX-TEST:TIMED-XFER ENDOF
      cancelled OF buf cap DROPBOX-TEST:CANCELLED-XFER ENDOF
   ;MATCH ;


\ Fails the reads of descriptor f as the fault says, until ;FAIL-READS.
: DROPBOX-TEST:FAIL-READS ( n DROPBOX-TEST:read-fault -- )
   DROPBOX-TEST:READ-FAULT ! DROPBOX-TEST:FAILING !
   ['] DROPBOX-TEST:STAGE-XFER is HOST-XFER ;


: DROPBOX-TEST:;FAIL-READS ( -- ) ['] URING-XFER is HOST-XFER ;

;package


package DROPBOX-TEST
private

TYPED-VARIABLE AR ^ARENA:arena


: ASSERT ( bool -- ) dup T-ASSERT 0= if T-REPORT then ;


: UNLINKED? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF true ENDOF
   ;MATCH ;


\ The ms a retry asks to wait, else -1.
: RETRY-MS ( DROPBOX:reply -- n )
   MATCH DROPBOX:reply
      done OF -1 ENDOF
      refused OF drop -1 ENDOF
      retry OF ENDOF
      unlinked OF -1 ENDOF
   ;MATCH ;


: REFUSED? ( DROPBOX:reply DROPBOX:error -- bool )
   {: r:DROPBOX:reply e:DROPBOX:error :}
   r MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF e DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ DROPBOX:WAIT with no descriptor, which answers some reply.
: LONG-POLL ( str n ^DROPBOX:client -- DROPBOX:reply )
   {: k secs:n c :}
   k secs OPTION:NONE c DROPBOX:WAIT MATCH option
      some OF ENDOF
      none OF false ASSERT DROPBOX-REPLY:UNLINKED ENDOF
   ;MATCH ;


\ The recording store: the refresh tokens it was handed, joined by
\ spaces, the paths the fake had seen at its last call, and how many more
\ calls it refuses, throwing E-FS-IO, before it takes one.
create KEPT 256 allot
variable KEPT-U
create WITNESS 256 allot
variable WITNESS-U
variable REFUSALS


: KEPT$ ( -- str ) KEPT KEPT-U @ >str ;
: WITNESS$ ( -- str ) WITNESS WITNESS-U @ >str ;


: KEPT+ ( str -- )
   str> {: a:^ u:n :}
   a KEPT KEPT-U @ + u BYTE-COPY
   u KEPT-U +! ;


: RECORD-TOKEN ( str -- )
   {: t :}
   KEPT-U @ 0<> if s"  " KEPT+ then
   t KEPT+
   TEST-DROPBOX:SEEN$ str> {: w:^ wu:n :}
   w WITNESS wu BYTE-COPY wu WITNESS-U !
   REFUSALS @ 0= if exit then
   -1 REFUSALS +!
   E-FS-IO throw ;


\ The store refuses its next n calls; nothing is recorded yet.
: RECORDING ( n -- ) REFUSALS ! 0 KEPT-U ! 0 WITNESS-U ! ;


\ A client on the fake with the refresh token t and root r, and the
\ recording store.
: RECORDED-CLIENT ( str str -- ^DROPBOX:client )
   {: t r :}
   [: RECORD-TOKEN ;] t r AR @ TEST-CLIENT:CLIENT-ON ;


: ACCOUNT-CASE ( -- )
   s" account" T-LABEL
   TEST-DROPBOX:RESET
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT-ID s" dbid:account" T$=
   TEST-CLIENT:MAIN @ DROPBOX:ROOT-NAMESPACE s" namespace" T$=
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:AUTH$ s" Bearer sl.fake-1" T$=
   TEST-DROPBOX:TYPE-SENT? TFALSE
   TEST-DROPBOX:TOKEN-TYPE$ s" application/x-www-form-urlencoded" T$=
   SB-RESET s" omabox/" SB-APPEND RELEASE:VERSION$ SB-APPEND
   TEST-DROPBOX:AGENT-SENT$ SB$ T$=
   TEST-DROPBOX:LEAKED? TFALSE ;


\ A root_info under a tag other than user or team answers no namespace,
\ though it carries one ahead of its tag.
: OTHER-ROOT-CASE ( -- )
   s" account under another root tag" T-LABEL
   TEST-DROPBOX:RESET
   s" /2/users/get_current_account" 200 s" " s" "
   S\" {\qaccount_id\q:\qdbid:account\q,\qroot_info\q:{\qroot_namespace_id\q:\qnamespace\q,\q.tag\q:\qother\q}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT-ID s" dbid:account" T$=
   TEST-CLIENT:MAIN @ DROPBOX:ROOT-NAMESPACE s" " T$= ;


: FILE-CASE ( -- )
   s" metadata found" T-LABEL
   TEST-DROPBOX:RESET
   s" /docs/a.txt" s" /Docs/A.txt" s" 015f0c1d2e3a"
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   12 TEST-DROPBOX:FILE!
   s" /docs/a.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FILE DROPBOX-KIND:EQ TTRUE
   e DROPBOX-ENTRY:LOWER @ SPAN:$ s" /docs/a.txt" T$=
   e DROPBOX-ENTRY:DISPLAY @ SPAN:$ s" /Docs/A.txt" T$=
   e DROPBOX-ENTRY:REV @ SPAN:$ s" 015f0c1d2e3a" T$=
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   e DROPBOX-ENTRY:SIZE @ 12 T=
   e DROPBOX-ENTRY:DOWNLOADABLE @ TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$=
   s" /2/files/get_metadata" TEST-DROPBOX:BODIES-TO$
   S\" {\qpath\q:\q/docs/a.txt\q,\qinclude_deleted\q:true}" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/json" T$= ;


\ FILE! keeps a path that lives in the string builder, which it leaves as
\ it was.
: BUILT-PATH-CASE ( -- )
   s" metadata of a built path" T-LABEL
   TEST-DROPBOX:RESET
   SB-RESET s" /docs/built.txt" SB-APPEND
   SB$ s" /Docs/Built.txt" s" 015f0c1d2e3b"
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   0 TEST-DROPBOX:FILE!
   SB$ s" /docs/built.txt" T$=
   s" /docs/built.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$
   s" /docs/built.txt" T$= ;


: MISSING-CASE ( -- )
   s" metadata not found" T-LABEL
   TEST-DROPBOX:RESET
   s" /missing" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX-ERROR:NOT-FOUND REFUSED? ASSERT ;


: LOST-READ-CASE ( -- )
   s" lost metadata" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:CUT
   s" /docs/a.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA RETRY-MS 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$= ;


\ get_metadata answers /paper with the body; the entry is a file that is
\ not downloadable.
: UNDOWNLOADABLE ( str -- )
   {: b :}
   TEST-DROPBOX:RESET
   200 s" " s" " b TEST-DROPBOX:SCRIPT!
   s" /paper" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FILE DROPBOX-KIND:EQ TTRUE
   e DROPBOX-ENTRY:LOWER @ SPAN:$ s" /paper" T$=
   e DROPBOX-ENTRY:DOWNLOADABLE @ TFALSE ;


\ A file that is not downloadable needs no content hash.
: UNDOWNLOADABLE-CASE ( -- )
   s" metadata of a file that is not downloadable" T-LABEL
   S\" {\q.tag\q:\qfile\q,\qname\q:\qPaper\q,\qid\q:\qid:p\q,\qpath_lower\q:\q/paper\q,\qpath_display\q:\q/Paper\q,\qrev\q:\q015f0c1d2e3c\q,\qsize\q:0,\qis_downloadable\q:false}"
   UNDOWNLOADABLE ;


\ symlink_info read before is_downloadable true still marks the file.
: SYMLINK-CASE ( -- )
   s" metadata of a symlink" T-LABEL
   S\" {\q.tag\q:\qfile\q,\qname\q:\qPaper\q,\qid\q:\qid:p\q,\qpath_lower\q:\q/paper\q,\qpath_display\q:\q/Paper\q,\qrev\q:\q015f0c1d2e3d\q,\qsize\q:0,\qsymlink_info\q:{\qtarget\q:\q/docs\q},\qis_downloadable\q:true}"
   UNDOWNLOADABLE ;


\ A downloadable file with a rev and no content hash is handed as Dropbox
\ sent it, incomplete.
: INCOMPLETE-CASE ( -- )
   s" metadata of a file with no content hash" T-LABEL
   TEST-DROPBOX:RESET
   200 s" " s" "
   S\" {\q.tag\q:\qfile\q,\qname\q:\qIncomplete.txt\q,\qid\q:\qid:i\q,\qclient_modified\q:\q2024-01-02T03:04:05Z\q,\qserver_modified\q:\q2024-01-02T03:04:05Z\q,\qpath_lower\q:\q/incomplete.txt\q,\qpath_display\q:\q/Incomplete.txt\q,\qrev\q:\qrev-incomplete\q,\qsize\q:0,\qis_downloadable\q:true}"
   TEST-DROPBOX:SCRIPT!
   s" /incomplete.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FILE DROPBOX-KIND:EQ TTRUE
   e DROPBOX:COMPLETE? TFALSE ;


: METADATA-ELSEWHERE-CASE ( -- )
   s" metadata of an entry at another path" T-LABEL
   TEST-DROPBOX:RESET
   200 s" " s" "
   S\" {\q.tag\q:\qfolder\q,\qname\q:\qb\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/docs/b\q,\qpath_display\q:\q/Docs/b\q}"
   TEST-DROPBOX:SCRIPT!
   s" /docs/a" TEST-CLIENT:MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:PATH-MISMATCH REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$= ;


\ Dropbox's path_lower keeps U+13A0, whose full lowercase is U+AB70; it
\ and the path /Ꭰ.txt have the same full lowercase, so the entry is at
\ the path, and one at /b.txt is not.
: METADATA-CASEFOLD-CASE ( -- )
   s" metadata of an entry whose path_lower keeps U+13A0" T-LABEL
   TEST-DROPBOX:RESET
   200 s" " s" "
   S\" {\q.tag\q:\qfolder\q,\qname\q:\q\xe1\x8e\xa0.txt\q,\qid\q:\qid:c\q,\qpath_lower\q:\q/\xe1\x8e\xa0.txt\q,\qpath_display\q:\q/\xe1\x8e\xa0.txt\q}"
   TEST-DROPBOX:SCRIPT!
   S\" /\xe1\x8e\xa0.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   s" metadata of an entry at /b.txt for /Ꭰ.txt" T-LABEL
   TEST-DROPBOX:RESET
   200 s" " s" "
   S\" {\q.tag\q:\qfolder\q,\qname\q:\qb.txt\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/b.txt\q,\qpath_display\q:\q/b.txt\q}"
   TEST-DROPBOX:SCRIPT!
   S\" /\xe1\x8e\xa0.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:PATH-MISMATCH REFUSED? ASSERT ;


: ROOT-CASE ( -- )
   s" path root" T-LABEL
   TEST-DROPBOX:ROOT-SENT? TTRUE
   TEST-DROPBOX:ROOT-SENT$ S\" {\q.tag\q:\qroot\q,\qroot\q:\qns-root\q}" T$=
   s" " TEST-DROPBOX:ROOT!
   TEST-DROPBOX:RESET
   s" live-token" s" " RECORDED-CLIENT {: home :}
   home DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:ROOT-SENT? TFALSE
   home DROPBOX:CLOSE
   s" ns-root" TEST-DROPBOX:ROOT! ;


\ The expired token's route is resent on the same client with the new
\ token; neither the refresh nor the long poll after it carries a token.
: SDK-EXPIRY-REFRESH-REISSUES-THE-ROUTE-WITH-THE-SAME-CLIENT ( -- )
   s" sdk_expiry_refresh_reissues_the_route_with_the_same_client" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:EXPIRE
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account" T$=
   SB-RESET s" Bearer " SB-APPEND TEST-DROPBOX:ISSUED$ SB-APPEND
   TEST-DROPBOX:AUTH$ SB$ T$=
   false 0 TEST-DROPBOX:POLL!
   s" c3" 30 TEST-CLIENT:MAIN @ LONG-POLL DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TFALSE
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account /2/files/list_folder/longpoll" T$=
   TEST-DROPBOX:LEAKED? TFALSE ;


\ ---- the log a case checks

create ERR-PATH 256 allot
variable ERR-PATH-U
PTR-VARIABLE ERR         \ the captured log, in AR
variable ERR-U
TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE OUTCOME bool


: ERR-PATH$ ( -- str ) ERR-PATH ERR-PATH-U @ >str ;
: ERR$ ( -- str ) ERR @ ERR-U @ >str ;


\ TMPDIR/<name> at dst; answers its length.
: IN-TMP ( str ^u8 -- n )
   {: nm dst:^ :}
   nm str> {: n:^ nu:n :}
   s" TMPDIR" GETENV str> {: d:^ du:n :}
   d dst du BYTE-COPY
   47 dst du + c!
   n dst du + 1+ nu BYTE-COPY
   du 1+ nu + ;


\ The code xt throws, 0 for none, with fd 2 sent to TMPDIR/stderr.txt,
\ which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ACTION !
   s" stderr.txt" ERR-PATH IN-TMP ERR-PATH-U !
   ACTION @ ERR-PATH$ AR @ STDERR:CAPTURING str> ERR-U ! ERR ! ;


: LINES ( str -- n )
   str> {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;


\ ERR$ is one line that holds the text.
: LOGGED? ( str -- bool )
   {: t :}
   ERR$ LINES 1 = ERR$ t STR:CONTAINS? and ;


\ A case's own client, for an action LOGGED runs.
TYPED-VARIABLE OWN ^DROPBOX:client


\ OUTCOME: the client's account call answered unlinked.
: ACCOUNT-UNLINKED ( ^DROPBOX:client -- )
   DROPBOX:ACCOUNT UNLINKED? OUTCOME ! ;


\ The client's account call, logged: it answers unlinked.
: UNLINKED-LOGGED ( ^DROPBOX:client -- )
   OWN ! false OUTCOME !
   [: OWN @ ACCOUNT-UNLINKED ;] LOGGED 0 T=
   OUTCOME @ TTRUE ;


: REJECTED-GRANT-CASE ( -- )
   s" a_refused_grant_becomes_a_rejected_token" T-LABEL
   TEST-DROPBOX:RESET
   s" dead-token" s" ns-root" RECORDED-CLIENT {: dead :}
   dead UNLINKED-LOGGED
   s" error dropbox: oauth2/token unlinked: the refresh token was refused"
   LOGGED? TTRUE
   dead UNLINKED-LOGGED
   ERR-U @ 0 T=
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   dead DROPBOX:CLOSE ;


\ A rejected client still long-polls, which needs no token. A delete after
\ a poll answered 503 is unlinked, unsent, never unverified by that 503.
: REJECTED-POLL-CASE ( -- )
   s" rejected client after a failed long poll" T-LABEL
   TEST-DROPBOX:RESET
   s" dead-token" s" ns-root" RECORDED-CLIENT {: dead :}
   dead UNLINKED-LOGGED
   503 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   s" c5" 30 dead LONG-POLL RETRY-MS 0 T=
   s" /x.txt" s" " dead DROPBOX:DELETE UNLINKED? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/files/list_folder/longpoll" T$=
   dead DROPBOX:CLOSE ;


\ A client of its own, as a refreshed token refused rejects it.
: REVOKED-CASE ( -- )
   s" revoked token" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" RECORDED-CLIENT {: gone :}
   gone DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:RESET
   TEST-DROPBOX:REVOKE
   gone UNLINKED-LOGGED
   s" error dropbox: users/get_current_account unlinked: a refreshed token was refused"
   LOGGED? TTRUE
   gone UNLINKED-LOGGED
   ERR-U @ 0 T=
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account" T$=
   SB-RESET s" Bearer " SB-APPEND TEST-DROPBOX:ISSUED$ SB-APPEND
   TEST-DROPBOX:AUTH$ SB$ T$=
   gone DROPBOX:CLOSE ;


: DENIED-CASE ( -- )
   s" access denied" T-LABEL
   TEST-DROPBOX:RESET
   403 s" " s" "
   S\" {\qerror_summary\q:\qno_permission/...\q,\qerror\q:{\q.tag\q:\qno_permission\q}}"
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ UNLINKED-LOGGED
   s" error dropbox: users/get_current_account unlinked: 403" LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/users/get_current_account" T$= ;


\ ---- the refresh token's rotation

: BEARER$ ( -- str )
   SB-RESET s" Bearer " SB-APPEND TEST-DROPBOX:ISSUED$ SB-APPEND SB$ ;


\ The store saw only the refresh: no call had used its access token yet.
: STORED-FIRST-CASE ( -- )
   s" a_rotated_refresh_token_is_stored_before_the_new_token_is_published"
   T-LABEL
   TEST-DROPBOX:RESET 0 RECORDING
   s" refresh-2" TEST-DROPBOX:ROTATE!
   s" live-token" s" ns-root" RECORDED-CLIENT {: c :}
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   KEPT$ s" refresh-2" T$=
   WITNESS$ s" /oauth2/token" T$=
   c DROPBOX:REFRESH-TOKEN s" refresh-2" T$=
   TEST-DROPBOX:AUTH$ BEARER$ T$=
   c DROPBOX:CLOSE
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT! ;


\ OUTCOME: OWN's account call answered done.
: ACCOUNT-DONE ( -- ) OWN @ DROPBOX:ACCOUNT DROPBOX:DONE? OUTCOME ! ;


\ The refused store throws from the call, which keeps both tokens; the
\ next call stores the token again and goes out with no new refresh.
: UNSTORED-CASE ( -- )
   s" an_unstored_rotation_stays_usable_and_is_retried" T-LABEL
   TEST-DROPBOX:RESET 1 RECORDING
   s" refresh-2" TEST-DROPBOX:ROTATE!
   s" live-token" s" ns-root" RECORDED-CLIENT {: c :}
   c OWN ! false OUTCOME !
   [: ACCOUNT-DONE ;] LOGGED DROPBOX:E-NOT-STORED T=
   SB-RESET
   s" the rotated Dropbox refresh token could not be stored; the store threw "
   SB-APPEND E-FS-IO FMT:SB-INT SB$ LOGGED? TTRUE
   c DROPBOX:REFRESH-TOKEN s" refresh-2" T$=
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   KEPT$ s" refresh-2 refresh-2" T$=
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:AUTH$ BEARER$ T$=
   c DROPBOX:CLOSE
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT! ;


\ Neither a refresh with no refresh_token nor one that answers the same
\ one runs the store.
: UNROTATED-CASE ( -- )
   s" an_unrotated_refresh_never_touches_secret_service" T-LABEL
   TEST-DROPBOX:RESET 0 RECORDING
   s" live-token" s" ns-root" RECORDED-CLIENT {: c :}
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   c DROPBOX:CLOSE
   s" live-token" TEST-DROPBOX:ROTATE!
   s" live-token" s" ns-root" RECORDED-CLIENT {: same :}
   same DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   same DROPBOX:CLOSE
   KEPT-U @ 0 T= ;


\ A client that holds no access token refreshes first; the answer
\ scripted before the call passes the token request by.
: SCRIPTED-REFRESH-CASE ( -- )
   s" scripted answer after a refresh" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" RECORDED-CLIENT {: fresh :}
   503 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   fresh DROPBOX:ACCOUNT RETRY-MS 0 T=
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   fresh DROPBOX:CLOSE ;


\ A refresh Dropbox rate limits waits Retry-After, longer than the body's
\ retry_after; the account call is never sent.
: OAUTH-RATE-LIMIT-PRESERVES-RETRY-AFTER-HEADER ( -- )
   s" oauth_rate_limit_preserves_retry_after_header" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" RECORDED-CLIENT {: fresh :}
   s" /oauth2/token" 429 s" Retry-After" s" 23"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:1}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   fresh DROPBOX:ACCOUNT RETRY-MS 23000 T=
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   fresh DROPBOX:CLOSE ;


\ ALPHABET's rev and content hash, as DOWNLOAD takes them.
: ABC-REV ( -- DROPBOX:rev ) s" 0160a1b2c3d4" DROPBOX:>REV ;
: ABC-HASH ( -- DROPBOX:hash )
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   DROPBOX:>HASH ;


\ A download whose refresh is answered s with body b throws code; the
\ download is never sent, and HTTP-STATUS answers 0, not s.
: REFRESH-FAILED ( n str n -- )
   {: s:n b code:n :}
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" RECORDED-CLIENT OWN !
   s" /oauth2/token" s s" " s" " b TEST-DROPBOX:ROUTE-SCRIPT!
   [: ABC-REV ABC-HASH 0 OWN @ [: 2drop drop ;] DROPBOX:DOWNLOAD
      DROPBOX:DONE? drop ;] LOGGED code T=
   OWN @ DROPBOX:HTTP-STATUS 0 T=
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   OWN @ DROPBOX:CLOSE ;


: FAILED-REFRESH-CASE ( -- )
   s" a failed refresh leaves no status" T-LABEL
   400 S\" {\qerror\q:\qinvalid_request\q}" DROPBOX:E-BAD-REQUEST
   REFRESH-FAILED
   404 s" " DROPBOX:E-STATUS REFRESH-FAILED ;


\ An answer bound to download's route passes get_metadata and list_folder
\ by; the unbound one goes to get_metadata.
: ROUTED-SCRIPT-CASE ( -- )
   s" scripted answer bound to its route" T-LABEL
   TEST-DROPBOX:RESET
   s" /2/files/download" 409 s" " s" "
   S\" {\qerror_summary\q:\qpath/restricted_content/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qrestricted_content\q}}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   500 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   s" []" s" c1" false TEST-DROPBOX:PAGE!
   s" /docs/a.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA RETRY-MS 0 T=
   s" /sync" TEST-CLIENT:MAIN @ [: drop ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" c1" T$=
   ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: drop 2drop ;] DROPBOX:DOWNLOAD
   DROPBOX-ERROR:RESTRICTED-CONTENT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/files/get_metadata /2/files/list_folder /2/files/download" T$= ;


: RATE-CASE ( -- )
   s" rate limited" T-LABEL
   TEST-DROPBOX:RESET
   429 s" Retry-After" s" 7"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:3}}"
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 7000 T= ;


\ A 429 waits the larger of Retry-After and the body's retry_after.
: RATE-BODY-CASE ( -- )
   s" rate limited longer in the body" T-LABEL
   TEST-DROPBOX:RESET
   429 s" Retry-After" s" 2"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:3}}"
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 3000 T= ;


\ A Retry-After date waits until it, at most 15 minutes.
: RATE-DATE-CASE ( -- )
   s" unavailable until a far date" T-LABEL
   TEST-DROPBOX:RESET
   503 s" Retry-After" s" Fri, 31 Dec 9999 23:59:59 GMT" s" "
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 900000 T= ;


\ A body's retry_after alone waits at most 15 minutes.
: RATE-CAP-CASE ( -- )
   s" rate limited past the cap" T-LABEL
   TEST-DROPBOX:RESET
   429 s" " s" "
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:100000}}"
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 900000 T= ;


\ Retry-After seconds may carry more digits than an i64 holds.
: RATE-ZEROS-CASE ( -- )
   s" unavailable for zero-padded seconds" T-LABEL
   TEST-DROPBOX:RESET
   503 s" Retry-After" s" 00000000000000000002" s" "
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 2000 T= ;


\ Retry-After seconds past an i64 wait at most 15 minutes.
: RATE-HUGE-CASE ( -- )
   s" unavailable for seconds past an i64" T-LABEL
   TEST-DROPBOX:RESET
   503 s" Retry-After" s" 99999999999999999999999999" s" "
   TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 900000 T= ;


: BUSY-CASE ( -- )
   s" unavailable" T-LABEL
   TEST-DROPBOX:RESET
   503 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 0 T= ;


: ACCOUNT-DROPPED ( -- ) TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? drop ;


: REDIRECT-CASE ( -- )
   s" redirect" T-LABEL
   TEST-DROPBOX:RESET
   302 s" Location" s" /2/users/get_current_account" s" " TEST-DROPBOX:SCRIPT!
   [: ACCOUNT-DROPPED ;] DROPBOX:E-REDIRECT TTHROWSQ
   TEST-DROPBOX:SEEN$ s" /2/users/get_current_account" T$= ;


: BAD-REQUEST-CASE ( -- )
   s" bad request" T-LABEL
   TEST-DROPBOX:RESET
   400 s" " s" "
   S\" Error in call to API function \qusers/get_current_account\q: bad input"
   TEST-DROPBOX:SCRIPT!
   [: ACCOUNT-DROPPED ;] DROPBOX:E-BAD-REQUEST TTHROWSQ ;


\ ---- the classifier's other answers

: METADATA-DROPPED ( -- )
   s" /docs/a.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? drop ;


\ A write Dropbox is too busy to take is retried at once.
: WRITE-BUSY-CASE ( -- )
   s" too many write operations" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath_write/too_many_write_operations/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qtoo_many_write_operations\q}}}"
   TEST-DROPBOX:SCRIPT!
   s" /busy.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE RETRY-MS 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


\ A delete refused 409 with the WriteError tag answers refused with e.
: WRITE-REFUSED ( str DROPBOX:error -- )
   {: t e:DROPBOX:error :}
   TEST-DROPBOX:RESET
   SB-RESET S\" {\qerror_summary\q:\qpath_write/" SB-APPEND t SB-APPEND
   S\" /\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\q"
   SB-APPEND t SB-APPEND S\" \q}}}" SB-APPEND
   409 s" " s" " SB$ TEST-DROPBOX:SCRIPT!
   s" /held.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE e REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


: WRITE-TAGS-CASE ( -- )
   s" write refused by tag" T-LABEL
   s" access_restricted" DROPBOX-ERROR:ACCESS-RESTRICTED WRITE-REFUSED
   s" team_folder" DROPBOX-ERROR:TEAM-FOLDER WRITE-REFUSED
   s" operation_suppressed" DROPBOX-ERROR:OPERATION-SUPPRESSED WRITE-REFUSED ;


: METADATA-OTHER ( -- )
   s" /docs/a.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:OTHER REFUSED? OUTCOME ! ;


: UNKNOWN-TAG-CASE ( -- )
   s" refusal of an unknown tag" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath/new_tag/\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnew_tag\q}}}"
   TEST-DROPBOX:SCRIPT!
   false OUTCOME !
   [: METADATA-OTHER ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" warn dropbox: files/get_metadata refused: new_tag" LOGGED? TTRUE ;


: UNPARSED-ERROR-CASE ( -- )
   s" refusal that does not parse" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" " s" not json" TEST-DROPBOX:SCRIPT!
   [: METADATA-DROPPED ;] LOGGED DROPBOX:E-ANSWER T=
   s" error dropbox: files/get_metadata answered 409: an error that does not parse"
   LOGGED? TTRUE ;


\ The fake answers 422 to a call whose Path-Root is not the one it expects.
: WRONG-ROOT-CASE ( -- )
   s" path root refused" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-wrong" RECORDED-CLIENT {: off :}
   off DROPBOX:ACCOUNT DROPBOX-ERROR:INVALID-ROOT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   off DROPBOX:CLOSE ;


: TIMEOUT-CASE ( -- )
   s" request timeout" T-LABEL
   TEST-DROPBOX:RESET
   408 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT RETRY-MS 0 T= ;


: TEAPOT-CASE ( -- )
   s" unexpected status" T-LABEL
   TEST-DROPBOX:RESET
   418 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   [: ACCOUNT-DROPPED ;] LOGGED DROPBOX:E-STATUS T=
   s" error dropbox: users/get_current_account answered 418: an unexpected status"
   LOGGED? TTRUE ;


: UNPARSED-ANSWER-CASE ( -- )
   s" answer that does not parse" T-LABEL
   TEST-DROPBOX:RESET
   200 s" " s" " s" not json" TEST-DROPBOX:SCRIPT!
   [: METADATA-DROPPED ;] LOGGED DROPBOX:E-ANSWER T=
   s" error dropbox: files/get_metadata answered 200: an answer that does not parse"
   LOGGED? TTRUE ;


\ A line that is not HTTP on a connection an answer kept open, as the
\ client's calls on one origin reuse one: HTTPC's malformed, not a lost
\ exchange, logged with no cause.
: GARBLED-CASE ( -- )
   s" transport failure" T-LABEL
   TEST-DROPBOX:RESET
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? TTRUE
   TEST-DROPBOX:RESET
   TEST-DROPBOX:GARBLE
   [: METADATA-DROPPED ;] LOGGED DROPBOX:E-TRANSPORT T=
   HTTPC-FAULT:MALFORMED HTTPC:LOST? TFALSE
   SB-RESET s" error dropbox: http files/get_metadata: " SB-APPEND
   HTTPC-FAULT:MALFORMED HTTPC:FAULT$ SB-APPEND
   s"  cause=0" SB-APPEND
   SB$ LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$= ;


: CLASSIFY-CASES ( -- )
   WRITE-BUSY-CASE WRITE-TAGS-CASE UNKNOWN-TAG-CASE UNPARSED-ERROR-CASE WRONG-ROOT-CASE
   TIMEOUT-CASE TEAPOT-CASE UNPARSED-ANSWER-CASE GARBLED-CASE ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

256 constant GOT-CAP
create GOT GOT-CAP allot
variable GOT-U


: GOT+ ( str -- )
   {: a :}
   a GOT GOT-U @ + GOT-CAP GOT-U @ - SPAN:MAKE SPAN:COPY
   a str> nip GOT-U +! ;


: KIND$ ( DROPBOX:kind -- str )
   MATCH DROPBOX:kind
      file OF s" f" ENDOF
      folder OF s" d" ENDOF
      deleted OF s" x" ENDOF
   ;MATCH ;


\ Each entry handed on, as its kind's letter and path_lower, joined by
\ spaces.
: SAW ( ^DROPBOX:entry -- )
   {: e :}
   GOT-U @ 0<> if s"  " GOT+ then
   e DROPBOX-ENTRY:KIND @ KIND$ GOT+
   e DROPBOX-ENTRY:LOWER @ SPAN:$ GOT+ ;


: GOT$ ( -- str ) GOT GOT-U @ >str ;
: LISTING ( -- ) TEST-DROPBOX:RESET 0 GOT-U ! ;


: PAGES-CASE ( -- )
   s" listing pages" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}]"
   s" c1" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/a.txt\q,\qpath_display\q:\q/Sync/A.txt\q,\qrev\q:\q015f\q,\qsize\q:3,\qcontent_hash\q:\qabc\q}]"
   s" c2" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" c3" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" d/sync f/sync/a.txt d/sync/b" T$=
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" c3" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   s" /2/files/list_folder" TEST-DROPBOX:BODIES-TO$
   S\" {\qpath\q:\q/sync\q,\qrecursive\q:true,\qinclude_deleted\q:false}" T$=
   s" /2/files/list_folder/continue" TEST-DROPBOX:BODIES-TO$
   S\" {\qcursor\q:\qc1\q} {\qcursor\q:\qc2\q}" T$= ;


\ A long listing: 12 pages of one folder each but page 5, whose 1200
\ entries take over 64 KiB. Entry n is the folder /sync/d<n>.
12 constant LONG-PAGES
1200 constant WIDE-COUNT
create WIDE BUF:HDR-BYTES allot
\ The entries handed on, those not at their place, and the widest page's
\ entries text in bytes.
variable HANDED
variable ASTRAY
variable WIDEST


: WIDE+ ( str -- ) str> BUF:N>BLEN WIDE BUF:APPEND-SPAN ;


: NTH+ ( n -- )
   FMT:INT$ {: d :}
   S\" {\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/d" WIDE+ d WIDE+
   S\" \q,\qpath_display\q:\q/Sync/d" WIDE+ d WIDE+ S\" \q}" WIDE+ ;


\ The entries array of entries from up to to, in WIDE.
: NTHS ( n n -- str )
   {: from:n to:n :}
   WIDE 1024 BUF:N>BLEN BUF:RESET
   s" [" WIDE+
   to from ?do i from <> if s" ," WIDE+ then i NTH+ loop
   s" ]" WIDE+
   WIDE BUF:SPAN$ BUF:BLEN>N >str ;


: WIDTH ( n -- n ) 5 = if WIDE-COUNT else 1 then ;


\ Queues page j from entry from, and answers the entry after its last.
: LONG-PAGE ( n n -- n )
   {: from:n j:n :}
   from j WIDTH + {: to:n :}
   from to NTHS {: e :}
   e str> nip WIDEST @ max WIDEST !
   SB-RESET s" c" SB-APPEND j FMT:SB-INT
   e SB$ j LONG-PAGES 1 - < TEST-DROPBOX:PAGE!
   to ;


: NTH? ( str n -- bool )
   {: s i:n :}
   s s" /sync/d" STR:STARTS-WITH? 0= if false exit then
   s str> {: p:^ u:n :}
   p 7 + u 7 - >str i FMT:INT$ STR:= ;


: TALLIED ( ^DROPBOX:entry -- )
   {: e :}
   e DROPBOX-ENTRY:LOWER @ SPAN:$ HANDED @ NTH? 0= if 1 ASTRAY +! then
   1 HANDED +! ;


: LONG-CASE ( -- )
   s" listing of 12 pages, one over 64 KiB" T-LABEL
   LISTING 0 HANDED ! 0 ASTRAY ! 0 WIDEST !
   0 LONG-PAGES 0 ?do i LONG-PAGE loop {: total:n :}
   WIDEST @ 65536 > TTRUE
   s" /sync" TEST-CLIENT:MAIN @ [: TALLIED ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   HANDED @ total T=
   ASTRAY @ 0 T=
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" c11" T$= ;



\ A listing of one page that answers done with the cursor, so a case sets
\ the cursor it starts from.
: LISTED ( str -- )
   {: k :}
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}]"
   k false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   LISTING ;


\ A reset leaves the cursor of the last listing that answered done.
: RESET-CASE ( -- )
   s" listing reset" T-LABEL
   s" r0" LISTED
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}]"
   s" r1" true TEST-DROPBOX:PAGE!
   TEST-DROPBOX:PAGE-RESET!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW ;] DROPBOX:LIST
   DROPBOX-ERROR:RESET REFUSED? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" r0" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/list_folder/continue" T$= ;


: CHANGES-DROPPED ( -- )
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR TEST-CLIENT:MAIN @ [: SAW ;] DROPBOX:CHANGES DROPBOX:DONE? drop ;


: STALL-CASE ( -- )
   s" cursor stalled" T-LABEL
   s" s0" LISTED
   S\" [{\q.tag\q:\qdeleted\q,\qname\q:\qb\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" c4" true TEST-DROPBOX:PAGE!
   s" []" s" c4" true TEST-DROPBOX:PAGE!
   [: CHANGES-DROPPED ;] DROPBOX:E-UNUSABLE TTHROWSQ
   GOT$ s" x/sync/b" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   s" /2/files/list_folder/continue" TEST-DROPBOX:BODIES-TO$
   S\" {\qcursor\q:\qs0\q} {\qcursor\q:\qc4\q}" T$= ;


\ A listing's entry is a Metadata union: one with no `.tag` has no kind,
\ and is never handed on as a deleted entry.
: UNTAGGED-LISTED ( -- )
   s" /sync" TEST-CLIENT:MAIN @ [: SAW ;] DROPBOX:LIST DROPBOX:DONE? drop ;


: UNTAGGED-CASE ( -- )
   s" listing entry with no .tag" T-LABEL
   LISTING
   S\" [{\qname\q:\qb\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" u1" false TEST-DROPBOX:PAGE!
   [: UNTAGGED-LISTED ;] DROPBOX:E-ANSWER TTHROWSQ
   GOT$ s" " T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;


: PATHLESS-CASE ( -- )
   s" listing entry with no path_display" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qname\q:\qb\q,\qpath_lower\q:\q/sync/b\q}]"
   s" u1" false TEST-DROPBOX:PAGE!
   [: UNTAGGED-LISTED ;] DROPBOX:E-UNUSABLE TTHROWSQ
   GOT$ s" " T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;


: PROBE$ ( DROPBOX:probe -- str )
   MATCH DROPBOX:probe
      empty OF s" empty" ENDOF
      occupied OF s" occupied" ENDOF
      interrupted OF s" interrupted" ENDOF
   ;MATCH ;


: PROBE-STALL-CASE ( -- )
   s" probe stalled" T-LABEL
   LISTING
   s" []" s" p1" true TEST-DROPBOX:PAGE!
   s" []" s" p1" true TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ DROPBOX:PROBE PROBE$ s" interrupted" T$=
   DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue" T$= ;


\ A page with more that shows an entry not at the path ends the probe.
: PROBE-FIRST-CASE ( -- )
   s" probe stopped at its first entry" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" p1" true TEST-DROPBOX:PAGE!
   s" []" s" p2" false TEST-DROPBOX:PAGE!
   s" /Sync" TEST-CLIENT:MAIN @ DROPBOX:PROBE PROBE$ s" occupied" T$=
   DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;


\ As SAW, each entry marked + if downloadable, else -.
: SAW-DOWNLOADABLE ( ^DROPBOX:entry -- )
   {: e :}
   e SAW
   e DROPBOX-ENTRY:DOWNLOADABLE @ if s" +" else s" -" then GOT+ ;


\ A file that is not downloadable has no content hash; one with no
\ is_downloadable is downloadable.
: UNDOWNLOADABLE-LISTED-CASE ( -- )
   s" listing a file that is not downloadable" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/paper\q,\qpath_display\q:\q/Sync/Paper\q,\qrev\q:\q015e\q,\qsize\q:0,\qis_downloadable\q:false},{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/a.txt\q,\qpath_display\q:\q/Sync/A.txt\q,\qrev\q:\q015f\q,\qsize\q:3,\qcontent_hash\q:\qabc\q}]"
   s" p1" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW-DOWNLOADABLE ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" f/sync/paper- f/sync/a.txt+" T$= ;


\ As SAW, each entry marked + if COMPLETE?, else -.
: SAW-COMPLETE ( ^DROPBOX:entry -- )
   {: e :}
   e SAW
   e DROPBOX:COMPLETE? if s" +" else s" -" then GOT+ ;


\ A downloadable file with no content hash, one whose hash has 63 digits,
\ one whose hash has an uppercase digit and one with an empty rev are
\ each handed on incomplete beside a whole one; none ends the listing.
: INCOMPLETE-LISTED-CASE ( -- )
   s" listing files described incompletely" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/a\q,\qpath_display\q:\q/Sync/a\q,\qrev\q:\q015a\q,\qsize\q:0,\qis_downloadable\q:true}]"
   s" i1" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q,\qrev\q:\q015b\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85\q}]"
   s" i2" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/c\q,\qpath_display\q:\q/Sync/c\q,\qrev\q:\q015c\q,\qsize\q:0,\qcontent_hash\q:\qE3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q}]"
   s" i3" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/d\q,\qpath_display\q:\q/Sync/d\q,\qrev\q:\q\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q}]"
   s" i4" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/e\q,\qpath_display\q:\q/Sync/e\q,\qrev\q:\q015e\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q}]"
   s" i5" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW-COMPLETE ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" f/sync/a- f/sync/b- f/sync/c- f/sync/d- f/sync/e+" T$=
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" i5" T$= ;


\ As SAW, each entry marked + if restricted, else -.
: SAW-RESTRICTED ( ^DROPBOX:entry -- )
   {: e :}
   e SAW
   e DROPBOX-ENTRY:RESTRICTED @ if s" +" else s" -" then GOT+ ;


\ A folder whose sharing_info has no_access or traverse_only is
\ restricted, its `.tag` before or after it; no other entry is.
: RESTRICTED-LISTED-CASE ( -- )
   s" listing restricted folders" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q},{\qpath_lower\q:\q/sync/a\q,\qpath_display\q:\q/Sync/a\q,\qsharing_info\q:{\qread_only\q:false,\qno_access\q:true},\q.tag\q:\qfolder\q}]"
   s" s1" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q,\qsharing_info\q:{\qread_only\q:false,\qtraverse_only\q:true}},{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/c\q,\qpath_display\q:\q/Sync/c\q,\qsharing_info\q:{\qno_access\q:false,\qtraverse_only\q:false}}]"
   s" s2" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/d\q,\qpath_display\q:\q/Sync/d\q},{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/e\q,\qpath_display\q:\q/Sync/e\q,\qrev\q:\q015e\q,\qsize\q:0,\qsharing_info\q:{\qread_only\q:false}}]"
   s" s3" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW-RESTRICTED ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" d/sync- d/sync/a+ d/sync/b+ d/sync/c- d/sync/d- f/sync/e-" T$= ;


\ Only a downloadable file can be complete: not a folder, nor a file
\ that is not downloadable, whatever its rev and hash.
: INCOMPLETE-KINDS-CASE ( -- )
   s" COMPLETE? of a folder and of a file not downloadable" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}]"
   s" k1" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/paper\q,\qpath_display\q:\q/Sync/Paper\q,\qrev\q:\q015f\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q,\qis_downloadable\q:false}]"
   s" k2" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW-COMPLETE ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" d/sync- f/sync/paper-" T$= ;


: WAITED ( bool n -- )
   LISTING TEST-DROPBOX:POLL!
   s" c3" 30 TEST-CLIENT:MAIN @ LONG-POLL DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder/longpoll" T$=
   s" /2/files/list_folder/longpoll" TEST-DROPBOX:BODIES-TO$
   S\" {\qcursor\q:\qc3\q,\qtimeout\q:30}" T$=
   TEST-DROPBOX:LEAKED? TFALSE ;


: POLL-CASE ( -- )
   s" long poll changes" T-LABEL
   true 0 WAITED
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TTRUE
   TEST-CLIENT:MAIN @ DROPBOX:BACKOFF 0 T=
   s" long poll timeout" T-LABEL
   false 0 WAITED
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TFALSE
   TEST-CLIENT:MAIN @ DROPBOX:BACKOFF 0 T=
   s" long poll backoff" T-LABEL
   true 5 WAITED
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TTRUE
   TEST-CLIENT:MAIN @ DROPBOX:BACKOFF 5 T= ;


\ A long poll on a cursor Dropbox no longer takes is refused, unread; one
\ rate limited waits the larger of Retry-After and the body's retry_after.
: LONG-POLL-EXPOSES-RESET-AND-RATE-LIMIT-OUTCOMES ( -- )
   s" long_poll_exposes_reset_and_rate_limit_outcomes" T-LABEL
   LISTING
   409 s" " s" "
   S\" {\qerror_summary\q:\qreset/\q,\qerror\q:{\q.tag\q:\qreset\q}}"
   TEST-DROPBOX:SCRIPT!
   429 s" Retry-After" s" 17"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:1}}"
   TEST-DROPBOX:SCRIPT!
   s" c3" 30 TEST-CLIENT:MAIN @ LONG-POLL DROPBOX-ERROR:RESET REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder/longpoll" T$=
   s" c4" 30 TEST-CLIENT:MAIN @ LONG-POLL RETRY-MS 17000 T=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/longpoll /2/files/list_folder/longpoll" T$= ;


\ ---- a long poll a descriptor ends

\ The pipe a long poll is given, as fd numbers, and the semaphore the fake
\ holds its answer on.
variable WAKE-R
variable WAKE-W
TASK:SEMAPHORE HOLD


: PIPED ( -- ) FD:PIPE-PAIR FD>N WAKE-W ! FD>N WAKE-R ! ;
: UNPIPED ( -- ) WAKE-R @ close WAKE-W @ close ;
\ Makes the pipe's read end readable; the fake's hooks run it.
: STIR ( -- ) WAKE-W @ >FD s" x" FD:WRITE-FULL ;
: STIR-HELD ( -- ) STIR HOLD TASK:WAIT-SEM ;


: WAKE ( -- option<fd> ) WAKE-R @ >FD OPTION:SOME ;
\ A long poll on c3 the pipe's read end ends.
: WAKEABLE ( -- option<DROPBOX:reply> )
   s" c3" 30 WAKE TEST-CLIENT:MAIN @ DROPBOX:WAIT ;


: WOKEN? ( option<DROPBOX:reply> -- bool )
   MATCH option
      none OF true ENDOF
      some OF DROPBOX:DONE? drop false ENDOF
   ;MATCH ;


: SOME-DONE? ( option<DROPBOX:reply> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:DONE? ENDOF
   ;MATCH ;


: TWO-POLLS ( -- )
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/longpoll /2/files/list_folder/longpoll" T$= ;


\ The pipe turns readable while the fake holds the answer: the long poll
\ answers none and logs nothing; the next one dials again and answers.
: WOKEN-CASE ( -- )
   s" a readable descriptor ends the long poll" T-LABEL
   LISTING false 0 TEST-DROPBOX:POLL!
   0 HOLD TASK:SEMAPHORE-INIT PIPED
   [: STIR-HELD ;] TEST-DROPBOX:DURING-POLL!
   [: WAKEABLE WOKEN? OUTCOME ! ;] LOGGED 0 T=
   HOLD TASK:SIGNAL-SEM
   OUTCOME @ TTRUE ERR$ s" " T$=
   UNPIPED PIPED
   WAKEABLE SOME-DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TFALSE
   TWO-POLLS UNPIPED HOLD TASK:SEMAPHORE-DESTROY ;


\ An answer with the pipe never readable, and one sent before the pipe
\ turns readable, are some done.
: UNWOKEN-CASE ( -- )
   s" an answer before the descriptor stirs ends the long poll" T-LABEL
   LISTING true 0 TEST-DROPBOX:POLL! PIPED
   WAKEABLE SOME-DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TTRUE
   [: STIR ;] TEST-DROPBOX:AFTER-POLL!
   WAKEABLE SOME-DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TTRUE
   TWO-POLLS UNPIPED ;


\ ---- files/download

create SUNK 64 allot
variable SUNK-U
variable SUNK-AT
variable SUNK-SIZE
variable BODIES
variable BODY-CODE
16 constant READ-CAP
READ-CAP TYPED-BUFFER READS n
variable READ-COUNT


: SUNK-CLEAR ( -- )
   0 SUNK-U ! -1 SUNK-AT ! -1 SUNK-SIZE ! 0 BODIES ! 0 BODY-CODE !
   0 READ-COUNT ! ;


\ A read's answer into READS, those past its room dropped; once PART bytes
\ are in, a paused server sends the rest.
: TOOK ( n -- )
   {: k:n :}
   READ-COUNT @ {: j:n :}
   j READ-CAP < if k j READS ! 1 READ-COUNT +! then
   SUNK-U @ TEST-DROPBOX:PART >= if TEST-DROPBOX:RESUME-BODY then ;


\ A download's body: read whole into SUNK, at most step bytes a read;
\ BODIES counts its calls.
: PACED ( n n ^DROPBOX:fetch n -- )
   {: at:n size:n f step:n :}
   1 BODIES +! at SUNK-AT ! size SUNK-SIZE !
   begin
      SUNK SUNK-U @ + 64 SUNK-U @ - step min f DROPBOX:READ-BODY
      dup SUNK-U +! dup TOOK
   0= until ;


\ PACED at most 7 bytes a read, so reads end inside a chunk.
: SUNK-BODY ( n n ^DROPBOX:fetch -- ) 7 PACED ;


: SUNK$ ( -- str ) SUNK SUNK-U @ >str ;


\ The alphabet as the file at rev 0160a1b2c3d4.
: ALPHABET ( -- )
   s" /docs/abc.txt" s" /Docs/abc.txt" s" 0160a1b2c3d4"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   26 TEST-DROPBOX:FILE!
   s" 0160a1b2c3d4" s" abcdefghijklmnopqrstuvwxyz" TEST-DROPBOX:CONTENT! ;


: FETCH ( n -- DROPBOX:reply )
   {: at:n :}
   SUNK-CLEAR
   ABC-REV ABC-HASH at TEST-CLIENT:MAIN @ [: SUNK-BODY ;] DROPBOX:DOWNLOAD ;


\ A long poll on c that answers no change, set up as WAITED's.
: POLLED ( ^DROPBOX:client -- )
   {: c :}
   LISTING false 0 TEST-DROPBOX:POLL!
   s" c3" 30 c LONG-POLL DROPBOX:DONE? ASSERT ;


\ A whole download of the alphabet file on c, read to its end.
: DOWNLOADED ( ^DROPBOX:client -- )
   {: c :}
   TEST-DROPBOX:RESET ALPHABET SUNK-CLEAR
   ABC-REV ABC-HASH 0 c [: SUNK-BODY ;] DROPBOX:DOWNLOAD
   DROPBOX:DONE? ASSERT ;


\ A client's calls on each origin reuse one connection; after REST the api and
\ content calls dial again while the long poll's stays: the server counts dials.
: REUSED-CASE ( -- )
   s" connections reused and rested" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" RECORDED-CLIENT {: c :}
   TEST-DROPBOX:ACCEPTED {: n0:n :}
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:ACCEPTED n0 - 1 T=
   c DOWNLOADED c DOWNLOADED
   TEST-DROPBOX:ACCEPTED n0 - 2 T=
   c POLLED
   TEST-DROPBOX:ACCEPTED n0 - 3 T=
   c DROPBOX:REST
   c POLLED
   TEST-DROPBOX:ACCEPTED n0 - 3 T=
   c DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:ACCEPTED n0 - 4 T=
   c DOWNLOADED
   TEST-DROPBOX:ACCEPTED n0 - 5 T=
   c DROPBOX:CLOSE ;


: WHOLE-CASE ( -- )
   s" download whole" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   0 FETCH DROPBOX:DONE? ASSERT
   BODIES @ 1 T=
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   SUNK-AT @ 0 T= SUNK-SIZE @ 26 T=
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:REV @ SPAN:$ s" 0160a1b2c3d4" T$=
   e DROPBOX-ENTRY:SIZE @ 26 T=
   TEST-DROPBOX:SEEN$ s" /2/files/download" T$=
   TEST-DROPBOX:ARG-SENT$ S\" {\qpath\q:\qrev:0160a1b2c3d4\q}" T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   TEST-DROPBOX:TYPE-SENT? TFALSE ;


: RESUME-CASE ( -- )
   s" download resumed" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   10 FETCH DROPBOX:DONE? ASSERT
   BODIES @ 1 T=
   SUNK$ s" klmnopqrstuvwxyz" T$=
   SUNK-AT @ 10 T= SUNK-SIZE @ 26 T=
   TEST-DROPBOX:RANGE-SENT$ s" bytes=10-" T$=
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ 26 T= ;


: UNVERIFIED? ( DROPBOX:reply -- bool ) DROPBOX-ERROR:UNVERIFIED REFUSED? ;


\ The main client still answers a call after a download.
: USABLE ( -- )
   s" /docs/abc.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT ;


\ A download answered status s throws code as any call does,
\ unconverted, and HTTP-STATUS answers s.
: THROWN-DOWNLOAD ( n n -- )
   {: s:n code:n :}
   TEST-DROPBOX:RESET ALPHABET
   s s" " s" " s" bad" TEST-DROPBOX:SCRIPT!
   [: 0 FETCH DROPBOX:DONE? drop ;] LOGGED code T=
   TEST-CLIENT:MAIN @ DROPBOX:HTTP-STATUS s T=
   USABLE ;


: BAD-REQUEST-DOWNLOAD-CASE ( -- )
   s" download answered 400" T-LABEL
   400 DROPBOX:E-BAD-REQUEST THROWN-DOWNLOAD ;


\ 404 is a status no route expects; 403 would answer unlinked.
: UNEXPECTED-DOWNLOAD-CASE ( -- )
   s" download answered 404" T-LABEL
   404 DROPBOX:E-STATUS THROWN-DOWNLOAD ;


: SKEW-CASE ( -- )
   s" download range mismatch" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:SKEW
   10 FETCH UNVERIFIED? ASSERT
   BODIES @ 0 T=
   USABLE ;


\ An empty file at rev 0160e0e0e0e0.
: EMPTY-FILE ( -- )
   s" /docs/none.txt" s" /Docs/none.txt" s" 0160e0e0e0e0"
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   0 TEST-DROPBOX:FILE!
   s" 0160e0e0e0e0" s" " TEST-DROPBOX:CONTENT! ;


\ A 416 whose length is the offset asked is the whole file: the body reads
\ its end at once, nothing restarts and the entry read first is another's.
: COMPLETE-CASE ( -- )
   s" download 416 at the end is complete" T-LABEL
   TEST-DROPBOX:RESET ALPHABET EMPTY-FILE
   s" /docs/none.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   26 FETCH DROPBOX:DONE? ASSERT
   BODIES @ 1 T= SUNK-U @ 0 T=
   SUNK-AT @ 26 T= SUNK-SIZE @ 26 T=
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata /2/files/download" T$=
   TEST-DROPBOX:RANGE-SENT$ s" bytes=26-" T$= ;


: RESTART-CASE ( -- )
   s" download 416 of another size" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   30 FETCH DROPBOX:DONE? ASSERT
   BODIES @ 1 T=
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   SUNK-AT @ 0 T=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ 26 T= ;


\ A 416 with no Range to drop: one from offset 0.
: UNSATISFIABLE! ( -- )
   416 s" Content-Range" s" bytes */26" s" " TEST-DROPBOX:SCRIPT! ;


: UNSATISFIABLE-CASE ( -- )
   s" download 416 on the restart" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   UNSATISFIABLE! UNSATISFIABLE!
   10 FETCH UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/download /2/files/download" T$=
   BODIES @ 0 T=
   USABLE ;


: FIRST-UNSATISFIABLE-CASE ( -- )
   s" download 416 from 0" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   UNSATISFIABLE!
   0 FETCH UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/download" T$=
   BODIES @ 0 T=
   USABLE ;


: UNKNOWN-REV-CASE ( -- )
   s" download unknown rev" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   SUNK-CLEAR
   s" 0160ffffffff" DROPBOX:>REV ABC-HASH 0 TEST-CLIENT:MAIN @
   [: SUNK-BODY ;] DROPBOX:DOWNLOAD
   DROPBOX-ERROR:NOT-FOUND REFUSED? ASSERT
   BODIES @ 0 T= ;


\ OUTCOME: the download from 0, or from 10, answered refused unverified.
: WHOLE-UNVERIFIED ( -- ) 0 FETCH UNVERIFIED? OUTCOME ! ;
: RESUME-UNVERIFIED ( -- ) 10 FETCH UNVERIFIED? OUTCOME ! ;


\ The download fetch makes answers refused unverified, logging one line
\ that holds the text.
: REFUSED-LOGGED ( [ -- ] str -- )
   {: fetch t :}
   false OUTCOME !
   fetch LOGGED 0 T=
   OUTCOME @ TTRUE
   t LOGGED? TTRUE ;


: OTHER-REV-CASE ( -- )
   s" download of another rev" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   s" /docs/abc.txt" s" /Docs/abc.txt" s" 0160aaaaaaaa"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   26 TEST-DROPBOX:FILE!
   s" 0160aaaaaaaa" s" ABCDEFGHIJKLMNOPQRSTUVWXYZ" TEST-DROPBOX:CONTENT!
   s" 0160aaaaaaaa" TEST-DROPBOX:MISFILE
   [: WHOLE-UNVERIFIED ;] s" another rev" REFUSED-LOGGED
   BODIES @ 0 T=
   USABLE ;


\ OUTCOME: ALPHABET's rev asked with another content hash answered
\ refused unverified.
: OTHER-HASH-UNVERIFIED ( -- )
   SUNK-CLEAR
   ABC-REV
   s" ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
   DROPBOX:>HASH 0 TEST-CLIENT:MAIN @ [: SUNK-BODY ;] DROPBOX:DOWNLOAD
   UNVERIFIED? OUTCOME ! ;


: OTHER-HASH-CASE ( -- )
   s" download of another content hash" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   [: OTHER-HASH-UNVERIFIED ;] s" another content hash" REFUSED-LOGGED
   BODIES @ 0 T=
   USABLE ;


TYPED-VARIABLE ZEROED bool


\ SUNK-BODY, then ZEROED, as READ-BODY answered 0.
: ZEROED-BODY ( n n ^DROPBOX:fetch -- ) SUNK-BODY true ZEROED ! ;


\ OUTCOME: the download from 10, read by body, answered refused
\ unverified.
: BODY-UNVERIFIED ( [ n n ^DROPBOX:fetch -- ] -- )
   {: body :}
   SUNK-CLEAR false ZEROED !
   ABC-REV ABC-HASH 10 TEST-CLIENT:MAIN @ body DROPBOX:DOWNLOAD
   UNVERIFIED? OUTCOME ! ;


: READ-UNVERIFIED ( -- ) [: ZEROED-BODY ;] BODY-UNVERIFIED ;


\ A resumed body one byte short fails at its end, before READ-BODY
\ answers 0.
: SHORT-READ-CASE ( -- )
   s" download resumed one byte short" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:SHORTEN
   [: READ-UNVERIFIED ;] s" a body of another length" REFUSED-LOGGED
   ZEROED @ TFALSE
   USABLE ;


\ A resumed body one byte long fails at the read that would take that
\ byte, so the body gets at most the 16 bytes after the offset.
: LONG-READ-CASE ( -- )
   s" download resumed one byte long" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:LENGTHEN
   [: READ-UNVERIFIED ;] s" a body of another length" REFUSED-LOGGED
   ZEROED @ TFALSE
   SUNK-U @ 16 <= ASSERT
   USABLE ;


\ The text of the code READ-BODY throws for a body of another length.
: UNVERIFIED$ ( -- str ) s" a download's answer failed its checks" ;


\ ZEROED-BODY, ending normally where READ-BODY threw E-UNVERIFIED, which
\ BODY-CODE keeps.
: CAUGHT-BODY ( n n ^DROPBOX:fetch -- )
   {: at:n size:n f :}
   [: at size f ZEROED-BODY ;] catch {: code:n :}
   code BODY-CODE !
   code 0= if exit then
   code ERROR:TEXT$ UNVERIFIED$ STR:= 0= if code throw then ;


variable AGAIN-CODE


\ CAUGHT-BODY, then one more read, whose code AGAIN-CODE keeps.
: REREAD-BODY ( n n ^DROPBOX:fetch -- )
   {: at:n size:n f :}
   at size f CAUGHT-BODY
   [: SUNK 1 f DROPBOX:READ-BODY drop ;] catch AGAIN-CODE ! ;


\ A resumed body one byte short whose body catches READ-BODY's throw
\ and reads again: that read throws too, never answering 0, and the
\ answer is still refused, logged once.
: CAUGHT-SHORT-CASE ( -- )
   s" download one byte short, its failure caught" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:SHORTEN
   0 AGAIN-CODE !
   [: [: REREAD-BODY ;] BODY-UNVERIFIED ;]
   s" a body of another length" REFUSED-LOGGED
   ZEROED @ TFALSE
   BODY-CODE @ ERROR:TEXT$ UNVERIFIED$ T$=
   AGAIN-CODE @ ERROR:TEXT$ UNVERIFIED$ T$=
   USABLE ;


\ A held body one byte long, met while its transfer is in flight, whose
\ body catches READ-BODY's throw: the answer is still refused, logged once.
: CAUGHT-LONG-CASE ( -- )
   s" download one byte long, its failure caught" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   s" /docs/five.txt" s" /Docs/five.txt" s" 0160b1b2c3d4"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   5 TEST-DROPBOX:FILE!
   s" 0160b1b2c3d4" s" abcde" TEST-DROPBOX:CONTENT!
   TEST-DROPBOX:HOLD-BODY TEST-DROPBOX:LENGTHEN
   SUNK-CLEAR false ZEROED !
   [: s" 0160b1b2c3d4" DROPBOX:>REV
      s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      DROPBOX:>HASH 0 TEST-CLIENT:MAIN @ [: CAUGHT-BODY ;] DROPBOX:DOWNLOAD
      UNVERIFIED? OUTCOME ! ;] s" a body of another length" REFUSED-LOGGED
   ZEROED @ TFALSE
   SUNK-U @ 5 <= ASSERT
   BODY-CODE @ ERROR:TEXT$ UNVERIFIED$ T$=
   USABLE ;


: WHOLE-FOR-RANGE-CASE ( -- )
   s" download whole for a range" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:IGNORE-RANGE
   [: RESUME-UNVERIFIED ;] s" a whole file for a range" REFUSED-LOGGED
   TEST-DROPBOX:RANGE-SENT$ s" bytes=10-" T$=
   BODIES @ 0 T=
   USABLE ;


: UNASKED-RANGE-CASE ( -- )
   s" download range nobody asked for" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:FORCE-RANGE
   [: WHOLE-UNVERIFIED ;] s" a range nobody asked for" REFUSED-LOGGED
   TEST-DROPBOX:RANGE-SENT? TFALSE
   BODIES @ 0 T=
   USABLE ;


\ A 200 whose Dropbox-API-Result is not JSON: the body never sees it.
: UNPARSED-RESULT-CASE ( -- )
   s" download whose result does not parse" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   200 s" Dropbox-API-Result" s" not json" s" abc" TEST-DROPBOX:SCRIPT!
   [: WHOLE-UNVERIFIED ;]
   s" files/download answered 200: an answer that does not parse"
   REFUSED-LOGGED
   BODIES @ 0 T=
   USABLE ;


: UNPARSED-REFUSAL-CASE ( -- )
   s" download whose error does not parse" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   409 s" " s" " s" not json" TEST-DROPBOX:SCRIPT!
   [: WHOLE-UNVERIFIED ;]
   s" files/download answered 409: an error that does not parse"
   REFUSED-LOGGED
   BODIES @ 0 T=
   USABLE ;


\ The text of the code READ-BODY throws for a transfer lost in the body.
: LOST$ ( -- str ) s" a download's transfer ended inside its body" ;


\ SUNK-BODY, keeping in BODY-CODE the code it ended with.
: CODED-BODY ( n n ^DROPBOX:fetch -- )
   {: at:n size:n f :}
   [: at size f SUNK-BODY ;] catch {: code:n :}
   code BODY-CODE !
   code 0<> if code throw then ;


: CUT-FETCH ( -- )
   SUNK-CLEAR
   ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: CODED-BODY ;] DROPBOX:DOWNLOAD
   RETRY-MS 0 T= ;


\ The next download cut mid-body: the body sees READ-BODY's throw, not an
\ end, and the answer is a retry, not a failure, so no log line.
: BROKEN-CASE ( -- )
   s" download cut mid-body" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:CUT-BODY
   [: CUT-FETCH ;] LOGGED 0 T=
   ERR-U @ 0 T=
   BODIES @ 1 T=
   BODY-CODE @ ERROR:TEXT$ LOST$ T$=
   SUNK-U @ 10 <= TTRUE
   SUNK$ s" abcdefghij" str> SUNK-U @ min >str STR:= TTRUE
   USABLE ;


\ CODED-BODY, ending normally where READ-BODY threw E-BODY-LOST.
: SWALLOWING ( n n ^DROPBOX:fetch -- )
   {: at:n size:n f :}
   [: at size f CODED-BODY ;] catch {: code:n :}
   code 0= if exit then
   code ERROR:TEXT$ LOST$ STR:= 0= if code throw then ;


\ A body that catches the transfer lost inside it and returns: the answer
\ is still a retry, and the client usable.
: SWALLOWED-CASE ( -- )
   s" download cut mid-body, its loss caught" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:CUT-BODY
   SUNK-CLEAR
   ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: SWALLOWING ;] DROPBOX:DOWNLOAD
   RETRY-MS 0 T=
   BODIES @ 1 T=
   BODY-CODE @ ERROR:TEXT$ LOST$ T$=
   USABLE ;


\ A body that fails as a full disk would, before it reads.
: REFUSING ( n n ^DROPBOX:fetch -- ) drop 2drop 77 throw ;


\ DOWNLOAD rethrows its body's throw and leaves the client usable.
: BODY-THROWS-CASE ( -- )
   s" download body throws" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   [: ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: REFUSING ;]
      DROPBOX:DOWNLOAD DROPBOX:DONE? drop ;] 77 TTHROWSQ
   USABLE ;


\ A body that reads to the end, then fails as a hash check would.
: DISOWNING ( n n ^DROPBOX:fetch -- ) SUNK-BODY 78 throw ;


\ A throw after READ-BODY reached the end finds the transfer ended:
\ nothing is cancelled and the code is the body's own.
: LATE-THROW-CASE ( -- )
   s" download body throws after its end" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   SUNK-CLEAR
   [: ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: DISOWNING ;]
      DROPBOX:DOWNLOAD DROPBOX:DONE? drop ;] 78 TTHROWSQ
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   USABLE ;


\ A body that makes one read of at most 5 bytes and returns.
: GLANCING ( n n ^DROPBOX:fetch -- )
   {: f :} 2drop
   1 BODIES +!
   SUNK 5 f DROPBOX:READ-BODY SUNK-U ! ;


\ A body left unread while the server holds the rest is cancelled; the
\ answer is done and the client usable.
: UNREAD-CASE ( -- )
   s" download body left unread" T-LABEL
   TEST-DROPBOX:RESET ALPHABET TEST-DROPBOX:HOLD-BODY
   SUNK-CLEAR
   ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: GLANCING ;] DROPBOX:DOWNLOAD
   DROPBOX:DONE? ASSERT
   BODIES @ 1 T=
   SUNK$ s" abcde" T$=
   USABLE ;


\ A download whose server sends the rest of the body once PART bytes are
\ taken, read step bytes a read.
: PAUSED-FETCH ( n -- DROPBOX:reply )
   {: step:n :}
   TEST-DROPBOX:RESET ALPHABET TEST-DROPBOX:PAUSE-BODY
   SUNK-CLEAR
   ABC-REV ABC-HASH 0 TEST-CLIENT:MAIN @ [: step PACED ;] DROPBOX:DOWNLOAD ;


\ Read 7 bytes a read, a body in two chunks is taken whole.
: PAUSED-CASE ( -- )
   s" download body in two chunks, 7 bytes a read" T-LABEL
   7 PAUSED-FETCH DROPBOX:DONE? ASSERT
   BODIES @ 1 T=
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$= ;


\ Read 64 bytes a read, each read answers one chunk whole.
: CHUNKED-CASE ( -- )
   s" download body in two chunks, 64 bytes a read" T-LABEL
   64 PAUSED-FETCH DROPBOX:DONE? ASSERT
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   READ-COUNT @ 3 T=
   0 READS @ 10 T= 1 READS @ 16 T= 2 READS @ 0 T= ;


\ An empty file: the body reads its end at once.
: EMPTY-CASE ( -- )
   s" download of an empty file" T-LABEL
   TEST-DROPBOX:RESET EMPTY-FILE
   SUNK-CLEAR
   s" 0160e0e0e0e0" DROPBOX:>REV
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   DROPBOX:>HASH 0 TEST-CLIENT:MAIN @ [: SUNK-BODY ;] DROPBOX:DOWNLOAD
   DROPBOX:DONE? ASSERT
   BODIES @ 1 T= SUNK-U @ 0 T=
   SUNK-AT @ 0 T= SUNK-SIZE @ 0 T= ;


: DOWNLOAD-CASES ( -- )
   WHOLE-CASE RESUME-CASE SKEW-CASE COMPLETE-CASE RESTART-CASE
   UNSATISFIABLE-CASE FIRST-UNSATISFIABLE-CASE UNKNOWN-REV-CASE
   OTHER-REV-CASE OTHER-HASH-CASE SHORT-READ-CASE LONG-READ-CASE
   CAUGHT-SHORT-CASE CAUGHT-LONG-CASE
   WHOLE-FOR-RANGE-CASE UNASKED-RANGE-CASE
   UNPARSED-RESULT-CASE UNPARSED-REFUSAL-CASE
   BROKEN-CASE SWALLOWED-CASE BODY-THROWS-CASE LATE-THROW-CASE UNREAD-CASE
   PAUSED-CASE CHUNKED-CASE EMPTY-CASE BAD-REQUEST-DOWNLOAD-CASE
   UNEXPECTED-DOWNLOAD-CASE ;


\ ---- delete_v2, create_folder_v2 and the code exchange

: KIND? ( DROPBOX:kind -- bool )
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:KIND @ DROPBOX-KIND:EQ ;


: LOWER$ ( -- str ) TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$ ;


: DELETED-FILE ( str str -- )
   {: l r :}
   l l r
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   0 TEST-DROPBOX:FILE! ;


\ Queues a 503 that asks to wait 3 s.
: BUSY! ( -- ) 503 s" Retry-After" s" 3" s" " TEST-DROPBOX:SCRIPT! ;


\ Queues a 503 that asks no wait.
: UNAVAILABLE! ( -- ) 503 s" " s" " s" " TEST-DROPBOX:SCRIPT! ;


\ The next call answers done with a body that does not parse.
: GARBLED! ( -- ) 200 s" " s" " s" []" TEST-DROPBOX:SCRIPT! ;


\ No get_metadata went out since RESET.
: NO-LOOKUP ( -- ) s" /2/files/get_metadata" TEST-DROPBOX:CALLS 0 T= ;


\ The next call answers path_write/conflict, as delete_v2 does.
: DELETE-CONFLICT! ( -- )
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath_write/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}}}}"
   TEST-DROPBOX:SCRIPT! ;


: DELETE-CONFLICT-CASE ( -- )
   s" delete conflict" T-LABEL
   TEST-DROPBOX:RESET
   s" /del.txt" s" rev-del" DELETED-FILE
   s" /del.txt" s" rev-other" TEST-CLIENT:MAIN @ DROPBOX:DELETE
   DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   s" /del.txt" s" rev-del" TEST-CLIENT:MAIN @ DROPBOX:DELETE DROPBOX:DONE? ASSERT
   DROPBOX-KIND:FILE KIND? TTRUE
   LOWER$ s" /del.txt" T$=
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:REV @ SPAN:$ s" rev-del" T$=
   s" /del.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:NOT-FOUND REFUSED? ASSERT ;


: DELETE-MISSING-CASE ( -- )
   s" delete not found" T-LABEL
   TEST-DROPBOX:RESET
   s" /absent" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE DROPBOX:DONE? ASSERT
   DROPBOX-KIND:DELETED KIND? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


\ A resent delete that Dropbox already applied, refused as a conflict.
: DELETE-GONE-CASE ( -- )
   s" delete conflict on a gone path" T-LABEL
   TEST-DROPBOX:RESET
   DELETE-CONFLICT!
   s" /gone.txt" s" rev-gone" TEST-CLIENT:MAIN @ DROPBOX:DELETE
   DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


: LOST-DELETE-CASE ( -- )
   s" lost delete" T-LABEL
   TEST-DROPBOX:RESET
   s" /lost.txt" s" rev-lost" DELETED-FILE
   TEST-DROPBOX:LOSE
   s" /lost.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE UNVERIFIED? ASSERT
   NO-LOOKUP ;


\ A delete answered with the entry at /b.txt as its path_lower.
: DELETE-ELSEWHERE-CASE ( -- )
   s" delete answered at another path" T-LABEL
   TEST-DROPBOX:RESET
   S\" /\xc3\x84.txt" s" rev-a" DELETED-FILE
   200 s" " s" "
   S\" {\qmetadata\q:{\q.tag\q:\qfile\q,\qpath_lower\q:\q/b.txt\q,\qpath_display\q:\q/\xc3\x84.txt\q,\qrev\q:\qrev-a\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q}}"
   TEST-DROPBOX:SCRIPT!
   S\" /\xc3\x84.txt" s" rev-a" TEST-CLIENT:MAIN @ DROPBOX:DELETE UNVERIFIED? ASSERT
   NO-LOOKUP ;


\ A delete answered with the file at another rev than the one asked.
: DELETE-REV-CASE ( -- )
   s" delete answered at another rev" T-LABEL
   TEST-DROPBOX:RESET
   s" /rev.txt" s" rev-new" DELETED-FILE
   200 s" " s" "
   S\" {\qmetadata\q:{\q.tag\q:\qfile\q,\qpath_lower\q:\q/rev.txt\q,\qpath_display\q:\q/rev.txt\q,\qrev\q:\qrev-old\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q}}"
   TEST-DROPBOX:SCRIPT!
   s" /rev.txt" s" rev-new" TEST-CLIENT:MAIN @ DROPBOX:DELETE UNVERIFIED? ASSERT
   NO-LOOKUP ;


: FOLDER-CONFLICT-CASE ( -- )
   s" create-folder conflict" T-LABEL
   TEST-DROPBOX:RESET
   s" /made" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER DROPBOX:DONE? ASSERT
   DROPBOX-KIND:FOLDER KIND? TTRUE
   LOWER$ s" /made" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/json" T$=
   s" /made" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER
   DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   s" /taken" s" rev-taken" DELETED-FILE
   s" /taken" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER
   DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/create_folder_v2 /2/files/create_folder_v2"
   T$= ;


: LOST-FOLDER-CASE ( -- )
   s" lost create-folder" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:LOSE
   s" /lost-made" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER UNVERIFIED? ASSERT
   NO-LOOKUP ;


\ A create-folder of /Ä answered with the folder at /b as its path_lower.
: FOLDER-ELSEWHERE-CASE ( -- )
   s" create-folder answered at another path" T-LABEL
   TEST-DROPBOX:RESET
   s" /2/files/create_folder_v2" 200 s" " s" "
   S\" {\qmetadata\q:{\qname\q:\qb\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/b\q,\qpath_display\q:\q/b\q}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   S\" /\xc3\x84" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER UNVERIFIED? ASSERT
   NO-LOOKUP ;


: UNAVAILABLE-DELETE-CASE ( -- )
   s" delete answered 503" T-LABEL
   TEST-DROPBOX:RESET UNAVAILABLE!
   s" /down.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


: UNAVAILABLE-FOLDER-CASE ( -- )
   s" create-folder answered 503" T-LABEL
   TEST-DROPBOX:RESET UNAVAILABLE!
   s" /down-made" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/create_folder_v2" T$= ;


\ Dropbox may have applied it, but asks to wait: the delete waits.
: WAITED-DELETE-CASE ( -- )
   s" delete answered 503 with a wait" T-LABEL
   TEST-DROPBOX:RESET BUSY!
   s" /busy.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE RETRY-MS 3000 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


: GARBLED-DELETE ( -- )
   s" /garbled.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE UNVERIFIED? OUTCOME ! ;


: GARBLED-DELETE-CASE ( -- )
   s" delete answer that does not parse" T-LABEL
   TEST-DROPBOX:RESET GARBLED!
   false OUTCOME !
   [: GARBLED-DELETE ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" error dropbox: files/delete_v2 answered 200: an answer that does not parse"
   LOGGED? TTRUE
   NO-LOOKUP ;


\ A rate limit applies nothing, so the delete waits it out.
: RATED-DELETE-CASE ( -- )
   s" delete rate limited" T-LABEL
   TEST-DROPBOX:RESET
   429 s" Retry-After" s" 3" s" " TEST-DROPBOX:SCRIPT!
   s" /rated.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE RETRY-MS 3000 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


\ A delete refused for an expired token, whose refresh is lost: retry 0,
\ not resent, so the path is still there.
: LOST-REFRESH-CASE ( -- )
   s" refresh lost during a delete" T-LABEL
   TEST-DROPBOX:RESET
   s" /held.txt" s" rev-held" DELETED-FILE
   TEST-DROPBOX:EXPIRE TEST-DROPBOX:CUT-TOKEN
   s" /held.txt" s" " TEST-CLIENT:MAIN @ DROPBOX:DELETE RETRY-MS 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2 /oauth2/token" T$=
   s" /held.txt" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/files/delete_v2 /oauth2/token /oauth2/token /2/files/get_metadata"
   T$= ;


: EXCHANGE-CASE ( -- )
   s" code exchange" T-LABEL
   TEST-DROPBOX:RESET
   TEST-CLIENT:MAIN @ DROPBOX:REFRESH-TOKEN s" live-token" T$=
   s" fake-code" s" fake-verifier" TEST-DROPBOX:GRANT!
   s" " s" ns-root" RECORDED-CLIENT {: link :}
   s" fake-code" s" fake-verifier" link DROPBOX:EXCHANGE DROPBOX:DONE? ASSERT
   link DROPBOX:REFRESH-TOKEN s" fake-refresh-granted" T$=
   link DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:LEAKED? TFALSE
   link DROPBOX:CLOSE ;


\ Bytes a form reserves: each must reach Dropbox encoded.
: RESERVED$ ( -- str ) s" a+b&c=d%e f" ;


: RESERVED-REFRESH-CASE ( -- )
   s" refresh token with reserved bytes" T-LABEL
   TEST-DROPBOX:RESET
   s" fake-key" RESERVED$ TEST-DROPBOX:ACCEPT!
   RESERVED$ s" ns-root" RECORDED-CLIENT {: odd :}
   odd DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   odd DROPBOX:CLOSE
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT! ;


: RESERVED-CODE-CASE ( -- )
   s" code with reserved bytes" T-LABEL
   TEST-DROPBOX:RESET
   RESERVED$ s" fake-verifier" TEST-DROPBOX:GRANT!
   s" " s" ns-root" RECORDED-CLIENT {: link :}
   RESERVED$ s" fake-verifier" link DROPBOX:EXCHANGE DROPBOX:DONE? ASSERT
   link DROPBOX:REFRESH-TOKEN s" fake-refresh-granted" T$=
   link DROPBOX:CLOSE ;


\ A refresh token's bytes reach Dropbox as form_urlencoded writes them: `~`
\ escaped, `*` as it is and a space as `+`.
: FORM-BYTES-CASE ( -- )
   s" refresh token form-encoded" T-LABEL
   TEST-DROPBOX:RESET
   s" fake-key" s" a~b*c d" TEST-DROPBOX:ACCEPT!
   s" a~b*c d" s" ns-root" RECORDED-CLIENT {: odd :}
   odd DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   s" /oauth2/token" TEST-DROPBOX:BODIES-TO$
   s" grant_type=refresh_token&refresh_token=a%7Eb*c+d&client_id=fake-key" T$=
   odd DROPBOX:CLOSE
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT! ;


\ OUTCOME: OWN's exchange of a dead code answered unlinked.
: DEAD-EXCHANGE ( -- )
   s" dead-code" s" fake-verifier" OWN @ DROPBOX:EXCHANGE UNLINKED?
   OUTCOME ! ;


\ A dead code answers unlinked and logs nothing.
: DEAD-CODE-CASE ( -- )
   s" exchange invalid grant" T-LABEL
   TEST-DROPBOX:RESET
   s" " s" ns-root" RECORDED-CLIENT {: link :}
   link OWN ! false OUTCOME !
   [: DEAD-EXCHANGE ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   ERR-U @ 0 T=
   link DROPBOX:REFRESH-TOKEN s" " T$=
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   link DROPBOX:CLOSE ;


\ The documented protocol in order: a code exchange and the account on a
\ client with no root, as linking has none yet; then the root's metadata
\ under its Path-Root, two pages, the second a file that is not
\ downloadable, a long poll and an exact download.
: OAUTH-LISTING-LONGPOLL-AND-EXACT-DOWNLOAD-USE-DOCUMENTED-PROTOCOL ( -- )
   s" oauth_listing_longpoll_and_exact_download_use_documented_protocol"
   T-LABEL
   LISTING s" " TEST-DROPBOX:ROOT!
   s" fake-code" s" fake-verifier" TEST-DROPBOX:GRANT!
   s" " s" " RECORDED-CLIENT {: link :}
   s" fake-code" s" fake-verifier" link DROPBOX:EXCHANGE DROPBOX:DONE? ASSERT
   link DROPBOX:ACCOUNT DROPBOX:DONE? ASSERT
   link DROPBOX:ACCOUNT-ID s" dbid:account" T$=
   link DROPBOX:ROOT-NAMESPACE s" namespace" T$=
   TEST-DROPBOX:AUTH$ BEARER$ T$=
   TEST-DROPBOX:ROOT-SENT? TFALSE
   link DROPBOX:CLOSE
   s" ns-root" TEST-DROPBOX:ROOT!
   200 s" " s" "
   S\" {\q.tag\q:\qfolder\q,\qname\q:\qSync\q,\qid\q:\qid:s\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}"
   TEST-DROPBOX:SCRIPT!
   s" /sync" TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? ASSERT
   DROPBOX-KIND:FOLDER KIND? TTRUE
   TEST-DROPBOX:ROOT-SENT$ S\" {\q.tag\q:\qroot\q,\qroot\q:\qns-root\q}" T$=
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q},{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync/folder\q,\qpath_display\q:\q/Sync/Folder\q},{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/alpha.txt\q,\qpath_display\q:\q/Sync/Alpha.txt\q,\qrev\q:\qrev-a\q,\qsize\q:0,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q,\qis_downloadable\q:true}]"
   s" cursor-a" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfile\q,\qpath_lower\q:\q/sync/paper\q,\qpath_display\q:\q/Sync/Paper\q,\qrev\q:\qrev-paper\q,\qsize\q:0,\qis_downloadable\q:false,\qexport_info\q:{\qexport_as\q:\qhtml\q}}]"
   s" cursor-b" false TEST-DROPBOX:PAGE!
   s" /sync" TEST-CLIENT:MAIN @ [: SAW-DOWNLOADABLE ;] DROPBOX:LIST DROPBOX:DONE? ASSERT
   GOT$ s" d/sync+ d/sync/folder+ f/sync/alpha.txt+ f/sync/paper-" T$=
   TEST-CLIENT:MAIN @ DROPBOX:CURSOR s" cursor-b" T$=
   true 2 TEST-DROPBOX:POLL!
   s" cursor-b" 30 TEST-CLIENT:MAIN @ LONG-POLL DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:CHANGED? TTRUE
   TEST-CLIENT:MAIN @ DROPBOX:BACKOFF 2 T=
   ALPHABET
   0 FETCH DROPBOX:DONE? ASSERT
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   TEST-DROPBOX:ARG-SENT$ S\" {\qpath\q:\qrev:0160a1b2c3d4\q}" T$=
   TEST-DROPBOX:SEEN$
   s" /oauth2/token /2/users/get_current_account /2/files/get_metadata /2/files/list_folder /2/files/list_folder/continue /2/files/list_folder/longpoll /2/files/download"
   T$=
   TEST-DROPBOX:LEAKED? TFALSE ;


\ ---- files/upload and upload sessions

$2000000 constant CHUNK
TYPED-VARIABLE HASHER DROPBOX:hasher
TYPED-VARIABLE UP DROPBOX:upload
create STAGE 256 allot
variable STAGE-U
create EXPECTED 64 allot
variable SHOWN
variable SHOWS
\ UPLOAD's checkpoints: the session and offset of the last, and the calls.
create CHECKED-ID 64 allot
variable CHECKED-ID-U
variable CHECKED
variable CHECKS
\ The count of accepted bytes at which FAULT strikes, -1 for none, and
\ the strikes left there.
variable FAULT-AT
variable STRIKES
ENUM fault
   cut cut-twice lose close unfound applied offset denied busy garbled
   revless unavailable backoff ;ENUM
TYPED-VARIABLE FAULT fault


\ Byte i of every patterned file is i mod 256.
: PATTERN ( ^u8 n -- )
   {: a:^ u:n :}
   u 0 ?do i 255 and a i + c! loop ;


: HASHED ( ^u8 n -- str )
   {: a:^ u:n :}
   HASHER DROPBOX:HASH-BEGIN
   a u HASHER DROPBOX:HASH-FEED
   HASHER DROPBOX:HASH-END ;


\ Pinned by Python's hashlib over the same pattern.
: HASH-CASE ( -- )
   s" content hash" T-LABEL
   DROPBOX:BLOCK 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: a:^ cap:NUM:alloc-byte-len :}
   a DROPBOX:BLOCK 1+ PATTERN
   a 0 HASHED
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   a 1 HASHED
   s" 1406e05881e299367766d313e26c05564ec91bf721d31726bd6e46e60689539a" T$=
   a DROPBOX:BLOCK HASHED
   s" 894bbb52d1212d6bcbe9967f1a2169138c4d4af0c8dfbaeae86cd1d3f0c03faf" T$=
   a DROPBOX:BLOCK 1+ HASHED
   s" 9eb62f609dee341fdcc4521fd6d5a78d9e5c5bb36d844618d9e8d1b32f28ba95" T$=
   a cap MEM:RELEASE-BYTES ;


: STAGE$ ( -- str ) STAGE STAGE-U @ >str ;


\ TMPDIR/<name>, made fresh.
: STAGE! ( str -- ) STAGE IN-TMP STAGE-U ! ;


\ Writes the bytes as the stage, opens it and removes its name before any
\ check can end the run, and readies UP to upload them to path over rev.
: STAGED ( str str str -- )
   {: b p r :}
   STAGE$ b FS:WRITE-ALL
   STAGE$ FS:OPEN-SIZED STAGE$ FS:REMOVE-FILE ASSERT {: f:fd size:n :}
   f UP DROPBOX-UPLOAD:FD !
   size UP DROPBOX-UPLOAD:SIZE !
   b str> HASHED str> EXPECTED swap BYTE-COPY
   EXPECTED 64 SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH !
   p str> SPAN:MAKE UP DROPBOX-UPLOAD:PATH !
   r str> SPAN:MAKE UP DROPBOX-UPLOAD:REV !
   s" " str> SPAN:MAKE UP DROPBOX-UPLOAD:SESSION !
   0 UP DROPBOX-UPLOAD:CONFIRMED ! ;


: UNSTAGED ( -- ) UP DROPBOX-UPLOAD:FD @ FD>N close ;


: EXPECTED$ ( -- str ) EXPECTED 64 >str ;


\ The next call answers lookup_failed/not_found, as Dropbox answers a
\ finish whose session it no longer holds, or one it already applied.
: UNFOUND ( -- )
   409 s" " s" "
   S\" {\qerror_summary\q:\qlookup_failed/not_found/...\q,\qerror\q:{\q.tag\q:\qlookup_failed\q,\qlookup_failed\q:{\q.tag\q:\qnot_found\q}}}"
   TEST-DROPBOX:SCRIPT! ;


\ Dropbox holds the big file, as a finish it applied leaves it.
: APPLIED ( -- )
   s" /big.bin" s" /Big.bin" s" rev-applied" EXPECTED$ CHUNK 1+
   TEST-DROPBOX:FILE! ;


\ The next call finds the big file with the upload's content hash and no
\ rev, which Dropbox does not answer for a file it committed.
: REVLESS! ( -- )
   SB-RESET
   S\" {\q.tag\q:\qfile\q,\qname\q:\qBig.bin\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/big.bin\q,\qpath_display\q:\q/Big.bin\q,\qsize\q:"
   SB-APPEND CHUNK 1+ FMT:INT$ SB-APPEND
   S\" ,\qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND
   S\" \q,\qis_downloadable\q:true}" SB-APPEND
   200 s" " s" " SB$ TEST-DROPBOX:SCRIPT! ;


\ The next call to the route answers the upload's file, n bytes with its
\ content hash, at /b.txt.
: ELSEWHERE! ( str n -- )
   {: r n:n :}
   SB-RESET
   S\" {\qname\q:\qb.txt\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/b.txt\q,\qpath_display\q:\q/b.txt\q,\qrev\q:\q0170b\q,\qsize\q:"
   SB-APPEND n FMT:INT$ SB-APPEND
   S\" ,\qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND
   S\" \q,\qis_downloadable\q:true}" SB-APPEND
   r 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT! ;


\ The next call refused with incorrect_offset at 0, short of any chunk's end.
: OFFSET! ( -- )
   409 s" " s" "
   S\" {\qerror_summary\q:\qincorrect_offset/...\q,\qerror\q:{\q.tag\q:\qincorrect_offset\q,\qcorrect_offset\q:0}}"
   TEST-DROPBOX:SCRIPT! ;


: STRIKE ( -- )
   FAULT @ MATCH fault
      cut OF TEST-DROPBOX:CUT ENDOF
      cut-twice OF TEST-DROPBOX:CUT TEST-DROPBOX:CUT ENDOF
      lose OF TEST-DROPBOX:LOSE ENDOF
      close OF TEST-DROPBOX:CLOSE-SESSIONS ENDOF
      unfound OF UNFOUND ENDOF
      applied OF UNFOUND APPLIED ENDOF
      offset OF OFFSET! ENDOF
      denied OF UNFOUND TEST-DROPBOX:DENY ENDOF
      busy OF UNFOUND BUSY! ENDOF
      garbled OF GARBLED! APPLIED ENDOF
      revless OF UNFOUND REVLESS! ENDOF
      unavailable OF UNAVAILABLE! ENDOF
      backoff OF BUSY! ENDOF
   ;MATCH ;


\ UPLOAD's progress: the last count and the calls, and the fault while
\ strikes are left.
: PROGRESSED ( n -- )
   {: n:n :}
   n SHOWN ! 1 SHOWS +!
   n FAULT-AT @ <> if exit then
   -1 STRIKES +!
   STRIKES @ 0= if -1 FAULT-AT ! then
   STRIKE ;


: CHECKPOINTED ( str n -- )
   {: sid:str n:n :}
   sid str> 64 min {: a:^ u:n :}
   a CHECKED-ID u BYTE-COPY u CHECKED-ID-U !
   n CHECKED ! 1 CHECKS +! ;


: CHECKED-ID$ ( -- str ) CHECKED-ID CHECKED-ID-U @ >str ;


: SEND ( -- DROPBOX:reply )
   0 SHOWN ! 0 SHOWS ! 0 CHECKED-ID-U ! 0 CHECKED ! 0 CHECKS !
   UP TEST-CLIENT:MAIN @ [: PROGRESSED ;] [: CHECKPOINTED ;] DROPBOX:UPLOAD ;


: ENTRY-HASH$ ( -- str )
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$ ;


\ Each mutation of the four sent once, conditional where it can be: an add,
\ an add at a path Dropbox-API-Arg escapes to ASCII, an update over the
\ rev held, a delete of the rev held and a folder.
: CONDITIONAL-MUTATIONS-USE-STRICT-DOCUMENTED-REQUESTS ( -- )
   s" conditional_mutations_use_strict_documented_requests" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   SEND DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:LOWER @ SPAN:$ s" /docs/up.txt" T$=
   e DROPBOX-ENTRY:SIZE @ 12 T=
   ENTRY-HASH$ EXPECTED$ T$=
   SHOWN @ 12 T= SHOWS @ 1 T= CHECKS @ 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/octet-stream" T$=
   SB-RESET S\" {\qpath\q:\q/Docs/Up.txt\q,\qmode\q:\qadd\q," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED
   s" cafe.txt" STAGE!
   s" hello cafe" S\" /Caf\xc3\xa9/\xe9\x9b\xaa.txt" s" " STAGED
   SEND DROPBOX:DONE? ASSERT
   SB-RESET S\" {\qpath\q:\q/Caf\\u00e9/\\u96ea.txt\q,\qmode\q:\qadd\q," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED
   s" /replace.txt" s" /Replace.txt" s" expected-rev" EXPECTED$ 12
   TEST-DROPBOX:FILE!
   s" up.txt" STAGE! s" hello upload" s" /Replace.txt" s" expected-rev" STAGED
   SEND DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:REV @ SPAN:$ s" expected-rev" STR:= TFALSE
   SB-RESET S\" {\qpath\q:\q/Replace.txt\q,\qmode\q:" SB-APPEND
   S\" {\q.tag\q:\qupdate\q,\qupdate\q:\qexpected-rev\q}," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED
   s" /delete.txt" s" delete-rev" DELETED-FILE
   s" /delete.txt" s" delete-rev" TEST-CLIENT:MAIN @ DROPBOX:DELETE DROPBOX:DONE? ASSERT
   LOWER$ s" /delete.txt" T$=
   s" /folder" TEST-CLIENT:MAIN @ DROPBOX:CREATE-FOLDER DROPBOX:DONE? ASSERT
   DROPBOX-KIND:FOLDER KIND? TTRUE
   LOWER$ s" /folder" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/upload /2/files/upload /2/files/upload /2/files/delete_v2 /2/files/create_folder_v2"
   T$=
   s" Bearer sl.fake-" {: b :}
   TEST-DROPBOX:AUTH$ str> b str> nip min >str b T$=
   TEST-DROPBOX:ROOT-SENT$ S\" {\q.tag\q:\qroot\q,\qroot\q:\qns-root\q}" T$= ;


\ The path holds other bytes at rev 0160a; an update over rev 0160b.
: CONFLICT-CASE ( -- )
   s" upload conflict" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" /docs/up.txt" s" /Docs/Up.txt" s" 0160a"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   5 TEST-DROPBOX:FILE!
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" 0160b" STAGED
   SEND DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   SB-RESET S\" {\qpath\q:\q/Docs/Up.txt\q,\qmode\q:" SB-APPEND
   S\" {\q.tag\q:\qupdate\q,\qupdate\q:\q0160b\q}," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED ;


\ Dropbox already holds these bytes, as after an upload that reached it
\ but whose answer was lost.
: HELD-CASE ( -- )
   s" upload already held" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   s" /docs/up.txt" s" /Docs/Up.txt" s" 0160a" EXPECTED$ 12 TEST-DROPBOX:FILE!
   SEND DROPBOX-ERROR:CONFLICT REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   UNSTAGED ;


: NON-ASCII-CASE ( -- )
   s" non-ascii path" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" cafe.txt" STAGE! s" hello cafe" S\" /Docs/Caf\xc3\xa9.txt" s" " STAGED
   SEND DROPBOX:DONE? ASSERT
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$
   S\" /docs/caf\xc3\xa9.txt" T$=
   S\" {\qpath\q:\q/Docs/Caf\\u00e9.txt\q," {: x :}
   TEST-DROPBOX:ARG-SENT$ str> x str> nip min >str x T$=
   UNSTAGED ;


\ The code SEND throws, 0 for none, with what it logged in ERR$.
: SEND-LOGGED ( -- n ) [: SEND DROPBOX:DONE? drop ;] LOGGED ;


\ An upload to /Docs/CAFÉ.txt answered with its file at /b.txt as its
\ path_lower.
: OTHER-CASE-CASE ( -- )
   s" committed path elsewhere" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" cafe.txt" STAGE! s" hello cafe" S\" /Docs/CAF\xc3\x89.txt" s" " STAGED
   s" /2/files/upload" 10 ELSEWHERE!
   SEND UNVERIFIED? ASSERT
   NO-LOOKUP
   UNSTAGED ;


\ ERR$ holds the line UPLOAD logs for a failure of UP's stage.
: STAGE-LOGGED? ( str -- bool )
   {: why :}
   SB-RESET s" error dropbox: upload of " SB-APPEND
   UP DROPBOX-UPLOAD:PATH @ SPAN:$ SB-APPEND
   s" : " SB-APPEND why SB-APPEND
   ERR$ SB$ STR:CONTAINS? ;


\ A stage shorter than the size UPLOAD was given.
: SHORT-STAGE-CASE ( -- )
   s" stage shorter than its size" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   20 UP DROPBOX-UPLOAD:SIZE !
   SEND-LOGGED DROPBOX:E-STAGE T=
   s" the stage is shorter than its size" STAGE-LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


\ A stage open for writing alone, whose read the kernel refuses: EBADF.
: REFUSED-STAGE-CASE ( -- )
   s" stage read refused" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   UNSTAGED STAGE$ FS:OPEN-APPEND-FD >FD UP DROPBOX-UPLOAD:FD !
   SEND-LOGGED DROPBOX:E-STAGE T=
   s" the stage's read was refused, errno 9" STAGE-LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


\ The code SEND throws with the reads of UP's stage failed as the fault
\ says, and its log in ERR$; the real transfer is back however SEND ends.
: READ-FAILED ( read-fault -- n )
   UP DROPBOX-UPLOAD:FD @ FD>N swap FAIL-READS
   [: SEND-LOGGED ;] [: ;FAIL-READS ;] finally ;


\ The stage, readied for a single upload with no fault from the fake.
: SMALL-STAGED ( -- )
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED ;


\ The ring full: the buffer stays UPLOAD's, which it releases.
: FULL-READ-CASE ( -- )
   s" stage read refused by a full ring" T-LABEL
   SMALL-STAGED
   construct read-fault full READ-FAILED E-AIO-FULL T=
   OFFERED @ MAPPED:LIVE? TFALSE
   ERR-U @ 0 T=
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


\ The enter refused: the kernel may yet run the read, so UPLOAD leaves
\ its buffer mapped.
: ENTERED-READ-CASE ( -- )
   s" stage read's enter refused" T-LABEL
   SMALL-STAGED
   construct read-fault entered READ-FAILED E-AIO-ENTER T=
   OFFERED @ MAPPED:LIVE? TTRUE
   OFFERED @ OFFERED-CAP @ MEM:RELEASE-BYTES
   ERR-U @ 0 T=
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


: TIMED-OUT-READ-CASE ( -- )
   s" stage read timed out" T-LABEL
   SMALL-STAGED
   construct read-fault timed-out READ-FAILED DROPBOX:E-STAGE T=
   s" the stage's read timed out" STAGE-LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


: CANCELLED-READ-CASE ( -- )
   s" stage read cancelled" T-LABEL
   SMALL-STAGED
   construct read-fault cancelled READ-FAILED DROPBOX:E-STAGE T=
   s" the stage's read was cancelled" STAGE-LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   UNSTAGED ;


: SEND-UNLINKED ( -- ) SEND UNLINKED? OUTCOME ! ;


: SEND-UNVERIFIED ( -- ) SEND UNVERIFIED? OUTCOME ! ;


\ An upload whose answer does not parse, logged, though Dropbox holds the
\ file with its content hash.
: GARBLED-SINGLE-CASE ( -- )
   s" upload answer that does not parse" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   s" /docs/up.txt" s" /Docs/Up.txt" s" 0160a" EXPECTED$ 12 TEST-DROPBOX:FILE!
   GARBLED!
   false OUTCOME !
   [: SEND-UNVERIFIED ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" error dropbox: files/upload answered 200: an answer that does not parse"
   LOGGED? TTRUE
   NO-LOOKUP
   UNSTAGED ;


\ A single upload lost after Dropbox committed it: no progress shows.
: LOST-SINGLE-CASE ( -- )
   s" lost upload" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   TEST-DROPBOX:LOSE
   SEND UNVERIFIED? ASSERT
   SHOWS @ 0 T=
   NO-LOOKUP
   UNSTAGED ;


: UNAVAILABLE-SINGLE-CASE ( -- )
   s" upload answered 503" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   UNAVAILABLE!
   SEND UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   UNSTAGED ;


: SINGLE-CASES ( -- )
   CONDITIONAL-MUTATIONS-USE-STRICT-DOCUMENTED-REQUESTS
   CONFLICT-CASE HELD-CASE NON-ASCII-CASE OTHER-CASE-CASE
   GARBLED-SINGLE-CASE LOST-SINGLE-CASE UNAVAILABLE-SINGLE-CASE
   SHORT-STAGE-CASE REFUSED-STAGE-CASE FULL-READ-CASE
   ENTERED-READ-CASE TIMED-OUT-READ-CASE CANCELLED-READ-CASE ;


\ A file one byte over a chunk: two appends.
: BIG-STAGED ( -- )
   CHUNK 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: a:^ cap:NUM:alloc-byte-len :}
   a CHUNK 1+ PATTERN
   s" big.bin" STAGE! a CHUNK 1+ >str s" /Big.bin" s" " STAGED
   a cap MEM:RELEASE-BYTES ;


: S-START ( -- ) s" /2/files/upload_session/start" SB-APPEND ;
: S-RESTART ( -- ) s"  " SB-APPEND S-START ;
: S-APPEND ( -- ) s"  /2/files/upload_session/append_v2" SB-APPEND ;
: S-FINISH ( -- ) s"  /2/files/upload_session/finish" SB-APPEND ;


\ UPLOAD's reply, with the fault striking times at the count.
: STRUCK ( n fault n -- DROPBOX:reply )
   STRIKES ! FAULT ! FAULT-AT !
   TEST-DROPBOX:RESET
   SEND ;


\ An upload with the fault once at the count, done with the entry Dropbox
\ committed.
: FAULTED ( n fault -- )
   1 STRUCK DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ CHUNK 1+ T=
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: SESSION-CASE ( -- )
   s" session upload" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   -1 construct fault cut FAULTED
   SHOWS @ 2 T= SHOWN @ CHUNK 1+ T=
   CHECKS @ 2 T= CHECKED @ CHUNK 1+ T= CHECKED-ID$ s" fake-session-0" T$=
   SB-RESET S\" {\qcursor\q:{\qsession_id\q:\qfake-session-0\q," SB-APPEND
   S\" \qoffset\q:" SB-APPEND CHUNK 1+ FMT:SB-INT
   S\" },\qcommit\q:{\qpath\q:\q/Big.bin\q,\qmode\q:\qadd\q," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true}}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$= ;


: LOST-APPEND-CASE ( -- )
   s" lost append" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-APPEND S-FINISH
   CHUNK construct fault cut FAULTED ;


: HELD-APPEND-CASE ( -- )
   s" incorrect_offset at the chunk's end" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-APPEND S-FINISH
   CHUNK construct fault lose FAULTED ;


: CLOSED-CASE ( -- )
   s" closed session" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-RESTART S-APPEND S-APPEND
   S-FINISH
   CHUNK construct fault close FAULTED
   CHECKS @ 3 T= CHECKED @ CHUNK 1+ T= CHECKED-ID$ s" fake-session-1" T$= ;


\ incorrect_offset short of the chunk's end: Dropbox does not hold the
\ chunk, so the session is gone and the upload starts over.
: OFFSET-APPEND-CASE ( -- )
   s" incorrect_offset short of the chunk's end" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-RESTART S-APPEND S-APPEND S-FINISH
   CHUNK construct fault offset FAULTED ;


: LOST-START-CASE ( -- )
   s" lost session start" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   TEST-DROPBOX:CUT
   SEND UNVERIFIED? ASSERT
   SHOWS @ 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/upload_session/start" T$= ;


: UNAVAILABLE-START-CASE ( -- )
   s" session start answered 503" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   UNAVAILABLE!
   SEND UNVERIFIED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/upload_session/start" T$= ;


\ The second chunk's append answered 503 once: resent.
: UNAVAILABLE-APPEND-CASE ( -- )
   s" append answered 503" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-APPEND S-FINISH
   CHUNK construct fault unavailable FAULTED ;


\ The second chunk's append answered 503 asking a wait: not resent.
: WAITED-APPEND-CASE ( -- )
   s" append answered 503 with a wait" T-LABEL
   CHUNK construct fault backoff 1 STRUCK RETRY-MS 3000 T=
   SB-RESET S-START S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: UNAVAILABLE-FINISH-CASE ( -- )
   s" finish answered 503" T-LABEL
   CHUNK 1+ construct fault unavailable 1 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: LOST-FINISH-CASE ( -- )
   s" lost finish" T-LABEL
   CHUNK 1+ construct fault lose 1 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The second chunk's answer lost on its append and again on the resend.
: CUT-APPEND-CASE ( -- )
   s" append lost twice" T-LABEL
   CHUNK construct fault cut-twice 1 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The session closed after its first chunk, and its restart's too.
: CLOSED-TWICE-CASE ( -- )
   s" session gone twice" T-LABEL
   CHUNK construct fault close 2 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-RESTART S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The upload's content hash is not that of the bytes Dropbox commits.
: MISMATCH-CASE ( -- )
   s" committed content hash mismatch" T-LABEL
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   str> SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH !
   -1 construct fault cut 1 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$=
   EXPECTED$ str> SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH ! ;


\ A session upload to /É.bin whose finish is answered with its file at
\ /b.txt as its path_lower.
: FINISH-ELSEWHERE-CASE ( -- )
   s" finish answered at another path" T-LABEL
   S\" /\xc3\x89.bin" str> SPAN:MAKE UP DROPBOX-UPLOAD:PATH !
   -1 FAULT-AT ! TEST-DROPBOX:RESET
   s" /2/files/upload_session/finish" CHUNK 1+ ELSEWHERE!
   SEND UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$=
   s" /Big.bin" str> SPAN:MAKE UP DROPBOX-UPLOAD:PATH ! ;


\ Sized a byte past the stage: the second append carries the stage's last
\ byte and the read for the next one returns 0.
: ENDED-EARLY-CASE ( -- )
   s" session stage shorter than its size" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   CHUNK 2 + UP DROPBOX-UPLOAD:SIZE !
   SEND-LOGGED DROPBOX:E-STAGE T=
   s" the stage is shorter than its size" STAGE-LOGGED? TTRUE
   SB-RESET S-START S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$=
   CHUNK 1+ UP DROPBOX-UPLOAD:SIZE ! ;


: APPLIED-FINISH-CASE ( -- )
   s" finish gone, already applied" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   CHUNK 1+ construct fault applied FAULTED ;


: UNFOUND-FINISH-CASE ( -- )
   s" finish gone, not applied" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   S-RESTART S-APPEND S-APPEND S-FINISH
   CHUNK 1+ construct fault unfound FAULTED ;


\ A finish gone twice, each time with the file Dropbox holds incomplete:
\ not the upload's entry, so it restarts, and then is unverified.
: REVLESS-FINISH-CASE ( -- )
   s" finish gone, held with no rev" T-LABEL
   CHUNK 1+ construct fault revless 2 STRUCK UNVERIFIED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   S-RESTART S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A finish whose answer does not parse, logged, though Dropbox holds the
\ file it committed.
: GARBLED-FINISH-CASE ( -- )
   s" finish answer that does not parse" T-LABEL
   1 STRIKES ! construct fault garbled FAULT ! CHUNK 1+ FAULT-AT !
   TEST-DROPBOX:RESET
   false OUTCOME !
   [: SEND-UNVERIFIED ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" error dropbox: files/upload_session/finish answered 200: an answer that does not parse"
   LOGGED? TTRUE
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A finish answered gone whose confirmation asks to wait: the
\ confirmation's retry, with no restart.
: BUSY-FINISH-CASE ( -- )
   s" finish gone, confirmation busy" T-LABEL
   CHUNK 1+ construct fault busy 1 STRUCK RETRY-MS 3000 T=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A finish answered gone whose confirmation Dropbox refuses 403: unlinked.
: DENIED-FINISH-CASE ( -- )
   s" finish gone, confirmation denied" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   1 STRIKES ! construct fault denied FAULT ! CHUNK 1+ FAULT-AT !
   TEST-DROPBOX:RESET
   false OUTCOME !
   [: SEND-UNLINKED ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" error dropbox: files/get_metadata unlinked: 403" LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ ---- resuming a recorded session

: S-METADATA ( -- ) s"  /2/files/get_metadata" SB-APPEND ;


\ UPLOAD's reply with UP resuming the session the string names at n
\ confirmed bytes, on the fake's sessions as the last upload left them;
\ UP then holds no record again.
: RESUMED ( str n -- DROPBOX:reply )
   {: sid:str n:n :}
   sid str> SPAN:MAKE UP DROPBOX-UPLOAD:SESSION !
   n UP DROPBOX-UPLOAD:CONFIRMED !
   -1 FAULT-AT !
   SEND
   s" " str> SPAN:MAKE UP DROPBOX-UPLOAD:SESSION !
   0 UP DROPBOX-UPLOAD:CONFIRMED ! ;


\ The checkpoints of the last upload: their count, then the last's
\ session and bytes.
: CHECKPOINTS ( n str n -- )
   {: k:n sid:str n:n :}
   CHECKS @ k T= CHECKED-ID$ sid T$= CHECKED @ n T= ;


\ Two appends and a finish whose answer is cut before Dropbox runs it:
\ fake-session-0 holds the whole stage, uncommitted.
: FINISH-CUT ( -- )
   CHUNK 1+ construct fault cut 1 STRUCK UNVERIFIED? ASSERT
   2 s" fake-session-0" CHUNK 1+ CHECKPOINTS ;


\ One append, then the second's answer lost twice: resumed at CHUNK, the
\ rest goes in one append and a finish, with no start.
: RESUMED-APPEND-CASE ( -- )
   s" resumed after one append" T-LABEL
   CHUNK construct fault cut-twice 1 STRUCK UNVERIFIED? ASSERT
   1 s" fake-session-0" CHUNK CHECKPOINTS
   s" fake-session-0" CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   SHOWS @ 1 T= SHOWN @ CHUNK 1+ T=
   1 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ Two appends, then a finish Dropbox committed whose answer was lost:
\ resumed with the whole stage confirmed, get_metadata finds the upload
\ and no finish is sent.
: RESUMED-COMMITTED-CASE ( -- )
   s" resumed after a lost finish" T-LABEL
   CHUNK 1+ construct fault lose 1 STRUCK UNVERIFIED? ASSERT
   2 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   s" fake-session-0" CHUNK 1+ RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   SHOWS @ 1 T= SHOWN @ CHUNK 1+ T= CHECKS @ 0 T=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-METADATA
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ Resumed with the whole stage confirmed, Dropbox not holding the upload:
\ get_metadata, then the finish.
: RESUMED-UNCOMMITTED-CASE ( -- )
   s" resumed whole, not committed" T-LABEL
   FINISH-CUT
   s" fake-session-0" CHUNK 1+ RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   CHECKS @ 0 T=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-METADATA S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ Resumed whole, get_metadata asking to wait: its retry, with no finish.
: RESUMED-BUSY-CASE ( -- )
   s" resumed whole, confirmation busy" T-LABEL
   FINISH-CUT BUSY!
   s" fake-session-0" CHUNK 1+ RESUMED RETRY-MS 3000 T=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-METADATA
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: SEND-RESUMED-UNLINKED ( -- )
   s" fake-session-0" CHUNK 1+ RESUMED UNLINKED? OUTCOME ! ;


\ Resumed whole, get_metadata refused 403: unlinked, with no finish.
: RESUMED-DENIED-CASE ( -- )
   s" resumed whole, confirmation denied" T-LABEL
   FINISH-CUT TEST-DROPBOX:DENY
   false OUTCOME !
   [: SEND-RESUMED-UNLINKED ;] LOGGED 0 T=
   OUTCOME @ TTRUE
   s" error dropbox: files/get_metadata unlinked: 403" LOGGED? TTRUE
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-METADATA
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The next get_metadata answers the upload's file at /b.txt; unlike a
\ finish's answer, it carries its .tag.
: METADATA-ELSEWHERE! ( -- )
   SB-RESET
   S\" {\q.tag\q:\qfile\q,\qname\q:\qb.txt\q,\qid\q:\qid:b\q,\qpath_lower\q:\q/b.txt\q,\qpath_display\q:\q/b.txt\q,\qrev\q:\q0170b\q,\qsize\q:"
   SB-APPEND CHUNK 1+ FMT:INT$ SB-APPEND
   S\" ,\qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND
   S\" \q,\qis_downloadable\q:true}" SB-APPEND
   s" /2/files/get_metadata" 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT! ;


\ Resumed whole, get_metadata showing the upload's file at /b.txt: a
\ path mismatch, with no finish.
: RESUMED-ELSEWHERE-CASE ( -- )
   s" resumed whole, confirmed elsewhere" T-LABEL
   FINISH-CUT METADATA-ELSEWHERE!
   s" fake-session-0" CHUNK 1+ RESUMED
   DROPBOX-ERROR:PATH-MISMATCH REFUSED? ASSERT
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-METADATA
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A record one chunk behind Dropbox, its last checkpoint lost: the
\ append's incorrect_offset at the chunk's end is taken as stored.
: RESUMED-BEHIND-CASE ( -- )
   s" resumed one chunk behind" T-LABEL
   FINISH-CUT
   s" fake-session-0" CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   1 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND S-FINISH S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A record below Dropbox's offset, short of the chunk's end: the session
\ is gone and a new one carries the upload.
: RESUMED-BELOW-CASE ( -- )
   s" resumed below Dropbox's offset" T-LABEL
   FINISH-CUT
   s" fake-session-0" 0 RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   2 s" fake-session-1" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   S-APPEND S-RESTART S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: APPEND-UNAVAILABLE! ( -- )
   s" /2/files/upload_session/append_v2" 503 s" " s" " s" "
   TEST-DROPBOX:ROUTE-SCRIPT! ;


\ A record above Dropbox's offset: fake-session-0 holds nothing, its
\ first append answered 503 twice, and the record says CHUNK. The
\ session is gone and a new one carries the upload.
: RESUMED-ABOVE-CASE ( -- )
   s" resumed above Dropbox's offset" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   APPEND-UNAVAILABLE! APPEND-UNAVAILABLE!
   SEND UNVERIFIED? ASSERT CHECKS @ 0 T=
   s" fake-session-0" CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   2 s" fake-session-1" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND
   S-APPEND S-RESTART S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ A session Dropbox never opened: gone, and a new one carries the upload.
: RESUMED-UNKNOWN-CASE ( -- )
   s" resumed an unknown session" T-LABEL
   TEST-DROPBOX:RESET
   s" fake-session-5" CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   2 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   SB-RESET s" /2/files/upload_session/append_v2" SB-APPEND
   S-RESTART S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ An empty id names no session, whatever bytes it says it confirmed: the
\ upload starts one and appends from 0.
: UNRECORDED-CASE ( -- )
   s" no recorded session" T-LABEL
   TEST-DROPBOX:RESET
   s" " CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   2 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ An id of 513 bytes, one over the run's 512-byte room, names no session:
\ the upload starts one and appends from 0.
: OVERSIZED-ID-CASE ( -- )
   s" recorded id over the cap" T-LABEL
   TEST-DROPBOX:RESET
   SB-RESET 513 0 ?do s" x" SB-APPEND loop
   SB$ CHUNK RESUMED DROPBOX:DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   2 s" fake-session-0" CHUNK 1+ CHECKPOINTS
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: RESUMED-CASES ( -- )
   RESUMED-APPEND-CASE RESUMED-COMMITTED-CASE RESUMED-UNCOMMITTED-CASE
   RESUMED-BUSY-CASE RESUMED-DENIED-CASE RESUMED-ELSEWHERE-CASE
   RESUMED-BEHIND-CASE RESUMED-BELOW-CASE RESUMED-ABOVE-CASE
   RESUMED-UNKNOWN-CASE UNRECORDED-CASE OVERSIZED-ID-CASE ;


: UPLOAD-CASES ( -- )
   HASH-CASE SINGLE-CASES
   BIG-STAGED
   SESSION-CASE LOST-APPEND-CASE HELD-APPEND-CASE OFFSET-APPEND-CASE
   CLOSED-CASE LOST-START-CASE LOST-FINISH-CASE APPLIED-FINISH-CASE
   UNFOUND-FINISH-CASE REVLESS-FINISH-CASE DENIED-FINISH-CASE
   CUT-APPEND-CASE CLOSED-TWICE-CASE
   MISMATCH-CASE FINISH-ELSEWHERE-CASE GARBLED-FINISH-CASE BUSY-FINISH-CASE
   UNAVAILABLE-START-CASE UNAVAILABLE-APPEND-CASE UNAVAILABLE-FINISH-CASE
   WAITED-APPEND-CASE RESUMED-CASES
   ENDED-EARLY-CASE
   UNSTAGED ;


\ ---- linking a login

\ A client on the fake with no root, holding its first access token as
\ an EXCHANGE leaves one, nothing seen yet.
: LINKABLE ( -- ^DROPBOX:client )
   TEST-DROPBOX:RESET
   AR @ TEST-CLIENT:TOKENED
   TEST-DROPBOX:RESET ;


: CHECK$ ( DROPBOX:root-check -- str )
   MATCH DROPBOX:root-check
      valid OF s" valid" ENDOF
      failed OF drop s" failed" ENDOF
      unbound OF s" unbound" ENDOF
      unavailable OF s" unavailable" ENDOF
      not-folder OF s" not-folder" ENDOF
      restricted OF s" restricted" ENDOF
   ;MATCH ;


\ Whether the check failed on a call Dropbox refused with e.
: CHECK-REFUSED? ( DROPBOX:root-check DROPBOX:error -- bool )
   {: e:DROPBOX:error :}
   MATCH DROPBOX:root-check
      valid OF false ENDOF
      failed OF e REFUSED? ENDOF
      unbound OF false ENDOF
      unavailable OF false ENDOF
      not-folder OF false ENDOF
      restricted OF false ENDOF
   ;MATCH ;


\ Rust's root_link_failure: LINK of /Sync on a client whose get_metadata
\ answers status st and the body b builds, after its two requests.
: ROOT-LINKED ( n [ -- str ] -- DROPBOX:root-check )
   {: st:n b :}
   LINKABLE {: c :}
   s" /2/files/get_metadata" st s" " s" " b execute
   TEST-DROPBOX:ROUTE-SCRIPT!
   s" /Sync" c AR @ DROPBOX:LINK
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /2/files/get_metadata" T$=
   c DROPBOX:CLOSE ;


\ Rust's lookup_error("not_found").
: NOT-FOUND$ ( -- str )
   SB-RESET S\" {\qerror_summary\q:\qpath/not_found/...\q," SB-APPEND
   S\" \qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}"
   SB-APPEND SB$ ;


\ Rust's file_metadata("/sync", "/Sync", "root-file-revision") of the
\ bytes "root file".
: ROOT-FILE$ ( -- str )
   HASHER DROPBOX:HASH-BEGIN
   s" root file" str> HASHER DROPBOX:HASH-FEED
   HASHER DROPBOX:HASH-END {: h :}
   SB-RESET S\" {\q.tag\q:\qfile\q" SB-APPEND TEST-CLIENT:SYNC-PATHS+
   S\" ,\qrev\q:\qroot-file-revision\q,\qsize\q:0" SB-APPEND
   S\" ,\qcontent_hash\q:" SB-APPEND h TEST-CLIENT:QUOTED+
   S\" ,\qis_downloadable\q:true}" SB-APPEND SB$ ;


\ A LINK that answers valid keeps the fake's account and namespace past
\ the get_metadata call, which carried the namespace's Path-Root.
: VALID-LINK-CASE ( -- )
   s" link of a folder" T-LABEL
   LINKABLE {: c :}
   s" /2/files/get_metadata" 200 s" " s" "
   SB-RESET S\" {\q.tag\q:\qfolder\q" SB-APPEND TEST-CLIENT:SYNC-PATHS+
   s" }" SB-APPEND SB$
   TEST-DROPBOX:ROUTE-SCRIPT!
   s" /Sync" c AR @ DROPBOX:LINK CHECK$ s" valid" T$=
   c DROPBOX:ACCOUNT-ID s" dbid:account" T$=
   c DROPBOX:ROOT-NAMESPACE s" namespace" T$=
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /2/files/get_metadata" T$=
   TEST-DROPBOX:ROOT-SENT? TTRUE
   TEST-DROPBOX:ROOT-SENT$ S\" {\q.tag\q:\qroot\q,\qroot\q:\qnamespace\q}" T$=
   c DROPBOX:CLOSE ;


\ OUTCOME: LINK of a missing /Sync failed on Dropbox's not_found.
: NOT-FOUND-LINKED ( -- )
   409 [: NOT-FOUND$ ;] ROOT-LINKED
   DROPBOX-ERROR:NOT-FOUND CHECK-REFUSED? OUTCOME ! ;

: LINK-REJECTS-UNAVAILABLE-FILE-AND-RESTRICTED-ROOTS ( -- )
   s" link_rejects_unavailable_file_and_restricted_roots" T-LABEL
   false OUTCOME ! [: NOT-FOUND-LINKED ;] LOGGED 0 T= OUTCOME @ TTRUE
   s" files/get_metadata answered 409: not_found" LOGGED? TTRUE
   200 [: ROOT-FILE$ ;] ROOT-LINKED CHECK$ s" not-folder" T$=
   200 [: s" no_access" TEST-CLIENT:RESTRICTED$ ;] ROOT-LINKED CHECK$
   s" restricted" T$=
   200 [: s" traverse_only" TEST-CLIENT:RESTRICTED$ ;] ROOT-LINKED CHECK$
   s" restricted" T$= ;


\ A root_info under a tag other than user or team binds no namespace:
\ unbound after the account alone.
: UNBOUND-LINK-CASE ( -- )
   s" link under another root tag" T-LABEL
   LINKABLE {: c :}
   s" /2/users/get_current_account" 200 s" " s" "
   S\" {\qaccount_id\q:\qdbid:account\q,\qroot_info\q:{\qroot_namespace_id\q:\qnamespace\q,\q.tag\q:\qother\q}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   s" /Sync" c AR @ DROPBOX:LINK CHECK$ s" unbound" T$=
   TEST-DROPBOX:SEEN$ s" /2/users/get_current_account" T$=
   c DROPBOX:CLOSE ;


\ OUTCOME: LINK of /Sync on OWN answered failed.
: LINK-FAILED ( -- )
   s" /Sync" OWN @ AR @ DROPBOX:LINK CHECK$ s" failed" STR:= OUTCOME ! ;


\ LINK of /Sync on a client whose call to the route rt answers 503 answers
\ failed and logs Rust's one line t for that operation.
: FAILED-LINKED ( str str -- )
   {: rt t :}
   LINKABLE {: c :}
   rt 503 s" " s" " s" " TEST-DROPBOX:ROUTE-SCRIPT!
   c OWN ! false OUTCOME !
   [: LINK-FAILED ;] LOGGED 0 T=
   OUTCOME @ TTRUE t LOGGED? TTRUE
   c DROPBOX:CLOSE ;


: FAILED-LINK-CASE ( -- )
   s" link whose call answers 503" T-LABEL
   s" /2/files/get_metadata"
   s" Dropbox operation `validate configured Dropbox root` failed: files/get_metadata answered 503"
   FAILED-LINKED
   s" /2/users/get_current_account"
   s" Dropbox operation `inspect authorized Dropbox account` failed: users/get_current_account answered 503"
   FAILED-LINKED ;


\ One client's root check answers 409 not_found, then 503: the 503's
\ line names no tag left from the 409.
: UNTAGGED-AFTER-TAGGED-CASE ( -- )
   s" a 503 after a 409 names no tag" T-LABEL
   LINKABLE {: c :}
   s" /2/files/get_metadata" 409 s" " s" " NOT-FOUND$
   TEST-DROPBOX:ROUTE-SCRIPT!
   s" /2/files/get_metadata" 503 s" " s" " s" " TEST-DROPBOX:ROUTE-SCRIPT!
   c OWN !
   [: LINK-FAILED ;] LOGGED 0 T=
   S\" files/get_metadata answered 409: not_found\n" LOGGED? TTRUE
   [: s" /Sync" OWN @ DROPBOX:METADATA UNLINKED? drop
      LOG:ERROR s" test" LOG:LINE OWN @ DROPBOX:LAST-CALL+ LOG:;LINE ;]
   LOGGED 0 T=
   S\" files/get_metadata answered 503\n" LOGGED? TTRUE
   c DROPBOX:CLOSE ;


\ Rust's GetMetadataArg asks for no deleted entry, so a deleted root is
\ not_found as a missing one is.
: UNDELETED-ROOT-CASE ( -- )
   s" root check asks for no deleted entry" T-LABEL
   200 [: SB-RESET S\" {\q.tag\q:\qfolder\q" SB-APPEND
      TEST-CLIENT:SYNC-PATHS+ s" }" SB-APPEND SB$ ;] ROOT-LINKED
   CHECK$ s" valid" T$=
   s" /2/files/get_metadata" TEST-DROPBOX:BODIES-TO$
   S\" {\qpath\q:\q/Sync\q,\qinclude_deleted\q:false}" T$= ;


\ OUTCOME: CHECK-ROOT of /Sync on OWN answered unavailable.
: ROOT-UNAVAILABLE ( -- )
   s" /Sync" OWN @ DROPBOX:CHECK-ROOT CHECK$ s" unavailable" STR:=
   OUTCOME ! ;


\ A get_metadata answered at another path_lower is unavailable, with no
\ line logged.
: ELSEWHERE-ROOT-CASE ( -- )
   s" root check answered at another path" T-LABEL
   LINKABLE {: c :}
   s" /2/files/get_metadata" 200 s" " s" "
   S\" {\q.tag\q:\qfolder\q,\qpath_lower\q:\q/other\q,\qpath_display\q:\q/Other\q}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   c OWN ! false OUTCOME !
   [: ROOT-UNAVAILABLE ;] LOGGED 0 T=
   OUTCOME @ TTRUE ERR$ str> nip 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$=
   c DROPBOX:CLOSE ;


\ OUTCOME: LINK of Sync, no leading slash, on OWN answered.
: LINK-UNROOTED ( -- )
   s" Sync" OWN @ AR @ DROPBOX:LINK CHECK$ drop true OUTCOME ! ;


\ A root ROOT-PATH? refuses throws E-ROOT-PATH with its line, unsent.
: INVALID-ROOT-CASE ( -- )
   s" link of an invalid root" T-LABEL
   LINKABLE {: c :}
   c OWN ! false OUTCOME !
   [: LINK-UNROOTED ;] LOGGED DROPBOX:E-ROOT-PATH T=
   OUTCOME @ TFALSE
   DROPBOX:E-ROOT-PATH ERROR:TEXT$ LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   c DROPBOX:CLOSE ;


\ Linking starts at the account's home, so the fake expects no Path-Root;
\ the get_metadata under the namespace's is scripted, and a scripted
\ answer passes no root check.
: LINK-CASES ( -- )
   s" " TEST-DROPBOX:ROOT!
   VALID-LINK-CASE
   LINK-REJECTS-UNAVAILABLE-FILE-AND-RESTRICTED-ROOTS UNBOUND-LINK-CASE
   FAILED-LINK-CASE UNTAGGED-AFTER-TAGGED-CASE
   UNDELETED-ROOT-CASE ELSEWHERE-ROOT-CASE
   INVALID-ROOT-CASE
   s" ns-root" TEST-DROPBOX:ROOT! ;


: CASES ( -- )
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" ns-root" TEST-DROPBOX:ROOT!
   s" live-token" s" ns-root" RECORDED-CLIENT TEST-CLIENT:MAIN !
   ACCOUNT-CASE OTHER-ROOT-CASE FILE-CASE BUILT-PATH-CASE MISSING-CASE
   ROOT-CASE
   LOST-READ-CASE UNDOWNLOADABLE-CASE SYMLINK-CASE INCOMPLETE-CASE
   METADATA-ELSEWHERE-CASE METADATA-CASEFOLD-CASE
   SDK-EXPIRY-REFRESH-REISSUES-THE-ROUTE-WITH-THE-SAME-CLIENT
   REJECTED-GRANT-CASE REJECTED-POLL-CASE REVOKED-CASE DENIED-CASE
   STORED-FIRST-CASE UNSTORED-CASE UNROTATED-CASE SCRIPTED-REFRESH-CASE
   OAUTH-RATE-LIMIT-PRESERVES-RETRY-AFTER-HEADER FAILED-REFRESH-CASE
   ROUTED-SCRIPT-CASE
   RATE-CASE RATE-BODY-CASE RATE-DATE-CASE RATE-CAP-CASE
   RATE-ZEROS-CASE RATE-HUGE-CASE
   BUSY-CASE REDIRECT-CASE BAD-REQUEST-CASE
   CLASSIFY-CASES
   PAGES-CASE LONG-CASE RESET-CASE STALL-CASE UNTAGGED-CASE PATHLESS-CASE
   PROBE-STALL-CASE PROBE-FIRST-CASE UNDOWNLOADABLE-LISTED-CASE
   INCOMPLETE-LISTED-CASE RESTRICTED-LISTED-CASE INCOMPLETE-KINDS-CASE
   POLL-CASE REUSED-CASE LONG-POLL-EXPOSES-RESET-AND-RATE-LIMIT-OUTCOMES
   WOKEN-CASE UNWOKEN-CASE
   DOWNLOAD-CASES
   DELETE-CONFLICT-CASE DELETE-MISSING-CASE DELETE-GONE-CASE
   LOST-DELETE-CASE DELETE-ELSEWHERE-CASE DELETE-REV-CASE
   FOLDER-CONFLICT-CASE LOST-FOLDER-CASE FOLDER-ELSEWHERE-CASE
   UNAVAILABLE-DELETE-CASE UNAVAILABLE-FOLDER-CASE RATED-DELETE-CASE
   WAITED-DELETE-CASE GARBLED-DELETE-CASE
   LOST-REFRESH-CASE
   EXCHANGE-CASE DEAD-CODE-CASE RESERVED-REFRESH-CASE RESERVED-CODE-CASE
   FORM-BYTES-CASE
   OAUTH-LISTING-LONGPOLL-AND-EXACT-DOWNLOAD-USE-DOCUMENTED-PROTOCOL
   LINK-CASES
   UPLOAD-CASES DROPBOX:THROW-CASES
   TEST-CLIENT:MAIN @ DROPBOX:CLOSE ;


: SERVED ( -- )
   TEST-DROPBOX:START
   [: CASES ;] [: TEST-DROPBOX:STOP ;] finally ;


\ DOWNLOADING's lines against formal/Downloading.tla.
: FORMAL-DOWNLOADING-CASE ( -- )
   s" formal_holds_the_downloading_table" T-LABEL
   s" src/dropbox.f" s" DOWNLOADING" s" Downloading" AR @ TEST-FORMAL:HOLDS ;


\ SESSION's lines against formal/UploadSession.tla.
: FORMAL-SESSION-CASE ( -- )
   s" formal_holds_the_session_table" T-LABEL
   s" src/dropbox.f" s" SESSION" s" UploadSession" AR @ TEST-FORMAL:HOLDS ;


public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   FORMAL-DOWNLOADING-CASE
   FORMAL-SESSION-CASE
   AIO:START
   [: SERVED ;] [: AIO:STOP ;] finally
   AR @ ARENA:RELEASE
   s" dropbox-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

DROPBOX-TEST:RUN
