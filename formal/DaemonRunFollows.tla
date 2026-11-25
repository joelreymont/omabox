---- MODULE DaemonRunFollows ----
\* Follows: every step of DaemonRun is a line of DAEMON-RUN and every
\* line's step moves as the line says. The model's states are the table's
\* and it has no step outside the table.
EXTENDS DaemonRun
T == INSTANCE DaemonRunTable
Walks(l) ==
    CASE l[2] = "ok" /\ l[1] \in DOMAIN After -> state = l[1] /\ Ok
      [] l[2] = "ok" /\ l[1] = "polling" -> state = l[1] /\ Cycle
      [] l[2] \in {"clean", "dirty"} /\ l[1] = "syncing" -> Complete
      [] l[2] = "rested" /\ l[1] = "syncing" -> Rest
      [] l[2] = "fresh" /\ l[1] = "syncing" -> Fresh
      [] l[2] \in {"changed", "due"} -> state = l[1] /\ Cycle
      [] l[2] = "quiet" /\ l[1] = "settling" -> state = l[1] /\ Cycle
      [] l[2] = "quiet" /\ l[1] = "resting" -> state = l[1] /\ Wait
      [] l[2] = "heard" -> state = l[1] /\ Wait
      [] l[2] = "stirred" -> state = l[1] /\ Stir
      [] l[2] = "retry" /\ l[1] \in Tried -> state = l[1] /\ Retry
      [] l[2] = "stop" /\ l[1] \in Tried -> state = l[1] /\ Stop
Line(l) == state = l[1] /\ state' = l[3]
Follows ==
    [][ /\ \E l \in T!Lines : Line(l) /\ Walks(l)
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
