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
require src/lib/byte-buffer.f
require src/lib/json.f
require src/model.f
require src/planner.f

using MODEL
package PLANNER-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

10 constant LF
9 constant TAB

create OUT BUF:HDR-BYTES allot
TYPED-VARIABLE W JSON:writer

\ The writer's bytes for one value equal the line's JSON.
: WRITES ( ^u8 n [ ^JSON:writer -- ^JSON:writer ] -- )
   {: j:^ ju:n q :}
   W OUT JSON:WRITE-OPEN-BUF q execute JSON:WRITTEN$ j ju T$= ;

\ A line's first column, then the rest after its tab, empty at the end.
: COLUMN ( ^u8 n -- ^u8 n ^u8 n )
   {: p:^ u:n :}
   p u TAB 0 SPLIT-NEXT drop {: h:^ hu:n next:n :}
   h hu p next + u next - 0 max ;

: SUBTREE ( ^u8 n -- subtree )
   2dup s\" \"Empty\"" STR= if 2drop MODEL-SUBTREE:EMPTY exit then
   s\" \"Occupied\"" T$= MODEL-SUBTREE:OCCUPIED ;

\ The four inputs from a line's columns, then the columns after them.
: INPUTS ( ^u8 n -- baseline observation<local>
   observation<remote> subtree ^u8 n )
   COLUMN {: b:^ bu:n t1:^ u1:n :}
   t1 u1 COLUMN {: l:^ lu:n t2:^ u2:n :}
   t2 u2 COLUMN {: r:^ ru:n t3:^ u3:n :}
   t3 u3 COLUMN {: s:^ su:n t4:^ u4:n :}
   b bu >str AR @ JSON>BASELINE
   l lu >str AR @ JSON>LOCAL-OBSERVATION
   r ru >str AR @ JSON>REMOTE-OBSERVATION
   s su SUBTREE t4 u4 ;

\ Each word below takes a decision's payload, the line's decision
\ column and the columns after it.
: NOOP-IS ( baseline ^u8 n ^u8 n -- )
   {: v k:^ ku:n j:^ ju:n :}
   k ku s" noop" T$=
   j ju [: v swap BASELINE>JSON ;] WRITES ;

: OPERATE-IS ( operation ^u8 n ^u8 n -- )
   {: v k:^ ku:n j:^ ju:n :}
   k ku s" operate" T$=
   j ju [: v swap OPERATION>JSON ;] WRITES ;

: BLOCKED-IS ( blocked-reason ^u8 n ^u8 n -- )
   {: v k:^ ku:n j:^ ju:n :}
   k ku s" blocked" T$=
   v MATCH blocked-reason
      unknown OF s" unknown" ENDOF
      occupied OF s" occupied" ENDOF
   ;MATCH j ju T$= ;

: CONFLICT-IS ( conflict ^u8 n ^u8 n -- )
   {: v k:^ ku:n j:^ ju:n :}
   k ku s" conflict" T$=
   j ju [: v swap CONFLICT>JSON ;] WRITES ;

\ A collision's columns: its variant, then its payload's JSON.
: COLLISION-IS ( collision ^u8 n ^u8 n -- )
   {: v k:^ ku:n t:^ tu:n :}
   k ku s" collision" T$=
   t tu COLUMN {: n:^ nu:n j:^ ju:n :}
   v MATCH collision
      local-file OF {: f :} n nu s" LocalFileRemoteDirectory" T$=
         j ju [: f swap LOCAL>JSON ;] WRITES ENDOF
      local-dir OF {: f :} n nu s" LocalDirectoryRemoteFile" T$=
         j ju [: f swap REMOTE>JSON ;] WRITES ENDOF
   ;MATCH ;

\ The decision equals the line's from its decision column on.
: DECIDED ( decision ^u8 n -- )
   COLUMN {: d k:^ ku:n j:^ ju:n :}
   d MATCH decision
      noop OF k ku j ju NOOP-IS ENDOF
      operate OF k ku j ju OPERATE-IS ENDOF
      blocked OF k ku j ju BLOCKED-IS ENDOF
      conflicted OF k ku j ju CONFLICT-IS ENDOF
      collided OF k ku j ju COLLISION-IS ENDOF
   ;MATCH ;

\ Plans one line, if it is not empty, and counts it.
: PLAN-LINE ( n ^u8 n -- n )
   {: line:^ lu:n :}
   lu 0= if exit then
   line lu INPUTS {: b l r s t:^ tu:n :}
   b l r s PLANNER:PLAN t tu DECIDED 1+ ;

\ Plans every line of T; answers how many it planned.
: PLAN-LINES ( ^u8 n -- n )
   {: t:^ u:n :}
   0 0
   begin >r t u LF r> SPLIT-NEXT while
      >r PLAN-LINE r>
   repeat
   2drop drop ;

: LINES ( ^u8 n -- n )
   {: t:^ u:n :}
   0 u 0 ?do t i + c@ LF = if 1+ then loop ;

: PLAN-CASE ( -- n )
   s" plan.tsv" T-LABEL
   s" src/oracle/plan.tsv" {: f:^ fu:n :}
   AR @ f fu FS:FILE-SIZE ARENA:ALLOC {: t:^ u:n :}
   f fu t u FS:READ-ALL u T=
   t u PLAN-LINES dup t u LINES T= ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   OUT 64 BUF:N>BLEN BUF:INIT
   [: PLAN-CASE ;] [: OUT BUF:DISPOSE AR @ ARENA:RELEASE ;] finally
   s" planner-test: " type FMT:.INT s"  lines, " type
   T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package
;using

PLANNER-TEST:RUN
