\ test-formal.f - the check that an FSM table in a source file is the one
\ its TLA+ model holds, for tests, never production. HOLDS compares Habu's
\ TEST-FSM rendering of the table with formal/<Model>Table.tla and runs TLC
\ on formal/<Model>Follows.tla.
\ Tests alone load this file; nothing in the program calls these words.
\ STORAGE CLASS. CALLER-OWNED: the file, the rendered table and the temp
\ directory's path lie in the arena the caller passes.

require src/lib/adt/result.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/process-command.f
require src/lib/test.f
require src/lib/test-fsm.f

package TEST-FORMAL

\ The bytes, copied into the arena.
: KEPT ( str ^ARENA:arena -- str )
   {: s:str ar :}
   s STR:len {: u:n :}
   ar u ARENA:ALLOC drop {: b:^ :}
   s STR:data b u BYTE-COPY
   b u >str ;

\ The file at the path, whole, in the arena.
: FILE$ ( str ^ARENA:arena -- str )
   {: p:str ar :}
   p FS:FILE-SIZE {: u:n :}
   ar u ARENA:ALLOC drop {: b:^ :}
   b  p b u FS:READ-ALL >str ;

\ TLC on the model's Follows module, its files in d; its output on a failure.
: FOLLOWS-RUN ( CMD:command str str -- CMD:command )
   {: d:str m:str :}
   s" tlc" CMD:ARG+ s" -workers" CMD:ARG+ s" 1" CMD:ARG+
   s" -metadir" CMD:ARG+
   SB-RESET d SB-APPEND s" /tlc" SB-APPEND SB$ CMD:ARG+
   s" -config" CMD:ARG+
   SB-RESET m SB-APPEND s" Follows.cfg" SB-APPEND SB$ CMD:ARG+
   SB-RESET m SB-APPEND s" Follows.tla" SB-APPEND SB$ CMD:ARG+
   s" formal" CMD:CWD!  s" TMPDIR" d CMD:ENV+
   s" /usr/bin/env" 120000 >MS CMD:RUN-RC
   MATCH result ok OF ENDOF err OF ENDOF ;MATCH {: rc:n :}
   rc 0<> if CMD:OUT$ type then
   rc 0 T= ;

public

\ The model's copy of the source file's table is its lines; TLC finds the
\ model follows them, run in a temp dir made under TMPDIR and removed.
: HOLDS ( str str str ^ARENA:arena -- )
   {: f:str n:str m:str ar :}
   f n m ar TEST-FSM:TABLE-MODULE {: t:str :}
   t STR:len 0= if exit then
   SB-RESET s" formal/" SB-APPEND m SB-APPEND s" Table.tla" SB-APPEND
   SB$ ar FILE$ t T$=
   s" test-formal" FS:MKTEMP-DIR ar KEPT {: d:str :}
   [: d m FOLLOWS-RUN ;] CMD:WITH-COMMAND
   d FS:REMOVE-TREE ;

;package
