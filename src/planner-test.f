\ planner-test.f - PLANNER's PLAN on every line of src/oracle/plan.tsv,
\ the Rust version's answers: the line's baseline, local and remote
\ observations, read with this file's readers, and its subtree go
\ through PLAN, and the decision is written in the line's own form and
\ compared with the rest of the line.
\ Run from the repository root: hb --load src/planner-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/test/assert.f
require src/lib/fmt.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/json/write.f
require src/lib/json/value.f
require src/model.f
require src/planner.f
require src/dropbox.f

package PLANNER-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

10 constant LF
9 constant TAB

TYPED-VARIABLE OUT ^VEC:vector<u8>
TYPED-VARIABLE W JSON:writer

\ The writer's bytes for one value equal the line's JSON.
: WRITES ( str [ ^JSON:writer -- ^JSON:writer ] -- )
   {: j q :}
   W OUT @ JSON:OPEN q execute JSON:WRITTEN$ j T$= ;

\ A line's first column, then the rest after its tab, empty at the end.
: COLUMN ( str -- str str )
   {: s :}
   s TAB 0 STR:SPLIT-NEXT drop {: h next:n :}
   s str> {: p:^ u:n :}
   h p next + u next - 0 max >str ;

: SUBTREE ( str -- MODEL:subtree )
   dup s\" \"Empty\"" STR:= if drop MODEL-SUBTREE:EMPTY exit then
   s\" \"Occupied\"" T$= MODEL-SUBTREE:OCCUPIED ;

\ The readers below take the forms plan.tsv holds and no
\ others; each answers its value and whether it took it.

\ A string's decoded bytes, copied into AR.
: STRING-OF ( JSON:value -- str bool )
   {: v :}
   v JSON:STRING? 0= if s" " false exit then
   v [: AR @ ARENA:COPY ;] JSON:WITH-STRING true ;

: MEMBER-OF ( JSON:value str -- str bool )
   JSON:FIND MATCH option
      none OF s" " false ENDOF
      some OF STRING-OF ENDOF
   ;MATCH ;

: COUNTED ( n JSON:value JSON:value -- n )
   {: k:n name:JSON:value v:JSON:value :} k 1+ ;

: MEMBERS ( JSON:value -- n )
   {: v :} 0 v [: COUNTED ;] JSON:EACH-MEMBER ;

: OBJECT-OF? ( JSON:value n -- bool )
   {: v n:n :}
   v JSON:OBJECT? if v MEMBERS n = exit then
   false ;

\ An externally tagged variant's payload, or the value itself
\ when it is not an object of that one member.
: TAGGED ( JSON:value str -- JSON:value bool )
   {: v name:str :}
   v 1 OBJECT-OF? 0= if v false exit then
   v name JSON:FIND MATCH option
      none OF v false ENDOF
      some OF true ENDOF
   ;MATCH ;

: LOCAL-OF ( JSON:value -- MODEL:local bool )
   {: v :}
   v 1 OBJECT-OF? {: ok:bool :}
   ok if v s" content" MEMBER-OF else s" " false then
   {: c:str ok2:bool :}
   c DROPBOX:>HASH MODEL-LOCAL:MAKE ok ok2 and ;

: REMOTE-OF ( JSON:value -- MODEL:remote bool )
   {: v :}
   v 2 OBJECT-OF? {: ok:bool :}
   ok if v s" content" MEMBER-OF else s" " false then
   {: c:str ok2:bool :}
   ok if v s" revision" MEMBER-OF else s" " false then
   {: r:str ok3:bool :}
   c DROPBOX:>HASH r DROPBOX:>REV MODEL-REMOTE:MAKE
   ok ok2 and ok3 and ;

: REASON-OF ( JSON:value -- MODEL:unknown-reason bool )
   {: v :}
   v s" Incomplete" JSON:STRING= if
      MODEL-UNKNOWN--REASON:INCOMPLETE true exit then
   v s" Inaccessible" JSON:STRING= if
      MODEL-UNKNOWN--REASON:INACCESSIBLE true exit then
   v s" Unavailable" JSON:STRING= if
      MODEL-UNKNOWN--REASON:UNAVAILABLE true exit then
   v s" Stale" JSON:STRING= if
      MODEL-UNKNOWN--REASON:STALE true exit then
   v s" CursorReset" JSON:STRING= if
      MODEL-UNKNOWN--REASON:CURSOR-RESET true exit then
   v s" Unsupported" JSON:STRING= if
      MODEL-UNKNOWN--REASON:UNSUPPORTED true exit then
   MODEL-UNKNOWN--REASON:INCOMPLETE false ;

: BASELINE-OF ( JSON:value -- MODEL:baseline bool )
   {: v :}
   v s" Absent" JSON:STRING= if
      MODEL-BASELINE:ABSENT true exit then
   v s" Directory" JSON:STRING= if
      MODEL-BASELINE:DIRECTORY true exit then
   v s" Present" TAGGED {: p ok:bool :}
   p REMOTE-OF {: f ok2:bool :}
   f MODEL-BASELINE:PRESENT ok ok2 and ;

: LOCAL-OBSERVATION-OF
   ( JSON:value -- MODEL:observation<MODEL:local> bool )
   {: v :}
   v s" ConfirmedAbsent" JSON:STRING= if
      MODEL-OBSERVATION:ABSENT true exit then
   v s" Directory" JSON:STRING= if
      MODEL-OBSERVATION:DIRECTORY true exit then
   v s" Unknown" TAGGED {: u ok:bool :}
   ok if u REASON-OF swap MODEL-OBSERVATION:UNKNOWN swap exit then
   v s" Present" TAGGED {: p ok2:bool :}
   p LOCAL-OF {: f ok3:bool :}
   f MODEL-OBSERVATION:PRESENT ok2 ok3 and ;

: REMOTE-OBSERVATION-OF
   ( JSON:value -- MODEL:observation<MODEL:remote> bool )
   {: v :}
   v s" ConfirmedAbsent" JSON:STRING= if
      MODEL-OBSERVATION:ABSENT true exit then
   v s" Directory" JSON:STRING= if
      MODEL-OBSERVATION:DIRECTORY true exit then
   v s" Unknown" TAGGED {: u ok:bool :}
   ok if u REASON-OF swap MODEL-OBSERVATION:UNKNOWN swap exit then
   v s" Present" TAGGED {: p ok2:bool :}
   p REMOTE-OF {: f ok3:bool :}
   f MODEL-OBSERVATION:PRESENT ok2 ok3 and ;

\ A column no reader took fails a check naming its text.
: TOOK ( bool str str -- )
   {: ok:bool t:str what:str :}
   ok 0= if t what T$= then ;

: BASELINE-IN ( str -- MODEL:baseline )
   {: t :} t JSON:PARSE BASELINE-OF t s" a baseline" TOOK ;

: LOCAL-IN ( str -- MODEL:observation<MODEL:local> )
   {: t :}
   t JSON:PARSE LOCAL-OBSERVATION-OF t s" a local observation" TOOK ;

: REMOTE-IN ( str -- MODEL:observation<MODEL:remote> )
   {: t :}
   t JSON:PARSE REMOTE-OBSERVATION-OF
   t s" a remote observation" TOOK ;

\ The four inputs from a line's columns, then the columns after them.
: INPUTS ( str -- MODEL:baseline MODEL:observation<MODEL:local>
   MODEL:observation<MODEL:remote> MODEL:subtree str )
   COLUMN {: b t1 :}
   t1 COLUMN {: l t2 :}
   t2 COLUMN {: r t3 :}
   t3 COLUMN {: s t4 :}
   b BASELINE-IN l LOCAL-IN r REMOTE-IN s SUBTREE t4 ;

\ Each word below takes a decision's payload, the line's decision
\ column and the columns after it.
: NOOP-IS ( MODEL:baseline str str -- )
   {: v k j :}
   k s" noop" T$=
   j BASELINE-IN v MODEL:BASELINE= TTRUE ;

: OPERATE-IS ( MODEL:operation str str -- )
   {: v k j :}
   k s" operate" T$=
   j [: v swap MODEL:OPERATION>JSON ;] WRITES ;

: BLOCKED-IS ( MODEL:blocked-reason str str -- )
   {: v k j :}
   k s" blocked" T$=
   v MATCH MODEL:blocked-reason
      unknown OF s" unknown" ENDOF
      occupied OF s" occupied" ENDOF
   ;MATCH j T$= ;

: CONFLICT-IS ( MODEL:conflict str str -- )
   {: v k j :}
   k s" conflict" T$=
   j [: v swap MODEL:CONFLICT>JSON ;] WRITES ;

\ A collision's columns: its variant, then its payload's JSON.
: COLLISION-IS ( MODEL:collision str str -- )
   {: v k t :}
   k s" collision" T$=
   t COLUMN {: n j :}
   v MATCH MODEL:collision
      local-file OF {: f :} n s" LocalFileRemoteDirectory" T$=
         j [: f swap MODEL:LOCAL>JSON ;] WRITES ENDOF
      local-dir OF {: f :} n s" LocalDirectoryRemoteFile" T$=
         j [: f swap MODEL:REMOTE>JSON ;] WRITES ENDOF
   ;MATCH ;

\ The decision equals the line's from its decision column on.
: DECIDED ( MODEL:decision str -- )
   COLUMN {: d k j :}
   d MATCH MODEL:decision
      noop OF k j NOOP-IS ENDOF
      operate OF k j OPERATE-IS ENDOF
      blocked OF k j BLOCKED-IS ENDOF
      conflicted OF k j CONFLICT-IS ENDOF
      collided OF k j COLLISION-IS ENDOF
   ;MATCH ;

\ Plans one line, if it is not empty, and counts it.
: PLAN-LINE ( n str -- n )
   {: line :}
   line STR:len 0= if exit then
   line INPUTS {: b l r s t :}
   b l r s PLANNER:PLAN t DECIDED 1+ ;

\ Plans every line of T; answers how many it planned.
: PLAN-LINES ( str -- n )
   {: t :}
   0 0
   begin >r t LF r> STR:SPLIT-NEXT while
      >r PLAN-LINE r>
   repeat
   drop drop ;

: LINES ( str -- n )
   str> {: t:^ u:n :}
   0 u 0 ?do t i + c@ LF = if 1+ then loop ;

: PLAN-CASE ( -- n )
   s" plan.tsv" T-LABEL
   s" src/oracle/plan.tsv" {: f :}
   AR @ f FS:FILE-SIZE ARENA:ALLOC {: t:^ u:n :}
   f t u FS:READ-ALL u T=
   t u >str PLAN-LINES dup t u >str LINES T= ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW OUT !
   [: PLAN-CASE ;] [: OUT @ VEC:DELETE AR @ ARENA:RELEASE ;] finally
   s" planner-test: " type FMT:.INT s"  lines, " type
   T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

PLANNER-TEST:RUN
