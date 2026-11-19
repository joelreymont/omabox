---- MODULE LocalLifecycleFollows ----
\* Follows: every step that moves an operation between the table's
\* states, and every step of the table's lines on the operation (Run on
\* op), one that keeps its state included, is a line of LOCAL-LIFECYCLE,
\* and every line's step moves as the line says. Out is an operation
\* outside a run: not yet reached in the pass, or its run ended by the
\* next operation, the commit or a crash; the pass enters each at First.
EXTENDS LocalLifecycle
T == INSTANCE LocalLifecycleTable
Out == "out"
First == "recorded"
At(i) == IF i = op THEN phase ELSE Out
Walks(l, i) ==
    CASE l = <<"recorded", "completed", "passed">> -> Skip /\ op = i
      [] l = <<"recorded", "pending", "applying">> -> Enter /\ op = i
      [] l = <<"applying", "done", "passed">> -> Done /\ op = i
      [] l = <<"applying", "blocked", "stopped">> ->
            (Block \/ Retire) /\ op = i
Line(l, i) == At(i) = l[1] /\ At(i)' = l[3]
Follows ==
    [][ \A i \in Ops :
          /\ (At(i)' # At(i) \/ (Run /\ op = i)) =>
                \/ \E l \in T!Lines : Line(l, i) /\ Walks(l, i)
                \/ At(i)' = Out
                \/ At(i) = Out /\ At(i)' = First
          /\ \A l \in T!Lines : Walks(l, i) => Line(l, i) ]_vars
====
