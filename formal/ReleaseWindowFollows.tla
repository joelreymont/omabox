---- MODULE ReleaseWindowFollows ----
\* Follows: every step that moves the window out of an open state takes
\* the line of RELEASING for its state and Input and moves where that
\* line says; a signal's arrival moves no state. The ASSUME fails the
\* check on a line whose input no sense answers.
EXTENDS ReleaseWindow
T == INSTANCE ReleaseWindowTable
ASSUME \A l \in T!Lines :
    \E k \in Codes, g \in Signals : Outcome(k, g) = l[2]
Follows ==
    [][ (state \in Open /\ state' # state) =>
        <<state, Input, state'>> \in T!Lines ]_vars
====
