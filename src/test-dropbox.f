\ test-dropbox.f - a fake Dropbox for tests, never a production server: the
\ routes /oauth2/token, /2/users/get_current_account, /2/files/get_metadata,
\ /2/files/list_folder, its /continue, its /longpoll, /2/files/download,
\ /2/files/delete_v2, /2/files/create_folder_v2, /2/files/upload and
\ /2/files/upload_session/* on Habu's HTTP server at 127.0.0.1, answered in
\ the shapes tests/dropbox_fake.rs gives them. It accepts one app key and
\ refresh token, and one code GRANT! sets; it issues the access tokens
\ sl.fake-1, sl.fake-2 and on, and EXPIRE expires every token issued so far.
\ ROTATE! makes the next refresh also answer a new refresh token, which the
\ token route accepts from then on.
\ LOSE applies the next API call and loses its answer; each CUT loses one
\ more API call's answer, before the call takes effect, and CUT-TOKEN a token
\ request's; GARBLE answers the next API call, before it takes effect, with a
\ line that is not HTTP. REVOKE refuses every access token, issued or yet to
\ be, as invalid until RESET; the refresh still issues them. DENY refuses
\ every call that carries a token 403 until RESET. A call must carry the
\ Path-Root ROOT! expects, none when that is empty, else it answers 422.
\ DURING-DOWNLOAD! hooks a quotation into the next download,
\ DURING-LISTING! into the next listing call, DURING-POLL! into the next
\ long poll before it answers and AFTER-POLL! after.
\ Scripted answers go before a route's own: a call takes the first left
\ bound to its path, else, an API call only, the first left bound to none.
\ ARG-SCRIPT! also binds one to a text the call's Dropbox-API-Arg must
\ contain.
\ It records each request once, in order: its route, its Dropbox-API-Arg
\ and its body's first KiB, which SEEN$, CALLS, ARGS-TO$ and BODIES-TO$
\ read; the last API call's Authorization, Path-Root and Content-Type; the
\ last token request's Content-Type; and the last request's User-Agent.
\ STORAGE CLASS. PROCESS-WIDE: one worker serves every request, so its handler
\ alone writes the state while a test waits on its call, and the test sets it
\ between calls; only RESUME-BODY sets it during one, and the
\ DURING-DOWNLOAD!, DURING-LISTING!, DURING-POLL! and AFTER-POLL! hooks run
\ on the fake's task. A
\ body stays in its buffer, as HTTP:BODY! borrows it, until the next
\ request.

require src/lib/string.f
require src/lib/span.f
require src/lib/fmt.f
require src/lib/json.f
require src/lib/adt/option.f
require src/lib/task.f
require src/lib/time.f
require src/lib/byte-buffer.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/net/tcp4.f
require src/lib/net/http.f
require src/dropbox.f

package TEST-DROPBOX
private

8 constant SLOTS
128 constant PATH-CAP
1024 constant TEXT-CAP
128 constant NAME-CAP

create KEY NAME-CAP allot
variable KEY-U
create REFRESH NAME-CAP allot
variable REFRESH-U
create ROOT NAME-CAP allot
variable ROOT-U
create ORIGIN NAME-CAP allot
variable ORIGIN-U
create ISSUED NAME-CAP allot
variable ISSUED-U
create ROTATED NAME-CAP allot
variable ROTATED-U
variable ISSUES
\ Tokens numbered up to this one are expired.
variable EXPIRED
\ Every access token is refused as invalid.
variable REVOKED
variable DENIED

SLOTS PATH-CAP * BUFFER: PATHS
SLOTS TYPED-BUFFER PATH-US n
\ An entry is held as its plain FileMetadata or FolderMetadata, the shape
\ upload, download and create_folder_v2 answer, and FOLDERS marks a
\ folder's. TAGGED+ builds the Metadata union get_metadata and delete_v2
\ answer.
SLOTS TEXT-CAP * BUFFER: ENTRIES
SLOTS TYPED-BUFFER ENTRY-US n
SLOTS TYPED-BUFFER FOLDERS bool
variable FILES

SLOTS TYPED-BUFFER STATUSES n
SLOTS NAME-CAP * BUFFER: NAMES
SLOTS TYPED-BUFFER NAME-US n
SLOTS NAME-CAP * BUFFER: VALUES
SLOTS TYPED-BUFFER VALUE-US n
SLOTS TEXT-CAP * BUFFER: BODIES
SLOTS TYPED-BUFFER BODY-US n
SLOTS PATH-CAP * BUFFER: ROUTES
SLOTS TYPED-BUFFER ROUTE-US n
SLOTS PATH-CAP * BUFFER: NEEDLES
SLOTS TYPED-BUFFER NEEDLE-US n
SLOTS TYPED-BUFFER SPENT bool
variable SCRIPTS

create AUTH NAME-CAP allot
variable AUTH-U
create ROOT-SENT TEXT-CAP allot
variable ROOT-SENT-U
TYPED-VARIABLE ROOTED bool
create TYPE-SENT NAME-CAP allot
variable TYPE-SENT-U
TYPED-VARIABLE TYPED bool
create TOKEN-TYPE NAME-CAP allot
variable TOKEN-TYPE-U
create AGENT-SENT NAME-CAP allot
variable AGENT-SENT-U
TYPED-VARIABLE LEAKED bool

create OUT TEXT-CAP allot
variable OUT-U
create ASKED PATH-CAP allot
variable ASKED-U
TYPED-VARIABLE PARSER JSON:cursor
TYPED-VARIABLE LOSING bool
variable CUTS
TYPED-VARIABLE GARBLING bool
TYPED-VARIABLE TOKEN-CUTTING bool


\ Copies a string into a buffer of cap bytes and answers its length.
: STORE ( str ^u8 n -- n )
   {: s dst:^ cap:n :}
   s dst cap SPAN:MAKE SPAN:COPY s STR:len ;


TYPED-VARIABLE UNESCAPED ^VEC:vector<u8>
: UNESCAPER ( -- ) HEAP:ALLOCATOR 0 [type] u8 VEC:NEW UNESCAPED ! ;
UNESCAPER

\ Decodes the reader's string into a buffer of cap bytes and answers its length.
: READ-INTO ( JSON:reader ^u8 n -- JSON:reader n )
   {: d:^ cap:n :} UNESCAPED @ JSON:READ-STR d cap STORE ;

: AT ( ^u8 n n -- ^u8 n )
   {: base:^ cap:n i:n :}
   base i cap * + cap ;


: KEY$ ( -- str ) KEY KEY-U @ >str ;
: REFRESH$ ( -- str ) REFRESH REFRESH-U @ >str ;
: ROOT$ ( -- str ) ROOT ROOT-U @ >str ;
: OUT$ ( -- str ) OUT OUT-U @ >str ;
: PATH$ ( n -- str )
   {: i:n :} PATHS i PATH-CAP * + i PATH-US @ >str ;
: ENTRY$ ( n -- str )
   {: i:n :} ENTRIES i TEXT-CAP * + i ENTRY-US @ >str ;
: NAME$ ( n -- str )
   {: i:n :} NAMES i NAME-CAP * + i NAME-US @ >str ;
: VALUE$ ( n -- str )
   {: i:n :} VALUES i NAME-CAP * + i VALUE-US @ >str ;
: BODY$ ( n -- str )
   {: i:n :} BODIES i TEXT-CAP * + i BODY-US @ >str ;
: ROUTE$ ( n -- str )
   {: i:n :} ROUTES i PATH-CAP * + i ROUTE-US @ >str ;
: NEEDLE$ ( n -- str )
   {: i:n :} NEEDLES i PATH-CAP * + i NEEDLE-US @ >str ;


\ The builder's text into OUT, which outlives the handler.
: BUILT ( -- str )
   SB$ OUT TEXT-CAP STORE OUT-U !
   OUT$ ;


\ Entry i appended as a Metadata union: its `.tag`, then the plain
\ record's members after its `{`.
: TAGGED+ ( n -- )
   {: i:n :}
   i FOLDERS @ if S\" {\q.tag\q:\qfolder\q," else S\" {\q.tag\q:\qfile\q," then
   SB-APPEND
   i ENTRY$ str> {: e:^ eu:n :}
   e 1 + eu 1 - >str SB-APPEND ;


: TAGGED$ ( n -- str ) SB-RESET TAGGED+ BUILT ;


: ANSWER! ( HTTP:response str -- )
   {: a:HTTP:response b :}
   a s" Content-Type" s" application/json" HTTP:HEADER!
   a b HTTP:BODY! ;


\ ---- what was sent

\ Each request's route, Dropbox-API-Arg and body's first KiB lie back to
\ back in CALL-TEXT from its record's start; the fields hold their lengths.
STRUCTURE call DERIVE addr
   FIELD start n
   FIELD route n
   FIELD arg n
   FIELD body n
;STRUCTURE
create CALL-TEXT BUF:HDR-BYTES allot
TYPED-VARIABLE CALL-LOG ^VEC:vector<call>
\ SEEN$, ARGS-TO$ and BODIES-TO$ answer their text here.
create JOINED BUF:HDR-BYTES allot


: CALLS-MADE ( -- )
   CALL-TEXT TEXT-CAP BUF:N>BLEN BUF:INIT
   JOINED TEXT-CAP BUF:N>BLEN BUF:INIT
   HEAP:ALLOCATOR 0 [type] call VEC:NEW CALL-LOG ! ;
CALLS-MADE


: CALL-COUNT ( -- n ) CALL-LOG @ VEC:COUNT ;
: CALL-OF ( n -- ^call ) {: i:n :} CALL-LOG @ i VEC:AT ;


\ The u bytes of call i's text from offset off.
: CALL-SPAN ( n n n -- str )
   {: i:n off:n u:n :}
   CALL-TEXT BUF:SPAN$ drop i CALL-OF CALL-START @ + off + u >str ;


: ROUTE-OF$ ( n -- str )
   {: i:n :}
   i 0 i CALL-OF CALL-ROUTE @ CALL-SPAN ;


: ARG-OF$ ( n -- str )
   {: i:n :}
   i CALL-OF {: c :}
   i c CALL-ROUTE @ c CALL-ARG @ CALL-SPAN ;


: BODY-OF$ ( n -- str )
   {: i:n :}
   i CALL-OF {: c :}
   i c CALL-ROUTE @ c CALL-ARG @ + c CALL-BODY @ CALL-SPAN ;


: CALL-TEXT+ ( str -- ) str> BUF:N>BLEN CALL-TEXT BUF:APPEND-SPAN ;


\ The request's Dropbox-API-Arg, empty when it sends none.
: ARG-OF ( HTTP:request -- str )
   s" Dropbox-API-Arg" HTTP:HEADER-OF$ 0= if str> drop 0 >str then ;


\ The body is read first, so one that fails to arrive records nothing.
: CALL+ ( HTTP:request -- )
   {: q:HTTP:request :}
   q HTTP:PATH$ q ARG-OF q HTTP:BODY$ str> TEXT-CAP min >str
   {: p a b :}
   CALL-LOG @ VEC:PUSH {: c :}
   CALL-TEXT BUF:LEN@ BUF:BLEN>N c CALL-START !
   p STR:len c CALL-ROUTE ! a STR:len c CALL-ARG !
   b STR:len c CALL-BODY !
   p CALL-TEXT+ a CALL-TEXT+ b CALL-TEXT+ ;


: CALLS-RESET ( -- ) CALL-TEXT BUF:CLEAR CALL-LOG @ 0 VEC:RESIZE ;


\ Appends a to JOINED, after a space unless JOINED is empty.
: JOIN+ ( str -- )
   {: s :}
   JOINED BUF:LEN@ BUF:BLEN>N 0<> if 32 JOINED BUF:APPEND-BYTE then
   s str> BUF:N>BLEN JOINED BUF:APPEND-SPAN ;


: JOINED$ ( -- str ) JOINED BUF:SPAN$ BUF:BLEN>N >str ;


\ What f answers for each call to the route r, joined; an empty answer
\ adds nothing.
: JOINED-TO$ ( str [ n -- str ] -- str )
   {: r f :}
   JOINED BUF:CLEAR
   CALL-COUNT 0 ?do
      i ROUTE-OF$ r STR:= if
         i f execute {: a :}
         a STR:len 0<> if a JOIN+ then
      then
   loop JOINED$ ;


: SENT ( HTTP:request str ^u8 n -- n bool )
   {: q:HTTP:request nm dst:^ cap:n :}
   q nm HTTP:HEADER-OF$ if dst cap STORE true exit then
   drop 0 false ;


: TOKEN-HEADERS ( HTTP:request -- )
   {: q:HTTP:request :}
   q s" Authorization" HTTP:HEADER-OF$ nip
   q s" Dropbox-API-Path-Root" HTTP:HEADER-OF$ nip or
   if true LEAKED ! then ;


: RECORD ( HTTP:request -- )
   {: q:HTTP:request :}
   q CALL+
   q s" User-Agent" AGENT-SENT NAME-CAP SENT drop AGENT-SENT-U !
   q HTTP:PATH$ s" /oauth2/token" STR:= if
      q s" Content-Type" TOKEN-TYPE NAME-CAP SENT drop TOKEN-TYPE-U !
      q TOKEN-HEADERS exit
   then
   q HTTP:PATH$ s" /2/files/list_folder/longpoll" STR:=
   if q TOKEN-HEADERS exit then
   q s" Authorization" AUTH NAME-CAP SENT drop AUTH-U !
   q s" Dropbox-API-Path-Root" ROOT-SENT TEXT-CAP SENT ROOTED ! ROOT-SENT-U !
   q s" Content-Type" TYPE-SENT NAME-CAP SENT TYPED ! TYPE-SENT-U ! ;


: API? ( HTTP:request -- bool ) HTTP:PATH$ s" /oauth2/token" STR:= 0= ;


\ The first scripted answer left bound to the route path, the empty
\ path standing for none, whose text q's argument contains; -1 when no
\ answer is.
: LEFT-FOR ( HTTP:request str -- n )
   {: q:HTTP:request p :}
   q ARG-OF {: a :}
   SCRIPTS @ 0 ?do
      i SPENT @ 0= i ROUTE$ p STR:= and a i NEEDLE$ STR:CONTAINS? and
      if i unloop exit then
   loop -1 ;


\ Sends a call the first answer left bound to its path, else, an API call
\ only, the first left bound to none, if there is one.
: SCRIPTED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   q q HTTP:PATH$ LEFT-FOR {: bound:n :}
   bound 0 < q API? and if q s" " LEFT-FOR else bound then {: i:n :}
   i 0 < if false exit then
   true i SPENT !
   a i STATUSES @ HTTP:STATUS!
   i NAME$ STR:len 0<> if a i NAME$ i VALUE$ HTTP:HEADER! then
   a i BODY$ ANSWER!
   true ;


\ ---- the token

\ A token form is read as a form decoder reads it: & and = part names and
\ values, + is a space, %XX a byte, and any byte its encoder escapes is
\ malformed. DECODED holds each name and value followed by a NUL.
create DECODED TEXT-CAP allot
variable DECODED-U
variable FORM-AT


\ A byte a form may carry unescaped.
: PLAIN? ( n -- bool )
   {: b:n :}
   b STR:DIGIT? b STR:ASCII-LOWER dup 97 >= swap 122 <= and or
   b 45 = or b 46 = or b 95 = or b 126 = or b 42 = or ;


\ The byte a %XX at the offset names and the offset after it; -1 for a
\ malformed escape.
: ESCAPED ( str n -- n n )
   {: s at:n :}
   s str> {: a:^ u:n :}
   at 3 + u > if -1 u exit then
   a at 1+ + c@ a at 2 + + c@ {: h:n l:n :}
   h STR:HEX-DIGIT? l STR:HEX-DIGIT? and 0= if -1 u exit then
   h STR:HEX-DIGIT-VALUE 16 * l STR:HEX-DIGIT-VALUE + at 3 + ;


\ The byte at the offset, decoded, and the offset after it; -1 for one
\ the form may not carry.
: FORM-BYTE ( str n -- n n )
   {: s at:n :}
   s STR:data at + c@ {: b:n :}
   b 43 = if 32 at 1+ exit then
   b 37 = if s at ESCAPED exit then
   b PLAIN? if b else -1 then at 1+ ;


\ The byte onto DECODED; false once it is full.
: KEPT ( n -- bool )
   {: b:n :}
   DECODED-U @ TEXT-CAP >= if false exit then
   b DECODED DECODED-U @ + c! 1 DECODED-U +! true ;


\ One step from FORM-AT: a separator as a NUL, else a decoded byte, which
\ may not be a NUL; false when the form is malformed.
: FORM-STEP ( str n -- bool )
   {: s at:n :}
   s STR:data at + c@ {: b:n :}
   b 38 = b 61 = or if at 1+ FORM-AT ! 0 KEPT exit then
   s at FORM-BYTE FORM-AT ! {: d:n :}
   d 0 <= if false exit then
   d KEPT ;


\ A form body's names and values as DECODED holds them; empty when it is
\ malformed.
: FIELDS$ ( str -- str )
   {: s :}
   0 DECODED-U ! 0 FORM-AT !
   begin FORM-AT @ s STR:len < while
      s FORM-AT @ FORM-STEP 0= if DECODED 0 >str exit then
   repeat
   0 KEPT 0= if DECODED 0 >str exit then
   DECODED DECODED-U @ >str ;


: FIELD+ ( str -- ) SB-APPEND 0 SB-APPEND-C ;


\ The refresh form's names and values, as FIELDS$ decodes them.
: FORM$ ( -- str )
   SB-RESET
   s" grant_type" FIELD+ s" refresh_token" FIELD+
   s" refresh_token" FIELD+ REFRESH$ FIELD+
   s" client_id" FIELD+ KEY$ FIELD+
   SB$ ;


: ISSUE ( -- )
   1 ISSUES +!
   SB-RESET s" sl.fake-" SB-APPEND ISSUES @ FMT:SB-INT
   SB$ ISSUED NAME-CAP STORE ISSUED-U ! ;


\ The rotated refresh token, which the token route accepts from then on.
: ROTATION+ ( -- )
   S\" \q,\qrefresh_token\q:\q" SB-APPEND
   ROTATED ROTATED-U @ >str SB-APPEND
   ROTATED ROTATED-U @ >str REFRESH NAME-CAP STORE REFRESH-U !
   0 ROTATED-U ! ;


: TOKEN ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q HTTP:BODY$ FIELDS$ FORM$ STR:= 0= if
      a 400 HTTP:STATUS!
      a S\" {\qerror\q:\qinvalid_grant\q,\qerror_description\q:\qrefresh token is invalid or revoked\q}" ANSWER!
      exit
   then
   ISSUE
   SB-RESET S\" {\qaccess_token\q:\q" SB-APPEND
   ISSUED ISSUED-U @ >str SB-APPEND
   ROTATED-U @ 0<> if ROTATION+ then
   S\" \q,\qtoken_type\q:\qbearer\q,\qexpires_in\q:14400}" SB-APPEND
   a BUILT ANSWER! ;


\ ---- calls

: UNAUTHORIZED! ( HTTP:response str -- )
   {: a:HTTP:response t :}
   a 401 HTTP:STATUS!
   SB-RESET S\" {\qerror_summary\q:\q" SB-APPEND t SB-APPEND
   S\" /...\q,\qerror\q:{\q.tag\q:\q" SB-APPEND t SB-APPEND
   S\" \q}}" SB-APPEND
   a BUILT ANSWER! ;


\ The number of an issued token in an Authorization value, else -1.
: TOKEN-NUMBER ( str -- n )
   {: s :}
   s str> {: t:^ tu:n :}
   s" Bearer sl.fake-" STR:len {: pu:n :}
   tu pu <= if -1 exit then
   t pu >str s" Bearer sl.fake-" STR:= 0= if -1 exit then
   t pu + tu pu - >str STR:PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF ENDOF
   ;MATCH ;


: AUTHORIZED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   q s" Authorization" HTTP:HEADER-OF$
   0= if drop -1 else TOKEN-NUMBER then
   {: k:n :}
   k 1 < k ISSUES @ > or REVOKED @ or if
      a s" invalid_access_token" UNAUTHORIZED! false exit
   then
   k EXPIRED @ <= if a s" expired_access_token" UNAUTHORIZED! false exit then
   true ;


: ROOT-LINE$ ( -- str )
   SB-RESET S\" {\q.tag\q:\qroot\q,\qroot\q:\q" SB-APPEND ROOT$ SB-APPEND
   S\" \q}" SB-APPEND SB$ ;


: ROOT-OK? ( HTTP:request -- bool )
   {: q:HTTP:request :}
   q s" Dropbox-API-Path-Root" HTTP:HEADER-OF$ {: v sent:bool :}
   ROOT-U @ 0= if sent 0= exit then
   sent if v ROOT-LINE$ STR:= else false then ;


: ROOTED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   q ROOT-OK? if true exit then
   a 422 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qinvalid_root/...\q,\qerror\q:{\q.tag\q:\qinvalid_root\q,\qinvalid_root\q:{\q.tag\q:\quser\q}}}" ANSWER!
   false ;


: FORBIDDEN! ( HTTP:response -- )
   {: a:HTTP:response :}
   a 403 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qno_permission/...\q,\qerror\q:{\q.tag\q:\qno_permission\q}}" ANSWER! ;


: ADMITTED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   DENIED @ if a FORBIDDEN! false exit then
   q a AUTHORIZED? 0= if false exit then
   q a ROOTED? ;


: ACCOUNT ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   a S\" {\qaccount_id\q:\qdbid:account\q,\qname\q:{\qgiven_name\q:\qFixture\q,\qsurname\q:\qAccount\q,\qfamiliar_name\q:\qFixture\q,\qdisplay_name\q:\qFixture Account\q,\qabbreviated_name\q:\qFA\q},\qemail\q:\qfixture@example.invalid\q,\qemail_verified\q:true,\qdisabled\q:false,\qlocale\q:\qen\q,\qis_paired\q:false,\qaccount_type\q:{\q.tag\q:\qbasic\q},\qroot_info\q:{\q.tag\q:\quser\q,\qroot_namespace_id\q:\qnamespace\q,\qhome_namespace_id\q:\qnamespace\q}}" ANSWER! ;


\ The request body's path into ASKED.
: ASK ( HTTP:request -- )
   {: q:HTTP:request :}
   0 ASKED-U !
   PARSER q HTTP:BODY$ JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" path" JSON:READ-FIND-KEY if
         ASKED PATH-CAP READ-INTO ASKED-U !
      then
   then
   JSON:READ-FINISH ;


\ Dropbox's paths ignore case; this fake folds ASCII alone.
: FOUND ( -- n )
   FILES @ 0 ?do
      i PATH$ ASKED ASKED-U @ >str STR:=CI if i unloop exit then
   loop -1 ;


: METADATA ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ASK
   FOUND {: i:n :}
   i 0 >= if a i TAGGED$ ANSWER! exit then
   a 409 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qpath/not_found/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}" ANSWER! ;


\ ---- delete_v2, create_folder_v2, the code grant and a lost answer

create GRANT-CODE NAME-CAP allot
variable GRANT-CODE-U
create VERIFIER NAME-CAP allot
variable VERIFIER-U
create WANT NAME-CAP allot
variable WANT-U
create HELD NAME-CAP allot
variable HELD-U


\ The code grant's names and values, as FIELDS$ decodes them.
: CODE-FORM$ ( -- str )
   SB-RESET
   s" grant_type" FIELD+ s" authorization_code" FIELD+
   s" code" FIELD+ GRANT-CODE GRANT-CODE-U @ >str FIELD+
   s" code_verifier" FIELD+ VERIFIER VERIFIER-U @ >str FIELD+
   s" client_id" FIELD+ KEY$ FIELD+
   SB$ ;


\ The code grant, good once; any other form goes to TOKEN.
: GRANT ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   GRANT-CODE-U @ 0<> q HTTP:BODY$ FIELDS$ CODE-FORM$ STR:= and 0=
   if q a TOKEN exit then
   0 GRANT-CODE-U !
   ISSUE
   SB-RESET S\" {\qaccess_token\q:\q" SB-APPEND
   ISSUED ISSUED-U @ >str SB-APPEND
   S\" \q,\qrefresh_token\q:\qfake-refresh-granted\q" SB-APPEND
   S\" ,\qtoken_type\q:\qbearer\q,\qexpires_in\q:14400}" SB-APPEND
   a BUILT ANSWER! ;


\ The request body's parent_rev into WANT, and whether it sent one.
: PARENT ( HTTP:request -- bool )
   {: q:HTTP:request :}
   0 WANT-U !
   PARSER q HTTP:BODY$ JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" parent_rev" JSON:READ-FIND-KEY if
         WANT NAME-CAP READ-INTO WANT-U ! JSON:READ-FINISH true exit
      then
   then
   JSON:READ-FINISH false ;


\ The rev of entry i, empty for a folder.
: HELD$ ( n -- str )
   {: i:n :}
   0 HELD-U !
   PARSER i ENTRY$ JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" rev" JSON:READ-FIND-KEY if HELD NAME-CAP READ-INTO HELD-U ! then
   then
   JSON:READ-FINISH HELD HELD-U @ >str ;


\ Entry i goes; the last entry takes its slot.
: FORGET ( n -- )
   {: i:n :}
   FILES @ 1- {: last:n :}
   -1 FILES +!
   i last = if exit then
   last PATH$ PATHS PATH-CAP i AT STORE i PATH-US !
   last ENTRY$ ENTRIES TEXT-CAP i AT STORE i ENTRY-US !
   last FOLDERS @ i FOLDERS ! ;


\ Appends a span to entry i in its slot, so no argument shares a buffer
\ with it.
: ENTRY+ ( str n -- )
   {: s i:n :}
   s i ENTRY$ str> + TEXT-CAP i ENTRY-US @ - STORE i ENTRY-US +! ;


\ A folder at the path, which serves as path_lower and path_display.
: FOLDER+ ( str -- )
   {: p :}
   FILES @ {: i:n :}
   p PATHS PATH-CAP i AT STORE i PATH-US !
   0 i ENTRY-US ! S\" {\qname\q:\qa\q,\qid\q:\qid:a\q" i ENTRY+
   S\" ,\qpath_lower\q:\q" i ENTRY+ p i ENTRY+
   S\" \q,\qpath_display\q:\q" i ENTRY+ p i ENTRY+ S\" \q}" i ENTRY+
   true i FOLDERS !
   1 FILES +! ;


\ delete_v2's answer: entry i as `metadata`, a Metadata union.
: DELETED! ( HTTP:response n -- )
   {: a:HTTP:response i:n :}
   SB-RESET S\" {\qmetadata\q:" SB-APPEND i TAGGED+ s" }" SB-APPEND
   a BUILT ANSWER! ;


\ create_folder_v2's answer: entry i as `metadata`, a plain FolderMetadata.
: MADE! ( HTTP:response n -- )
   {: a:HTTP:response i:n :}
   SB-RESET S\" {\qmetadata\q:" SB-APPEND i ENTRY$ SB-APPEND s" }" SB-APPEND
   a BUILT ANSWER! ;


: REFUSED! ( HTTP:response str -- )
   {: a:HTTP:response b :}
   a 409 HTTP:STATUS!
   a b ANSWER! ;


\ A delete of a missing path, and one whose parent_rev is not the entry's.
: DELETE-PATH ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ASK
   FOUND {: i:n :}
   i 0< if a S\" {\qerror_summary\q:\qpath_lookup/not_found/...\q,\qerror\q:{\q.tag\q:\qpath_lookup\q,\qpath_lookup\q:{\q.tag\q:\qnot_found\q}}}" REFUSED! exit then
   q PARENT if
      WANT WANT-U @ >str i HELD$ STR:= 0= if
         a S\" {\qerror_summary\q:\qpath_write/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}}}}" REFUSED! exit
      then
   then
   a i DELETED!
   i FORGET ;


: CREATE-FOLDER ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ASK
   FOUND 0 >= if
      a S\" {\qerror_summary\q:\qpath/conflict/folder/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfolder\q}}}}" REFUSED! exit
   then
   ASKED ASKED-U @ >str FOLDER+

   a FILES @ 1- MADE! ;


: CLOSED ( TCP4:status -- )
   MATCH TCP4:status
      ok OF ENDOF
      failed OF drop ENDOF
   ;MATCH ;


\ Sends a 200 head promising one body byte and closes: the client reads a
\ cut inside the body, which its LOST answers as retry 0.
: SEVER ( HTTP:request -- )
   {: q:HTTP:request :}
   q HTTP:TAKE-OVER drop {: conn:TCP4:connection :}
   conn S\" HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n" TCP4:WRITE CLOSED
   conn TCP4:CLOSE CLOSED ;


\ After LOSE, an API call's route runs and takes effect, then its answer is
\ severed.
: LOSE? ( HTTP:request -- )
   {: q:HTTP:request :}
   LOSING @ 0= if exit then
   q API? 0= if exit then
   false LOSING !
   q SEVER ;


\ Whether a cut waits for the request, one of CUT's for an API call or
\ CUT-TOKEN's for a token request, which it then takes.
: ARMED? ( HTTP:request -- bool )
   API? if
      CUTS @ 0= if false exit then
      -1 CUTS +! true exit
   then
   TOKEN-CUTTING @ false TOKEN-CUTTING ! ;


\ After CUT, an API call's body is read and its answer severed before its
\ route runs, and after CUT-TOKEN a token request's: read, so no unread
\ byte turns the close into a reset.
: CUT? ( HTTP:request -- bool )
   {: q:HTTP:request :}
   q ARMED? 0= if false exit then
   q HTTP:BODY$ drop
   q SEVER true ;


\ After GARBLE, an API call's body is read, as CUT's is, and its answer is
\ one line that is not HTTP, then a close. The client reads it as a
\ malformed answer, a fault HTTPC:LOST? does not take.
: GARBLED? ( HTTP:request -- bool )
   {: q:HTTP:request :}
   GARBLING @ 0= if false exit then
   q API? 0= if false exit then
   false GARBLING !
   q HTTP:BODY$ drop
   q HTTP:TAKE-OVER drop {: conn:TCP4:connection :}
   conn S\" not http\r\n" TCP4:WRITE CLOSED
   conn TCP4:CLOSE CLOSED true ;


: SERVE ( HTTP:request HTTP:response [ HTTP:request HTTP:response -- ] -- )
   {: q:HTTP:request a:HTTP:response route :}
   q RECORD
   q a SCRIPTED? if exit then
   q CUT? if exit then
   q GARBLED? if exit then
   q a route execute
   q LOSE? ;

\ A file's FileMetadata after its `{`, appended to entry i: path_lower,
\ path_display, rev, content_hash and size.
: FIELDS+ ( str str str str n n -- )
   {: l d r h size:n i:n :}
   S\" \qname\q:\qa\q,\qid\q:\qid:a\q,\qpath_lower\q:\q" i ENTRY+
   l i ENTRY+ S\" \q,\qpath_display\q:\q" i ENTRY+ d i ENTRY+
   S\" \q,\qrev\q:\q" i ENTRY+ r i ENTRY+
   S\" \q,\qsize\q:" i ENTRY+ size FMT:INT$ i ENTRY+
   S\" ,\qcontent_hash\q:\q" i ENTRY+ h i ENTRY+
   S\" \q,\qis_downloadable\q:true}" i ENTRY+ ;


\ The file get_metadata finds in slot i.
: FILE-AT! ( str str str str n n -- )
   {: l d r h size:n i:n :}
   l PATHS PATH-CAP i AT STORE i PATH-US !
   0 i ENTRY-US ! s" {" i ENTRY+
   l d r h size i FIELDS+
   false i FOLDERS ! ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

\ Pages go out in order, one per listing call, each with its status; the
\ long poll answers POLLED every time; while SENDING, on the connection it
\ takes over, and then runs AFTER-POLL's hook.
STRUCTURE page DERIVE addr
   FIELD start n
   FIELD len n
   FIELD status n
;STRUCTURE
\ Every page's bytes, back to back; each page holds its start. A test
\ queues between calls, so the page a call answers stays put.
create PAGE-TEXT BUF:HDR-BYTES allot
TYPED-VARIABLE PAGES ^VEC:vector<page>
variable PAGE-SERVED
create POLLED TEXT-CAP allot
variable POLLED-U

: NO-HOOK ( -- ) ;
TYPED-VARIABLE ON-LISTING [ -- ]
' NO-HOOK ON-LISTING !
TYPED-VARIABLE ON-POLL [ -- ]
' NO-HOOK ON-POLL !
TYPED-VARIABLE AFTER-POLL [ -- ]
' NO-HOOK AFTER-POLL !
TYPED-VARIABLE SENDING bool


: PAGES-MADE ( -- )
   PAGE-TEXT TEXT-CAP BUF:N>BLEN BUF:INIT
   HEAP:ALLOCATOR 0 [type] page VEC:NEW PAGES ! ;
PAGES-MADE


: PAGE-COUNT ( -- n ) PAGES @ VEC:COUNT ;
: PAGE-OF ( n -- ^page ) {: i:n :} PAGES @ i VEC:AT ;


: PAGE$ ( n -- str )
   PAGE-OF {: p :}
   PAGE-TEXT BUF:SPAN$ drop p PAGE-START @ + p PAGE-LEN @ >str ;


: UNSET! ( HTTP:response -- )
   {: a:HTTP:response :}
   a 400 HTTP:STATUS!
   a s" the test set no answer" HTTP:BODY! ;


: LISTING ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   ON-LISTING @ ['] NO-HOOK ON-LISTING ! execute
   PAGE-SERVED @ {: i:n :}
   i PAGE-COUNT >= if a UNSET! exit then
   1 PAGE-SERVED +!
   a i PAGE-OF PAGE-STATUS @ HTTP:STATUS!
   a i PAGE$ ANSWER! ;


: POLLED$ ( -- str ) POLLED POLLED-U @ >str ;


\ POLLED as a whole answer that closes its connection.
: POLL-ANSWER$ ( -- str )
   SB-RESET S\" HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
   SB-APPEND s" Content-Length: " SB-APPEND POLLED-U @ FMT:SB-INT
   S\" \r\nConnection: close\r\n\r\n" SB-APPEND POLLED$ SB-APPEND SB$ ;


\ POLLED sent on the request's connection, then the hook, then a close.
: SENT-THEN ( HTTP:request [ -- ] -- )
   {: q:HTTP:request hook :}
   q HTTP:TAKE-OVER drop {: conn:TCP4:connection :}
   conn POLL-ANSWER$ TCP4:WRITE CLOSED
   hook execute
   conn TCP4:CLOSE CLOSED ;


: LONGPOLL ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   ON-POLL @ ['] NO-HOOK ON-POLL ! execute
   POLLED-U @ 0= if a UNSET! exit then
   SENDING @ if
      false SENDING ! AFTER-POLL @ ['] NO-HOOK AFTER-POLL !
      q swap SENT-THEN exit
   then
   a POLLED$ ANSWER! ;


: LISTING-RESET ( -- )
   PAGE-TEXT BUF:CLEAR PAGES @ 0 VEC:RESIZE
   0 PAGE-SERVED ! 0 POLLED-U !
   ['] NO-HOOK ON-LISTING ! ['] NO-HOOK ON-POLL !
   ['] NO-HOOK AFTER-POLL ! false SENDING ! ;


\ Opens the next page, with this status, at the end of PAGE-TEXT.
: QUEUE ( n -- )
   {: s:n :}
   PAGES @ VEC:PUSH {: p :}
   PAGE-TEXT BUF:LEN@ BUF:BLEN>N p PAGE-START !
   s p PAGE-STATUS ! ;


\ Appends to the page QUEUE opened last.
: PAGE+ ( str -- )
   {: s :}
   s str> BUF:N>BLEN PAGE-TEXT BUF:APPEND-SPAN
   s STR:len PAGE-COUNT 1 - PAGE-OF PAGE-LEN +! ;


: BOOL$ ( bool -- str ) if s" true" else s" false" then ;
: BOOL+ ( bool -- ) BOOL$ SB-APPEND ;

\ ---- files/download

\ CONTENT! keeps each rev's bytes. Each fault below applies to the next
\ download alone, as the word that sets it says.
SLOTS NAME-CAP * BUFFER: CONTENT-REVS
SLOTS TYPED-BUFFER CONTENT-REV-US n
SLOTS TEXT-CAP * BUFFER: CONTENT-BYTES
SLOTS TYPED-BUFFER CONTENT-US n
\ The bytes each slot's content holds before those it keeps; a download
\ that sends bytes from before them answers 500.
SLOTS TYPED-BUFFER CONTENT-SKIPS n
variable CONTENTS
TYPED-VARIABLE SKEWED bool
TYPED-VARIABLE CLIPPED bool
TYPED-VARIABLE INFLATED bool
create MISHASHED NAME-CAP allot
variable MISHASHED-U
TYPED-VARIABLE MISSIZED bool
variable MISSIZE-TO
create MISFILED NAME-CAP allot
variable MISFILED-U
TYPED-VARIABLE SHORTED bool
TYPED-VARIABLE LENGTHENED bool
TYPED-VARIABLE EMPTIED bool
TYPED-VARIABLE WHOLED bool
TYPED-VARIABLE PARTED bool
TYPED-VARIABLE BREAKING bool
TYPED-VARIABLE HOLDING bool
TYPED-VARIABLE PAUSING bool
\ Set by the test's task while the worker reads it, so atomic.
variable RESUMING
create REV-SEEN NAME-CAP allot
variable REV-SEEN-U
create ARG-SENT TEXT-CAP allot
variable ARG-SENT-U
create RANGE-SENT NAME-CAP allot
variable RANGE-SENT-U
TYPED-VARIABLE RANGED bool
TYPED-VARIABLE DURING [ -- ]
' NO-HOOK DURING !


: ARG-SENT! ( str -- ) ARG-SENT TEXT-CAP STORE ARG-SENT-U ! ;


: CONTENT-REV$ ( n -- str )
   {: i:n :} CONTENT-REVS NAME-CAP i AT drop i CONTENT-REV-US @ >str ;
: CONTENT$ ( n -- str )
   {: i:n :} CONTENT-BYTES TEXT-CAP i AT drop i CONTENT-US @ >str ;
: CONTENT-SIZE ( n -- n )
   {: i:n :} i CONTENT-SKIPS @ i CONTENT-US @ + ;


\ Slot i's content from the offset, at or past its skip, to its end.
: CONTENT-FROM ( n n -- str )
   {: i:n from:n :}
   i CONTENT$ str> {: b:^ u:n :}
   from i CONTENT-SKIPS @ - {: at:n :}
   b at + u at - >str ;


\ The slot holding the rev's bytes, else -1.
: CONTENT-OF ( str -- n )
   {: r :}
   CONTENTS @ 0 ?do
      i CONTENT-REV$ r STR:= if i unloop exit then
   loop -1 ;


\ The rev in a request's Dropbox-API-Arg {"path": "rev:<rev>"} into ASKED,
\ empty when it names no rev.
: REV-ASK ( HTTP:request -- )
   {: q:HTTP:request :}
   q s" Dropbox-API-Arg" HTTP:HEADER-OF$ {: v sent:bool :}
   v ARG-SENT!
   0 ASKED-U !
   sent if
      PARSER v JSON:READ-INIT
      JSON:READ-NEXT JSON:T-OBJ = if
         s" path" JSON:READ-FIND-KEY if
            ASKED PATH-CAP READ-INTO ASKED-U !
         then
      then
      JSON:READ-FINISH
   then ;


: REV$ ( -- str )
   ASKED-U @ 4 <= if ASKED 0 >str exit then
   ASKED 4 >str s" rev:" STR:= 0= if ASKED 0 >str exit then
   ASKED 4 + ASKED-U @ 4 - >str ;


\ An entry's rev into REV-SEEN.
: ENTRY-REV ( str -- str )
   {: e :}
   0 REV-SEEN-U !
   PARSER e JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" rev" JSON:READ-FIND-KEY if
         REV-SEEN NAME-CAP READ-INTO REV-SEEN-U !
      then
   then
   JSON:READ-FINISH
   REV-SEEN REV-SEEN-U @ >str ;


\ The FILE! slot whose entry has the rev, else -1.
: FILE-OF ( str -- n )
   {: r :}
   FILES @ 0 ?do
      i ENTRY$ ENTRY-REV r STR:= if i unloop exit then
   loop -1 ;


\ The offset a Range bytes=<n>- names, 0 for none, -1 for another form.
: RANGE-OF ( HTTP:request -- n )
   {: q:HTTP:request :}
   q s" Range" HTTP:HEADER-OF$ {: h sent:bool :}
   h str> {: v:^ vu:n :}
   sent RANGED !
   h RANGE-SENT NAME-CAP STORE RANGE-SENT-U !
   sent 0= if 0 exit then
   vu 7 < if -1 exit then
   v 6 >str s" bytes=" STR:= 0= if -1 exit then
   v vu + 1- c@ 45 <> if -1 exit then
   v 6 + vu 7 - >str STR:PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF ENDOF
   ;MATCH ;


: NOT-FOUND! ( HTTP:response -- )
   {: a:HTTP:response :}
   a 409 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qpath/not_found/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}" ANSWER! ;


\ bytes <first>-<last>/<total>.
: RANGE-TEXT$ ( n n n -- str )
   {: first:n last:n total:n :}
   SB-RESET s" bytes " SB-APPEND first FMT:SB-INT s" -" SB-APPEND
   last FMT:SB-INT s" /" SB-APPEND total FMT:SB-INT SB$ ;


\ bytes <from>-<size-1>/<size>, bent once by SKEWED, CLIPPED and INFLATED.
: CONTENT-RANGE$ ( n n -- str )
   {: from:n size:n :}
   SKEWED @ if from 1+ else from then
   CLIPPED @ if size 2 - else size 1- then
   INFLATED @ if size 1+ else size then
   false SKEWED ! false CLIPPED ! false INFLATED !
   RANGE-TEXT$ ;


: UNSATISFIABLE! ( HTTP:response n -- )
   {: a:HTTP:response size:n :}
   a 416 HTTP:STATUS!
   SB-RESET s" bytes */" SB-APPEND size FMT:SB-INT
   a s" Content-Range" SB$ HTTP:HEADER! ;


\ The bytes and one more, in OUT.
: LONGER$ ( str -- str ) SB-RESET SB-APPEND 33 SB-APPEND-C BUILT ;


\ The text e with its bytes from at up to the byte c as v, into OUT.
: REPLACED ( str n n str -- str )
   {: e at:n c:n v :}
   e str> {: ea:^ eu:n :}
   ea at + eu at - >str {: t :}
   t str> {: ta:^ tu:n :}
   t c STR:INDEX-OF MATCH option
      none OF tu ENDOF
      some OF IDX>N ENDOF
   ;MATCH {: len:n :}
   SB-RESET ea at >str SB-APPEND v SB-APPEND
   ta len + tu len - >str SB-APPEND BUILT ;


\ The text e with the value after its member m, up to the byte c, as v.
: SPLICED ( str str n str -- str )
   {: e m c:n v :}
   e m STR:FIND-SUB MATCH option
      none OF e ENDOF
      some OF IDX>N m STR:len + {: at:n :} e at c v REPLACED ENDOF
   ;MATCH ;


: HASH-SWAPPED ( str -- str )
   MISHASHED-U @ 0= if exit then
   S\" \qcontent_hash\q:\q" 34 MISHASHED MISHASHED-U @ >str SPLICED
   0 MISHASHED-U ! ;


: SIZE-SWAPPED ( str -- str )
   MISSIZED @ if
      S\" \qsize\q:" 44 MISSIZE-TO @ FMT:INT$ SPLICED
   then
   false MISSIZED ! ;


\ Entry i as the next download's Dropbox-API-Result.
: RESULT$ ( n -- str ) ENTRY$ HASH-SWAPPED SIZE-SWAPPED ;


\ The file in slot i with the bytes in slot k, from the offset.
: FILE-SENT ( HTTP:response n n n -- )
   {: a:HTTP:response i:n k:n from:n :}
   k CONTENT-SIZE {: size:n :}
   from size >= from 0 > and if a size UNSATISFIABLE! exit then
   a s" Dropbox-API-Result" i RESULT$ HTTP:HEADER!
   a s" Content-Type" s" application/octet-stream" HTTP:HEADER!
   from 0 > PARTED @ or if
      a 206 HTTP:STATUS!
      a s" Content-Range" from size CONTENT-RANGE$ HTTP:HEADER!
   then
   false PARTED !
   EMPTIED @ if s" " else
      k from CONTENT-FROM SHORTED @ if str> 1- >str then
      LENGTHENED @ if LONGER$ then
   then {: b :}
   false SHORTED ! false LENGTHENED ! false EMPTIED !
   a b HTTP:BODY! ;


\ The rev the next download answers: a MISFILE's once, else the one asked.
: SERVED-REV$ ( -- str )
   MISFILED-U @ 0= if REV$ exit then
   MISFILED MISFILED-U @ >str 0 MISFILED-U ! ;


\ The offset the next download answers from: 0 once WHOLED.
: SERVED-AT ( n -- n )
   WHOLED @ if drop 0 then
   false WHOLED ! ;


public
\ The bytes a cut, held or paused download sends of its body first.
10 constant PART
private

\ How long, in ms, a paused download waits for RESUME-BODY, and a held one
\ for the client to send or close.
5000 constant HOLD-MS
16 BUFFER: SINK


\ The file in slot i with the bytes in slot k from the offset, cut: a 200
\ head promising them all, and PART of them. LENGTHENED, they carry one
\ byte more under a head promising one more still, so it arrives mid-transfer.
\ The head says Connection: close, as its taker closes the connection after.
: CUT$ ( n n n -- str )
   {: i:n k:n from:n :}
   k CONTENT-SIZE from - LENGTHENED @ {: rest:n extra:bool :}
   false LENGTHENED !
   i RESULT$ {: e :}
   SB-RESET S\" HTTP/1.1 200 OK\r\nDropbox-API-Result: " SB-APPEND
   e SB-APPEND S\" \r\nContent-Length: " SB-APPEND
   rest extra if 2 + then FMT:SB-INT S\" \r\nConnection: close\r\n\r\n" SB-APPEND
   k from CONTENT-FROM str> PART min >str SB-APPEND
   extra rest PART < and if 33 SB-APPEND-C then
   SB$ ;


\ The request's connection, its body read and CUT$ sent on it.
: CUT-SENT ( HTTP:request n n n -- TCP4:connection )
   {: q:HTTP:request i:n k:n from:n :}
   q HTTP:BODY$ drop
   q HTTP:TAKE-OVER drop {: conn:TCP4:connection :}
   conn i k from CUT$ TCP4:WRITE CLOSED
   conn ;


\ CUT-SENT and a close, which the client reads as a cut.
: BROKEN ( HTTP:request n n n -- )
   {: q:HTTP:request i:n k:n from:n :}
   false BREAKING !
   q i k from CUT-SENT TCP4:CLOSE CLOSED ;


\ One read; true once the client closed the connection or it failed.
: SHUT? ( TCP4:connection -- bool )
   {: conn:TCP4:connection :}
   conn SINK 16 TCP4:TRANSFER-BYTES TCP4:READ MATCH TCP4:read-result
      data OF drop false ENDOF
      closed OF drop true ENDOF
      failed OF drop true ENDOF
   ;MATCH ;


\ True once the client closed the connection, or sent nothing for HOLD-MS.
: GONE? ( TCP4:connection -- bool )
   {: conn:TCP4:connection :}
   conn HOLD-MS >MS TCP4:READABLE-WITHIN? MATCH TCP4:ready-result
      ready OF conn SHUT? ENDOF
      idle OF true ENDOF
      failed OF drop true ENDOF
   ;MATCH ;


\ CUT-SENT, then the connection held until GONE?, and a close.
: HELD-OPEN ( HTTP:request n n n -- )
   {: q:HTTP:request i:n k:n from:n :}
   false HOLDING !
   q i k from CUT-SENT {: conn:TCP4:connection :}
   begin conn GONE? until
   conn TCP4:CLOSE CLOSED ;


\ Whether RESUME-BODY came before HOLD-MS passed; the worker yields
\ between its reads of the flag.
: RESUMED? ( -- bool )
   TIME:MONO-NS HOLD-MS 1000000 * + {: end:n :}
   begin
      RESUMING atomic@ 0<> if true exit then
      TIME:MONO-NS end <
   while TASK:PAUSE repeat
   false ;


\ The bytes r of the body's rest, sent once RESUMED?.
: REST-SENT ( TCP4:connection str -- )
   {: conn:TCP4:connection r :}
   r STR:len 0= if exit then
   RESUMED? 0= if exit then
   conn r TCP4:WRITE CLOSED ;



\ CUT-SENT, then the bytes after PART once RESUMED?, and a close.
: PAUSED ( HTTP:request n n n -- )
   {: q:HTTP:request i:n k:n from:n :}
   false PAUSING !
   q i k from CUT-SENT {: conn:TCP4:connection :}
   from PART + k CONTENT-SIZE min {: at:n :}
   conn k at CONTENT-FROM REST-SENT
   conn TCP4:CLOSE CLOSED ;


\ Runs the DURING-DOWNLOAD! hook, cleared first, so once.
: HOOKED ( -- ) DURING @ ['] NO-HOOK DURING ! execute ;


: DOWNLOAD ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   HOOKED
   q RANGE-OF SERVED-AT {: from:n :}
   q REV-ASK
   SERVED-REV$ {: r :}
   r FILE-OF r CONTENT-OF {: i:n k:n :}

   i 0< k 0< or if a NOT-FOUND! exit then
   from 0< if a 400 HTTP:STATUS! a s" bad range" HTTP:BODY! exit then
   from k CONTENT-SKIPS @ < EMPTIED @ 0= and if a 500 HTTP:STATUS! exit then
   BREAKING @ if q i k from BROKEN exit then
   HOLDING @ if q i k from HELD-OPEN exit then
   PAUSING @ if q i k from PAUSED exit then
   a i k from FILE-SENT ;



\ ---- files/upload and upload sessions

\ An upload's Dropbox-API-Arg lands in the ARG- fields, nested members
\ included. A session is slot i of SLOTS, named fake-session-<i>, hashing
\ what its appends bring; CLOSE-SESSIONS closes every open one. A commit
\ takes the next rev, 0170<n>, and lowers ASCII alone in path_lower.
create ARG-KEY NAME-CAP allot
variable ARG-KEY-U
create ARG-PATH PATH-CAP allot
variable ARG-PATH-U
create ARG-MODE NAME-CAP allot
variable ARG-MODE-U
create ARG-REV NAME-CAP allot
variable ARG-REV-U
create ARG-HASH NAME-CAP allot
variable ARG-HASH-U
create ARG-SESSION NAME-CAP allot
variable ARG-SESSION-U
variable ARG-OFFSET
create LOWERED PATH-CAP allot
create REV-NEW NAME-CAP allot
variable REV-NEW-U
variable REVS
TYPED-VARIABLE BODY-HASHER DROPBOX:hasher
SLOTS TYPED-BUFFER SESSION-HASHERS DROPBOX:hasher
SLOTS TYPED-BUFFER SESSION-ATS n
SLOTS TYPED-BUFFER SESSION-OPEN bool
variable SESSIONS


: ARG-PATH$ ( -- str ) ARG-PATH ARG-PATH-U @ >str ;
: ARG-MODE$ ( -- str ) ARG-MODE ARG-MODE-U @ >str ;
: ARG-REV$ ( -- str ) ARG-REV ARG-REV-U @ >str ;
: ARG-HASH$ ( -- str ) ARG-HASH ARG-HASH-U @ >str ;
: REV-NEW$ ( -- str ) REV-NEW REV-NEW-U @ >str ;


\ A string member's value into the ARG- field its key names.
: ARG-STRING ( JSON:reader -- JSON:reader )
   ARG-KEY ARG-KEY-U @ >str {: k :}
   k s" path" STR:= if ARG-PATH PATH-CAP READ-INTO ARG-PATH-U ! exit then
   k s" mode" STR:= k s" .tag" STR:= or
   if ARG-MODE NAME-CAP READ-INTO ARG-MODE-U ! exit then
   k s" update" STR:= if ARG-REV NAME-CAP READ-INTO ARG-REV-U ! exit then
   k s" content_hash" STR:=
   if ARG-HASH NAME-CAP READ-INTO ARG-HASH-U ! exit then
   k s" session_id" STR:=
   if ARG-SESSION NAME-CAP READ-INTO ARG-SESSION-U ! then ;


: ARG-VALUE ( JSON:reader n -- JSON:reader )
   {: t:n :}
   t JSON:T-STR = if ARG-STRING exit then
   t JSON:T-INT = if
      ARG-KEY ARG-KEY-U @ >str s" offset" STR:=
      if JSON:READ-INT ARG-OFFSET ! then
      exit
   then
   JSON:READ-SKIP-VALUE ;


\ Every member of the object just opened, and of the objects in it.
: ARG-MEMBERS ( JSON:reader -- JSON:reader )
   begin JSON:READ-NEXT dup JSON:T-KEY = while
      drop ARG-KEY NAME-CAP READ-INTO ARG-KEY-U !
      JSON:READ-NEXT dup JSON:T-OBJ = if drop RECURSE else ARG-VALUE then
   repeat drop ;


: ARG-READ ( HTTP:request -- )
   {: q:HTTP:request :}
   0 ARG-PATH-U ! 0 ARG-MODE-U ! 0 ARG-REV-U ! 0 ARG-HASH-U !
   0 ARG-SESSION-U ! -1 ARG-OFFSET !
   q s" Dropbox-API-Arg" HTTP:HEADER-OF$ {: v sent:bool :}
   v ARG-SENT!
   sent 0= if exit then
   PARSER v JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if ARG-MEMBERS then
   JSON:READ-FINISH ;


: LOWERED$ ( -- str )
   ARG-PATH-U @ 0 ?do ARG-PATH i + c@ STR:ASCII-LOWER LOWERED i + c! loop
   LOWERED ARG-PATH-U @ >str ;


: REV-TAKE ( -- )
   1 REVS +!
   SB-RESET s" 0170" SB-APPEND REVS @ FMT:SB-INT
   SB$ REV-NEW NAME-CAP STORE REV-NEW-U ! ;


\ A single upload's conflict carries `reason`, a finish's `path`.
: CONFLICT! ( HTTP:response bool -- )
   {: a:HTTP:response single:bool :}
   a 409 HTTP:STATUS!
   single if
      a S\" {\qerror_summary\q:\qpath/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qreason\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}},\qupload_session_id\q:\qfixture-session\q}}" ANSWER!
      exit
   then
   a S\" {\qerror_summary\q:\qpath/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}}}}" ANSWER! ;


\ Whether the argument's mode takes the path whose slot is i, -1 for none.
: TAKES? ( n -- bool )
   {: i:n :}
   ARG-MODE$ s" add" STR:= if i 0< exit then
   i 0< if false exit then
   i ENTRY$ ENTRY-REV ARG-REV$ STR:= ;


\ Commits the argument's path with the hash and size as its mode allows,
\ and answers the FileMetadata, which carries no `.tag`.
: COMMIT ( HTTP:response str n bool -- )
   {: a:HTTP:response h size:n single:bool :}
   LOWERED$ ASKED PATH-CAP STORE ASKED-U !
   FOUND {: i:n :}
   i TAKES? 0= if a single CONFLICT! exit then
   i 0< if FILES @ 1 FILES +! else i then {: j:n :}
   REV-TAKE
   ASKED ASKED-U @ >str ARG-PATH$ REV-NEW$ h size j FILE-AT!
   a j ENTRY$ ANSWER! ;


: UPLOAD-FILE ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARG-READ
   q HTTP:BODY$ {: b :}
   BODY-HASHER DROPBOX:HASH-BEGIN
   b str> BODY-HASHER DROPBOX:HASH-FEED
   BODY-HASHER DROPBOX:HASH-END {: h :}
   h ARG-HASH$ STR:= 0= if
      a 409 HTTP:STATUS!
      a S\" {\qerror_summary\q:\qcontent_hash_mismatch/...\q,\qerror\q:{\q.tag\q:\qcontent_hash_mismatch\q}}" ANSWER!
      exit
   then
   a h b STR:len true COMMIT ;


: UPLOAD-START ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q HTTP:BODY$ drop
   SESSIONS @ {: i:n :}
   i SLOTS >= if a 500 HTTP:STATUS! exit then
   1 SESSIONS +!
   i SESSION-HASHERS DROPBOX:HASH-BEGIN
   0 i SESSION-ATS ! true i SESSION-OPEN !
   SB-RESET S\" {\qsession_id\q:\qfake-session-" SB-APPEND i FMT:SB-INT
   S\" \q}" SB-APPEND a BUILT ANSWER! ;


\ The argument's session slot, else -1.
: SESSION-OF ( -- n )
   s" fake-session-" STR:len {: pu:n :}
   ARG-SESSION-U @ pu <= if -1 exit then
   ARG-SESSION pu >str s" fake-session-" STR:= 0= if -1 exit then
   ARG-SESSION pu + ARG-SESSION-U @ pu - >str STR:PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF dup SESSIONS @ < 0= if drop -1 then ENDOF
   ;MATCH ;


\ A session lookup's error, inside lookup_failed for a finish; offset is
\ incorrect_offset's correct_offset.
: LOOKUP! ( HTTP:response str n bool -- )
   {: a:HTTP:response t at:n finish:bool :}
   a 409 HTTP:STATUS!
   SB-RESET S\" {\qerror_summary\q:\q" SB-APPEND t SB-APPEND
   S\" /...\q,\qerror\q:" SB-APPEND
   finish if
      S\" {\q.tag\q:\qlookup_failed\q,\qlookup_failed\q:" SB-APPEND
   then
   S\" {\q.tag\q:\q" SB-APPEND t SB-APPEND S\" \q" SB-APPEND
   t s" incorrect_offset" STR:= if
      S\" ,\qcorrect_offset\q:" SB-APPEND at FMT:SB-INT
   then
   s" }" SB-APPEND finish if s" }" SB-APPEND then s" }" SB-APPEND
   a BUILT ANSWER! ;


\ The argument's open session at its offset, else -1 once answered why.
: SESSION-CHECK ( HTTP:response bool -- n )
   {: a:HTTP:response finish:bool :}
   SESSION-OF {: i:n :}
   i 0< if a s" not_found" 0 finish LOOKUP! -1 exit then
   i SESSION-OPEN @ 0= if a s" closed" 0 finish LOOKUP! -1 exit then
   i SESSION-ATS @ {: at:n :}
   ARG-OFFSET @ at <> if a s" incorrect_offset" at finish LOOKUP! -1 exit then
   i ;


: UPLOAD-APPEND ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARG-READ
   q HTTP:BODY$ {: b :}
   a false SESSION-CHECK {: i:n :}
   i 0< if exit then
   b str> i SESSION-HASHERS DROPBOX:HASH-FEED
   b STR:len i SESSION-ATS +!
   a s" null" ANSWER! ;


: UPLOAD-FINISH ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARG-READ
   q HTTP:BODY$ drop
   a true SESSION-CHECK {: i:n :}
   i 0< if exit then
   false i SESSION-OPEN !
   i SESSION-HASHERS DROPBOX:HASH-END {: h :}
   a h i SESSION-ATS @ false COMMIT ;


\ How long a connection may sit quiet, longer than any test runs: a request
\ crossing the server's idle close would be lost, never answered.
600000 constant KEEP-MS
TYPED-VARIABLE SERVING HTTP:config


\ Listens on 127.0.0.1, a free port, with one worker and KEEP-MS.
: LISTEN ( -- )
   $7F000001 SERVING HTTP-CONFIG:ADDRESS !
   0 SERVING HTTP-CONFIG:PORT !
   1 SERVING HTTP-CONFIG:WORKERS !
   KEEP-MS >MS SERVING HTTP-CONFIG:IDLE !
   SERVING HTTP:START ;


public

\ An upload's body, one chunk of 32 MiB at most, with room to spare.
$2100000 constant UPLOAD-CAP


\ Starts the server on a free port with one worker.
: START ( -- )
   0 ISSUES ! 0 EXPIRED ! false REVOKED ! false DENIED !
   HTTP:ROUTES-RESET
   s" POST" s" /oauth2/token" [: [: GRANT ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/users/get_current_account" [: [: ACCOUNT ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/get_metadata" [: [: METADATA ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/list_folder" [: [: LISTING ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/list_folder/continue" [: [: LISTING ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/list_folder/longpoll" [: [: LONGPOLL ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/download" [: [: DOWNLOAD ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/delete_v2" [: [: DELETE-PATH ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/create_folder_v2" [: [: CREATE-FOLDER ;] SERVE ;]
   HTTP:ROUTE
   s" POST" s" /2/files/upload" [: [: UPLOAD-FILE ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/upload_session/start"
   [: [: UPLOAD-START ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/upload_session/append_v2"
   [: [: UPLOAD-APPEND ;] SERVE ;] HTTP:ROUTE
   s" POST" s" /2/files/upload_session/finish"
   [: [: UPLOAD-FINISH ;] SERVE ;] HTTP:ROUTE
   UPLOAD-CAP HTTP:BODY-CAP!
   LISTEN
   SB-RESET s" http://127.0.0.1:" SB-APPEND HTTP:PORT FMT:SB-INT
   SB$ ORIGIN NAME-CAP STORE ORIGIN-U ! ;


: STOP ( -- ) HTTP:STOP ;


\ The server's origin, http://127.0.0.1:<port>.
: ORIGIN$ ( -- str ) ORIGIN ORIGIN-U @ >str ;


\ Forgets the script, the entries, the kept bytes, the pages, the long
\ poll's answer, the sessions, the revs uploads took, a download's fault, a
\ SKEW, a LOSE, the CUTs, a CUT-TOKEN, a GARBLE, a code GRANT! set, a
\ ROTATE!, a REVOKE, a DENY, a DURING-DOWNLOAD!, DURING-LISTING!,
\ DURING-POLL! or AFTER-POLL! hook and what was sent; the tokens and the
\ root stay.
: RESET ( -- )
   0 SCRIPTS ! 0 FILES ! 0 CONTENTS ! 0 SESSIONS ! 0 REVS !
   0 GRANT-CODE-U ! 0 ROTATED-U !
   CALLS-RESET 0 AUTH-U ! 0 ROOT-SENT-U ! 0 TYPE-SENT-U !
   0 TOKEN-TYPE-U ! 0 AGENT-SENT-U !
   0 ARG-SENT-U ! 0 RANGE-SENT-U !
   false ROOTED ! false TYPED ! false LEAKED ! false RANGED !
   false SKEWED ! false CLIPPED ! false INFLATED !
   0 MISHASHED-U ! false MISSIZED ! 0 MISFILED-U !
   false SHORTED ! false LENGTHENED ! false EMPTIED ! false WHOLED !
   false PARTED ! false BREAKING ! false LOSING ! 0 CUTS !
   false HOLDING ! false PAUSING ! 0 RESUMING atomic!
   false TOKEN-CUTTING ! false REVOKED ! false DENIED ! false GARBLING !
   ['] NO-HOOK DURING !
   SLOTS 0 ?do 0 i CONTENT-SKIPS ! loop
   LISTING-RESET ;


\ The app key and refresh token the token route accepts.
: ACCEPT! ( str str -- )
   {: k t :}
   k KEY NAME-CAP STORE KEY-U !
   t REFRESH NAME-CAP STORE REFRESH-U ! ;


\ The root every call's Path-Root names; empty means none is sent.
: ROOT! ( str -- ) ROOT NAME-CAP STORE ROOT-U ! ;


\ The next refresh also answers this refresh token, which the token route
\ accepts in place of the one before from then on.
: ROTATE! ( str -- ) ROTATED NAME-CAP STORE ROTATED-U ! ;


\ Expires every access token issued so far.
: EXPIRE ( -- ) ISSUES @ EXPIRED ! ;
\ The next token request's answer is lost as CUT's is, before a token is
\ issued.
: CUT-TOKEN ( -- ) true TOKEN-CUTTING ! ;


\ Refuses every access token, issued or yet to be, as Dropbox does once the
\ user disconnects the app, until RESET.
: REVOKE ( -- ) true REVOKED ! ;


\ Refuses every call that carries a token 403, as Dropbox does an app it no
\ longer allows, until RESET. The long poll takes no token, so it still answers.
: DENY ( -- ) true DENIED ! ;


\ A file get_metadata finds: path_lower, path_display, rev, content_hash and
\ size.
: FILE! ( str str str str n -- )
   FILES @ FILE-AT! 1 FILES +! ;


\ An answer bound to none, which an API call gets before its route's own
\ and a token request leaves queued: status, header (empty for none), body.
: SCRIPT! ( n str str str -- )
   {: s:n nm v b :}
   SCRIPTS @ {: i:n :}
   s i STATUSES !
   nm NAMES NAME-CAP i AT STORE i NAME-US !
   v VALUES NAME-CAP i AT STORE i VALUE-US !
   b BODIES TEXT-CAP i AT STORE i BODY-US !
   0 i ROUTE-US ! 0 i NEEDLE-US ! false i SPENT !
   1 SCRIPTS +! ;


\ SCRIPT!'s answer, which only a call to the route path gets.
: ROUTE-SCRIPT! ( str n str str str -- )
   SCRIPT! SCRIPTS @ 1 - {: r i:n :}
   r ROUTES PATH-CAP i AT STORE i ROUTE-US ! ;


\ ROUTE-SCRIPT!'s answer, which only a call whose Dropbox-API-Arg
\ contains the text t gets: route, t, status, header, body.
: ARG-SCRIPT! ( str str n str str str -- )
   {: r t s:n nm v b :}
   r s nm v b ROUTE-SCRIPT!
   SCRIPTS @ 1 - {: i:n :}
   t NEEDLES PATH-CAP i AT STORE i NEEDLE-US ! ;


\ The routes requested since RESET, in order, joined by single spaces.
: SEEN$ ( -- str )
   JOINED BUF:CLEAR
   CALL-COUNT 0 ?do i ROUTE-OF$ JOIN+ loop JOINED$ ;
\ How many requests since RESET went to exactly the route.
: CALLS ( str -- n )
   {: r :}
   0 CALL-COUNT 0 ?do i ROUTE-OF$ r STR:= if 1+ then loop ;
\ The Dropbox-API-Args and the bodies' first KiB of the requests to the
\ route since RESET, in order, joined by single spaces.
: ARGS-TO$ ( str -- str ) [: ARG-OF$ ;] JOINED-TO$ ;
: BODIES-TO$ ( str -- str ) [: BODY-OF$ ;] JOINED-TO$ ;
\ The last API call's Authorization value.
: AUTH$ ( -- str ) AUTH AUTH-U @ >str ;
\ The access token the fake issued last.
: ISSUED$ ( -- str ) ISSUED ISSUED-U @ >str ;
\ The last API call's Path-Root value, and whether it sent one.
: ROOT-SENT$ ( -- str ) ROOT-SENT ROOT-SENT-U @ >str ;
: ROOT-SENT? ( -- bool ) ROOTED @ ;
\ The last API call's Content-Type value, and whether it sent one.
: TYPE-SENT$ ( -- str ) TYPE-SENT TYPE-SENT-U @ >str ;
: TYPE-SENT? ( -- bool ) TYPED @ ;
\ The last token request's Content-Type value, empty when it sent none.
: TOKEN-TYPE$ ( -- str ) TOKEN-TYPE TOKEN-TYPE-U @ >str ;
\ The last request's User-Agent value, any route, empty when it sent none.
: AGENT-SENT$ ( -- str ) AGENT-SENT AGENT-SENT-U @ >str ;
\ Whether a token request or long poll since RESET carried Authorization or
\ Path-Root.
: LEAKED? ( -- bool ) LEAKED @ ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

\ A page the listing routes answer in turn: the entries array's JSON, the
\ cursor and has_more.
: PAGE! ( str str bool -- )
   {: e k more:bool :}
   200 QUEUE S\" {\qentries\q:" PAGE+ e PAGE+
   S\" ,\qcursor\q:\q" PAGE+ k PAGE+
   S\" \q,\qhas_more\q:" PAGE+ more BOOL$ PAGE+ s" }" PAGE+ ;


\ A 409 reset the listing routes answer in turn.
: PAGE-RESET! ( -- )
   409 QUEUE
   S\" {\qerror_summary\q:\qreset/\q,\qerror\q:{\q.tag\q:\qreset\q}}" PAGE+ ;


\ The long poll's answer: changes, and a backoff in seconds, 0 for none.
: POLL! ( bool n -- )
   {: changes:bool wait:n :}
   SB-RESET S\" {\qchanges\q:" SB-APPEND changes BOOL+
   wait 0<> if S\" ,\qbackoff\q:" SB-APPEND wait FMT:SB-INT then
   s" }" SB-APPEND
   SB$ POLLED TEXT-CAP STORE POLLED-U ! ;


\ The next listing call runs the quotation once, on the fake's task,
\ once it is admitted and before it answers.
: DURING-LISTING! ( [ -- ] -- ) ON-LISTING ! ;


\ The next long poll runs the quotation once, on the fake's task, before
\ it answers.
: DURING-POLL! ( [ -- ] -- ) ON-POLL ! ;


\ The next long poll that has an answer sends it, runs the quotation once
\ on the fake's task, then closes its connection.
: AFTER-POLL! ( [ -- ] -- ) AFTER-POLL ! true SENDING ! ;


\ ---- files/download

\ CONTENT! of skip bytes the fake does not keep, then the tail t; the size
\ FILE! was given must be skip plus t's length.
: CONTENT-TAIL! ( str n str -- )
   {: r skip:n t :}
   r CONTENT-OF {: k:n :}
   k 0< if CONTENTS @ 1 CONTENTS +! else k then {: j:n :}
   r CONTENT-REVS NAME-CAP j AT STORE j CONTENT-REV-US !
   skip j CONTENT-SKIPS !
   t CONTENT-BYTES TEXT-CAP j AT STORE j CONTENT-US ! ;


\ The bytes files/download serves for a FILE!'s rev, which replace any kept
\ for it; the size FILE! was given must be their length.
: CONTENT! ( str str -- )
   {: r b :}
   r 0 b CONTENT-TAIL! ;


\ Shifts the next download's Content-Range start by one.
: SKEW ( -- ) true SKEWED ! ;
\ The next download's Content-Range ends a byte early.
: CLIP ( -- ) true CLIPPED ! ;
\ The next download's Content-Range totals a byte more than the file.
: INFLATE ( -- ) true INFLATED ! ;
\ The next download's Dropbox-API-Result carries this content hash.
: MISHASH ( str -- ) MISHASHED NAME-CAP STORE MISHASHED-U ! ;
\ The next download's Dropbox-API-Result carries this size.
: MISSIZE ( n -- ) MISSIZE-TO ! true MISSIZED ! ;
\ The next download answers the file at this rev, whatever rev it asked.
: MISFILE ( str -- ) MISFILED NAME-CAP STORE MISFILED-U ! ;
\ The next download's body lacks its last byte.
: SHORTEN ( -- ) true SHORTED ! ;
\ The next download's body carries one byte past the file's end; a held
\ one's head promises one byte more than that.
: LENGTHEN ( -- ) true LENGTHENED ! ;
\ The next download's body is empty, with Content-Length 0.
: EMPTY ( -- ) true EMPTIED ! ;
\ The next download's body is cut after PART bytes.
: CUT-BODY ( -- ) true BREAKING ! ;
\ The next download's body stops after PART bytes, its connection held
\ until the client closes it.
: HOLD-BODY ( -- ) true HOLDING ! ;
\ The next download's body stops after PART bytes until RESUME-BODY.
: PAUSE-BODY ( -- ) 0 RESUMING atomic! true PAUSING ! ;
\ The paused download's server sends the rest of its body.
: RESUME-BODY ( -- ) 1 RESUMING atomic! ;
\ The next download runs the quotation once, on the fake's task, once it
\ is admitted and before it answers.
: DURING-DOWNLOAD! ( [ -- ] -- ) DURING ! ;
\ The next download answers the whole file, whatever Range it asked.
: IGNORE-RANGE ( -- ) true WHOLED ! ;
\ The next download answers a 206 with its Content-Range, even with no
\ Range asked.
: FORCE-RANGE ( -- ) true PARTED ! ;
\ The Dropbox-API-Arg value of the last download, upload, or upload
\ session append or finish.
: ARG-SENT$ ( -- str ) ARG-SENT ARG-SENT-U @ >str ;
\ The last download's Range value, and whether it sent one.
: RANGE-SENT$ ( -- str ) RANGE-SENT RANGE-SENT-U @ >str ;
: RANGE-SENT? ( -- bool ) RANGED @ ;


\ ---- delete_v2, create_folder_v2, the code grant and a lost answer

\ The code and PKCE verifier the token route grants once, answering the
\ refresh token fake-refresh-granted.
: GRANT! ( str str -- )
   {: k v :}
   k GRANT-CODE NAME-CAP STORE GRANT-CODE-U !
   v VERIFIER NAME-CAP STORE VERIFIER-U ! ;



\ The next API call's route runs and takes effect, and its answer is lost:
\ the connection sends a 200 head and closes before its body.
: LOSE ( -- ) true LOSING ! ;


\ ---- files/upload and upload sessions

\ One more of the next API calls' answers is lost as LOSE's is, before
\ its route runs: CUT twice loses the next two.
: CUT ( -- ) 1 CUTS +! ;
\ The next API call's answer is a line that is not HTTP, before its route
\ runs.
: GARBLE ( -- ) true GARBLING ! ;
\ Closes every open session: an append to one answers closed.
: CLOSE-SESSIONS ( -- )
   SESSIONS @ 0 ?do false i SESSION-OPEN ! loop ;


;package


\ A white-box read of how many connections the server has accepted since
\ START, defined into TEST-DROPBOX so HTTP's public surface gains nothing.
package HTTP
: TEST-DROPBOX:ACCEPTED ( -- n ) ACCEPTED-COUNT atomic@ ;
;package
