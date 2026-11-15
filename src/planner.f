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

using MODEL
package PLANNER
private

: LOCAL-CONTENT ( local -- DROPBOX:hash ) MODEL-LOCAL:UNMAKE ;

: REMOTE-CONTENT ( remote -- DROPBOX:hash )
   MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :} c ;

: REMOTE-REV ( remote -- DROPBOX:rev )
   MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :} r ;

: BLOCKED ( -- decision )
   MODEL-BLOCKED--REASON:unknown MODEL-DECISION:blocked ;

: BOTH-ABSENT ( -- decision )
   MODEL-BASELINE:absent MODEL-DECISION:noop ;

: DIRECTORIES ( -- decision )
   MODEL-BASELINE:directory MODEL-DECISION:noop ;

\ Both sides hold this file now.
: AGREED ( remote -- decision )
   MODEL-BASELINE:present MODEL-DECISION:noop ;

: LOCAL-FILE ( local -- decision )
   MODEL-COLLISION:local-file MODEL-DECISION:collided ;

: LOCAL-DIRECTORY ( remote -- decision )
   MODEL-COLLISION:local-dir MODEL-DECISION:collided ;

: CREATE-REMOTE ( local -- decision )
   LOCAL-CONTENT MODEL-OPERATION:create-remote
   MODEL-DECISION:operate ;

: INSTALL ( remote -- decision )
   MODEL-OPERATION:install-local MODEL-DECISION:operate ;

\ Both sides hold a file and the baseline none: equal contents agree,
\ and neither side's file may replace the other's.
: FIRST-FILES ( local remote -- decision )
   {: l r :}
   l LOCAL-CONTENT r REMOTE-CONTENT DROPBOX:HASH=
   if r AGREED exit then
   l r MODEL-CONFLICT:initial MODEL-DECISION:conflicted ;

\ A local file where the baseline holds none, absent or a directory.
: NEW-FILE ( local observation<remote> -- decision )
   {: l r :}
   r MATCH observation
      present OF l swap FIRST-FILES ENDOF
      directory OF l LOCAL-FILE ENDOF
      absent OF l CREATE-REMOTE ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ A local directory where the baseline holds none, absent or a file.
: NEW-DIRECTORY ( observation<remote> -- decision )
   MATCH observation
      present OF LOCAL-DIRECTORY ENDOF
      directory OF DIRECTORIES ENDOF
      absent OF MODEL-OPERATION:create-remote-directory
         MODEL-DECISION:operate ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's directory, still local.
: KEPT-DIRECTORY ( observation<remote> -- decision )
   MATCH observation
      present OF LOCAL-DIRECTORY ENDOF
      directory OF DIRECTORIES ENDOF
      absent OF MODEL-OPERATION:delete-local-directory
         MODEL-DECISION:operate ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ Dropbox deletes a folder with everything beneath it, so only an empty
\ one follows a local deletion.
: DELETE-FOLDER ( subtree -- decision )
   MATCH subtree
      empty OF MODEL-OPERATION:delete-remote-directory
         MODEL-DECISION:operate ENDOF
      occupied OF MODEL-BLOCKED--REASON:occupied
         MODEL-DECISION:blocked ENDOF
   ;MATCH ;

\ The baseline's directory, deleted locally.
: GONE-DIRECTORY ( observation<remote> subtree -- decision )
   {: r s :}
   r MATCH observation
      present OF INSTALL ENDOF
      directory OF s DELETE-FOLDER ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline and the local side both absent.
: STILL-ABSENT ( observation<remote> -- decision )
   MATCH observation
      present OF INSTALL ENDOF
      directory OF MODEL-OPERATION:create-local-directory
         MODEL-DECISION:operate ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's file (first) and both sides' now: equal contents
\ agree, and else the side that kept the baseline's content takes the
\ other's, conditional on what it holds.
: EDITED ( remote local remote -- decision )
   {: b l f :}
   l LOCAL-CONTENT {: lc:DROPBOX:hash :}
   f REMOTE-CONTENT {: fc:DROPBOX:hash :}
   b REMOTE-CONTENT {: bc:DROPBOX:hash :}
   lc fc DROPBOX:HASH= if f AGREED exit then
   lc bc DROPBOX:HASH= 0= fc bc DROPBOX:HASH= and if
      lc f REMOTE-REV MODEL-OPERATION:replace-remote
      MODEL-DECISION:operate exit
   then
   lc bc DROPBOX:HASH= fc bc DROPBOX:HASH= 0= and if
      f lc MODEL-OPERATION:replace-local MODEL-DECISION:operate exit
   then
   l f MODEL-CONFLICT:divergent MODEL-DECISION:conflicted ;

\ Dropbox deleted the baseline's file (first): the local copy follows
\ only when it kept the baseline's content.
: REMOTE-DELETED ( remote local -- decision )
   {: b l :}
   l LOCAL-CONTENT {: lc:DROPBOX:hash :}
   lc b REMOTE-CONTENT DROPBOX:HASH= if
      lc MODEL-OPERATION:delete-local MODEL-DECISION:operate exit
   then
   l MODEL-CONFLICT:remote-deleted MODEL-DECISION:conflicted ;

\ The baseline's file (first) deleted locally: Dropbox's follows only
\ when it kept the baseline's content.
: LOCAL-DELETED ( remote remote -- decision )
   {: b f :}
   f REMOTE-CONTENT b REMOTE-CONTENT DROPBOX:HASH= if
      f REMOTE-REV MODEL-OPERATION:delete-remote
      MODEL-DECISION:operate exit
   then
   f MODEL-CONFLICT:local-deleted MODEL-DECISION:conflicted ;

\ The baseline's file (first) and the local one.
: KEPT-FILE ( remote local observation<remote> -- decision )
   {: b l r :}
   r MATCH observation
      present OF {: f :} b l f EDITED ENDOF
      directory OF l LOCAL-FILE ENDOF
      absent OF b l REMOTE-DELETED ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

\ The baseline's file (first), deleted locally.
: GONE-FILE ( remote observation<remote> -- decision )
   {: b r :}
   r MATCH observation
      present OF {: f :} b f LOCAL-DELETED ENDOF
      directory OF MODEL-OPERATION:create-local-directory
         MODEL-DECISION:operate ENDOF
      absent OF BOTH-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-ABSENT ( observation<local> observation<remote>
   -- decision )
   {: l r :}
   l MATCH observation
      present OF r NEW-FILE ENDOF
      directory OF r NEW-DIRECTORY ENDOF
      absent OF r STILL-ABSENT ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-DIRECTORY ( observation<local> observation<remote>
   subtree -- decision )
   {: l r s :}
   l MATCH observation
      present OF r NEW-FILE ENDOF
      directory OF r KEPT-DIRECTORY ENDOF
      absent OF r s GONE-DIRECTORY ENDOF
      unknown OF drop BLOCKED ENDOF
   ;MATCH ;

: FROM-FILE ( remote observation<local> observation<remote>
   -- decision )
   {: b l r :}
   l MATCH observation
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
: PLAN ( baseline observation<local> observation<remote> subtree
   -- decision )
   {: b l r s :}
   b MATCH baseline
      absent OF l r FROM-ABSENT ENDOF
      present OF l r FROM-FILE ENDOF
      directory OF l r s FROM-DIRECTORY ENDOF
   ;MATCH ;

;package
;using
