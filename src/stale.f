\ stale.f - package STALE: removal of the temporaries a killed or failed
\ Omabox process left behind, as the Rust version's stale.rs removes them.
\ SWEEP removes each entry of a directory named exactly
\ {prefix}{pid}.{seq}{suffix}, both numbers canonical decimals (no sign,
\ no leading zero but a lone 0), the PID a positive i32 and the sequence a
\ u64, whose process is gone: kill(pid, 0) fails ESRCH. A live PID keeps
\ its entry whatever process now owns it, and EPERM or any other answer
\ counts as live. A matching symlink is unlinked, never followed; a
\ matching directory is removed whole, no symlink inside it followed. A
\ missing directory holds nothing to sweep, and an entry gone before its
\ removal counts as removed. SWEEP never throws for the file system: it
\ goes on past each directory or entry it cannot read or remove and
\ answers one leftover for each, which the next sweep tries again.
\ Linux only: an entry is inspected and unlinked through the directory's
\ descriptor, and a directory removed whole through its path.
\ STORAGE CLASS. CALLER-OWNED: the leftovers and their paths are laid in
\ the arena the caller passes; the listing and the names it matched live
\ in an arena of SWEEP's own, released on return.

require src/lib/string.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/vector.f
require src/lib/adt/option.f
require src/lib/fmt.f
require src/lib/fd.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/process.f

package STALE
private

ENUM operation read-directory remove-temporary ;ENUM

public

\ A directory the sweep could not read, or a stale temporary it could not
\ inspect or remove, with the host errno that stopped it.
STRUCTURE leftover OPAQUE DERIVE addr
   FIELD path str
   FIELD operation operation
   FIELD errno n
;STRUCTURE

private

\ ---- a name's owner

: DIGIT? ( n -- bool )
   {: b:n :}
   b [char] 0 >= b [char] 9 <= and ;

\ Not empty, digits only, and no leading zero but a lone 0.
: CANONICAL? ( ^u8 n -- bool )
   {: a:^ u:n :}
   u 0= if false exit then
   u 1 > a c@ [char] 0 = and if false exit then
   u 0 ?do a i + c@ DIGIT? 0= if false unloop exit then loop
   true ;

: DECIMAL ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do 10 * a i + c@ [char] 0 - + loop ;

\ A canonical sequence that fits a u64.
: SEQUENCE? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u CANONICAL? 0= if false exit then
   u 20 < if true exit then
   u 20 > if false exit then
   s" 18446744073709551615" a u STR< 0= ;

\ A canonical PID: a positive i32.
: PID ( ^u8 n -- option<n> )
   {: a:^ u:n :}
   a u CANONICAL? 0= u 10 > or if OPTION:NONE exit then
   a u DECIMAL {: v:n :}
   v 0= v $7FFFFFFF > or if OPTION:NONE exit then
   v OPTION:SOME ;

\ The index of the token's only dot, else -1.
: DOT ( ^u8 n -- n )
   {: a:^ u:n :}
   -1 u 0 ?do
      a i + c@ [char] . = if
         dup 0 >= if drop -1 unloop exit then
         drop i
      then
   loop ;

\ The PID in a token of the form {pid}.{seq}.
: TOKEN-OWNER ( ^u8 n -- option<n> )
   {: a:^ u:n :}
   a u DOT {: d:n :}
   d 0 < if OPTION:NONE exit then
   a d + 1 + u d - 1 - SEQUENCE? 0= if OPTION:NONE exit then
   a d PID ;

\ The PID in a name of the form {prefix}{pid}.{seq}{suffix}.
: OWNER ( ^u8 n ^u8 n ^u8 n -- option<n> )
   {: a:^ u:n p:^ pu:n s:^ su:n :}
   u pu su + < if OPTION:NONE exit then
   a pu p pu STR= 0= if OPTION:NONE exit then
   a u + su - su s su STR= 0= if OPTION:NONE exit then
   a pu + u pu - su - TOKEN-OWNER ;

: DEAD? ( n -- bool )
   0 kill-errno PROCESS:ESRCH# negate = ;


\ ---- leftovers

: LEFTOVER! ( ^VEC:vector<leftover> str operation n -- )
   {: v p op e:n :}
   v VEC:PUSH {: l :}
   p l LEFTOVER-PATH !
   op l LEFTOVER-OPERATION !
   e l LEFTOVER-ERRNO ! ;

: COPY ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u:n ar :}
   ar u ARENA:ALLOC drop {: d:^ :}
   a d u BYTE-COPY
   d u >str ;

\ directory/name laid in the arena, as Rust's Path::join lays it.
: JOINED ( str ^u8 n ^ARENA:arena -- str )
   {: dir name:^ nu:n ar :}
   dir str> nip nu + 1 + {: cap:n :}
   ar cap ARENA:ALLOC drop {: d:^ :}
   dir str> name nu d cap SPAN:MAKE FS:JOIN-PATH-INTO {: u:n :}
   d u >str ;

: GONE? ( -- bool ) FS:ERRNO FS:ENOENT = ;


\ ---- removal

\ A directory removed whole; false leaves the cause in FS:ERRNO.
: TREE-REMOVED? ( str -- bool )
   {: p :}
   [: p str> FS:REMOVE-TREE ;] catch {: code:n :}
   code 0= if true exit then
   GONE? ;

\ The entry removed, or gone already; false leaves the cause in FS:ERRNO.
: REMOVED? ( fd ^u8 n str -- bool )
   {: dir:fd name:^ nu:n p :}
   dir name nu FS:TRY-STAT-AT 0= if GONE? exit then
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFDIR = if p TREE-REMOVED? exit then
   dir name nu FS:TRY-REMOVE-FILE-AT if true exit then
   GONE? ;

\ A matched name whose owner is gone, removed.
: SETTLE ( fd str str ^VEC:vector<leftover> ^ARENA:arena -- )
   {: dir:fd directory name v ar :}
   name str> {: n:^ nu:n :}
   directory n nu ar JOINED {: p :}
   dir n nu p REMOVED? 0= if
      v p OPERATION-REMOVE-TEMPORARY FS:ERRNO LEFTOVER!
   then ;


\ ---- the listing

\ The name kept in the scratch arena when a dead process owns it.
: MATCH-ONE ( ^u8 n ^u8 n ^u8 n ^VEC:vector<str> ^ARENA:arena -- )
   {: a:^ u:n p:^ pu:n s:^ su:n names scratch :}
   a u p pu s su OWNER MATCH option
      none OF ENDOF
      some OF DEAD? if a u scratch COPY names VEC:PUSH ! then ENDOF
   ;MATCH ;

\ Each name a dead process owns; the listing lives in the scratch arena.
: MATCHED ( fd ^u8 n ^u8 n ^VEC:vector<str> ^ARENA:arena -- )
   {: dir:fd p:^ pu:n s:^ su:n names scratch :}
   scratch FS-LIST:STORAGE-BYTES ARENA:ALLOC SPAN:MAKE FS-LIST:INIT
   dir [: drop p pu s su names scratch MATCH-ONE ;] FS-LIST:EACH-TYPED-AT ;

: LIST-CODE? ( n -- bool )
   {: code:n :}
   code FS-LIST:E-OPEN = code FS-LIST:E-READ = or
   code FS-LIST:E-ENTRY = or ;

\ The matched names; a failed listing is one leftover, and the names
\ listed before it still count.
: LISTED ( fd str ^u8 n ^u8 n ^VEC:vector<leftover> ^ARENA:arena
     -- ^VEC:vector<str> )
   {: dir:fd directory p:^ pu:n s:^ su:n v scratch :}
   scratch ARENA:ALLOCATOR 0 [type] str VEC:NEW {: names :}
   [: dir p pu s su names scratch MATCHED ;] catch {: code:n :}
   code 0<> if
      code LIST-CODE? 0= if code throw then
      v directory OPERATION-READ-DIRECTORY FS:ERRNO LEFTOVER!
   then
   names ;

\ The scratch arena first, as ARENA:WITH passes it.
: SWEEP-IN ( ^ARENA:arena fd str ^u8 n ^u8 n ^VEC:vector<leftover>
     ^ARENA:arena -- )
   {: scratch dir:fd directory p:^ pu:n s:^ su:n v ar :}
   dir directory p pu s su v scratch LISTED {: names :}
   names VEC:COUNT 0 ?do
      dir directory names i VEC:AT @ v ar SETTLE
   loop ;

\ The directory's descriptor, none when it cannot be opened; FS:ERRNO
\ then holds why, 0 for a path the kernel cannot take.
: OPENED ( str -- option<fd> )
   {: directory :}
   0 FS:CAUSE!
   -1 >FD [: drop directory str> FS:OPEN-DIR-FOLLOW ;] catch {: code:n :}
   code 0<> if drop OPTION:NONE exit then
   OPTION:SOME ;


\ ---- the report

: OPERATION-TEXT ( operation -- ^u8 n )
   MATCH operation
      read-directory OF s" read a directory" ENDOF
      remove-temporary OF s" remove a stale temporary" ENDOF
   ;MATCH ;

\ The error as Rust's io::Error displays an OS error.
: ERROR-OUT ( n fd -- )
   {: e:n f:fd :}
   f e FS:ERRNO$ FD:WRITE-FULL
   f s"  (os error " FD:WRITE-FULL
   f e FMT:INT$ FD:WRITE-FULL
   f s" )" FD:WRITE-FULL ;

: LINE ( ^leftover fd -- )
   {: l f:fd :}
   f s" Left a stale temporary in place: could not " FD:WRITE-FULL
   f l LEFTOVER-OPERATION @ OPERATION-TEXT FD:WRITE-FULL
   f s"  `" FD:WRITE-FULL
   f l LEFTOVER-PATH @ str> FD:WRITE-FULL
   f s" `: " FD:WRITE-FULL
   l LEFTOVER-ERRNO @ f ERROR-OUT
   f s\" \n" FD:WRITE-FULL ;

public

: PATH ( ^leftover -- str ) LEFTOVER-PATH @ ;

\ "read a directory" or "remove a stale temporary".
: OPERATION$ ( ^leftover -- ^u8 n ) LEFTOVER-OPERATION @ OPERATION-TEXT ;

: ERRNO ( ^leftover -- n ) LEFTOVER-ERRNO @ ;

\ One line on the fd for each leftover; a failed write throws FD's code,
\ where `type` would drop it.
: REPORT ( ^VEC:vector<leftover> fd -- )
   {: v f:fd :}
   v VEC:COUNT 0 ?do v i VEC:AT f LINE loop ;

\ The directory, then the prefix and the suffix of the names to sweep.
: SWEEP ( str ^u8 n ^u8 n ^ARENA:arena -- ^VEC:vector<leftover> )
   {: directory p:^ pu:n s:^ su:n ar :}
   ar ARENA:ALLOCATOR 0 [type] leftover VEC:NEW {: v :}
   directory OPENED MATCH option
      none OF
         GONE? 0= if
            v directory OPERATION-READ-DIRECTORY FS:ERRNO LEFTOVER!
         then
      ENDOF
      some OF {: dir:fd :}
         [: [: dir directory p pu s su v ar SWEEP-IN ;] ARENA:WITH ;]
         [: dir FD>N close ;] finally
      ENDOF
   ;MATCH
   v ;

;package
