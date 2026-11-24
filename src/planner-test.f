\ planner-test.f - PLANNER's PLAN on every line of src/oracle/plan.tsv,
\ the Rust version's answers: the line's baseline, local and remote
\ observations, read with MODEL's readers, and its subtree go through
\ PLAN, and the decision is written in the line's own form and compared
\ with the rest of the line.
\ Run from the repository root: hb --load src/planner-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/test.f
require src/lib/fmt.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/json.f
require src/model.f
require src/planner.f

using MODEL
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

: SUBTREE ( str -- subtree )
   dup s\" \"Empty\"" STR:= if drop MODEL-SUBTREE:EMPTY exit then
   s\" \"Occupied\"" T$= MODEL-SUBTREE:OCCUPIED ;

\ The four inputs from a line's columns, then the columns after them.
: INPUTS ( str -- baseline observation<local>
   observation<remote> subtree str )
   COLUMN {: b t1 :}
   t1 COLUMN {: l t2 :}
   t2 COLUMN {: r t3 :}
   t3 COLUMN {: s t4 :}
   b AR @ JSON>BASELINE
   l AR @ JSON>LOCAL-OBSERVATION
   r AR @ JSON>REMOTE-OBSERVATION
   s SUBTREE t4 ;

\ Each word below takes a decision's payload, the line's decision
\ column and the columns after it.
: NOOP-IS ( baseline str str -- )
   {: v k j :}
   k s" noop" T$=
   j [: v swap BASELINE>JSON ;] WRITES ;

: OPERATE-IS ( operation str str -- )
   {: v k j :}
   k s" operate" T$=
   j [: v swap OPERATION>JSON ;] WRITES ;

: BLOCKED-IS ( blocked-reason str str -- )
   {: v k j :}
   k s" blocked" T$=
   v MATCH blocked-reason
      unknown OF s" unknown" ENDOF
      occupied OF s" occupied" ENDOF
   ;MATCH j T$= ;

: CONFLICT-IS ( conflict str str -- )
   {: v k j :}
   k s" conflict" T$=
   j [: v swap CONFLICT>JSON ;] WRITES ;

\ A collision's columns: its variant, then its payload's JSON.
: COLLISION-IS ( collision str str -- )
   {: v k t :}
   k s" collision" T$=
   t COLUMN {: n j :}
   v MATCH collision
      local-file OF {: f :} n s" LocalFileRemoteDirectory" T$=
         j [: f swap LOCAL>JSON ;] WRITES ENDOF
      local-dir OF {: f :} n s" LocalDirectoryRemoteFile" T$=
         j [: f swap REMOTE>JSON ;] WRITES ENDOF
   ;MATCH ;

\ The decision equals the line's from its decision column on.
: DECIDED ( decision str -- )
   COLUMN {: d k j :}
   d MATCH decision
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
;using

PLANNER-TEST:RUN
