\ replay-test.f - REPLAY's journal steps on a journal under TMPDIR:
\ RETIRE-EXCLUDED-PLANS, given two pending plans, one at an excluded
\ name, supersedes that one and leaves the other, in the vector and in
\ the journal's pending plans. MATERIALIZE-LOCAL-CONFLICT, given a
\ staged upload in a fresh sync root, answers blocked
\ conflict-copy-occupied for a directory or an unreadable file at the
\ copy's name and ready beside a directory elsewhere, and passes up
\ LOCAL's E-IO when the copy's parent denies writes. Each case removes
\ its directory.
\ Run from the repository root: hb --load src/replay-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/vector.f
require src/model.f
require src/journal.f
require src/local.f
require src/replay.f

package REPLAY-TEST
private


\ ---- a case's directory ------------------------------------------

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d:str a:^ u ar :}
   d str> {: p:^ pu :}
   ar pu u + 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst pu BYTE-COPY
   47 dst pu + c!
   a dst pu + 1+ u BYTE-COPY
   dst pu u + 1+ >str ;

\ A case's directory and the journal path in it.
: JOURNAL-AT ( ^ARENA:arena -- str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d d s" journal.sqlite3" ar INSIDE ;

: GONE ( str -- ) str> FS:REMOVE-TREE ;


\ ---- plans ---------------------------------------------------------

: DISPLAY ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: o ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: RECORDED? ( JOURNAL:plan-write -- bool )
   MATCH JOURNAL:plan-write
      recorded OF drop true ENDOF
      already-live OF drop false ENDOF
   ;MATCH ;

\ A pending plan creating the local directory at path.
: RECORD ( JOURNAL:journal ^u8 n ^ARENA:arena -- )
   {: j a:^ u ar :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY ar ONE-PLAN {: plan :}
   j a u DISPLAY plan ar JOURNAL:RECORD-PLAN RECORDED? TTRUE ;

: PATH-OF ( ^VEC:vector<JOURNAL:plan-record> n -- ^u8 n )
   VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   p MODEL:PATH>STR str> ;

\ The vector holds one plan, at path.
: ONLY-AT ( ^VEC:vector<JOURNAL:plan-record> ^u8 n -- )
   {: plans a:^ u :}
   plans VEC:COUNT 1 T=
   plans 0 PATH-OF a u STR= TTRUE ;


\ ---- cases ---------------------------------------------------------

: RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ( ^ARENA:arena -- )
   {: ar :}
   s" retire excluded plans supersedes only excluded plans" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   j s" folder/.DS_Store" ar RECORD
   j s" folder/notes.md" ar RECORD
   j ar JOURNAL:PENDING-PLANS {: plans :}
   plans VEC:COUNT 2 T=
   j plans ar REPLAY:RETIRE-EXCLUDED-PLANS
   plans s" folder/notes.md" ONLY-AT
   j ar JOURNAL:PENDING-PLANS s" folder/notes.md" ONLY-AT
   j JOURNAL:CLOSE
   d GONE ;


\ ---- local conflict copies -----------------------------------------

\ 0500: its owner reads and searches it, but writes nothing in it.
$140 constant MODE-NO-WRITE

\ A case's directory, and the sync root and upload staging made in it.
: CONFLICT-DIRS ( ^ARENA:arena -- str str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d s" root" ar INSIDE {: r:str :}
   d s" staging" ar INSIDE {: s:str :}
   r str> FS:MAKE-DIR s str> FS:MAKE-DIR
   d r s ;

: UPLOAD-OF
   ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- ^LOCAL:staged-upload )
   MATCH LOCAL:stage-outcome
      staged OF ENDOF
      already-staged OF ENDOF
      content-changed OF drop LOCAL:E-CHANGED throw ENDOF
      destination-occupied OF drop LOCAL:E-OCCUPIED throw ENDOF
   ;MATCH ;

\ The file at p below the root, written and staged as an upload.
: STAGED
   ( str str ^u8 n ^ARENA:arena -- ^LOCAL:staged-upload )
   {: r:str s:str p:^ u:n ar :}
   r p u ar INSIDE str> s" local edit" FS:WRITE-ALL
   r str> p u ar LOCAL:OBSERVE-UPLOAD-SOURCE {: c:DROPBOX:hash :}
   r str> p u s str> c ar LOCAL:STAGE-UPLOAD UPLOAD-OF ;

\ The absolute path of p's local conflict copy holding the upload.
: COPY-NAME
   ( str ^u8 n ^LOCAL:staged-upload ^ARENA:arena -- str )
   {: r:str p:^ u:n up ar :}
   p u LOCAL-CONFLICT--SIDE:LOCAL up LOCAL:UPLOAD-CONTENT ar
   LOCAL:CONFLICT-RELATIVE-PATH {: c:^ cu:n :}
   r c cu ar INSIDE ;

: REASON$ ( MODEL:blockage -- ^u8 n )
   MATCH MODEL:blockage
      unsupported-file-size OF s" other" ENDOF
      remote-rejected OF drop s" other" ENDOF
      download-unavailable OF drop s" other" ENDOF
      download-verification-failed OF s" other" ENDOF
      stage-occupied OF s" other" ENDOF
      local-object-in-way OF s" other" ENDOF
      remote-object OF s" other" ENDOF
      conflict-copy-occupied OF s" conflict-copy-occupied" ENDOF
   ;MATCH ;

\ The outcome's variant, and a blocked one's reason, else empty.
: COPY$ ( REPLAY:copy-outcome -- ^u8 n ^u8 n )
   MATCH REPLAY:copy-outcome
      ready OF s" ready" s" " ENDOF
      blocked OF {: b:MODEL:blockage :} s" blocked" b REASON$ ENDOF
      source-changed OF s" source-changed" s" " ENDOF
   ;MATCH ;

\ The local conflict copy of p, written below the root r.
: LOCAL-COPY$
   ( str ^u8 n ^LOCAL:staged-upload ^ARENA:arena -- ^u8 n ^u8 n )
   {: r:str p:^ u:n up ar :}
   r str> p u DISPLAY up ar REPLAY:MATERIALIZE-LOCAL-CONFLICT COPY$ ;

: BLOCKED-OCCUPIED ( ^u8 n ^u8 n -- )
   s" conflict-copy-occupied" T$= s" blocked" T$= ;

\ An unreadable file at the copy's name blocks the copy.
: UNREADABLE-COPY ( str ^LOCAL:staged-upload str ^ARENA:arena -- )
   {: r:str up c:str ar :}
   c str> s" other bytes" FS:WRITE-ALL
   c str> 0 FS:CHMOD-MODE
   [: r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED ;]
   [: c str> FS:MODE-PRIVATE-FILE FS:CHMOD-MODE ;] finally
   c str> FS:REMOVE-FILE ;

: ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT ( ^ARENA:arena -- )
   {: ar :}
   s" only_an_object_at_the_copy_name_occupies_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   r s" notes.txt" up ar COPY-NAME {: c:str :}
   c str> FS:MAKE-DIR
   r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED
   c str> FS:REMOVE-DIR
   r up c ar UNREADABLE-COPY
   r s" notes.d" ar INSIDE str> FS:MAKE-DIR
   r s" notes.txt" up ar LOCAL-COPY$ s" " T$= s" ready" T$=
   d GONE ;

\ The copy below dir, which denies writes; LOCAL's E-IO passes up.
: DENIED-COPY ( str ^LOCAL:staged-upload ^ARENA:arena -- )
   {: r:str up ar :}
   [: r str> s" dir/notes.txt" DISPLAY up ar
      REPLAY:MATERIALIZE-LOCAL-CONFLICT drop ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:EACCES T= ;

: A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_denied_operation_at_the_copy_name_does_not_occupy_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" dir" ar INSIDE {: dir:str :}
   dir str> FS:MAKE-DIR
   r s s" dir/notes.txt" ar STAGED {: up :}
   dir str> MODE-NO-WRITE FS:CHMOD-MODE
   [: r up ar DENIED-COPY ;]
   [: dir str> FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally
   d GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ar ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT
   ar A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
