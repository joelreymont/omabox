---- MODULE DownloadExecutorFollows ----
\* Follows: every step that moves a path between the table's states, and
\* every step of the table's lines on a path (Run), one that keeps its
\* state included, is a line of DOWNLOAD-EXECUTOR, and every line's step
\* moves as the line says.
\* Out is a path outside a run: not yet queued, failed, cancelled, reset by
\* a crash or a lifted block, or installed by a later pass from the stage a
\* run left unrooted; a queued job enters at First.
EXTENDS DownloadExecutor
T == INSTANCE DownloadExecutorTable
Out == "out"
First == "queued"
At(p) ==
    IF p \in unrooted
    THEN IF job[p] = "Staged" THEN "unrooted" ELSE Out
    ELSE CASE job[p] \in {"Queued", "Active"} -> "queued"
           [] job[p] = "Staged" -> "staged"
           [] job[p] \in {"Installed", "Completed"} -> "installed"
           [] job[p] = "Blocked" -> "blocked"
           [] job[p] \in {"Pending", "Failed", "Cancelled"} -> Out
Walks(l, p) ==
    CASE l = <<"queued", "staged", "staged">> -> FinishSuccess(p)
      [] l = <<"queued", "blocked", "blocked">> -> FinishPermanent(p)
      [] l = <<"staged", "active", "installed">> ->
            Install(p) /\ rootActive /\ p \notin unrooted
      [] l = <<"staged", "changed", "unrooted">> -> Unroot(p) /\ ~rootActive
Line(l, p) == At(p) = l[1] /\ At(p)' = l[3]
Follows ==
    [][ \A p \in Paths :
          /\ (At(p)' # At(p) \/ Run(p)) =>
                \/ \E l \in T!Lines : Line(l, p) /\ Walks(l, p)
                \/ At(p)' = Out
                \/ At(p) = Out /\ At(p)' = First
          /\ \A l \in T!Lines : Walks(l, p) => Line(l, p) ]_vars
====
