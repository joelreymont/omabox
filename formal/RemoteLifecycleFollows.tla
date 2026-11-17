---- MODULE RemoteLifecycleFollows ----
\* Follows: every step that moves an operation between the table's states
\* is a line of REMOTE-LIFECYCLE and every line's step moves as the line
\* says. Out is an operation outside a pass: not reached yet, or its pass
\* ended; a pass enters each operation at First.
EXTENDS RemoteLifecycle
T == INSTANCE RemoteLifecycleTable
Out == "out"
First == "recorded"
At(i) == run[i]
Walks(l, i) ==
    CASE l = <<"recorded", "completed", "passed">> -> Skip(i)
      [] l = <<"recorded", "pending", "applying">> -> Apply(i)
      [] l = <<"applying", "done", "passed">> -> Complete(i) \/ Conflict(i)
      [] l = <<"applying", "blocked", "stopped">> -> Block(i)
      [] l = <<"applying", "local", "yielded">> -> Yield(i)
Line(l, i) == At(i) = l[1] /\ At(i)' = l[3]
Follows ==
    [][ \A i \in Ops :
          /\ At(i)' # At(i) => \/ \E l \in T!Lines : Line(l, i) /\ Walks(l, i)
                               \/ At(i)' = Out
                               \/ At(i) = Out /\ At(i)' = First
          /\ \A l \in T!Lines : Walks(l, i) => Line(l, i) ]_vars
====
