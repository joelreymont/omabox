\ test-client.f - the fake Dropbox's client, journal plans, download
\ slot leases and checkpointed partial downloads, for tests, never
\ production.
\ CLIENT-ON opens a client on test-dropbox.f's fake with a store, a token
\ and a root, OPENED one keeping no rotated token, IDLE the same at
\ NOWHERE$, an origin that never resolves, MAIN holds it while it
\ serves, ACCOUNTED takes its first access token, NEW-LINK makes a
\ REPLAY link on a client below a root, and DOWNLOADS$ is the fake's
\ record of downloads. RECORD journals a pending plan at a path.
\ UNPROTECTED protects no binding and LEASED takes a lease that must
\ exist. CHECKPOINTED leaves a slot holding a durable checkpoint of
\ CHECKPOINT "x" bytes, FILL-XS writes those bytes, and PAST-HASH and
\ SERVES-PAST give the fake a file of them followed by a tail. SOCKET-AT
\ binds a socket at a path. INSIDE names a file in a directory, REFUSAL?
\ tells a refusal of one error, and QUOTED+ appends bytes between double
\ quotes to the string builder; SYNC-PATHS+ appends /sync's paths and
\ RESTRICTED$ makes a restricted /Sync folder there. TOKENED opens a
\ client that holds its first access token. Tests alone load this file;
\ nothing in the program calls these words.
\ STORAGE CLASS. PROCESS-WIDE: CFG, MAIN, the "x" bytes, their hasher and
\ the socket address are one each, for one case at a time.

require src/lib/error.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/string.f
require src/lib/vector.f
require src/lib/test/assert.f
require src/lib/fs.f
require src/lib/fmt.f
require src/lib/adt/option.f
require src/lib/ffi-abi.f
require src/dropbox.f
require src/test-dropbox.f
require src/model.f
require src/journal.f
require src/local.f
require src/replay.f

package TEST-CLIENT
public

\ Ends the run: the case cannot go on.
: FAILED ( str -- ) EXIT-STATUS:FAILURE die ;

: COPIED ( str ^ARENA:arena -- str )
   {: s:str ar :}
   s str> {: a:^ u:n :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

\ dir/name.
: INSIDE ( str str ^ARENA:arena -- str )
   {: d:str s:str ar :}
   d str> {: p:^ pu:n :}
   s str> {: a:^ u:n :}
   ar pu u + 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst pu BYTE-COPY
   47 dst pu + c!
   a dst pu + 1+ u BYTE-COPY
   dst pu u + 1+ >str ;

: REFUSAL? ( DROPBOX:reply DROPBOX:error -- bool )
   {: e:DROPBOX:error :}
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF e DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

: QUOTED+ ( str -- ) S\" \q" SB-APPEND SB-APPEND S\" \q" SB-APPEND ;

\ Appends path_lower /sync and path_display /Sync, after a member.
: SYNC-PATHS+ ( -- )
   S\" ,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q" SB-APPEND ;

\ Rust's restricted_folder_metadata("/sync", "/Sync", {r: true}).
: RESTRICTED$ ( str -- str )
   {: r:str :}
   SB-RESET S\" {\q.tag\q:\qfolder\q" SB-APPEND SYNC-PATHS+
   S\" ,\qsharing_info\q:{" SB-APPEND r QUOTED+
   S\" :true,\qread_only\q:false}}" SB-APPEND SB$ ;


\ ---- the fake's client

TYPED-VARIABLE CFG DROPBOX:config
\ The client on the fake, while it serves.
TYPED-VARIABLE MAIN ^DROPBOX:client

\ A client at origin o with the store s, refresh token t and root r.
: CLIENT-AT
   ( str [ str -- ] str str ^ARENA:arena -- ^DROPBOX:client )
   {: o:str s t:str r:str ar :}
   s CFG DROPBOX-CONFIG:STORE !
   CFG DROPBOX:PRODUCTION
   o str> SPAN:MAKE CFG DROPBOX-CONFIG:API !
   o str> SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   o str> SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" str> SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   t str> SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   r str> SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG ar DROPBOX:OPEN ;

\ A client on the fake with the store s, refresh token t and root r.
: CLIENT-ON
   ( [ str -- ] str str ^ARENA:arena -- ^DROPBOX:client )
   {: s t:str r:str ar :}
   TEST-DROPBOX:ORIGIN$ s t r ar CLIENT-AT ;

private

\ A store that keeps no rotated token.
: KEEP-NONE ( str -- ) drop ;

public

\ A client on the fake, no root, keeping no rotated token.
: OPENED ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   [: KEEP-NONE ;] s" live-token" s" " ar CLIENT-ON ;

\ An origin under the name RFC 6761 reserves never to resolve.
: NOWHERE$ ( -- str ) s" https://dropbox.invalid" ;

\ OPENED at NOWHERE$, for a case that sends nothing.
: IDLE ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   NOWHERE$ [: KEEP-NONE ;] s" live-token" s" " ar CLIENT-AT ;

\ The account call takes the client's first access token, so no case's
\ requests start with a refresh.
: ACCOUNT-OF ( ^DROPBOX:client -- )
   DROPBOX:ACCOUNT MATCH DROPBOX:reply
      done OF ENDOF
      refused OF drop s" the account was refused" FAILED ENDOF
      retry OF drop s" the account asked a retry" FAILED ENDOF
      unlinked OF s" the account was unlinked" FAILED ENDOF
   ;MATCH ;

: ACCOUNTED ( -- ) MAIN @ ACCOUNT-OF ;

\ A client on the fake, no root, holding its first access token.
: TOKENED ( ^ARENA:arena -- ^DROPBOX:client )
   OPENED {: c :}
   c ACCOUNT-OF c ;

private
ARENA LINKS REPLAY:link
public

\ A link on the client below root, with no status.
: NEW-LINK ( ^DROPBOX:client str ^ARENA:arena -- ^REPLAY:link )
   {: c r:str ar :}
   ar LINKS-NEW {: l :}
   c l REPLAY-LINK:CLIENT ! r ar COPIED l REPLAY-LINK:ROOT !
   l ;

: RETRY? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop true ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

\ The fake's record of k downloads.
: DOWNLOADS$ ( n -- str )
   {: k:n :}
   SB-RESET
   k 0 ?do
      i 0 > if s"  " SB-APPEND then s" /2/files/download" SB-APPEND
   loop SB$ ;


\ ---- journal plans

: DISPLAY ( str -- MODEL:path ) MODEL:>PATH ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: o ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: RECORDED? ( JOURNAL:plan-write -- bool )
   MATCH JOURNAL:plan-write
      recorded OF drop true ENDOF
      already-live OF drop false ENDOF
   ;MATCH ;

\ A pending plan creating the local directory at path.
: RECORD ( JOURNAL:journal str ^ARENA:arena -- )
   {: j a:str ar :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY ar ONE-PLAN {: plan :}
   j a DISPLAY plan ar JOURNAL:RECORD-PLAN RECORDED? TTRUE ;


\ ---- download slot leases

: UNPROTECTED ( LOCAL:binding -- bool ) drop false ;

: LEASED
   ( option<LOCAL:download-slot-lease> -- LOCAL:download-slot-lease )
   MATCH option
      none OF s" test-client: no download slot leased" FAILED ENDOF
      some OF ENDOF
   ;MATCH ;


\ ---- the checkpointed partial download

EXPORT LOCAL:DOWNLOAD-CHECKPOINT-BYTES

: CHECKPOINT ( -- n ) DOWNLOAD-CHECKPOINT-BYTES ;

private

TYPED-VARIABLE HASHING DROPBOX:hasher
variable REMAINING
$10000 constant XS-SIZE
XS-SIZE BUFFER: XS

\ Rust's FailingBytes: "x" bytes until none remain, then a reset
\ connection.
: FAILING ( ^u8 n -- n )
   {: dst:^ cap:n :}
   REMAINING @ 0= if 104 FS:CAUSE! E-FS-IO throw then
   REMAINING @ cap min XS-SIZE min {: k:n :}
   XS dst k BYTE-COPY
   k negate REMAINING +!
   k ;

: READY-PARTIAL
   ( LOCAL:download-preparation -- ^LOCAL:download-partial )
   MATCH LOCAL:download-preparation
      ready OF ENDOF
      complete OF drop s" test-client: no partial" FAILED ENDOF
      ephemeral OF s" test-client: no partial" FAILED ENDOF
   ;MATCH ;

public

: FILL-XS ( -- ) XS-SIZE 0 ?do $78 XS i + c! loop ;

\ The lease's slot holding a durable checkpoint of CHECKPOINT "x"
\ bytes for target t, as a transfer lost just past it leaves it.
: CHECKPOINTED
   ( fd str str DROPBOX:hash LOCAL:download-slot-lease ^ARENA:arena
     -- )
   {: root:fd r:str t:str c:DROPBOX:hash
      l:LOCAL:download-slot-lease ar :}
   root r t c l ar LOCAL:PREPARE-DOWNLOAD-SLOT-AT READY-PARTIAL
   {: x :}
   CHECKPOINT 1+ REMAINING !
   [: x CHECKPOINT DROPBOX:BLOCK + [: FAILING ;] ar
      LOCAL:APPEND-PARTIAL drop ;]
   [: 2drop true ;] LOCAL:CONVERTING LOCAL:E-STAGE-READ T= ;

\ The content hash of CHECKPOINT "x" bytes, then t.
: PAST-HASH ( str ^ARENA:arena -- DROPBOX:hash )
   {: t:str ar :}
   HASHING DROPBOX:HASH-BEGIN
   CHECKPOINT XS-SIZE / 0 ?do XS XS-SIZE HASHING DROPBOX:HASH-FEED loop
   t str> HASHING DROPBOX:HASH-FEED
   HASHING DROPBOX:HASH-END ar COPIED DROPBOX:>HASH ;

\ The fake's p at rev v, of content c: CHECKPOINT bytes it does not
\ keep, then t, so its download from the start answers 500.
: SERVES-PAST ( str str str DROPBOX:hash -- )
   {: p:str v:str t:str c:DROPBOX:hash :}
   t str> nip {: tu:n :}
   p p v c DROPBOX:HASH>STR CHECKPOINT tu + TEST-DROPBOX:FILE!
   v CHECKPOINT t TEST-DROPBOX:CONTENT-TAIL! ;


\ ---- a socket

private

PROCESS-SYMBOLS
FUNCTION: SOCKET-CALL socket ( n n n -- i32 ) ;FUNCTION
FUNCTION: BIND-CALL bind ( n ^u8 n -- i32 ) ;FUNCTION

1 constant AF-UNIX
1 constant SOCK-STREAM
\ Linux sockaddr_un: a u16 sun_family, then a 108-byte sun_path.
110 BUFFER: SOCKADDR

public

\ A socket bound at the path, as Rust's UnixListener::bind leaves one,
\ by /proc/self/fd/<parent>/<name>, which any depth fits; its descriptor.
: SOCKET-AT ( str -- fd )
   {: s:str :}
   s str> {: p:^ u:n :}
   s FS:BASENAME {: b:str :}
   b str> nip {: bu:n :}
   p u bu - >str FS:OPEN-DIR-READ {: d:n :}
   SB-RESET s" /proc/self/fd/" SB-APPEND d FMT:SB-INT
   s" /" SB-APPEND b SB-APPEND SB$ str> {: q:^ qu:n :}
   qu 108 >= if d close E-FS-PATH throw then
   AF-UNIX SOCKADDR c! 0 SOCKADDR 1 + c!
   q SOCKADDR 2 + qu BYTE-COPY 0 SOCKADDR 2 + qu + c!
   AF-UNIX SOCK-STREAM 0 SOCKET-CALL {: s:n :}
   s 0 >= TTRUE
   s SOCKADDR qu 3 + BIND-CALL 0 T=
   d close
   s >FD ;

;package
