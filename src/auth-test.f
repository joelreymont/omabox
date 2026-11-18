\ auth-test.f - AUTH's store and load on a recording store SECRET:STORE!
\ binds before any SECRET call, so no case reaches the keyring or the
\ session bus. Five cases BIND the store that runs a program, with
\ PROGRAM a path in the suite's scratch directory, then bind the
\ recording store again: Rust's exact arguments and the exact record
\ STORE writes to a `#!/bin/sh` fake's stdin; Rust's arguments for a
\ lookup, the record LOAD decodes from a fake's stdout on exit 0, and a
\ miss on exit 1 and on SIGKILL; a program that does not exist, which
\ STORE and LOAD cannot start; a lookup's output of 8192 bytes or more,
\ and of more than a pipe holds; and a store's exit 3, and its exit 1
\ before reading a value larger than a pipe holds, each logged once. On
\ the recording store: a refused access and an unanswered service
\ answering unavailable, and a configuration failure passed up;
\ a store SECRET:WRITE fails with each code it throws, passed up;
\ a malformed record, one cut off, and one not UTF-8; a wrongly typed
\ version, a repeated one, and one out of u8's range; a token STORE
\ cannot write as UTF-8; a record of 8191 bytes read back, one of 8192
\ bytes or more, written or read; and version 2. Each refusal's log
\ line is captured in TMPDIR, checked to be one line with its text and
\ not the word sentinel, and removed. A login's URL for RFC 7636's
\ example verifier, written out by dropbox-sdk 0.20.3's rules, and two
\ STARTs' verifiers.
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

\ AUTH reopened: a case reads CAP and the lookup's variants, sets
\ PROGRAM and calls AUTHORIZE-URL.
package AUTH
private

16384 constant ROOM
ROOM BUFFER: HELD          \ the record READ answers, or WRITE took
variable HELD-U
TYPED-VARIABLE PRESENT bool
false PRESENT !
variable READ-CODE         \ READ throws it when nonzero
variable WRITE-CODE        \ WRITE throws it when nonzero
variable WRITES

9000 constant FILLER-U
FILLER-U BUFFER: FILLER
variable TOKEN-U           \ the bytes of FILLER a too-large token takes
\ The bytes a default pipe holds at most: 16 pages of 64 KiB.
1048576 constant PIPE-MOST

PATH-CAP BUFFER: DIR       variable DIR-U
PATH-CAP BUFFER: LOG-PATH  variable LOG-PATH-U
TYPED-VARIABLE AR ^ARENA:arena    \ captured logs, scratch paths and their bytes

TYPED-VARIABLE ACTION [ -- ]


\ ---- the recording store ------------------------------------------

: REC-READ ( str str SPAN:span<u8> -- n bool )
   {: s:str a:str dest :}
   READ-CODE @ 0<> if READ-CODE @ throw then
   PRESENT @ 0= if 0 false exit then
   HELD-U @ dest SPAN:$ nip > if SECRET:E-CAPACITY throw then
   HELD HELD-U @ dest SPAN:COPY
   HELD-U @ true ;

: REC-WRITE ( str str str -- )
   {: s:str a:str vs:str :}
   vs str> {: v:^ vu:n :}
   WRITE-CODE @ 0<> if WRITE-CODE @ throw then
   v HELD vu BYTE-COPY vu HELD-U !
   1 WRITES +! ;

: REC-ERASE ( str str -- bool ) {: s:str a:str :} false ;

\ Binds the recording store, in place of the one BIND binds.
: RECORDING ( -- )
   [: REC-READ ;] [: REC-WRITE ;] [: REC-ERASE ;] SECRET:STORE! ;
RECORDING

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


\ The action throws want with fd 2 sent to LOG-PATH, which then holds
\ one line with the text and no sentinel, and is removed.
: LOGGED ( [ -- ] n ^u8 n -- )
   {: want t:^ tu :}
   ACTION !
   ACTION @ LOG-PATH LOG-PATH-U @ >str AR @ STDERR:CAPTURING str>
   {: code:n e:^ u:n :}
   code want T=
   e u >str 10 COUNT-CHAR 1 T=
   e u t tu CONTAINS? TTRUE
   e u s" sentinel" CONTAINS? TFALSE ;

: SCRATCH-OPEN ( -- )
   s" auth-test" FS:MKTEMP-DIR {: d:^ du :}
   d DIR du BYTE-COPY du DIR-U !
   d LOG-PATH du BYTE-COPY
   s" /stderr.txt" {: f:^ fu :}
   f LOG-PATH du + fu BYTE-COPY
   du fu + LOG-PATH-U ! ;

: SCRATCH-CLOSE ( -- ) DIR DIR-U @ FS:REMOVE-TREE ;


\ ---- the program ----------------------------------------------------

\ DIR/name, in AR.
: UNDER ( ^u8 n -- str )
   {: n:^ nu:n :}
   DIR-U @ 1+ nu + {: pu:n :}
   AR @ pu ARENA:ALLOC drop {: p:^ :}
   DIR p DIR-U @ BYTE-COPY
   [char] / p DIR-U @ + c!
   n p DIR-U @ 1+ + nu BYTE-COPY
   p pu >str ;

\ DIR/name now holds the text.
: HOLDS ( ^u8 n ^u8 n -- )
   {: n:^ nu:n t:^ tu:n :}
   n nu UNDER str> t tu FS:WRITE-ALL ;

\ DIR/name's bytes, in the arena.
: TAKEN ( ^u8 n -- ^u8 n )
   UNDER str> {: p:^ pu:n :}
   AR @ ROOM ARENA:ALLOC {: d:^ du:n :}
   p pu d du FS:READ-ALL {: got:n :}
   d got ;

\ An executable script DIR/name holding the body, which STORE and LOAD
\ then run.
: RUNS ( ^u8 n ^u8 n -- )
   {: n:^ nu:n b:^ bu:n :}
   n nu UNDER {: p:str :}
   p str> b bu FS:WRITE-ALL
   p FS:CHMOD-X
   p PROGRAM ! BIND ;

\ Rust's store fake: its arguments to $0.args, its stdin to $0.stdin.
: STORE-FAKE ( -- ^u8 n )
   s\" #!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\ncat > \"$0.stdin\"\n" ;

\ Rust's lookup fake, whose output and status the case holds in
\ $0.out and $0.status.
: LOOKUP-FAKE ( -- ^u8 n )
   s\" #!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\ncat \"$0.out\"\nexit \"$(cat \"$0.status\")\"\n" ;

: ATTRIBUTES ( -- ^u8 n )
   s\" application\norg.omarchy.omabox\nkind\ndropbox-credentials-v1\n" ;

\ The verb's lines, then the attributes', in the arena.
: ARGUMENTS ( ^u8 n -- ^u8 n )
   {: v:^ vu:n :}
   ATTRIBUTES {: t:^ tu:n :}
   AR @ vu tu + ARENA:ALLOC {: d:^ du:n :}
   v d vu BYTE-COPY
   t d vu + tu BYTE-COPY
   d du ;


\ ---- the cases ----------------------------------------------------

: SECRET-TOOL-STORE-USES-FIXED-ARGUMENTS-AND-EXACT-JSON-STDIN ( -- )
   s" secret_tool_store_uses_fixed_arguments_and_exact_json_stdin" T-LABEL
   s" store-fake" STORE-FAKE RUNS
   s" credential-stdin-sentinel" STORE-TOKEN
   s" store-fake.args" TAKEN
   s\" store\n--label=Omabox Dropbox credentials\n" ARGUMENTS T$=
   s" store-fake.stdin" TAKEN
   s\" {\"version\":1,\"refresh_token\":\"credential-stdin-sentinel\",\"account_id\":\"account-id\",\"root_namespace_id\":\"namespace-id\",\"remote_root\":\"/Root\"}"
   T$=
   RECORDING ;

: SECRET-TOOL-LOOKUP-DECODES-RECORD-AND-PRESERVES-NONZERO-STATUS
   ( ^ARENA:arena -- )
   {: ar :}
   s" secret_tool_lookup_decodes_record_and_preserves_nonzero_status"
   T-LABEL
   s" lookup-fake.out"
   s\" {\"version\":1,\"refresh_token\":\"lookup-token\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Root\"}"
   HOLDS
   s" lookup-fake.status" s" 0" HOLDS
   s" lookup-fake" LOOKUP-FAKE RUNS
   ar LOAD FOUND
   s" lookup-fake.args" TAKEN s\" lookup\n" ARGUMENTS T$=
   s" lookup-fake.status" s" 1" HOLDS
   ar LOAD UNAVAILABLE TTRUE
   s" killed-fake" s\" #!/bin/sh\nkill -9 $$\n" RUNS
   ar LOAD UNAVAILABLE TTRUE
   RECORDING
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

: MISSING-SECRET-TOOL-COULD-NOT-START ( -- )
   s" missing_secret_tool_could_not_start" T-LABEL
   s" absent" UNDER PROGRAM ! BIND
   [: s" absent-sentinel" STORE-TOKEN ;] SECRET:E-CONFIG
   s" credential operation `store Dropbox credential` could not start" LOGGED
   [: LOADS ;] SECRET:E-CONFIG
   s" credential operation `load Dropbox credential` could not start" LOGGED
   RECORDING ;

\ At CAP bytes LOAD refuses the output, past CAP the store does, and
\ past any pipe's capacity the lookup still ends.
: SECRET-TOOL-OUTPUT-OF-8192-BYTES-OR-MORE-IS-TOO-LARGE ( -- )
   s" secret_tool_output_of_8192_bytes_or_more_is_too_large" T-LABEL
   s" large-fake.status" s" 0" HOLDS
   s" large-fake" LOOKUP-FAKE RUNS
   s" large-fake.out" FILLER CAP HOLDS
   [: LOADS ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   s" large-fake.out" FILLER CAP 1+ HOLDS
   [: LOADS ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   s" large-fake.out" UNDER {: o:str :}
   PIPE-MOST FILLER-U / 1+ 0 ?do o FILLER FILLER-U >str FS:APPEND-FILE loop
   [: LOADS ;] E-TOO-LARGE s" exceeds the supported size" LOGGED
   RECORDING ;

: STORED-CREDENTIAL-VERSION-2-IS-UNSUPPORTED ( -- )
   s" stored_credential_version_2_is_unsupported" T-LABEL
   s\" {\"version\":2,\"refresh_token\":\"version-sentinel\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Root\"}"
   HOLD
   [: LOADS ;] E-VERSION
   s" Secret Service returned unsupported Omabox credential version 2"
   LOGGED ;

\ A store's exit 3, and its exit 1 before reading a value no pipe holds,
\ are logged once as failed. Each code the recording store's WRITE throws
\ is rethrown unlogged, and the store keeps no record.
: STORE-FAILURE-NAMES-THE-CREDENTIAL-OPERATION ( -- )
   s" store_failure_names_the_credential_operation" T-LABEL
   s" failing-fake" s\" #!/bin/sh\ncat >/dev/null\nexit 3\n" RUNS
   [: s" exit-sentinel" STORE-TOKEN ;] SECRET:E-ACCESS
   s" credential operation `store Dropbox credential` failed" LOGGED
   s" unread-fake" s\" #!/bin/sh\nexit 1\n" RUNS
   [: SERVICE ACCOUNT AR @ PIPE-MOST 1+ ARENA:ALLOC SECRET:WRITE ;]
   SECRET:E-ACCESS
   s" credential operation `store Dropbox credential` failed" LOGGED
   RECORDING
   0 WRITES !
   SECRET:E-CONFIG WRITE-CODE !
   [: s" config-sentinel" STORE-TOKEN ;] SECRET:E-CONFIG TTHROWSQ
   SECRET:E-ACCESS WRITE-CODE !
   [: s" access-sentinel" STORE-TOKEN ;] SECRET:E-ACCESS TTHROWSQ
   SECRET:E-UNAVAILABLE WRITE-CODE !
   [: s" unavailable-sentinel" STORE-TOKEN ;] SECRET:E-UNAVAILABLE TTHROWSQ
   0 WRITE-CODE !
   WRITES @ 0 T= ;


\ RFC 7636 appendix B's verifier and its challenge. The key holds a
\ space, a byte form_urlencoded encodes and one it keeps.
: FIXED-URL ( ^ARENA:arena -- )
   {: ar :}
   s" app-key 1~*" s" dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
   ar AUTHORIZE-URL str>
   s" https://www.dropbox.com/oauth2/authorize?response_type=code&client_id=app-key+1%7E*&token_access_type=offline&scope=account_info.read+files.metadata.read+files.content.read+files.content.write&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
   T$= ;

: PKCE-AUTHORIZATION-USES-OFFLINE-CODE-FLOW ( ^ARENA:arena -- )
   {: ar :}
   s" pkce_authorization_uses_offline_code_flow" T-LABEL
   ar FIXED-URL
   s" app-key" ar START {: p :}
   p URL s" app-key" p VERIFIER ar AUTHORIZE-URL str> T$= ;

: URL-SAFE? ( n -- bool )
   {: b:n :}
   b STR-ALNUM? b [char] - = or b [char] _ = or ;

: PROOF-SHAPE ( ^u8 n -- )
   {: v:^ u:n :}
   u 43 T=
   u 0 ?do v i + c@ URL-SAFE? TTRUE loop ;

: START-DRAWS-A-FRESH-VERIFIER ( ^ARENA:arena -- )
   {: ar :}
   s" start_draws_a_fresh_verifier" T-LABEL
   s" app-key" ar START {: a :}
   s" app-key" ar START {: b :}
   a VERIFIER PROOF-SHAPE
   b VERIFIER PROOF-SHAPE
   a VERIFIER b VERIFIER STR= TFALSE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   SECRET-TOOL-STORE-USES-FIXED-ARGUMENTS-AND-EXACT-JSON-STDIN
   ar SECRET-TOOL-LOOKUP-DECODES-RECORD-AND-PRESERVES-NONZERO-STATUS
   SECRET-TOOL-PARSER-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT
   SECRET-TOOL-DATA-ERROR-DIAGNOSTICS-DO-NOT-ECHO-OUTPUT
   CREDENTIAL-OF-8192-BYTES-OR-MORE-IS-TOO-LARGE
   MISSING-SECRET-TOOL-COULD-NOT-START
   SECRET-TOOL-OUTPUT-OF-8192-BYTES-OR-MORE-IS-TOO-LARGE
   STORED-CREDENTIAL-VERSION-2-IS-UNSUPPORTED
   STORE-FAILURE-NAMES-THE-CREDENTIAL-OPERATION
   ar PKCE-AUTHORIZATION-USES-OFFLINE-CODE-FLOW
   ar START-DRAWS-A-FRESH-VERIFIER ;


: TESTS ( -- )
   T-RESET
   SCRATCH-OPEN
   ARENA:NEW {: ar :}
   ar AR !
   [: ar CASES ;] [: ar ARENA:RELEASE SCRATCH-CLOSE ;] finally
   s" auth-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
