\ omaboxd.f - the omaboxd program (rust src/bin/omaboxd.rs), whose
\ global MAIN is the build's entry. `--self-check` alone prints the
\ program's name and version and exits 0, reading nothing first, or
\ fails when the line cannot be written: the installer runs it to check
\ the program it installed. Any other arguments run the daemon, which
\ systemd starts, and exit with its status.
require src/lib/string.f
require src/lib/fd.f
require src/daemon.f
require src/version.f

package OMABOXD
private

: SELF-CHECK? ( -- bool )
   SCRIPT-ARGC 1 <> if false exit then
   0 SCRIPT-ARGV$ s" --self-check" STR= ;

\ A write the reader cannot take throws, as Rust's println! panics.
: SELF-CHECK ( -- )
   SB-RESET s" omaboxd " SB-APPEND RELEASE:VERSION$ SB-APPEND 10 SB-APPEND-C
   SB$ {: a:^ u:n :}
   FD:STDOUT [: FD:STDOUT a u FD:WRITE-FULL ;] FD:WITH-NOSIGPIPE ;

public

: RUN ( -- )
   SELF-CHECK? if SELF-CHECK exit then
   s" " DAEMON:RUN die ;

;package

: MAIN ( -- ) OMABOXD:RUN ;
