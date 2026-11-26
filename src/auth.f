\ auth.f - package AUTH: the Dropbox credential in the Secret Service
\ (rust src/auth.rs RefreshTokenStore), through SECRET, read and written
\ by running `secret-tool`, as Rust's is, or, under systemd with
\ credentials passed, read from SECRET:DIR-BIND's store over their
\ directory, the item the file dropbox-credentials-v1. WRITE-FILE writes
\ such a file for setup. The Secret Service's item is the one whose
\ attributes application and kind hold org.omarchy.omabox and
\ dropbox-credentials-v1, so either version reads what the other stored.
\ Its value is serde_json's compact record of the version, 1, the
\ refresh token and the Dropbox binding, under 8192 bytes. LOAD reads it
\ as serde reads Rust's LoadedSecret: members in any order, an unknown
\ one skipped, one absent, repeated or of another type refused. It
\ refuses records serde reads and no writer makes: one written as an
\ array, one whose skipped member holds a lone surrogate escape or a
\ repeated member name, and one that repeats a skipped member's name.
\ AUTH's failures, the Secret Service store's included, are logged once
\ with the Rust version's text, then thrown as its codes; the directory
\ store's read faults are logged by SECRET, and its refusal to store is
\ thrown unlogged, for the caller to report. No log line holds a string
\ of the record, only an unsupported version's number.
\ START begins a browser login (rust OAuthClient::begin): a PKCE verifier
\ of 32 random bytes, and the URL dropbox-sdk 0.20.3's AuthorizeUrlBuilder
\ builds for it, byte for byte.
\ STORAGE CLASS. PROCESS-WIDE: PROGRAM, written before BIND and only
\ read by a call; the store BIND binds, and its directory, SECRET keeps.
\ CALLER-OWNED: the strings LOAD answers, the record it read, and
\ START's login, lie in the arena the caller passes; a lookup's output,
\ and WRITE-FILE's record, in their own arenas.
HB-TARGET-LINUX? HB-TARGET-LINUX-X86-64? or ?TARGET
require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/utf8-scalar.f
require src/lib/vector.f
require src/lib/secret.f
require src/lib/secret/dir.f
require src/lib/process.f
require src/lib/entropy.f
require src/lib/base64.f
require src/lib/uri.f
require src/lib/json/write.f
require src/lib/json/value.f
require src/lib/json/read.f
require src/lib/spawn.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/journal.f

package AUTH
public

-100600 constant E-FIRST
-100699 constant E-LAST
-100600
   s" the credential store returned an invalid Omabox Dropbox credential record"
   ERROR:CODE E-JSON
-100601
   s" the credential store returned an invalid Omabox Dropbox credential encoding"
   ERROR:CODE E-UTF8
-100602 s" Omabox Dropbox credential record exceeds the supported size"
   ERROR:CODE E-TOO-LARGE
-100603
   s" the credential store returned unsupported Omabox credential version"
   ERROR:CODE E-VERSION
-100604 s" could not generate a secure OAuth proof" ERROR:CODE E-RANDOM

\ found: the binding and the refresh token; unavailable: no item, or a
\ Secret Service that refused or did not answer.
ENUM lookup
   VARIANT found
      FIELD binding JOURNAL:dropbox-binding
      FIELD refresh-token str
   ;VARIANT
   VARIANT unavailable ;VARIANT
;ENUM

\ A browser login in progress: the URL the user opens, and the PKCE
\ verifier the code it shows is exchanged with.
STRUCTURE pending OPAQUE DERIVE addr
   FIELD url str
   FIELD verifier str
;STRUCTURE

private

8192 constant CAP          \ a record's bytes, exclusive
1 constant VERSION

: SERVICE ( -- str ) s" org.omarchy.omabox" ;
: ACCOUNT ( -- str ) s" dropbox-credentials-v1" ;


\ ---- failures ------------------------------------------------------

: LOG-OPEN ( -- ) LOG:ERROR s" auth" LOG:LINE ;

: FAIL ( n -- )
   {: code:n :}
   LOG-OPEN code ERROR:TEXT$ LOG:TEXT+ LOG:;LINE
   code throw ;

\ Logs a refused record with the category of the error found first:
\ the whole text is read before any member, so where serde stops at an
\ earlier data error, or calls an unterminated string end-of-input, this
\ one says syntax.
: REFUSED ( str -- )
   {: what:str :}
   LOG-OPEN E-JSON ERROR:TEXT$ LOG:TEXT+
   s" : credential JSON " LOG:TEXT+ what LOG:TEXT+
   s"  error" LOG:TEXT+ LOG:;LINE
   E-JSON throw ;

: WRONG-VERSION ( n -- )
   {: found:n :}
   LOG-OPEN E-VERSION ERROR:TEXT$ LOG:TEXT+
   s"  " LOG:TEXT+ found LOG:INT+ LOG:;LINE
   E-VERSION throw ;

: STORING ( -- str ) s" store Dropbox credential" ;
: LOADING ( -- str ) s" load Dropbox credential" ;

\ rust CredentialSpawn, CredentialWait and CredentialStatus: the
\ operation, then what befell it.
: OPERATION ( str str n -- )
   {: op:str what:str code:n :}
   LOG-OPEN s" credential operation `" LOG:TEXT+ op LOG:TEXT+
   s" ` " LOG:TEXT+ what LOG:TEXT+ LOG:;LINE
   code throw ;

\ The answers secret-tool's nonzero exit gives: a locked or refused
\ keyring, and a Secret Service that did not answer.
: UNAVAILABLE? ( n -- bool )
   {: code:n :}
   code SECRET:E-ACCESS = code SECRET:E-UNAVAILABLE = or ;


\ ---- the record written --------------------------------------------

ARENA WRITERS JSON:writer

: STRING+ ( ^JSON:writer str str -- ^JSON:writer )
   {: k:str v:str :}
   k v JSON:WRITE-FIELD-S ;

\ serde's field order, StoredSecret's.
: FIELDS ( JOURNAL:dropbox-binding str ^JSON:writer -- )
   {: b token:str w :}
   b JOURNAL-DROPBOX--BINDING:UNMAKE
   {: account:str namespace:str root:str :}
   w JSON:WRITE-OBJECT-START
   s" version" VERSION JSON:WRITE-FIELD-U JSON:WRITE-COMMA
   s" refresh_token" token STRING+ JSON:WRITE-COMMA
   s" account_id" account STRING+ JSON:WRITE-COMMA
   s" root_namespace_id" namespace STRING+ JSON:WRITE-COMMA
   s" remote_root" root STRING+
   JSON:WRITE-OBJECT-END drop ;

\ The record, written into a vector in the arena; one of CAP bytes or
\ more is too large, and a string that is not UTF-8 is a record serde
\ could not write.
: RECORD ( JOURNAL:dropbox-binding str ^ARENA:arena -- str )
   {: b token:str ar :}
   ar WRITERS-NEW {: w :}
   ar ARENA:ALLOCATOR 0 [type] u8 VEC:NEW {: v :}
   v CAP VEC:RESERVE
   w v JSON:OPEN drop
   [: b token w FIELDS ;] catch {: code:n :}
   code E-JSON-WRITE-BYTE = if s" data" REFUSED then
   code 0<> if code throw then
   w JSON:WRITTEN$ {: r:str :}
   w JSON:CLOSE
   r STR:len CAP >= if E-TOO-LARGE FAIL then
   r ;

: WRITE-RECORD ( JOURNAL:dropbox-binding str ^ARENA:arena -- )
   RECORD {: r:str :} SERVICE ACCOUNT r SECRET:WRITE ;


\ ---- the record read -----------------------------------------------

\ The record is parsed once, which refuses a repeated member name at any
\ depth, and each member is taken by GET.

: EXPECT ( bool -- ) 0= if E-JSON throw then ;

\ A string's decoded bytes, in a vector in the arena sized to its text,
\ which bounds them.
: READ-STRING ( JSON:value ^ARENA:arena -- str )
   {: v ar :}
   v JSON:STRING? EXPECT
   ar ARENA:ALLOCATOR 0 [type] u8 VEC:NEW {: s :}
   s v JSON:TEXT$ STR:len VEC:RESERVE
   v s JSON:APPEND-STRING
   s VEC:BYTES ;

\ serde's u8: an integer with no sign, up to 255, so digits alone.
: READ-VERSION ( JSON:value -- n )
   {: v :}
   v JSON:TEXT$ {: a:str :}
   a STR:DIGITS? EXPECT
   a STR:len 3 <= EXPECT
   v JSON:>N {: n:n :}
   n 255 <= EXPECT
   n ;

: STRING-AT ( JSON:value str ^ARENA:arena -- str )
   {: ar :} JSON:GET ar READ-STRING ;

\ LoadedSecret: the version, the binding and the refresh token.
: READ-RECORD
   ( str ^ARENA:arena -- n JOURNAL:dropbox-binding str )
   {: t:str ar :}
   t JSON:PARSE {: v :}
   v s" version" JSON:GET READ-VERSION
   v s" account_id" ar STRING-AT
   v s" root_namespace_id" ar STRING-AT
   v s" remote_root" ar STRING-AT
   JOURNAL-DROPBOX--BINDING:MAKE
   v s" refresh_token" ar STRING-AT ;

\ The category a refusal is logged with: E-JSON-READ-EOF the text's end,
\ another reader code its syntax; E-JSON its data, and JSON:E-MEMBER, a
\ member missing or repeated or a text no object, which serde calls data.
: CATEGORY ( n -- str )
   {: code:n :}
   code E-JSON = code JSON:E-MEMBER = or if s" data" exit then
   code E-JSON-READ-EOF = if s" end-of-input" exit then
   s" syntax" ;

: REFUSAL? ( n -- bool )
   {: code:n :}
   code E-JSON-READ-LAST >= code E-JSON-READ-FIRST <= and
   code E-JSON = or ;

: NO-STR ( -- str ) s" " ;

: NO-BINDING ( -- JOURNAL:dropbox-binding )
   NO-STR NO-STR NO-STR JOURNAL-DROPBOX--BINDING:MAKE ;

\ A seed's typed drop, which types the read that replaces it.
: DROP-SEED ( n JOURNAL:dropbox-binding str -- ) drop drop drop ;

\ READ-RECORD, replacing the seed it is given, as catch keeps the
\ stack's shape.
: DECODE ( str ^ARENA:arena -- n JOURNAL:dropbox-binding str )
   {: s:str ar :}
   0 NO-BINDING NO-STR [: DROP-SEED s ar READ-RECORD ;] catch
   {: code:n :}
   code 0= if exit then
   code REFUSAL? if code CATEGORY REFUSED then
   code throw ;

\ Rust's checks of the item's value, in Rust's order: its size, its
\ encoding, its form, then its version.
: CREDENTIAL ( str ^ARENA:arena -- lookup )
   {: t:str ar :}
   t STR:len CAP >= if E-TOO-LARGE FAIL then
   t UTF8:VALID? 0= if E-UTF8 FAIL then
   t ar DECODE {: version:n b token:str :}
   version VERSION <> if version WRONG-VERSION then
   b token construct lookup found ;

\ Whether the item was found, appended to dest.
: FETCH ( ^VEC:vector<u8> -- bool )
   {: dest :}
   false [: drop SERVICE ACCOUNT dest SECRET:READ ;] catch
   {: code:n :}
   code 0= if exit then
   drop
   code UNAVAILABLE? if false exit then
   code E-TOO-LARGE = if E-TOO-LARGE FAIL then
   code throw ;


\ ---- the store: one `secret-tool` run per call ---------------------

\ Rust's arguments: the verb, a store's label, then the item's attributes.
\ Neither the value nor the child's output is logged.

TYPED-VARIABLE PROGRAM str     \ the program a call runs; tests set it

: SECRET-TOOL ( -- ) s" /usr/bin/secret-tool" PROGRAM ! ;
SECRET-TOOL

: LABEL ( -- str ) s" --label=Omabox Dropbox credentials" ;

\ The item's attributes, for the service and the account.
: ITEM ( PROCESS:request str str -- PROCESS:request )
   {: s:str a:str :}
   s" application" PROCESS:ARG s PROCESS:ARG
   s" kind" PROCESS:ARG a PROCESS:ARG ;

\ Whether the child ended other than by exit 0: a nonzero exit or a signal.
: FAILED? ( PROCESS:status -- bool )
   PROCESS:STATUS>RC RC>N 0<> ;

\ `secret-tool lookup`, its output captured into room of CAP bytes; only
\ an exit of 0 appends it to dest, so a miss leaves dest unchanged.
: LOOKED-UP ( str str ^VEC:vector<u8> ^ARENA:arena -- bool )
   {: s:str a:str dest ar :}
   ar CAP ARENA:ALLOC SPAN:MAKE {: room :}
   PROGRAM @ PROCESS:NEW s" lookup" PROCESS:ARG s a ITEM
   PROCESS-STDIO:NULL room PROCESS-STDIO:PIPE PROCESS-STDIO:NULL
   PROCESS:RUN {: u:len eu:len status :}
   status FAILED? if SECRET:E-UNAVAILABLE throw then
   room u LEN>N SPAN:TAKE SPAN:$ dest VEC:APPEND
   true ;

\ `secret-tool store`, the value its stdin.
: STORED ( str str str -- )
   {: s:str a:str v:str :}
   PROGRAM @ PROCESS:NEW s" store" PROCESS:ARG LABEL PROCESS:ARG
   s a ITEM
   v str> SPAN:MAKE PROCESS-STDIO:PIPE PROCESS-STDIO:NULL PROCESS-STDIO:NULL
   PROCESS:RUN {: u:len eu:len status :}
   status FAILED? if SECRET:E-ACCESS throw then ;

\ rust CredentialRead: a lookup's failed read or poll.
: UNREAD ( -- )
   LOG-OPEN s" could not read the Dropbox credential from Secret Service"
   LOG:TEXT+ LOG:;LINE SECRET:E-UNAVAILABLE throw ;

\ rust CredentialWrite: a store's failed pipe or poll.
: UNSENT ( -- )
   LOG-OPEN s" could not send the Dropbox credential to Secret Service"
   LOG:TEXT+ LOG:;LINE SECRET:E-ACCESS throw ;

\ A run's failure, logged once as the store's code: an unstarted child
\ E-CONFIG, a failed wait fail; another code passes up unlogged.
: CAUGHT ( n str n -- )
   {: code:n op:str fail:n :}
   code E-PROC-SPAWN = if
      op s" could not start" SECRET:E-CONFIG OPERATION
   then
   code E-PROC-WAIT = if
      op s" could not wait for completion" fail OPERATION
   then
   code throw ;

\ SECRET:STORE!'s three words. A lookup's nonzero exit or signal is a
\ miss, which is no failure: rust CredentialsUnavailable. Output that
\ fills CAP is E-TOO-LARGE, which FETCH logs.
: ITEM-READ ( str str ^VEC:vector<u8> -- bool )
   {: s:str a:str dest :}
   false [: drop s a dest [: LOOKED-UP ;] ARENA:WITH ;]
   catch {: code:n :}
   code 0= if exit then
   drop
   code E-PROC-OUTPUT = if UNREAD then
   code E-PROC-STDOUT-CAPACITY = if E-TOO-LARGE throw then
   code LOADING SECRET:E-UNAVAILABLE CAUGHT ;

\ A store's nonzero exit or signal is STORED's E-ACCESS.
: ITEM-WRITE ( str str str -- )
   {: s:str a:str v:str :}
   [: s a v STORED ;] catch {: code:n :}
   code 0= if exit then
   code E-PROC-OUTPUT = if UNSENT then
   code SECRET:E-ACCESS = if STORING s" failed" code OPERATION then
   code STORING SECRET:E-ACCESS CAUGHT ;

\ AUTH never erases: an operation this store cannot do.
: ITEM-ERASE ( str str -- bool ) drop drop SECRET:E-CONFIG throw ;

public

\ Binds the Secret Service store for the whole process, before any
\ other AUTH word: the CLI's, as the CLI never reads the credential.
: BIND-SECRET-TOOL ( -- )
   [: ITEM-READ ;] [: ITEM-WRITE ;] [: ITEM-ERASE ;] SECRET:STORE! ;

private


\ ---- the credential file: setup's write ------------------------------

\ The record in one new owner-only file, which systemd then passes to
\ the daemon as a credential. Its failures are logged once with the
\ path and their cause, as E-ACCESS.

\ The cause of an FS failure: its errno's text, else the code's.
: FILE-CAUSE$ ( n n -- str )
   {: code:n cause:n :}
   cause 0<> if cause FS:ERRNO$ exit then
   code ERROR:TEXT$ ;

: FILE-FAULT? ( n -- bool )
   {: code:n :}
   code E-FS-OPEN = code E-FS-IO = or code E-FS-PATH = or ;

\ An FS failure of the write to the file at the path, logged with the
\ note after its cause, is E-ACCESS; any other code passes up unlogged.
: FILE-CAUGHT ( n n str str -- )
   {: code:n cause:n p:str note:str :}
   code FILE-FAULT? 0= if code throw then
   LOG-OPEN s" credential operation `" LOG:TEXT+ STORING LOG:TEXT+
   s" ` failed on " LOG:TEXT+ p LOG:TEXT+ s" : " LOG:TEXT+
   code cause FILE-CAUSE$ LOG:TEXT+ note LOG:TEXT+ LOG:;LINE
   SECRET:E-ACCESS throw ;

\ The note for a removal's code: none if the partial file went.
: REMOVAL$ ( n -- str )
   0= if NO-STR exit then
   s" ; the partial file remains" ;

\ A new owner-only file at the path; a failure goes to FILE-CAUGHT.
: CREATED ( str -- fd )
   {: p:str :}
   0 FS:CAUSE!
   -1 >FD
   [: drop p FS:MODE-PRIVATE-FILE FS:CREATE-NEW ;] catch {: code:n :}
   code 0<> if code FS:ERRNO p NO-STR FILE-CAUGHT then ;

\ The value written to the open file, which is closed whatever
\ happens; a failure leaves its cause in FS:ERRNO.
: FILLED ( fd str -- )
   {: f:fd v:str :}
   0 FS:CAUSE!
   [: f v FD:WRITE-FULL ;] catch {: code:n :}
   FS:ERRNO {: cause:n :}
   f FD>N close
   cause FS:CAUSE!
   code 0<> if code throw then ;

\ The record, made first, in a new file at the path; a failure once the
\ file exists removes it, or its log line says the partial file remains.
: FILE-RECORD ( JOURNAL:dropbox-binding str str ^ARENA:arena -- )
   {: b token:str p:str ar :}
   b token ar RECORD {: r:str :}
   p CREATED {: f:fd :}
   [: f r FILLED ;] catch {: code:n :}
   code 0= if exit then
   FS:ERRNO {: cause:n :}
   [: p FS:REMOVE-FILE ;] catch {: kept:n :}
   code cause p kept REMOVAL$ FILE-CAUGHT ;


\ ---- the login -----------------------------------------------------

ARENA PENDINGS pending

32 constant PROOF-BYTES    \ the verifier's random bytes
43 constant PROOF-CHARS    \ 32 bytes in unpadded base64url

: SCOPE ( -- str )
   s" account_info.read files.metadata.read files.content.read files.content.write" ;

\ The URL's texts around its three values, in the SDK's order.
: BASE$ ( -- str )
   s" https://www.dropbox.com/oauth2/authorize?response_type=code&client_id=" ;
: TYPE$ ( -- str ) s" &token_access_type=offline&scope=" ;
: CHALLENGE$ ( -- str ) s" &code_challenge=" ;
: METHOD$ ( -- str ) s" &code_challenge_method=S256" ;

: FIXED ( -- n )
   BASE$ STR:len TYPE$ STR:len + CHALLENGE$ STR:len +
   METHOD$ STR:len + ;

\ Copies the bytes to p; answers the address after them.
: PUT ( ^u8 str -- ^u8 )
   {: p:^ s:str :}
   s str> {: a:^ u:n :}
   a p u BYTE-COPY p u + ;

\ Writes the bytes to p form-encoded, as form_urlencoded does; answers the
\ address after them.
: FORM ( ^u8 str -- ^u8 )
   {: p:^ s:str :}
   s p s URI:FORM-LEN SPAN:MAKE URI:FORM-ENCODE p + ;

\ The SDK's PKCE challenge: the verifier's SHA-256 in unpadded base64url.
: CHALLENGE ( str ^ARENA:arena -- str )
   {: v:str ar :}
   ar SHA256-CTX-BYTES ARENA:ALLOC drop {: ctx:^ :}
   ar 32 ARENA:ALLOC {: d:^ du:n :}
   ctx v d SHA256-IN
   ar PROOF-CHARS ARENA:ALLOC {: c:^ cu:n :}
   d du >str c cu SPAN:MAKE BASE64:ENCODE-URL {: n:n :}
   c n >str ;

\ The authorize URL's parameters, as AuthorizeUrlBuilder appends them
\ for a PKCE code flow with token type ShortLivedAndRefresh and a scope.
: QUERY ( ^u8 str str -- ^u8 )
   {: p:^ k:str c:str :}
   p BASE$ PUT k FORM TYPE$ PUT SCOPE FORM
   CHALLENGE$ PUT c FORM METHOD$ PUT ;

\ The URL for the app key and the verifier; a value at most triples.
: AUTHORIZE-URL ( str str ^ARENA:arena -- str )
   {: k:str v:str ar :}
   v ar CHALLENGE {: c:str :}
   FIXED k STR:len SCOPE STR:len + 3 * + c STR:len + {: cap:n :}
   ar cap ARENA:ALLOC drop {: d:^ :}
   d k c QUERY {: e:^ :}
   d e d - >str ;

\ The u bytes at b, u at most a cell, from one ENTROPY:RANDOM cell.
: CELL-BYTES ( ^u8 n -- )
   {: b:^ u:n :}
   ENTROPY:RANDOM {: r:n :}
   u 0 ?do r i 8 * rshift $FF and b i + c! loop ;

: RANDOM ( ^u8 n -- )
   {: b:^ u:n :}
   [: u 0 ?do b i + u i - CELL min CELL-BYTES CELL +loop ;] catch
   {: code:n :}
   code ENTROPY:E-FILL = if E-RANDOM FAIL then
   code 0<> if code throw then ;

\ rust random_urlsafe: 32 random bytes in unpadded base64url.
: PROOF ( ^ARENA:arena -- str )
   {: ar :}
   ar PROOF-BYTES ARENA:ALLOC {: b:^ bu:n :}
   b bu RANDOM
   ar PROOF-CHARS ARENA:ALLOC {: v:^ vu:n :}
   b bu >str v vu SPAN:MAKE BASE64:ENCODE-URL {: n:n :}
   v n >str ;

\ The store a rejected directory binds: a read is unavailable, so LOAD
\ answers unavailable, and a write or an erase is refused.
: REFUSED-READ ( str str ^VEC:vector<u8> -- bool )
   drop drop drop SECRET:E-UNAVAILABLE throw ;

: REFUSED-WRITE ( str str str -- ) drop drop drop SECRET:E-ACCESS throw ;

: REFUSED-ERASE ( str str -- bool ) drop drop SECRET:E-ACCESS throw ;

: BIND-REFUSING ( -- )
   [: REFUSED-READ ;] [: REFUSED-WRITE ;] [: REFUSED-ERASE ;] SECRET:STORE! ;

\ BIND for the directory's path: its store; unset or empty, the Secret
\ Service; a directory SECRET rejects (logged), the refusing store.
: BIND-FOR ( str -- )
   {: dir:str :}
   dir STR:DATA NULL-PTR = dir STR:LEN 0= or if
      BIND-SECRET-TOOL exit
   then
   [: dir SERVICE SECRET:DIR-BIND ;] catch {: code:n :}
   code 0= if exit then
   code SECRET:E-CONFIG <> if code throw then
   BIND-REFUSING ;

public

\ Binds the credential store for the whole process from
\ CREDENTIALS_DIRECTORY, once, at the daemon's entry before any AUTH word.
: BIND ( -- ) s" CREDENTIALS_DIRECTORY" GETENV BIND-FOR ;

\ Stores the binding and the refresh token, replacing the item's value.
: STORE ( JOURNAL:dropbox-binding str -- )
   [: WRITE-RECORD ;] ARENA:WITH ;

\ Writes the binding and the refresh token to a new owner-only file at
\ the path, whatever store is bound; an FS failure is SECRET:E-ACCESS.
: WRITE-FILE ( JOURNAL:dropbox-binding str str -- )
   [: FILE-RECORD ;] ARENA:WITH ;

\ The binding and the refresh token, copied into the arena.
: LOAD ( ^ARENA:arena -- lookup )
   {: ar :}
   ar ARENA:ALLOCATOR 0 [type] u8 VEC:NEW {: dest :}
   dest FETCH 0= if construct lookup unavailable exit then
   dest VEC:SPAN SPAN:$ ar CREDENTIAL ;


\ A login for the app key with a fresh verifier, in the arena.
: START ( str ^ARENA:arena -- ^pending )
   {: k:str ar :}
   ar PROOF {: v:str :}
   ar PENDINGS-NEW {: p :}
   v p PENDING-VERIFIER !
   k v ar AUTHORIZE-URL p PENDING-URL !
   p ;

\ The URL the user opens to authorize Omabox.
: URL ( ^pending -- str ) PENDING-URL @ ;

\ The verifier DROPBOX:EXCHANGE sends with the code.
: VERIFIER ( ^pending -- str ) PENDING-VERIFIER @ ;

;package
