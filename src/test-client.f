\ test-client.f - the fake Dropbox's client and its checkpointed partial
\ downloads, for tests, never production.
\ OPENED opens a client on test-dropbox.f's fake, MAIN holds it while it
\ serves, ACCOUNTED takes its first access token, and NEW-LINK makes a
\ REPLAY link on a client below a root. CHECKPOINTED leaves a slot
\ holding a durable checkpoint of CHECKPOINT "x" bytes, FILL-XS writes
\ those bytes, and PAST-HASH and SERVES-PAST give the fake a file of them
\ followed by a tail. SOCKET-AT binds a socket at a path. Tests alone
\ load this file; nothing in the program calls these words.
\ STORAGE CLASS. PROCESS-WIDE: CFG, MAIN, the "x" bytes, their hasher and
\ the socket address are one each, for one case at a time.

require src/lib/error.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/test.f
require src/lib/fs.f
require src/lib/adt/option.f
require src/lib/net/curl.f
require src/dropbox.f
require src/test-dropbox.f
require src/local.f
require src/replay.f

package TEST-CLIENT
public

\ Ends the run: the case cannot go on.
: FAILED ( ^u8 n -- ) T-EX-FAIL die ;

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;


\ ---- the fake's client

TYPED-VARIABLE CFG DROPBOX:config
\ The client on the fake, while it serves.
TYPED-VARIABLE MAIN ^DROPBOX:client

\ A client on the fake, no root, keeping no rotated token.
: OPENED ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   [: 2drop ;] CFG DROPBOX-CONFIG:STORE !
   CFG DROPBOX:PRODUCTION
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:API !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   s" live-token" SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   s" " SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG ar DROPBOX:OPEN ;

: CURL-READY ( CURL:status -- )
   MATCH CURL:status
      ok OF ENDOF
      failed OF drop s" the curl loop did not start" FAILED ENDOF
   ;MATCH ;

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

private
ARENA LINKS REPLAY:link
public

\ A link on the client below root, with no status.
: NEW-LINK ( ^DROPBOX:client ^u8 n ^ARENA:arena -- ^REPLAY:link )
   {: c r:^ ru:n ar :}
   ar LINKS-NEW {: l :}
   c l REPLAY-LINK:CLIENT ! r ru ar COPIED l REPLAY-LINK:ROOT !
   l ;

: RETRY? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop true ENDOF
      unlinked OF false ENDOF
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
   ( fd str ^u8 n DROPBOX:hash LOCAL:download-slot-lease ^ARENA:arena
     -- )
   {: root:fd r:str t:^ tu:n c:DROPBOX:hash
      l:LOCAL:download-slot-lease ar :}
   root r str> t tu c l ar LOCAL:PREPARE-DOWNLOAD-SLOT-AT READY-PARTIAL
   {: x :}
   CHECKPOINT 1+ REMAINING !
   [: x CHECKPOINT DROPBOX:BLOCK + [: FAILING ;] ar
      LOCAL:APPEND-PARTIAL drop ;]
   [: 2drop true ;] LOCAL:CONVERTING LOCAL:E-STAGE-READ T= ;

\ The content hash of CHECKPOINT "x" bytes, then t.
: PAST-HASH ( ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: t:^ tu:n ar :}
   HASHING DROPBOX:HASH-BEGIN
   CHECKPOINT XS-SIZE / 0 ?do XS XS-SIZE HASHING DROPBOX:HASH-FEED loop
   t tu HASHING DROPBOX:HASH-FEED
   HASHING DROPBOX:HASH-END ar COPIED DROPBOX:>HASH ;

\ The fake's p at rev v, of content c: CHECKPOINT bytes it does not
\ keep, then t, so its download from the start answers 500.
: SERVES-PAST ( ^u8 n ^u8 n ^u8 n DROPBOX:hash -- )
   {: p:^ pu:n v:^ vu:n t:^ tu:n c:DROPBOX:hash :}
   c DROPBOX:HASH>STR str> {: h:^ hu:n :}
   p pu p pu v vu h hu CHECKPOINT tu + TEST-DROPBOX:FILE!
   v vu CHECKPOINT t tu TEST-DROPBOX:CONTENT-TAIL! ;


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

\ A socket bound at the path, as Rust's UnixListener::bind leaves one;
\ its descriptor.
: SOCKET-AT ( ^u8 n -- fd )
   {: p:^ u:n :}
   u 108 < TTRUE
   AF-UNIX SOCKADDR c! 0 SOCKADDR 1 + c!
   p SOCKADDR 2 + u BYTE-COPY 0 SOCKADDR 2 + u + c!
   AF-UNIX SOCK-STREAM 0 SOCKET-CALL {: s:n :}
   s 0 >= TTRUE
   s SOCKADDR u 3 + BIND-CALL 0 T=
   s >FD ;

;package
