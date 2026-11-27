---- MODULE UploadSessionFollows ----
\* Follows: every step of UploadSession is a line of SESSION and every
\* line's step moves as the line says. The model's states are the table's
\* and it has no step outside the table.
EXTENDS UploadSession
T == INSTANCE UploadSessionTable
Walks(l) ==
    CASE l[1] = "single" -> Send(l[2])
      [] l[1] = "starting" -> Start(l[2])
      [] l[1] = "appending" -> Append(l[2])
      [] l[1] = "checkpointing" -> Checkpoint(l[2])
      [] l[1] = "finishing" -> Finish(l[2])
      [] l[1] = "verifying" -> Confirm(l[2])
      [] l[1] = "confirming" -> Confirming(l[2])
      [] l[1] = "restarting" -> Restart(l[2])
Line(l) == step = l[1] /\ step' = l[3]
Follows ==
    [][ /\ \E l \in T!Lines : Line(l) /\ Walks(l)
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
