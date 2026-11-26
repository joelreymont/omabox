\ dropbox.f - package DROPBOX: the Dropbox API v2 routes omabox calls, over
\ HTTPC and json.f (docs/habu-dropbox.md).
\ A client holds three HTTPC connections, one per origin (api, content,
\ notify), each dialed at its first request and kept between calls while
\ each answer allows, until REST closes api and content. Every request is a
\ POST with `User-Agent: omabox/<version>` and its call shape's deadlines.
\ A call reads its answer whole into a growing buffer, a download's body
\ through READ-BODY; an answer's head stays on its connection until that
\ connection's next request. No proxy is used: the proxy variables are
\ ignored. A call is a POST to <api>/2/<route>; a client with no access
\ token refreshes first, and any 401 refreshes and resends the call once,
\ which answers unlinked if refused again. Unlinked is logged once, where
\ it is decided, and a confirmation that answers unlinked answers it in its
\ call's place. A refresh that rotates the refresh token hands it to the
\ config's store before the new access token is used (the token's phase,
\ below). The long poll is a POST to <notify>/2/files/list_folder/longpoll
\ with neither token nor root.
\ An answer is classified once: 200 done, 403 unlinked, 409 refused by its
\ error tag, 422 refused invalid-root, 429, 408 and 5xx retry, a timeout or
\ lost connection retry 0; anything else logs one line (route, status, at
\ most EXCERPT bytes of the body, never a token) and throws a DROPBOX code,
\ a bug on one side of the wire. An answer that does not parse logs one
\ line too and throws E-ANSWER, and one that parses but cannot be used
\ E-UNUSABLE, but a 200 to upload, finish, delete or create-folder answers
\ refused unverified. A mutation lost, or answered 408 or 5xx with no wait,
\ may have been applied, so it answers refused unverified; a wait Dropbox
\ asks for stays retry. E-NOT-STORED is environmental instead: the store
\ failed, and the next call retries it.
\ A 409's error is a Dropbox union: its leaf tag is the `.tag` of the member
\ named by the outer `.tag`, or of `reason` in an upload's error, when that
\ member is an object, else the outer `.tag` itself, so path/not_found reads
\ not_found.
\ STORAGE CLASS. CALLER-OWNED: OPEN lays the client and its copies of the
\ config in the caller's arena; the client owns its connections and buffers
\ until CLOSE. Every span or entry it answers is borrowed until its next
\ call. One task uses a client at a time. A program runs its DROPBOX calls
\ inside WITH-LOOP, which runs AIO's loop that uploads' AIO:READ needs.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/byte-buffer.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/arena.f
require src/lib/json.f
require src/lib/fmt.f
require src/lib/log.f
require src/lib/net/httpc.f
require src/lib/memory.f
require src/lib/aio.f
require src/lib/fsm.f
require src/lib/adt/option.f
require src/lib/unicode.f
require src/lib/date.f
require src/lib/uri.f
require src/lib/type/deftype.f
require src/version.f

package DROPBOX
public

-100000 constant E-FIRST
-100099 constant E-LAST
-100000 s" Dropbox answered a redirect, which is never followed"
   ERROR:CODE E-REDIRECT
-100001 s" Dropbox refused a request as malformed" ERROR:CODE E-BAD-REQUEST
-100002 s" Dropbox answered a status no route expects" ERROR:CODE E-STATUS
-100003 s" Dropbox's answer did not parse" ERROR:CODE E-ANSWER
-100004 s" Dropbox refused the access token" ERROR:CODE E-AUTH
-100005 s" the transfer to Dropbox failed" ERROR:CODE E-TRANSPORT
-100007 s" the rotated Dropbox refresh token could not be stored"
   ERROR:CODE E-NOT-STORED
-100010 s" Dropbox's answer cannot be used" ERROR:CODE E-UNUSABLE

\ Dropbox's 409 tags omabox decides on, else other; no tag: path-mismatch, an
\ entry elsewhere, and unverified, an answer omabox cannot trust.
ENUM error DERIVE eq
   not-found not-file not-folder malformed-path disallowed-name
   conflict no-write-permission restricted-content
   access-restricted team-folder operation-suppressed
   insufficient-space locked reset invalid-root
   content-hash-mismatch unsupported-file path-mismatch unverified
   other ;ENUM

\ What a call answers: done, the client holds the answer; refused, Dropbox
\ said no and why; retry, the ms Dropbox asked to wait, else 0; unlinked,
\ Dropbox refuses this app until the user acts: the refresh token is dead,
\ a refreshed token was refused too, or Dropbox answered 403.
ENUM reply
   VARIANT done ;VARIANT
   VARIANT refused FIELD why error ;VARIANT
   VARIANT retry FIELD ms n ;VARIANT
   VARIANT unlinked ;VARIANT
;ENUM

\ What PROBE found in a folder; interrupted, a continue page whose cursor
\ did not advance, settles nothing.
ENUM probe empty occupied interrupted ;ENUM

ENUM kind DERIVE eq file folder deleted ;ENUM

\ Dropbox's content hash of a file's bytes.
DEFTYPE HASH str
\ A file's revision, which a conditional write names.
DEFTYPE REV str
\ A listing's cursor, which list_folder/continue resumes from.
DEFTYPE CURSOR str

: HASH= ( hash hash -- bool )
   {: a:hash b:hash :}
   a HASH>STR b HASH>STR STR:= ;

\ rev, content-hash, size and downloadable are a file's alone: empty, 0 and
\ true for any other kind; lower and display are path_lower and path_display.
\ restricted: a folder whose sharing_info has no_access or traverse_only.
STRUCTURE entry DERIVE addr
   FIELD kind kind
   FIELD lower SPAN:span<u8>
   FIELD display SPAN:span<u8>
   FIELD rev SPAN:span<u8>
   FIELD content-hash SPAN:span<u8>
   FIELD size n
   FIELD downloadable bool
   FIELD restricted bool
;STRUCTURE

\ What OPEN copies: key is the app key, Dropbox's client_id; token the
\ refresh token; store keeps a rotated refresh token where token came
\ from, throws when it cannot and must not use the client; root the root
\ namespace, empty for the account's home; api, content and notify the
\ origins, which tests point at a fake.
STRUCTURE config DERIVE addr
   FIELD key SPAN:span<u8>
   FIELD token SPAN:span<u8>
   FIELD store [ str -- ]
   FIELD root SPAN:span<u8>
   FIELD api SPAN:span<u8>
   FIELD content SPAN:span<u8>
   FIELD notify SPAN:span<u8>
;STRUCTURE

private

\ The refresh token's phase. pending: the client holds a rotated refresh
\ token the store refused; rejected: Dropbox refuses the client until the
\ user logs in again.
ENUM phase ready pending rejected ;ENUM

public

\ token, access and answer are BUF headers in the arena, body and line
\ heap vectors: token holds the refresh token, access the access token,
\ body a route's JSON body, line a target or header line being built,
\ answer the body received. values, a heap vector, holds the strings
\ decoded from it. holds names what answer holds, for the log: body, or
\ result once a download's Dropbox-API-Result replaced it. root-line is
\ the Path-Root header line, empty for none.
\ route names the request for the log; quiet marks the token route, whose
\ body is never logged. api-conn, content-conn and notify-conn are the
\ origins' connections, conn the connection of the last request PREPARE
\ started, whose head HEADER$ reads, and out the body SEND writes. status
\ is the answer's HTTP status, 0 when none arrived; failure the fault of
\ the read that failed, none until one does. outer, leaf-name and leaf are
\ an error body's tags; wait its retry_after in seconds, -1 for none;
\ correct its correct_offset, -1 for none; issued a token answer's
\ access_token and granted its refresh_token. sent holds a listing's
\ cursor, the one sent and then its page's, and mark the cursor of the
\ last listing that answered done; page is a page's cursor, more its
\ has_more, got the members an answer must hold, one bit each; changes and
\ backoff are a long poll's answer. tagged marks the `.tag` of the union
\ being read: a Metadata entry or an account's root_info, whose tag is
\ root-tag. store and phase are the config's store and the refresh token's
\ phase.
STRUCTURE client OPAQUE DERIVE addr
   FIELD api-conn HTTPC:conn
   FIELD content-conn HTTPC:conn
   FIELD notify-conn HTTPC:conn
   FIELD conn ^HTTPC:conn
   FIELD out SPAN:span<u8>
   FIELD key SPAN:span<u8>
   FIELD token ^n
   FIELD store [ str -- ]
   FIELD phase phase
   FIELD api SPAN:span<u8>
   FIELD content SPAN:span<u8>
   FIELD notify SPAN:span<u8>
   FIELD root-line SPAN:span<u8>
   FIELD access ^n
   FIELD body ^VEC:vector<u8>
   FIELD line ^VEC:vector<u8>
   FIELD answer ^n
   FIELD holds SPAN:span<u8>
   FIELD values ^VEC:vector<u8>
   FIELD writer JSON:writer
   FIELD cursor JSON:cursor
   FIELD route SPAN:span<u8>
   FIELD quiet bool
   FIELD status n
   FIELD failure option<HTTPC:fault>
   FIELD outer SPAN:span<u8>
   FIELD leaf-name SPAN:span<u8>
   FIELD leaf SPAN:span<u8>
   FIELD wait n
   FIELD correct n
   FIELD issued SPAN:span<u8>
   FIELD granted SPAN:span<u8>
   FIELD account SPAN:span<u8>
   FIELD namespace SPAN:span<u8>
   FIELD root-tag SPAN:span<u8>
   FIELD entry entry
   FIELD sent ^n
   FIELD mark ^n
   FIELD page SPAN:span<u8>
   FIELD more bool
   FIELD got n
   FIELD changes bool
   FIELD backoff n
   FIELD tagged bool
;STRUCTURE

private

ARENA CLIENTS client

\ transport.rs JSON_REQUEST_SECONDS: one whole-call deadline.
60000 constant DEADLINE
\ The least free room the answer buffer offers each read.
$4000 constant CHUNK
256 constant FIRST-CAP
200 constant EXCERPT

ENUM verdict
   VARIANT answer FIELD r reply ;VARIANT
   VARIANT rejected ;VARIANT
;ENUM

: EMPTY ( -- SPAN:span<u8> ) s" " str> SPAN:MAKE ;
: BLEN ( ^n -- n ) BUF:LEN@ BUF:BLEN>N ;
: BUF$ ( ^n -- str ) BUF:SPAN$ BUF:BLEN>N >str ;
: APPEND ( str ^n -- )
   {: s buf :} s str> BUF:N>BLEN buf BUF:APPEND-SPAN ;
: BYTES$ ( ^VEC:vector<u8> -- str ) VEC:SPAN SPAN:$ ;
: BYTES+ ( str ^VEC:vector<u8> -- )
   VEC:APPEND ;
: PUSH ( n ^VEC:vector<u8> -- ) VEC:PUSH c! ;
: ANSWER$ ( ^client -- str ) CLIENT-ANSWER @ BUF$ ;
: TAG$ ( ^client -- str ) CLIENT-OUTER @ SPAN:$ ;


\ ---- logging and the codes it precedes

: LOG-OPEN ( -- ) LOG:ERROR s" dropbox" LOG:LINE ;


: EXCERPT$ ( ^client -- str )
   ANSWER$ str> EXCERPT min >str ;


\ One line: the route, the status, why, and the answer buffer's start,
\ labelled by what it holds, unless the route is quiet.
: REPORT ( ^client str -- )
   {: c why :}
   LOG-OPEN
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+
   s"  answered " LOG:TEXT+ c CLIENT-STATUS @ LOG:INT+
   s" : " LOG:TEXT+ why LOG:TEXT+
   c CLIENT-QUIET @ 0= if
      s" ; " LOG:TEXT+ c CLIENT-HOLDS @ SPAN:$ LOG:TEXT+
      s" : " LOG:TEXT+ c EXCERPT$ LOG:TEXT+
   then
   LOG:;LINE ;


: FAILED ( ^client str n -- )
   {: c why code:n :}
   c why REPORT
   code throw ;


\ One line, the route, the fault and its cause on the request's connection,
\ then E-TRANSPORT.
: HTTP-FAILED ( ^client HTTPC:fault -- )
   {: c f:HTTPC:fault :}
   LOG-OPEN
   s" http " LOG:TEXT+ c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+
   s" : " LOG:TEXT+ f HTTPC:FAULT$ LOG:TEXT+
   s"  cause=" LOG:TEXT+ c CLIENT-CONN @ HTTPC:CAUSE LOG:INT+
   LOG:;LINE
   E-TRANSPORT throw ;


\ ---- the loop

public

\ The step under AIO's loop, which uploads' AIO:READ needs.
: WITH-LOOP ( [ -- ] -- )
   {: step :}
   AIO:START step [: AIO:STOP ;] finally ;

private


\ ---- opening

: KEEP ( str ^ARENA:arena -- SPAN:span<u8> )
   {: s ar :}
   s STR:len {: u:n :}
   u 0= if EMPTY exit then
   ar u ARENA:ALLOC {: dst:^ du:n :}
   s STR:data dst u BYTE-COPY
   dst u SPAN:MAKE ;


: KEPT ( ^config ^ARENA:arena [ ^config -- ^SPAN:span<u8> ] -- SPAN:span<u8> )
   {: cfg ar field :}
   cfg field execute @ SPAN:$ ar KEEP ;


: BUFFER ( ^ARENA:arena -- ^n )
   BUF:HDR-BYTES ARENA:ALLOC drop CELL-VIEW
   dup FIRST-CAP BUF:N>BLEN BUF:INIT ;


\ The allocator the client's vectors take; a test counts with it.
TYPED-VARIABLE VEC-ALLOC ^ALLOC:allocator
HEAP:ALLOCATOR VEC-ALLOC !


\ On VEC-ALLOC; CLOSE deletes it.
: VECTOR ( -- ^VEC:vector<u8> )
   VEC-ALLOC @ 0 [type] u8 VEC:NEW ;


\ Each connection's room, for a request's head and then its answer's.
65536 constant HEAD-ROOM
: TRUST ( -- str ) s" /etc/ssl/certs/ca-certificates.crt" ;


\ Opens h on the origin o with a room from the arena; an origin HTTPC
\ cannot read logs one line and throws E-TRANSPORT.
: ORIGIN-CONN ( ^HTTPC:conn SPAN:span<u8> ^ARENA:arena -- )
   {: h o:SPAN:span<u8> ar :}
   h o SPAN:$ TRUST ar HEAD-ROOM ARENA:ALLOC HTTPC:OPEN if exit then
   LOG-OPEN s" http " LOG:TEXT+ o SPAN:$ LOG:TEXT+
   s" : not an origin" LOG:TEXT+ LOG:;LINE
   E-TRANSPORT throw ;


\ The Path-Root line, written once through the line buffer; Dropbox
\ requires DEL and non-ASCII escaped in a header.
: ROOT-LINE ( ^client str ^ARENA:arena -- SPAN:span<u8> )
   {: c r ar :}
   r STR:len 0= if EMPTY exit then
   c CLIENT-LINE @ {: line :}
   c CLIENT-WRITER line JSON:OPEN
   true JSON:WRITE-ASCII!
   JSON:WRITE-OBJECT-START
   s" .tag" s" root" JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" root" r JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:CLOSE
   line BYTES$ str> {: j:^ ju:n :}
   s" Dropbox-API-Path-Root: " str> {: p:^ pu:n :}
   pu ju + {: u:n :}
   ar u ARENA:ALLOC {: dst:^ du:n :}
   p dst pu BYTE-COPY
   j dst pu + ju BYTE-COPY
   dst u SPAN:MAKE ;


: CONFIGURED ( ^client ^config ^ARENA:arena -- )
   {: c cfg ar :}
   cfg ar [: DROPBOX-CONFIG:KEY ;] KEPT c CLIENT-KEY !
   cfg DROPBOX-CONFIG:TOKEN @ SPAN:$ str> BUF:N>BLEN
   c CLIENT-TOKEN @ BUF:REPLACE
   cfg DROPBOX-CONFIG:STORE @ c CLIENT-STORE !
   construct phase ready c CLIENT-PHASE !
   cfg ar [: DROPBOX-CONFIG:API ;] KEPT c CLIENT-API !
   cfg ar [: DROPBOX-CONFIG:CONTENT ;] KEPT c CLIENT-CONTENT !
   cfg ar [: DROPBOX-CONFIG:NOTIFY ;] KEPT c CLIENT-NOTIFY ! ;


\ The three connections, on the origins CONFIGURED kept.
: ORIGIN-CONNS ( ^client ^ARENA:arena -- )
   {: c ar :}
   c CLIENT-API-CONN c CLIENT-API @ ar ORIGIN-CONN
   c CLIENT-CONTENT-CONN c CLIENT-CONTENT @ ar ORIGIN-CONN
   c CLIENT-NOTIFY-CONN c CLIENT-NOTIFY @ ar ORIGIN-CONN ;


: BUFFERED ( ^client ^ARENA:arena -- )
   {: c ar :}
   ar BUFFER c CLIENT-TOKEN !
   ar BUFFER c CLIENT-ACCESS !
   VECTOR c CLIENT-BODY !
   VECTOR c CLIENT-LINE !
   ar BUFFER c CLIENT-ANSWER !
   s" body" str> SPAN:MAKE c CLIENT-HOLDS !
   VEC-ALLOC @ 0 [type] u8 VEC:NEW c CLIENT-VALUES !
   ar BUFFER c CLIENT-SENT !
   ar BUFFER c CLIENT-MARK ! ;


\ ---- one request

: LINE-CLEAR ( ^client -- ) CLIENT-LINE @ 0 VEC:RESIZE ;
: LINE+ ( ^client str -- ) {: c s :} s c CLIENT-LINE @ BYTES+ ;
: LINE$ ( ^client -- str ) CLIENT-LINE @ BYTES$ ;


\ Starts on h, the request's connection from now, a POST to the target the
\ line holds, under the whole-call deadline, with the User-Agent line.
: PREPARE ( ^client ^HTTPC:conn -- ^HTTPC:conn )
   {: c h :}
   h c CLIENT-CONN !
   h s" POST" c LINE$ HTTPC:REQUEST
   h DEADLINE 0 HTTPC:DEADLINES!
   c LINE-CLEAR c s" User-Agent: omabox/" LINE+ c RELEASE:VERSION$ LINE+
   h c LINE$ HTTPC:HEADER+
   h ;


: AUTHORIZE ( ^HTTPC:conn ^client -- )
   {: h c :}
   c LINE-CLEAR
   c s" Authorization: Bearer " LINE+
   c c CLIENT-ACCESS @ BUF$ LINE+
   h c LINE$ HTTPC:HEADER+
   c CLIENT-ROOT-LINE @ SPAN:$ {: r :}
   r STR:len 0= if exit then
   h r HTTPC:HEADER+ ;


\ Free room past the answer's end, at least CHUNK bytes.
: ROOM ( ^n -- ^u8 len )
   {: buf :}
   buf buf BLEN CHUNK + BUF:N>BLEN BUF:ENSURE
   buf BUF:SPAN$ BUF:BLEN>N +
   buf BUF:CAP@ BUF:BLEN>N buf BLEN - >LEN ;


: ADVANCE ( n ^n -- )
   {: got:n buf :}
   buf BLEN got + BUF:N>BLEN buf BUF:LEN! ;


\ HTTPC:NEXT, or with some descriptor HTTPC:NEXT-UNLESS on it.
: NEXT-READ ( option<fd> ^HTTPC:conn ^u8 len -- HTTPC:chunk-result )
   {: w:option<fd> h a:^ u:len :}
   w MATCH option
      none OF h a u HTTPC:NEXT ENDOF
      some OF {: f:fd :} h a u f HTTPC:NEXT-UNLESS ENDOF
   ;MATCH ;


\ One read; true once the transfer ended, its status or failure kept.
: STEP ( option<fd> ^HTTPC:conn ^client -- bool )
   {: w:option<fd> h c :}
   c CLIENT-ANSWER @ {: buf :}
   w h buf ROOM NEXT-READ MATCH HTTPC:chunk-result
      chunk OF LEN>N buf ADVANCE drop false ENDOF
      response OF c CLIENT-STATUS ! true ENDOF
      failed OF OPTION:SOME c CLIENT-FAILURE ! true ENDOF
   ;MATCH ;


\ Sends the prepared request and its body, nothing received yet.
: STARTED ( ^client -- ^HTTPC:conn )
   {: c :}
   0 c CLIENT-STATUS ! OPTION:NONE c CLIENT-FAILURE !
   EMPTY c CLIENT-OUTER ! EMPTY c CLIENT-LEAF-NAME ! EMPTY c CLIENT-LEAF !
   c CLIENT-ANSWER @ BUF:CLEAR
   s" body" str> SPAN:MAKE c CLIENT-HOLDS !
   c CLIENT-CONN @ {: h :}
   h c CLIENT-OUT @ SPAN:$ HTTPC:SEND
   h ;


\ The one place a throw ends h's transfer: it is closed unless ended
\ answers that a read of reads ended it; the code is rethrown.
: READ-OUT ( ^HTTPC:conn [ -- ] [ -- bool ] -- )
   {: h reads ended :}
   [: reads execute ;] catch {: code:n :}
   code 0= if exit then
   ended execute 0= if h HTTPC:CLOSE then
   code throw ;


\ Sends the prepared request and reads its answer whole, every read through
\ NEXT-READ with w. Nothing after the read that ended the transfer throws,
\ so a throw finds it in flight.
: TRANSFER ( option<fd> ^client -- )
   {: w:option<fd> c :}
   c STARTED {: h :}
   h [: begin w h c STEP until ;] [: false ;] READ-OUT ;


\ ---- reading headers

: LINE-END ( str n -- n )
   {: s at:n :}
   s str> {: a:^ u:n :}
   at begin dup u < while
      a over + c@ 10 = if exit then
      1+
   repeat ;


\ The line at `at`, and where the next one starts.
: LINE ( str n -- str n )
   {: s at:n :}
   s at LINE-END {: lf:n :}
   s STR:data at + lf at - >str lf 1+ ;


: NAMES? ( str str -- bool )
   {: s nm :}
   s str> {: a:^ u:n :}
   nm STR:len {: nu:n :}
   u nu > 0= if false exit then
   a nu + c@ 58 <> if false exit then
   a nu >str nm STR:=CI ;


\ The trimmed value of the header name in the answer's head, else empty.
: HEADER$ ( ^client str -- str )
   {: c nm :}
   nm STR:len {: nu:n :}
   c CLIENT-CONN @ HTTPC:HEAD$ {: head :}
   head STR:len {: u:n :}
   0 begin dup u < while
      head swap LINE >r
      dup nm NAMES? if
         r> drop str> swap nu 1+ + swap nu 1+ - >str STR:TRIM exit
      then
      drop r>
   repeat drop head STR:data 0 >str ;


\ The longest wait in seconds, 15 minutes.
900 constant WAIT-CAP
\ Delta-seconds are decimal.
10 constant RADIX


\ Delta-seconds: digits only, any number of them, at most WAIT-CAP.
: DELTA-SECONDS ( str -- option<n> )
   {: s :}
   s str> {: a:^ u:n :}
   s STR:DIGITS? 0= if OPTION:NONE exit then
   0 0 begin dup u < while
      swap RADIX * over a + c@ STR:DIGIT-VALUE +
      WAIT-CAP min swap 1+
   repeat drop OPTION:SOME ;


\ Retry-After in seconds: delta-seconds, else an HTTP date less now and at
\ least 0 (a passed date asks for no wait); 0 false when absent or neither.
: RETRY-AFTER ( ^client -- n bool )
   s" Retry-After" HEADER$ epoch-seconds {: a now:n :}
   a DELTA-SECONDS MATCH option
      some OF true ENDOF
      none OF a now DATE:PARSE-HTTP MATCH option
         none OF 0 false ENDOF
         some OF now - 0 max true ENDOF
      ;MATCH ENDOF
   ;MATCH ;


\ ---- reading answers

: VALUE ( JSON:reader -- JSON:reader n ) JSON:READ-NEXT ;
: SKIP ( JSON:reader -- JSON:reader ) JSON:READ-NEXT drop JSON:READ-SKIP-VALUE ;


: OBJECT ( JSON:reader n -- JSON:reader )
   JSON:T-OBJ <> if E-ANSWER throw then ;


\ The current string or key decoded into values. READ-ANSWER reserves values
\ for the whole answer first, so a span taken here never moves.
: DECODE ( JSON:reader ^client -- JSON:reader SPAN:span<u8> )
   {: c :}
   JSON:READ-TOKEN dup JSON:T-STR = swap JSON:T-KEY = or
   0= if E-ANSWER throw then
   c CLIENT-VALUES @ {: v:^ :}
   v VEC:COUNT {: at:n :}
   v JSON:READ-STR-APPEND
   v VEC:SPAN at SPAN:SKIP ;


: STRING ( JSON:reader ^client -- JSON:reader SPAN:span<u8> )
   {: c :}
   VALUE drop c DECODE ;


: INT ( JSON:reader -- JSON:reader n )
   VALUE JSON:T-INT <> if E-ANSWER throw then
   JSON:READ-INT ;


: BOOLEAN ( JSON:reader -- JSON:reader bool )
   VALUE dup JSON:T-TRUE = if drop true exit then
   JSON:T-FALSE <> if E-ANSWER throw then
   false ;


\ The members of the object just opened, each read by `member` at its key.
: MEMBERS ( JSON:reader ^client [ JSON:reader ^client -- JSON:reader ] -- JSON:reader )
   {: c member :}
   begin JSON:READ-NEXT dup JSON:T-KEY = while
      drop c member execute
   repeat
   JSON:T-OBJ-END <> if E-ANSWER throw then ;


\ Each answer's values get a block of their own, so the room a large answer
\ took is freed with the next.
: READ-ANSWER ( ^client [ JSON:reader ^client -- JSON:reader ] -- ^client )
   {: c member :}
   VEC-ALLOC @ 0 [type] u8 VEC:NEW {: v:^ :}
   c CLIENT-VALUES @ VEC:DELETE  v c CLIENT-VALUES !
   v c ANSWER$ STR:len VEC:RESERVE
   c CLIENT-CURSOR c ANSWER$ JSON:READ-INIT
   VALUE OBJECT c member MEMBERS
   JSON:READ-FINISH c ;


\ Whether code says the answer does not parse: a JSON read code or
\ E-ANSWER.
: UNPARSED? ( n -- bool )
   {: code:n :}
   code E-ANSWER = if true exit then
   code E-JSON-READ-LAST >= code E-JSON-READ-FIRST <= and ;


\ Whether code is E-ANSWER or E-UNUSABLE, logged where it was thrown.
: BAD-ANSWER? ( n -- bool )
   {: code:n :}
   code E-ANSWER = code E-UNUSABLE = or ;


\ Whether the answer is one JSON object `member` reads; a failure leaves
\ the cursor disposed, and any other code, such as a memory fault, goes on.
: PARSES? ( ^client [ JSON:reader ^client -- JSON:reader ] -- bool )
   {: c member :}
   c [: member READ-ANSWER ;] catch {: code:n :} drop
   code 0= if true exit then
   c CLIENT-CURSOR JSON:READ-DISPOSE
   code UNPARSED? 0= if code throw then
   false ;


: PARSE ( ^client [ JSON:reader ^client -- JSON:reader ] -- )
   {: c member :}
   c member PARSES? if exit then
   c s" an answer that does not parse" E-ANSWER FAILED ;


\ ---- error bodies

: LEAF-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" .tag" JSON:READ-STR-EQ? if c STRING c CLIENT-LEAF ! exit then
   SKIP ;


: ERROR-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" .tag" JSON:READ-STR-EQ? if c STRING c CLIENT-OUTER ! exit then
   s" retry_after" JSON:READ-STR-EQ? if INT c CLIENT-WAIT ! exit then
   s" correct_offset" JSON:READ-STR-EQ? if INT c CLIENT-CORRECT ! exit then
   c DECODE {: name:SPAN:span<u8> :}
   VALUE JSON:T-OBJ = if
      c [: LEAF-MEMBER ;] MEMBERS
      name c CLIENT-LEAF-NAME ! exit
   then
   JSON:READ-SKIP-VALUE ;


\ `error` is a string in an OAuth answer and a union object in an API one.
: ERROR-TOP ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" error" JSON:READ-STR-EQ? 0= if SKIP exit then
   VALUE dup JSON:T-STR = if drop c DECODE c CLIENT-OUTER ! exit then
   OBJECT c [: ERROR-MEMBER ;] MEMBERS ;


: ERROR-READ? ( ^client -- bool )
   {: c :}
   EMPTY c CLIENT-OUTER ! EMPTY c CLIENT-LEAF-NAME ! EMPTY c CLIENT-LEAF !
   -1 c CLIENT-WAIT ! -1 c CLIENT-CORRECT !
   c [: ERROR-TOP ;] PARSES? ;


: LEAF$ ( ^client -- str )
   {: c :}
   c CLIENT-LEAF-NAME @ SPAN:$ {: m :}
   m c TAG$ STR:= m s" reason" STR:= or
   c CLIENT-LEAF @ SPAN:LEN 0<> and if c CLIENT-LEAF @ SPAN:$ exit then
   c TAG$ ;


: TAG>ERROR ( str -- error bool )
   dup s" not_found" STR:= if drop construct error not-found true exit then
   dup s" not_file" STR:= if drop construct error not-file true exit then
   dup s" not_folder" STR:= if drop construct error not-folder true exit then
   dup s" malformed_path" STR:= if drop construct error malformed-path true exit then
   dup s" disallowed_name" STR:= if drop construct error disallowed-name true exit then
   dup s" conflict" STR:= if drop construct error conflict true exit then
   dup s" no_write_permission" STR:= if drop construct error no-write-permission true exit then
   dup s" restricted_content" STR:= if drop construct error restricted-content true exit then
   dup s" access_restricted" STR:= if drop construct error access-restricted true exit then
   dup s" team_folder" STR:= if drop construct error team-folder true exit then
   dup s" operation_suppressed" STR:= if drop construct error operation-suppressed true exit then
   dup s" insufficient_space" STR:= if drop construct error insufficient-space true exit then
   dup s" locked" STR:= if drop construct error locked true exit then
   dup s" reset" STR:= if drop construct error reset true exit then
   dup s" content_hash_mismatch" STR:= if drop construct error content-hash-mismatch true exit then
   dup s" unsupported_file" STR:= if drop construct error unsupported-file true exit then
   drop construct error other false ;


\ ---- classifying an answer

: RETRY ( n -- reply ) construct reply retry ;
: ANSWER ( reply -- verdict ) construct verdict answer ;


\ A fault that may pass if the call is made again, a timeout or a lost
\ connection, is retry 0; any other is logged and thrown.
: FAULTED ( ^client HTTPC:fault -- reply )
   {: c f:HTTPC:fault :}
   f HTTPC:LOST? if 0 RETRY exit then
   c f HTTP-FAILED ;


\ One line, the route and that no answer came, then E-TRANSPORT.
: UNANSWERED ( ^client -- reply )
   {: c :}
   LOG-OPEN s" http " LOG:TEXT+ c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+
   s" : no answer" LOG:TEXT+ LOG:;LINE
   E-TRANSPORT throw ;


\ A transfer that ended with no answer, by its fault.
: LOST ( ^client -- reply )
   {: c :}
   c CLIENT-FAILURE @ MATCH option
      some OF c swap FAULTED ENDOF
      none OF c UNANSWERED ENDOF
   ;MATCH ;


\ 408, 429 and 5xx: statuses Dropbox may answer otherwise later.
: UNAVAILABLE? ( n -- bool )
   {: s:n :}
   s 408 = s 429 = or s 500 >= s 599 <= and or ;


\ Whether the reply is a retry asking no wait.
: RETRY-NOW? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF 0= ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ Whether Dropbox may have applied the call r answers, a retry asking no
\ wait; never after a refresh's failure, as the call never went out.
: UNSURE? ( reply ^client -- bool )
   {: r:reply c :}
   r RETRY-NOW? 0= if false exit then
   c CLIENT-QUIET @ if false exit then
   c CLIENT-STATUS @ {: s:n :}
   s 0= if true exit then
   s 429 <> s UNAVAILABLE? and ;


\ 429: the larger of Retry-After and the body's error.retry_after; 408 or
\ 5xx: Retry-After; 0 when neither gives one. Each wait is at most WAIT-CAP
\ seconds.
: WAITED ( ^client -- reply )
   {: c :}
   c RETRY-AFTER 0= if drop 0 then
   c CLIENT-STATUS @ 429 = if
      c ERROR-READ? if c CLIENT-WAIT @ max then
   then
   0 max WAIT-CAP min 1000 * RETRY ;


: UNEXPECTED ( ^client n -- )
   {: c s:n :}
   s 300 >= s 400 < and if c s" a redirect" E-REDIRECT FAILED then
   s 400 = if c s" a malformed request" E-BAD-REQUEST FAILED then
   s 401 = if c s" an unauthorized request" E-AUTH FAILED then
   c s" an unexpected status" E-STATUS FAILED ;


: REFUSED ( ^client -- reply )
   {: c :}
   c ERROR-READ? 0= if c s" an error that does not parse" E-ANSWER FAILED then
   c LEAF$ {: t :}
   t s" too_many_write_operations" STR:= if 0 RETRY exit then
   t TAG>ERROR if construct reply refused exit then
   LOG:WARN s" dropbox" LOG:LINE
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+ s"  refused: " LOG:TEXT+ t LOG:TEXT+
   LOG:;LINE
   construct reply refused ;


\ One line, the route and why: Dropbox refuses this app until the user
\ logs in again.
: UNLINKED ( ^client str -- reply )
   {: c why :}
   LOG-OPEN
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+ s"  unlinked: " LOG:TEXT+
   why LOG:TEXT+ LOG:;LINE
   construct reply unlinked ;


: CLASSIFY ( ^client -- verdict )
   {: c :}
   c CLIENT-STATUS @ {: s:n :}
   s 0= if c LOST ANSWER exit then
   s 200 = if construct reply done ANSWER exit then
   s 401 = if construct verdict rejected exit then
   s 403 = if c s" 403" UNLINKED ANSWER exit then
   s 409 = if c REFUSED ANSWER exit then
   s 422 = if construct error invalid-root construct reply refused ANSWER exit then
   s UNAVAILABLE? if c WAITED ANSWER exit then
   c s UNEXPECTED ;


\ ---- the token

\ Appends the bytes form-encoded, as URI:FORM-ENCODE writes them; they may be
\ the vector's own, though growth moves the block.
: ENCODED+ ( str ^VEC:vector<u8> -- )
   {: s:str v:^ :}
   s URI:FORM-LEN {: len:n :}
   v VEC:COUNT {: at:n :}
   v at len + s STR:DATA VEC:MAKE-ROOM {: src:^ :}
   v at len + VEC:ENSURE
   src s STR:LEN >str v VEC:BYTES STR:DATA at + len SPAN:MAKE
   URI:FORM-ENCODE drop ;


\ The refresh's form body, in the line buffer: HTTPC:HEADER+ copied each
\ head line out of it.
: FORM ( ^client -- str )
   {: c :}
   c CLIENT-LINE @ {: v :}
   v 0 VEC:RESIZE
   s" grant_type=refresh_token&refresh_token=" v BYTES+
   c CLIENT-TOKEN @ BUF$ v ENCODED+
   s" &client_id=" v BYTES+
   c CLIENT-KEY @ SPAN:$ v ENCODED+
   v BYTES$ ;


: ISSUED-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" access_token" JSON:READ-STR-EQ? 0= if SKIP exit then
   c STRING c CLIENT-ISSUED ! ;


\ A token answer's members: access_token and refresh_token.
: GRANTED-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" refresh_token" JSON:READ-STR-EQ? 0= if c ISSUED-MEMBER exit then
   c STRING c CLIENT-GRANTED ! ;


: REPLACED ( SPAN:span<u8> ^n -- )
   {: t:SPAN:span<u8> buf :}
   t SPAN:$ str> BUF:N>BLEN buf BUF:REPLACE ;


\ ---- the refresh token's phase
\ phase     input                                  next
\ ready     a refresh with no new refresh token    ready
\ ready     a new one the store takes              ready
\ ready     a new one the store refuses            pending
\ ready     invalid_grant, a fresh token refused   rejected
\ pending   a call, the store taking the token     ready
\ pending   a call, the store refusing it          pending
\ rejected  a call, answered unlinked unsent       rejected
\ any       an exchange's tokens kept              ready
\ A refusal throws E-NOT-STORED from the call. A call starts by its
\ phase, so a refresh only ever starts in ready.

\ Hands the client's refresh token to the store: ready when it returns,
\ pending when it throws. Answers its code, 0 for none.
: PERSIST ( ^client -- n )
   {: c :}
   [: c CLIENT-TOKEN @ BUF$ c CLIENT-STORE @ execute ;] catch
   {: code:n :}
   code 0= if construct phase ready else construct phase pending then
   c CLIENT-PHASE !
   code ;


\ One line with the store's code, then E-NOT-STORED.
: NOT-STORED ( n -- )
   {: code:n :}
   LOG-OPEN E-NOT-STORED LOG:CODE+
   s" ; the store threw " LOG:TEXT+ code LOG:CODE+ LOG:;LINE
   E-NOT-STORED throw ;


\ A new refresh token goes to the store, and the client keeps it either
\ way. Answers the store's code, 0 when it took it or none was new.
: ROTATED ( ^client -- n )
   {: c :}
   c CLIENT-GRANTED @ SPAN:$ {: g :}
   g STR:len 0= if 0 exit then
   g c CLIENT-TOKEN @ BUF$ STR:= if 0 exit then
   c CLIENT-GRANTED @ c CLIENT-TOKEN @ REPLACED
   c PERSIST ;


\ A refresh's tokens: the access token is kept once the store has run.
: KEPT-TOKEN ( ^client -- reply )
   {: c :}
   EMPTY c CLIENT-ISSUED ! EMPTY c CLIENT-GRANTED !
   c [: GRANTED-MEMBER ;] PARSE
   c CLIENT-ISSUED @ SPAN:LEN 0=
   if c s" no access_token" E-ANSWER FAILED then
   c ROTATED {: code:n :}
   c CLIENT-ISSUED @ c CLIENT-ACCESS @ REPLACED
   code 0<> if code NOT-STORED then
   construct reply done ;


\ Unlinked, which every later call that carries a token answers with
\ nothing sent.
: REJECTED ( ^client str -- reply )
   {: c why :}
   construct phase rejected c CLIENT-PHASE !
   c why UNLINKED ;


\ invalid_grant answers what `dead` answers.
: GRANT ( ^client [ ^client -- reply ] -- reply )
   {: c dead :}
   c ERROR-READ? if
      c TAG$ s" invalid_grant" STR:= if c dead execute exit then
   then
   c s" a refused token request" E-BAD-REQUEST FAILED ;


\ A token answer; `kept` reads a 200's tokens and `dead` answers an
\ invalid_grant.
: REFRESHED ( ^client [ ^client -- reply ] [ ^client -- reply ] -- reply )
   {: c kept dead :}
   c CLIENT-STATUS @ {: s:n :}
   s 0= if c LOST exit then
   s 200 = if c kept execute exit then
   s 400 = if c dead GRANT exit then
   s UNAVAILABLE? if c WAITED exit then
   c s UNEXPECTED ;


\ A POST to <api>/oauth2/token of the form `form` writes, with no
\ Authorization or Path-Root; the access token is empty until one is kept.
: TOKEN-POST ( ^client [ ^client -- str ] -- )
   {: c form :}
   c CLIENT-ACCESS @ BUF:CLEAR
   s" oauth2/token" str> SPAN:MAKE c CLIENT-ROUTE !
   true c CLIENT-QUIET !
   c LINE-CLEAR c s" /oauth2/token" LINE+
   c c CLIENT-API-CONN PREPARE {: h :}
   h s" Content-Type: application/x-www-form-urlencoded" HTTPC:HEADER+
   c form execute str> SPAN:MAKE c CLIENT-OUT !
   OPTION:NONE c TRANSFER ;


\ A new access token for the refresh token.
: REFRESH ( ^client -- reply )
   {: c :}
   c [: FORM ;] TOKEN-POST
   c [: KEPT-TOKEN ;]
   [: s" the refresh token was refused" REJECTED ;] REFRESHED ;


\ ---- a call

public

: DONE? ( reply -- bool )
   MATCH reply
      done OF true ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

private


\ A POST to /2/<route> on the origin's connection o; body sets the route's
\ headers and body, and send exchanges the request and classifies its
\ answer.
: ATTEMPT ( ^client ^HTTPC:conn str [ ^HTTPC:conn ^client -- ] [ ^client -- verdict ] -- verdict )
   {: c o r body send :}
   r str> SPAN:MAKE c CLIENT-ROUTE !
   false c CLIENT-QUIET !
   c LINE-CLEAR c s" /2/" LINE+ c r LINE+
   c o PREPARE {: h :}
   h c AUTHORIZE
   h c body execute
   c send execute ;


: RESEND ( ^client ^HTTPC:conn str [ ^HTTPC:conn ^client -- ] [ ^client -- verdict ] -- reply )
   {: c o r body send :}
   c REFRESH {: again:reply :}
   again DONE? 0= if again exit then
   c o r body send ATTEMPT MATCH verdict
      answer OF ENDOF
      rejected OF c s" a refreshed token was refused" REJECTED ENDOF
   ;MATCH ;


: ACCESS ( ^client -- reply )
   {: c :}
   c CLIENT-ACCESS @ BLEN 0<> if construct reply done exit then
   c REFRESH ;


: RETRIED ( ^client -- reply )
   {: c :}
   c PERSIST {: code:n :}
   code 0<> if code NOT-STORED then
   c ACCESS ;


\ A call starts by the refresh token's phase.
: READY ( ^client -- reply )
   {: c :}
   c CLIENT-PHASE @ MATCH phase
      ready OF c ACCESS ENDOF
      pending OF c RETRIED ENDOF
      rejected OF construct reply unlinked ENDOF
   ;MATCH ;


: CALL-AT ( ^client ^HTTPC:conn str [ ^HTTPC:conn ^client -- ] [ ^client -- verdict ] -- reply )
   {: c o r body send :}
   c READY {: first:reply :}
   first DONE? 0= if first exit then
   c o r body send ATTEMPT MATCH verdict
      answer OF ENDOF
      rejected OF c o r body send RESEND ENDOF
   ;MATCH ;


\ The whole answer read and classified.
: RECEIVED ( ^client -- verdict )
   {: c :}
   OPTION:NONE c TRANSFER c CLASSIFY ;


\ A POST to <api>/2/<route>; body sets the route's headers and body.
: CALL ( ^client str [ ^HTTPC:conn ^client -- ] -- reply )
   {: c r body :}
   c c CLIENT-API-CONN r body [: RECEIVED ;] CALL-AT ;


\ On done, reads the answer into the client.
: ANSWERED ( reply ^client [ ^client -- ] -- reply )
   {: r:reply c read :}
   r DONE? if c read execute then
   r ;


\ An empty body, with no Content-Type line.
: NO-BODY ( ^HTTPC:conn ^client -- )
   nip {: c :}
   EMPTY c CLIENT-OUT ! ;


: JSON-BODY ( ^HTTPC:conn ^client -- )
   {: h c :}
   h s" Content-Type: application/json" HTTPC:HEADER+
   c CLIENT-BODY @ VEC:SPAN c CLIENT-OUT ! ;


: BODY-OPEN ( ^client -- ^JSON:writer )
   {: c :}
   c CLIENT-WRITER c CLIENT-BODY @ JSON:OPEN
   true JSON:WRITE-ASCII! ;


\ ---- the routes' answers

: ROOT-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" .tag" JSON:READ-STR-EQ? if
      c STRING c CLIENT-ROOT-TAG ! true c CLIENT-TAGGED ! exit
   then
   s" root_namespace_id" JSON:READ-STR-EQ? 0= if SKIP exit then
   c STRING c CLIENT-NAMESPACE ! ;


: ACCOUNT-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" account_id" JSON:READ-STR-EQ? if c STRING c CLIENT-ACCOUNT ! exit then
   s" root_info" JSON:READ-STR-EQ? 0= if SKIP exit then
   VALUE OBJECT c [: ROOT-MEMBER ;] MEMBERS ;


\ Whether root_info's tag is user or team, the roots that carry a namespace.
: NAMED-ROOT? ( ^client -- bool )
   CLIENT-ROOT-TAG @ SPAN:$ {: t :}
   t s" user" STR:= t s" team" STR:= or ;


\ A root under any other tag, which Dropbox's open union may add, answers
\ no namespace, so it never matches a binding, as Rust refuses it.
: ACCOUNT-READ ( ^client -- )
   {: c :}
   EMPTY c CLIENT-ACCOUNT ! EMPTY c CLIENT-NAMESPACE !
   EMPTY c CLIENT-ROOT-TAG ! false c CLIENT-TAGGED !
   c [: ACCOUNT-MEMBER ;] PARSE
   c CLIENT-ACCOUNT @ SPAN:LEN 0= c CLIENT-TAGGED @ 0= or
   if c s" no account_id or root_info tag" E-ANSWER FAILED then
   c NAMED-ROOT? 0= if EMPTY c CLIENT-NAMESPACE ! exit then
   c CLIENT-NAMESPACE @ SPAN:LEN 0=
   if c s" no root_namespace_id" E-ANSWER FAILED then ;


: KIND-OF ( JSON:reader -- JSON:reader kind )
   VALUE JSON:T-STR <> if E-ANSWER throw then
   s" file" JSON:READ-STR-EQ? if construct kind file exit then
   s" folder" JSON:READ-STR-EQ? if construct kind folder exit then
   s" deleted" JSON:READ-STR-EQ? if construct kind deleted exit then
   E-ANSWER throw ;


: ENTRY-CLEAR ( ^entry -- )
   {: e :}
   construct kind deleted e DROPBOX-ENTRY:KIND !
   EMPTY e DROPBOX-ENTRY:LOWER ! EMPTY e DROPBOX-ENTRY:DISPLAY !
   EMPTY e DROPBOX-ENTRY:REV ! EMPTY e DROPBOX-ENTRY:CONTENT-HASH !
   0 e DROPBOX-ENTRY:SIZE ! true e DROPBOX-ENTRY:DOWNLOADABLE !
   false e DROPBOX-ENTRY:RESTRICTED ! ;


: FILE? ( ^entry -- bool )
   DROPBOX-ENTRY:KIND @ construct kind file DROPBOX-KIND:EQ ;


: DELETED? ( ^entry -- bool )
   DROPBOX-ENTRY:KIND @ construct kind deleted DROPBOX-KIND:EQ ;


: DOWNLOADS? ( ^entry -- bool )
   {: e :}
   e FILE? e DROPBOX-ENTRY:DOWNLOADABLE @ and ;


: HEX-DIGIT? ( u8 -- bool )
   {: b :}
   b 48 >= b 57 <= and b 97 >= b 102 <= and or ;


public

\ Dropbox's content hash: 64 lowercase hex digits.
: CONTENT-HASH? ( str -- bool )
   str> {: p:^ u:n :}
   u 64 <> if false exit then
   true u 0 ?do p i + c@ HEX-DIGIT? and loop ;

\ Whether a downloadable file has a rev and a well-formed content hash.
: COMPLETE? ( ^entry -- bool )
   {: e :}
   e DOWNLOADS? 0= if false exit then
   e DROPBOX-ENTRY:REV @ SPAN:LEN 0<>
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$ CONTENT-HASH? and ;

private


\ Whether the entry holds both its paths.
: PATHS? ( ^entry -- bool )
   {: e :}
   e DROPBOX-ENTRY:LOWER @ SPAN:LEN 0<>
   e DROPBOX-ENTRY:DISPLAY @ SPAN:LEN 0<> and ;


\ Whether a downloadable file holds a rev and a hash; any other entry
\ needs neither.
: FILLED? ( ^entry -- bool )
   {: e :}
   e DOWNLOADS? 0= if true exit then
   e DROPBOX-ENTRY:REV @ SPAN:LEN 0<>
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:LEN 0<> and ;


\ A route answers its entry in one shape. A plain FileMetadata or
\ FolderMetadata takes its kind from the route and skips a `.tag` as any
\ member it does not know, as the SDK does; a Metadata union takes its kind
\ from its `.tag`.

\ is_downloadable into the entry; a symlink_info read before it keeps
\ it false.
: DOWNLOADABLE ( JSON:reader ^entry -- JSON:reader )
   {: e :}
   BOOLEAN e DROPBOX-ENTRY:DOWNLOADABLE @ and
   e DROPBOX-ENTRY:DOWNLOADABLE ! ;


\ Whether the key is FolderSharingInfo's no_access or traverse_only.
: BARRED? ( JSON:reader -- JSON:reader bool )
   s" no_access" JSON:READ-STR-EQ? if true exit then
   s" traverse_only" JSON:READ-STR-EQ? ;


\ Either member true marks the entry; any other is skipped.
: SHARING-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   BARRED? 0= if SKIP exit then
   c CLIENT-ENTRY {: e :}
   BOOLEAN e DROPBOX-ENTRY:RESTRICTED @ or e DROPBOX-ENTRY:RESTRICTED ! ;


: SHARING ( JSON:reader ^client -- JSON:reader )
   {: c :}
   VALUE OBJECT c [: SHARING-MEMBER ;] MEMBERS ;


\ The members both shapes hold.
: FIELD-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c CLIENT-ENTRY {: e :}
   s" path_lower" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:LOWER ! exit then
   s" path_display" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:DISPLAY ! exit then
   s" rev" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:REV ! exit then
   s" content_hash" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:CONTENT-HASH ! exit then
   s" size" JSON:READ-STR-EQ? if INT e DROPBOX-ENTRY:SIZE ! exit then
   s" is_downloadable" JSON:READ-STR-EQ? if e DOWNLOADABLE exit then
   s" symlink_info" JSON:READ-STR-EQ? if SKIP false e DROPBOX-ENTRY:DOWNLOADABLE ! exit then
   s" sharing_info" JSON:READ-STR-EQ? if c SHARING exit then
   SKIP ;


: TAGGED-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" .tag" JSON:READ-STR-EQ? if
      KIND-OF c CLIENT-ENTRY DROPBOX-ENTRY:KIND ! true c CLIENT-TAGGED ! exit
   then
   c FIELD-MEMBER ;


\ restricted kept for a folder alone, once its members are read: a
\ union's `.tag` may follow its sharing_info.
: ENTRY-CLOSE ( ^client -- )
   CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ construct kind folder DROPBOX-KIND:EQ
   e DROPBOX-ENTRY:RESTRICTED @ and e DROPBOX-ENTRY:RESTRICTED ! ;


\ The entry cleared to read one of kind k, with no `.tag` read yet.
: ENTRY-OPEN ( ^client kind -- )
   {: c k:kind :}
   c CLIENT-ENTRY {: e :}
   e ENTRY-CLEAR k e DROPBOX-ENTRY:KIND !
   false c CLIENT-TAGGED ! ;


\ A plain record of kind k, its object just opened, read into the entry.
: PLAIN-OBJECT ( JSON:reader ^client kind -- JSON:reader )
   {: c k:kind :}
   c k ENTRY-OPEN
   c [: FIELD-MEMBER ;] MEMBERS c ENTRY-CLOSE ;


\ A Metadata union, its object just opened, read into the entry: one with
\ no `.tag` has no kind, and is never taken for a deleted entry.
: TAGGED-OBJECT ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c construct kind deleted ENTRY-OPEN
   c [: TAGGED-MEMBER ;] MEMBERS c ENTRY-CLOSE
   c CLIENT-TAGGED @ 0= if E-ANSWER throw then ;


\ The answer's entry, as `member` finds it with the entry open at kind k,
\ with both its paths. An entry left at deleted with no `.tag` read, as a
\ union with none or an answer with no entry is, fails.
: ENTRY-FOUND ( ^client kind [ JSON:reader ^client -- JSON:reader ] -- )
   {: c k:kind member :}
   c k ENTRY-OPEN
   c member PARSE c ENTRY-CLOSE
   c CLIENT-ENTRY {: e :}
   e DELETED? c CLIENT-TAGGED @ 0= and
   if c s" an incomplete entry" E-ANSWER FAILED then
   e PATHS? 0= if c s" an incomplete entry" E-UNUSABLE FAILED then ;


\ As ENTRY-FOUND for a mutation's answer, a file or folder: fails a deleted
\ entry, and a downloadable file without its rev or hash.
: ENTRY-PARSE ( ^client kind [ JSON:reader ^client -- JSON:reader ] -- )
   {: c k:kind member :}
   c k member ENTRY-FOUND
   c CLIENT-ENTRY {: e :}
   e DELETED? e FILLED? 0= or
   if c s" an incomplete entry" E-UNUSABLE FAILED then ;


\ get_metadata's answer, a Metadata union, a deleted entry among them; a
\ file Dropbox described incompletely is handed as it is, and COMPLETE? tells.
: ENTRY-READ ( ^client -- )
   construct kind deleted [: TAGGED-MEMBER ;] ENTRY-FOUND ;


\ The answer of upload and upload_session/finish, and download's
\ Dropbox-API-Result: a plain FileMetadata.
: FILE-READ ( ^client -- )
   construct kind file [: FIELD-MEMBER ;] ENTRY-PARSE ;


\ Whether the entry's path_lower is the path's full lowercase.
: AT? ( str ^client -- bool )
   CLIENT-ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$ UNICODE:LOWERS-TO? ;


\ done stands for an entry at the path; one elsewhere is refused
\ path-mismatch.
: PLACED ( reply str ^client -- reply )
   {: m:reply p c :}
   m DONE? 0= if m exit then
   p c AT? if m exit then
   construct error path-mismatch construct reply refused ;


\ ---- files/download

\ transport.rs BODY_IDLE_SECONDS: the longest a body, or a connect, may stall.
60 constant IDLE


: INT+ ( ^client n -- ) {: c v:n :} c v FMT:INT$ LINE+ ;


\ The Dropbox-API-Arg line, {"path": "rev:<rev>"}: the value is built in
\ the line, the JSON in the body buffer a download never sends.
: ARG-LINE ( ^client str -- str )
   {: c r :}
   c LINE-CLEAR c s" rev:" LINE+ c r LINE+
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" c LINE$ JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:CLOSE
   c LINE-CLEAR c s" Dropbox-API-Arg: " LINE+
   c c CLIENT-BODY @ BYTES$ LINE+
   c LINE$ ;


\ The content deadlines: a stall ends the call, a long body does not.
: STALLED ( ^HTTPC:conn -- )
   0 IDLE 1000 * HTTPC:DEADLINES! ;


\ An empty body, the rev's argument, a Range from a nonzero offset, and the
\ content deadlines.
: ASKED ( ^HTTPC:conn ^client str n -- )
   {: h c r at:n :}
   h c NO-BODY
   h c r ARG-LINE HTTPC:HEADER+
   at 0 > if
      c LINE-CLEAR c s" Range: bytes=" LINE+ c at INT+ c s" -" LINE+
      h c LINE$ HTTPC:HEADER+
   then
   h STALLED ;


-100009 s" a download's answer failed its checks"
   ERROR:CODE E-UNVERIFIED


\ Runs a parse of the download's answer, which replaces its seed as catch
\ keeps the stack's shape; a bad answer, logged already, is E-UNVERIFIED.
: VERIFIED ( R [ R -- R ] -- R )
   {: parse :}
   [: parse execute ;] catch {: code:n :}
   code 0= if exit then
   code BAD-ANSWER? if E-UNVERIFIED throw then
   code throw ;


\ The metadata the Dropbox-API-Result header holds, read into the entry.
\ It replaces the answer buffer, so a 2xx chunk lands in the body buffer
\ and a failed check logs the result, never a byte of the file.
: RESULT-READ ( ^client -- )
   {: c :}
   c s" Dropbox-API-Result" HEADER$ str> BUF:N>BLEN
   c CLIENT-ANSWER @ BUF:REPLACE
   s" result" str> SPAN:MAKE c CLIENT-HOLDS !
   [: c FILE-READ ;] VERIFIED ;


\ The Content-Range a ranged answer of the entry must carry, in the line.
: RANGE-LINE ( ^client n ^entry -- str )
   {: c at:n e :}
   e DROPBOX-ENTRY:SIZE @ {: size:n :}
   c LINE-CLEAR c s" bytes " LINE+ c at INT+ c s" -" LINE+
   c size 1- INT+ c s" /" LINE+ c size INT+
   c LINE$ ;


\ An offset above 0 needs a 206 with the range asked, InvalidDownloadRange
\ in dropbox.rs; offset 0 needs a 200.
: RANGED ( ^client n ^entry -- )
   {: c at:n e :}
   c CLIENT-STATUS @ {: s:n :}
   at 0= if
      s 200 <> if c s" a range nobody asked for" E-UNVERIFIED FAILED then
      exit
   then
   s 206 <> if c s" a whole file for a range" E-UNVERIFIED FAILED then
   at e DROPBOX-ENTRY:SIZE @ >=
   if c s" a range past the file" E-UNVERIFIED FAILED then
   c s" Content-Range" HEADER$ c at e RANGE-LINE STR:=
   0= if c s" another Content-Range" E-UNVERIFIED FAILED then ;


\ The status, metadata and Content-Range of a 2xx answer, from the answer's
\ headers: the rev, content hash and range asked.
: CHECKED ( ^client str str n -- )
   {: c r h at:n :}
   c RESULT-READ
   c CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:REV @ SPAN:$ r STR:=
   0= if c s" another rev" E-UNVERIFIED FAILED then
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$ h STR:=
   0= if c s" another content hash" E-UNVERIFIED FAILED then
   c at e RANGED ;


\ ---- the download's machine

\ A read steps streaming, again while it pulls an empty chunk, and pulls
\ only once the held chunk is all taken: held, or overran by a byte past
\ the file's end; drained or short at the body's end, by its length;
\ cancelled once the body returns.
ENUM download-step DERIVE eq
   opened streaming buffering answered drained lost cancelled
   overran short ;ENUM
ENUM read-event chunk response failure ;ENUM
ENUM open-event passed other response failure ;ENUM
ENUM stream-event held response short failure overrun unread ;ENUM


\ One download's read: held the chunk read last and taken its bytes the
\ reader took, total all it took; conn the transfer's connection; failure
\ the fault of the read that failed;
\ room what the read in progress asks; returned once the body returned.
public
STRUCTURE fetch OPAQUE DERIVE addr
   FIELD client ^client
   FIELD conn ^HTTPC:conn
   FIELD rev rev
   FIELD content-hash hash
   FIELD offset n
   FIELD step download-step
   FIELD held SPAN:span<u8>
   FIELD taken n
   FIELD status n
   FIELD failure option<HTTPC:fault>
   FIELD total n
   FIELD room n
   FIELD returned bool
;STRUCTURE
private

HEAP FETCHES fetch

: REV-HASH ( ^fetch -- str str )
   {: f :}
   f FETCH-REV @ REV>STR f FETCH-CONTENT-HASH @ HASH>STR ;


-100008 s" a download's transfer ended inside its body"
   ERROR:CODE E-BODY-LOST


: HOLD ( n len ^u8 ^fetch -- )
   {: p:^ f :}
   LEN>N p swap SPAN:MAKE f FETCH-HELD !
   0 f FETCH-TAKEN !
   f FETCH-STATUS ! ;


\ The body vector's whole room, at least CHUNK bytes, as one span; the bytes
\ it held stay unzeroed for the read to overwrite.
: BODY-ROOM ( ^VEC:vector<u8> -- ^u8 len )
   {: v :}
   v CHUNK VEC:RESERVE
   v v VEC:CAP VEC:RESIZE
   v VEC:SPAN SPAN:$ str> >LEN ;


\ One read into the body vector, which a download never sends.
: PULL ( ^fetch -- read-event )
   {: f :}
   f FETCH-CLIENT @ CLIENT-BODY @ BODY-ROOM {: p:^ room:len :}
   f FETCH-CONN @ p room HTTPC:NEXT MATCH HTTPC:chunk-result
      chunk OF p f HOLD construct read-event chunk ENDOF
      response OF
         f FETCH-STATUS !
         construct read-event response
      ENDOF
      failed OF
         OPTION:SOME f FETCH-FAILURE !
         construct read-event failure
      ENDOF
   ;MATCH ;


\ The first chunk: a 2xx one passes CHECKED, made through the answer's
\ head, read before that chunk, or CHECKED throws; any other status is
\ the core's to classify.
: FIRST-CHECKED ( ^fetch -- open-event )
   {: f :}
   f FETCH-STATUS @ {: s:n :}
   s 200 >= s 300 < and 0= if construct open-event other exit then
   f FETCH-CLIENT @ {: c :}
   s c CLIENT-STATUS !
   c f REV-HASH f FETCH-OFFSET @ CHECKED
   construct open-event passed ;


: OPEN-SENSE ( ^fetch -- open-event )
   {: f :}
   f PULL MATCH read-event
      chunk OF f FIRST-CHECKED ENDOF
      response OF construct open-event response ENDOF
      failure OF construct open-event failure ENDOF
   ;MATCH ;


\ A chunk of a status other than 2xx, for the core to classify.
: ANSWER+ ( ^fetch -- )
   {: f :}
   f FETCH-HELD @ SPAN:$ f FETCH-CLIENT @ CLIENT-ANSWER @ APPEND ;


\ The transfer ended with an answer: only its status, as nothing after
\ the read that ended a transfer may throw.
: RESPONDED ( ^fetch -- )
   {: f :}
   f FETCH-STATUS @ f FETCH-CLIENT @ CLIENT-STATUS ! ;


: BROKE ( ^fetch -- )
   {: f :}
   f FETCH-CLIENT @ {: c :}
   0 c CLIENT-STATUS !
   f FETCH-FAILURE @ c CLIENT-FAILURE ! ;


: STREAMING? ( download-step -- bool )
   construct download-step streaming DOWNLOAD-STEP-EQ ;
: DRAINED? ( download-step -- bool )
   construct download-step drained DOWNLOAD-STEP-EQ ;
: CUT? ( download-step -- bool )
   construct download-step lost DOWNLOAD-STEP-EQ ;
: CANCELLED? ( download-step -- bool )
   construct download-step cancelled DOWNLOAD-STEP-EQ ;
: OVERRAN? ( download-step -- bool )
   construct download-step overran DOWNLOAD-STEP-EQ ;
: SHORT? ( download-step -- bool )
   construct download-step short DOWNLOAD-STEP-EQ ;


\ Whether the machine streams with its held chunk all taken.
: STARVED? ( ^fetch -- bool )
   {: f :}
   f FETCH-STEP @ STREAMING? 0= if false exit then
   f FETCH-TAKEN @ f FETCH-HELD @ SPAN:LEN = ;


\ How many of the held chunk's untaken bytes fit in room.
: TAKING ( n ^fetch -- n )
   {: room:n f :}
   f FETCH-HELD @ SPAN:LEN f FETCH-TAKEN @ - room min ;


: FILE-SIZE ( ^client -- n ) CLIENT-ENTRY DROPBOX-ENTRY:SIZE @ ;


\ held, or overrun when the room the read asks would take a byte of the
\ held chunk past the rest bytes after the offset.
: HELD-EVENT ( ^fetch n -- stream-event )
   {: f rest:n :}
   f FETCH-ROOM @ f TAKING f FETCH-TOTAL @ + rest > if
      construct stream-event overrun exit
   then
   construct stream-event held ;


\ The transfer's last read: response for a body of the rest bytes after the
\ offset, short for one of fewer.
: LAST-EVENT ( ^fetch n -- stream-event )
   {: f rest:n :}
   f FETCH-TOTAL @ rest = if construct stream-event response exit then
   construct stream-event short ;


\ unread once the body returned; else, with the held chunk all taken,
\ the transfer's next read, then held or overrun for the read in progress.
: STREAM-SENSE ( ^fetch -- stream-event )
   {: f :}
   f FETCH-RETURNED @ if construct stream-event unread exit then
   f FETCH-CLIENT @ FILE-SIZE f FETCH-OFFSET @ - {: rest:n :}
   f STARVED? 0= if f rest HELD-EVENT exit then
   f PULL MATCH read-event
      chunk OF f rest HELD-EVENT ENDOF
      response OF f rest LAST-EVENT ENDOF
      failure OF construct stream-event failure ENDOF
   ;MATCH ;


\ Ends the transfer in flight by closing its connection.
: ABANDON ( ^fetch -- )
   FETCH-CONN @ HTTPC:CLOSE ;


\ One download's transfer, after formal/Downloading.tla. A throw from a
\ sense or an action leaves the transfer in flight, for READ-OUT to end.
FSM:DEFINE DOWNLOADING ( ^fetch ) download-step open-event
   IN opened  OPEN-SENSE
      passed    -          >streaming
      other     ANSWER+    >buffering
      response  RESPONDED  >answered
      failure   BROKE      >lost
   IN streaming  STREAM-SENSE ( stream-event )
      held      -          >streaming
      response  RESPONDED  >drained
      short     RESPONDED  >short
      failure   BROKE      >lost
      overrun   ABANDON    >overran
      unread    ABANDON    >cancelled
   IN buffering  PULL ( read-event )
      chunk     ANSWER+    >buffering
      response  RESPONDED  >answered
      failure   BROKE      >lost
   FINAL answered  -
   FINAL drained   -
   FINAL lost      -
   FINAL cancelled -
   FINAL overran   -
   FINAL short     -
;DEFINE


\ Whether the machine is at its end, so the transfer has ended.
: FINAL? ( download-step -- bool )
   {: s:download-step :}
   s DRAINED? s CUT? or s CANCELLED? or s OVERRAN? or s SHORT? or
   s construct download-step answered DOWNLOAD-STEP-EQ or ;


\ Steps the machine once; true only when it already stood at its end.
: STEPPED ( ^fetch -- bool )
   {: f :}
   f f FETCH-STEP @ DOWNLOADING-STEP {: s:download-step end:bool :}
   s f FETCH-STEP !
   end ;


\ Copies what fits in room of the held chunk's untaken bytes to p.
: TAKEN ( ^u8 n ^fetch -- n )
   {: p:^ room:n f :}
   room f TAKING {: k:n :}
   f FETCH-HELD @ SPAN:$ STR:data f FETCH-TAKEN @ + p k BYTE-COPY
   k f FETCH-TAKEN +! k f FETCH-TOTAL +!
   k ;


: MISSIZED ( ^client -- )
   s" a body of another length" E-UNVERIFIED FAILED ;


\ A body of every byte after the offset.
: SIZED ( ^client n n -- )
   {: c at:n got:n :}
   c FILE-SIZE at - got <> if c MISSIZED then ;


public

\ At most room of the body's next bytes into p, 0 at its end; each read
\ steps the machine, again while it pulls an empty chunk. A lost transfer
\ throws E-BODY-LOST; a body of another length logs and throws
\ E-UNVERIFIED at the read that meets it, and every later read throws it
\ too, never answering 0.
: READ-BODY ( ^u8 n ^fetch -- n )
   {: p:^ room:n f :}
   f FETCH-STEP @ STREAMING? {: flight:bool :}
   room f FETCH-ROOM !
   begin f STEPPED drop f STARVED? 0= until
   f FETCH-STEP @ {: s:download-step :}
   s CUT? if E-BODY-LOST throw then
   s OVERRAN? s SHORT? or if
      flight if f FETCH-CLIENT @ MISSIZED then
      E-UNVERIFIED throw
   then
   s STREAMING? 0= if 0 exit then
   p room f TAKEN ;

private


\ Hands body the offset, the file's size and the fetch, then steps the
\ machine once: a body it left unread is cancelled, and nothing after
\ that throws.
: BODIED ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ c FILE-SIZE f body execute
   true f FETCH-RETURNED !
   f STEPPED drop ;


\ Steps the machine from opened: once the checks pass, body reads the
\ body; otherwise the machine steps to its end.
: DRIVEN ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f STEPPED drop
   f FETCH-STEP @ STREAMING? if f body BODIED exit then
   begin f STEPPED until ;


\ Sends the request and reads it through DOWNLOADING under READ-OUT.
: RECEIVING ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ STARTED {: h :}
   h f FETCH-CONN !
   h [: f body DRIVEN ;] [: f FETCH-STEP @ FINAL? ;] READ-OUT ;


\ RECEIVING, where the reader's E-BODY-LOST ends: the machine is lost.
: ABSORBED ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   [: f body RECEIVING ;] catch {: code:n :}
   code 0= if exit then
   code E-BODY-LOST <> if code throw then ;


\ A seed's typed drop, which types the classification that replaces it.
: DROP-VERDICT ( verdict -- ) drop ;


\ A 206 is a download's done too; RANGED checks it was asked for.
: SORTED ( ^client -- verdict )
   {: c :}
   c CLIENT-STATUS @ 206 = if construct reply done ANSWER exit then
   construct verdict rejected [: DROP-VERDICT c CLASSIFY ;] VERIFIED ;


\ A done answer no chunk came with: the rev, content hash and range
\ asked and an empty body; body reads it from the fetch, at its end.
: EMPTIED ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ {: at:n :}
   c f REV-HASH at CHECKED
   c at 0 SIZED
   at c FILE-SIZE f body execute ;


\ A 416 from offset 0, where no Range was sent.
: UNSATISFIABLE ( ^fetch -- reply )
   FETCH-CLIENT @ s" a range it cannot satisfy from 0" E-UNVERIFIED FAILED ;


\ An answer that arrived with no chunk handed to body. A 416 carries no
\ Dropbox-API-Result (RangeUnsatisfiable in dropbox.rs); unsat answers it.
: ARRIVED ( ^fetch [ n n ^fetch -- ] [ ^fetch -- reply ] -- verdict )
   {: f body unsat :}
   f FETCH-CLIENT @ {: c :}
   c CLIENT-STATUS @ 416 = if f unsat execute ANSWER exit then
   c SORTED {: v:verdict :}
   v MATCH verdict
      answer OF DONE? if f body EMPTIED then ENDOF
      rejected OF ENDOF
   ;MATCH
   v ;


\ A body of another length was logged as READ-BODY met it; status 0, a
\ lost transfer, is the core's; a body unread or read to its end is done.
: SETTLED ( ^fetch [ n n ^fetch -- ] [ ^fetch -- reply ] -- verdict )
   {: f body unsat :}
   f body ABSORBED
   f FETCH-CLIENT @ {: c :}
   f FETCH-STEP @ {: s:download-step :}
   s OVERRAN? s SHORT? or if E-UNVERIFIED throw then
   c CLIENT-STATUS @ 0= if c LOST ANSWER exit then
   s CANCELLED? s DRAINED? or if construct reply done ANSWER exit then
   f body unsat ARRIVED ;


\ The fetch is made before the transfer starts and lives until the call
\ answers, so nothing allocates in flight but what READ-OUT covers.
: FETCHED
   ( ^client rev hash n [ n n ^fetch -- ] [ ^fetch -- reply ] -- verdict )
   {: c v:rev h:hash at:n body unsat :}
   FETCHES-NEW {: f :}
   c f FETCH-CLIENT !
   v f FETCH-REV ! h f FETCH-CONTENT-HASH !
   at f FETCH-OFFSET !
   construct download-step opened f FETCH-STEP !
   [: f body unsat SETTLED ;] [: f FETCHES-RELEASE ;] finally ;


\ files/download from the offset; unsat answers a 416.
: FROM
   ( rev hash n ^client [ n n ^fetch -- ] [ ^fetch -- reply ] -- reply )
   {: v:rev h:hash at:n c body unsat :}
   c c CLIENT-CONTENT-CONN s" files/download"
   [: v REV>STR at ASKED ;] [: v h at body unsat FETCHED ;] CALL-AT ;


\ files/download from offset 0.
: AFRESH ( ^client rev hash [ n n ^fetch -- ] -- reply )
   {: c v:rev h:hash body :}
   v h 0 c body [: UNSATISFIABLE ;] FROM ;


\ The Content-Range of a 416 whose length is the offset, in the line.
: LENGTH-LINE ( ^client n -- str )
   {: c at:n :}
   c LINE-CLEAR c s" bytes */" LINE+ c at INT+
   c LINE$ ;


\ A 416 whose length is the offset is done, body reading a fetch at its
\ end and ENTRY not this answer's; any other starts over from 0.
: RESUMED ( ^fetch [ n n ^fetch -- ] -- reply )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ {: at:n :}
   c s" Content-Range" HEADER$ c at LENGTH-LINE STR:=
   0= if c f FETCH-REV @ f FETCH-CONTENT-HASH @ body AFRESH exit then
   at at f body execute
   construct reply done ;


\ A seed's typed drop, which types the download that replaces it.
: DROP-REPLY ( reply -- ) drop ;


\ files/download from the offset: from 0 afresh, else through RESUMED.
: REQUESTED ( rev hash n ^client [ n n ^fetch -- ] -- reply )
   {: v:rev h:hash at:n c body :}
   at 0= if c v h body AFRESH exit then
   v h at c body [: body RESUMED ;] FROM ;


\ Disposes buf unless it is null, a buffer OPEN never made: the arena
\ zeroes the record.
: DISCARD ( ^n -- )
   {: buf :}
   buf NULL-PTR = if exit then
   buf BUF:DISPOSE ;


\ The buffers and vectors BUFFERED made, before a throw part-way or after
\ them all.
: UNBUFFERED ( ^client -- )
   {: c :}
   c CLIENT-TOKEN @ DISCARD
   c CLIENT-ACCESS @ DISCARD
   c CLIENT-BODY @ VEC:DELETE
   c CLIENT-LINE @ VEC:DELETE
   c CLIENT-ANSWER @ DISCARD
   c CLIENT-VALUES @ VEC:DELETE
   c CLIENT-SENT @ DISCARD
   c CLIENT-MARK @ DISCARD ;


\ What OPEN keeps in c. A throw part-way disposes the buffers made and
\ goes on; the rest, the connections' rooms included, is the arena's.
: FILLED ( ^client ^config ^ARENA:arena -- )
   {: c cfg ar :}
   [: c ar BUFFERED
      c cfg ar CONFIGURED
      c cfg DROPBOX-CONFIG:ROOT @ SPAN:$ ar ROOT-LINE c CLIENT-ROOT-LINE !
      c ar ORIGIN-CONNS ;] catch {: code:n :}
   code 0= if exit then
   c UNBUFFERED
   code throw ;


public

\ Sets the three origins to Dropbox's.
: PRODUCTION ( ^config -- )
   {: cfg :}
   s" https://api.dropboxapi.com" str> SPAN:MAKE cfg DROPBOX-CONFIG:API !
   s" https://content.dropboxapi.com" str> SPAN:MAKE
   cfg DROPBOX-CONFIG:CONTENT !
   s" https://notify.dropboxapi.com" str> SPAN:MAKE
   cfg DROPBOX-CONFIG:NOTIFY ! ;


: OPEN ( ^config ^ARENA:arena -- ^client )
   {: cfg ar :}
   ar CLIENTS-NEW {: c :}
   c cfg ar FILLED
   c ;


\ Closes the api and content connections; the next call on either dials
\ again. The long poll's stays.
: REST ( ^client -- )
   {: c :}
   c CLIENT-API-CONN HTTPC:CLOSE
   c CLIENT-CONTENT-CONN HTTPC:CLOSE ;

: CLOSE ( ^client -- )
   {: c :}
   c REST
   c CLIENT-NOTIFY-CONN HTTPC:CLOSE
   c CLIENT-CURSOR JSON:READ-DISPOSE
   c UNBUFFERED ;


\ users/get_current_account
: ACCOUNT ( ^client -- reply )
   {: c :}
   c s" users/get_current_account" [: NO-BODY ;] CALL
   c [: ACCOUNT-READ ;] ANSWERED ;


: ACCOUNT-ID ( ^client -- str ) CLIENT-ACCOUNT @ SPAN:$ ;
\ Empty under a root_info tag other than user or team: a root no binding
\ may take.
: ROOT-NAMESPACE ( ^client -- str ) CLIENT-NAMESPACE @ SPAN:$ ;


private

\ files/get_metadata of the path, a deleted entry included as d says.
: METADATA-WITH ( str bool ^client -- reply )
   {: p d:bool c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" include_deleted" d JSON:WRITE-FIELD-BOOL
   JSON:WRITE-OBJECT-END JSON:CLOSE
   c s" files/get_metadata" [: JSON-BODY ;] CALL
   c [: ENTRY-READ ;] ANSWERED p c PLACED ;

public

\ files/get_metadata of the path, a deleted entry included.
: METADATA ( str ^client -- reply ) true swap METADATA-WITH ;


: ENTRY ( ^client -- ^entry ) CLIENT-ENTRY ;

\ The status of the last call's answer, 0 when none came or a token request
\ answered last; an E-STATUS or E-BAD-REQUEST call leaves its own.
: HTTP-STATUS ( ^client -- n )
   {: c :}
   c CLIENT-QUIET @ if 0 exit then
   c CLIENT-STATUS @ ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

private

\ transport.rs LONG_POLL_SLACK_SECONDS and LONG_POLL_GRACE_SECONDS: the
\ slack Dropbox documents past a long poll's timeout, and ours past that.
90 constant SLACK
105 constant GRACE

\ The bits of got: a page needs entries, cursor and has_more, a long poll's
\ answer changes; other marks a probed page's entry not at the path.
1 constant GOT-ENTRIES
2 constant GOT-CURSOR
4 constant GOT-MORE
7 constant GOT-PAGE
8 constant GOT-OTHER
1 constant GOT-CHANGES


: GOT ( ^client n -- )
   {: c bit:n :}
   c CLIENT-GOT @ bit or c CLIENT-GOT ! ;


\ Each object of the array that opens next, read by `entry` once opened.
: ENTRIES ( JSON:reader ^client [ JSON:reader ^client -- JSON:reader ] -- JSON:reader )
   {: c entry :}
   VALUE JSON:T-ARR <> if E-ANSWER throw then
   begin VALUE dup JSON:T-OBJ = while
      drop c entry execute
   repeat
   JSON:T-ARR-END <> if E-ANSWER throw then ;


\ A listing's entry needs both its paths; a file Dropbox described
\ incompletely is handed as it is.
: LISTED ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c TAGGED-OBJECT
   c CLIENT-ENTRY PATHS? 0= if
      c s" Dropbox listing contained an invalid or out-of-root path"
      E-UNUSABLE FAILED
   then ;


: PAGE-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" entries" JSON:READ-STR-EQ? if
      c [: LISTED ;] ENTRIES c GOT-ENTRIES GOT exit
   then
   s" cursor" JSON:READ-STR-EQ? if
      c STRING c CLIENT-PAGE ! c GOT-CURSOR GOT exit
   then
   s" has_more" JSON:READ-STR-EQ? 0= if SKIP exit then
   BOOLEAN c CLIENT-MORE ! c GOT-MORE GOT ;


\ Reads a page and checks it has entries, cursor and has_more.
: PAGE-PARSE ( ^client -- )
   {: c :}
   0 c CLIENT-GOT ! EMPTY c CLIENT-PAGE ! false c CLIENT-MORE !
   c [: PAGE-MEMBER ;] PARSE
   c CLIENT-GOT @ GOT-PAGE <>
   if c s" no entries, cursor or has_more" E-ANSWER FAILED then ;


\ Whether the page's cursor is the one sent.
: STALE? ( ^client -- bool )
   {: c :}
   c CLIENT-PAGE @ SPAN:$ c CLIENT-SENT @ BUF$ STR:= ;


\ Reads and checks a page; one with more whose cursor is the one sent
\ would list the same page forever.
: PAGE-READ ( ^client -- )
   {: c :}
   c PAGE-PARSE
   c CLIENT-MORE @ 0= if exit then
   c STALE? if c s" a cursor that did not advance" E-UNUSABLE FAILED then ;


: HANDED ( JSON:reader ^client [ ^entry -- ] -- JSON:reader )
   {: c each :}
   c TAGGED-OBJECT
   c CLIENT-ENTRY each execute ;


: HAND-MEMBER ( JSON:reader ^client [ ^entry -- ] -- JSON:reader )
   {: c each :}
   s" entries" JSON:READ-STR-EQ? 0= if SKIP exit then
   c [: each HANDED ;] ENTRIES ;


\ A done page: checked whole, its cursor kept in sent, then read again to
\ hand its entries on outside PARSE, so a throw of each stays its own;
\ true when another page follows.
: TURN ( ^client [ ^entry -- ] -- bool )
   {: c each :}
   c PAGE-READ
   c CLIENT-PAGE @ SPAN:$ str> BUF:N>BLEN c CLIENT-SENT @ BUF:REPLACE
   c [: each HAND-MEMBER ;] READ-ANSWER drop
   c CLIENT-MORE @ ;


: CONTINUE ( ^client -- reply )
   {: c :}
   c CLIENT-SENT @ BUF$ {: k :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" cursor" k JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:CLOSE
   c s" files/list_folder/continue" [: JSON-BODY ;] CALL ;


\ One page of a listing: the reply and true when it ends the listing,
\ else the next page's reply and false.
: PAGE-STEP ( reply ^client [ ^entry -- ] -- reply bool )
   {: r:reply c each :}
   r DONE? 0= if r true exit then
   c each TURN 0= if r true exit then
   c CONTINUE false ;


\ Every page from the first page's reply; done keeps the last cursor.
: PAGES ( reply ^client [ ^entry -- ] -- reply )
   {: c each :}
   begin c each PAGE-STEP until
   {: r:reply :}
   r DONE? if
      c CLIENT-SENT @ BUF$ str> BUF:N>BLEN c CLIENT-MARK @ BUF:REPLACE
   then
   r ;


: LIST-BODY ( str ^client -- )
   {: p c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" recursive" true JSON:WRITE-FIELD-BOOL JSON:WRITE-COMMA
   s" include_deleted" false JSON:WRITE-FIELD-BOOL
   JSON:WRITE-OBJECT-END JSON:CLOSE ;


: PROBE-BODY ( str ^client -- )
   {: p c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" recursive" false JSON:WRITE-FIELD-BOOL JSON:WRITE-COMMA
   s" include_deleted" false JSON:WRITE-FIELD-BOOL JSON:WRITE-COMMA
   s" limit" 1 JSON:WRITE-FIELD-INT
   JSON:WRITE-OBJECT-END JSON:CLOSE ;


\ Marks the page when the entry just handed on is not at t.
: OTHER ( str ^client -- )
   {: t c :}
   t c AT? if exit then
   c GOT-OTHER GOT ;


\ Whether the page read last shows an entry not at t.
: OCCUPIED? ( str ^client -- bool )
   {: t c :}
   c [: [: drop t c OTHER ;] HAND-MEMBER ;] READ-ANSWER drop
   c CLIENT-GOT @ GOT-OTHER and 0<> ;


\ One page of the probe of t from its reply, next true for a continue
\ page: the reply, the probe, and true while a later page decides it.
: PROBE-STEP ( reply str ^client bool -- reply probe bool )
   {: r:reply t c next:bool :}
   r DONE? 0= if r construct probe empty false exit then
   c PAGE-PARSE
   next c STALE? and if r construct probe interrupted false exit then
   c CLIENT-PAGE @ SPAN:$ str> BUF:N>BLEN c CLIENT-SENT @ BUF:REPLACE
   t c OCCUPIED? if r construct probe occupied false exit then
   c CLIENT-MORE @ 0= if r construct probe empty false exit then
   c CONTINUE construct probe empty true ;


: POLL-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" changes" JSON:READ-STR-EQ? if
      BOOLEAN c CLIENT-CHANGES ! c GOT-CHANGES GOT exit
   then
   s" backoff" JSON:READ-STR-EQ? 0= if SKIP exit then
   INT c CLIENT-BACKOFF ! ;


: POLL-READ ( ^client -- )
   {: c :}
   0 c CLIENT-GOT ! false c CLIENT-CHANGES ! 0 c CLIENT-BACKOFF !
   c [: POLL-MEMBER ;] PARSE
   c CLIENT-GOT @ GOT-CHANGES <> if c s" no changes" E-ANSWER FAILED then ;


: POLL-BODY ( str n ^client -- )
   {: k secs:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" cursor" k JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" timeout" secs JSON:WRITE-FIELD-INT
   JSON:WRITE-OBJECT-END JSON:CLOSE ;


\ Whether NEXT-UNLESS's descriptor ended the client's last call.
: WOKEN? ( ^client -- bool )
   CLIENT-FAILURE @ MATCH option
      none OF false ENDOF
      some OF HTTPC-FAULT:WOKEN HTTPC-FAULT:EQ ENDOF
   ;MATCH ;


\ The body is silent until Dropbox answers, so only the whole call is
\ bounded: the timeout asked for, Dropbox's slack and ours. None when w
\ was readable first: the transfer is hung up, never classified.
: LONG-POLL ( option<fd> ^client n -- option<verdict> )
   {: w:option<fd> c secs:n :}
   s" files/list_folder/longpoll" str> SPAN:MAKE c CLIENT-ROUTE !
   false c CLIENT-QUIET !
   c LINE-CLEAR c s" /2/files/list_folder/longpoll" LINE+
   c c CLIENT-NOTIFY-CONN PREPARE {: h :}
   h secs SLACK + GRACE + 1000 * 0 HTTPC:DEADLINES!
   h c JSON-BODY
   w c TRANSFER
   c WOKEN? if OPTION:NONE exit then
   c CLASSIFY OPTION:SOME ;


: POLL-REPLY ( verdict ^client -- reply )
   {: v:verdict c :}
   v MATCH verdict
      answer OF ENDOF
      rejected OF c s" a long poll refused a token" E-AUTH FAILED ENDOF
   ;MATCH
   c [: POLL-READ ;] ANSWERED ;

public

\ files/list_folder of the path, recursive, and every page after it.
: LIST ( str ^client [ ^entry -- ] -- reply )
   {: p c each :}
   c CLIENT-SENT @ BUF:CLEAR
   p c LIST-BODY
   c s" files/list_folder" [: JSON-BODY ;] CALL
   c each PAGES ;


\ files/list_folder of the path, one entry a page, until a page shows an
\ entry not at the path or ends the listing; any reply but done answers
\ itself, empty as filler. The listing's cursor stays.
: PROBE ( str ^client -- reply probe )
   {: p c :}
   p c PROBE-BODY
   c s" files/list_folder" [: JSON-BODY ;] CALL
   p c false PROBE-STEP
   begin while drop p c true PROBE-STEP repeat ;


\ files/list_folder/continue from the cursor, deleted entries included.
: CHANGES ( str ^client [ ^entry -- ] -- reply )
   {: k c each :}
   k str> BUF:N>BLEN c CLIENT-SENT @ BUF:REPLACE
   c CONTINUE c each PAGES ;


: CURSOR ( ^client -- str ) CLIENT-MARK @ BUF$ ;


\ files/list_folder/longpoll on the cursor for at most secs seconds. None
\ when the descriptor given was readable before Dropbox answered: the poll
\ is hung up, nothing logged, and the next WAIT dials again.
: WAIT ( str n option<fd> ^client -- option<reply> )
   {: k secs:n w:option<fd> c :}
   k secs c POLL-BODY
   w c secs LONG-POLL MATCH option
      none OF OPTION:NONE ENDOF
      some OF c POLL-REPLY OPTION:SOME ENDOF
   ;MATCH ;


: CHANGED? ( ^client -- bool ) CLIENT-CHANGES @ ;
\ Seconds Dropbox asks to wait before the next long poll, 0 for none.
: BACKOFF ( ^client -- n ) CLIENT-BACKOFF @ ;


\ ---- files/download

\ files/download of rev:<rev>, that exact revision, from the offset;
\ body reads an answer that passed its checks through READ-BODY.
: DOWNLOAD ( rev hash n ^client [ n n ^fetch -- ] -- reply )
   {: v:rev h:hash at:n c body :}
   construct reply done
   [: DROP-REPLY v h at c body REQUESTED ;] catch
   {: code:n :}
   code 0= if exit then
   drop
   code E-UNVERIFIED <> if code throw then
   construct error unverified construct reply refused ;

\ ---- delete_v2, create_folder_v2 and the code exchange
private

\ delete_v2 and create_folder_v2 answer the entry as `metadata`: delete_v2
\ a Metadata union, create_folder_v2 a plain FolderMetadata. The entry
\ opens at deleted, so an answer with no `metadata` fails.
: DELETED-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" metadata" JSON:READ-STR-EQ? 0= if SKIP exit then
   VALUE OBJECT c TAGGED-OBJECT ;


: MADE-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" metadata" JSON:READ-STR-EQ? 0= if SKIP exit then
   VALUE OBJECT c construct kind folder PLAIN-OBJECT ;


\ Each reads the answer's entry and answers whether it is at the path;
\ DELETED-READ, given a rev, also whether it is a file at that rev.
: DELETED-READ ( str str ^client -- bool )
   {: p r c :}
   c construct kind deleted [: DELETED-MEMBER ;] ENTRY-PARSE
   p c AT? 0= if false exit then
   r STR:len 0= if true exit then
   c CLIENT-ENTRY {: e :}
   e FILE? e DROPBOX-ENTRY:REV @ SPAN:$ r STR:= and ;


: MADE-READ ( str ^client -- bool )
   {: p c :}
   c construct kind deleted [: MADE-MEMBER ;] ENTRY-PARSE
   p c AT? ;


: MISMATCH? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF construct error path-mismatch DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


: UNLINKED? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF true ENDOF
   ;MATCH ;


\ An answer that asks to wait, 0 ms or more.
: RETRY? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop true ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ The path is absent, as a delete intends: done, with the entry cleared,
\ as Dropbox holds none.
: ABSENT ( ^client -- reply )
   CLIENT-ENTRY ENTRY-CLEAR construct reply done ;


\ not-found is done: Dropbox holds nothing at the path.
: DELETE-REFUSED ( error ^client -- reply )
   {: e:error c :}
   e construct error not-found DROPBOX-ERROR:EQ if c ABSENT exit then
   e construct reply refused ;


: UNVERIFIED ( -- reply )
   construct error unverified construct reply refused ;


\ Whether `read` finds the intended entry; an answer that does not parse or
\ is incomplete, which it logged, is not. Other codes go on.
: INTENDED? ( ^client [ ^client -- bool ] -- bool )
   {: c read :}
   false [: drop c read execute ;] catch {: code:n :}
   code 0= if exit then
   drop code BAD-ANSWER? 0= if code throw then
   false ;


\ done stands if `read` finds its intended entry at the path, else
\ unverified, as is any answer UNSURE? flags; a refusal goes to `refusal`.
: MUTATE ( ^client str [ ^client -- bool ]
           [ error ^client -- reply ] -- reply )
   {: c rt read refusal :}
   c rt [: JSON-BODY ;] CALL {: r:reply :}
   r c UNSURE? if UNVERIFIED exit then
   r MATCH reply
      done OF
         c read INTENDED?
         if construct reply done else UNVERIFIED then
      ENDOF
      refused OF c refusal execute ENDOF
      retry OF RETRY ENDOF
      unlinked OF construct reply unlinked ENDOF
   ;MATCH ;


: DELETE-BODY ( str str ^client -- )
   {: p r c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p JSON:WRITE-FIELD-S
   r STR:len 0<> if
      JSON:WRITE-COMMA s" parent_rev" r JSON:WRITE-FIELD-S
   then
   JSON:WRITE-OBJECT-END JSON:CLOSE ;


: FOLDER-BODY ( str ^client -- )
   {: p c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" autorename" false JSON:WRITE-FIELD-BOOL
   JSON:WRITE-OBJECT-END JSON:CLOSE ;


\ The code grant's form body, in the line vector as FORM's is.
: CODE-FORM ( str str ^client -- str )
   {: k v c :}
   c CLIENT-LINE @ {: buf :}
   buf 0 VEC:RESIZE
   s" grant_type=authorization_code&code=" buf BYTES+
   k buf ENCODED+
   s" &code_verifier=" buf BYTES+
   v buf ENCODED+
   s" &client_id=" buf BYTES+
   c CLIENT-KEY @ SPAN:$ buf ENCODED+
   buf BYTES$ ;


\ An exchange's tokens, both kept only when both came.
: KEPT-GRANT ( ^client -- reply )
   {: c :}
   EMPTY c CLIENT-ISSUED ! EMPTY c CLIENT-GRANTED !
   c [: GRANTED-MEMBER ;] PARSE
   c CLIENT-GRANTED @ SPAN:LEN 0=
   if c s" no refresh_token" E-ANSWER FAILED then
   c CLIENT-ISSUED @ SPAN:LEN 0=
   if c s" no access_token" E-ANSWER FAILED then
   c CLIENT-GRANTED @ c CLIENT-TOKEN @ REPLACED
   c CLIENT-ISSUED @ c CLIENT-ACCESS @ REPLACED
   construct phase ready c CLIENT-PHASE !
   construct reply done ;

public

\ files/delete_v2, conditional on the rev unless it is empty.
: DELETE ( str str ^client -- reply )
   {: p r c :}
   p r c DELETE-BODY
   c s" files/delete_v2" [: drop p r c DELETED-READ ;]
   [: DELETE-REFUSED ;] MUTATE ;


\ files/create_folder_v2, which never renames.
: CREATE-FOLDER ( str ^client -- reply )
   {: p c :}
   p c FOLDER-BODY
   c s" files/create_folder_v2" [: drop p c MADE-READ ;]
   [: drop construct reply refused ;] MUTATE ;


\ oauth2/token's authorization_code grant of the code and its PKCE
\ verifier; unlinked means the code is dead.
: EXCHANGE ( str str ^client -- reply )
   {: k v c :}
   c [: drop k v c CODE-FORM ;] TOKEN-POST
   c [: KEPT-GRANT ;] [: drop construct reply unlinked ;] REFRESHED ;


\ The refresh token: the config's, or the one an EXCHANGE kept.
: REFRESH-TOKEN ( ^client -- str ) CLIENT-TOKEN @ BUF$ ;


\ ---- linking a login

private

$2F constant SEPARATOR

\ Rust's invalid_dropbox_component: empty, . or .., or holding a NUL.
: INVALID-COMPONENT? ( str -- bool )
   {: p :}
   p STR:len 0= if true exit then
   p s" ." STR:= p s" .." STR:= or if true exit then
   p 0 STR:COUNT-CHAR 0<> ;

\ Whether the separated part from at is invalid; the index after it,
\ or -1 past the last.
: PART-INVALID ( str n -- bool n )
   {: p at:n :}
   p SEPARATOR at STR:SPLIT-NEXT 0= if drop drop false -1 exit then
   {: s next:n :}
   s INVALID-COMPONENT? next ;

public

-100011
   s" configured Dropbox root must be empty or a normalized absolute Dropbox path"
   ERROR:CODE E-ROOT-PATH

\ Whether any part of split('/') is invalid; the empty bytes are one
\ empty part.
: INVALID-PARTS? ( str -- bool )
   {: p :}
   0 begin dup 0 >= while
      p swap PART-INVALID swap if drop true exit then
   repeat drop false ;

\ Rust's DropboxRoot::is_valid_path, valid UTF-8 as a Rust string is.
: ROOT-PATH? ( str -- bool )
   {: s :}
   s str> {: p:^ u:n :}
   u 0= if true exit then
   s UTF8:VALID? 0= if false exit then
   p c@ SEPARATOR <> if false exit then
   p u + 1- c@ SEPARATOR = if false exit then
   p 1+ u 1- >str INVALID-PARTS? 0= ;

\ What checking a remote root found. failed carries the reply of a call
\ that did not answer done; unbound: root_info neither user nor team.
ENUM root-check
   VARIANT valid ;VARIANT
   VARIANT failed FIELD r reply ;VARIANT
   VARIANT unbound ;VARIANT
   VARIANT unavailable ;VARIANT
   VARIANT not-folder ;VARIANT
   VARIANT restricted ;VARIANT
;ENUM

private

\ The root's entry as Rust's validate_remote_root judges it: a folder,
\ unless folder_restricted, a sharing_info of no_access or traverse_only.
: ENTRY-CHECK ( ^entry -- root-check )
   {: e :}
   e DROPBOX-ENTRY:KIND @ construct kind folder DROPBOX-KIND:EQ 0= if
      construct root-check not-folder exit
   then
   e DROPBOX-ENTRY:RESTRICTED @ if construct root-check restricted exit then
   construct root-check valid ;

\ One line with Rust's InvalidRootPath text, then E-ROOT-PATH.
: ROOT-REFUSED ( -- )
   LOG-OPEN E-ROOT-PATH ERROR:TEXT$ LOG:TEXT+ LOG:;LINE
   E-ROOT-PATH throw ;

public

\ Appends c's last call to the open log line: its route, then the status
\ Dropbox answered and the error's tag, or that it got no answer and why.
: LAST-CALL+ ( ^client -- )
   {: c :}
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+
   c CLIENT-STATUS @ {: s:n :}
   s 0= if
      s"  got no answer" LOG:TEXT+
      c CLIENT-FAILURE @ MATCH option
         some OF s" : " LOG:TEXT+ HTTPC:FAULT$ LOG:TEXT+ ENDOF
         none OF ENDOF
      ;MATCH
   else
      s"  answered " LOG:TEXT+ s LOG:INT+
      c TAG$ STR:len 0<> if s" : " LOG:TEXT+ c LEAF$ LOG:TEXT+ then
   then ;

\ Whether the client's last call's transfer ended with an HTTP
\ status; one cut after the head did not.
: ANSWERED? ( ^client -- bool ) CLIENT-STATUS @ 0<> ;

private

\ Rust's "Dropbox operation `op` failed" line, then c's last call.
: OP-FAILED ( ^client str -- )
   {: c op :}
   LOG-OPEN s" Dropbox operation `" LOG:TEXT+ op LOG:TEXT+
   s" ` failed: " LOG:TEXT+ c LAST-CALL+ LOG:;LINE ;

public

\ Rust's validate_remote_root under the client's Path-Root, asking for no
\ deleted entry. An empty p needs no call; another path_lower is unavailable.
: CHECK-ROOT ( str ^client -- root-check )
   {: p c :}
   p STR:len 0= if construct root-check valid exit then
   p false c METADATA-WITH {: r:reply :}
   r MISMATCH? if construct root-check unavailable exit then
   r DONE? 0= if
      c s" validate configured Dropbox root" OP-FAILED
      r construct root-check failed exit
   then
   c CLIENT-ENTRY ENTRY-CHECK ;

\ Rust's link_inner with no expected account; the client's Path-Root line
\ must be empty. After valid the binding lives in ar and roots the client.
: LINK ( str ^client ^ARENA:arena -- root-check )
   {: p c ar :}
   p ROOT-PATH? 0= if ROOT-REFUSED then
   c ACCOUNT {: r:reply :}
   r DONE? 0= if
      c s" inspect authorized Dropbox account" OP-FAILED
      r construct root-check failed exit
   then
   c CLIENT-NAMESPACE @ SPAN:LEN 0= if construct root-check unbound exit then
   c CLIENT-ACCOUNT @ SPAN:$ ar KEEP c CLIENT-ACCOUNT !
   c CLIENT-NAMESPACE @ SPAN:$ ar KEEP c CLIENT-NAMESPACE !
   c c ROOT-NAMESPACE ar ROOT-LINE c CLIENT-ROOT-LINE !
   p c CHECK-ROOT ;


\ ---- files/upload and upload sessions

\ A file up to CHUNK-SIZE bytes goes in one files/upload; a larger one
\ through an upload session: CHUNK-SIZE appends, then a finish that carries
\ no content_hash, as Dropbox checks that field against the call's own
\ bytes. A call Dropbox may have applied, or a 2xx answer that is not the
\ upload's complete entry at its path with its content hash, is refused
\ unverified, but an append is resent once; a conflict is answered as
\ refused. A run's chunk buffer is MEM's and SEND writes it in place: it
\ is refilled and released only between calls, each transfer ended, before
\ UPLOAD answers or throws.

public

-100006 s" the upload's stage could not be read whole" ERROR:CODE E-STAGE

\ fd is the verified stage, read from 0; content-hash its Dropbox
\ content hash; rev empty to add only while the path is absent.
STRUCTURE upload DERIVE addr
   FIELD fd fd
   FIELD size n
   FIELD content-hash SPAN:span<u8>
   FIELD path SPAN:span<u8>
   FIELD rev SPAN:span<u8>
;STRUCTURE

private

\ Room held inline in a record and read as bytes: a STRUCTURE field holds
\ values, not a byte array, so these lay the cells out.
STRUCTURE cells8 DERIVE addr
   FIELD c0 n FIELD c1 n FIELD c2 n FIELD c3 n
   FIELD c4 n FIELD c5 n FIELD c6 n FIELD c7 n
;STRUCTURE

STRUCTURE cells64 DERIVE addr
   FIELD c0 cells8 FIELD c1 cells8 FIELD c2 cells8 FIELD c3 cells8
   FIELD c4 cells8 FIELD c5 cells8 FIELD c6 cells8 FIELD c7 cells8
;STRUCTURE

STRUCTURE sha-room DERIVE addr
   FIELD a cells64 FIELD b cells8 FIELD c cells8
   FIELD d cells8 FIELD e cells8 FIELD f cells8
;STRUCTURE

CAST: CELLS8>BYTES ( ^cells8 -- ^u8 )
CAST: CELLS64>BYTES ( ^cells64 -- ^u8 )
CAST: ROOM>BYTES ( ^sha-room -- ^u8 )

public

\ Dropbox's content hash: SHA-256 over the joined SHA-256 digests of each
\ 4 MiB block. fill counts the bytes of the block being hashed.
STRUCTURE hasher OPAQUE DERIVE addr
   FIELD fill n
   FIELD block sha-room
   FIELD whole sha-room
   FIELD digest cells8
   FIELD hex cells8
;STRUCTURE

\ A content-hash block's bytes.
$400000 constant BLOCK

private

$2000000 constant CHUNK-SIZE
512 constant ID-CAP

TYPED-VARIABLE ROOM-PROBE sha-room
TYPED-VARIABLE ID-PROBE cells64


\ The rooms are laid out by hand, so the load checks they hold enough.
: ROOMS-FIT ( -- )
   ROOM-PROBE SHA-ROOM-BYTES nip SHA256-CTX-BYTES <
   ID-PROBE CELLS64-BYTES nip ID-CAP < or
   if s" dropbox: a room is smaller than it holds" 70 die then ;
ROOMS-FIT


: BLOCK$ ( ^hasher -- ^u8 ) HASHER-BLOCK ROOM>BYTES ;
: WHOLE$ ( ^hasher -- ^u8 ) HASHER-WHOLE ROOM>BYTES ;
: DIGEST$ ( ^hasher -- ^u8 ) HASHER-DIGEST CELLS8>BYTES ;
: HEX$ ( ^hasher -- ^u8 ) HASHER-HEX CELLS8>BYTES ;


\ Ends the block, feeds its digest to the whole and starts the next.
: BLOCK-END ( ^hasher -- )
   {: h :}
   h BLOCK$ h DIGEST$ SHA256-END
   h WHOLE$ h DIGEST$ 32 >str SHA256-FEED
   h BLOCK$ SHA256-BEGIN
   0 h HASHER-FILL ! ;


\ Feeds what fits in the block; answers the bytes it took.
: BLOCK-FEED ( ^u8 n ^hasher -- n )
   {: a:^ u:n h :}
   BLOCK h HASHER-FILL @ - u min {: k:n :}
   h BLOCK$ a k >str SHA256-FEED
   k h HASHER-FILL +!
   h HASHER-FILL @ BLOCK = if h BLOCK-END then
   k ;


\ Feeds the bytes past done; answers done with the bytes taken added.
: FEED-PAST ( ^u8 n n ^hasher -- n )
   {: a:^ u:n done:n h :}
   a done + u done - h BLOCK-FEED done + ;

public

: HASH-BEGIN ( ^hasher -- )
   {: h :}
   0 h HASHER-FILL !
   h BLOCK$ SHA256-BEGIN
   h WHOLE$ SHA256-BEGIN ;


: HASH-FEED ( ^u8 n ^hasher -- )
   {: a:^ u:n h :}
   0 begin dup u < while
      a u rot h FEED-PAST
   repeat drop ;


\ The 64 lowercase hex digits, held in the hasher until its next
\ HASH-BEGIN.
: HASH-END ( ^hasher -- str )
   {: h :}
   h HASHER-FILL @ 0 > if h BLOCK-END then
   h WHOLE$ h DIGEST$ SHA256-END
   h DIGEST$ h HEX$ SHA256>HEX
   h HEX$ 64 >str ;

private

\ One UPLOAD, the machine's context: up and client the call's; last the
\ reply of the last call; answer what UPLOAD answers; buf the chunk buffer
\ of cap bytes, held unless a read owns it; accepted the bytes Dropbox
\ took, shown the count last reported; chunk the bytes read there; id the
\ session's id of id-u bytes; resent and restarted the one resend of a
\ chunk and the one restart an UPLOAD allows.
STRUCTURE run OPAQUE DERIVE addr
   FIELD up ^upload
   FIELD client ^client
   FIELD last reply
   FIELD answer reply
   FIELD buf ^u8
   FIELD cap NUM:alloc-byte-len
   FIELD held bool
   FIELD xfer AIO:xfer
   FIELD accepted n
   FIELD shown n
   FIELD chunk n
   FIELD id cells64
   FIELD id-u n
   FIELD resent bool
   FIELD restarted bool
;STRUCTURE

HEAP RUNS run


: SIZE ( ^run -- n ) RUN-UP @ DROPBOX-UPLOAD:SIZE @ ;
: CHUNK$ ( ^run -- ^u8 n ) dup RUN-BUF @ swap RUN-CHUNK @ ;
: SESSION$ ( ^run -- str )
   dup RUN-ID CELLS64>BYTES swap RUN-ID-U @ >str ;


\ ---- reading the stage

: STAGE-FAILED ( ^run str -- )
   {: r why :}
   LOG-OPEN s" upload of " LOG:TEXT+
   r RUN-UP @ DROPBOX-UPLOAD:PATH @ SPAN:$ LOG:TEXT+
   s" : " LOG:TEXT+ why LOG:TEXT+ LOG:;LINE
   E-STAGE throw ;


: READ-REFUSED ( ^run n -- )
   {: r errno:n :}
   LOG-OPEN s" upload of " LOG:TEXT+
   r RUN-UP @ DROPBOX-UPLOAD:PATH @ SPAN:$ LOG:TEXT+
   s" : the stage's read was refused, errno " LOG:TEXT+ errno LOG:INT+
   LOG:;LINE
   E-STAGE throw ;


: SUBMIT ( ^run -- ^run )
   {: r :}
   r RUN-UP @ DROPBOX-UPLOAD:FD @ r RUN-BUF @ r RUN-CAP @
   r RUN-CHUNK @ r RUN-ACCEPTED @ AIO:READ r RUN-XFER !
   r ;


\ A read owns the buffer from its submission until AWAIT-XFER gives it
\ back; E-AIO-ENTER leaves it the kernel's, which the loop releases.
: SUBMITTED ( ^run -- )
   {: r :}
   false r RUN-HELD !
   r [: SUBMIT ;] catch {: code:n :} drop
   code 0= if exit then
   code E-AIO-ENTER <> if true r RUN-HELD ! then
   code throw ;


\ Reads chunk bytes of the stage from accepted into the buffer; chunk becomes
\ the bytes read, fewer at the stage's end.
: CHUNK-READ ( ^run -- )
   {: r :}
   r RUN-CHUNK @ 0= if exit then
   r SUBMITTED
   r RUN-XFER @ AIO:AWAIT-XFER {: o:AIO:outcome :}
   r RUN-CAP ! r RUN-BUF ! true r RUN-HELD !
   o MATCH AIO:outcome
      ready OF r RUN-CHUNK ! ENDOF
      timed-out OF r s" the stage's read timed out" STAGE-FAILED ENDOF
      cancelled OF r s" the stage's read was cancelled" STAGE-FAILED ENDOF
      rejected OF r swap READ-REFUSED ENDOF
   ;MATCH ;


: SHORT ( ^run -- )
   s" the stage is shorter than its size" STAGE-FAILED ;


\ ---- the requests

: MODE+ ( ^JSON:writer ^upload -- ^JSON:writer )
   DROPBOX-UPLOAD:REV @ SPAN:$ {: v :}
   v STR:len 0= if s" mode" s" add" JSON:WRITE-FIELD-S exit then
   s" mode" JSON:WRITE-KEY JSON:WRITE-OBJECT-START
   s" .tag" s" update" JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" update" v JSON:WRITE-FIELD-S JSON:WRITE-OBJECT-END ;


\ Dropbox's CommitInfo, which the single upload's argument extends.
: COMMIT+ ( ^JSON:writer ^upload -- ^JSON:writer )
   {: up :}
   s" path" up DROPBOX-UPLOAD:PATH @ SPAN:$ JSON:WRITE-FIELD-S
   JSON:WRITE-COMMA up MODE+ JSON:WRITE-COMMA
   s" autorename" false JSON:WRITE-FIELD-BOOL JSON:WRITE-COMMA
   s" strict_conflict" true JSON:WRITE-FIELD-BOOL ;


: CURSOR+ ( ^JSON:writer ^run n -- ^JSON:writer )
   {: r at:n :}
   s" cursor" JSON:WRITE-KEY JSON:WRITE-OBJECT-START
   s" session_id" r SESSION$ JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" offset" at JSON:WRITE-FIELD-INT JSON:WRITE-OBJECT-END ;


: CLOSE+ ( ^JSON:writer -- ^JSON:writer )
   s" close" false JSON:WRITE-FIELD-BOOL ;


\ transport.rs SESSION_FINISH_SECONDS: the longest a finish, which commits
\ every appended byte, may take to answer.
3600 constant FINISH-WAIT


\ A finish sends no byte and is silent until Dropbox commits, so only the
\ whole call is bounded.
: PATIENT ( ^HTTPC:conn -- )
   FINISH-WAIT 1000 * 0 HTTPC:DEADLINES! ;


\ The argument the fields write, the bytes, and the deadlines.
: ARGUED ( ^HTTPC:conn ^client ^u8 n [ ^JSON:writer -- ^JSON:writer ] [ ^HTTPC:conn -- ] -- )
   {: h c b:^ bu:n fields deadline :}
   c BODY-OPEN JSON:WRITE-OBJECT-START fields execute
   JSON:WRITE-OBJECT-END JSON:CLOSE
   c LINE-CLEAR c s" Dropbox-API-Arg: " LINE+
   c c CLIENT-BODY @ BYTES$ LINE+
   h c LINE$ HTTPC:HEADER+
   h s" Content-Type: application/octet-stream" HTTPC:HEADER+
   b bu SPAN:MAKE c CLIENT-OUT !
   h deadline execute ;


\ A POST of the bytes to <content>/2/<route>, under the deadlines.
: SENT ( ^run str ^u8 n [ ^JSON:writer -- ^JSON:writer ] [ ^HTTPC:conn -- ] -- reply )
   {: r rt b:^ bu:n fields deadline :}
   r RUN-CLIENT @ {: c :}
   c c CLIENT-CONTENT-CONN rt
   [: b bu fields deadline ARGUED ;] [: RECEIVED ;] CALL-AT ;


: SINGLE-SENT ( ^run -- reply )
   {: r :}
   r RUN-UP @ {: up :}
   r s" files/upload" r CHUNK$
   [: up COMMIT+ JSON:WRITE-COMMA s" content_hash"
      up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ JSON:WRITE-FIELD-S ;]
   [: STALLED ;] SENT ;


: START-SENT ( ^run -- reply )
   s" files/upload_session/start" s" " str> [: CLOSE+ ;]
   [: STALLED ;] SENT ;


: APPEND-SENT ( ^run -- reply )
   {: r :}
   r s" files/upload_session/append_v2" r CHUNK$
   [: r r RUN-ACCEPTED @ CURSOR+ JSON:WRITE-COMMA CLOSE+ ;]
   [: STALLED ;] SENT ;


: FINISH-SENT ( ^run -- reply )
   {: r :}
   r s" files/upload_session/finish" s" " str>
   [: r r SIZE CURSOR+ JSON:WRITE-COMMA
      s" commit" JSON:WRITE-KEY JSON:WRITE-OBJECT-START
      r RUN-UP @ COMMIT+ JSON:WRITE-OBJECT-END ;]
   [: PATIENT ;] SENT ;


\ ---- the answers

\ Reads the entry Dropbox committed; false for an answer that does not
\ parse or an incomplete entry, which FILE-READ logged. Other codes go on.
: ANSWER-READ? ( ^run -- bool )
   {: r :}
   r RUN-CLIENT @ {: c :}
   [: c FILE-READ ;] catch {: code:n :}
   code 0= if true exit then
   code BAD-ANSWER? 0= if code throw then
   false ;


\ Whether the answer is the upload's complete entry, at its path and with
\ its content hash.
: UPLOADED? ( ^run -- bool )
   {: r :}
   r ANSWER-READ? 0= if false exit then
   r RUN-CLIENT @ {: c :}
   r RUN-UP @ {: up :}
   c CLIENT-ENTRY COMPLETE? 0= if false exit then
   up DROPBOX-UPLOAD:PATH @ SPAN:$ c AT? 0= if false exit then
   c CLIENT-ENTRY DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ STR:= ;


: REFUSAL? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF drop true ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ A session Dropbox no longer takes chunks for.
: GONE-TAG? ( str -- bool )
   {: t :}
   t s" not_found" STR:= t s" closed" STR:= or
   t s" incorrect_offset" STR:= or ;


\ incorrect_offset at the chunk's end: Dropbox already holds the chunk.
: HELD? ( reply ^run -- bool )
   {: rep:reply r :}
   rep REFUSAL? 0= if false exit then
   r RUN-CLIENT @ {: c :}
   c TAG$ s" incorrect_offset" STR:=
   c CLIENT-CORRECT @ r RUN-ACCEPTED @ r RUN-CHUNK @ + = and ;


: APPEND-GONE? ( reply ^client -- bool )
   {: rep:reply c :}
   rep REFUSAL? 0= if false exit then
   c TAG$ GONE-TAG? ;


: FINISH-GONE? ( reply ^client -- bool )
   {: rep:reply c :}
   rep REFUSAL? 0= if false exit then
   c TAG$ s" lookup_failed" STR:= c LEAF$ GONE-TAG? and ;


: SESSION-MEMBER ( JSON:reader ^client ^run -- JSON:reader )
   {: c r :}
   s" session_id" JSON:READ-STR-EQ? 0= if SKIP exit then
   c STRING SPAN:$ str> {: a:^ u:n :}
   u 0= u ID-CAP > or if E-ANSWER throw then
   a r RUN-ID CELLS64>BYTES u BYTE-COPY
   u r RUN-ID-U ! ;


: SESSION-READ ( ^run -- )
   {: r :}
   0 r RUN-ID-U !
   r RUN-CLIENT @ {: c :}
   c [: r SESSION-MEMBER ;] PARSE
   r RUN-ID-U @ 0= if c s" no session_id" E-ANSWER FAILED then ;


\ ---- the machine

ENUM upload-step
   single starting appending finishing verifying restarting ended ;ENUM
ENUM send-event committed untrusted unsure failed ;ENUM
ENUM start-event opened unsure failed ;ENUM
ENUM append-event stored complete unsure cut gone failed ;ENUM
ENUM finish-event committed untrusted unsure gone failed ;ENUM
ENUM confirm-event same elsewhere wait other unlinked ;ENUM
ENUM restart-event once twice ;ENUM


: SEND-DONE ( ^run -- send-event )
   UPLOADED? if construct send-event committed exit then
   construct send-event untrusted ;


: SEND-SENSE ( ^run -- send-event )
   {: r :}
   r SIZE r RUN-CHUNK !
   r CHUNK-READ
   r RUN-CHUNK @ r SIZE <> if r SHORT then
   r SINGLE-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r SEND-DONE exit then
   rep r RUN-CLIENT @ UNSURE? if construct send-event unsure exit then
   construct send-event failed ;


: START-SENSE ( ^run -- start-event )
   {: r :}
   r START-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r SESSION-READ construct start-event opened exit then
   rep r RUN-CLIENT @ UNSURE? if construct start-event unsure exit then
   construct start-event failed ;


: ACCEPTED ( ^run -- append-event )
   {: r :}
   r RUN-ACCEPTED @ r RUN-CHUNK @ + r SIZE =
   if construct append-event complete exit then
   construct append-event stored ;


: UNSURE-AGAIN ( ^run -- append-event )
   {: r :}
   r RUN-RESENT @ if construct append-event cut exit then
   true r RUN-RESENT !
   construct append-event unsure ;


: APPEND-SENSE ( ^run -- append-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r SIZE r RUN-ACCEPTED @ - CHUNK-SIZE min r RUN-CHUNK !
   r CHUNK-READ
   r RUN-CHUNK @ 0= if r SHORT then
   r APPEND-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r ACCEPTED exit then
   rep c UNSURE? if r UNSURE-AGAIN exit then
   rep r HELD? if r ACCEPTED exit then
   rep c APPEND-GONE? if construct append-event gone exit then
   construct append-event failed ;


: FINISH-DONE ( ^run -- finish-event )
   UPLOADED? if construct finish-event committed exit then
   construct finish-event untrusted ;


: FINISH-SENSE ( ^run -- finish-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r FINISH-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r FINISH-DONE exit then
   rep c UNSURE? if construct finish-event unsure exit then
   rep c FINISH-GONE? if construct finish-event gone exit then
   construct finish-event failed ;


\ get_metadata of the path: same for a complete file with the upload's
\ content hash; a retry it answers becomes the last reply.
: CONFIRM-SENSE ( ^run -- confirm-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r RUN-UP @ {: up :}
   up DROPBOX-UPLOAD:PATH @ SPAN:$ c METADATA {: m:reply :}
   m UNLINKED? if construct confirm-event unlinked exit then
   m MISMATCH? if construct confirm-event elsewhere exit then
   m RETRY? if m r RUN-LAST ! construct confirm-event wait exit then
   m DONE? 0= if construct confirm-event other exit then
   c CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ STR:= e COMPLETE? and
   if construct confirm-event same exit then
   construct confirm-event other ;


: RESTART-SENSE ( ^run -- restart-event )
   {: r :}
   r RUN-RESTARTED @ if construct restart-event twice exit then
   true r RUN-RESTARTED !
   construct restart-event once ;


: ANSWER-DONE ( ^run -- )
   {: r :}
   construct reply done r RUN-ANSWER !
   r SIZE r RUN-ACCEPTED ! ;


: ANSWER-UNLINKED ( ^run -- )
   {: r :}
   construct reply unlinked r RUN-ANSWER ! ;


: ANSWER-MISMATCH ( ^run -- )
   {: r :}
   construct error path-mismatch construct reply refused
   r RUN-ANSWER ! ;


: ANSWER-UNVERIFIED ( ^run -- )
   {: r :}
   UNVERIFIED r RUN-ANSWER ! ;


\ Answers the last call's reply as it came, or as CONFIRM-SENSE set it.
: ANSWER-REPLY ( ^run -- ) {: r :} r RUN-LAST @ r RUN-ANSWER ! ;


: CHUNK-ADVANCE ( ^run -- )
   {: r :}
   r RUN-CHUNK @ r RUN-ACCEPTED +!
   false r RUN-RESENT ! ;


: REWIND ( ^run -- )
   {: r :}
   0 r RUN-ACCEPTED ! false r RUN-RESENT ! ;


\ One upload, after formal/UploadSession.tla. A finish whose session is
\ gone may have been committed: verifying starts over unless get_metadata
\ shows the upload's complete entry at its path.
FSM:DEFINE SESSION ( ^run ) upload-step send-event
   IN single  SEND-SENSE
      committed  ANSWER-DONE        >ended
      untrusted  ANSWER-UNVERIFIED  >ended
      unsure     ANSWER-UNVERIFIED  >ended
      failed     ANSWER-REPLY       >ended
   IN starting  START-SENSE ( start-event )
      opened  -                  >appending
      unsure  ANSWER-UNVERIFIED  >ended
      failed  ANSWER-REPLY       >ended
   IN appending  APPEND-SENSE ( append-event )
      stored    CHUNK-ADVANCE      >appending
      complete  CHUNK-ADVANCE      >finishing
      unsure    -                  >appending
      cut       ANSWER-UNVERIFIED  >ended
      gone      -                  >restarting
      failed    ANSWER-REPLY       >ended
   IN finishing  FINISH-SENSE ( finish-event )
      committed  ANSWER-DONE        >ended
      untrusted  ANSWER-UNVERIFIED  >ended
      unsure     ANSWER-UNVERIFIED  >ended
      gone       -                  >verifying
      failed     ANSWER-REPLY       >ended
   IN verifying  CONFIRM-SENSE ( confirm-event )
      same       ANSWER-DONE      >ended
      elsewhere  ANSWER-MISMATCH  >ended
      wait       ANSWER-REPLY     >ended
      other      -                >restarting
      unlinked   ANSWER-UNLINKED  >ended
   IN restarting  RESTART-SENSE ( restart-event )
      once   REWIND             >starting
      twice  ANSWER-UNVERIFIED  >ended
   FINAL ended  -
;DEFINE


\ ---- running an upload

: RUN-INIT ( ^run ^upload ^client -- )
   {: r up c :}
   up r RUN-UP ! c r RUN-CLIENT !
   0 RETRY r RUN-LAST ! 0 RETRY r RUN-ANSWER !
   up DROPBOX-UPLOAD:SIZE @ CHUNK-SIZE min 1 max
   MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   r RUN-CAP ! r RUN-BUF ! true r RUN-HELD ! ;


: RELEASED ( ^run -- )
   {: r :}
   r RUN-HELD @ if r RUN-BUF @ r RUN-CAP @ MEM:RELEASE-BYTES then
   r RUNS-RELEASE ;


: FIRST ( ^run -- upload-step )
   SIZE CHUNK-SIZE > if construct upload-step starting exit then
   construct upload-step single ;


: SHOW ( ^run [ n -- ] -- )
   {: r progress :}
   r RUN-ACCEPTED @ {: at:n :}
   at r RUN-SHOWN @ = if exit then
   at r RUN-SHOWN !
   at progress execute ;


: DRIVE ( ^run [ n -- ] -- reply )
   {: r progress :}
   r FIRST
   begin r swap SESSION-STEP r progress SHOW until
   drop r RUN-ANSWER @ ;

public

\ files/upload of the stage, or an upload session for one over 32 MiB.
\ progress is called with the bytes Dropbox has accepted each time that
\ count changes. On done, ENTRY holds the entry Dropbox committed.
: UPLOAD ( ^upload ^client [ n -- ] -- reply )
   {: up c progress :}
   RUNS-NEW {: r :}
   [: r up c RUN-INIT r progress DRIVE ;] [: r RELEASED ;] finally ;

;package
