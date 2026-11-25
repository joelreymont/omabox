---- MODULE LocalWatchFollows ----
\* Follows: every step of the watch takes the line of WATCHING for its
\* state and event and moves where that line says; a move that steps
\* nothing keeps the state. The ASSUME fails the check unless the table
\* is exactly the model's machine, a line for each state and event.
EXTENDS LocalWatch
T == INSTANCE LocalWatchTable
ASSUME \A s \in States, e \in Events : <<s, e, Moved(s, e)>> \in T!Lines
ASSUME \A l \in T!Lines :
    l[1] \in States /\ l[2] \in Events /\ l[3] = Moved(l[1], l[2])
Follows ==
    [][ IF ev' = None THEN state' = state
        ELSE <<state, ev', state'>> \in T!Lines ]_vars
====
