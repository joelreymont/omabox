\ local-test.f - LOCAL's shared words: local.rs's tests that an entry's
\ existence below the root never follows a symlink and takes a failed probe
\ as unconfirmed, that the content hash composes block hashes, and the
\ hashing half of its test that the hash does not depend on how a reader
\ fragments the bytes. The case that makes files works in its own
\ directory under TMPDIR and removes it.
\ Run from the repository root: hb --load src/local-test.f </dev/null
require src/lib/test.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/property.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/dropbox.f
require src/local.f

\ LOCAL reopened for the stream a fragmenting reader feeds.
package LOCAL
public
EXPORT HASH-STREAM
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

\ Case i takes length arm i mod 9 and schedule arm i mod 3.
: FRAGMENTED ( ^u8 n -- )
   {: bytes:^ i:n :}
   i 9 mod LENGTH {: u:n :}
   i 3 mod SCHEDULE
   bytes u 256 PROP:RND% PATTERNED
   bytes u REFERENCE {: want:^ wu:n :}
   bytes u START
   [: FRAGMENT ;] AR @ LOCAL:HASH-STREAM DROPBOX:HASH>STR str>
   want wu T$= ;

\ The hashing half of local.rs's property; its copy half waits for
\ copy_and_hash. Twelve cases, as proptest's, from a fixed seed.
: DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION ( -- )
   s" dropbox_hash_and_copy_are_independent_of_reader_fragmentation" T-LABEL
   1 PROP:SEED!
   BLOCK 2 * 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: bytes:^ cap:NUM:alloc-byte-len :}
   [: 12 0 ?do bytes i FRAGMENTED loop ;]
   [: bytes cap MEM:RELEASE-BYTES ;] finally ;

: CASES ( -- )
   ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION
   DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
