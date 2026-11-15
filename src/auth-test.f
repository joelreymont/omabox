\ auth-test.f - AUTH's store and load on a recording store SECRET:STORE!
\ binds before any SECRET call, so no case reaches the keyring or the
\ session bus: the item BIND names and the exact record STORE writes; a
\ record LOAD decodes, a miss, a refused access and an unanswered
\ service answering unavailable, and a configuration failure passed up;
\ a malformed record, one cut off, and one not UTF-8; a wrongly typed
\ version, a repeated one, and one out of u8's range; a token STORE
\ cannot write as UTF-8; a record of 8191 bytes read back, one of 8192
\ bytes or more, written or read; and version 2. Each refusal's log
\ line is captured in TMPDIR, checked to be one line with its text and
\ not the word sentinel, and removed.
\ Run from the repository root: hb --load src/auth-test.f </dev/null
require src/lib/arena.f
require src/lib/span.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/secret.f
require src/journal.f
require src/auth.f

\ SECRET reopened: the attribute keys and label BIND bound, as LINUX-ITEM!
\ lays them, each NUL-terminated. The word lands in AUTH-TEST, so SECRET's
\ public surface gains nothing.
package SECRET
: AUTH-TEST:BOUND-NAMES ( -- ^u8 n )
   0 ITEM-NAMES ITEM-LABEL-AT @ s" Omabox Dropbox credentials" nip + 1+ ;
;package

\ AUTH reopened: a case reads CAP and the lookup's variants.
package AUTH
private

16384 constant ROOM
ROOM BUFFER: HELD          \ the record READ answers, or WRITE took
variable HELD-U
TYPED-VARIABLE PRESENT bool
false PRESENT !
variable READ-CODE         \ READ throws it when nonzero
variable WRITES
64 BUFFER: SEEN-SERVICE  variable SEEN-SERVICE-U
64 BUFFER: SEEN-ACCOUNT  variable SEEN-ACCOUNT-U

9000 constant FILLER-U
FILLER-U BUFFER: FILLER
variable TOKEN-U           \ the bytes of FILLER a too-large token takes

PATH-CAP BUFFER: DIR       variable DIR-U
PATH-CAP BUFFER: LOG-PATH  variable LOG-PATH-U
CAP BUFFER: ERR

TYPED-VARIABLE ACTION [ -- ]


\ ---- the recording store ------------------------------------------

: SEEN ( ^u8 n ^u8 n -- )
   {: s:^ su:n a:^ au:n :}
   s SEEN-SERVICE su BYTE-COPY su SEEN-SERVICE-U !
   a SEEN-ACCOUNT au BYTE-COPY au SEEN-ACCOUNT-U ! ;

: REC-READ ( ^u8 n ^u8 n SPAN:span<u8> -- n bool )
   {: s:^ su:n a:^ au:n dest :}
   s su a au SEEN
   READ-CODE @ 0<> if READ-CODE @ throw then
   PRESENT @ 0= if 0 false exit then
   HELD-U @ dest SPAN:$ nip > if SECRET:E-CAPACITY throw then
   HELD HELD-U @ dest SPAN:COPY
   HELD-U @ true ;

: REC-WRITE ( ^u8 n ^u8 n ^u8 n -- )
   {: s:^ su:n a:^ au:n v:^ vu:n :}
   s su a au SEEN
   v HELD vu BYTE-COPY vu HELD-U !
   1 WRITES +! ;

: REC-ERASE ( ^u8 n ^u8 n -- bool ) 2drop 2drop false ;

' REC-READ ' REC-WRITE ' REC-ERASE SECRET:STORE!

: FILL-FILLER ( -- ) FILLER-U 0 ?do [char] x FILLER i + c! loop ;
FILL-FILLER


\ ---- helpers ------------------------------------------------------

\ The store holds the record, and READ finds it.
: HOLD ( ^u8 n -- )
   {: r:^ ru:n :}
   r HELD ru BYTE-COPY ru HELD-U !
   true PRESENT ! 0 READ-CODE ! ;

: BINDING ( -- JOURNAL:dropbox-binding )
   s" account-id" >str s" namespace-id" >str s" /Root" >str
   JOURNAL-DROPBOX--BINDING:MAKE ;

: STORE-TOKEN ( ^u8 n -- ) >str {: t:str :} BINDING t STORE ;

: DROP-LOOKUP ( lookup -- ) drop ;

: LOADS ( -- ) [: LOAD DROP-LOOKUP ;] ARENA:WITH ;

: TOO-LONG ( -- ) FILLER TOKEN-U @ STORE-TOKEN ;

: UNAVAILABLE ( lookup -- bool )
   MATCH lookup
      found OF drop drop false ENDOF
      unavailable OF true ENDOF
   ;MATCH ;

: SAME$ ( ^u8 n str -- ) str> T$= ;

: CHECK-FOUND ( JOURNAL:dropbox-binding str -- )
   {: b token:str :}
   b JOURNAL-DROPBOX--BINDING:UNMAKE {: a:str n:str r:str :}
   s" account" a SAME$
   s" namespace" n SAME$
   s" /Root" r SAME$
   s" lookup-token" token SAME$ ;

: FOUND ( lookup -- )
   MATCH lookup
      found OF CHECK-FOUND ENDOF
      unavailable OF false TTRUE ENDOF
   ;MATCH ;

: IDENTIFIED ( -- )
   SEEN-SERVICE SEEN-SERVICE-U @ s" org.omarchy.omabox" T$=
   SEEN-ACCOUNT SEEN-ACCOUNT-U @ s" dropbox-credentials-v1" T$= ;


\ The action throws want with fd 2 sent to LOG-PATH, which then holds
\ one line with the text and no sentinel, and is removed.
: LOGGED ( [ -- ] n ^u8 n -- )
   {: want t:^ tu :}
   ACTION !
   LOG-PATH LOG-PATH-U @ STDERR:CAPTURE
   [: ACTION @ want TTHROWSQ ;] [: STDERR:;CAPTURE ;] finally
   LOG-PATH LOG-PATH-U @ ERR CAP FS:READ-ALL {: u :}
   LOG-PATH LOG-PATH-U @ FS:REMOVE-FILE
   ERR u 10 COUNT-CHAR 1 T=
   ERR u t tu CONTAINS? TTRUE
   ERR u s" sentinel" CONTAINS? TFALSE ;

: SCRATCH-OPEN ( -- )
   s" auth-test" FS:MKTEMP-DIR {: d:^ du :}
   d DIR du BYTE-COPY du DIR-U !
   d LOG-PATH du BYTE-COPY
   s" /stderr.txt" {: f:^ fu :}
   f LOG-PATH du + fu BYTE-COPY
   du fu + LOG-PATH-U ! ;

: SCRATCH-CLOSE ( -- ) DIR DIR-U @ FS:REMOVE-TREE ;


\ ---- the cases ----------------------------------------------------

: SECRET-TOOL-STORE-USES-FIXED-ARGUMENTS-AND-EXACT-JSON-STDIN ( -- )
   s" secret_tool_store_uses_fixed_arguments_and_exact_json_stdin" T-LABEL
   0 WRITES !
   s" credential-stdin-sentinel" STORE-TOKEN
   WRITES @ 1 T=
   IDENTIFIED
   HELD HELD-U @
   s\" {\"version\":1,\"refresh_token\":\"credential-stdin-sentinel\",\"account_id\":\"account-id\",\"root_namespace_id\":\"namespace-id\",\"remote_root\":\"/Root\"}"
   T$=
   AUTH-TEST:BOUND-NAMES
   s\" application\zkind\zOmabox Dropbox credentials\z" T$= ;

: SECRET-TOOL-LOOKUP-DECODES-RECORD-AND-PRESERVES-NONZERO-STATUS
   ( ^ARENA:arena -- )
   {: ar :}
   s" secret_tool_lookup_decodes_record_and_preserves_nonzero_status"
   T-LABEL
   s\" {\"version\":1,\"refresh_token\":\"lookup-token\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Root\"}"
   HOLD
   0 SEEN-SERVICE-U ! 0 SEEN-ACCOUNT-U !
   ar LOAD FOUND
   IDENTIFIED
   false PRESENT !
   ar LOAD UNAVAILABLE TTRUE
   SECRET:E-ACCESS READ-CODE !
   ar LOAD UNAVAILABLE TTRUE
   SECRET:E-UNAVAILABLE READ-CODE !
   ar LOAD UNAVAILABLE TTRUE
   SECRET:E-CONFIG READ-CODE !
   [: LOADS ;] SECRET:E-CONFIG TTHROWSQ
   0 READ-CODE ! ;

: SECRET-TOOL-PARSER-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT ( -- )
   s" secret_tool_parser_diagnostics_do_not_echo_output" T-LABEL
   s\" {\"refresh_token\":\"parser-output-secret-sentinel\",BROKEN" HOLD
   [: LOADS ;] E-JSON
   s" invalid Omabox Dropbox credential record: credential JSON syntax error"
   LOGGED
   \ Cut after a key: one cut inside a string logs syntax (see REFUSED).
   s\" {\"version\":1,\"refresh_token\":\"cut-sentinel\",\"account_id\":" HOLD
   [: LOADS ;] E-JSON s" credential JSON end-of-input error" LOGGED
   s\" {\"version\":1,\"refresh_token\":\"utf8-sentinel\xFF\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\"}"
   HOLD
   [: LOADS ;] E-UTF8
   s" Secret Service returned an invalid Omabox Dropbox credential encoding"
   LOGGED ;

: SECRET-TOOL-DATA-ERROR-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT ( -- )
   s" secret_tool_data_error_diagnostics_do_not_echo_output" T-LABEL
   s\" {\"version\":\"typed-field-secret-sentinel\",\"refresh_token\":\"token\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\"}"
   HOLD
   [: LOADS ;] E-JSON s" credential JSON data error" LOGGED
   s\" {\"version\":1,\"refresh_token\":\"repeat-sentinel\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\",\"version\":1}"
   HOLD
   [: LOADS ;] E-JSON s" credential JSON data error" LOGGED
   s\" {\"version\":256,\"refresh_token\":\"range-sentinel\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\"}"
   HOLD
   [: LOADS ;] E-JSON s" credential JSON data error" LOGGED
   s\" {\"version\":-1,\"refresh_token\":\"sign-sentinel\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\"}"
   HOLD
   [: LOADS ;] E-JSON s" credential JSON data error" LOGGED
   [: s\" token-sentinel\xFF" STORE-TOKEN ;] E-JSON
   s" invalid Omabox Dropbox credential record: credential JSON data error"
   LOGGED ;

\ STORE's bound, where an empty token gives the record's other bytes,
\ and the CAP - 1 bytes it wrote LOAD finds; then LOAD's bound, at CAP
\ bytes and at CAP + 1, which E-CAPACITY refuses.
: CREDENTIAL-OF-8192-BYTES-OR-MORE-IS-TOO-LARGE ( -- )
   s" credential_of_8192_bytes_or_more_is_too_large" T-LABEL
   s" " STORE-TOKEN HELD-U @ {: other:n :}
   0 WRITES !
   FILLER CAP 1- other - STORE-TOKEN
   WRITES @ 1 T=
   HELD-U @ CAP 1- T=
   true PRESENT ! 0 READ-CODE !
   [: LOAD UNAVAILABLE ;] ARENA:WITH TFALSE
   CAP other - TOKEN-U !
   [: TOO-LONG ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   FILLER-U TOKEN-U !
   [: TOO-LONG ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   WRITES @ 1 T=
   FILLER CAP HOLD
   [: LOADS ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   FILLER CAP 1+ HOLD
   [: LOADS ;] E-TOO-LARGE s" exceeds the supported size" LOGGED ;

: STORED-CREDENTIAL-VERSION-2-IS-UNSUPPORTED ( -- )
   s" stored_credential_version_2_is_unsupported" T-LABEL
   s\" {\"version\":2,\"refresh_token\":\"version-sentinel\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Root\"}"
   HOLD
   [: LOADS ;] E-VERSION
   s" Secret Service returned unsupported Omabox credential version 2"
   LOGGED ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   SECRET-TOOL-STORE-USES-FIXED-ARGUMENTS-AND-EXACT-JSON-STDIN
   ar SECRET-TOOL-LOOKUP-DECODES-RECORD-AND-PRESERVES-NONZERO-STATUS
   SECRET-TOOL-PARSER-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT
   SECRET-TOOL-DATA-ERROR-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT
   CREDENTIAL-OF-8192-BYTES-OR-MORE-IS-TOO-LARGE
   STORED-CREDENTIAL-VERSION-2-IS-UNSUPPORTED ;


: TESTS ( -- )
   T-RESET
   BIND
   SCRATCH-OPEN
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE SCRATCH-CLOSE ;] finally
   s" auth-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
