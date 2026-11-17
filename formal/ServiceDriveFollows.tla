---- MODULE ServiceDriveFollows ----
\* Follows: every step of a drive takes the line of DRIVING for its phase
\* and Step and moves where that line says, or throws, which leaves the
\* table for "failed". The ASSUME fails the check on a line whose input
\* Due never answers from its state.
EXTENDS ServiceDrive
T == INSTANCE ServiceDriveTable
ASSUME \A l \in T!Lines :
    \E g \in Goals, b \in Option, u \in Option : Due(l[1], g, b, u) = l[2]
Follows ==
    [][ phase' = "failed" \/ <<phase, Step, phase'>> \in T!Lines ]_vars
====
