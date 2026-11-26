---- MODULE ReleaseWindowCloseFollows ----
\* Follows: every step that moves the closed window takes the line of
\* CLOSING for Heard and moves where that line says. The ASSUME fails
\* the check on a line whose input no sense answers.
EXTENDS ReleaseWindow
T == INSTANCE ReleaseWindowCloseTable
ASSUME \A l \in T!Lines :
    \E g \in Signals, c \in Codes \cup {None}, r \in Codes :
        Hears(g, c, r) = l[2]
Follows ==
    [][ state = "closed" /\ state' # state =>
        <<state, Heard, state'>> \in T!Lines ]_vars
====
