\ attention.f - package ATTENTION: the text `omabox status` shows, the
\ Rust version's status.rs. RENDER reads a journal read-only and lists
\ what needs attention: each pending plan, its operations left and the
\ next one's description; each blocked plan and why; each path either
\ side observed as unknown; each pending recovery copy. An excluded path
\ is left out, but for a recovery copy. No account, namespace, root,
\ cursor, content, revision, recovery path or conflict is shown. A file
\ that is absent or holds no Dropbox binding is not set up. The journal
\ is never created, migrated or written.
\ The lines are sorted by path as Rust's Path::cmp orders paths, by
\ component, then by text. An absolute path shows as
\ "(invalid synchronized path)", the empty one as ".", and bytes that
\ are not UTF-8 as U+FFFD, as to_string_lossy shows them.
\ A failure logs two lines, Rust's text and its help, and throws.
\ E-INSPECT: stat of the journal failed other than ENOENT, the cause in
\ FS:ERRNO, 0 where none. E-JOURNAL: JOURNAL or SQLITE threw, after
\ their own lines, which name the journal `[Omabox journal]`; a code of
\ another package goes on unchanged.
\ STORAGE CLASS. CALLER-OWNED: the text RENDER answers is a literal or
\ lies in the arena the caller passes; what the journal answers lies in
\ an arena of RENDER's own, released before it returns.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/vector.f
require src/lib/sort.f
require src/lib/fmt.f
require src/lib/log.f
require src/lib/fs.f
require src/lib/sqlite.f
require src/lib/adt/option.f
require src/lib/utf8-lossy.f
require src/model.f
require src/journal.f

package ATTENTION
public

-100900 constant E-FIRST
-100999 constant E-LAST
-100900 s" could not inspect Omabox setup state" ERROR:CODE E-INSPECT
-100901 s" could not read the Omabox journal" ERROR:CODE E-JOURNAL

private

$2F constant SLASH

\ path: what the lines sort by; shown: the path as the text shows it;
\ detail: the text after it.
STRUCTURE entry
   FIELD path MODEL:path
   FIELD shown str
   FIELD detail str
;STRUCTURE

: NOT-SET-UP$ ( -- str )
   s\" Omabox is not set up; run `omabox setup [REMOTE_ROOT]`.\n" ;

: NOTHING$ ( -- str )
   s\" Omabox has no recorded work needing attention.\n" ;

: HEADER$ ( -- str ) s\" Omabox status:\n" ;


\ ---- failures ------------------------------------------------------

: LOG-OPEN ( -- ) LOG:ERROR s" attention" LOG:LINE ;

\ Ends the error's line, logs Rust's help, then throws code with cause
\ as FS:ERRNO.
: HELPED ( n n -- )
   {: code:n cause:n :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+
   s" Check access to the Omabox state directory, then retry"
   LOG:TEXT+ s"  `omabox status`." LOG:TEXT+ LOG:;LINE
   cause FS:CAUSE! code throw ;

: INSPECT-FAILED ( n -- )
   {: cause:n :}
   LOG-OPEN s" could not inspect Omabox setup state" LOG:TEXT+
   E-INSPECT cause HELPED ;

\ A path FS refuses before stat: too long, or holding a NUL byte.
: STAT-CAUGHT ( n -- )
   {: code:n :}
   code E-FS-PATH = if FS:ENAMETOOLONG INSPECT-FAILED then
   code E-FFI-NUL = if 0 INSPECT-FAILED then
   code throw ;

: WITHIN? ( n n n -- bool )
   {: c:n first:n last:n :}
   c last >= c first <= and ;

\ The codes Rust's JournalError holds: JOURNAL's and SQLITE's.
: JOURNAL-CODE? ( n -- bool )
   {: c:n :}
   c JOURNAL:E-FIRST JOURNAL:E-LAST WITHIN? if true exit then
   c SQLITE:E-SQL = c SQLITE:E-CORRUPT = or c SQLITE:E-FULL = or ;

\ JOURNAL's or SQLITE's code is E-JOURNAL's, logged with the operation
\ that failed; any other goes on.
: CAUGHT ( n str -- )
   {: code:n op:str :}
   code JOURNAL-CODE? 0= if code throw then
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
   E-JOURNAL 0 HELPED ;

\ Runs step; its failure is op's.
: GUARDED ( [ -- ] str -- )
   {: step op:str :}
   step catch {: code:n :}
   code 0= if exit then
   code op CAUGHT ;


\ ---- setup state ---------------------------------------------------

\ Path::try_exists: false only where stat answers ENOENT.
: PRESENT? ( str -- bool )
   {: path:str :}
   false [: drop path FS:TRY-STAT ;] catch {: code:n :}
   code 0<> if code STAT-CAUGHT then
   if true exit then
   FS:ERRNO FS:ENOENT <> if FS:ERRNO INSPECT-FAILED then
   false ;

\ A slot the open stores its journal in, read only once it has.
ARENA SLOTS JOURNAL:journal

: OPENED ( str ^ARENA:arena -- JOURNAL:journal )
   {: path:str ar :}
   ar SLOTS-NEW {: slot :}
   [: path JOURNAL:OPEN-READ slot ! ;]
   s" open the journal read-only" GUARDED
   slot @ ;

: BOUND? ( JOURNAL:journal ^ARENA:arena -- bool )
   JOURNAL:DROPBOX-BINDING MATCH option
      some OF drop true ENDOF
      none OF false ENDOF
   ;MATCH ;

: SET-UP? ( JOURNAL:journal ^ARENA:arena -- bool )
   {: j ar :}
   false [: drop j ar BOUND? ;] catch {: code:n :}
   code 0<> if code s" read Dropbox setup state" CAUGHT then ;


\ ---- text pieces ---------------------------------------------------

\ a then b, laid in the arena.
: CAT ( str str ^ARENA:arena -- str )
   {: x:str y:str ar :}
   x str> {: a:^ u:n :}
   y str> {: b:^ v:n :}
   ar u v + ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   b dst u + v BYTE-COPY
   dst u v + >str ;

: NUMBERED ( str n ^ARENA:arena -- str )
   {: a:str k:n ar :}
   a k FMT:INT$ ar CAT ;

: BLOCKAGE$ ( MODEL:blockage ^ARENA:arena -- str )
   {: why ar :}
   why MATCH MODEL:blockage
      unsupported-file-size OF
         s" file exceeds the supported Dropbox upload size" ENDOF
      remote-rejected OF {: tag:str :}
         s" Dropbox rejected the path (" tag ar CAT
         s" )" ar CAT ENDOF
      download-unavailable OF {: st:n :}
         s" Dropbox download returned HTTP " st ar NUMBERED ENDOF
      download-verification-failed OF
         s" Dropbox download did not match its recorded identity"
      ENDOF
      stage-occupied OF
         s" unrelated data occupies the private staging path" ENDOF
      local-object-in-way OF
         s" a local object blocks the download path" ENDOF
      remote-object OF
         s" a Dropbox object blocks the file path" ENDOF
      conflict-copy-occupied OF
         s" another file holds this path's conflict copy name" ENDOF
   ;MATCH ;


\ ---- how a path shows ----------------------------------------------

: SHOWN ( MODEL:path ^ARENA:arena -- str )
   {: path ar :}
   path MODEL:PATH>STR {: s:str :}
   s str> {: p:^ u:n :}
   u 0= if s" ." exit then
   p c@ SLASH = if s" (invalid synchronized path)" exit then
   s ar UTF8-LOSSY:REPAIR ;

: ENTRY+ ( MODEL:path str ^ARENA:arena ^VEC:vector<entry> -- )
   {: path detail:str ar v :}
   path path ar SHOWN detail ENTRY-MAKE v VEC:PUSH ! ;


\ ---- what needs attention -----------------------------------------

: PENDING? ( JOURNAL:planned-operation -- bool )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :}
   s MATCH JOURNAL:record-status
      pending OF true ENDOF
      completed OF false ENDOF
   ;MATCH ;

: PENDING-COUNT ( ^VEC:vector<JOURNAL:planned-operation> -- n )
   {: ops :}
   0 ops VEC:COUNT 0 ?do ops i VEC:AT @ PENDING? if 1+ then loop ;

\ The first pending operation's description; one is pending.
: NEXT$ ( ^VEC:vector<JOURNAL:planned-operation> -- str )
   {: ops :}
   0 begin ops over VEC:AT @ PENDING? 0= while 1+ repeat
   ops swap VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :}
   o MODEL:OPERATION$ ;

: PENDING-DETAIL
   ( ^VEC:vector<JOURNAL:planned-operation> ^ARENA:arena -- str )
   {: ops ar :}
   ops PENDING-COUNT {: k:n :}
   k 0= if
      s" pending sync: completion is awaiting journal recovery"
      exit
   then
   s" pending sync: " k ar NUMBERED s"  remaining; next: " ar CAT
   ops NEXT$ ar CAT ;

: PENDING+ ( JOURNAL:plan-record ^ARENA:arena ^VEC:vector<entry> -- )
   {: plan ar v :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id path ops s :}
   path MODEL:EXCLUDED? if exit then
   path ops ar PENDING-DETAIL ar v ENTRY+ ;

: PENDING-ENTRIES
   ( JOURNAL:journal ^ARENA:arena ^VEC:vector<entry> -- )
   {: j ar v :}
   j ar JOURNAL:PENDING-PLANS {: plans :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ ar v PENDING+ loop ;

: BLOCKED-DETAIL ( MODEL:blockage ^ARENA:arena -- str )
   {: why ar :}
   s" blocked sync: " why ar BLOCKAGE$ ar CAT
   s" ; retry is scheduled" ar CAT ;

: BLOCKED+ ( JOURNAL:plan-record ^ARENA:arena ^VEC:vector<entry> -- )
   {: plan ar v :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id path ops s :}
   path MODEL:EXCLUDED? if exit then
   s MATCH JOURNAL:plan-status
      pending OF ENDOF
      blocked OF drop {: why :} path why ar BLOCKED-DETAIL ar v ENTRY+
      ENDOF
      completed OF ENDOF
   ;MATCH ;

: BLOCKED-ENTRIES
   ( JOURNAL:journal ^ARENA:arena ^VEC:vector<entry> -- )
   {: j ar v :}
   j ar JOURNAL:BLOCKED-PLANS {: plans :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ ar v BLOCKED+ loop ;

\ The reason's text after the side's words, when the observation was
\ unknown.
: UNKNOWN+
   ( MODEL:path option<MODEL:unknown-reason> str ^ARENA:arena
     ^VEC:vector<entry> -- )
   {: path why side:str ar v :}
   why MATCH option
      none OF ENDOF
      some OF MODEL:UNKNOWN$ {: t:str :}
         path side t ar CAT ar v ENTRY+
      ENDOF
   ;MATCH ;

: LOCAL-WHY
   ( MODEL:observation<MODEL:local> -- option<MODEL:unknown-reason> )
   MATCH MODEL:observation
      present OF drop OPTION:NONE ENDOF
      directory OF OPTION:NONE ENDOF
      absent OF OPTION:NONE ENDOF
      unknown OF OPTION:SOME ENDOF
   ;MATCH ;

: REMOTE-WHY
   ( MODEL:observation<MODEL:remote> -- option<MODEL:unknown-reason> )
   MATCH MODEL:observation
      present OF drop OPTION:NONE ENDOF
      directory OF OPTION:NONE ENDOF
      absent OF OPTION:NONE ENDOF
      unknown OF OPTION:SOME ENDOF
   ;MATCH ;

: LOCAL+ ( MODEL:local-record ^ARENA:arena ^VEC:vector<entry> -- )
   {: r ar v :}
   r MODEL-LOCAL--RECORD:UNMAKE {: path o :}
   path MODEL:EXCLUDED? if exit then
   path o LOCAL-WHY s" local status unknown: " ar v UNKNOWN+ ;

: LOCAL-ENTRIES ( JOURNAL:journal ^ARENA:arena ^VEC:vector<entry> -- )
   {: j ar v :}
   j ar JOURNAL:UNKNOWN-LOCALS {: rs :}
   rs VEC:COUNT 0 ?do rs i VEC:AT @ ar v LOCAL+ loop ;

: REMOTE+ ( MODEL:remote-record ^ARENA:arena ^VEC:vector<entry> -- )
   {: r ar v :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k path o :}
   path MODEL:EXCLUDED? if exit then
   path o REMOTE-WHY s" Dropbox status unknown: " ar v UNKNOWN+ ;

: REMOTE-ENTRIES
   ( JOURNAL:journal ^ARENA:arena ^VEC:vector<entry> -- )
   {: j ar v :}
   j ar JOURNAL:UNKNOWN-REMOTES {: rs :}
   rs VEC:COUNT 0 ?do rs i VEC:AT @ ar v REMOTE+ loop ;

: RECOVERY+ ( JOURNAL:recovery-record ^ARENA:arena ^VEC:vector<entry> -- )
   {: r ar v :}
   r JOURNAL-RECOVERY--RECORD:UNMAKE {: id op path copy h s kept :}
   path s" recovery copy is pending" ar v ENTRY+ ;

: RECOVERY-ENTRIES
   ( JOURNAL:journal ^ARENA:arena ^VEC:vector<entry> -- )
   {: j ar v :}
   j ar JOURNAL:PENDING-RECOVERIES {: rs :}
   rs VEC:COUNT 0 ?do rs i VEC:AT @ ar v RECOVERY+ loop ;

: ENTRIES ( JOURNAL:journal ^ARENA:arena -- ^VEC:vector<entry> )
   {: j ar :}
   ar ARENA:ALLOCATOR 0 [type] entry VEC:NEW {: v :}
   [: j ar v PENDING-ENTRIES ;] s" read pending sync plans" GUARDED
   [: j ar v BLOCKED-ENTRIES ;] s" read blocked sync plans" GUARDED
   [: j ar v LOCAL-ENTRIES ;] s" read local observations" GUARDED
   [: j ar v REMOTE-ENTRIES ;] s" read remote observations" GUARDED
   [: j ar v RECOVERY-ENTRIES ;]
   s" read pending recovery copies" GUARDED
   v ;


\ ---- the text ------------------------------------------------------

: ENTRY< ( n n ^VEC:vector<entry> -- bool )
   {: x:n y:n v :}
   v x VEC:AT @ ENTRY-UNMAKE {: a sa:str da:str :}
   v y VEC:AT @ ENTRY-UNMAKE {: b sb:str db:str :}
   a b MODEL:PATH-CMP {: c:n :}
   c 0= if da db STR:< exit then
   c 0 < ;

\ The entries' indices in the text's order.
: ORDERED ( ^VEC:vector<entry> ^ARENA:arena -- ^VEC:vector<n> )
   {: v ar :}
   v VEC:COUNT {: k:n :}
   ar ARENA:ALLOCATOR k [type] n VEC:NEW {: idx :}
   k 0 ?do i idx i VEC:AT ! loop
   k 1 > if idx 0 VEC:AT k [: v ENTRY< ;] SORT:SORT! then
   idx ;

\ Copies s to dst at `at`; answers the index after it.
: PUT ( n str ^u8 -- n )
   {: at:n s:str dst:^ :}
   s str> {: a:^ u:n :}
   a dst at + u BYTE-COPY
   at u + ;

\ "- ", the path, ": ", the detail and a newline.
: LINE-SIZE ( entry -- n )
   ENTRY-UNMAKE {: k s:str d:str :}
   s STR:len d STR:len + 5 + ;

: LINE! ( n entry ^u8 -- n )
   {: at:n e dst:^ :}
   e ENTRY-UNMAKE {: k s:str d:str :}
   at s" - " dst PUT s dst PUT s" : " dst PUT
   d dst PUT s\" \n" dst PUT ;

: SIZE ( ^VEC:vector<entry> -- n )
   {: v :}
   HEADER$ STR:len v VEC:COUNT 0 ?do v i VEC:AT @ LINE-SIZE + loop ;

: TEXT ( ^VEC:vector<entry> ^VEC:vector<n> ^ARENA:arena -- str )
   {: v idx out :}
   v VEC:COUNT 0= if NOTHING$ exit then
   v SIZE {: size:n :}
   out size ARENA:ALLOC drop {: dst:^ :}
   0 HEADER$ dst PUT
   idx VEC:COUNT 0 ?do v idx i VEC:AT @ VEC:AT @ dst LINE! loop
   drop dst size >str ;

\ The text for a bound journal, laid in out; ar holds the reads.
: SHOW ( JOURNAL:journal ^ARENA:arena ^ARENA:arena -- str )
   {: j out ar :}
   j ar SET-UP? 0= if NOT-SET-UP$ exit then
   j ar ENTRIES {: v :}
   v v ar ORDERED out TEXT ;

\ The journal at path opened in ar, shown in out, then closed.
: READ ( str ^ARENA:arena ^ARENA:arena -- str )
   {: path:str out ar :}
   path ar OPENED {: j :}
   [: j out ar SHOW ;] [: j JOURNAL:CLOSE ;] finally ;

public

\ The status text for the journal file at path, laid in the arena.
: RENDER ( str ^ARENA:arena -- str )
   {: path:str out :}
   path PRESENT? 0= if NOT-SET-UP$ exit then
   path out [: READ ;] ARENA:WITH ;

;package
