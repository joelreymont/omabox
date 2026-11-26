\ planner.f - package PLANNER: the next safe step for one path, from the
\ last state both sides agreed on there and what each side holds now.
\ An unknown observation blocks the path; a file where the other side
\ holds a directory is a collision; two directories agree. The rest is
\ the baseline by the two observations, whose file arms compare
\ contents: a side whose content still equals the baseline's changed
\ nothing, and the other side's change carries over.
\ PLAN matches the baseline, then the local observation, then the remote
\ one, every variant in its own arm, so the checker proves that every
\ case is decided.
\ STORAGE CLASS. CALLER-OWNED: a decision borrows the strings of the
\ values it was planned from.

require src/dropbox.f
require src/model.f

package PLANNER
private

: LOCAL-CONTENT ( MODEL:local -- DROPBOX:hash ) MODEL-LOCAL:UNMAKE ;

: REMOTE-CONTENT ( MODEL:remote -- DROPBOX:hash )
   MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :} c ;

: REMOTE-REV ( MODEL:remote -- DROPBOX:rev )
   MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :} r ;

: BLOCKED ( -- MODEL:decision )
   MODEL-BLOCKED--REASON:UNKNOWN MODEL-DECISION:BLOCKED ;

: BOTH-ABSENT ( -- MODEL:decision )
   MODEL-BASELINE:ABSENT MODEL-DECISION:NOOP ;

: DIRECTORIES ( -- MODEL:decision )
   MODEL-BASELINE:DIRECTORY MODEL-DECISION:NOOP ;

\ Both sides hold this file now.
: AGREED ( MODEL:remote -- MODEL:decision )
   MODEL-BASELINE:PRESENT MODEL-DECISION:NOOP ;

: LOCAL-FILE ( MODEL:local -- MODEL:decision )
   MODEL-COLLISION:LOCAL-FILE MODEL-DECISION:COLLIDED ;

: LOCAL-DIRECTORY ( MODEL:remote -- MODEL:decision )
   MODEL-COLLISION:LOCAL-DIR MODEL-DECISION:COLLIDED ;

: CREATE-REMOTE ( MODEL:local -- MODEL:decision )
   LOCAL-CONTENT MODEL-OPERATION:CREATE-REMOTE
   MODEL-DECISION:OPERATE ;

: INSTALL ( MODEL:remote -- MODEL:decision )
   MODEL-OPERATION:INSTALL-LOCAL MODEL-DECISION:OPERATE ;

\ Both sides hold a file and the baseline none: equal contents agree,
\ and neither side's file may replace the other's.
: FIRST-FILES ( MODEL:local MODEL:remote -- MODEL:decision )
   {: l r :}
   l LOCAL-CONTENT r REMOTE-CONTENT DROPBOX:HASH=
   if r AGREED exit then
   l r MODEL-CONFLICT:INITIAL MODEL-DECISION:CONFLICTED ;

\ A local file where the baseline holds none, absent or a directory.
: NEW-FILE
   ( MODEL:local MODEL:observation<MODEL:remote> -- MODEL:decision )
   {: l r :}
   r MATCH MODEL:observation
      present OF l swap FIRST-FILES ENDOF
      directory OF l LOCAL-FILE ENDOF
      absent OF l CREATE-REMOTE ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ A local directory where the baseline holds none, absent or a file.
: NEW-DIRECTORY ( MODEL:observation<MODEL:remote> -- MODEL:decision )
   MATCH MODEL:observation
      present OF LOCAL-DIRECTORY ENDOF
      directory OF DIRECTORIES ENDOF
      absent OF MODEL-OPERATION:CREATE-REMOTE-DIRECTORY
         MODEL-DECISION:OPERATE ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's directory, still local.
: KEPT-DIRECTORY ( MODEL:observation<MODEL:remote> -- MODEL:decision )
   MATCH MODEL:observation
      present OF LOCAL-DIRECTORY ENDOF
      directory OF DIRECTORIES ENDOF
      absent OF MODEL-OPERATION:DELETE-LOCAL-DIRECTORY
         MODEL-DECISION:OPERATE ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ Dropbox deletes a folder with everything beneath it, so only an empty
\ one follows a local deletion.
: DELETE-FOLDER ( MODEL:subtree -- MODEL:decision )
   MATCH MODEL:subtree
      empty OF MODEL-OPERATION:DELETE-REMOTE-DIRECTORY
         MODEL-DECISION:OPERATE ENDOF
      occupied OF MODEL-BLOCKED--REASON:OCCUPIED
         MODEL-DECISION:BLOCKED ENDOF
   ;MATCH ;

\ The baseline's directory, deleted locally.
: GONE-DIRECTORY
   ( MODEL:observation<MODEL:remote> MODEL:subtree -- MODEL:decision )
   {: r s :}
   r MATCH MODEL:observation
      present OF INSTALL ENDOF
      directory OF s DELETE-FOLDER ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline and the local side both absent.
: STILL-ABSENT ( MODEL:observation<MODEL:remote> -- MODEL:decision )
   MATCH MODEL:observation
      present OF INSTALL ENDOF
      directory OF MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
         MODEL-DECISION:OPERATE ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's file (first) and both sides' now: equal contents
\ agree, and else the side that kept the baseline's content takes the
\ other's, conditional on what it holds.
: EDITED
   ( MODEL:remote MODEL:local MODEL:remote -- MODEL:decision )
   {: b l f :}
   l LOCAL-CONTENT {: lc:DROPBOX:hash :}
   f REMOTE-CONTENT {: fc:DROPBOX:hash :}
   b REMOTE-CONTENT {: bc:DROPBOX:hash :}
   lc fc DROPBOX:HASH= if f AGREED exit then
   lc bc DROPBOX:HASH= 0= fc bc DROPBOX:HASH= and if
      lc f REMOTE-REV MODEL-OPERATION:REPLACE-REMOTE
      MODEL-DECISION:OPERATE exit
   then
   lc bc DROPBOX:HASH= fc bc DROPBOX:HASH= 0= and if
      f lc MODEL-OPERATION:REPLACE-LOCAL MODEL-DECISION:OPERATE exit
   then
   l f MODEL-CONFLICT:DIVERGENT MODEL-DECISION:CONFLICTED ;

\ Dropbox deleted the baseline's file (first): the local copy follows
\ only when it kept the baseline's content.
: REMOTE-DELETED ( MODEL:remote MODEL:local -- MODEL:decision )
   {: b l :}
   l LOCAL-CONTENT {: lc:DROPBOX:hash :}
   lc b REMOTE-CONTENT DROPBOX:HASH= if
      lc MODEL-OPERATION:DELETE-LOCAL MODEL-DECISION:OPERATE exit
   then
   l MODEL-CONFLICT:REMOTE-DELETED MODEL-DECISION:CONFLICTED ;

\ The baseline's file (first) deleted locally: Dropbox's follows only
\ when it kept the baseline's content.
: LOCAL-DELETED ( MODEL:remote MODEL:remote -- MODEL:decision )
   {: b f :}
   f REMOTE-CONTENT b REMOTE-CONTENT DROPBOX:HASH= if
      f REMOTE-REV MODEL-OPERATION:DELETE-REMOTE
      MODEL-DECISION:OPERATE exit
   then
   f MODEL-CONFLICT:LOCAL-DELETED MODEL-DECISION:CONFLICTED ;

\ The baseline's file (first) and the local one.
: KEPT-FILE
   ( MODEL:remote MODEL:local MODEL:observation<MODEL:remote>
   -- MODEL:decision )
   {: b l r :}
   r MATCH MODEL:observation
      present OF {: f :} b l f EDITED ENDOF
      directory OF l LOCAL-FILE ENDOF
      absent OF b l REMOTE-DELETED ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's file (first), deleted locally.
: GONE-FILE
   ( MODEL:remote MODEL:observation<MODEL:remote> -- MODEL:decision )
   {: b r :}
   r MATCH MODEL:observation
      present OF {: f :} b f LOCAL-DELETED ENDOF
      directory OF MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
         MODEL-DECISION:OPERATE ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-ABSENT
   ( MODEL:observation<MODEL:local> MODEL:observation<MODEL:remote>
   -- MODEL:decision )
   {: l r :}
   l MATCH MODEL:observation
      present OF r NEW-FILE ENDOF
      directory OF r NEW-DIRECTORY ENDOF
      absent OF r STILL-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-DIRECTORY
   ( MODEL:observation<MODEL:local> MODEL:observation<MODEL:remote>
   MODEL:subtree -- MODEL:decision )
   {: l r s :}
   l MATCH MODEL:observation
      present OF r NEW-FILE ENDOF
      directory OF r KEPT-DIRECTORY ENDOF
      absent OF r s GONE-DIRECTORY ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-FILE
   ( MODEL:remote MODEL:observation<MODEL:local>
   MODEL:observation<MODEL:remote>
   -- MODEL:decision )
   {: b l r :}
   l MATCH MODEL:observation
      present OF {: f :} b f r KEPT-FILE ENDOF
      directory OF r NEW-DIRECTORY ENDOF
      absent OF b r GONE-FILE ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

public

\ The decision for one path. An unknown observation is never read as
\ absence, so it can never produce a deletion. SUBTREE is what the same
\ inventory holds beneath the path; it decides only whether a locally
\ deleted directory may be deleted on Dropbox.
: PLAN
   ( MODEL:baseline MODEL:observation<MODEL:local>
   MODEL:observation<MODEL:remote> MODEL:subtree
   -- MODEL:decision )
   {: b l r s :}
   b MATCH MODEL:baseline
      absent OF l r FROM-ABSENT ENDOF
      present OF l r FROM-FILE ENDOF
      directory OF l r s FROM-DIRECTORY ENDOF
   ;MATCH ;

;package
