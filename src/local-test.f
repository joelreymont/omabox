\ local-test.f - LOCAL's shared words and download stages: local.rs's tests
\ that an entry's existence below the root never follows a symlink and
\ takes a failed probe as unconfirmed, that the content hash composes block
\ hashes, and that neither the hash nor a stage's copy depends on how a
\ reader fragments the bytes; then each stage outcome, each inspected
\ download stage, a stage marker set, read and removed, and each parent a
\ download opens; then that a slot's state keeps its last checkpoint, a
\ reset never touches a replacement swapped in, the pool's four fixed
\ slots, a protected slot kept and a stale one rebound; then that a cut
\ download resumes from its last durable checkpoint, a completed partial
\ is promoted before or after its rename, a corrupt one restarts only in
\ its own slot, a promotion keeps a swapped replacement, a copy across
\ filesystems frees its slot, and a reset slot replays to offset 0. A case
\ that makes files works in its own directory under TMPDIR and removes it.
\ Run from the repository root: hb --load src/local-test.f </dev/null
require src/lib/test.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/property.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/xattr.f
require src/lib/adt/option.f
require src/dropbox.f
require src/model.f
require src/local.f

\ LOCAL reopened for the stream a fragmenting reader feeds, its stage
\ words, and the names of its private results' variants.
package LOCAL
private

\ The variant's name; a verified stage's descriptor is closed.
: DOWNLOAD-STAGE$ ( download-stage -- ^u8 n )
   MATCH download-stage
      missing OF s" missing" ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD s" verified"
      ENDOF
      destination-occupied OF {: p:str :} s" destination-occupied" ENDOF
   ;MATCH ;

: INSPECTED$
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   INSPECT-DOWNLOAD-STAGE DOWNLOAD-STAGE$ ;

: MARKER$ ( fd ^u8 n ^u8 n -- ^u8 n )
   READ-DOWNLOAD-MARKER MATCH download-marker
      missing OF s" missing" ENDOF
      expected OF s" expected" ENDOF
      other OF s" other" ENDOF
   ;MATCH ;

\ WRITE-VERIFIED-STAGE's result as its caller sees it, the stage 0.
: WRITE-STAGE-OUTCOME
   ( fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] option<str> ^u8 n
     ^ARENA:arena -- stage-outcome<n> )
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

\ OPEN-PARENT's answer apart: its descriptor, name, parent path and true;
\ for none, -1, empty spans and false.
: PARENT-OF ( fd ^u8 n bool -- fd ^u8 n ^u8 n bool )
   OPEN-PARENT MATCH option
      none OF -1 >FD s" " s" " false ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str path:str :}
         f name str> path str> true
      ENDOF
   ;MATCH ;

\ The lease's slot, its binding and true; for none, -1, a zero binding
\ and false.
: LEASE-OF ( option<download-slot-lease> -- n binding bool )
   MATCH option
      none OF -1 0 0 0 0 BINDING-MAKE false ENDOF
      some OF DOWNLOAD-SLOT-LEASE-UNMAKE {: d:str slot:n b:binding :}
         slot b true
      ENDOF
   ;MATCH ;

: STATE-APART ( option<download-slot-state> -- binding n bool )
   MATCH option
      none OF 0 0 0 0 BINDING-MAKE 0 false ENDOF
      some OF DOWNLOAD-SLOT-STATE-UNMAKE true ENDOF
   ;MATCH ;

\ The slot's state apart: its binding, its offset and true.
: SLOT-STATE-OF ( fd ^u8 n -- binding n bool )
   READ-DOWNLOAD-SLOT-STATE STATE-APART ;

\ The state encoded and decoded again, apart.
: STATE-ROUND-TRIP ( binding n -- binding n bool )
   DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE
   DECODE-DOWNLOAD-SLOT-STATE STATE-APART ;

32 BUFFER: FILLED

\ The binding whose 32 bytes are all c.
: FILLED-BINDING ( n -- binding )
   {: c:n :}
   32 0 ?do c FILLED i + c! loop
   FILLED BYTES>BINDING ;

\ The slot opened for writing and true; for a missing or occupied one,
\ -1 and false.
: OPENED-SLOT ( fd ^u8 n ^u8 n -- fd bool )
   OPEN-DOWNLOAD-SLOT MATCH download-slot-open
      missing OF -1 >FD false ENDOF
      file OF true ENDOF
      occupied OF -1 >FD false ENDOF
   ;MATCH ;

\ The preparation's partial; anything else ends the run, as Rust's test
\ returns an error.
: READY-PARTIAL ( download-preparation -- ^download-partial )
   MATCH download-preparation
      ready OF ENDOF
      complete OF DROP-OUTCOME
         s" test expected a ready download partial" 1 die
      ENDOF
      ephemeral OF s" test expected a ready download partial" 1 die ENDOF
   ;MATCH ;

: LEASED ( option<download-slot-lease> -- download-slot-lease )
   MATCH option
      none OF s" test expected a download slot lease" 1 die ENDOF
      some OF ENDOF
   ;MATCH ;

\ Rust's tests' raw fsetxattr of the partial's stage marker, then fsync.
: MARK-PARTIAL ( ^download-partial ^ARENA:arena -- )
   {: x ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   x PARTIAL-FILE DOWNLOAD-STAGE-XATTR
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER XATTR:ADD
   x PARTIAL-FILE FD:SYNC ;

\ Moves the partial's slot to its stage's name, as renameat NOREPLACE.
: RENAME-TO-STAGE ( ^download-partial -- bool )
   {: x :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   loc SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         slots name str> loc TARGET-DIR@ loc STAGE-NAME@
         FS:TRY-RENAME-NEW-AT
      ENDOF
      disposable OF {: p:str :} false ENDOF
   ;MATCH ;

\ Empties the partial's slot and records offset 0 for its binding.
: ZERO-CHECKPOINT ( ^download-partial -- )
   {: x :}
   x PARTIAL-FILE 0 FD:RESIZE
   x DOWNLOAD-PARTIAL-LOCATION SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         x PARTIAL-FILE DOWNLOAD-PARTIAL-XATTR
         b 0 DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE XATTR:SET
      ENDOF
      disposable OF {: p:str :} ENDOF
   ;MATCH
   x PARTIAL-FILE FD:SYNC ;

: PROMOTE-WITH
   ( ^download-partial [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: x before ar:^ARENA:arena :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION before ar
   PROMOTE-COMPLETED-SLOT-WITH ;

: COPY-PARTIAL ( ^download-partial ^ARENA:arena -- stage-outcome<n> )
   {: x ar:^ARENA:arena :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION ar COPY-COMPLETED-SLOT ;

: PARTIAL-STAGE-PATH ( ^download-partial -- ^u8 n )
   DOWNLOAD-PARTIAL-LOCATION STAGE-PATH@ ;

public
EXPORT READY-PARTIAL
EXPORT LEASED
EXPORT MARK-PARTIAL
EXPORT RENAME-TO-STAGE
EXPORT ZERO-CHECKPOINT
EXPORT PROMOTE-WITH
EXPORT COPY-PARTIAL
EXPORT PARTIAL-STAGE-PATH
EXPORT CLOSE-PARTIAL
EXPORT PARTIAL-FILE
EXPORT PARTIAL-PATH
EXPORT DOWNLOAD-PARTIAL-XATTR
EXPORT DOWNLOAD-CHECKPOINT-BYTES
EXPORT DOWNLOAD-SLOT-NAME
EXPORT RESET-DOWNLOAD-SLOT-FILE-WITH
EXPORT TAKEN?
EXPORT LEASE-OF
EXPORT SLOT-STATE-OF
EXPORT STATE-ROUND-TRIP
EXPORT FILLED-BINDING
EXPORT OPENED-SLOT
EXPORT PARENT-OF
EXPORT HASH-STREAM
EXPORT COPY-AND-HASH
EXPORT DOWNLOAD-STAGE-XATTR
EXPORT STAGE-MARKER
EXPORT SET-XATTR
EXPORT REMOVE-XATTR
EXPORT MARKER$
EXPORT INSPECTED$
EXPORT WRITE-STAGE-OUTCOME
;package

package LOCAL-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

$400000 constant BLOCK
448 constant MODE-0700

\ ---- entry existence

FS:PATHZ-CAP BUFFER: ROOT-BUF
variable ROOT-U
FS:PATHZ-CAP BUFFER: JOINED

: ROOT$ ( -- ^u8 n ) ROOT-BUF ROOT-U @ ;

\ The name below the case's directory, valid until the next AT.
: AT ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u JOINED FS:JOIN-PATH JOINED swap ;

: CASE-DIR ( -- )
   s" local-test" FS:MKTEMP-DIR {: p:^ u:n :}
   p ROOT-BUF u BYTE-COPY u ROOT-U ! ;

\ Runs q on the case directory's fd, then removes the directory.
: IN-CASE-DIR ( [ fd -- ] -- )
   {: q :}
   CASE-DIR ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root q execute ;]
   [: root FS:CLOSE-DIR ROOT$ FS:REMOVE-TREE ;] finally ;

: ENTRY-TREE ( -- )
   s" dir" AT FS:MAKE-DIR
   s" dir/file.txt" AT s" bytes" FS:WRITE-ALL
   s" file.txt" AT s" bytes" FS:WRITE-ALL
   s" missing" s" dangling" AT FS:MAKE-SYMLINK
   s" dir" s" linked" AT FS:MAKE-SYMLINK
   s" denied" AT FS:MAKE-DIR ;

: EXISTS ( fd ^u8 n bool -- )
   {: root:fd p:^ u:n want:bool :}
   p u T-LABEL
   root p u LOCAL:ENTRY-EXISTS-AT want if TTRUE else TFALSE then ;

: ENTRY-CHECKS ( fd -- )
   {: root:fd :}
   root s" dir" true EXISTS
   root s" dir/file.txt" true EXISTS
   root s" dangling" true EXISTS
   root s" linked" true EXISTS
   root s" missing.txt" false EXISTS
   root s" missing/file.txt" false EXISTS
   root s" file.txt/child" false EXISTS
   root s" linked/file.txt" false EXISTS ;

\ Rust's deny_all_access, then allow_owner_access whatever the probe did.
: DENIED ( fd -- )
   {: root:fd :}
   s" denied" AT 0 FS:CHMOD-MODE
   [: root s" denied/file.txt" false EXISTS ;]
   [: s" denied" AT MODE-0700 FS:CHMOD-MODE ;] finally ;

: ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   ( -- )
   CASE-DIR ENTRY-TREE
   ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root ENTRY-CHECKS root DENIED ;]
   [: root FS:CLOSE-DIR ROOT$ FS:REMOVE-TREE ;] finally ;

\ ---- content hashes

\ Rust's identity: the content hash of the bytes, read from a pipe.
: IDENTITY ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   FD:PIPE {: r:fd w:fd :}
   w p u FD:WRITE-FULL w FS:CLOSE-DIR
   r AR @ LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR
   DROPBOX:HASH>STR str> ;

: DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION ( -- )
   s" dropbox_hash_uses_block_hash_composition" T-LABEL
   s" " IDENTITY
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   s" abc" IDENTITY
   s" 4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358" T$= ;

\ The bytes a FRAGMENT reader answers from, and the schedule of the most
\ each of its reads gives, taken in turn.
PTR-VARIABLE SOURCE
variable SOURCE-U
variable POSITION
variable NEXT-FRAGMENT
12 constant FRAGMENT-CAP
FRAGMENT-CAP TYPED-BUFFER FRAGMENTS n
variable FRAGMENT-COUNT

: SOURCE@ ( -- ^u8 ) SOURCE @ ;

: START ( ^u8 n -- )
   {: p:^ u:n :}
   p SOURCE ! u SOURCE-U ! 0 POSITION ! 0 NEXT-FRAGMENT ! ;

\ Rust's FragmentedReader: the next fragment's bytes, at most the span's.
: FRAGMENT ( ^u8 n -- n )
   {: dst:^ cap:n :}
   SOURCE-U @ POSITION @ - {: left:n :}
   cap 0= left 0= or if 0 exit then
   NEXT-FRAGMENT @ FRAGMENT-COUNT @ mod FRAGMENTS @ {: most:n :}
   left cap min most min {: k:n :}
   SOURCE@ POSITION @ + dst k BYTE-COPY
   k POSITION +! 1 NEXT-FRAGMENT +!
   k ;

\ Rust's patterned_bytes: one xorshift64 step per byte, its low byte.
: PATTERNED ( ^u8 n n -- )
   {: a:^ u:n seed:n :}
   seed 1 or
   u 0 ?do
      dup 13 lshift xor dup 7 rshift xor dup 17 lshift xor
      dup $FF and a i + c!
   loop drop ;

SHA256-CTX-BYTES BUFFER: WHOLE
SHA256-CTX-BYTES BUFFER: PART
32 BUFFER: DIGEST
64 BUFFER: HEX

\ Rust's reference_dropbox_hash: SHA-256 over each block's SHA-256.
: REFERENCE ( ^u8 n -- ^u8 n )
   {: a:^ u:n :}
   WHOLE SHA256-BEGIN
   0 begin dup u < while
      {: at:n :}
      u at - BLOCK min {: k:n :}
      PART a at + k DIGEST SHA256-IN
      WHOLE DIGEST 32 SHA256-FEED
      at k +
   repeat drop
   WHOLE DIGEST SHA256-END DIGEST HEX SHA256>HEX
   HEX 64 ;

\ Rust's hash_length_strategy, its random arm 2..=65536.
: LENGTH ( n -- n )
   case
      0 of 0 endof
      1 of 1 endof
      2 of BLOCK 1- endof
      3 of BLOCK endof
      4 of BLOCK 1+ endof
      5 of BLOCK 2 * 1- endof
      6 of BLOCK 2 * endof
      7 of BLOCK 2 * 1+ endof
      65535 PROP:RND% 2 + swap
   endcase ;

: PUT ( n n -- ) {: v:n idx:n :} v idx FRAGMENTS ! ;

\ Rust's fragment_strategy, its random arm 1 to 11 reads of 1..=128 KiB.
: SCHEDULE ( n -- )
   {: k:n :}
   k 0 = if
      1 0 PUT 7 1 PUT 4096 2 PUT 65535 3 PUT 4 FRAGMENT-COUNT ! exit
   then
   k 1 = if 17 0 PUT 1021 1 PUT 16384 2 PUT 3 FRAGMENT-COUNT ! exit then
   11 PROP:RND% 1+ {: count:n :}
   count 0 ?do 131072 PROP:RND% 1+ i PUT loop
   count FRAGMENT-COUNT ! ;

1 BUFFER: ONE

: FULL? ( FD:fill -- bool )
   MATCH FD:fill
      full OF true ENDOF
      eof OF {: k:n :} false ENDOF
   ;MATCH ;

\ What COPY-AND-HASH gives an unnamed file in dir from the fragments.
: COPY ( fd -- ^u8 n fd )
   {: dir:fd :}
   dir FS:TEMP-AT {: f:fd :}
   [: FRAGMENT ;] f s" fragmented-download"
   s" test fragmented download copy" AR @ LOCAL:COPY-AND-HASH
   DROPBOX:HASH>STR str> f ;

\ The file's bytes from its start fill back, and nothing follows them.
: READ-BACK ( fd ^u8 n -- )
   {: f:fd back:^ u:n :}
   f 0 FD:SEEK
   f back u SPAN:MAKE FD:READ-EXACT FULL? TTRUE
   f ONE 1 SPAN:MAKE FD:READ-EXACT FULL? TFALSE ;

\ The bytes copied hash as want and read back as they were.
: COPIED ( ^u8 n ^u8 n fd ^u8 -- )
   {: bytes:^ u:n want:^ wu:n dir:fd back:^ :}
   bytes u START
   dir COPY {: c:^ cu:n f:fd :}
   [: c cu want wu T$= f back u READ-BACK bytes u back u STR= TTRUE ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ Case i takes length arm i mod 9 and schedule arm i mod 3.
: FRAGMENTED ( ^u8 ^u8 fd n -- )
   {: bytes:^ back:^ dir:fd i:n :}
   i 9 mod LENGTH {: u:n :}
   i 3 mod SCHEDULE
   bytes u 256 PROP:RND% PATTERNED
   bytes u REFERENCE {: want:^ wu:n :}
   bytes u START
   [: FRAGMENT ;] AR @ LOCAL:HASH-STREAM DROPBOX:HASH>STR str>
   want wu T$=
   bytes u want wu dir back COPIED ;

: FRAGMENT-CASES ( fd ^u8 ^u8 -- )
   {: dir:fd bytes:^ back:^ :}
   12 0 ?do bytes back dir i FRAGMENTED loop ;

\ Twelve cases, as proptest's, from a fixed seed.
: DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION ( -- )
   s" dropbox_hash_and_copy_are_independent_of_reader_fragmentation" T-LABEL
   1 PROP:SEED!
   BLOCK 2 * 1+ MEM:BYTES-ALLOC-LEN {: len:NUM:alloc-byte-len :}
   len MEM:ALLOC-BYTES {: bytes:^ cap:NUM:alloc-byte-len :}
   len MEM:ALLOC-BYTES {: back:^ cap2:NUM:alloc-byte-len :}
   [: [: bytes back FRAGMENT-CASES ;] IN-CASE-DIR ;]
   [: bytes cap MEM:RELEASE-BYTES back cap2 MEM:RELEASE-BYTES ;]
   finally ;

\ ---- download stages

: HASH-OF ( ^u8 n -- DROPBOX:hash ) IDENTITY >str DROPBOX:>HASH ;
: TARGET ( -- ^u8 n ) s" target.txt" ;
: WANT ( -- DROPBOX:hash ) s" remote" HASH-OF ;
: MARKER ( -- ^u8 n ) TARGET WANT AR @ LOCAL:STAGE-MARKER ;

: PUT-FILE ( ^u8 n ^u8 n -- )
   {: name:^ nu:n b:^ bu:n :}
   name nu AT b bu FS:WRITE-ALL ;

: OPEN-AT ( fd ^u8 n -- fd )
   FS:TRY-OPEN-READ-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MARK ( fd ^u8 n -- )
   {: f:fd p:^ u:n :}
   f LOCAL:DOWNLOAD-STAGE-XATTR MARKER true p u s" test mark"
   LOCAL:SET-XATTR ;

\ The Rust daemon's marker for target.txt holding "remote".
: MARKER-IS-RUSTS ( -- )
   s" stage marker is the Rust daemon's" T-LABEL
   MARKER
   s" .omabox-download-marker-v1-650b14d6787578d77de1e8b7f15a0de414baf0aa96888b334fb9a1b1dd9fe93a"
   T$= ;

: UNMARK ( fd -- )
   LOCAL:DOWNLOAD-STAGE-XATTR s" marked" s" test unmark"
   LOCAL:REMOVE-XATTR ;

: MARKER-CHECKS ( fd -- )
   {: f:fd :}
   f s" marked" MARK
   f MARKER s" marked" LOCAL:MARKER$ s" expected" T$=
   f s" other" s" marked" LOCAL:MARKER$ s" other" T$=
   [: f s" marked" MARK ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:EEXIST T=
   f UNMARK
   f MARKER s" marked" LOCAL:MARKER$ s" missing" T$=
   f UNMARK ;

: MARKER-ROUND-TRIP ( fd -- )
   {: root:fd :}
   s" marked" s" remote" PUT-FILE
   root s" marked" OPEN-AT {: f:fd :}
   [: f MARKER-CHECKS ;] [: f FS:CLOSE-DIR ;] finally ;

: STAGE-MARKER-IS-SET-READ-AND-REMOVED ( -- )
   s" stage marker is set, read and removed" T-LABEL
   [: MARKER-ROUND-TRIP ;] IN-CASE-DIR ;

: INSPECTED ( fd ^u8 n ^u8 n -- )
   {: root:fd p:^ u:n want:^ wu:n :}
   p u T-LABEL
   root p u p u TARGET WANT AR @ LOCAL:INSPECTED$ want wu T$= ;

: OWNED-STAGE ( fd -- )
   {: root:fd :}
   s" owned" s" remote" PUT-FILE
   root s" owned" OPEN-AT {: f:fd :}
   [: f s" owned" MARK ;] [: f FS:CLOSE-DIR ;] finally ;

: INSPECT-CASES ( fd -- )
   {: root:fd :}
   s" foreign" s" mutant" PUT-FILE
   s" unmarked" s" remote" PUT-FILE
   root OWNED-STAGE
   root s" absent" s" missing" INSPECTED
   root s" foreign" s" destination-occupied" INSPECTED
   root s" unmarked" s" destination-occupied" INSPECTED
   root s" owned" s" verified" INSPECTED ;

: EACH-DOWNLOAD-STAGE-IS-INSPECTED ( -- )
   s" each download stage is inspected" T-LABEL
   [: INSPECT-CASES ;] IN-CASE-DIR ;

\ The outcome's variant, and its actual hash or path, else empty.
: OUTCOME$ ( LOCAL:stage-outcome<n> -- ^u8 n ^u8 n )
   MATCH LOCAL:stage-outcome
      staged OF drop s" staged" s" " ENDOF
      already-staged OF drop s" already-staged" s" " ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR str>
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p str>
      ENDOF
   ;MATCH ;

\ Stages bytes at name, marked as target's owned download of "remote".
: STAGED ( fd ^u8 n ^u8 n -- ^u8 n ^u8 n )
   {: root:fd name:^ nu:n b:^ bu:n :}
   name nu T-LABEL
   b bu START 0 SCHEDULE
   root name nu name nu WANT [: FRAGMENT ;] MARKER >str OPTION:SOME
   s" test stage" AR @ LOCAL:WRITE-STAGE-OUTCOME OUTCOME$ ;

: STAGE-CASES ( fd -- )
   {: root:fd :}
   root s" fresh" s" remote" STAGED s" " T$= s" staged" T$=
   root s" fresh" s" remote" STAGED s" " T$= s" already-staged" T$=
   root s" fresh" s" verified" INSPECTED
   root s" changed" s" mutant" STAGED
   s" mutant" IDENTITY T$= s" content-changed" T$=
   root s" changed" LOCAL:ENTRY-EXISTS-AT TFALSE
   s" foreign" s" mutant" PUT-FILE
   root s" foreign" s" remote" STAGED
   s" foreign" T$= s" destination-occupied" T$= ;

: EACH-STAGE-OUTCOME-IS-REACHED ( -- )
   s" each stage outcome is reached" T-LABEL
   [: STAGE-CASES ;] IN-CASE-DIR ;

\ ---- download slots

\ One case of Rust's property: the checkpoint at or below x round-trips,
\ is the last at or before x, and is a whole number of blocks.
: CHECKPOINT ( n -- )
   {: x:n :}
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   x cp / cp * {: offset:n :}
   7 LOCAL:FILLED-BINDING {: seven:LOCAL:binding :}
   seven offset LOCAL:STATE-ROUND-TRIP
   {: b:LOCAL:binding at:n found:bool :}
   found TTRUE at offset T= b seven LOCAL:BINDING= TTRUE
   offset x <= TTRUE x offset cp + < TTRUE offset BLOCK mod 0 T= ;

\ Rust's range is 0 to 1024 checkpoints and a block; its boundaries are
\ 0, each checkpoint and the bytes either side of it, and the last.
: DOWNLOAD-CHECKPOINT-STATE-ENCODES-THE-LAST-COMPLETE-BOUNDARY ( -- )
   s" download_checkpoint_state_encodes_the_last_complete_boundary"
   T-LABEL
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   0 CHECKPOINT
   1025 1 ?do
      i cp * 1- CHECKPOINT i cp * CHECKPOINT i cp * 1+ CHECKPOINT
   loop
   1024 cp * BLOCK + CHECKPOINT ;

32 BUFFER: TEXT-BUF

\ The prefix and n's digits, valid until the next.
: NUMBERED ( ^u8 n n -- ^u8 n )
   {: x:^ xu:n k:n :}
   x TEXT-BUF xu BYTE-COPY
   k FMT:INT$ {: d:^ du:n :}
   d TEXT-BUF xu + du BYTE-COPY
   TEXT-BUF xu du + ;

\ Rust's test_slot_identity: target t's download of c at "revision-<op>".
: SLOT-IDENTITY
   ( ^u8 n DROPBOX:hash n n -- LOCAL:download-slot-identity )
   {: t:^ tu:n c:DROPBOX:hash generation:n op:n :}
   c s" revision-" op NUMBERED >str DROPBOX:>REV MODEL-REMOTE:MAKE
   {: r:MODEL:remote :}
   generation op t tu r LOCAL:NEW-SLOT-IDENTITY ;

: DOWNLOAD ( -- DROPBOX:hash ) s" download" HASH-OF ;

\ The lease of the case directory's slots for the identity, apart.
: LEASE
   ( ^u8 n DROPBOX:hash n n [ LOCAL:binding -- bool ]
     -- n LOCAL:binding bool )
   {: t:^ tu:n c:DROPBOX:hash generation:n op:n protected :}
   t tu c generation op SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id protected LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASE-OF ;

: UNPROTECTED ( LOCAL:binding -- bool ) drop false ;

TYPED-VARIABLE HELD LOCAL:binding
: HELD? ( LOCAL:binding -- bool ) HELD @ LOCAL:BINDING= ;

4 TYPED-BUFFER LEASED LOCAL:binding
variable LEASED-COUNT

: LEASED? ( LOCAL:binding -- bool )
   {: b:LOCAL:binding :}
   LEASED-COUNT @ 0 ?do
      i LEASED @ b LOCAL:BINDING= if true unloop exit then
   loop false ;

: SLOT-AT ( n -- ^u8 n ) LOCAL:DOWNLOAD-SLOT-NAME AT ;

64 BUFFER: HELD-BYTES

\ The file at the path holds exactly the bytes.
: HOLDS ( ^u8 n ^u8 n -- )
   {: p:^ u:n b:^ bu:n :}
   p u HELD-BYTES 64 FS:READ-ALL {: k:n :}
   HELD-BYTES k b bu T$= ;

\ The open file carries the binding at offset at.
: STATE-IS ( fd ^u8 n LOCAL:binding n -- )
   {: f:fd name:^ nu:n want:LOCAL:binding offset:n :}
   f name nu LOCAL:SLOT-STATE-OF {: b:LOCAL:binding at:n found:bool :}
   found TTRUE b want LOCAL:BINDING= TTRUE at offset T= ;

\ The file at name below the root carries the binding at offset at.
: STATE-AT ( fd ^u8 n LOCAL:binding n -- )
   {: root:fd name:^ nu:n want:LOCAL:binding offset:n :}
   root name nu OPEN-AT {: f:fd :}
   [: f name nu want offset STATE-IS ;] [: f FS:CLOSE-DIR ;] finally ;

variable FILES

: POOL-LEASE ( n -- )
   {: op:n :}
   s" target-" op NUMBERED DOWNLOAD 1 op 1+ [: LEASED? ;] LEASE
   {: slot:n b:LOCAL:binding found:bool :}
   found if b LEASED-COUNT @ LEASED ! 1 LEASED-COUNT +! then ;

\ A one-slot lease takes a slot per call, so the leases already held
\ are protected, as one Rust call's leases are from each other.
: POOL ( fd -- )
   {: root:fd :}
   0 LEASED-COUNT !
   5 0 ?do i POOL-LEASE loop
   LEASED-COUNT @ 4 T=
   0 FILES ! ROOT$ [: 2drop 1 FILES +! ;] FS:WALK-FILES FILES @ 4 T=
   4 0 ?do i SLOT-AT FS:FILE? TTRUE loop ;

: DOWNLOAD-SLOT-POOL-HAS-FOUR-FIXED-PATHS-WITHOUT-OVERFLOW ( -- )
   s" download_slot_pool_has_four_fixed_paths_without_overflow" T-LABEL
   [: POOL ;] IN-CASE-DIR ;

: PROTECTED ( fd -- )
   {: root:fd :}
   s" held.bin" DOWNLOAD 1 20 [: UNPROTECTED ;] LEASE
   {: hs:n hb:LOCAL:binding held:bool :}
   held TTRUE hb HELD !
   hs SLOT-AT s" partial download bytes" FS:WRITE-ALL
   s" other.bin" DOWNLOAD 1 21 [: HELD? ;] LEASE
   {: os:n ob:LOCAL:binding other:bool :}
   other TTRUE os hs <> TTRUE
   hs SLOT-AT s" partial download bytes" HOLDS
   root hs LOCAL:DOWNLOAD-SLOT-NAME hb 0 STATE-AT ;

: PROTECTED-DOWNLOAD-SLOT-KEEPS-ITS-BINDING-AND-BYTES ( -- )
   s" protected_download_slot_keeps_its_binding_and_bytes" T-LABEL
   [: PROTECTED ;] IN-CASE-DIR ;

: STALE ( n -- ) SLOT-AT s" stale bytes" FS:WRITE-ALL ;

\ The slot is empty and carries the binding at offset 0.
: EMPTY-SLOT ( fd n LOCAL:binding -- )
   {: root:fd slot:n b:LOCAL:binding :}
   slot SLOT-AT FS:FILE-SIZE 0 T=
   root slot LOCAL:DOWNLOAD-SLOT-NAME b 0 STATE-AT ;

\ A one-slot lease has no empty form to free a stale slot with, so a
\ second stale slot shows the freeing: the rebinding lease claims the
\ first and empties the second, its binding kept.
: STALE-SLOTS ( fd -- )
   {: root:fd :}
   TARGET DOWNLOAD 1 10 [: UNPROTECTED ;] LEASE
   {: old:n ob:LOCAL:binding f0:bool :}
   f0 TTRUE ob HELD ! old STALE
   s" other.bin" DOWNLOAD 1 30 [: HELD? ;] LEASE
   {: other:n xb:LOCAL:binding f1:bool :}
   f1 TTRUE other STALE
   TARGET DOWNLOAD 2 10 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 1 11 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 2 10 [: UNPROTECTED ;] LEASE
   {: new:n nb:LOCAL:binding f2:bool :}
   f2 TTRUE
   root new nb EMPTY-SLOT
   root other xb EMPTY-SLOT ;

: STALE-SLOT-IS-REBOUND-ACROSS-ROOT-AND-OPERATION-IDENTITY ( -- )
   s" stale_slot_is_rebound_across_root_and_operation_identity" T-LABEL
   [: STALE-SLOTS ;] IN-CASE-DIR ;

FS:PATHZ-CAP BUFFER: JOINED2
32 BUFFER: SLOT-NAME-BUF
variable SLOT-NAME-U
FS:PATHZ-CAP BUFFER: SLOT-PATH-BUF
variable SLOT-PATH-U

\ AT into a buffer of its own.
: AT2 ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u JOINED2 FS:JOIN-PATH JOINED2 swap ;

: SLOT$ ( -- ^u8 n ) SLOT-NAME-BUF SLOT-NAME-U @ ;
: SLOT-PATH$ ( -- ^u8 n ) SLOT-PATH-BUF SLOT-PATH-U @ ;

\ Keeps the slot's name and path where only the case reads them.
: KEEP-SLOT ( n -- )
   {: slot:n :}
   slot LOCAL:DOWNLOAD-SLOT-NAME {: p:^ u:n :}
   p SLOT-NAME-BUF u BYTE-COPY u SLOT-NAME-U !
   SLOT$ AT {: q:^ qu:n :}
   q SLOT-PATH-BUF qu BYTE-COPY qu SLOT-PATH-U ! ;

\ Rust's before_reset here: the slot moves to held-slot and a new file
\ takes its name.
: SWAP-SLOT ( -- )
   SLOT$ AT2 s" held-slot" AT FS:RENAME-FILE
   SLOT$ AT s" replacement" FS:WRITE-ALL ;

: EXPECTED ( -- DROPBOX:hash ) s" expected bytes" HASH-OF ;

\ The reset of the slot open at f, with the swap before its truncate.
: SWAP-RESET ( fd fd LOCAL:binding -- bool )
   {: f:fd root:fd b:LOCAL:binding :}
   f root SLOT$ SLOT-PATH$ b [: SWAP-SLOT ;]
   LOCAL:RESET-DOWNLOAD-SLOT-FILE-WITH LOCAL:TAKEN? ;

\ prepare_download_slot_at answers a fresh lease's slot opened, which
\ this case opens itself: it leaves prepare_download_slot_at out.
: SWAPPED ( fd -- )
   {: root:fd :}
   TARGET EXPECTED 1 1 [: UNPROTECTED ;] LEASE
   {: slot:n b:LOCAL:binding found:bool :}
   found TTRUE slot KEEP-SLOT
   root SLOT$ SLOT-PATH$ LOCAL:OPENED-SLOT {: f:fd opened:bool :}
   opened TTRUE
   [: f root b SWAP-RESET TFALSE ;] [: f FS:CLOSE-DIR ;] finally
   SLOT$ AT s" replacement" HOLDS
   s" held-slot" AT FS:FILE-SIZE 0 T=
   root s" held-slot" b 0 STATE-AT
   root s" held-slot" OPEN-AT {: moved:fd :}
   [: moved TARGET EXPECTED AR @ LOCAL:STAGE-MARKER s" held-slot"
      LOCAL:MARKER$ s" missing" T$= ;]
   [: moved FS:CLOSE-DIR ;] finally ;

: PARTIAL-RESET-NEVER-MUTATES-A-SWAPPED-REPLACEMENT ( -- )
   s" partial_reset_never_mutates_a_swapped_replacement" T-LABEL
   [: SWAPPED ;] IN-CASE-DIR ;

\ ---- resumed downloads

FS:PATHZ-CAP BUFFER: SYNC-BUF
variable SYNC-U

: SYNC$ ( -- ^u8 n ) SYNC-BUF SYNC-U @ ;

: WITH-SYNC-ROOT ( fd [ fd -- ] -- )
   {: case:fd q :}
   s" sync" AT FS:MAKE-DIR
   s" sync" AT {: p:^ u:n :}
   p SYNC-BUF u BYTE-COPY u SYNC-U !
   SYNC$ s" open test sync root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root q execute ;] [: root FS:CLOSE-DIR ;] finally ;

\ Runs q on a sync root in the case directory, which holds the slots as
\ Rust's staging TempDir does.
: IN-SYNC-ROOT ( [ fd -- ] -- )
   {: q :}
   [: q WITH-SYNC-ROOT ;] IN-CASE-DIR ;

\ Rust's test_download_lease: the slot leased for target t's download
\ of c, root generation 1, operation 1.
: TEST-LEASE ( ^u8 n DROPBOX:hash -- LOCAL:download-slot-lease )
   {: t:^ tu:n c:DROPBOX:hash :}
   t tu c 1 1 SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id [: UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASED ;

: PREPARE
   ( fd ^u8 n DROPBOX:hash LOCAL:download-slot-lease
     -- LOCAL:download-preparation )
   {: root:fd t:^ tu:n c:DROPBOX:hash lease:LOCAL:download-slot-lease :}
   root SYNC$ t tu c lease AR @ LOCAL:PREPARE-DOWNLOAD-SLOT-AT ;

: DROP-OUTCOME ( LOCAL:stage-outcome<n> -- ) drop ;

\ The preparation's variant, a complete one's outcome and its path; a
\ ready partial is freed.
: PREPARATION$ ( LOCAL:download-preparation -- ^u8 n ^u8 n )
   MATCH LOCAL:download-preparation
      ready OF LOCAL:CLOSE-PARTIAL s" ready" s" " ENDOF
      complete OF OUTCOME$ ENDOF
      ephemeral OF s" ephemeral" s" " ENDOF
   ;MATCH ;

: PREPARED-AS ( LOCAL:download-preparation ^u8 n -- )
   {: p:LOCAL:download-preparation want:^ wu:n :}
   p PREPARATION$ s" " T$= want wu T$= ;

104 constant ECONNRESET
variable REMAINING

\ Rust's FailingBytes: "x" bytes until none remain, then a reset
\ connection.
: FAILING ( ^u8 n -- n )
   {: dst:^ cap:n :}
   REMAINING @ 0= if ECONNRESET FS:CAUSE! E-FS-IO throw then
   REMAINING @ cap min {: k:n :}
   k 0 ?do $78 dst i + c! loop
   k negate REMAINING +!
   k ;

: TOTAL ( -- n ) LOCAL:DOWNLOAD-CHECKPOINT-BYTES BLOCK 2 * + ;

: BOUNDARY ( -- ^u8 n ) s" boundary.bin" ;

: SIZE-OF ( fd -- n ) FS:FD-STAT FS:STAT-SIZE@ ;

\ A download cut after cut bytes leaves written bytes and resumes at
\ durable.
: INTERRUPTED ( fd n n n -- )
   {: root:fd cut:n written:n durable:n :}
   s" download never reaches verification" HASH-OF {: c:DROPBOX:hash :}
   BOUNDARY c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root BOUNDARY c lease PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   cut REMAINING !
   [: x TOTAL [: FAILING ;] AR @ LOCAL:APPEND-PARTIAL DROP-OUTCOME ;]
   LOCAL:E-STAGE-READ TTHROWSQ
   p u FS:FILE-SIZE written T=
   root BOUNDARY c lease PREPARE LOCAL:READY-PARTIAL {: y :}
   y LOCAL:PARTIAL-OFFSET@ durable T=
   y LOCAL:PARTIAL-FILE SIZE-OF durable T=
   y LOCAL:CLOSE-PARTIAL ;

: INTERRUPTED-DOWNLOADS-RESUME-FROM-DURABLE-BOUNDARIES ( -- )
   s" interrupted_downloads_resume_from_durable_boundaries" T-LABEL
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   [: cp 1- cp BLOCK - 0 INTERRUPTED ;] IN-SYNC-ROOT
   [: cp cp cp INTERRUPTED ;] IN-SYNC-ROOT
   [: cp 1+ cp cp INTERRUPTED ;] IN-SYNC-ROOT
   [: cp BLOCK + 1+ cp BLOCK + cp INTERRUPTED ;] IN-SYNC-ROOT ;

\ The prepared partial of target.txt's download of c, its bytes written.
: WRITTEN
   ( fd DROPBOX:hash LOCAL:download-slot-lease ^u8 n
     -- ^LOCAL:download-partial )
   {: root:fd c:DROPBOX:hash lease:LOCAL:download-slot-lease b:^ bu:n :}
   root TARGET c lease PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-FILE b bu FD:WRITE-FULL
   x ;

: STAGE-HOLDS ( ^LOCAL:download-partial ^u8 n -- )
   {: x b:^ bu:n :}
   x LOCAL:PARTIAL-STAGE-PATH b bu HOLDS ;

\ install_download is not ported yet: Rust's test then installs the
\ stage and reads the bytes back at the target.
: RECOVERED ( fd bool -- )
   {: root:fd renamed:bool :}
   s" completed bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   renamed if x LOCAL:RENAME-TO-STAGE TTRUE then
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease PREPARE
   renamed if s" already-staged" else s" staged" then PREPARED-AS
   root TARGET c lease PREPARE s" already-staged" PREPARED-AS
   x b bu STAGE-HOLDS ;

: COMPLETED-PARTIAL-RECOVERS-BEFORE-AND-AFTER-RENAME ( -- )
   s" completed_partial_recovers_before_and_after_rename" T-LABEL
   [: false RECOVERED ;] IN-SYNC-ROOT
   [: true RECOVERED ;] IN-SYNC-ROOT ;

: RESTARTED-EMPTY ( LOCAL:download-preparation -- )
   LOCAL:READY-PARTIAL {: y :}
   y LOCAL:PARTIAL-OFFSET@ 0 T=
   y LOCAL:PARTIAL-FILE SIZE-OF 0 T=
   y LOCAL:CLOSE-PARTIAL ;

: CORRUPT ( fd bool -- )
   {: root:fd owned:bool :}
   s" complete bytes" HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease s" incomplete" WRITTEN {: x :}
   owned 0= if
      x LOCAL:PARTIAL-FILE LOCAL:DOWNLOAD-PARTIAL-XATTR s" foreign owner"
      XATTR:SET
   then
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease PREPARE {: prep:LOCAL:download-preparation :}
   owned if prep RESTARTED-EMPTY exit then
   prep s" ephemeral" PREPARED-AS
   p u s" incomplete" HOLDS ;

: CORRUPT-COMPLETED-PARTIAL-RESTARTS-ONLY-WHEN-OWNED ( -- )
   s" corrupt_completed_partial_restarts_only_when_owned" T-LABEL
   [: true CORRUPT ;] IN-SYNC-ROOT
   [: false CORRUPT ;] IN-SYNC-ROOT ;

\ Rust's before_move here: the slot moves to held-slot and a new file
\ takes its name.
: SWAP-PARTIAL ( ^u8 n -- )
   {: p:^ u:n :}
   p u s" held-slot" AT FS:RENAME-FILE
   p u s" replacement" FS:WRITE-ALL ;

: SWAPPED-PROMOTION ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   [: x [: p u SWAP-PARTIAL ;] AR @ LOCAL:PROMOTE-WITH OUTCOME$
      p u T$= s" destination-occupied" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   p u s" replacement" HOLDS
   s" held-slot" AT b bu HOLDS
   x LOCAL:PARTIAL-STAGE-PATH FS:TRY-LSTAT TFALSE ;

: COMPLETED-PARTIAL-PROMOTION-PRESERVES-A-SWAPPED-REPLACEMENT ( -- )
   s" completed_partial_promotion_preserves_a_swapped_replacement" T-LABEL
   [: SWAPPED-PROMOTION ;] IN-SYNC-ROOT ;

\ install_download is not ported yet: Rust's test then installs the
\ stage and reads the bytes back at the target.
: CROSS-FILESYSTEM ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   [: x AR @ LOCAL:COPY-PARTIAL OUTCOME$ s" " T$= s" staged" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   x LOCAL:PARTIAL-PATH FS:FILE-SIZE 0 T=
   x b bu STAGE-HOLDS ;

: CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   ( -- )
   s" cross_filesystem_slot_completion_copies_rehashes_and_frees_the_slot"
   T-LABEL
   [: CROSS-FILESYSTEM ;] IN-SYNC-ROOT ;

\ Rust's staged_download(stage_download(...)): b staged from a reader.
: STAGE-BYTES ( ^u8 n DROPBOX:hash -- )
   {: b:^ bu:n c:DROPBOX:hash :}
   b bu START 0 SCHEDULE
   SYNC$ TARGET c [: FRAGMENT ;] AR @ LOCAL:STAGE-DOWNLOAD OUTCOME$
   s" " T$= s" staged" T$= ;

\ install_download is not ported yet: Rust's test then installs the
\ stage and reads the bytes back at the target.
: ZERO-REPLAY ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:ZERO-CHECKPOINT
   b bu c STAGE-BYTES
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease PREPARE s" already-staged" PREPARED-AS
   p u FS:FILE-SIZE 0 T=
   root TARGET c lease PREPARE s" already-staged" PREPARED-AS ;

: INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT ( -- )
   s" interrupted_partial_reset_replays_to_a_reusable_zero_checkpoint"
   T-LABEL
   [: ZERO-REPLAY ;] IN-SYNC-ROOT ;

\ ---- parents

: INODE ( fd -- n ) FS:FD-STAT FS:STAT-INO@ ;

: PATH-INODE ( ^u8 n -- n ) AT FS:TRY-LSTAT TTRUE FS:STAT-INO@ ;

: SAME-ADDRESS ( ^u8 ^u8 -- )
   {: a:^ b:^ :}
   a NULL-PTR - b NULL-PTR - T= ;

\ p's parent opens, its name and path spans of p; answers the descriptor.
: PARENT ( fd ^u8 n bool ^u8 n ^u8 n -- fd )
   {: root:fd p:^ u:n create:bool name:^ nu:n path:^ pu:n :}
   p u T-LABEL
   root p u create LOCAL:PARENT-OF TTRUE
   {: f:fd got:^ gu:n gp:^ gpu:n :}
   got gu name nu T$= gp gpu path pu T$=
   got p u + nu - SAME-ADDRESS gp p SAME-ADDRESS
   f ;

\ Closes the descriptor PARENT-OF answers, if any.
: TRY-PARENT ( fd ^u8 n bool -- )
   LOCAL:PARENT-OF {: f:fd n:^ nu:n pp:^ pu:n found:bool :}
   found if f FS:CLOSE-DIR then ;

: ROOT-PARENT ( fd -- )
   {: root:fd :}
   s" present" s" bytes" PUT-FILE
   root s" present" false s" present" s" " PARENT {: f:fd :}
   f FD>N root FD>N <> TTRUE
   f INODE root INODE T=
   f FS:CLOSE-DIR
   root s" present" LOCAL:ENTRY-EXISTS-AT TTRUE ;

: EXISTING-PARENT ( fd -- )
   {: root:fd :}
   s" a/b" AT FS:MAKE-DIRS
   root s" a/b/file" false s" file" s" a/b" PARENT {: f:fd :}
   f INODE s" a/b" PATH-INODE T=
   f FS:CLOSE-DIR ;

: MISSING-PARENT ( fd -- )
   {: root:fd :}
   s" a" AT FS:MAKE-DIR
   s" a/missing/file" T-LABEL
   root s" a/missing/file" false LOCAL:PARENT-OF TFALSE
   {: f:fd n:^ nu:n pp:^ pu:n :}
   root s" a/missing" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: PRIVATE-DIR ( ^u8 n -- )
   {: p:^ u:n :}
   p u T-LABEL
   p u AT FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFDIR T=
   FS:STAT-MODE@ $1FF and MODE-0700 T= ;

: CREATED-PARENTS ( fd -- )
   {: root:fd :}
   root s" x/y/z/file" true s" file" s" x/y/z" PARENT {: f:fd :}
   s" x" PRIVATE-DIR s" x/y" PRIVATE-DIR s" x/y/z" PRIVATE-DIR
   f INODE s" x/y/z" PATH-INODE T=
   f FS:CLOSE-DIR
   root s" x/y/z/file" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: SYMLINK-PARENT ( fd -- )
   {: root:fd :}
   s" real" AT FS:MAKE-DIR
   s" real" s" link" AT FS:MAKE-SYMLINK
   s" link/sub/file" T-LABEL
   [: root s" link/sub/file" true TRY-PARENT ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:ENOTDIR T=
   root s" real/sub" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: UNSAFE-PARENT ( fd ^u8 n -- )
   {: root:fd p:^ u:n :}
   p u T-LABEL
   [: root p u false TRY-PARENT ;] LOCAL:E-UNSAFE-PATH TTHROWSQ ;

: UNSAFE-PARENTS ( fd -- )
   {: root:fd :}
   root s" " UNSAFE-PARENT
   root s" /absolute" UNSAFE-PARENT
   root s" ./file" UNSAFE-PARENT
   root s" a/../file" UNSAFE-PARENT ;

: ONE-COMPONENT-PARENT-IS-A-DUPLICATE-ROOT ( -- )
   s" one component's parent is a duplicate root" T-LABEL
   [: ROOT-PARENT ;] IN-CASE-DIR ;

: EXISTING-PARENT-OPENS ( -- )
   s" existing parent opens" T-LABEL
   [: EXISTING-PARENT ;] IN-CASE-DIR ;

: MISSING-PARENT-IS-NONE-WITHOUT-CREATE ( -- )
   s" missing parent is none without create" T-LABEL
   [: MISSING-PARENT ;] IN-CASE-DIR ;

: CREATE-MAKES-PRIVATE-PARENTS ( -- )
   s" create makes private parents" T-LABEL
   [: CREATED-PARENTS ;] IN-CASE-DIR ;

: SYMLINK-PARENT-IS-REFUSED ( -- )
   s" symlink parent is refused" T-LABEL
   [: SYMLINK-PARENT ;] IN-CASE-DIR ;

: UNSAFE-PARENT-PATH-FAILS ( -- )
   s" unsafe parent path fails" T-LABEL
   [: UNSAFE-PARENTS ;] IN-CASE-DIR ;

: CASES ( -- )
   ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION
   DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION
   MARKER-IS-RUSTS
   STAGE-MARKER-IS-SET-READ-AND-REMOVED
   EACH-DOWNLOAD-STAGE-IS-INSPECTED
   EACH-STAGE-OUTCOME-IS-REACHED
   ONE-COMPONENT-PARENT-IS-A-DUPLICATE-ROOT
   EXISTING-PARENT-OPENS
   MISSING-PARENT-IS-NONE-WITHOUT-CREATE
   CREATE-MAKES-PRIVATE-PARENTS
   SYMLINK-PARENT-IS-REFUSED
   UNSAFE-PARENT-PATH-FAILS
   DOWNLOAD-CHECKPOINT-STATE-ENCODES-THE-LAST-COMPLETE-BOUNDARY
   PARTIAL-RESET-NEVER-MUTATES-A-SWAPPED-REPLACEMENT
   DOWNLOAD-SLOT-POOL-HAS-FOUR-FIXED-PATHS-WITHOUT-OVERFLOW
   PROTECTED-DOWNLOAD-SLOT-KEEPS-ITS-BINDING-AND-BYTES
   STALE-SLOT-IS-REBOUND-ACROSS-ROOT-AND-OPERATION-IDENTITY
   INTERRUPTED-DOWNLOADS-RESUME-FROM-DURABLE-BOUNDARIES
   COMPLETED-PARTIAL-RECOVERS-BEFORE-AND-AFTER-RENAME
   CORRUPT-COMPLETED-PARTIAL-RESTARTS-ONLY-WHEN-OWNED
   COMPLETED-PARTIAL-PROMOTION-PRESERVES-A-SWAPPED-REPLACEMENT
   CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
