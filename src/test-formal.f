\ test-formal.f - the check that an FSM table in a source file is the one
\ its TLA+ model holds, for tests, never production. HOLDS renders the
\ table named in the source file as the model's Table module, compares it
\ with formal/<Model>Table.tla, and runs TLC on formal/<Model>Follows.tla.
\ Tests alone load this file; nothing in the program calls these words.
\ STORAGE CLASS. CALLER-OWNED: the file, the rendered table and the temp
\ directory's path lie in the arena the caller passes.

require src/lib/adt/option.f
require src/lib/adt/result.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fsm.f
require src/lib/process-command.f
require src/lib/test.f

package TEST-FORMAL

ARENA RENDERED str

\ The bytes laid after the text at h, in the arena.
: ADD ( ^str ^u8 n ^ARENA:arena -- )
   {: h a:^ u:n ar :}
   h @ str> {: s:^ su:n :}
   ar su u + ARENA:ALLOC drop {: b:^ :}
   s b su BYTE-COPY
   a b su + u BYTE-COPY
   b su u + >str h ! ;

\ The file at the path, whole, in the arena.
: FILE$ ( ^u8 n ^ARENA:arena -- ^u8 n )
   {: p:^ pu:n ar :}
   p pu FS:FILE-SIZE {: u:n :}
   ar u ARENA:ALLOC drop {: b:^ :}
   b  p pu b u FS:READ-ALL ;

\ The text from the table's name to its end; none if absent.
: TABLE-AT ( ^u8 n ^u8 n -- ^u8 n )
   {: t:^ tu:n n:^ nu:n :}
   SB-RESET s" FSM:DEFINE " SB-APPEND n nu SB-APPEND
   t tu SB$ FIND-SUB MATCH option
      none OF t 0 ENDOF
      some OF IDX>N s" FSM:DEFINE " nip + t over + tu rot - ENDOF
   ;MATCH ;

: SB-LINE ( ^u8 n -- ) SB-APPEND 10 SB-APPEND-C ;

\ The model's Table module's lines before the tuples.
: HEAD$ ( ^u8 n ^u8 n ^u8 n -- ^u8 n )
   {: f:^ fu:n n:^ nu:n m:^ mu:n :}
   SB-RESET
   s" ---- MODULE " SB-APPEND m mu SB-APPEND s" Table ----" SB-LINE
   s" \* The lines of " SB-APPEND n nu SB-APPEND
   s" , " SB-APPEND f fu SB-APPEND s" , as <<state, input," SB-LINE
   s" \* next state>>. TEST-FORMAL:HOLDS fails unless this file is that table." SB-LINE
   s" Lines == {" SB-LINE SB$ ;

\ A line state input >next as a tuple after the text at h; a PICK
\ line has no fixed next state, which the check cannot hold.
: TUPLE+ ( ^u8 n ^u8 n ^u8 n ^str ^ARENA:arena -- )
   {: s:^ su:n i:^ iu:n x:^ xu:n h ar :}
   x c@ 62 = TTRUE
   SB-RESET h @ str> nip 0 > if S\" ,\n" SB-APPEND then
   S\"     <<\q" SB-APPEND s su SB-APPEND
   S\" \q, \q" SB-APPEND i iu SB-APPEND
   S\" \q, \q" SB-APPEND x 1+ xu 1- SB-APPEND
   S\" \q>>" SB-APPEND h SB$ ar ADD ;

\ The table at t as the model's Table module holds it.
: TABLE-TLA ( ^u8 n ^u8 n ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: t:^ tu:n f:^ fu:n n:^ nu:n m:^ mu:n ar :}
   ar RENDERED-NEW {: h :}
   t tu [: h ar TUPLE+ ;] FSM:LINES
   ar RENDERED-NEW {: o :}
   o f fu n nu m mu HEAD$ ar ADD  o h @ str> ar ADD
   o S\" \n}\n====\n" ar ADD  o @ str> ;

\ TLC on the model's Follows module, its files in d; its output on a failure.
: FOLLOWS-RUN ( CMD:command str ^u8 n -- CMD:command )
   {: d:str m:^ mu:n :}
   s" tlc" CMD:ARG+ s" -workers" CMD:ARG+ s" 1" CMD:ARG+
   s" -metadir" CMD:ARG+
   SB-RESET d str> SB-APPEND s" /tlc" SB-APPEND SB$ CMD:ARG+
   s" -config" CMD:ARG+
   SB-RESET m mu SB-APPEND s" Follows.cfg" SB-APPEND SB$ CMD:ARG+
   SB-RESET m mu SB-APPEND s" Follows.tla" SB-APPEND SB$ CMD:ARG+
   s" formal" CMD:CWD!  s" TMPDIR" d str> CMD:ENV+
   s" /usr/bin/env" 120000 >MS CMD:RUN-RC
   MATCH result ok OF ENDOF err OF ENDOF ;MATCH {: rc:n :}
   rc 0<> if CMD:OUT$ type then
   rc 0 T= ;

public

\ The model's copy of the source file's table is its lines; TLC finds the
\ model follows them, run in a temp dir made under TMPDIR and removed.
: HOLDS ( ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: f:^ fu:n n:^ nu:n m:^ mu:n ar :}
   f fu ar FILE$ n nu TABLE-AT {: t:^ tu:n :}
   tu 0 > TTRUE  tu 0= if exit then
   SB-RESET s" formal/" SB-APPEND m mu SB-APPEND s" Table.tla" SB-APPEND
   SB$ ar FILE$
   t tu f fu n nu m mu ar TABLE-TLA T$=
   ar RENDERED-NEW {: c :}
   c s" test-formal" FS:MKTEMP-DIR ar ADD  c @ {: d:str :}
   [: d m mu FOLLOWS-RUN ;] CMD:WITH-COMMAND
   d str> FS:REMOVE-TREE ;

;package
