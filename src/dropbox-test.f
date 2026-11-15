\ dropbox-test.f - DROPBOX's client core against the fake Dropbox of
\ test-dropbox.f on a loopback port: the account, metadata, the Path-Root
\ header, the token's refresh, a revoked token, access denied, rate limits,
\ outages, a redirect, a malformed request, the listing, the long poll,
\ downloads, delete, create-folder, the code exchange, Dropbox's content
\ hash and uploads, whose stages are written under TMPDIR and removed once
\ open, so no run leaves one. One server and one main client serve every
\ case; a case that needs another config opens its own client. DROPBOX's
\ log lines go to stderr, but a stage or classifier failure's, which is
\ captured in TMPDIR, checked and removed. A stub in place of AIO's
\ transfer fails the stage's reads. The first failed assertion ends the run.
\ Run from the repository root: hb --load src/dropbox-test.f </dev/null
require src/lib/aio.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/string.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/test/mapped.f
require src/lib/memory.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/net/curl.f
require src/dropbox.f
require src/test-dropbox.f

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
\ real XFER-STAGE. Each name lands in DROPBOX-TEST, so AIO gains none.
package AIO

TYPED-VARIABLE DROPBOX-TEST:READ-FAULT DROPBOX-TEST:read-fault
variable DROPBOX-TEST:FAILING
\ The buffer the failed read was handed.
TYPED-VARIABLE DROPBOX-TEST:OFFERED ptr u8
TYPED-VARIABLE DROPBOX-TEST:OFFERED-CAP NUM:alloc-byte-len


\ The record holds the buffer as XFER-STAGE's does, so AWAIT-XFER gives
\ it back with the record's outcome.
: DROPBOX-TEST:HOLDS ( ptr u8 NUM:alloc-byte-len n -- )
   {: buf cap:NUM:alloc-byte-len idx:n :}
   buf idx REC-BUF ! cap idx REC-BUF-LEN!
   1 idx REC REC.HOLD ! ;


\ A timer of ms in the read's place, which the kernel ends as timed out.
: DROPBOX-TEST:TIMED-XFER ( ptr u8 NUM:alloc-byte-len n -- n n )
   {: buf cap:NUM:alloc-byte-len ms:n :}
   ms HOST-TIMEOUT {: rc:n idx:n :}
   rc 0<> if rc idx exit then
   buf cap idx DROPBOX-TEST:HOLDS 0 idx ;


\ A minute's timer in the read's place, cancelled at once: the kernel ends
\ it as cancelled. A refused cancel leaves the buffer the caller's.
: DROPBOX-TEST:CANCELLED-XFER ( ptr u8 NUM:alloc-byte-len -- n n )
   {: buf cap:NUM:alloc-byte-len :}
   60000 HOST-TIMEOUT {: rc:n idx:n :}
   rc 0<> if rc idx exit then
   idx HOST-CANCEL {: refused:n :}
   refused 0<> if refused idx exit then
   buf cap idx DROPBOX-TEST:HOLDS 0 idx ;


\ E-AIO-FULL leaves the buffer the caller's, as a refused claim does.
\ E-AIO-ENTER leaves it with the kernel, which the test plays: it keeps
\ OFFERED and releases it as AIO's loop would at the late completion.
\ Runs under AIO-LOCK, as every HOST-XFER does.
: DROPBOX-TEST:STAGE-XFER ( n ptr u8 NUM:alloc-byte-len n n n -- n n )
   {: f:n buf cap:NUM:alloc-byte-len count:n off:n kind:n :}
   f DROPBOX-TEST:FAILING @ <> if
      f buf cap count off kind XFER-STAGE exit
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


: DROPBOX-TEST:;FAIL-READS ( -- ) ['] XFER-STAGE is HOST-XFER ;

;package


package DROPBOX-TEST
private

TYPED-VARIABLE CFG DROPBOX:config
TYPED-VARIABLE AR ptr ARENA:arena
TYPED-VARIABLE MAIN ptr DROPBOX:client


: ASSERT ( bool -- ) dup T-ASSERT 0= if T-REPORT then ;


: DONE? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF true ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


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


\ A client on the fake with the refresh token and root.
: OPENED ( ptr u8 n ptr u8 n -- ptr DROPBOX:client )
   {: t:ptr tu:n r:ptr ru:n :}
   CFG DROPBOX:PRODUCTION
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:API !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   t tu SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   r ru SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG AR @ DROPBOX:OPEN ;


: ACCOUNT-CASE ( -- )
   s" account" T-LABEL
   TEST-DROPBOX:RESET
   MAIN @ DROPBOX:ACCOUNT DONE? ASSERT
   MAIN @ DROPBOX:ACCOUNT-ID s" dbid:account" T$=
   MAIN @ DROPBOX:ROOT-NAMESPACE s" namespace" T$=
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:AUTH$ s" Bearer sl.fake-1" T$=
   TEST-DROPBOX:TYPE-SENT? TFALSE
   TEST-DROPBOX:LEAKED? TFALSE ;


: FILE-CASE ( -- )
   s" metadata found" T-LABEL
   TEST-DROPBOX:RESET
   s" /docs/a.txt" s" /Docs/A.txt" s" 015f0c1d2e3a"
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   12 TEST-DROPBOX:FILE!
   s" /docs/a.txt" MAIN @ DROPBOX:METADATA DONE? ASSERT
   MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ DROPBOX-KIND:file DROPBOX-KIND:EQ TTRUE
   e DROPBOX-ENTRY:LOWER @ SPAN:$ s" /docs/a.txt" T$=
   e DROPBOX-ENTRY:DISPLAY @ SPAN:$ s" /Docs/A.txt" T$=
   e DROPBOX-ENTRY:REV @ SPAN:$ s" 015f0c1d2e3a" T$=
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   e DROPBOX-ENTRY:SIZE @ 12 T=
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/json" T$= ;


: MISSING-CASE ( -- )
   s" metadata not found" T-LABEL
   TEST-DROPBOX:RESET
   s" /missing" MAIN @ DROPBOX:METADATA DROPBOX-ERROR:not-found REFUSED? ASSERT ;


: ROOT-CASE ( -- )
   s" path root" T-LABEL
   TEST-DROPBOX:ROOT-SENT? TTRUE
   TEST-DROPBOX:ROOT-SENT$ S\" {\q.tag\q:\qroot\q,\qroot\q:\qns-root\q}" T$=
   s" " TEST-DROPBOX:ROOT!
   TEST-DROPBOX:RESET
   s" live-token" s" " OPENED {: home :}
   home DROPBOX:ACCOUNT DONE? ASSERT
   TEST-DROPBOX:ROOT-SENT? TFALSE
   home DROPBOX:CLOSE
   s" ns-root" TEST-DROPBOX:ROOT! ;


: EXPIRED-CASE ( -- )
   s" expired token" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:EXPIRE
   MAIN @ DROPBOX:ACCOUNT DONE? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account" T$= ;


: UNLINKED-CASE ( -- )
   s" invalid grant" T-LABEL
   TEST-DROPBOX:RESET
   s" dead-token" s" ns-root" OPENED {: dead :}
   dead DROPBOX:ACCOUNT UNLINKED? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   dead DROPBOX:CLOSE ;


: REVOKED-CASE ( -- )
   s" revoked token" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:REVOKE
   MAIN @ DROPBOX:ACCOUNT UNLINKED? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account" T$= ;


: DENIED-CASE ( -- )
   s" access denied" T-LABEL
   TEST-DROPBOX:RESET
   403 s" " s" "
   S\" {\qerror_summary\q:\qno_permission/...\q,\qerror\q:{\q.tag\q:\qno_permission\q}}"
   TEST-DROPBOX:SCRIPT!
   MAIN @ DROPBOX:ACCOUNT UNLINKED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/users/get_current_account" T$= ;


: EXPIRED! ( -- )
   401 s" " s" "
   S\" {\qerror_summary\q:\qexpired_access_token/...\q,\qerror\q:{\q.tag\q:\qexpired_access_token\q}}"
   TEST-DROPBOX:SCRIPT! ;


\ Its own client, as the refresh it is scripted keeps a token the fake
\ never issued.
: REFUSED-AGAIN-CASE ( -- )
   s" refreshed token refused" T-LABEL
   TEST-DROPBOX:RESET
   s" live-token" s" ns-root" OPENED {: again :}
   again DROPBOX:ACCOUNT DONE? ASSERT
   TEST-DROPBOX:RESET
   EXPIRED!
   200 s" " s" "
   S\" {\qaccess_token\q:\qsl.fake-scripted\q,\qtoken_type\q:\qbearer\q,\qexpires_in\q:14400}"
   TEST-DROPBOX:SCRIPT!
   EXPIRED!
   again DROPBOX:ACCOUNT UNLINKED? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/users/get_current_account /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:AUTH$ s" Bearer sl.fake-scripted" T$=
   again DROPBOX:CLOSE ;


: RATE-CASE ( -- )
   s" rate limited" T-LABEL
   TEST-DROPBOX:RESET
   429 s" Retry-After" s" 7"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:3}}"
   TEST-DROPBOX:SCRIPT!
   MAIN @ DROPBOX:ACCOUNT RETRY-MS 7000 T= ;


: BUSY-CASE ( -- )
   s" unavailable" T-LABEL
   TEST-DROPBOX:RESET
   503 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   MAIN @ DROPBOX:ACCOUNT RETRY-MS 0 T= ;


: ACCOUNT-DROPPED ( -- ) MAIN @ DROPBOX:ACCOUNT DONE? drop ;


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

create ERR-PATH 256 allot
variable ERR-PATH-U
create ERR 512 allot
variable ERR-U
TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE OUTCOME bool


: ERR-PATH$ ( -- ptr u8 n ) ERR-PATH ERR-PATH-U @ ;
: ERR$ ( -- ptr u8 n ) ERR ERR-U @ ;


\ TMPDIR/<name> at dst; answers its length.
: IN-TMP ( ptr u8 n ptr u8 -- n )
   {: nm:ptr nu:n dst:ptr :}
   s" TMPDIR" GETENV {: d:ptr du:n :}
   d dst du BYTE-COPY
   47 dst du + c!
   nm dst du + 1+ nu BYTE-COPY
   du 1+ nu + ;


\ The code xt throws, 0 for none, with fd 2 sent to TMPDIR/stderr.txt,
\ which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ACTION !
   s" stderr.txt" ERR-PATH IN-TMP ERR-PATH-U !
   ERR-PATH$ STDERR:CAPTURE
   [: ACTION @ catch ;] [: STDERR:;CAPTURE ;] finally
   ERR-PATH$ ERR 512 FS:READ-ALL ERR-U !
   ERR-PATH$ FS:REMOVE-FILE ;


: LINES ( ptr u8 n -- n )
   {: a:ptr u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;


\ ERR$ is one line that holds the text.
: LOGGED? ( ptr u8 n -- bool )
   {: t:ptr tu:n :}
   ERR$ LINES 1 = ERR$ t tu CONTAINS? and ;


: METADATA-DROPPED ( -- ) s" /docs/a.txt" MAIN @ DROPBOX:METADATA DONE? drop ;


\ A write Dropbox is too busy to take is retried at once.
: WRITE-BUSY-CASE ( -- )
   s" too many write operations" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath_write/too_many_write_operations/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qtoo_many_write_operations\q}}}"
   TEST-DROPBOX:SCRIPT!
   s" /busy.txt" s" " MAIN @ DROPBOX:DELETE RETRY-MS 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


: METADATA-OTHER ( -- )
   s" /docs/a.txt" MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:other REFUSED? OUTCOME ! ;


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
   s" live-token" s" ns-wrong" OPENED {: off :}
   off DROPBOX:ACCOUNT DROPBOX-ERROR:invalid-root REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   off DROPBOX:CLOSE ;


: TIMEOUT-CASE ( -- )
   s" request timeout" T-LABEL
   TEST-DROPBOX:RESET
   408 s" " s" " s" " TEST-DROPBOX:SCRIPT!
   MAIN @ DROPBOX:ACCOUNT RETRY-MS 0 T= ;


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


\ libcurl takes no HTTP/0.9 answer: CURLE_UNSUPPORTED_PROTOCOL, 1, which
\ is not a lost exchange.
: GARBLED-CASE ( -- )
   s" transport failure" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:GARBLE
   [: METADATA-DROPPED ;] LOGGED DROPBOX:E-TRANSPORT T=
   1 CURL:>CODE CURL:LOST? TFALSE
   SB-RESET s" error dropbox: curl files/get_metadata: " SB-APPEND
   1 CURL:>CODE CURL:ERROR$ SB-APPEND
   SB$ LOGGED? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/get_metadata" T$= ;


: CLASSIFY-CASES ( -- )
   WRITE-BUSY-CASE UNKNOWN-TAG-CASE UNPARSED-ERROR-CASE WRONG-ROOT-CASE
   TIMEOUT-CASE TEAPOT-CASE UNPARSED-ANSWER-CASE GARBLED-CASE ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

256 constant GOT-CAP
create GOT GOT-CAP allot
variable GOT-U


: GOT+ ( ptr u8 n -- )
   {: a:ptr u:n :}
   a u GOT GOT-U @ + GOT-CAP GOT-U @ - SPAN:MAKE SPAN:COPY
   u GOT-U +! ;


: KIND$ ( DROPBOX:kind -- ptr u8 n )
   MATCH DROPBOX:kind
      file OF s" f" ENDOF
      folder OF s" d" ENDOF
      deleted OF s" x" ENDOF
   ;MATCH ;


\ Each entry handed on, as its kind's letter and path_lower, joined by
\ spaces.
: SAW ( ptr DROPBOX:entry -- )
   {: e :}
   GOT-U @ 0<> if s"  " GOT+ then
   e DROPBOX-ENTRY:KIND @ KIND$ GOT+
   e DROPBOX-ENTRY:LOWER @ SPAN:$ GOT+ ;


: GOT$ ( -- ptr u8 n ) GOT GOT-U @ ;
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
   s" /sync" MAIN @ [: SAW ;] DROPBOX:LIST DONE? ASSERT
   GOT$ s" d/sync f/sync/a.txt d/sync/b" T$=
   MAIN @ DROPBOX:CURSOR s" c3" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   TEST-DROPBOX:ARGS$
   S\" {\qpath\q:\q/sync\q,\qrecursive\q:true,\qinclude_deleted\q:false} {\qcursor\q:\qc1\q} {\qcursor\q:\qc2\q}" T$= ;


\ A reset leaves the cursor of the last listing that answered done.
: RESET-CASE ( -- )
   s" listing reset" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q}]"
   s" r1" true TEST-DROPBOX:PAGE!
   TEST-DROPBOX:PAGE-RESET!
   s" /sync" MAIN @ [: SAW ;] DROPBOX:LIST
   DROPBOX-ERROR:reset REFUSED? ASSERT
   MAIN @ DROPBOX:CURSOR s" c3" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/list_folder/continue" T$= ;


: CHANGES-DROPPED ( -- )
   s" c3" MAIN @ [: SAW ;] DROPBOX:CHANGES DONE? drop ;


: STALL-CASE ( -- )
   s" cursor stalled" T-LABEL
   LISTING
   S\" [{\q.tag\q:\qdeleted\q,\qname\q:\qb\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" c4" true TEST-DROPBOX:PAGE!
   s" []" s" c4" true TEST-DROPBOX:PAGE!
   [: CHANGES-DROPPED ;] DROPBOX:E-ANSWER TTHROWSQ
   GOT$ s" x/sync/b" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   TEST-DROPBOX:ARGS$ S\" {\qcursor\q:\qc3\q} {\qcursor\q:\qc4\q}" T$= ;


\ A listing's entry is a Metadata union: one with no `.tag` has no kind,
\ and is never handed on as a deleted entry.
: UNTAGGED-LISTED ( -- )
   s" /sync" MAIN @ [: SAW ;] DROPBOX:LIST DONE? drop ;


: UNTAGGED-CASE ( -- )
   s" listing entry with no .tag" T-LABEL
   LISTING
   S\" [{\qname\q:\qb\q,\qpath_lower\q:\q/sync/b\q,\qpath_display\q:\q/Sync/b\q}]"
   s" u1" false TEST-DROPBOX:PAGE!
   [: UNTAGGED-LISTED ;] DROPBOX:E-ANSWER TTHROWSQ
   GOT$ s" " T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;


: WAITED ( bool n -- )
   LISTING TEST-DROPBOX:POLL!
   s" c3" 30 MAIN @ DROPBOX:WAIT DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder/longpoll" T$=
   TEST-DROPBOX:ARGS$ S\" {\qcursor\q:\qc3\q,\qtimeout\q:30}" T$=
   TEST-DROPBOX:LEAKED? TFALSE ;


: POLL-CASE ( -- )
   s" long poll changes" T-LABEL
   true 0 WAITED
   MAIN @ DROPBOX:CHANGED? TTRUE
   MAIN @ DROPBOX:BACKOFF 0 T=
   s" long poll timeout" T-LABEL
   false 0 WAITED
   MAIN @ DROPBOX:CHANGED? TFALSE
   MAIN @ DROPBOX:BACKOFF 0 T=
   s" long poll backoff" T-LABEL
   true 5 WAITED
   MAIN @ DROPBOX:CHANGED? TTRUE
   MAIN @ DROPBOX:BACKOFF 5 T= ;


\ A long poll on a cursor Dropbox no longer takes is refused, unread.
: POLL-RESET-CASE ( -- )
   s" long poll reset" T-LABEL
   LISTING
   409 s" " s" "
   S\" {\qerror_summary\q:\qreset/\q,\qerror\q:{\q.tag\q:\qreset\q}}"
   TEST-DROPBOX:SCRIPT!
   s" c3" 30 MAIN @ DROPBOX:WAIT DROPBOX-ERROR:reset REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder/longpoll" T$= ;


\ ---- files/download

create SUNK 64 allot
variable SUNK-U
variable SUNK-AT


\ A download's sink: each chunk appended to SUNK, its offset the one after
\ the last; SUNK-AT keeps the first chunk's.
: SUNK+ ( ptr u8 n n -- )
   {: a:ptr u:n off:n :}
   SUNK-U @ 0= if off SUNK-AT ! then
   off SUNK-AT @ SUNK-U @ + T=
   SUNK-U @ u + 64 > if false ASSERT exit then
   a SUNK SUNK-U @ + u BYTE-COPY
   u SUNK-U +! ;


: SUNK$ ( -- ptr u8 n ) SUNK SUNK-U @ ;


\ The alphabet as the file at rev 0160a1b2c3d4.
: ALPHABET ( -- )
   s" /docs/abc.txt" s" /Docs/abc.txt" s" 0160a1b2c3d4"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   26 TEST-DROPBOX:FILE!
   s" 0160a1b2c3d4" s" abcdefghijklmnopqrstuvwxyz" TEST-DROPBOX:CONTENT! ;


: FETCH ( n -- DROPBOX:reply )
   {: at:n :}
   0 SUNK-U ! -1 SUNK-AT !
   s" 0160a1b2c3d4" at MAIN @ [: SUNK+ ;] DROPBOX:DOWNLOAD ;


: WHOLE-CASE ( -- )
   s" download whole" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   0 FETCH DONE? ASSERT
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   SUNK-AT @ 0 T=
   MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:REV @ SPAN:$ s" 0160a1b2c3d4" T$=
   e DROPBOX-ENTRY:SIZE @ 26 T=
   TEST-DROPBOX:SEEN$ s" /2/files/download" T$=
   TEST-DROPBOX:ARG-SENT$ S\" {\qpath\q:\qrev:0160a1b2c3d4\q}" T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   TEST-DROPBOX:TYPE-SENT? TFALSE ;


: RESUME-CASE ( -- )
   s" download resumed" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   10 FETCH DONE? ASSERT
   SUNK$ s" klmnopqrstuvwxyz" T$=
   SUNK-AT @ 10 T=
   TEST-DROPBOX:RANGE-SENT$ s" bytes=10-" T$=
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ 26 T= ;


: FETCH-DROPPED ( -- ) 10 FETCH DONE? drop ;


: SKEW-CASE ( -- )
   s" download range mismatch" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   TEST-DROPBOX:SKEW
   [: FETCH-DROPPED ;] DROPBOX:E-ANSWER TTHROWSQ
   SUNK-U @ 0 T= ;


: UNSATISFIED-CASE ( -- )
   s" download 416 from the end restarts" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   26 FETCH DONE? ASSERT
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   SUNK-AT @ 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/download /2/files/download" T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ 26 T= ;


: RESTART-CASE ( -- )
   s" download 416 of another size" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   30 FETCH DONE? ASSERT
   SUNK$ s" abcdefghijklmnopqrstuvwxyz" T$=
   SUNK-AT @ 0 T=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ 26 T= ;


\ A 416 with no Range to drop: one from offset 0.
: UNSATISFIABLE! ( -- )
   416 s" Content-Range" s" bytes */26" s" " TEST-DROPBOX:SCRIPT! ;


: UNSATISFIABLE-CASE ( -- )
   s" download 416 on the restart" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   UNSATISFIABLE! UNSATISFIABLE!
   [: FETCH-DROPPED ;] DROPBOX:E-ANSWER TTHROWSQ
   TEST-DROPBOX:SEEN$ s" /2/files/download /2/files/download" T$=
   SUNK-U @ 0 T= ;


: FIRST-UNSATISFIABLE-CASE ( -- )
   s" download 416 from 0" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   UNSATISFIABLE!
   [: 0 FETCH DONE? drop ;] DROPBOX:E-ANSWER TTHROWSQ
   TEST-DROPBOX:SEEN$ s" /2/files/download" T$=
   SUNK-U @ 0 T= ;


: UNKNOWN-REV-CASE ( -- )
   s" download unknown rev" T-LABEL
   TEST-DROPBOX:RESET ALPHABET
   0 SUNK-U ! -1 SUNK-AT !
   s" 0160ffffffff" 0 MAIN @ [: SUNK+ ;] DROPBOX:DOWNLOAD
   DROPBOX-ERROR:not-found REFUSED? ASSERT
   SUNK-U @ 0 T= ;


: DOWNLOAD-CASES ( -- )
   WHOLE-CASE RESUME-CASE SKEW-CASE UNSATISFIED-CASE RESTART-CASE
   UNSATISFIABLE-CASE FIRST-UNSATISFIABLE-CASE UNKNOWN-REV-CASE ;


\ ---- delete_v2, create_folder_v2 and the code exchange

: KIND? ( DROPBOX:kind -- bool )
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:KIND @ DROPBOX-KIND:EQ ;


: LOWER$ ( -- ptr u8 n ) MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$ ;


: DELETED-FILE ( ptr u8 n ptr u8 n -- )
   {: l:ptr lu:n r:ptr ru:n :}
   l lu l lu r ru
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   0 TEST-DROPBOX:FILE! ;


: DELETE-CONFLICT-CASE ( -- )
   s" delete conflict" T-LABEL
   TEST-DROPBOX:RESET
   s" /del.txt" s" rev-del" DELETED-FILE
   s" /del.txt" s" rev-other" MAIN @ DROPBOX:DELETE
   DROPBOX-ERROR:conflict REFUSED? ASSERT
   s" /del.txt" s" rev-del" MAIN @ DROPBOX:DELETE DONE? ASSERT
   DROPBOX-KIND:file KIND? TTRUE
   LOWER$ s" /del.txt" T$=
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:REV @ SPAN:$ s" rev-del" T$=
   s" /del.txt" MAIN @ DROPBOX:METADATA
   DROPBOX-ERROR:not-found REFUSED? ASSERT ;


: DELETE-MISSING-CASE ( -- )
   s" delete not found" T-LABEL
   TEST-DROPBOX:RESET
   s" /absent" s" " MAIN @ DROPBOX:DELETE DONE? ASSERT
   DROPBOX-KIND:deleted KIND? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;


\ A resent delete that Dropbox already applied, refused as a conflict.
: DELETE-GONE-CASE ( -- )
   s" delete conflict on a gone path" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath_write/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}}}}"
   TEST-DROPBOX:SCRIPT!
   s" /gone.txt" s" rev-gone" MAIN @ DROPBOX:DELETE DONE? ASSERT
   DROPBOX-KIND:deleted KIND? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2 /2/files/get_metadata" T$= ;


: LOST-DELETE-CASE ( -- )
   s" lost delete" T-LABEL
   TEST-DROPBOX:RESET
   s" /lost.txt" s" rev-lost" DELETED-FILE
   TEST-DROPBOX:LOSE
   s" /lost.txt" s" " MAIN @ DROPBOX:DELETE DONE? ASSERT
   DROPBOX-KIND:deleted KIND? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2 /2/files/get_metadata" T$= ;


: FOLDER-CONFLICT-CASE ( -- )
   s" create-folder conflict" T-LABEL
   TEST-DROPBOX:RESET
   s" /made" MAIN @ DROPBOX:CREATE-FOLDER DONE? ASSERT
   DROPBOX-KIND:folder KIND? TTRUE
   LOWER$ s" /made" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/json" T$=
   s" /made" MAIN @ DROPBOX:CREATE-FOLDER DONE? ASSERT
   DROPBOX-KIND:folder KIND? TTRUE
   s" /taken" s" rev-taken" DELETED-FILE
   s" /taken" MAIN @ DROPBOX:CREATE-FOLDER
   DROPBOX-ERROR:conflict REFUSED? ASSERT
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/create_folder_v2 /2/files/get_metadata /2/files/create_folder_v2 /2/files/get_metadata"
   T$= ;


: LOST-FOLDER-CASE ( -- )
   s" lost create-folder" T-LABEL
   TEST-DROPBOX:RESET
   TEST-DROPBOX:LOSE
   s" /lost-made" MAIN @ DROPBOX:CREATE-FOLDER DONE? ASSERT
   DROPBOX-KIND:folder KIND? TTRUE
   LOWER$ s" /lost-made" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/get_metadata" T$= ;


: EXCHANGE-CASE ( -- )
   s" code exchange" T-LABEL
   TEST-DROPBOX:RESET
   MAIN @ DROPBOX:REFRESH-TOKEN s" live-token" T$=
   s" fake-code" s" fake-verifier" TEST-DROPBOX:GRANT!
   s" " s" ns-root" OPENED {: link :}
   s" fake-code" s" fake-verifier" link DROPBOX:EXCHANGE DONE? ASSERT
   link DROPBOX:REFRESH-TOKEN s" fake-refresh-granted" T$=
   link DROPBOX:ACCOUNT DONE? ASSERT
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/users/get_current_account" T$=
   TEST-DROPBOX:LEAKED? TFALSE
   link DROPBOX:CLOSE ;


: DEAD-CODE-CASE ( -- )
   s" exchange invalid grant" T-LABEL
   TEST-DROPBOX:RESET
   s" " s" ns-root" OPENED {: link :}
   s" dead-code" s" fake-verifier" link DROPBOX:EXCHANGE UNLINKED? ASSERT
   link DROPBOX:REFRESH-TOKEN s" " T$=
   TEST-DROPBOX:SEEN$ s" /oauth2/token" T$=
   link DROPBOX:CLOSE ;


\ ---- files/upload and upload sessions

$400000 constant BLOCK
$2000000 constant CHUNK
TYPED-VARIABLE HASHER DROPBOX:hasher
TYPED-VARIABLE UP DROPBOX:upload
create STAGE 256 allot
variable STAGE-U
create EXPECTED 64 allot
variable SHOWN
variable SHOWS
\ The count of accepted bytes at which FAULT strikes, -1 for none, and
\ the strikes left there.
variable FAULT-AT
variable STRIKES
ENUM fault cut cut-twice lose close unfound applied ;ENUM
TYPED-VARIABLE FAULT fault


\ Byte i of every patterned file is i mod 256.
: PATTERN ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 0 ?do i 255 and a i + c! loop ;


: HASHED ( ptr u8 n -- ptr u8 n )
   {: a:ptr u:n :}
   HASHER DROPBOX:HASH-BEGIN
   a u HASHER DROPBOX:HASH-FEED
   HASHER DROPBOX:HASH-END ;


\ Pinned by Python's hashlib over the same pattern.
: HASH-CASE ( -- )
   s" content hash" T-LABEL
   BLOCK 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: a:ptr cap:NUM:alloc-byte-len :}
   a BLOCK 1+ PATTERN
   a 0 HASHED
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   a 1 HASHED
   s" 1406e05881e299367766d313e26c05564ec91bf721d31726bd6e46e60689539a" T$=
   a BLOCK HASHED
   s" 894bbb52d1212d6bcbe9967f1a2169138c4d4af0c8dfbaeae86cd1d3f0c03faf" T$=
   a BLOCK 1+ HASHED
   s" 9eb62f609dee341fdcc4521fd6d5a78d9e5c5bb36d844618d9e8d1b32f28ba95" T$=
   a cap MEM:RELEASE-BYTES ;


: STAGE$ ( -- ptr u8 n ) STAGE STAGE-U @ ;


\ TMPDIR/<name>, made fresh.
: STAGE! ( ptr u8 n -- ) STAGE IN-TMP STAGE-U ! ;


\ Writes the bytes as the stage, opens it and removes its name before any
\ check can end the run, and readies UP to upload them to path over rev.
: STAGED ( ptr u8 n ptr u8 n ptr u8 n -- )
   {: b:ptr bu:n p:ptr pu:n r:ptr ru:n :}
   STAGE$ b bu FS:WRITE-ALL
   STAGE$ FS:OPEN-SIZED STAGE$ FS:REMOVE-FILE ASSERT {: f:fd size:n :}
   f UP DROPBOX-UPLOAD:FD !
   size UP DROPBOX-UPLOAD:SIZE !
   b bu HASHED EXPECTED swap BYTE-COPY
   EXPECTED 64 SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH !
   p pu SPAN:MAKE UP DROPBOX-UPLOAD:PATH !
   r ru SPAN:MAKE UP DROPBOX-UPLOAD:REV ! ;


: UNSTAGED ( -- ) UP DROPBOX-UPLOAD:FD @ FD>N close ;
: EXPECTED$ ( -- ptr u8 n ) EXPECTED 64 ;


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


: STRIKE ( -- )
   FAULT @ MATCH fault
      cut OF TEST-DROPBOX:CUT ENDOF
      cut-twice OF TEST-DROPBOX:CUT TEST-DROPBOX:CUT ENDOF
      lose OF TEST-DROPBOX:LOSE ENDOF
      close OF TEST-DROPBOX:CLOSE-SESSIONS ENDOF
      unfound OF UNFOUND ENDOF
      applied OF UNFOUND APPLIED ENDOF
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


: SEND ( -- DROPBOX:reply )
   0 SHOWN ! 0 SHOWS !
   UP MAIN @ [: PROGRESSED ;] DROPBOX:UPLOAD ;


: ENTRY-HASH$ ( -- ptr u8 n )
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$ ;


: SINGLE-CASE ( -- )
   s" single upload" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   SEND DONE? ASSERT
   MAIN @ DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:LOWER @ SPAN:$ s" /docs/up.txt" T$=
   e DROPBOX-ENTRY:SIZE @ 12 T=
   ENTRY-HASH$ EXPECTED$ T$=
   SHOWN @ 12 T= SHOWS @ 1 T=
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   TEST-DROPBOX:TYPE-SENT$ s" application/octet-stream" T$=
   SB-RESET S\" {\qpath\q:\q/Docs/Up.txt\q,\qmode\q:\qadd\q," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED ;


\ The path holds other bytes at rev 0160a; an update over rev 0160b.
: CONFLICT-CASE ( -- )
   s" upload conflict" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" /docs/up.txt" s" /Docs/Up.txt" s" 0160a"
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   5 TEST-DROPBOX:FILE!
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" 0160b" STAGED
   SEND DROPBOX-ERROR:conflict REFUSED? ASSERT
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   SB-RESET S\" {\qpath\q:\q/Docs/Up.txt\q,\qmode\q:" SB-APPEND
   S\" {\q.tag\q:\qupdate\q,\qupdate\q:\q0160b\q}," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND EXPECTED$ SB-APPEND S\" \q}" SB-APPEND
   TEST-DROPBOX:ARG-SENT$ SB$ T$=
   UNSTAGED ;


\ Dropbox already holds these bytes, as after an upload libcurl resent.
: HELD-CASE ( -- )
   s" upload already held" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   s" /docs/up.txt" s" /Docs/Up.txt" s" 0160a" EXPECTED$ 12 TEST-DROPBOX:FILE!
   SEND DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   UNSTAGED ;


\ The upload takes effect and its answer is lost: confirmed by get_metadata.
: LOST-SINGLE-CASE ( -- )
   s" lost upload" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" up.txt" STAGE! s" hello upload" s" /Docs/Up.txt" s" " STAGED
   TEST-DROPBOX:LOSE
   SEND DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   UNSTAGED ;


: NON-ASCII-CASE ( -- )
   s" non-ascii path" T-LABEL
   TEST-DROPBOX:RESET -1 FAULT-AT !
   s" cafe.txt" STAGE! s" hello cafe" S\" /Docs/Caf\xc3\xa9.txt" s" " STAGED
   SEND DONE? ASSERT
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$
   S\" /docs/caf\xc3\xa9.txt" T$=
   S\" {\qpath\q:\q/Docs/Caf\\u00e9.txt\q," {: x:ptr xu:n :}
   TEST-DROPBOX:ARG-SENT$ xu min x xu T$=
   UNSTAGED ;


\ The code SEND throws, 0 for none, with what it logged in ERR$.
: SEND-LOGGED ( -- n ) [: SEND DONE? drop ;] LOGGED ;


\ ERR$ holds the line UPLOAD logs for a failure of UP's stage.
: STAGE-LOGGED? ( ptr u8 n -- bool )
   {: why:ptr wu:n :}
   SB-RESET s" error dropbox: upload of " SB-APPEND
   UP DROPBOX-UPLOAD:PATH @ SPAN:$ SB-APPEND
   s" : " SB-APPEND why wu SB-APPEND
   ERR$ SB$ CONTAINS? ;


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


: SINGLE-CASES ( -- )
   SINGLE-CASE CONFLICT-CASE HELD-CASE LOST-SINGLE-CASE NON-ASCII-CASE
   SHORT-STAGE-CASE REFUSED-STAGE-CASE
   FULL-READ-CASE ENTERED-READ-CASE TIMED-OUT-READ-CASE
   CANCELLED-READ-CASE ;


\ A file one byte over a chunk: two appends.
: BIG-STAGED ( -- )
   CHUNK 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: a:ptr cap:NUM:alloc-byte-len :}
   a CHUNK 1+ PATTERN
   s" big.bin" STAGE! a CHUNK 1+ s" /Big.bin" s" " STAGED
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
   1 STRUCK DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ CHUNK 1+ T=
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: SESSION-CASE ( -- )
   s" session upload" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   -1 construct fault cut FAULTED
   SHOWS @ 2 T= SHOWN @ CHUNK 1+ T=
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
   CHUNK construct fault close FAULTED ;


: LOST-FINISH-CASE ( -- )
   s" lost finish" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   CHUNK 1+ construct fault lose FAULTED ;


\ The second chunk's answer lost on its append and again on the resend.
: CUT-APPEND-CASE ( -- )
   s" append lost twice" T-LABEL
   CHUNK construct fault cut-twice 1 STRUCK RETRY-MS 0 T=
   SB-RESET S-START S-APPEND S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The session closed after its first chunk, and its restart's too.
: CLOSED-TWICE-CASE ( -- )
   s" session gone twice" T-LABEL
   CHUNK construct fault close 2 STRUCK RETRY-MS 0 T=
   SB-RESET S-START S-APPEND S-APPEND S-RESTART S-APPEND S-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


\ The upload's content hash is not that of the bytes Dropbox commits.
: MISMATCH-CASE ( -- )
   s" committed content hash mismatch" T-LABEL
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH !
   -1 construct fault cut 1 STRUCK
   DROPBOX-ERROR:content-hash-mismatch REFUSED? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   TEST-DROPBOX:SEEN$ SB$ T$=
   EXPECTED$ SPAN:MAKE UP DROPBOX-UPLOAD:CONTENT-HASH ! ;


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


\ FAULTED's expected calls would not survive: the fake builds a FILE!'s
\ metadata in the same string buffer.
: APPLIED-FINISH-CASE ( -- )
   s" finish gone, already applied" T-LABEL
   CHUNK 1+ construct fault applied 1 STRUCK DONE? ASSERT
   ENTRY-HASH$ EXPECTED$ T$=
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:SIZE @ CHUNK 1+ T=
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   TEST-DROPBOX:SEEN$ SB$ T$= ;


: UNFOUND-FINISH-CASE ( -- )
   s" finish gone, not applied" T-LABEL
   SB-RESET S-START S-APPEND S-APPEND S-FINISH
   s"  /2/files/get_metadata" SB-APPEND
   S-RESTART S-APPEND S-APPEND S-FINISH
   CHUNK 1+ construct fault unfound FAULTED ;


: UPLOAD-CASES ( -- )
   HASH-CASE SINGLE-CASES
   BIG-STAGED
   SESSION-CASE LOST-APPEND-CASE HELD-APPEND-CASE CLOSED-CASE
   LOST-FINISH-CASE APPLIED-FINISH-CASE UNFOUND-FINISH-CASE CUT-APPEND-CASE
   CLOSED-TWICE-CASE MISMATCH-CASE ENDED-EARLY-CASE
   UNSTAGED ;


: CASES ( -- )
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" ns-root" TEST-DROPBOX:ROOT!
   s" live-token" s" ns-root" OPENED MAIN !
   ACCOUNT-CASE FILE-CASE MISSING-CASE ROOT-CASE EXPIRED-CASE
   UNLINKED-CASE REVOKED-CASE DENIED-CASE REFUSED-AGAIN-CASE
   RATE-CASE BUSY-CASE REDIRECT-CASE BAD-REQUEST-CASE
   CLASSIFY-CASES
   PAGES-CASE RESET-CASE STALL-CASE UNTAGGED-CASE POLL-CASE POLL-RESET-CASE
   DOWNLOAD-CASES
   DELETE-CONFLICT-CASE DELETE-MISSING-CASE DELETE-GONE-CASE
   LOST-DELETE-CASE
   FOLDER-CONFLICT-CASE LOST-FOLDER-CASE EXCHANGE-CASE DEAD-CODE-CASE
   UPLOAD-CASES
   MAIN @ DROPBOX:CLOSE ;


: SERVED ( -- )
   TEST-DROPBOX:START
   [: CASES ;] [: TEST-DROPBOX:STOP ;] finally ;


: CURL-READY ( CURL:status -- )
   MATCH CURL:status
      ok OF ENDOF
      failed OF drop false ASSERT ENDOF
   ;MATCH ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   AIO:START CURL:LOOP-START CURL-READY
   [: SERVED ;] [: CURL:LOOP-STOP AIO:STOP ;] finally
   AR @ ARENA:RELEASE
   s" dropbox-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

DROPBOX-TEST:RUN
