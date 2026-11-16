\ omaboxd.f - the omaboxd program (rust src/bin/omaboxd.rs), whose
\ global MAIN is the build's entry. `--self-check` alone prints the
\ program's name and version and exits 0, reading nothing first: the
\ installer runs it to check the program it installed. Any other
\ arguments run the daemon, which systemd starts, and exit with its
\ status.
require src/lib/string.f
require src/daemon.f

package OMABOXD
private

\ rust Cargo.toml's package version.
: VERSION ( -- ^u8 n ) s" 0.1.0" ;

: SELF-CHECK? ( -- bool )
   SCRIPT-ARGC 1 <> if false exit then
   0 SCRIPT-ARGV$ s" --self-check" STR= ;

: SELF-CHECK ( -- ) s" omaboxd " type VERSION type cr ;

public

: RUN ( -- )
   SELF-CHECK? if SELF-CHECK exit then
   s" " DAEMON:RUN die ;

;package

: MAIN ( -- ) OMABOXD:RUN ;
