\ dropbox.f - package DROPBOX: the Dropbox API v2 routes omabox calls, over
\ libcurl's easy interface and json.f (docs/habu-dropbox.md).
\ A client owns one curl handle. Every request resets it, sets all it needs,
\ streams the answer whole into a growing buffer and captures the final header
\ block, so no option or header outlives its request. A call is a POST to
\ <api>/2/<route>; a client with no access token refreshes first, and any 401
\ refreshes and resends the call once, which answers unlinked if refused
\ again. Unlinked is logged once, where it is decided, and a confirmation
\ that answers unlinked answers it in its call's place. A refresh that
\ rotates the refresh token hands it to the config's store before the new
\ access token is used (the token's phase, below). The long poll is a
\ POST to <notify>/2/files/list_folder/longpoll with neither token nor root.
\ An answer is classified once: 200 done, 403 unlinked, 409 refused by its
\ error tag, 422 refused invalid-root, 429, 408 and 5xx retry, a timeout or
\ lost connection retry 0; anything else logs one line (route, status, at
\ most EXCERPT bytes of the body, never a token) and throws a DROPBOX code,
\ a bug on one side of the wire. E-NOT-STORED is environmental instead:
\ the store failed, and the next call retries it.
\ A 409's error is a Dropbox union: its leaf tag is the `.tag` of the member
\ named by the outer `.tag`, or of `reason` in an upload's error, when that
\ member is an object, else the outer `.tag` itself, so path/not_found reads
\ not_found.
\ STORAGE CLASS. CALLER-OWNED: OPEN lays the client and its copies of the
\ config in the caller's arena; the client owns its handle and buffers until
\ CLOSE. Every span or entry it answers is borrowed until its next call. One
\ task uses a client at a time. A program using DROPBOX starts the CURL loop
\ (AIO:START CURL:LOOP-START) before its first call.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/byte-buffer.f
require src/lib/arena.f
require src/lib/json.f
require src/lib/fmt.f
require src/lib/log.f
require src/lib/net/curl.f
require src/lib/memory.f
require src/lib/aio.f
require src/lib/fsm.f
require src/lib/unicode.f
require src/lib/date.f
require src/lib/type/deftype.f

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

\ Dropbox's 409 tags omabox decides on, else other; no tag: path-mismatch,
\ an entry elsewhere, and unverified, a download that fails a check or parse.
ENUM error DERIVE eq
   not-found not-file not-folder malformed-path disallowed-name
   conflict no-write-permission restricted-content
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

ENUM kind DERIVE eq file folder deleted ;ENUM

\ Dropbox's content hash of a file's bytes.
DEFTYPE HASH str
\ A file's revision, which a conditional write names.
DEFTYPE REV str
\ A listing's cursor, which list_folder/continue resumes from.
DEFTYPE CURSOR str

: HASH= ( hash hash -- bool )
   {: a:hash b:hash :}
   a HASH>STR str> b HASH>STR str> STR= ;

\ rev, content-hash and size are a file's alone, empty and 0 for a
\ folder; lower and display are path_lower and path_display.
STRUCTURE entry DERIVE addr
   FIELD kind kind
   FIELD lower SPAN:span<u8>
   FIELD display SPAN:span<u8>
   FIELD rev SPAN:span<u8>
   FIELD content-hash SPAN:span<u8>
   FIELD size n
;STRUCTURE

\ What OPEN copies: key is the app key, Dropbox's client_id; token the
\ refresh token; store keeps a rotated refresh token where token came
\ from, throws when it cannot and must not use the client; root the root
\ namespace, empty for the account's home; api, content and notify the
\ origins, which tests point at a fake.
STRUCTURE config DERIVE addr
   FIELD key SPAN:span<u8>
   FIELD token SPAN:span<u8>
   FIELD store [ ^u8 n -- ]
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

\ The buffers are BUF headers in the arena: token holds the refresh token,
\ access the access token, body a route's JSON body, line a URL or header
\ line being built, answer the body received, heads its header block,
\ values the strings decoded from it. holds names what answer holds, for
\ the log: body, or result once a download's Dropbox-API-Result replaced
\ it. root-line is the Path-Root header line, empty for none. route names
\ the request for the log; quiet marks the token route, whose body is
\ never logged. status is the answer's HTTP status, 0 when curl failed
\ with failure. outer, leaf-name and leaf are an error body's tags; wait
\ its retry_after in seconds, -1 for none; correct its correct_offset,
\ -1 for none; issued a token answer's access_token and granted its
\ refresh_token. sent holds a listing's cursor, the one sent and then
\ its page's, and mark the cursor of the last listing that answered done;
\ page is a page's cursor, more its has_more, got the members an answer
\ must hold, one bit each; changes and backoff are a long poll's answer.
\ tagged marks the `.tag` of the Metadata union being read into entry.
\ drain takes the reads of a transfer ABANDONED ends; laid out at OPEN
\ and never grown, so ending a transfer allocates nothing. store and
\ phase are the config's store and the refresh token's phase.
STRUCTURE client OPAQUE DERIVE addr
   FIELD handle CURL:handle
   FIELD key SPAN:span<u8>
   FIELD token ^n
   FIELD store [ ^u8 n -- ]
   FIELD phase phase
   FIELD api SPAN:span<u8>
   FIELD content SPAN:span<u8>
   FIELD notify SPAN:span<u8>
   FIELD root-line SPAN:span<u8>
   FIELD access ^n
   FIELD body ^n
   FIELD line ^n
   FIELD answer ^n
   FIELD holds SPAN:span<u8>
   FIELD heads ^n
   FIELD values ^n
   FIELD writer JSON:writer
   FIELD cursor JSON:cursor
   FIELD route SPAN:span<u8>
   FIELD quiet bool
   FIELD status n
   FIELD failure n
   FIELD outer SPAN:span<u8>
   FIELD leaf-name SPAN:span<u8>
   FIELD leaf SPAN:span<u8>
   FIELD wait n
   FIELD correct n
   FIELD issued SPAN:span<u8>
   FIELD granted SPAN:span<u8>
   FIELD account SPAN:span<u8>
   FIELD namespace SPAN:span<u8>
   FIELD entry entry
   FIELD sent ^n
   FIELD mark ^n
   FIELD page SPAN:span<u8>
   FIELD more bool
   FIELD got n
   FIELD changes bool
   FIELD backoff n
   FIELD tagged bool
   FIELD drain SPAN:span<u8>
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

: EMPTY ( -- SPAN:span<u8> ) s" " SPAN:MAKE ;
: BLEN ( ^n -- n ) BUF:LEN@ BUF:BLEN>N ;
: BUF$ ( ^n -- ^u8 n ) BUF:SPAN$ BUF:BLEN>N ;
: APPEND ( ^u8 n ^n -- ) {: a:^ u:n buf :} a u BUF:N>BLEN buf BUF:APPEND-SPAN ;
: ANSWER$ ( ^client -- ^u8 n ) CLIENT-ANSWER @ BUF$ ;
: TAG$ ( ^client -- ^u8 n ) CLIENT-OUTER @ SPAN:$ ;


\ ---- logging and the codes it precedes

: LOG-OPEN ( -- ) LOG:ERROR s" dropbox" LOG:LINE ;


: EXCERPT$ ( ^client -- ^u8 n )
   ANSWER$ EXCERPT min ;


\ One line: the route, the status, why, and the answer buffer's start,
\ labelled by what it holds, unless the route is quiet.
: REPORT ( ^client ^u8 n -- )
   {: c why:^ why-u:n :}
   LOG-OPEN
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+
   s"  answered " LOG:TEXT+ c CLIENT-STATUS @ LOG:INT+
   s" : " LOG:TEXT+ why why-u LOG:TEXT+
   c CLIENT-QUIET @ 0= if
      s" ; " LOG:TEXT+ c CLIENT-HOLDS @ SPAN:$ LOG:TEXT+
      s" : " LOG:TEXT+ c EXCERPT$ LOG:TEXT+
   then
   LOG:;LINE ;


: FAILED ( ^client ^u8 n n -- )
   {: c why:^ why-u:n code:n :}
   c why why-u REPORT
   code throw ;


: CURL-FAILED ( CURL:code ^u8 n -- )
   {: code:CURL:code what:^ what-u:n :}
   LOG-OPEN
   s" curl " LOG:TEXT+ what what-u LOG:TEXT+
   s" : " LOG:TEXT+ code CURL:ERROR$ LOG:TEXT+
   LOG:;LINE
   E-TRANSPORT throw ;


\ A setter's status; the step names it in the log.
: OK ( CURL:status ^u8 n -- )
   {: s:CURL:status what:^ what-u:n :}
   s MATCH CURL:status
      ok OF ENDOF
      failed OF what what-u CURL-FAILED ENDOF
   ;MATCH ;


\ ---- opening

: KEEP ( ^u8 n ^ARENA:arena -- SPAN:span<u8> )
   {: a:^ u:n ar :}
   u 0= if EMPTY exit then
   ar u ARENA:ALLOC {: dst:^ du:n :}
   a dst u BYTE-COPY
   dst u SPAN:MAKE ;


: KEPT ( ^config ^ARENA:arena [ ^config -- ^SPAN:span<u8> ] -- SPAN:span<u8> )
   {: cfg ar field :}
   cfg field execute @ SPAN:$ ar KEEP ;


: BUFFER ( ^ARENA:arena -- ^n )
   BUF:HDR-BYTES ARENA:ALLOC drop CELL-VIEW
   dup FIRST-CAP BUF:N>BLEN BUF:INIT ;


: NEW-HANDLE ( -- CURL:handle )
   CURL:INIT MATCH CURL:init-result
      ready OF ENDOF
      failed OF s" init" CURL-FAILED ENDOF
   ;MATCH ;


\ The Path-Root line, written once through the line buffer; Dropbox
\ requires DEL and non-ASCII escaped in a header.
: ROOT-LINE ( ^client ^u8 n ^ARENA:arena -- SPAN:span<u8> )
   {: c r:^ ru:n ar :}
   ru 0= if EMPTY exit then
   c CLIENT-LINE @ {: line :}
   c CLIENT-WRITER line JSON:WRITE-OPEN-BUF
   true JSON:WRITE-ASCII!
   JSON:WRITE-OBJECT-START
   s" .tag" s" root" JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" root" r ru JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE
   line BUF$ {: j:^ ju:n :}
   s" Dropbox-API-Path-Root: " nip ju + {: u:n :}
   ar u ARENA:ALLOC {: dst:^ du:n :}
   s" Dropbox-API-Path-Root: " {: p:^ pu:n :}
   p dst pu BYTE-COPY
   j dst pu + ju BYTE-COPY
   dst u SPAN:MAKE ;


: CONFIGURED ( ^client ^config ^ARENA:arena -- )
   {: c cfg ar :}
   cfg ar [: DROPBOX-CONFIG:KEY ;] KEPT c CLIENT-KEY !
   cfg DROPBOX-CONFIG:TOKEN @ SPAN:$ BUF:N>BLEN
   c CLIENT-TOKEN @ BUF:REPLACE
   cfg DROPBOX-CONFIG:STORE @ c CLIENT-STORE !
   construct phase ready c CLIENT-PHASE !
   cfg ar [: DROPBOX-CONFIG:API ;] KEPT c CLIENT-API !
   cfg ar [: DROPBOX-CONFIG:CONTENT ;] KEPT c CLIENT-CONTENT !
   cfg ar [: DROPBOX-CONFIG:NOTIFY ;] KEPT c CLIENT-NOTIFY !
   ar CHUNK ARENA:ALLOC SPAN:MAKE c CLIENT-DRAIN ! ;


: BUFFERED ( ^client ^ARENA:arena -- )
   {: c ar :}
   ar BUFFER c CLIENT-TOKEN !
   ar BUFFER c CLIENT-ACCESS !
   ar BUFFER c CLIENT-BODY !
   ar BUFFER c CLIENT-LINE !
   ar BUFFER c CLIENT-ANSWER !
   s" body" SPAN:MAKE c CLIENT-HOLDS !
   ar BUFFER c CLIENT-HEADS !
   ar BUFFER c CLIENT-VALUES !
   ar BUFFER c CLIENT-SENT !
   ar BUFFER c CLIENT-MARK ! ;


\ ---- one request

: LINE-CLEAR ( ^client -- ) CLIENT-LINE @ BUF:CLEAR ;
: LINE+ ( ^client ^u8 n -- ) {: c a:^ u:n :} a u c CLIENT-LINE @ APPEND ;
: LINE$ ( ^client -- ^u8 n ) CLIENT-LINE @ BUF$ ;


\ Resets the handle and sets what every request needs, the URL the line
\ buffer holds included.
: PREPARE ( ^client -- CURL:handle )
   {: c :}
   c CLIENT-HANDLE @ {: h:CURL:handle :}
   h CURL:RESET s" reset" OK
   h c LINE$ CURL:URL! s" url" OK
   h false CURL:FOLLOW! s" follow" OK
   h DEADLINE >MS CURL:TIMEOUT! s" timeout" OK
   h ;


: AUTHORIZE ( CURL:handle ^client -- )
   {: h:CURL:handle c :}
   c LINE-CLEAR
   c s" Authorization: Bearer " LINE+
   c c CLIENT-ACCESS @ BUF$ LINE+
   h c LINE$ CURL:HEADER+ s" header" OK
   c CLIENT-ROOT-LINE @ SPAN:$ {: r:^ ru:n :}
   ru 0= if exit then
   h r ru CURL:HEADER+ s" header" OK ;


\ Free room past the answer's end, at least CHUNK bytes.
: ROOM ( ^n -- ^u8 len )
   {: buf :}
   buf buf BLEN CHUNK + BUF:N>BLEN BUF:ENSURE
   buf BUF$ +
   buf BUF:CAP@ BUF:BLEN>N buf BLEN - >LEN ;


: ADVANCE ( n ^n -- )
   {: got:n buf :}
   buf BLEN got + BUF:N>BLEN buf BUF:LEN! ;


\ One read; true once the transfer ended, its status or failure kept.
: STEP ( CURL:handle ^client -- bool )
   {: h:CURL:handle c :}
   c CLIENT-ANSWER @ {: buf :}
   h buf ROOM CURL:NEXT MATCH CURL:chunk-result
      chunk OF LEN>N buf ADVANCE drop false ENDOF
      response OF CURL:HTTP-STATUS>N c CLIENT-STATUS ! true ENDOF
      failed OF CURL:CODE>N c CLIENT-FAILURE ! true ENDOF
   ;MATCH ;


\ The final header block into heads; true when it fit.
: HEADS-FIT? ( ^client -- bool )
   {: c :}
   c CLIENT-HEADS @ {: buf :}
   c CLIENT-HANDLE @ buf BUF:SPAN$ drop buf BUF:CAP@ BUF:BLEN>N >LEN
   CURL:HEADERS MATCH CURL:header-result
      complete OF LEN>N BUF:N>BLEN buf BUF:LEN! true ENDOF
      truncated OF LEN>N BUF:N>BLEN buf swap BUF:RESERVE false ENDOF
   ;MATCH ;


: CAPTURE ( ^client -- )
   {: c :}
   c HEADS-FIT? if exit then
   c HEADS-FIT? drop ;


\ Starts the prepared request with nothing received yet.
: STARTED ( ^client -- CURL:handle )
   {: c :}
   0 c CLIENT-STATUS ! 0 c CLIENT-FAILURE !
   c CLIENT-ANSWER @ BUF:CLEAR
   s" body" SPAN:MAKE c CLIENT-HOLDS !
   c CLIENT-HEADS @ BUF:CLEAR
   c CLIENT-HANDLE @ {: h:CURL:handle :}
   h CURL:STREAM-START s" stream" OK
   h ;


\ The header block of an answer that arrived.
: ENDED ( ^client -- )
   {: c :}
   c CLIENT-STATUS @ 0<> if c CAPTURE then ;


\ Cancels the transfer in flight on h and reads it to its end, its
\ result included, so the handle is free for the next request.
: ABANDONED ( CURL:handle ^client -- )
   {: h:CURL:handle c :}
   h CURL:CANCEL
   c CLIENT-DRAIN @ SPAN:$ >LEN {: p:^ room:len :}
   begin
      h p room CURL:NEXT MATCH CURL:chunk-result
         chunk OF drop drop false ENDOF
         response OF drop true ENDOF
         failed OF drop true ENDOF
      ;MATCH
   until ;


\ Runs reads, the reads of the transfer started on h; ended answers
\ whether a read ended it. The one place a throw ends a transfer: whatever
\ reads throws, ABANDONED ends the transfer unless ended answers true, and
\ the code is rethrown.
: READ-OUT ( CURL:handle ^client [ -- ] [ -- bool ] -- )
   {: h:CURL:handle c reads ended :}
   [: reads execute ;] catch {: code:n :}
   code 0= if exit then
   ended execute 0= if h c ABANDONED then
   code throw ;


\ Sends the prepared request and reads its answer whole. Nothing after the
\ read that ended the transfer throws, so a throw finds it in flight.
: TRANSFER ( ^client -- )
   {: c :}
   c STARTED {: h:CURL:handle :}
   h c [: begin h c STEP until ;] [: false ;] READ-OUT
   c ENDED ;


\ ---- reading headers

: LINE-END ( ^u8 n n -- n )
   {: a:^ u:n at:n :}
   at begin dup u < while
      a over + c@ 10 = if exit then
      1+
   repeat ;


\ The line at `at`, and where the next one starts.
: LINE ( ^u8 n n -- ^u8 n n )
   {: a:^ u:n at:n :}
   a u at LINE-END {: lf:n :}
   a at + lf at - lf 1+ ;


: NAMES? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n nm:^ nu:n :}
   u nu > 0= if false exit then
   a nu + c@ 58 <> if false exit then
   a nu nm nu STR=CI ;


\ The trimmed value of the header name in the captured block, else empty.
: HEADER$ ( ^client ^u8 n -- ^u8 n )
   {: c nm:^ nu:n :}
   c CLIENT-HEADS @ BUF$ {: a:^ u:n :}
   0 begin dup u < while
      a u rot LINE >r
      2dup nm nu NAMES? if
         r> drop swap nu 1+ + swap nu 1+ - TRIM exit
      then
      2drop r>
   repeat drop a 0 ;


\ The longest wait in seconds, 15 minutes.
900 constant WAIT-CAP


\ Delta-seconds: digits only, any number of them, at most WAIT-CAP.
: DELTA-SECONDS ( ^u8 n -- option<n> )
   {: a:^ u:n :}
   a u STR-DIGITS? 0= if OPTION:NONE exit then
   0 0 begin dup u < while
      swap STR-BASE * over a + c@ STR-DIGIT-VALUE +
      WAIT-CAP min swap 1+
   repeat drop OPTION:SOME ;


\ Retry-After in seconds: delta-seconds, else an HTTP date less now and at
\ least 0 (a passed date asks for no wait); 0 false when absent or neither.
: RETRY-AFTER ( ^client -- n bool )
   s" Retry-After" HEADER$ epoch-seconds {: a:^ u:n now:n :}
   a u DELTA-SECONDS MATCH option
      some OF true ENDOF
      none OF a u now DATE:PARSE-HTTP MATCH option
         none OF 0 false ENDOF
         some OF now - 0 max true ENDOF
      ;MATCH ENDOF
   ;MATCH ;


\ ---- reading answers

: VALUE ( JSON:reader -- JSON:reader n ) JSON:READ-NEXT ;
: SKIP ( JSON:reader -- JSON:reader ) JSON:READ-NEXT drop JSON:READ-SKIP-VALUE ;


: OBJECT ( JSON:reader n -- JSON:reader )
   JSON:T-OBJ <> if E-ANSWER throw then ;


\ The current string or key decoded into values. PARSES? reserves values
\ for the whole answer first, so a span taken here never moves.
: DECODE ( JSON:reader ^client -- JSON:reader SPAN:span<u8> )
   {: c :}
   JSON:READ-TOKEN dup JSON:T-STR = swap JSON:T-KEY = or
   0= if E-ANSWER throw then
   c CLIENT-VALUES @ {: buf :}
   buf BLEN {: at:n :}
   buf JSON:READ-STR-APPEND
   buf BUF$ {: base:^ end:n :}
   base at + end at - SPAN:MAKE ;


: STRING ( JSON:reader ^client -- JSON:reader SPAN:span<u8> )
   {: c :}
   VALUE drop c DECODE ;


: INT ( JSON:reader -- JSON:reader n )
   VALUE JSON:T-INT <> if E-ANSWER throw then
   JSON:READ-INT ;


\ The members of the object just opened, each read by `member` at its key.
: MEMBERS ( JSON:reader ^client [ JSON:reader ^client -- JSON:reader ] -- JSON:reader )
   {: c member :}
   begin JSON:READ-NEXT dup JSON:T-KEY = while
      drop c member execute
   repeat
   JSON:T-OBJ-END <> if E-ANSWER throw then ;


: READ-ANSWER ( ^client [ JSON:reader ^client -- JSON:reader ] -- ^client )
   {: c member :}
   c CLIENT-VALUES @ {: buf :}
   buf BUF:CLEAR
   buf c ANSWER$ nip BUF:N>BLEN BUF:ENSURE
   c CLIENT-CURSOR c ANSWER$ JSON:READ-INIT
   VALUE OBJECT c member MEMBERS
   JSON:READ-FINISH c ;


\ Whether code says the answer does not parse: a JSON read code or
\ E-ANSWER.
: UNPARSED? ( n -- bool )
   {: code:n :}
   code E-ANSWER = if true exit then
   code E-JSON-READ-LAST >= code E-JSON-READ-FIRST <= and ;


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


: LEAF$ ( ^client -- ^u8 n )
   {: c :}
   c CLIENT-LEAF-NAME @ SPAN:$ {: m:^ mu:n :}
   m mu c TAG$ STR= m mu s" reason" STR= or
   c CLIENT-LEAF @ SPAN:LEN 0<> and if c CLIENT-LEAF @ SPAN:$ exit then
   c TAG$ ;


: TAG>ERROR ( ^u8 n -- error bool )
   2dup s" not_found" STR= if 2drop construct error not-found true exit then
   2dup s" not_file" STR= if 2drop construct error not-file true exit then
   2dup s" not_folder" STR= if 2drop construct error not-folder true exit then
   2dup s" malformed_path" STR= if 2drop construct error malformed-path true exit then
   2dup s" disallowed_name" STR= if 2drop construct error disallowed-name true exit then
   2dup s" conflict" STR= if 2drop construct error conflict true exit then
   2dup s" no_write_permission" STR= if 2drop construct error no-write-permission true exit then
   2dup s" restricted_content" STR= if 2drop construct error restricted-content true exit then
   2dup s" insufficient_space" STR= if 2drop construct error insufficient-space true exit then
   2dup s" locked" STR= if 2drop construct error locked true exit then
   2dup s" reset" STR= if 2drop construct error reset true exit then
   2dup s" content_hash_mismatch" STR= if 2drop construct error content-hash-mismatch true exit then
   2dup s" unsupported_file" STR= if 2drop construct error unsupported-file true exit then
   2drop construct error other false ;


\ ---- classifying an answer

: RETRY ( n -- reply ) construct reply retry ;
: ANSWER ( reply -- verdict ) construct verdict answer ;


\ A failed transfer: a timeout or a lost connection is retry 0.
: LOST ( ^client -- reply )
   {: c :}
   c CLIENT-FAILURE @ CURL:>CODE {: code:CURL:code :}
   code CURL:LOST? if 0 RETRY exit then
   c CLIENT-ROUTE @ SPAN:$ {: r:^ ru:n :}
   code r ru CURL-FAILED ;


\ Whether the last call's own answer was lost: its route's transfer failed,
\ so LOST answered retry 0. A lost refresh is the quiet token route's, so
\ the call never went out.
: LOST? ( ^client -- bool )
   {: c :}
   c CLIENT-STATUS @ 0= c CLIENT-QUIET @ 0= and ;


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
   c LEAF$ {: t:^ tu:n :}
   t tu s" too_many_write_operations" STR= if 0 RETRY exit then
   t tu TAG>ERROR if construct reply refused exit then
   LOG:WARN s" dropbox" LOG:LINE
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+ s"  refused: " LOG:TEXT+ t tu LOG:TEXT+
   LOG:;LINE
   construct reply refused ;


\ One line, the route and why: Dropbox refuses this app until the user
\ logs in again.
: UNLINKED ( ^client ^u8 n -- reply )
   {: c why:^ wu:n :}
   LOG-OPEN
   c CLIENT-ROUTE @ SPAN:$ LOG:TEXT+ s"  unlinked: " LOG:TEXT+
   why wu LOG:TEXT+ LOG:;LINE
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
   s CURL:>HTTP-STATUS CURL:UNAVAILABLE? if c WAITED ANSWER exit then
   c s UNEXPECTED ;


\ ---- the token

: UNRESERVED? ( n -- bool )
   {: b:n :}
   b STR-DIGIT? b ASCII-LOWER dup 97 >= swap 122 <= and or
   b 45 = or b 46 = or b 95 = or b 126 = or ;


: HEX ( n -- n ) dup 10 < if 48 + else 55 + then ;


: BYTE+ ( n ^n -- )
   {: b:n buf :}
   b UNRESERVED? if b buf BUF:APPEND-BYTE exit then
   37 buf BUF:APPEND-BYTE
   b 4 rshift HEX buf BUF:APPEND-BYTE
   b 15 and HEX buf BUF:APPEND-BYTE ;


\ Percent-encodes all but RFC 3986's unreserved bytes.
: ENCODED+ ( ^u8 n ^n -- )
   {: a:^ u:n buf :}
   u 0 ?do a i + c@ buf BYTE+ loop ;


\ The refresh's form body, in the line buffer once PREPARE copied the URL.
: FORM ( ^client -- ^u8 n )
   {: c :}
   c CLIENT-LINE @ {: buf :}
   buf BUF:CLEAR
   s" grant_type=refresh_token&refresh_token=" buf APPEND
   c CLIENT-TOKEN @ BUF$ buf ENCODED+
   s" &client_id=" buf APPEND
   c CLIENT-KEY @ SPAN:$ buf ENCODED+
   buf BUF$ ;


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
   t SPAN:$ BUF:N>BLEN buf BUF:REPLACE ;


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
   c CLIENT-GRANTED @ SPAN:$ {: g:^ gu:n :}
   gu 0= if 0 exit then
   g gu c CLIENT-TOKEN @ BUF$ STR= if 0 exit then
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
: REJECTED ( ^client ^u8 n -- reply )
   {: c why:^ wu:n :}
   construct phase rejected c CLIENT-PHASE !
   c why wu UNLINKED ;


\ invalid_grant answers what `dead` answers.
: GRANT ( ^client [ ^client -- reply ] -- reply )
   {: c dead :}
   c ERROR-READ? if
      c TAG$ s" invalid_grant" STR= if c dead execute exit then
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
   s CURL:>HTTP-STATUS CURL:UNAVAILABLE? if c WAITED exit then
   c s UNEXPECTED ;


\ A POST to <api>/oauth2/token of the form `form` writes, with no
\ Authorization or Path-Root; the access token is empty until one is kept.
: TOKEN-POST ( ^client [ ^client -- ^u8 n ] -- )
   {: c form :}
   c CLIENT-ACCESS @ BUF:CLEAR
   s" oauth2/token" SPAN:MAKE c CLIENT-ROUTE !
   true c CLIENT-QUIET !
   c LINE-CLEAR c c CLIENT-API @ SPAN:$ LINE+ c s" /oauth2/token" LINE+
   c PREPARE {: h:CURL:handle :}
   h c form execute CURL:BODY! s" body" OK
   c TRANSFER ;


\ A new access token for the refresh token.
: REFRESH ( ^client -- reply )
   {: c :}
   c [: FORM ;] TOKEN-POST
   c [: KEPT-TOKEN ;]
   [: s" the refresh token was refused" REJECTED ;] REFRESHED ;


\ ---- a call

: DONE? ( reply -- bool )
   MATCH reply
      done OF true ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ A POST to <origin>/2/<route>; body sets the route's headers and body, and
\ send exchanges the request and classifies its answer.
: ATTEMPT ( ^client SPAN:span<u8> ^u8 n [ CURL:handle ^client -- ] [ ^client -- verdict ] -- verdict )
   {: c o:SPAN:span<u8> r:^ ru:n body send :}
   r ru SPAN:MAKE c CLIENT-ROUTE !
   false c CLIENT-QUIET !
   c LINE-CLEAR c o SPAN:$ LINE+ c s" /2/" LINE+ c r ru LINE+
   c PREPARE {: h:CURL:handle :}
   h c AUTHORIZE
   h c body execute
   c send execute ;


: RESEND ( ^client SPAN:span<u8> ^u8 n [ CURL:handle ^client -- ] [ ^client -- verdict ] -- reply )
   {: c o:SPAN:span<u8> r:^ ru:n body send :}
   c REFRESH {: again:reply :}
   again DONE? 0= if again exit then
   c o r ru body send ATTEMPT MATCH verdict
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


: CALL-AT ( ^client SPAN:span<u8> ^u8 n [ CURL:handle ^client -- ] [ ^client -- verdict ] -- reply )
   {: c o:SPAN:span<u8> r:^ ru:n body send :}
   c READY {: first:reply :}
   first DONE? 0= if first exit then
   c o r ru body send ATTEMPT MATCH verdict
      answer OF ENDOF
      rejected OF c o r ru body send RESEND ENDOF
   ;MATCH ;


\ The whole answer read and classified.
: RECEIVED ( ^client -- verdict ) dup TRANSFER CLASSIFY ;


\ A POST to <api>/2/<route>; body sets the route's headers and body.
: CALL ( ^client ^u8 n [ CURL:handle ^client -- ] -- reply )
   {: c r:^ ru:n body :}
   c c CLIENT-API @ r ru body [: RECEIVED ;] CALL-AT ;


\ On done, reads the answer into the client.
: ANSWERED ( reply ^client [ ^client -- ] -- reply )
   {: r:reply c read :}
   r DONE? if c read execute then
   r ;


\ An empty body, and an empty Content-Type line to drop the form type
\ libcurl adds to it.
: NO-BODY ( CURL:handle ^client -- )
   drop {: h:CURL:handle :}
   h s" Content-Type:" CURL:HEADER+ s" header" OK
   h s" " CURL:BODY! s" body" OK ;


: JSON-BODY ( CURL:handle ^client -- )
   {: h:CURL:handle c :}
   h s" Content-Type: application/json" CURL:HEADER+ s" header" OK
   h c CLIENT-BODY @ BUF$ CURL:BODY! s" body" OK ;


: BODY-OPEN ( ^client -- ^JSON:writer )
   {: c :}
   c CLIENT-WRITER c CLIENT-BODY @ JSON:WRITE-OPEN-BUF
   true JSON:WRITE-ASCII! ;


\ ---- the routes' answers

: ROOT-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" root_namespace_id" JSON:READ-STR-EQ? 0= if SKIP exit then
   c STRING c CLIENT-NAMESPACE ! ;


: ACCOUNT-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" account_id" JSON:READ-STR-EQ? if c STRING c CLIENT-ACCOUNT ! exit then
   s" root_info" JSON:READ-STR-EQ? 0= if SKIP exit then
   VALUE OBJECT c [: ROOT-MEMBER ;] MEMBERS ;


: ACCOUNT-READ ( ^client -- )
   {: c :}
   EMPTY c CLIENT-ACCOUNT ! EMPTY c CLIENT-NAMESPACE !
   c [: ACCOUNT-MEMBER ;] PARSE
   c CLIENT-ACCOUNT @ SPAN:LEN 0= c CLIENT-NAMESPACE @ SPAN:LEN 0= or
   if c s" no account_id or root_namespace_id" E-ANSWER FAILED then ;


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
   0 e DROPBOX-ENTRY:SIZE ! ;


: FILE? ( ^entry -- bool )
   DROPBOX-ENTRY:KIND @ construct kind file DROPBOX-KIND:EQ ;


\ Whether the entry holds what its kind needs: both paths, and for a file
\ its rev and hash.
: WHOLE? ( ^entry -- bool )
   {: e :}
   e DROPBOX-ENTRY:LOWER @ SPAN:LEN 0<> e DROPBOX-ENTRY:DISPLAY @ SPAN:LEN 0<> and
   e FILE? 0= if exit then
   e DROPBOX-ENTRY:REV @ SPAN:LEN 0<> and
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:LEN 0<> and ;


\ A route answers its entry in one shape. A plain FileMetadata or
\ FolderMetadata takes its kind from the route and skips a `.tag` as any
\ member it does not know, as the SDK does; a Metadata union takes its kind
\ from its `.tag`.

\ The members both shapes hold.
: FIELD-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c CLIENT-ENTRY {: e :}
   s" path_lower" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:LOWER ! exit then
   s" path_display" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:DISPLAY ! exit then
   s" rev" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:REV ! exit then
   s" content_hash" JSON:READ-STR-EQ? if c STRING e DROPBOX-ENTRY:CONTENT-HASH ! exit then
   s" size" JSON:READ-STR-EQ? if INT e DROPBOX-ENTRY:SIZE ! exit then
   SKIP ;


: TAGGED-MEMBER ( JSON:reader ^client -- JSON:reader )
   {: c :}
   s" .tag" JSON:READ-STR-EQ? if
      KIND-OF c CLIENT-ENTRY DROPBOX-ENTRY:KIND ! true c CLIENT-TAGGED ! exit
   then
   c FIELD-MEMBER ;


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
   c [: FIELD-MEMBER ;] MEMBERS ;


\ A Metadata union, its object just opened, read into the entry: one with
\ no `.tag` has no kind, and is never taken for a deleted entry.
: TAGGED-OBJECT ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c construct kind deleted ENTRY-OPEN
   c [: TAGGED-MEMBER ;] MEMBERS
   c CLIENT-TAGGED @ 0= if E-ANSWER throw then ;


\ The answer's entry, as `member` finds it with the entry open at kind k.
\ A deleted entry is a listing's alone; any other route answers a file or
\ folder, so an entry left at deleted, as a union with no `.tag` is, fails.
: ENTRY-PARSE ( ^client kind [ JSON:reader ^client -- JSON:reader ] -- )
   {: c k:kind member :}
   c k ENTRY-OPEN
   c member PARSE
   c CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ construct kind deleted DROPBOX-KIND:EQ
   e WHOLE? 0= or if c s" an incomplete entry" E-ANSWER FAILED then ;


\ get_metadata's answer, a Metadata union.
: ENTRY-READ ( ^client -- )
   construct kind deleted [: TAGGED-MEMBER ;] ENTRY-PARSE ;


\ The answer of upload and upload_session/finish, and download's
\ Dropbox-API-Result: a plain FileMetadata.
: FILE-READ ( ^client -- )
   construct kind file [: FIELD-MEMBER ;] ENTRY-PARSE ;


\ ---- files/download

\ transport.rs BODY_IDLE_SECONDS: the longest a body, or a connect, may stall.
60 constant IDLE


: INT+ ( ^client n -- ) {: c v:n :} c v FMT:INT$ LINE+ ;


\ The Dropbox-API-Arg line, {"path": "rev:<rev>"}: the value is built in
\ the line, the JSON in the body buffer a download never sends.
: ARG-LINE ( ^client ^u8 n -- ^u8 n )
   {: c r:^ ru:n :}
   c LINE-CLEAR c s" rev:" LINE+ c r ru LINE+
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" c LINE$ JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE
   c LINE-CLEAR c s" Dropbox-API-Arg: " LINE+
   c c CLIENT-BODY @ BUF$ LINE+
   c LINE$ ;


\ The content deadlines: a stall ends the call, a long body does not.
: STALLED ( CURL:handle -- )
   {: h:CURL:handle :}
   h 0 >MS CURL:TIMEOUT! s" timeout" OK
   h 1 IDLE CURL:LOW-SPEED! s" low speed" OK ;


\ An empty body, the rev's argument, a Range from a nonzero offset, and the
\ content deadlines.
: ASKED ( CURL:handle ^client ^u8 n n -- )
   {: h:CURL:handle c r:^ ru:n at:n :}
   h c NO-BODY
   h c r ru ARG-LINE CURL:HEADER+ s" header" OK
   at 0 > if
      c LINE-CLEAR c s" Range: bytes=" LINE+ c at INT+ c s" -" LINE+
      h c LINE$ CURL:HEADER+ s" header" OK
   then
   h STALLED ;


-100009 s" a download's answer failed its checks"
   ERROR:CODE E-UNVERIFIED


\ Runs a parse of the download's answer, which replaces its seed as catch
\ keeps the stack's shape; its E-ANSWER, logged already, is E-UNVERIFIED.
: VERIFIED ( R [ R -- R ] -- R )
   {: parse :}
   [: parse execute ;] catch {: code:n :}
   code 0= if exit then
   code E-ANSWER = if E-UNVERIFIED throw then
   code throw ;


\ The metadata the Dropbox-API-Result header holds, read into the entry.
\ It replaces the answer buffer, so a 2xx chunk lands in the body buffer
\ and a failed check logs the result, never a byte of the file.
: RESULT-READ ( ^client -- )
   {: c :}
   c s" Dropbox-API-Result" HEADER$ BUF:N>BLEN
   c CLIENT-ANSWER @ BUF:REPLACE
   s" result" SPAN:MAKE c CLIENT-HOLDS !
   [: c FILE-READ ;] VERIFIED ;


\ The Content-Range a ranged answer of the entry must carry, in the line.
: RANGE-LINE ( ^client n ^entry -- ^u8 n )
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
   c s" Content-Range" HEADER$ c at e RANGE-LINE STR=
   0= if c s" another Content-Range" E-UNVERIFIED FAILED then ;


\ The status, metadata and Content-Range of a 2xx answer, from the captured
\ headers: the rev asked and the range asked.
: CHECKED ( ^client ^u8 n n -- )
   {: c r:^ ru:n at:n :}
   c RESULT-READ
   c CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:REV @ SPAN:$ r ru STR=
   0= if c s" another rev" E-UNVERIFIED FAILED then
   c at e RANGED ;


\ ---- the download's machine

\ A step ends in streaming only with a new chunk held, none of it taken,
\ and in drained once the reader reached the body's end.
ENUM download-step DERIVE eq
   opened streaming buffering answered drained lost ;ENUM
ENUM read-event chunk response failure ;ENUM
ENUM open-event passed other response failure ;ENUM


\ One download's read, the machine's context: client and handle the
\ call's; rev and offset the revision and offset asked; step where the
\ machine stands; held the chunk read last, taken the bytes of it the
\ reader took, and status its HTTP status, or a response's; failure a
\ failed transfer's curl code; total the bytes the reader took.
public
STRUCTURE fetch OPAQUE DERIVE addr
   FIELD client ^client
   FIELD handle CURL:handle
   FIELD rev SPAN:span<u8>
   FIELD offset n
   FIELD step download-step
   FIELD held SPAN:span<u8>
   FIELD taken n
   FIELD status n
   FIELD failure n
   FIELD total n
;STRUCTURE
private

HEAP FETCHES fetch

-100008 s" a download's transfer ended inside its body"
   ERROR:CODE E-BODY-LOST


: HOLD ( CURL:http-status len ^u8 ^fetch -- )
   {: p:^ f :}
   LEN>N p swap SPAN:MAKE f FETCH-HELD !
   0 f FETCH-TAKEN !
   CURL:HTTP-STATUS>N f FETCH-STATUS ! ;


\ One read into the body buffer, which a download never sends.
: PULL ( ^fetch -- read-event )
   {: f :}
   f FETCH-CLIENT @ CLIENT-BODY @ {: buf :}
   buf BUF:CLEAR
   buf ROOM {: p:^ room:len :}
   f FETCH-HANDLE @ p room CURL:NEXT MATCH CURL:chunk-result
      chunk OF p f HOLD construct read-event chunk ENDOF
      response OF
         CURL:HTTP-STATUS>N f FETCH-STATUS !
         construct read-event response
      ENDOF
      failed OF
         CURL:CODE>N f FETCH-FAILURE !
         construct read-event failure
      ENDOF
   ;MATCH ;


\ The first chunk: a 2xx one passes CHECKED, made through the headers
\ curl answers from that chunk on, or CHECKED throws; any other status is
\ the core's to classify.
: FIRST-CHECKED ( ^fetch -- open-event )
   {: f :}
   f FETCH-STATUS @ {: s:n :}
   s 200 >= s 300 < and 0= if construct open-event other exit then
   f FETCH-CLIENT @ {: c :}
   s c CLIENT-STATUS !
   c CAPTURE
   c f FETCH-REV @ SPAN:$ f FETCH-OFFSET @ CHECKED
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
\ the read that ended a transfer may throw; ENDED captures its headers.
: RESPONDED ( ^fetch -- )
   {: f :}
   f FETCH-STATUS @ f FETCH-CLIENT @ CLIENT-STATUS ! ;


: BROKE ( ^fetch -- )
   {: f :}
   f FETCH-CLIENT @ {: c :}
   0 c CLIENT-STATUS !
   f FETCH-FAILURE @ c CLIENT-FAILURE ! ;


\ A throw from a sense or an action leaves the transfer in flight, for
\ READ-OUT to end.
FSM:DEFINE DOWNLOADING ( ^fetch ) download-step open-event
   IN opened  OPEN-SENSE
      passed    -          >streaming
      other     ANSWER+    >buffering
      response  RESPONDED  >answered
      failure   BROKE      >lost
   IN streaming  PULL ( read-event )
      chunk     -          >streaming
      response  RESPONDED  >drained
      failure   BROKE      >lost
   IN buffering  PULL ( read-event )
      chunk     ANSWER+    >buffering
      response  RESPONDED  >answered
      failure   BROKE      >lost
   FINAL answered  -
   FINAL drained   -
   FINAL lost      -
;DEFINE


: STREAMING? ( download-step -- bool )
   construct download-step streaming DOWNLOAD-STEP-EQ ;
: DRAINED? ( download-step -- bool )
   construct download-step drained DOWNLOAD-STEP-EQ ;
: CUT? ( download-step -- bool )
   construct download-step lost DOWNLOAD-STEP-EQ ;


\ Whether the machine is at its end, so the transfer has ended.
: FINAL? ( download-step -- bool )
   {: s:download-step :}
   s DRAINED? s CUT? or
   s construct download-step answered DOWNLOAD-STEP-EQ or ;


\ Steps the machine once; true at its end.
: STEPPED ( ^fetch -- bool )
   {: f :}
   f f FETCH-STEP @ DOWNLOADING-STEP {: s:download-step end:bool :}
   s f FETCH-STEP !
   end ;


\ Whether the machine streams with its held chunk all taken.
: STARVED? ( ^fetch -- bool )
   {: f :}
   f FETCH-STEP @ STREAMING? 0= if false exit then
   f FETCH-TAKEN @ f FETCH-HELD @ SPAN:$ nip = ;


\ Copies what fits in room of the held chunk's untaken bytes to p.
: TAKEN ( ^u8 n ^fetch -- n )
   {: p:^ room:n f :}
   f FETCH-HELD @ SPAN:$ {: a:^ u:n :}
   f FETCH-TAKEN @ {: at:n :}
   u at - room min {: k:n :}
   a at + p k BYTE-COPY
   k f FETCH-TAKEN +! k f FETCH-TOTAL +!
   k ;


public

\ The reader of a download's body: at most room of its next bytes into p,
\ and how many, 0 at its end. A transfer lost inside the body throws
\ E-BODY-LOST.
: READ-BODY ( ^u8 n ^fetch -- n )
   {: p:^ room:n f :}
   begin f STARVED? while f STEPPED drop repeat
   f FETCH-STEP @ {: s:download-step :}
   s CUT? if E-BODY-LOST throw then
   s STREAMING? 0= if 0 exit then
   p room f TAKEN ;

private


: FILE-SIZE ( ^client -- n ) CLIENT-ENTRY DROPBOX-ENTRY:SIZE @ ;


\ Hands body the offset, the file's size and the fetch to read. A body it
\ leaves unread is cancelled, the machine left streaming; nothing throws
\ after.
: BODIED ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ c FILE-SIZE f body execute
   f FETCH-STEP @ STREAMING? 0= if exit then
   f FETCH-HANDLE @ c ABANDONED ;


\ Steps the machine from opened: once the checks pass, body reads the
\ body; otherwise the machine steps to its end.
: DRIVEN ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f STEPPED if exit then
   f FETCH-STEP @ STREAMING? if f body BODIED exit then
   begin f STEPPED until ;


\ Sends the prepared request, reads its answer through DOWNLOADING
\ under READ-OUT, which finds the transfer ended once the machine is at its
\ end, and captures an arrived answer's header block.
: RECEIVING ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   c STARTED {: h:CURL:handle :}
   h f FETCH-HANDLE !
   h c [: f body DRIVEN ;] [: f FETCH-STEP @ FINAL? ;] READ-OUT
   c ENDED ;


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


\ A body of every byte after the offset.
: SIZED ( ^client n n -- )
   {: c at:n got:n :}
   c FILE-SIZE at - got <>
   if c s" a body of another length" E-UNVERIFIED FAILED then ;


\ A done answer no chunk came with: the rev and range asked and an empty
\ body; body reads it from the fetch, at its end.
: EMPTIED ( ^fetch [ n n ^fetch -- ] -- )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ {: at:n :}
   c f FETCH-REV @ SPAN:$ at CHECKED
   c at 0 SIZED
   at c FILE-SIZE f body execute ;


\ A 416 from offset 0, where no Range was sent.
: UNSATISFIABLE ( ^fetch -- reply )
   FETCH-CLIENT @ s" a range it cannot satisfy from 0" E-UNVERIFIED FAILED ;


\ An answer that arrived with no chunk handed to body. A 416,
\ RangeUnsatisfiable in dropbox.rs, carries no Dropbox-API-Result, so it is
\ never done; unsat answers it.
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


\ A lost transfer, status 0, is the core's to classify, inside the body
\ too. A body left unread is done; one read to its end is done once it is
\ every byte after the offset.
: SETTLED ( ^fetch [ n n ^fetch -- ] [ ^fetch -- reply ] -- verdict )
   {: f body unsat :}
   f body ABSORBED
   f FETCH-CLIENT @ {: c :}
   f FETCH-STEP @ {: s:download-step :}
   c CLIENT-STATUS @ 0= if c LOST ANSWER exit then
   s STREAMING? if construct reply done ANSWER exit then
   s DRAINED? if
      c f FETCH-OFFSET @ f FETCH-TOTAL @ SIZED
      construct reply done ANSWER exit
   then
   f body unsat ARRIVED ;


\ The prepared request's answer through SETTLED. The fetch is made before
\ the transfer starts, so nothing allocates while it is in flight but what
\ READ-OUT covers, and lives until the call answers.
: FETCHED ( ^client ^u8 n n [ n n ^fetch -- ] [ ^fetch -- reply ] -- verdict )
   {: c r:^ ru:n at:n body unsat :}
   FETCHES-NEW {: f :}
   c f FETCH-CLIENT !
   r ru SPAN:MAKE f FETCH-REV ! at f FETCH-OFFSET !
   construct download-step opened f FETCH-STEP !
   [: f body unsat SETTLED ;] [: f FETCHES-RELEASE ;] finally ;


\ files/download from the offset; unsat answers a 416.
: FROM ( ^u8 n n ^client [ n n ^fetch -- ] [ ^fetch -- reply ] -- reply )
   {: r:^ ru:n at:n c body unsat :}
   c c CLIENT-CONTENT @ s" files/download"
   [: r ru at ASKED ;] [: r ru at body unsat FETCHED ;] CALL-AT ;


\ files/download from offset 0.
: AFRESH ( ^client ^u8 n [ n n ^fetch -- ] -- reply )
   {: c r:^ ru:n body :}
   r ru 0 c body [: UNSATISFIABLE ;] FROM ;


\ The Content-Range of a 416 whose length is the offset, in the line.
: LENGTH-LINE ( ^client n -- ^u8 n )
   {: c at:n :}
   c LINE-CLEAR c s" bytes */" LINE+ c at INT+
   c LINE$ ;


\ A 416 from the offset. A length of the offset says the bytes before it
\ are the whole file: body reads the fetch at its end and the answer is
\ done with no entry of its own. Any other starts over from 0.
: RESUMED ( ^fetch [ n n ^fetch -- ] -- reply )
   {: f body :}
   f FETCH-CLIENT @ {: c :}
   f FETCH-OFFSET @ {: at:n :}
   c s" Content-Range" HEADER$ c at LENGTH-LINE STR=
   0= if c f FETCH-REV @ SPAN:$ body AFRESH exit then
   at at f body execute
   construct reply done ;


\ A seed's typed drop, which types the download that replaces it.
: DROP-REPLY ( reply -- ) drop ;


\ files/download from the offset: from 0 afresh, else through RESUMED.
: REQUESTED ( ^u8 n n ^client [ n n ^fetch -- ] -- reply )
   {: r:^ ru:n at:n c body :}
   at 0= if c r ru body AFRESH exit then
   r ru at c body [: body RESUMED ;] FROM ;


\ Disposes buf unless it is null, a buffer OPEN never made: the arena
\ zeroes the record.
: DISCARD ( ^n -- )
   {: buf :}
   buf NULL-PTR = if exit then
   buf BUF:DISPOSE ;


\ The buffers BUFFERED made, before a throw part-way or after them all.
: UNBUFFERED ( ^client -- )
   {: c :}
   c CLIENT-TOKEN @ DISCARD
   c CLIENT-ACCESS @ DISCARD
   c CLIENT-BODY @ DISCARD
   c CLIENT-LINE @ DISCARD
   c CLIENT-ANSWER @ DISCARD
   c CLIENT-HEADS @ DISCARD
   c CLIENT-VALUES @ DISCARD
   c CLIENT-SENT @ DISCARD
   c CLIENT-MARK @ DISCARD ;


\ What OPEN keeps in c. A throw part-way disposes the buffers made and
\ goes on; the rest is the arena's, and the handle, made last, exists only
\ when nothing threw.
: FILLED ( ^client ^config ^ARENA:arena -- )
   {: c cfg ar :}
   [: c ar BUFFERED
      c cfg ar CONFIGURED
      c cfg DROPBOX-CONFIG:ROOT @ SPAN:$ ar ROOT-LINE c CLIENT-ROOT-LINE !
      NEW-HANDLE c CLIENT-HANDLE ! ;] catch {: code:n :}
   code 0= if exit then
   c UNBUFFERED
   code throw ;


public

\ Sets the three origins to Dropbox's.
: PRODUCTION ( ^config -- )
   {: cfg :}
   s" https://api.dropboxapi.com" SPAN:MAKE cfg DROPBOX-CONFIG:API !
   s" https://content.dropboxapi.com" SPAN:MAKE cfg DROPBOX-CONFIG:CONTENT !
   s" https://notify.dropboxapi.com" SPAN:MAKE cfg DROPBOX-CONFIG:NOTIFY ! ;


: OPEN ( ^config ^ARENA:arena -- ^client )
   {: cfg ar :}
   ar CLIENTS-NEW {: c :}
   c cfg ar FILLED
   c ;


: CLOSE ( ^client -- )
   {: c :}
   c CLIENT-HANDLE @ CURL:CLEANUP
   c CLIENT-CURSOR JSON:READ-DISPOSE
   c UNBUFFERED ;


\ users/get_current_account
: ACCOUNT ( ^client -- reply )
   {: c :}
   c s" users/get_current_account" [: NO-BODY ;] CALL
   c [: ACCOUNT-READ ;] ANSWERED ;


: ACCOUNT-ID ( ^client -- ^u8 n ) CLIENT-ACCOUNT @ SPAN:$ ;
: ROOT-NAMESPACE ( ^client -- ^u8 n ) CLIENT-NAMESPACE @ SPAN:$ ;


\ files/get_metadata of the path.
: METADATA ( ^u8 n ^client -- reply )
   {: p:^ pu:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p pu JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE
   c s" files/get_metadata" [: JSON-BODY ;] CALL
   c [: ENTRY-READ ;] ANSWERED ;


: ENTRY ( ^client -- ^entry ) CLIENT-ENTRY ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

private

\ transport.rs LONG_POLL_SLACK_SECONDS and LONG_POLL_GRACE_SECONDS: the
\ slack Dropbox documents past a long poll's timeout, and ours past that.
90 constant SLACK
105 constant GRACE

\ The bits of got: a page needs entries, cursor and has_more, a long poll's
\ answer changes.
1 constant GOT-ENTRIES
2 constant GOT-CURSOR
4 constant GOT-MORE
7 constant GOT-PAGE
1 constant GOT-CHANGES


: GOT ( ^client n -- )
   {: c bit:n :}
   c CLIENT-GOT @ bit or c CLIENT-GOT ! ;


: BOOLEAN ( JSON:reader -- JSON:reader bool )
   VALUE dup JSON:T-TRUE = if drop true exit then
   JSON:T-FALSE <> if E-ANSWER throw then
   false ;


\ Each object of the array that opens next, read by `entry` once opened.
: ENTRIES ( JSON:reader ^client [ JSON:reader ^client -- JSON:reader ] -- JSON:reader )
   {: c entry :}
   VALUE JSON:T-ARR <> if E-ANSWER throw then
   begin VALUE dup JSON:T-OBJ = while
      drop c entry execute
   repeat
   JSON:T-ARR-END <> if E-ANSWER throw then ;


: LISTED ( JSON:reader ^client -- JSON:reader )
   {: c :}
   c TAGGED-OBJECT
   c CLIENT-ENTRY WHOLE? 0= if E-ANSWER throw then ;


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


\ Reads and checks a page; one with more whose cursor is the one sent
\ would list the same page forever.
: PAGE-READ ( ^client -- )
   {: c :}
   0 c CLIENT-GOT ! EMPTY c CLIENT-PAGE ! false c CLIENT-MORE !
   c [: PAGE-MEMBER ;] PARSE
   c CLIENT-GOT @ GOT-PAGE <>
   if c s" no entries, cursor or has_more" E-ANSWER FAILED then
   c CLIENT-MORE @ 0= if exit then
   c CLIENT-PAGE @ SPAN:$ c CLIENT-SENT @ BUF$ STR=
   if c s" a cursor that did not advance" E-ANSWER FAILED then ;


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
   c CLIENT-PAGE @ SPAN:$ BUF:N>BLEN c CLIENT-SENT @ BUF:REPLACE
   c [: each HAND-MEMBER ;] READ-ANSWER drop
   c CLIENT-MORE @ ;


: CONTINUE ( ^client -- reply )
   {: c :}
   c CLIENT-SENT @ BUF$ {: k:^ ku:n :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" cursor" k ku JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE
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
      c CLIENT-SENT @ BUF$ BUF:N>BLEN c CLIENT-MARK @ BUF:REPLACE
   then
   r ;


: LIST-BODY ( ^u8 n ^client -- )
   {: p:^ pu:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p pu JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" recursive" true JSON:WRITE-FIELD-BOOL JSON:WRITE-COMMA
   s" include_deleted" false JSON:WRITE-FIELD-BOOL
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE ;


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


: POLL-BODY ( ^u8 n n ^client -- )
   {: k:^ ku:n secs:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" cursor" k ku JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" timeout" secs JSON:WRITE-FIELD-INT
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE ;


\ The body is silent until Dropbox answers, so only the whole call is
\ bounded: the timeout asked for, Dropbox's slack and ours.
: LONG-POLL ( ^client n -- verdict )
   {: c secs:n :}
   s" files/list_folder/longpoll" SPAN:MAKE c CLIENT-ROUTE !
   false c CLIENT-QUIET !
   c LINE-CLEAR c c CLIENT-NOTIFY @ SPAN:$ LINE+
   c s" /2/files/list_folder/longpoll" LINE+
   c PREPARE {: h:CURL:handle :}
   h secs SLACK + GRACE + 1000 * >MS CURL:TIMEOUT! s" timeout" OK
   h 0 0 CURL:LOW-SPEED! s" low speed" OK
   h c JSON-BODY
   c TRANSFER
   c CLASSIFY ;

public

\ files/list_folder of the path, recursive, and every page after it.
: LIST ( ^u8 n ^client [ ^entry -- ] -- reply )
   {: p:^ pu:n c each :}
   c CLIENT-SENT @ BUF:CLEAR
   p pu c LIST-BODY
   c s" files/list_folder" [: JSON-BODY ;] CALL
   c each PAGES ;


\ files/list_folder/continue from the cursor, deleted entries included.
: CHANGES ( ^u8 n ^client [ ^entry -- ] -- reply )
   {: k:^ ku:n c each :}
   k ku BUF:N>BLEN c CLIENT-SENT @ BUF:REPLACE
   c CONTINUE c each PAGES ;


: CURSOR ( ^client -- ^u8 n ) CLIENT-MARK @ BUF$ ;


\ files/list_folder/longpoll on the cursor for at most secs seconds.
: WAIT ( ^u8 n n ^client -- reply )
   {: k:^ ku:n secs:n c :}
   k ku secs c POLL-BODY
   c secs LONG-POLL MATCH verdict
      answer OF ENDOF
      rejected OF c s" a long poll refused a token" E-AUTH FAILED ENDOF
   ;MATCH
   c [: POLL-READ ;] ANSWERED ;


: CHANGED? ( ^client -- bool ) CLIENT-CHANGES @ ;
\ Seconds Dropbox asks to wait before the next long poll, 0 for none.
: BACKOFF ( ^client -- n ) CLIENT-BACKOFF @ ;


\ ---- files/download

\ files/download of rev:<rev>, that exact revision, from the offset. The
\ status, metadata and Content-Range are checked from the headers curl answers
\ at the first chunk, before any byte reaches body. A done answer calls body
\ once with the offset its bytes start at, the file's size and the fetch,
\ which READ-BODY reads until body returns; the length is checked once
\ READ-BODY reached the end. A body left unread is cancelled and the answer
\ is done. A transfer lost inside the body throws E-BODY-LOST from
\ READ-BODY, and the answer is the lost transfer's. A 416 from a nonzero
\ offset with the offset for its length calls body with the offset, that
\ size and a fetch at its end, and ENTRY is not this answer's; any other
\ starts over once from 0 with no Range. An answer that fails a check, a
\ 416 from 0 and an error that does not parse answer refused unverified,
\ logged once. A throw while the transfer is in flight, body's and
\ READ-BODY's included, cancels it and reads it to its end before it goes
\ on, so the client stays usable. Every other done answer carried
\ Dropbox-API-Result, and ENTRY is its entry.
: DOWNLOAD ( ^u8 n n ^client [ n n ^fetch -- ] -- reply )
   {: r:^ ru:n at:n c body :}
   construct reply done [: DROP-REPLY r ru at c body REQUESTED ;] catch
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


\ Whether the entry's path_lower is the path's full lowercase.
: AT? ( ^u8 n ^client -- bool )
   CLIENT-ENTRY DROPBOX-ENTRY:LOWER @ SPAN:$ UNICODE:LOWERS-TO? ;


\ Each reads the answer's entry and answers whether it is at the path;
\ DELETED-READ, given a rev, also whether it is a file at that rev.
: DELETED-READ ( ^u8 n ^u8 n ^client -- bool )
   {: p:^ pu:n r:^ ru:n c :}
   c construct kind deleted [: DELETED-MEMBER ;] ENTRY-PARSE
   p pu c AT? 0= if false exit then
   ru 0= if true exit then
   c CLIENT-ENTRY {: e :}
   e FILE? e DROPBOX-ENTRY:REV @ SPAN:$ r ru STR= and ;


: MADE-READ ( ^u8 n ^client -- bool )
   {: p:^ pu:n c :}
   c construct kind deleted [: MADE-MEMBER ;] ENTRY-PARSE
   p pu c AT? ;


\ A confirmation's get_metadata of the path: an entry at another path is
\ refused path-mismatch.
: CONFIRMED ( ^u8 n ^client -- reply )
   {: p:^ pu:n c :}
   p pu c METADATA {: m:reply :}
   m DONE? 0= if m exit then
   p pu c AT? if m exit then
   construct error path-mismatch construct reply refused ;


: MISMATCH? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF construct error path-mismatch DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ A confirmation that failed: retry, after the ms get_metadata asked for;
\ unlinked and path-mismatch stand.
: UNCONFIRMED ( reply -- reply )
   {: m:reply :}
   m MISMATCH? if m exit then
   m MATCH reply
      done OF 0 RETRY ENDOF
      refused OF drop 0 RETRY ENDOF
      retry OF RETRY ENDOF
      unlinked OF construct reply unlinked ENDOF
   ;MATCH ;


: NOT-FOUND? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF construct error not-found DROPBOX-ERROR:EQ ENDOF
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


\ A confirmation that answers in its call's place.
: STANDS? ( reply -- bool )
   {: r:reply :}
   r UNLINKED? r MISMATCH? or ;


: FOLDER? ( ^entry -- bool )
   DROPBOX-ENTRY:KIND @ construct kind folder DROPBOX-KIND:EQ ;


\ The path is absent, as a delete intends: done, with the entry cleared,
\ as Dropbox holds none.
: ABSENT ( ^client -- reply )
   CLIENT-ENTRY ENTRY-CLEAR construct reply done ;


\ A lost delete took effect only if the path is now not found.
: GONE ( ^u8 n ^client -- reply )
   {: p:^ pu:n c :}
   p pu c CONFIRMED {: r:reply :}
   r NOT-FOUND? if c ABSENT exit then
   r UNCONFIRMED ;


\ not-found is done, and a conflict once the path is gone, as a resent
\ applied delete answers; else a confirmation that STANDS? answers.
: DELETE-REFUSED ( error ^u8 n ^client -- reply )
   {: e:error p:^ pu:n c :}
   e construct error not-found DROPBOX-ERROR:EQ if c ABSENT exit then
   e construct error conflict DROPBOX-ERROR:EQ if
      p pu c CONFIRMED {: m:reply :}
      m NOT-FOUND? if c ABSENT exit then
      m STANDS? if m exit then
   then
   e construct reply refused ;


\ A lost create-folder took effect only if the path is now a folder.
: MADE ( ^u8 n ^client -- reply )
   {: p:^ pu:n c :}
   p pu c CONFIRMED {: r:reply :}
   r DONE? c CLIENT-ENTRY FOLDER? and if r exit then
   r UNCONFIRMED ;


\ A conflict is done once the path holds a folder, as a resent applied
\ create-folder answers; else a confirmation that STANDS? answers.
: FOLDER-REFUSED ( error ^u8 n ^client -- reply )
   {: e:error p:^ pu:n c :}
   e construct error conflict DROPBOX-ERROR:EQ if
      p pu c CONFIRMED {: m:reply :}
      m DONE? c CLIENT-ENTRY FOLDER? and
      if construct reply done exit then
      m STANDS? if m exit then
   then
   e construct reply refused ;


\ done stands if `read` finds its entry at the path; a lost answer or one
\ elsewhere goes to `lost`, a refusal to `refusal`, which confirm it.
: MUTATE ( ^client ^u8 n [ ^client -- bool ] [ ^client -- reply ]
           [ error ^client -- reply ] -- reply )
   {: c rt:^ rtu:n read lost refusal :}
   c rt rtu [: JSON-BODY ;] CALL {: r:reply :}
   c LOST? if c lost execute exit then
   r MATCH reply
      done OF
         c read execute
         if construct reply done else c lost execute then
      ENDOF
      refused OF c refusal execute ENDOF
      retry OF RETRY ENDOF
      unlinked OF construct reply unlinked ENDOF
   ;MATCH ;


: DELETE-BODY ( ^u8 n ^u8 n ^client -- )
   {: p:^ pu:n r:^ ru:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p pu JSON:WRITE-FIELD-S
   ru 0<> if JSON:WRITE-COMMA s" parent_rev" r ru JSON:WRITE-FIELD-S then
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE ;


: FOLDER-BODY ( ^u8 n ^client -- )
   {: p:^ pu:n c :}
   c BODY-OPEN JSON:WRITE-OBJECT-START
   s" path" p pu JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" autorename" false JSON:WRITE-FIELD-BOOL
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE ;


\ The code grant's form body, in the line buffer as FORM's is.
: CODE-FORM ( ^u8 n ^u8 n ^client -- ^u8 n )
   {: k:^ ku:n v:^ vu:n c :}
   c CLIENT-LINE @ {: buf :}
   buf BUF:CLEAR
   s" grant_type=authorization_code&code=" buf APPEND
   k ku buf ENCODED+
   s" &code_verifier=" buf APPEND
   v vu buf ENCODED+
   s" &client_id=" buf APPEND
   c CLIENT-KEY @ SPAN:$ buf ENCODED+
   buf BUF$ ;


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
: DELETE ( ^u8 n ^u8 n ^client -- reply )
   {: p:^ pu:n r:^ ru:n c :}
   p pu r ru c DELETE-BODY
   c s" files/delete_v2" [: drop p pu r ru c DELETED-READ ;]
   [: drop p pu c GONE ;]
   [: drop p pu c DELETE-REFUSED ;] MUTATE ;


\ files/create_folder_v2, which never renames.
: CREATE-FOLDER ( ^u8 n ^client -- reply )
   {: p:^ pu:n c :}
   p pu c FOLDER-BODY
   c s" files/create_folder_v2" [: drop p pu c MADE-READ ;]
   [: drop p pu c MADE ;]
   [: drop p pu c FOLDER-REFUSED ;] MUTATE ;


\ oauth2/token's authorization_code grant of the code and its PKCE
\ verifier; unlinked means the code is dead.
: EXCHANGE ( ^u8 n ^u8 n ^client -- reply )
   {: k:^ ku:n v:^ vu:n c :}
   c [: drop k ku v vu c CODE-FORM ;] TOKEN-POST
   c [: KEPT-GRANT ;] [: drop construct reply unlinked ;] REFRESHED ;


\ The refresh token: the config's, or the one an EXCHANGE kept.
: REFRESH-TOKEN ( ^client -- ^u8 n ) CLIENT-TOKEN @ BUF$ ;


\ ---- files/upload and upload sessions

\ A file up to CHUNK-SIZE bytes goes in one files/upload; a larger one
\ through an upload session: CHUNK-SIZE appends, then a finish that carries
\ no content_hash, as Dropbox checks that field against the call's own
\ bytes. The entry Dropbox commits must have the upload's path and content
\ hash. A lost answer to the upload or the finish, an entry at another
\ path, or a conflict, which a POST libcurl resent can answer for an
\ upload already applied, is confirmed by get_metadata. A run's chunk
\ buffer is MEM's, released before UPLOAD answers or throws.

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
   h WHOLE$ h DIGEST$ 32 SHA256-FEED
   h BLOCK$ SHA256-BEGIN
   0 h HASHER-FILL ! ;


\ Feeds what fits in the block; answers the bytes it took.
: BLOCK-FEED ( ^u8 n ^hasher -- n )
   {: a:^ u:n h :}
   BLOCK h HASHER-FILL @ - u min {: k:n :}
   h BLOCK$ a k SHA256-FEED
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
: HASH-END ( ^hasher -- ^u8 n )
   {: h :}
   h HASHER-FILL @ 0 > if h BLOCK-END then
   h WHOLE$ h DIGEST$ SHA256-END
   h DIGEST$ h HEX$ SHA256>HEX
   h HEX$ 64 ;

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
: SESSION$ ( ^run -- ^u8 n ) dup RUN-ID CELLS64>BYTES swap RUN-ID-U @ ;


\ ---- reading the stage

: STAGE-FAILED ( ^run ^u8 n -- )
   {: r why:^ wu:n :}
   LOG-OPEN s" upload of " LOG:TEXT+
   r RUN-UP @ DROPBOX-UPLOAD:PATH @ SPAN:$ LOG:TEXT+
   s" : " LOG:TEXT+ why wu LOG:TEXT+ LOG:;LINE
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
      refused OF r swap READ-REFUSED ENDOF
   ;MATCH ;


: SHORT ( ^run -- )
   s" the stage is shorter than its size" STAGE-FAILED ;


\ ---- the requests

: MODE+ ( ^JSON:writer ^upload -- ^JSON:writer )
   DROPBOX-UPLOAD:REV @ SPAN:$ {: v:^ vu:n :}
   vu 0= if s" mode" s" add" JSON:WRITE-FIELD-S exit then
   s" mode" JSON:WRITE-KEY JSON:WRITE-OBJECT-START
   s" .tag" s" update" JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" update" v vu JSON:WRITE-FIELD-S JSON:WRITE-OBJECT-END ;


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
: PATIENT ( CURL:handle -- )
   {: h:CURL:handle :}
   h FINISH-WAIT 1000 * >MS CURL:TIMEOUT! s" timeout" OK
   h 0 0 CURL:LOW-SPEED! s" low speed" OK ;


\ The argument the fields write, the bytes, and the deadlines.
: ARGUED ( CURL:handle ^client ^u8 n [ ^JSON:writer -- ^JSON:writer ] [ CURL:handle -- ] -- )
   {: h:CURL:handle c b:^ bu:n fields deadline :}
   c BODY-OPEN JSON:WRITE-OBJECT-START fields execute
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE
   c LINE-CLEAR c s" Dropbox-API-Arg: " LINE+
   c c CLIENT-BODY @ BUF$ LINE+
   h c LINE$ CURL:HEADER+ s" header" OK
   h s" Content-Type: application/octet-stream" CURL:HEADER+ s" header" OK
   h b bu CURL:BODY! s" body" OK
   h deadline execute ;


\ A POST of the bytes to <content>/2/<route>, under the deadlines.
: SENT ( ^run ^u8 n ^u8 n [ ^JSON:writer -- ^JSON:writer ] [ CURL:handle -- ] -- reply )
   {: r rt:^ ru:n b:^ bu:n fields deadline :}
   r RUN-CLIENT @ {: c :}
   c c CLIENT-CONTENT @ rt ru
   [: b bu fields deadline ARGUED ;] [: RECEIVED ;] CALL-AT ;


: SINGLE-SENT ( ^run -- reply )
   {: r :}
   r RUN-UP @ {: up :}
   r s" files/upload" r CHUNK$
   [: up COMMIT+ JSON:WRITE-COMMA s" content_hash"
      up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ JSON:WRITE-FIELD-S ;]
   [: STALLED ;] SENT ;


: START-SENT ( ^run -- reply )
   s" files/upload_session/start" s" " [: CLOSE+ ;] [: STALLED ;]
   SENT ;


: APPEND-SENT ( ^run -- reply )
   {: r :}
   r s" files/upload_session/append_v2" r CHUNK$
   [: r r RUN-ACCEPTED @ CURSOR+ JSON:WRITE-COMMA CLOSE+ ;]
   [: STALLED ;] SENT ;


: FINISH-SENT ( ^run -- reply )
   {: r :}
   r s" files/upload_session/finish" s" "
   [: r r SIZE CURSOR+ JSON:WRITE-COMMA
      s" commit" JSON:WRITE-KEY JSON:WRITE-OBJECT-START
      r RUN-UP @ COMMIT+ JSON:WRITE-OBJECT-END ;]
   [: PATIENT ;] SENT ;


\ ---- the answers

\ Reads the entry Dropbox committed: whether it is at the upload's path.
: COMMITTED-AT? ( ^run -- bool )
   {: r :}
   r RUN-CLIENT @ {: c :}
   c FILE-READ
   r RUN-UP @ DROPBOX-UPLOAD:PATH @ SPAN:$ c AT? ;


\ The committed entry has the upload's content hash, else last is refused
\ content-hash-mismatch.
: COMMITTED? ( ^run -- bool )
   {: r :}
   r RUN-CLIENT @ CLIENT-ENTRY {: e :}
   r RUN-UP @ {: up :}
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ STR= if true exit then
   construct error content-hash-mismatch construct reply refused
   r RUN-LAST !
   false ;


: REFUSAL? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF drop true ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


: CONFLICT? ( reply -- bool )
   MATCH reply
      done OF false ENDOF
      refused OF construct error conflict DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;


\ A session Dropbox no longer takes chunks for.
: GONE-TAG? ( ^u8 n -- bool )
   {: t:^ tu:n :}
   t tu s" not_found" STR= t tu s" closed" STR= or
   t tu s" incorrect_offset" STR= or ;


\ incorrect_offset at the chunk's end: Dropbox already holds the chunk.
: HELD? ( reply ^run -- bool )
   {: rep:reply r :}
   rep REFUSAL? 0= if false exit then
   r RUN-CLIENT @ {: c :}
   c TAG$ s" incorrect_offset" STR=
   c CLIENT-CORRECT @ r RUN-ACCEPTED @ r RUN-CHUNK @ + = and ;


: APPEND-GONE? ( reply ^client -- bool )
   {: rep:reply c :}
   rep REFUSAL? 0= if false exit then
   c TAG$ GONE-TAG? ;


: FINISH-GONE? ( reply ^client -- bool )
   {: rep:reply c :}
   rep REFUSAL? 0= if false exit then
   c TAG$ s" lookup_failed" STR= c LEAF$ GONE-TAG? and ;


: SESSION-MEMBER ( JSON:reader ^client ^run -- JSON:reader )
   {: c r :}
   s" session_id" JSON:READ-STR-EQ? 0= if SKIP exit then
   c STRING SPAN:$ {: a:^ u:n :}
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
   single starting appending finishing confirming verifying restarting
   ended ;ENUM
ENUM send-event committed elsewhere lost conflict failed ;ENUM
ENUM start-event opened lost failed ;ENUM
ENUM append-event stored complete lost cut gone failed ;ENUM
ENUM finish-event committed elsewhere lost conflict gone failed ;ENUM
ENUM confirm-event same elsewhere other unlinked ;ENUM
ENUM restart-event once twice ;ENUM


: SEND-DONE ( ^run -- send-event )
   {: r :}
   r COMMITTED-AT? 0= if construct send-event elsewhere exit then
   r COMMITTED? if construct send-event committed exit then
   construct send-event failed ;


: SEND-SENSE ( ^run -- send-event )
   {: r :}
   r SIZE r RUN-CHUNK !
   r CHUNK-READ
   r RUN-CHUNK @ r SIZE <> if r SHORT then
   r SINGLE-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r SEND-DONE exit then
   r RUN-CLIENT @ LOST? if construct send-event lost exit then
   rep CONFLICT? if construct send-event conflict exit then
   construct send-event failed ;


: START-SENSE ( ^run -- start-event )
   {: r :}
   r START-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r SESSION-READ construct start-event opened exit then
   r RUN-CLIENT @ LOST? if construct start-event lost exit then
   construct start-event failed ;


: ACCEPTED ( ^run -- append-event )
   {: r :}
   r RUN-ACCEPTED @ r RUN-CHUNK @ + r SIZE =
   if construct append-event complete exit then
   construct append-event stored ;


: LOST-AGAIN ( ^run -- append-event )
   {: r :}
   r RUN-RESENT @ if construct append-event cut exit then
   true r RUN-RESENT !
   construct append-event lost ;


: APPEND-SENSE ( ^run -- append-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r SIZE r RUN-ACCEPTED @ - CHUNK-SIZE min r RUN-CHUNK !
   r CHUNK-READ
   r RUN-CHUNK @ 0= if r SHORT then
   r APPEND-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r ACCEPTED exit then
   c LOST? if r LOST-AGAIN exit then
   rep r HELD? if r ACCEPTED exit then
   rep c APPEND-GONE? if construct append-event gone exit then
   construct append-event failed ;


: FINISH-DONE ( ^run -- finish-event )
   {: r :}
   r COMMITTED-AT? 0= if construct finish-event elsewhere exit then
   r COMMITTED? if construct finish-event committed exit then
   construct finish-event failed ;


: FINISH-SENSE ( ^run -- finish-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r FINISH-SENT {: rep:reply :}
   rep r RUN-LAST !
   rep DONE? if r FINISH-DONE exit then
   c LOST? if construct finish-event lost exit then
   rep CONFLICT? if construct finish-event conflict exit then
   rep c FINISH-GONE? if construct finish-event gone exit then
   construct finish-event failed ;


\ get_metadata of the path shows a file with the upload's content hash,
\ or an entry at another path, or answers unlinked.
: CONFIRM-SENSE ( ^run -- confirm-event )
   {: r :}
   r RUN-CLIENT @ {: c :}
   r RUN-UP @ {: up :}
   up DROPBOX-UPLOAD:PATH @ SPAN:$ c CONFIRMED {: m:reply :}
   m UNLINKED? if construct confirm-event unlinked exit then
   m MISMATCH? if construct confirm-event elsewhere exit then
   m DONE? 0= if construct confirm-event other exit then
   c CLIENT-ENTRY {: e :}
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$
   up DROPBOX-UPLOAD:CONTENT-HASH @ SPAN:$ STR= e FILE? and
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


: ANSWER-RETRY ( ^run -- ) {: r :} 0 RETRY r RUN-ANSWER ! ;


: ANSWER-UNLINKED ( ^run -- )
   {: r :}
   construct reply unlinked r RUN-ANSWER ! ;


: ANSWER-MISMATCH ( ^run -- )
   {: r :}
   construct error path-mismatch construct reply refused
   r RUN-ANSWER ! ;


\ A done answer at another path, as a lost one: retry unless confirmed.
: DISTRUST ( ^run -- ) {: r :} 0 RETRY r RUN-LAST ! ;


\ Answers the last call's reply as it came, or as COMMITTED? or DISTRUST
\ set it.
: ANSWER-REPLY ( ^run -- ) {: r :} r RUN-LAST @ r RUN-ANSWER ! ;


: CHUNK-ADVANCE ( ^run -- )
   {: r :}
   r RUN-CHUNK @ r RUN-ACCEPTED +!
   false r RUN-RESENT ! ;


: REWIND ( ^run -- )
   {: r :}
   0 r RUN-ACCEPTED ! false r RUN-RESENT ! ;


\ confirming asks whether an answer it cannot trust took effect; verifying
\ asks whether a finish whose session is gone was a resend Dropbox already
\ committed, and starts over only when it was not.
FSM:DEFINE SESSION ( ^run ) upload-step send-event
   IN single  SEND-SENSE
      committed  ANSWER-DONE   >ended
      elsewhere  DISTRUST      >confirming
      lost       -             >confirming
      conflict   -             >confirming
      failed     ANSWER-REPLY  >ended
   IN starting  START-SENSE ( start-event )
      opened  -             >appending
      lost    ANSWER-RETRY  >ended
      failed  ANSWER-REPLY  >ended
   IN appending  APPEND-SENSE ( append-event )
      stored    CHUNK-ADVANCE  >appending
      complete  CHUNK-ADVANCE  >finishing
      lost      -              >appending
      cut       ANSWER-RETRY   >ended
      gone      -              >restarting
      failed    ANSWER-REPLY   >ended
   IN finishing  FINISH-SENSE ( finish-event )
      committed  ANSWER-DONE   >ended
      elsewhere  DISTRUST      >confirming
      lost       -             >confirming
      conflict   -             >confirming
      gone       -             >verifying
      failed     ANSWER-REPLY  >ended
   IN confirming  CONFIRM-SENSE ( confirm-event )
      same       ANSWER-DONE      >ended
      elsewhere  ANSWER-MISMATCH  >ended
      other      ANSWER-REPLY     >ended
      unlinked   ANSWER-UNLINKED  >ended
   IN verifying  CONFIRM-SENSE ( confirm-event )
      same       ANSWER-DONE      >ended
      elsewhere  ANSWER-MISMATCH  >ended
      other      -                >restarting
      unlinked   ANSWER-UNLINKED  >ended
   IN restarting  RESTART-SENSE ( restart-event )
      once   REWIND        >starting
      twice  ANSWER-RETRY  >ended
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
