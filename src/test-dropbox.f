\ test-dropbox.f - a fake Dropbox for tests, never a production server: the
\ routes /oauth2/token, /2/users/get_current_account, /2/files/get_metadata,
\ /2/files/list_folder, its /continue, its /longpoll, /2/files/download,
\ /2/files/delete_v2, /2/files/create_folder_v2, /2/files/upload and
\ /2/files/upload_session/* on Habu's HTTP server at 127.0.0.1, answered in
\ the shapes tests/dropbox_fake.rs gives them. It accepts one app key and
\ refresh token, and one code GRANT! sets; it issues the access tokens
\ sl.fake-1, sl.fake-2 and on, and EXPIRE expires every token issued so far.
\ LOSE applies the next API call and loses its answer; each CUT loses one
\ more API call's answer, before the call takes effect, and CUT-TOKEN a token
\ request's; GARBLE answers the next API call, before it takes effect, with a
\ line that is not HTTP. REVOKE refuses every access token, issued or yet to
\ be, as invalid until RESET; the refresh still issues them. A call must
\ carry the Path-Root ROOT! expects, none when that is empty, else it answers
\ 422. Scripted answers go out in order before any route's own. It records
\ each request's path, and the last API call's Authorization, Path-Root and
\ Content-Type.
\ STORAGE CLASS. PROCESS-WIDE: one worker serves every request, so its handler
\ alone writes the state while a test waits on its call, and the test sets it
\ between calls. A body stays in its buffer, as HTTP:BODY! borrows it, until
\ the next request.

require src/lib/string.f
require src/lib/span.f
require src/lib/fmt.f
require src/lib/json.f
require src/lib/adt/option.f
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
variable ISSUES
\ Tokens numbered up to this one are expired.
variable EXPIRED
\ Every access token is refused as invalid.
variable REVOKED

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
variable SCRIPTS
variable SCRIPTED

create SEEN TEXT-CAP allot
variable SEEN-U
create AUTH NAME-CAP allot
variable AUTH-U
create ROOT-SENT TEXT-CAP allot
variable ROOT-SENT-U
TYPED-VARIABLE ROOTED bool
create TYPE-SENT NAME-CAP allot
variable TYPE-SENT-U
TYPED-VARIABLE TYPED bool
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


\ Copies a span into a buffer of cap bytes and answers its length.
: STORE ( ptr u8 n ptr u8 n -- n )
   {: a:ptr u:n dst:ptr cap:n :}
   a u dst cap SPAN:MAKE SPAN:COPY u ;


: AT ( ptr u8 n n -- ptr u8 n )
   {: base:ptr cap:n i:n :}
   base i cap * + cap ;


: KEY$ ( -- ptr u8 n ) KEY KEY-U @ ;
: REFRESH$ ( -- ptr u8 n ) REFRESH REFRESH-U @ ;
: ROOT$ ( -- ptr u8 n ) ROOT ROOT-U @ ;
: OUT$ ( -- ptr u8 n ) OUT OUT-U @ ;
: PATH$ ( n -- ptr u8 n ) {: i:n :} PATHS i PATH-CAP * + i PATH-US @ ;
: ENTRY$ ( n -- ptr u8 n ) {: i:n :} ENTRIES i TEXT-CAP * + i ENTRY-US @ ;
: NAME$ ( n -- ptr u8 n ) {: i:n :} NAMES i NAME-CAP * + i NAME-US @ ;
: VALUE$ ( n -- ptr u8 n ) {: i:n :} VALUES i NAME-CAP * + i VALUE-US @ ;
: BODY$ ( n -- ptr u8 n ) {: i:n :} BODIES i TEXT-CAP * + i BODY-US @ ;


\ The builder's text into OUT, which outlives the handler.
: BUILT ( -- ptr u8 n )
   SB$ OUT TEXT-CAP STORE OUT-U !
   OUT$ ;


\ Entry i appended as a Metadata union: its `.tag`, then the plain
\ record's members after its `{`.
: TAGGED+ ( n -- )
   {: i:n :}
   i FOLDERS @ if S\" {\q.tag\q:\qfolder\q," else S\" {\q.tag\q:\qfile\q," then
   SB-APPEND
   i ENTRY$ {: e:ptr eu:n :}
   e 1 + eu 1 - SB-APPEND ;


: TAGGED$ ( n -- ptr u8 n ) SB-RESET TAGGED+ BUILT ;


: ANSWER! ( HTTP:response ptr u8 n -- )
   {: a:HTTP:response b:ptr bu:n :}
   a s" Content-Type" s" application/json" HTTP:HEADER!
   a b bu HTTP:BODY! ;


\ ---- what was sent

: SEEN+ ( ptr u8 n -- )
   {: a:ptr u:n :}
   a u SEEN SEEN-U @ + TEXT-CAP SEEN-U @ - STORE SEEN-U +! ;


: SENT ( HTTP:request ptr u8 n ptr u8 n -- n bool )
   {: q:HTTP:request nm:ptr nu:n dst:ptr cap:n :}
   q nm nu HTTP:HEADER-OF$ if dst cap STORE true exit then
   2drop 0 false ;


: TOKEN-HEADERS ( HTTP:request -- )
   {: q:HTTP:request :}
   q s" Authorization" HTTP:HEADER-OF$ nip nip
   q s" Dropbox-API-Path-Root" HTTP:HEADER-OF$ nip nip or
   if true LEAKED ! then ;


: RECORD ( HTTP:request -- )
   {: q:HTTP:request :}
   SEEN-U @ 0<> if s"  " SEEN+ then
   q HTTP:PATH$ SEEN+
   q HTTP:PATH$ s" /oauth2/token" STR= if q TOKEN-HEADERS exit then
   q HTTP:PATH$ s" /2/files/list_folder/longpoll" STR=
   if q TOKEN-HEADERS exit then
   q s" Authorization" AUTH NAME-CAP SENT drop AUTH-U !
   q s" Dropbox-API-Path-Root" ROOT-SENT TEXT-CAP SENT ROOTED ! ROOT-SENT-U !
   q s" Content-Type" TYPE-SENT NAME-CAP SENT TYPED ! TYPE-SENT-U ! ;


\ Sends the next scripted answer, if one is left.
: SCRIPTED? ( HTTP:response -- bool )
   {: a:HTTP:response :}
   SCRIPTED @ SCRIPTS @ >= if false exit then
   SCRIPTED @ {: i:n :}
   1 SCRIPTED +!
   a i STATUSES @ HTTP:STATUS!
   i NAME$ nip 0<> if a i NAME$ i VALUE$ HTTP:HEADER! then
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
   b STR-DIGIT? b ASCII-LOWER dup 97 >= swap 122 <= and or
   b 45 = or b 46 = or b 95 = or b 126 = or b 42 = or ;


\ The byte a %XX at the offset names and the offset after it; -1 for a
\ malformed escape.
: ESCAPED ( ptr u8 n n -- n n )
   {: a:ptr u:n at:n :}
   at 3 + u > if -1 u exit then
   a at 1+ + c@ a at 2 + + c@ {: h:n l:n :}
   h STR-HEX-DIGIT? l STR-HEX-DIGIT? and 0= if -1 u exit then
   h STR-HEX-DIGIT-VALUE 16 * l STR-HEX-DIGIT-VALUE + at 3 + ;


\ The byte at the offset, decoded, and the offset after it; -1 for one
\ the form may not carry.
: FORM-BYTE ( ptr u8 n n -- n n )
   {: a:ptr u:n at:n :}
   a at + c@ {: b:n :}
   b 43 = if 32 at 1+ exit then
   b 37 = if a u at ESCAPED exit then
   b PLAIN? if b else -1 then at 1+ ;


\ The byte onto DECODED; false once it is full.
: KEPT ( n -- bool )
   {: b:n :}
   DECODED-U @ TEXT-CAP >= if false exit then
   b DECODED DECODED-U @ + c! 1 DECODED-U +! true ;


\ One step from FORM-AT: a separator as a NUL, else a decoded byte, which
\ may not be a NUL; false when the form is malformed.
: FORM-STEP ( ptr u8 n n -- bool )
   {: a:ptr u:n at:n :}
   a at + c@ {: b:n :}
   b 38 = b 61 = or if at 1+ FORM-AT ! 0 KEPT exit then
   a u at FORM-BYTE FORM-AT ! {: d:n :}
   d 0 <= if false exit then
   d KEPT ;


\ A form body's names and values as DECODED holds them; empty when it is
\ malformed.
: FIELDS$ ( ptr u8 n -- ptr u8 n )
   {: a:ptr u:n :}
   0 DECODED-U ! 0 FORM-AT !
   begin FORM-AT @ u < while
      a u FORM-AT @ FORM-STEP 0= if DECODED 0 exit then
   repeat
   0 KEPT 0= if DECODED 0 exit then
   DECODED DECODED-U @ ;


: FIELD+ ( ptr u8 n -- ) SB-APPEND 0 SB-APPEND-C ;


\ The refresh form's names and values, as FIELDS$ decodes them.
: FORM$ ( -- ptr u8 n )
   SB-RESET
   s" grant_type" FIELD+ s" refresh_token" FIELD+
   s" refresh_token" FIELD+ REFRESH$ FIELD+
   s" client_id" FIELD+ KEY$ FIELD+
   SB$ ;


: ISSUE ( -- )
   1 ISSUES +!
   SB-RESET s" sl.fake-" SB-APPEND ISSUES @ FMT:SB-INT
   SB$ ISSUED NAME-CAP STORE ISSUED-U ! ;


: TOKEN ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q HTTP:BODY$ FIELDS$ FORM$ STR= 0= if
      a 400 HTTP:STATUS!
      a S\" {\qerror\q:\qinvalid_grant\q,\qerror_description\q:\qrefresh token is invalid or revoked\q}" ANSWER!
      exit
   then
   ISSUE
   SB-RESET S\" {\qaccess_token\q:\q" SB-APPEND ISSUED ISSUED-U @ SB-APPEND
   S\" \q,\qtoken_type\q:\qbearer\q,\qexpires_in\q:14400}" SB-APPEND
   a BUILT ANSWER! ;


\ ---- calls

: UNAUTHORIZED! ( HTTP:response ptr u8 n -- )
   {: a:HTTP:response t:ptr tu:n :}
   a 401 HTTP:STATUS!
   SB-RESET S\" {\qerror_summary\q:\q" SB-APPEND t tu SB-APPEND
   S\" /...\q,\qerror\q:{\q.tag\q:\q" SB-APPEND t tu SB-APPEND
   S\" \q}}" SB-APPEND
   a BUILT ANSWER! ;


\ The number of an issued token in an Authorization value, else -1.
: TOKEN-NUMBER ( ptr u8 n -- n )
   {: t:ptr tu:n :}
   s" Bearer sl.fake-" nip {: pu:n :}
   tu pu <= if -1 exit then
   t pu s" Bearer sl.fake-" STR= 0= if -1 exit then
   t pu + tu pu - STR-PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF ENDOF
   ;MATCH ;


: AUTHORIZED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   q s" Authorization" HTTP:HEADER-OF$ 0= if 2drop -1 else TOKEN-NUMBER then
   {: k:n :}
   k 1 < k ISSUES @ > or REVOKED @ or if
      a s" invalid_access_token" UNAUTHORIZED! false exit
   then
   k EXPIRED @ <= if a s" expired_access_token" UNAUTHORIZED! false exit then
   true ;


: ROOT-LINE$ ( -- ptr u8 n )
   SB-RESET S\" {\q.tag\q:\qroot\q,\qroot\q:\q" SB-APPEND ROOT$ SB-APPEND
   S\" \q}" SB-APPEND SB$ ;


: ROOT-OK? ( HTTP:request -- bool )
   {: q:HTTP:request :}
   q s" Dropbox-API-Path-Root" HTTP:HEADER-OF$ {: v:ptr vu:n sent:bool :}
   ROOT-U @ 0= if sent 0= exit then
   sent if v vu ROOT-LINE$ STR= else false then ;


: ROOTED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
   q ROOT-OK? if true exit then
   a 422 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qinvalid_root/...\q,\qerror\q:{\q.tag\q:\qinvalid_root\q,\qinvalid_root\q:{\q.tag\q:\quser\q}}}" ANSWER!
   false ;


: ADMITTED? ( HTTP:request HTTP:response -- bool )
   {: q:HTTP:request a:HTTP:response :}
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
         ASKED PATH-CAP JSON:READ-STR ASKED-U !
      then
   then
   JSON:READ-FINISH ;


\ Dropbox's paths ignore case; this fake folds ASCII alone.
: FOUND ( -- n )
   FILES @ 0 ?do
      i PATH$ ASKED ASKED-U @ STR=CI if i unloop exit then
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
: CODE-FORM$ ( -- ptr u8 n )
   SB-RESET
   s" grant_type" FIELD+ s" authorization_code" FIELD+
   s" code" FIELD+ GRANT-CODE GRANT-CODE-U @ FIELD+
   s" code_verifier" FIELD+ VERIFIER VERIFIER-U @ FIELD+
   s" client_id" FIELD+ KEY$ FIELD+
   SB$ ;


\ The code grant, good once; any other form goes to TOKEN.
: GRANT ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   GRANT-CODE-U @ 0<> q HTTP:BODY$ FIELDS$ CODE-FORM$ STR= and 0=
   if q a TOKEN exit then
   0 GRANT-CODE-U !
   ISSUE
   SB-RESET S\" {\qaccess_token\q:\q" SB-APPEND ISSUED ISSUED-U @ SB-APPEND
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
         WANT NAME-CAP JSON:READ-STR WANT-U ! JSON:READ-FINISH true exit
      then
   then
   JSON:READ-FINISH false ;


\ The rev of entry i, empty for a folder.
: HELD$ ( n -- ptr u8 n )
   {: i:n :}
   0 HELD-U !
   PARSER i ENTRY$ JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" rev" JSON:READ-FIND-KEY if HELD NAME-CAP JSON:READ-STR HELD-U ! then
   then
   JSON:READ-FINISH HELD HELD-U @ ;


\ Entry i goes; the last entry takes its slot.
: FORGET ( n -- )
   {: i:n :}
   FILES @ 1- {: last:n :}
   -1 FILES +!
   i last = if exit then
   last PATH$ PATHS PATH-CAP i AT STORE i PATH-US !
   last ENTRY$ ENTRIES TEXT-CAP i AT STORE i ENTRY-US !
   last FOLDERS @ i FOLDERS ! ;


\ A folder at the path, which serves as path_lower and path_display.
: FOLDER+ ( ptr u8 n -- )
   {: p:ptr pu:n :}
   FILES @ {: i:n :}
   p pu PATHS PATH-CAP i AT STORE i PATH-US !
   SB-RESET S\" {\qname\q:\qa\q,\qid\q:\qid:a\q" SB-APPEND
   S\" ,\qpath_lower\q:\q" SB-APPEND p pu SB-APPEND
   S\" \q,\qpath_display\q:\q" SB-APPEND p pu SB-APPEND S\" \q}" SB-APPEND
   SB$ ENTRIES TEXT-CAP i AT STORE i ENTRY-US !
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


: REFUSED! ( HTTP:response ptr u8 n -- )
   {: a:HTTP:response b:ptr bu:n :}
   a 409 HTTP:STATUS!
   a b bu ANSWER! ;


\ A delete of a missing path, and one whose parent_rev is not the entry's.
: DELETE-PATH ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ASK
   FOUND {: i:n :}
   i 0< if a S\" {\qerror_summary\q:\qpath_lookup/not_found/...\q,\qerror\q:{\q.tag\q:\qpath_lookup\q,\qpath_lookup\q:{\q.tag\q:\qnot_found\q}}}" REFUSED! exit then
   q PARENT if
      WANT WANT-U @ i HELD$ STR= 0= if
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
   ASKED ASKED-U @ FOLDER+
   a FILES @ 1- MADE! ;


: CLOSED ( TCP4:status -- )
   MATCH TCP4:status
      ok OF ENDOF
      failed OF drop ENDOF
   ;MATCH ;


\ Sends a 200 head promising one body byte and closes. libcurl answers
\ CURLE_PARTIAL_FILE, which the client's LOST reads, and does not resend the
\ call, as it does when a reused connection closes before a whole header
\ line. A status line alone will not do: libcurl takes it, closed, as a
\ whole answer with no headers.
: SEVER ( HTTP:request -- )
   {: q:HTTP:request :}
   q HTTP:TAKE-OVER 2drop {: conn:TCP4:connection :}
   conn S\" HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n" TCP4:TRANSFER-BYTES TCP4:WRITE CLOSED
   conn TCP4:CLOSE CLOSED ;


: API? ( HTTP:request -- bool ) HTTP:PATH$ s" /oauth2/token" STR= 0= ;


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
   q HTTP:BODY$ 2drop
   q SEVER true ;


\ After GARBLE, an API call's body is read, as CUT's is, and its answer is
\ one line that is not HTTP, then a close. libcurl, which takes no
\ HTTP/0.9 answer, fails it with CURLE_UNSUPPORTED_PROTOCOL, a code
\ CURL:LOST? does not take.
: GARBLED? ( HTTP:request -- bool )
   {: q:HTTP:request :}
   GARBLING @ 0= if false exit then
   q API? 0= if false exit then
   false GARBLING !
   q HTTP:BODY$ 2drop
   q HTTP:TAKE-OVER 2drop {: conn:TCP4:connection :}
   conn S\" not http\r\n" TCP4:TRANSFER-BYTES TCP4:WRITE CLOSED
   conn TCP4:CLOSE CLOSED true ;


: SERVE ( HTTP:request HTTP:response [ HTTP:request HTTP:response -- ] -- )
   {: q:HTTP:request a:HTTP:response route :}
   q RECORD
   a SCRIPTED? if exit then
   q CUT? if exit then
   q GARBLED? if exit then
   q a route execute
   q LOSE? ;

\ A file's FileMetadata after its `{`: path_lower, path_display, rev,
\ content_hash and size.
: FIELDS+ ( ptr u8 n ptr u8 n ptr u8 n ptr u8 n n -- )
   {: l:ptr lu:n d:ptr du:n r:ptr ru:n h:ptr hu:n size:n :}
   S\" \qname\q:\qa\q,\qid\q:\qid:a\q,\qpath_lower\q:\q" SB-APPEND
   l lu SB-APPEND S\" \q,\qpath_display\q:\q" SB-APPEND d du SB-APPEND
   S\" \q,\qrev\q:\q" SB-APPEND r ru SB-APPEND
   S\" \q,\qsize\q:" SB-APPEND size FMT:SB-INT
   S\" ,\qcontent_hash\q:\q" SB-APPEND h hu SB-APPEND
   S\" \q,\qis_downloadable\q:true}" SB-APPEND ;


\ The file get_metadata finds in slot i.
: FILE-AT! ( ptr u8 n ptr u8 n ptr u8 n ptr u8 n n n -- )
   {: l:ptr lu:n d:ptr du:n r:ptr ru:n h:ptr hu:n size:n i:n :}
   l lu PATHS PATH-CAP i AT STORE i PATH-US !
   SB-RESET s" {" SB-APPEND
   l lu d du r ru h hu size FIELDS+
   SB$ ENTRIES TEXT-CAP i AT STORE i ENTRY-US !
   false i FOLDERS ! ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

\ Pages go out in order, one per listing call, each with its status; the
\ long poll answers POLLED every time. ARGS joins those calls' bodies.
SLOTS TEXT-CAP * BUFFER: PAGES
SLOTS TYPED-BUFFER PAGE-US n
SLOTS TYPED-BUFFER PAGE-STATUSES n
variable PAGE-COUNT
variable PAGE-SERVED
create POLLED TEXT-CAP allot
variable POLLED-U
create ARGS TEXT-CAP allot
variable ARGS-U


: PAGE$ ( n -- ptr u8 n ) {: i:n :} PAGES i TEXT-CAP * + i PAGE-US @ ;


: ARG+ ( ptr u8 n -- )
   {: a:ptr u:n :}
   a u ARGS ARGS-U @ + TEXT-CAP ARGS-U @ - STORE ARGS-U +! ;


: ARGUED ( HTTP:request -- )
   {: q:HTTP:request :}
   ARGS-U @ 0<> if s"  " ARG+ then
   q HTTP:BODY$ ARG+ ;


: UNSET! ( HTTP:response -- )
   {: a:HTTP:response :}
   a 400 HTTP:STATUS!
   a s" the test set no answer" HTTP:BODY! ;


: LISTING ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARGUED
   PAGE-SERVED @ {: i:n :}
   i PAGE-COUNT @ >= if a UNSET! exit then
   1 PAGE-SERVED +!
   a i PAGE-STATUSES @ HTTP:STATUS!
   a i PAGE$ ANSWER! ;


: LONGPOLL ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q ARGUED
   POLLED-U @ 0= if a UNSET! exit then
   a POLLED POLLED-U @ ANSWER! ;


: LISTING-RESET ( -- )
   0 PAGE-COUNT ! 0 PAGE-SERVED ! 0 POLLED-U ! 0 ARGS-U ! ;


: QUEUE ( n ptr u8 n -- )
   {: s:n b:ptr bu:n :}
   PAGE-COUNT @ {: i:n :}
   s i PAGE-STATUSES !
   b bu PAGES TEXT-CAP i AT STORE i PAGE-US !
   1 PAGE-COUNT +! ;


: BOOL+ ( bool -- ) if s" true" else s" false" then SB-APPEND ;

\ ---- files/download

\ CONTENT! keeps each rev's bytes. Each fault applies to the next download
\ alone: SKEWED shifts its Content-Range's start by one, MISFILED answers
\ another rev's file, SHORTED drops its body's last byte, WHOLED answers
\ the whole file whatever Range it asked, and PARTED answers a 206 with a
\ Content-Range though it asked none.
SLOTS NAME-CAP * BUFFER: CONTENT-REVS
SLOTS TYPED-BUFFER CONTENT-REV-US n
SLOTS TEXT-CAP * BUFFER: CONTENT-BYTES
SLOTS TYPED-BUFFER CONTENT-US n
variable CONTENTS
TYPED-VARIABLE SKEWED bool
create MISFILED NAME-CAP allot
variable MISFILED-U
TYPED-VARIABLE SHORTED bool
TYPED-VARIABLE WHOLED bool
TYPED-VARIABLE PARTED bool
create REV-SEEN NAME-CAP allot
variable REV-SEEN-U
create ARG-SENT TEXT-CAP allot
variable ARG-SENT-U
create RANGE-SENT NAME-CAP allot
variable RANGE-SENT-U
TYPED-VARIABLE RANGED bool


: CONTENT-REV$ ( n -- ptr u8 n )
   {: i:n :} CONTENT-REVS NAME-CAP i AT drop i CONTENT-REV-US @ ;
: CONTENT$ ( n -- ptr u8 n )
   {: i:n :} CONTENT-BYTES TEXT-CAP i AT drop i CONTENT-US @ ;


\ The slot holding the rev's bytes, else -1.
: CONTENT-OF ( ptr u8 n -- n )
   {: r:ptr ru:n :}
   CONTENTS @ 0 ?do
      i CONTENT-REV$ r ru STR= if i unloop exit then
   loop -1 ;


\ The rev in a request's Dropbox-API-Arg {"path": "rev:<rev>"} into ASKED,
\ empty when it names no rev.
: REV-ASK ( HTTP:request -- )
   {: q:HTTP:request :}
   q s" Dropbox-API-Arg" HTTP:HEADER-OF$ {: v:ptr vu:n sent:bool :}
   v vu ARG-SENT TEXT-CAP STORE ARG-SENT-U !
   0 ASKED-U !
   sent if
      PARSER v vu JSON:READ-INIT
      JSON:READ-NEXT JSON:T-OBJ = if
         s" path" JSON:READ-FIND-KEY if
            ASKED PATH-CAP JSON:READ-STR ASKED-U !
         then
      then
      JSON:READ-FINISH
   then ;


: REV$ ( -- ptr u8 n )
   ASKED-U @ 4 <= if ASKED 0 exit then
   ASKED 4 s" rev:" STR= 0= if ASKED 0 exit then
   ASKED 4 + ASKED-U @ 4 - ;


\ An entry's rev into REV-SEEN.
: ENTRY-REV ( ptr u8 n -- ptr u8 n )
   {: e:ptr eu:n :}
   0 REV-SEEN-U !
   PARSER e eu JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if
      s" rev" JSON:READ-FIND-KEY if
         REV-SEEN NAME-CAP JSON:READ-STR REV-SEEN-U !
      then
   then
   JSON:READ-FINISH
   REV-SEEN REV-SEEN-U @ ;


\ The FILE! slot whose entry has the rev, else -1.
: FILE-OF ( ptr u8 n -- n )
   {: r:ptr ru:n :}
   FILES @ 0 ?do
      i ENTRY$ ENTRY-REV r ru STR= if i unloop exit then
   loop -1 ;


\ The offset a Range bytes=<n>- names, 0 for none, -1 for another form.
: RANGE-OF ( HTTP:request -- n )
   {: q:HTTP:request :}
   q s" Range" HTTP:HEADER-OF$ {: v:ptr vu:n sent:bool :}
   sent RANGED !
   v vu RANGE-SENT NAME-CAP STORE RANGE-SENT-U !
   sent 0= if 0 exit then
   vu 7 < if -1 exit then
   v 6 s" bytes=" STR= 0= if -1 exit then
   v vu + 1- c@ 45 <> if -1 exit then
   v 6 + vu 7 - STR-PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF ENDOF
   ;MATCH ;


: NOT-FOUND! ( HTTP:response -- )
   {: a:HTTP:response :}
   a 409 HTTP:STATUS!
   a S\" {\qerror_summary\q:\qpath/not_found/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}" ANSWER! ;


\ bytes <from>-<size-1>/<size>, from shifted by one once when skewed.
: CONTENT-RANGE$ ( n n -- ptr u8 n )
   {: from:n size:n :}
   SKEWED @ if from 1+ else from then {: shown:n :}
   false SKEWED !
   SB-RESET s" bytes " SB-APPEND shown FMT:SB-INT s" -" SB-APPEND
   size 1- FMT:SB-INT s" /" SB-APPEND size FMT:SB-INT SB$ ;


: UNSATISFIABLE! ( HTTP:response n -- )
   {: a:HTTP:response size:n :}
   a 416 HTTP:STATUS!
   SB-RESET s" bytes */" SB-APPEND size FMT:SB-INT
   a s" Content-Range" SB$ HTTP:HEADER! ;


\ The file in slot i with the bytes in slot k, from the offset.
: FILE-SENT ( HTTP:response n n n -- )
   {: a:HTTP:response i:n k:n from:n :}
   k CONTENT$ {: b:ptr size:n :}
   from size >= from 0 > and if a size UNSATISFIABLE! exit then
   a s" Dropbox-API-Result" i ENTRY$ HTTP:HEADER!
   a s" Content-Type" s" application/octet-stream" HTTP:HEADER!
   from 0 > PARTED @ or if
      a 206 HTTP:STATUS!
      a s" Content-Range" from size CONTENT-RANGE$ HTTP:HEADER!
   then
   false PARTED !
   size from - SHORTED @ if 1- then {: len:n :}
   false SHORTED !
   a b from + len HTTP:BODY! ;


\ The rev the next download answers: a MISFILE's once, else the one asked.
: SERVED-REV$ ( -- ptr u8 n )
   MISFILED-U @ 0= if REV$ exit then
   MISFILED MISFILED-U @ 0 MISFILED-U ! ;


\ The offset the next download answers from: 0 once WHOLED.
: SERVED-AT ( n -- n )
   WHOLED @ if drop 0 then
   false WHOLED ! ;


: DOWNLOAD ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q RANGE-OF SERVED-AT {: from:n :}
   q REV-ASK
   SERVED-REV$ {: r:ptr ru:n :}
   r ru FILE-OF r ru CONTENT-OF {: i:n k:n :}
   i 0< k 0< or if a NOT-FOUND! exit then
   from 0< if a 400 HTTP:STATUS! a s" bad range" HTTP:BODY! exit then
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


: ARG-PATH$ ( -- ptr u8 n ) ARG-PATH ARG-PATH-U @ ;
: ARG-MODE$ ( -- ptr u8 n ) ARG-MODE ARG-MODE-U @ ;
: ARG-REV$ ( -- ptr u8 n ) ARG-REV ARG-REV-U @ ;
: ARG-HASH$ ( -- ptr u8 n ) ARG-HASH ARG-HASH-U @ ;
: REV-NEW$ ( -- ptr u8 n ) REV-NEW REV-NEW-U @ ;


\ A string member's value into the ARG- field its key names.
: ARG-STRING ( JSON:reader -- JSON:reader )
   ARG-KEY ARG-KEY-U @ {: k:ptr ku:n :}
   k ku s" path" STR= if ARG-PATH PATH-CAP JSON:READ-STR ARG-PATH-U ! exit then
   k ku s" mode" STR= k ku s" .tag" STR= or
   if ARG-MODE NAME-CAP JSON:READ-STR ARG-MODE-U ! exit then
   k ku s" update" STR= if ARG-REV NAME-CAP JSON:READ-STR ARG-REV-U ! exit then
   k ku s" content_hash" STR=
   if ARG-HASH NAME-CAP JSON:READ-STR ARG-HASH-U ! exit then
   k ku s" session_id" STR=
   if ARG-SESSION NAME-CAP JSON:READ-STR ARG-SESSION-U ! then ;


: ARG-VALUE ( JSON:reader n -- JSON:reader )
   {: t:n :}
   t JSON:T-STR = if ARG-STRING exit then
   t JSON:T-INT = if
      ARG-KEY ARG-KEY-U @ s" offset" STR= if JSON:READ-INT ARG-OFFSET ! then
      exit
   then
   JSON:READ-SKIP-VALUE ;


\ Every member of the object just opened, and of the objects in it.
: ARG-MEMBERS ( JSON:reader -- JSON:reader )
   begin JSON:READ-NEXT dup JSON:T-KEY = while
      drop ARG-KEY NAME-CAP JSON:READ-STR ARG-KEY-U !
      JSON:READ-NEXT dup JSON:T-OBJ = if drop RECURSE else ARG-VALUE then
   repeat drop ;


: ARG-READ ( HTTP:request -- )
   {: q:HTTP:request :}
   0 ARG-PATH-U ! 0 ARG-MODE-U ! 0 ARG-REV-U ! 0 ARG-HASH-U !
   0 ARG-SESSION-U ! -1 ARG-OFFSET !
   q s" Dropbox-API-Arg" HTTP:HEADER-OF$ {: v:ptr vu:n sent:bool :}
   v vu ARG-SENT TEXT-CAP STORE ARG-SENT-U !
   sent 0= if exit then
   PARSER v vu JSON:READ-INIT
   JSON:READ-NEXT JSON:T-OBJ = if ARG-MEMBERS then
   JSON:READ-FINISH ;


: LOWERED$ ( -- ptr u8 n )
   ARG-PATH-U @ 0 ?do ARG-PATH i + c@ ASCII-LOWER LOWERED i + c! loop
   LOWERED ARG-PATH-U @ ;


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
   ARG-MODE$ s" add" STR= if i 0< exit then
   i 0< if false exit then
   i ENTRY$ ENTRY-REV ARG-REV$ STR= ;


\ Commits the argument's path with the hash and size as its mode allows,
\ and answers the FileMetadata, which carries no `.tag`.
: COMMIT ( HTTP:response ptr u8 n n bool -- )
   {: a:HTTP:response h:ptr hu:n size:n single:bool :}
   LOWERED$ ASKED PATH-CAP STORE ASKED-U !
   FOUND {: i:n :}
   i TAKES? 0= if a single CONFLICT! exit then
   i 0< if FILES @ 1 FILES +! else i then {: j:n :}
   REV-TAKE
   ASKED ASKED-U @ ARG-PATH$ REV-NEW$ h hu size j FILE-AT!
   a j ENTRY$ ANSWER! ;


: UPLOAD-FILE ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARG-READ
   q HTTP:BODY$ {: b:ptr bu:n :}
   BODY-HASHER DROPBOX:HASH-BEGIN
   b bu BODY-HASHER DROPBOX:HASH-FEED
   BODY-HASHER DROPBOX:HASH-END {: h:ptr hu:n :}
   h hu ARG-HASH$ STR= 0= if
      a 409 HTTP:STATUS!
      a S\" {\qerror_summary\q:\qcontent_hash_mismatch/...\q,\qerror\q:{\q.tag\q:\qcontent_hash_mismatch\q}}" ANSWER!
      exit
   then
   a h hu bu true COMMIT ;


: UPLOAD-START ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q HTTP:BODY$ 2drop
   SESSIONS @ {: i:n :}
   i SLOTS >= if a 500 HTTP:STATUS! exit then
   1 SESSIONS +!
   i SESSION-HASHERS DROPBOX:HASH-BEGIN
   0 i SESSION-ATS ! true i SESSION-OPEN !
   SB-RESET S\" {\qsession_id\q:\qfake-session-" SB-APPEND i FMT:SB-INT
   S\" \q}" SB-APPEND a BUILT ANSWER! ;


\ The argument's session slot, else -1.
: SESSION-OF ( -- n )
   s" fake-session-" nip {: pu:n :}
   ARG-SESSION-U @ pu <= if -1 exit then
   ARG-SESSION pu s" fake-session-" STR= 0= if -1 exit then
   ARG-SESSION pu + ARG-SESSION-U @ pu - STR-PARSE-POS MATCH option
      none OF -1 ENDOF
      some OF dup SESSIONS @ < 0= if drop -1 then ENDOF
   ;MATCH ;


\ A session lookup's error, inside lookup_failed for a finish; offset is
\ incorrect_offset's correct_offset.
: LOOKUP! ( HTTP:response ptr u8 n n bool -- )
   {: a:HTTP:response t:ptr tu:n at:n finish:bool :}
   a 409 HTTP:STATUS!
   SB-RESET S\" {\qerror_summary\q:\q" SB-APPEND t tu SB-APPEND
   S\" /...\q,\qerror\q:" SB-APPEND
   finish if
      S\" {\q.tag\q:\qlookup_failed\q,\qlookup_failed\q:" SB-APPEND
   then
   S\" {\q.tag\q:\q" SB-APPEND t tu SB-APPEND S\" \q" SB-APPEND
   t tu s" incorrect_offset" STR= if
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
   q HTTP:BODY$ {: b:ptr bu:n :}
   a false SESSION-CHECK {: i:n :}
   i 0< if exit then
   b bu i SESSION-HASHERS DROPBOX:HASH-FEED
   bu i SESSION-ATS +!
   a s" null" ANSWER! ;


: UPLOAD-FINISH ( HTTP:request HTTP:response -- )
   {: q:HTTP:request a:HTTP:response :}
   q a ADMITTED? 0= if exit then
   q ARG-READ
   q HTTP:BODY$ 2drop
   a true SESSION-CHECK {: i:n :}
   i 0< if exit then
   false i SESSION-OPEN !
   i SESSION-HASHERS DROPBOX:HASH-END {: h:ptr hu:n :}
   a h hu i SESSION-ATS @ false COMMIT ;


public

\ An upload's body, one chunk of 32 MiB at most, with room to spare, and
\ the ms its read may take, which the connection's idle bound would cut.
$2100000 constant UPLOAD-CAP
60000 constant UPLOAD-MS


\ Starts the server on a free port with one worker.
: START ( -- )
   0 ISSUES ! 0 EXPIRED ! false REVOKED !
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
   UPLOAD-CAP HTTP:BODY-CAP! UPLOAD-MS HTTP:BODY-TIMEOUT!
   $7F000001 0 1 1000 HTTP:START
   SB-RESET s" http://127.0.0.1:" SB-APPEND HTTP:PORT FMT:SB-INT
   SB$ ORIGIN NAME-CAP STORE ORIGIN-U ! ;


: STOP ( -- ) HTTP:STOP ;


\ The server's origin, http://127.0.0.1:<port>.
: ORIGIN$ ( -- ptr u8 n ) ORIGIN ORIGIN-U @ ;


\ Forgets the script, the entries, the kept bytes, the pages, the long
\ poll's answer, the sessions, the revs uploads took, a download's fault, a
\ SKEW, a LOSE, the CUTs, a CUT-TOKEN, a GARBLE, a code GRANT! set, a REVOKE
\ and what was sent; the tokens and the root stay.
: RESET ( -- )
   0 SCRIPTS ! 0 SCRIPTED ! 0 FILES ! 0 CONTENTS ! 0 SESSIONS ! 0 REVS !
   0 GRANT-CODE-U !
   0 SEEN-U ! 0 AUTH-U ! 0 ROOT-SENT-U ! 0 TYPE-SENT-U !
   0 ARG-SENT-U ! 0 RANGE-SENT-U !
   false ROOTED ! false TYPED ! false LEAKED ! false RANGED !
   false SKEWED ! 0 MISFILED-U ! false SHORTED ! false WHOLED !
   false PARTED ! false LOSING ! 0 CUTS ! false TOKEN-CUTTING !
   false REVOKED ! false GARBLING !
   LISTING-RESET ;


\ The app key and refresh token the token route accepts.
: ACCEPT! ( ptr u8 n ptr u8 n -- )
   {: k:ptr ku:n t:ptr tu:n :}
   k ku KEY NAME-CAP STORE KEY-U !
   t tu REFRESH NAME-CAP STORE REFRESH-U ! ;


\ The root every call's Path-Root names; empty means none is sent.
: ROOT! ( ptr u8 n -- ) ROOT NAME-CAP STORE ROOT-U ! ;


\ Expires every access token issued so far.
: EXPIRE ( -- ) ISSUES @ EXPIRED ! ;
\ The next token request's answer is lost as CUT's is, before a token is
\ issued.
: CUT-TOKEN ( -- ) true TOKEN-CUTTING ! ;


\ Refuses every access token, issued or yet to be, as Dropbox does once the
\ user disconnects the app, until RESET.
: REVOKE ( -- ) true REVOKED ! ;


\ A file get_metadata finds: path_lower, path_display, rev, content_hash and
\ size.
: FILE! ( ptr u8 n ptr u8 n ptr u8 n ptr u8 n n -- )
   FILES @ FILE-AT! 1 FILES +! ;


\ An answer sent before any route's own: status, one header (an empty name
\ for none) and a body.
: SCRIPT! ( n ptr u8 n ptr u8 n ptr u8 n -- )
   {: s:n nm:ptr nu:n v:ptr vu:n b:ptr bu:n :}
   SCRIPTS @ {: i:n :}
   s i STATUSES !
   nm nu NAMES NAME-CAP i AT STORE i NAME-US !
   v vu VALUES NAME-CAP i AT STORE i VALUE-US !
   b bu BODIES TEXT-CAP i AT STORE i BODY-US !
   1 SCRIPTS +! ;


\ The paths requested since RESET, joined by spaces.
: SEEN$ ( -- ptr u8 n ) SEEN SEEN-U @ ;
\ The last API call's Authorization value.
: AUTH$ ( -- ptr u8 n ) AUTH AUTH-U @ ;
\ The last API call's Path-Root value, and whether it sent one.
: ROOT-SENT$ ( -- ptr u8 n ) ROOT-SENT ROOT-SENT-U @ ;
: ROOT-SENT? ( -- bool ) ROOTED @ ;
\ The last API call's Content-Type value, and whether it sent one.
: TYPE-SENT$ ( -- ptr u8 n ) TYPE-SENT TYPE-SENT-U @ ;
: TYPE-SENT? ( -- bool ) TYPED @ ;
\ Whether a token request or long poll since RESET carried Authorization or
\ Path-Root.
: LEAKED? ( -- bool ) LEAKED @ ;


\ ---- list_folder, list_folder/continue and list_folder/longpoll

\ A page the listing routes answer in turn: the entries array's JSON, the
\ cursor and has_more.
: PAGE! ( ptr u8 n ptr u8 n bool -- )
   {: e:ptr eu:n k:ptr ku:n more:bool :}
   SB-RESET S\" {\qentries\q:" SB-APPEND e eu SB-APPEND
   S\" ,\qcursor\q:\q" SB-APPEND k ku SB-APPEND
   S\" \q,\qhas_more\q:" SB-APPEND more BOOL+
   s" }" SB-APPEND
   200 SB$ QUEUE ;


\ A 409 reset the listing routes answer in turn.
: PAGE-RESET! ( -- )
   409 S\" {\qerror_summary\q:\qreset/\q,\qerror\q:{\q.tag\q:\qreset\q}}" QUEUE ;


\ The long poll's answer: changes, and a backoff in seconds, 0 for none.
: POLL! ( bool n -- )
   {: changes:bool wait:n :}
   SB-RESET S\" {\qchanges\q:" SB-APPEND changes BOOL+
   wait 0<> if S\" ,\qbackoff\q:" SB-APPEND wait FMT:SB-INT then
   s" }" SB-APPEND
   SB$ POLLED TEXT-CAP STORE POLLED-U ! ;


\ The bodies of the listing calls and long polls since RESET, joined by
\ spaces.
: ARGS$ ( -- ptr u8 n ) ARGS ARGS-U @ ;


\ ---- files/download

\ The bytes files/download serves for a FILE!'s rev, which replace any kept
\ for it; the size FILE! was given must be their length.
: CONTENT! ( ptr u8 n ptr u8 n -- )
   {: r:ptr ru:n b:ptr bu:n :}
   r ru CONTENT-OF {: k:n :}
   k 0< if CONTENTS @ 1 CONTENTS +! else k then {: j:n :}
   r ru CONTENT-REVS NAME-CAP j AT STORE j CONTENT-REV-US !
   b bu CONTENT-BYTES TEXT-CAP j AT STORE j CONTENT-US ! ;


\ Shifts the next download's Content-Range start by one.
: SKEW ( -- ) true SKEWED ! ;
\ The next download answers the file at this rev, whatever rev it asked.
: MISFILE ( ptr u8 n -- ) MISFILED NAME-CAP STORE MISFILED-U ! ;
\ The next download's body lacks its last byte.
: SHORTEN ( -- ) true SHORTED ! ;
\ The next download answers the whole file, whatever Range it asked.
: IGNORE-RANGE ( -- ) true WHOLED ! ;
\ The next download answers a 206 with its Content-Range, even with no
\ Range asked.
: FORCE-RANGE ( -- ) true PARTED ! ;
\ The last download's Dropbox-API-Arg value.
: ARG-SENT$ ( -- ptr u8 n ) ARG-SENT ARG-SENT-U @ ;
\ The last download's Range value, and whether it sent one.
: RANGE-SENT$ ( -- ptr u8 n ) RANGE-SENT RANGE-SENT-U @ ;
: RANGE-SENT? ( -- bool ) RANGED @ ;


\ ---- delete_v2, create_folder_v2, the code grant and a lost answer

\ The code and PKCE verifier the token route grants once, answering the
\ refresh token fake-refresh-granted.
: GRANT! ( ptr u8 n ptr u8 n -- )
   {: k:ptr ku:n v:ptr vu:n :}
   k ku GRANT-CODE NAME-CAP STORE GRANT-CODE-U !
   v vu VERIFIER NAME-CAP STORE VERIFIER-U ! ;


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
