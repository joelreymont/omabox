\ auth.f - package AUTH: the Dropbox credential in the Secret Service
\ (rust src/auth.rs RefreshTokenStore), through SECRET. The item is the
\ one whose attributes application and kind hold org.omarchy.omabox and
\ dropbox-credentials-v1, as `secret-tool` stores and looks it up, so
\ either version reads what the other stored. Its value is serde_json's
\ compact record of the version, 1, the refresh token and the Dropbox
\ binding, under 8192 bytes. LOAD reads it as serde reads Rust's
\ LoadedSecret: members in any order, an unknown one skipped, one absent,
\ repeated or of another type refused. It refuses two records serde reads
\ and no writer makes: one written as an array, and one whose skipped
\ member holds a lone surrogate escape. AUTH's failures are logged once
\ with the Rust version's text, then thrown as its codes; no log line
\ holds a string of the record, only an unsupported version's number.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: the strings LOAD
\ answers, and the record it read, lie in the arena the caller passes.
HB-TARGET-LINUX? HB-TARGET-LINUX-X86-64? or ?TARGET
require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/utf8-scalar.f
require src/lib/json.f
require src/lib/secret.f
require src/journal.f

package AUTH
public

-100600 constant E-FIRST
-100699 constant E-LAST
-100600
   s" Secret Service returned an invalid Omabox Dropbox credential record"
   ERROR:CODE E-JSON
-100601
   s" Secret Service returned an invalid Omabox Dropbox credential encoding"
   ERROR:CODE E-UTF8
-100602 s" Omabox Dropbox credential record exceeds the supported size"
   ERROR:CODE E-TOO-LARGE
-100603 s" Secret Service returned unsupported Omabox credential version"
   ERROR:CODE E-VERSION

\ found: the binding and the refresh token; unavailable: no item, or a
\ Secret Service that refused or did not answer.
ENUM lookup
   VARIANT found
      FIELD binding JOURNAL:dropbox-binding
      FIELD refresh-token str
   ;VARIANT
   VARIANT unavailable ;VARIANT
;ENUM

private

8192 constant CAP          \ a record's bytes, exclusive
1 constant VERSION

: SERVICE ( -- ^u8 n ) s" org.omarchy.omabox" ;
: ACCOUNT ( -- ^u8 n ) s" dropbox-credentials-v1" ;


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
: REFUSED ( ^u8 n -- )
   {: what:^ wu:n :}
   LOG-OPEN E-JSON ERROR:TEXT$ LOG:TEXT+
   s" : credential JSON " LOG:TEXT+ what wu LOG:TEXT+
   s"  error" LOG:TEXT+ LOG:;LINE
   E-JSON throw ;

: WRONG-VERSION ( n -- )
   {: found:n :}
   LOG-OPEN E-VERSION ERROR:TEXT$ LOG:TEXT+
   s"  " LOG:TEXT+ found LOG:INT+ LOG:;LINE
   E-VERSION throw ;


\ ---- the record written --------------------------------------------

ARENA WRITERS JSON:writer

: STRING+ ( ^JSON:writer ^u8 n str -- ^JSON:writer )
   {: k:^ ku:n v:str :}
   k ku v str> JSON:WRITE-FIELD-S ;

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

\ The record in a CAP-byte buffer, which a longer one does not fit; a
\ string that is not UTF-8 is a record serde could not write.
: RECORD ( JOURNAL:dropbox-binding str ^ARENA:arena -- ^u8 n )
   {: b token:str ar :}
   ar WRITERS-NEW {: w :}
   w ar CAP ARENA:ALLOC JSON:WRITE-OPEN drop
   [: b token w FIELDS ;] catch {: code:n :}
   code E-JSON-WRITE-CAPACITY = if E-TOO-LARGE FAIL then
   code E-JSON-WRITE-BYTE = if s" data" REFUSED then
   code 0<> if code throw then
   w JSON:WRITTEN$ {: r:^ ru:n :}
   w JSON:WRITE-CLOSE
   ru CAP >= if E-TOO-LARGE FAIL then
   r ru ;

: WRITE-RECORD ( JOURNAL:dropbox-binding str ^ARENA:arena -- )
   RECORD {: r:^ ru:n :}
   SERVICE ACCOUNT r ru SECRET:WRITE ;


\ ---- the record read -----------------------------------------------

\ Each member is found by JSON:READ-MEMBER$ searching the record's text
\ for its key, with the one cursor, which owns nothing after a read.

ARENA CURSORS JSON:cursor

: EXPECT ( n n -- ) <> if E-JSON throw then ;

\ A reader on text, and its first token.
: OPEN ( ^u8 n ^JSON:cursor -- JSON:reader n )
   {: t:^ u:n c :}
   c t u JSON:READ-INIT JSON:READ-NEXT ;

\ A string's decoded bytes, copied into the arena; its text bounds them.
: READ-STRING ( ^u8 n ^JSON:cursor ^ARENA:arena -- str )
   {: t:^ u:n c ar :}
   t u c OPEN JSON:T-STR EXPECT
   ar u ARENA:ALLOC {: d:^ du:n :}
   d du JSON:READ-STR {: len:n :}
   JSON:READ-FINISH d len >str ;

\ serde's u8: an integer with no sign, up to 255.
: READ-VERSION ( ^u8 n ^JSON:cursor -- n )
   {: t:^ u:n c :}
   t u c OPEN JSON:T-INT EXPECT
   JSON:READ-ANY-SPAN$ {: a:^ au:n :}
   a c@ [char] - = au 3 > or if E-JSON throw then
   JSON:READ-INT {: v:n :}
   JSON:READ-FINISH
   v 255 > if E-JSON throw then
   v ;

: STRING-AT ( ^u8 n ^u8 n ^JSON:cursor ^ARENA:arena -- str )
   {: c ar :} c JSON:READ-MEMBER$ c ar READ-STRING ;

\ LoadedSecret: the version, the binding and the refresh token.
: READ-RECORD
   ( ^u8 n ^JSON:cursor ^ARENA:arena -- n JOURNAL:dropbox-binding str )
   {: t:^ u:n c ar :}
   t u s" version" c JSON:READ-MEMBER$ c READ-VERSION
   t u s" account_id" c ar STRING-AT
   t u s" root_namespace_id" c ar STRING-AT
   t u s" remote_root" c ar STRING-AT
   JOURNAL-DROPBOX--BINDING:MAKE
   t u s" refresh_token" c ar STRING-AT ;

\ The category a refusal is logged with: E-JSON-READ-EOF the text's end,
\ another reader code its syntax; E-JSON its data, and JSON:E-MEMBER, a
\ member missing or repeated or a text no object, which serde calls data.
: CATEGORY ( n -- ^u8 n )
   {: code:n :}
   code E-JSON = code JSON:E-MEMBER = or if s" data" exit then
   code E-JSON-READ-EOF = if s" end-of-input" exit then
   s" syntax" ;

: REFUSAL? ( n -- bool )
   {: code:n :}
   code E-JSON-READ-LAST >= code E-JSON-READ-FIRST <= and
   code E-JSON = or ;

: NO-STR ( -- str ) s" " >str ;

: NO-BINDING ( -- JOURNAL:dropbox-binding )
   NO-STR NO-STR NO-STR JOURNAL-DROPBOX--BINDING:MAKE ;

\ A seed's typed drop, which types the read that replaces it.
: DROP-SEED ( n JOURNAL:dropbox-binding str -- ) drop drop drop ;

\ READ-RECORD, replacing the seed it is given, as catch keeps the
\ stack's shape; a refusal leaves the cursor owning nothing.
: DECODE ( ^u8 n ^ARENA:arena -- n JOURNAL:dropbox-binding str )
   {: t:^ u:n ar :}
   ar CURSORS-NEW {: c :}
   0 NO-BINDING NO-STR [: DROP-SEED t u c ar READ-RECORD ;] catch
   {: code:n :}
   code 0= if exit then
   c JSON:READ-DISPOSE
   code REFUSAL? if code CATEGORY REFUSED then
   code throw ;

\ Rust's checks of the item's value, in Rust's order: its size, its
\ encoding, its form, then its version.
: CREDENTIAL ( ^u8 n ^ARENA:arena -- lookup )
   {: t:^ u:n ar :}
   u CAP >= if E-TOO-LARGE FAIL then
   t u UTF8:VALID? 0= if E-UTF8 FAIL then
   t u ar DECODE {: version:n b token:str :}
   version VERSION <> if version WRONG-VERSION then
   b token construct lookup found ;

\ The answers secret-tool's nonzero exit gives: a locked or refused
\ keyring, and a Secret Service that did not answer.
: UNAVAILABLE? ( n -- bool )
   {: code:n :}
   code SECRET:E-ACCESS = code SECRET:E-UNAVAILABLE = or ;

\ The item's length in dest, and whether it was found.
: FETCH ( SPAN:span<u8> -- n bool )
   {: dest :}
   0 false [: drop drop SERVICE ACCOUNT dest SECRET:READ ;] catch
   {: code:n :}
   code 0= if exit then
   drop drop
   code UNAVAILABLE? if 0 false exit then
   code SECRET:E-CAPACITY = if E-TOO-LARGE FAIL then
   code throw ;

public

\ Names the item's attributes and label as `secret-tool store` wrote
\ them, for the whole process: the daemon calls it once, before any
\ other AUTH word.
: BIND ( -- )
   s" application" s" kind" s" Omabox Dropbox credentials"
   SECRET:LINUX-ITEM! ;

\ Stores the binding and the refresh token, replacing the item's value.
: STORE ( JOURNAL:dropbox-binding str -- )
   [: WRITE-RECORD ;] ARENA:WITH ;

\ The binding and the refresh token, copied into the arena.
: LOAD ( ^ARENA:arena -- lookup )
   {: ar :}
   ar CAP ARENA:ALLOC SPAN:MAKE {: dest :}
   dest FETCH {: u:n found:bool :}
   found 0= if construct lookup unavailable exit then
   dest SPAN:$ drop u ar CREDENTIAL ;

;package
