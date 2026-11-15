\ local-test.f - LOCAL's shared words and download stages: local.rs's tests
\ that an entry's existence below the root never follows a symlink and
\ takes a failed probe as unconfirmed, that the content hash composes block
\ hashes, and that neither the hash nor a stage's copy depends on how a
\ reader fragments the bytes; then each stage outcome, each inspected
\ download stage, a stage marker set, read and removed, and each parent a
\ download opens; then local.rs's install tests and each install outcome
\ and replacement preparation. A case that makes files works in its own
\ directory under TMPDIR and removes it.
\ Run from the repository root: hb --load src/local-test.f </dev/null
require src/lib/test.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/property.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fd.f
require src/lib/adt/option.f
require src/lib/xattr.f
require src/dropbox.f
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

\ The name target t's stage of want takes.
: STAGE-NAME ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t tu want ar INTERNAL-NAME ;

: DROP-OUTCOME ( install-outcome -- ) drop ;

\ The stage INSPECT-DOWNLOAD-STAGE verified for x; any other fails the
\ run.
: VERIFIED-STAGE ( install -- verified-download-stage )
   INSPECT-INSTALL-STAGE MATCH download-stage
      missing OF E-CHANGED throw ENDOF
      verified OF ENDOF
      destination-occupied OF {: p:str :} E-OCCUPIED throw ENDOF
   ;MATCH ;

\ Writes "mutant" over the sealed stage through w, opened before it.
: MUTATE ( fd -- )
   {: w:fd :}
   w FS:MODE-PRIVATE-FILE FD:MODE! w 0 FD:SEEK
   w s" mutant" FD:WRITE-FULL w FD:SYNC ;

: RENAME-REFUSED ( install verified-download-stage -- )
   {: x:install s:verified-download-stage :}
   [: x s RENAME-STAGE-INTO-ABSENT-TARGET DROP-OUTCOME ;]
   E-CHANGED TTHROWSQ ;

\ Verifies x's stage, mutates it through w, then renames it.
: RENAME-MUTATED ( install fd -- )
   {: x:install w:fd :}
   x VERIFIED-STAGE {: s:verified-download-stage :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   [: w MUTATE x s RENAME-REFUSED ;] [: f DISCARD ;] finally ;

\ RENAME-MUTATED on target t's install below the root fd at r, its
\ parent opened as INSTALL-DOWNLOAD-AT opens it.
: INSTALL-RENAME-MUTATED
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena fd -- )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena
      w:fd :}
   root t tu false OPEN-PARENT MATCH option
      none OF E-CHANGED throw ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r ru t tu want ar INSTALL-OF w RENAME-MUTATED ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ SYNC-RENAMED-DOWNLOAD of the file at t in dir, as a stage verified
\ now, refuses it: it carries no marker.
: RENAMED-WITHOUT-MARKER
   ( fd fd ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: f:fd dir:fd t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   f t tu s" inspect test download" STAT-FD t tu FILE-FINGERPRINT
   {: print:MODEL:fingerprint :}
   f print VERIFIED-DOWNLOAD-STAGE-MAKE {: s:verified-download-stage :}
   [: s dir t tu t tu want ar SYNC-RENAMED-DOWNLOAD ;]
   E-CHANGED TTHROWSQ ;

public
EXPORT STAGE-NAME
EXPORT GUARD-NAME
EXPORT DOWNLOAD-PARTIAL-XATTR
EXPORT SYNC-INSTALLED-DOWNLOAD
EXPORT INSTALL-RENAME-MUTATED
EXPORT RENAMED-WITHOUT-MARKER
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

\ ---- installs

64 BUFFER: READ-BUF

\ The bytes of the file at the name below the case's directory.
: READ$ ( ^u8 n -- ^u8 n )
   AT READ-BUF 64 FS:READ-ALL READ-BUF swap ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;
: HELD ( ^u8 n -- option<DROPBOX:hash> ) HASH-OF OPTION:SOME ;

: ACTUAL$ ( option<DROPBOX:hash> -- ^u8 n )
   MATCH option
      none OF s" none" ENDOF
      some OF DROPBOX:HASH>STR str> ENDOF
   ;MATCH ;

\ The outcome's variant, and its path or actual content, else empty.
: INSTALL$ ( LOCAL:install-outcome -- ^u8 n ^u8 n )
   MATCH LOCAL:install-outcome
      installed OF s" installed" s" " ENDOF
      already-installed OF s" already-installed" s" " ENDOF
      download-required OF s" download-required" s" " ENDOF
      stage-destination-occupied OF {: p:str :}
         s" stage-destination-occupied" p str>
      ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

: PREPARATION$ ( LOCAL:replacement-preparation -- ^u8 n ^u8 n )
   MATCH LOCAL:replacement-preparation
      prepared OF s" prepared" s" " ENDOF
      already-prepared OF s" already-prepared" s" " ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

: STAGE-NAME$ ( ^u8 n -- ^u8 n ) WANT AR @ LOCAL:STAGE-NAME ;

\ Stages "remote" as t's owned download, as stage_download does for a
\ top-level target; stage_download is not LOCAL's yet.
: STAGE-REMOTE ( fd ^u8 n -- )
   {: root:fd t:^ tu:n :}
   t tu STAGE-NAME$ {: sn:^ snu:n :}
   s" remote" START 0 SCHEDULE
   root sn snu sn snu WANT [: FRAGMENT ;]
   t tu WANT AR @ LOCAL:STAGE-MARKER >str OPTION:SOME
   s" stage download" AR @ LOCAL:WRITE-STAGE-OUTCOME OUTCOME$
   s" " T$= s" staged" T$= ;

\ INSTALL-DOWNLOAD of "remote" at t below the case's directory.
: INSTALL ( ^u8 n option<DROPBOX:hash> -- ^u8 n ^u8 n )
   {: t:^ tu:n expected:option<DROPBOX:hash> :}
   t tu T-LABEL
   ROOT$ t tu WANT expected AR @ LOCAL:INSTALL-DOWNLOAD INSTALL$ ;

: PREPARE ( ^u8 n ^u8 n -- ^u8 n ^u8 n )
   {: t:^ tu:n c:^ cu:n :}
   t tu T-LABEL
   ROOT$ t tu c cu HASH-OF AR @ LOCAL:PREPARE-REPLACEMENT PREPARATION$ ;

: ABSENT-INSTALL ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   TARGET s" local" PUT-FILE
   TARGET NO-CONTENT INSTALL
   s" local" IDENTITY T$= s" precondition-changed" T$=
   TARGET READ$ s" local" T$= ;

: ABSENT-INSTALL-NEVER-OVERWRITES-AN-EXISTING-FILE ( -- )
   s" absent_install_never_overwrites_an_existing_file" T-LABEL
   [: ABSENT-INSTALL ;] IN-CASE-DIR ;

: OPEN-WRITE-AT ( fd ^u8 n -- fd )
   FS:TRY-OPEN-WRITE-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MUTATED-STAGE ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   TARGET STAGE-NAME$ {: sn:^ snu:n :}
   sn snu AT FS:MODE-PRIVATE-FILE FS:CHMOD-MODE
   root sn snu OPEN-WRITE-AT {: w:fd :}
   [: root ROOT$ TARGET WANT AR @ w LOCAL:INSTALL-RENAME-MUTATED ;]
   [: w FS:CLOSE-DIR ;] finally
   root TARGET LOCAL:ENTRY-EXISTS-AT TFALSE
   sn snu READ$ s" mutant" T$= ;

\ The stage is verified, then changed through a writer opened before it
\ was sealed; the rename refuses it and leaves both names as they are.
: INSTALL-REJECTS-STAGE-CHANGED-THROUGH-A-PREEXISTING-WRITER ( -- )
   s" install_rejects_stage_changed_through_a_preexisting_writer" T-LABEL
   [: MUTATED-STAGE ;] IN-CASE-DIR ;

64 BUFFER: XATTR-BUF

: PARTIAL? ( fd -- bool )
   LOCAL:DOWNLOAD-PARTIAL-XATTR XATTR-BUF 64 SPAN:MAKE XATTR:GET
   MATCH XATTR:got
      absent OF false ENDOF
      value OF drop true ENDOF
      oversize OF true ENDOF
   ;MATCH ;

: INSTALLED-BYTES ( -- ^u8 n ) s" installed bytes" ;
: INSTALLED-MARKER ( -- ^u8 n )
   TARGET INSTALLED-BYTES HASH-OF AR @ LOCAL:STAGE-MARKER ;

\ The download slot words are not LOCAL's yet: the partial marker holds
\ bytes no slot state decodes, which cleanup removes all the same.
: MARK-INSTALLED ( fd -- )
   {: f:fd :}
   f LOCAL:DOWNLOAD-PARTIAL-XATTR s" slot state" true TARGET
   s" test mark" LOCAL:SET-XATTR
   f LOCAL:DOWNLOAD-STAGE-XATTR INSTALLED-MARKER true TARGET
   s" test mark" LOCAL:SET-XATTR
   f $100 FD:MODE! f FD:SYNC ;

: REMOVE-PARTIAL ( fd -- )
   {: f:fd :}
   f FS:MODE-PRIVATE-FILE FD:MODE!
   f LOCAL:DOWNLOAD-PARTIAL-XATTR XATTR:ERASE f FD:SYNC ;

: SYNC-INSTALLED ( fd -- )
   TARGET TARGET INSTALLED-BYTES HASH-OF AR @
   LOCAL:SYNC-INSTALLED-DOWNLOAD ;

: CLEANED-UP ( fd fd -- )
   {: root:fd f:fd :}
   root SYNC-INSTALLED
   f INSTALLED-MARKER TARGET LOCAL:MARKER$ s" missing" T$=
   f PARTIAL? TFALSE
   f FS:FD-STAT FS:STAT-MODE@ FS:MODE-PRIVATE-FILE and
   FS:MODE-PRIVATE-FILE T=
   root SYNC-INSTALLED ;

: PARTIAL-CLEANUP ( fd bool -- )
   {: root:fd removed:bool :}
   TARGET INSTALLED-BYTES PUT-FILE
   root TARGET OPEN-WRITE-AT {: f:fd :}
   [: f MARK-INSTALLED
      removed if f REMOVE-PARTIAL else f PARTIAL? TTRUE then
      f INSTALLED-MARKER TARGET LOCAL:MARKER$ s" expected" T$=
      root f CLEANED-UP ;]
   [: f FS:CLOSE-DIR ;] finally ;

: INSTALLED-DOWNLOAD-CLEANUP-REPLAYS-AROUND-PARTIAL-MARKER-REMOVAL ( -- )
   s" installed_download_cleanup_replays_around_partial_marker_removal"
   T-LABEL
   [: false PARTIAL-CLEANUP ;] IN-CASE-DIR
   [: true PARTIAL-CLEANUP ;] IN-CASE-DIR ;

: UNMARKED-RENAME ( fd -- )
   {: root:fd :}
   TARGET s" remote" PUT-FILE
   root TARGET OPEN-AT {: f:fd :}
   [: f root TARGET WANT AR @ LOCAL:RENAMED-WITHOUT-MARKER
      root TARGET TARGET WANT AR @ LOCAL:SYNC-INSTALLED-DOWNLOAD ;]
   [: f FS:CLOSE-DIR ;] finally ;

: RENAMED-DOWNLOAD-REQUIRES-ITS-OWNERSHIP-MARKER ( -- )
   s" renamed_download_requires_its_ownership_marker" T-LABEL
   [: UNMARKED-RENAME ;] IN-CASE-DIR ;

\ An absent target: none staged, then installed and installed again.
: ABSENT-OUTCOMES ( fd -- )
   {: root:fd :}
   TARGET NO-CONTENT INSTALL s" " T$= s" download-required" T$=
   s" missing/target.txt" NO-CONTENT INSTALL
   s" " T$= s" download-required" T$=
   root TARGET STAGE-REMOTE
   TARGET NO-CONTENT INSTALL s" " T$= s" installed" T$=
   TARGET READ$ s" remote" T$=
   root TARGET STAGE-NAME$ LOCAL:ENTRY-EXISTS-AT TFALSE
   TARGET AT FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ $1FF and FS:MODE-PRIVATE-FILE T=
   TARGET NO-CONTENT INSTALL s" " T$= s" already-installed" T$= ;

: OCCUPIED-STAGE ( -- )
   s" other.txt" STAGE-NAME$ {: sn:^ snu:n :}
   sn snu s" mutant" PUT-FILE
   s" other.txt" NO-CONTENT INSTALL
   sn snu AT T$= s" stage-destination-occupied" T$= ;

\ A replacement installs over the content expected and keeps any other.
: REPLACEMENT-OUTCOMES ( fd -- )
   {: root:fd :}
   s" old.txt" s" local" PUT-FILE
   root s" old.txt" STAGE-REMOTE
   s" old.txt" s" local" HELD INSTALL s" " T$= s" installed" T$=
   s" old.txt" READ$ s" remote" T$=
   root s" old.txt" s" local" HASH-OF AR @ LOCAL:GUARD-NAME
   LOCAL:ENTRY-EXISTS-AT TFALSE
   s" edited.txt" s" edit" PUT-FILE
   root s" edited.txt" STAGE-REMOTE
   s" edited.txt" s" local" HELD INSTALL
   s" edit" IDENTITY T$= s" precondition-changed" T$=
   s" edited.txt" READ$ s" edit" T$= ;

: INSTALL-CASES ( fd -- )
   {: root:fd :}
   root ABSENT-OUTCOMES OCCUPIED-STAGE root REPLACEMENT-OUTCOMES ;

: EACH-INSTALL-OUTCOME-IS-REACHED ( -- )
   s" each install outcome is reached" T-LABEL
   [: INSTALL-CASES ;] IN-CASE-DIR ;

: PREPARE-CASES ( fd -- )
   {: root:fd :}
   s" prep.txt" s" old" PUT-FILE
   s" prep.txt" s" old" PREPARE s" " T$= s" prepared" T$=
   root s" prep.txt" LOCAL:ENTRY-EXISTS-AT TFALSE
   s" prep.txt" s" old" HASH-OF AR @ LOCAL:GUARD-NAME READ$ s" old" T$=
   s" prep.txt" s" old" PREPARE s" " T$= s" already-prepared" T$=
   s" other.txt" s" new" PUT-FILE
   s" other.txt" s" old" PREPARE
   s" new" IDENTITY T$= s" precondition-changed" T$=
   s" other.txt" READ$ s" new" T$=
   s" absent.txt" s" old" PREPARE
   s" none" T$= s" precondition-changed" T$=
   s" missing/file.txt" s" old" PREPARE
   s" none" T$= s" precondition-changed" T$= ;

: EACH-REPLACEMENT-PREPARATION-IS-REACHED ( -- )
   s" each replacement preparation is reached" T-LABEL
   [: PREPARE-CASES ;] IN-CASE-DIR ;

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
   ABSENT-INSTALL-NEVER-OVERWRITES-AN-EXISTING-FILE
   INSTALL-REJECTS-STAGE-CHANGED-THROUGH-A-PREEXISTING-WRITER
   INSTALLED-DOWNLOAD-CLEANUP-REPLAYS-AROUND-PARTIAL-MARKER-REMOVAL
   RENAMED-DOWNLOAD-REQUIRES-ITS-OWNERSHIP-MARKER
   EACH-INSTALL-OUTCOME-IS-REACHED
   EACH-REPLACEMENT-PREPARATION-IS-REACHED ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
