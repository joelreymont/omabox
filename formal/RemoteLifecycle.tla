--------------------------- MODULE RemoteLifecycle ---------------------------
\* One plan's operations replayed against Dropbox one pass at a time, as
\* REMOTE-LIFECYCLE and REPLAY-REMOTE-PLAN in src/replay.f run them: a
\* completed operation passes, a pending one is applied, and one blocked or
\* local ends its plan's turn. run is each operation's state in the
\* table, "out" outside a pass.

EXTENDS Naturals

\* A local operation, then two Dropbox ones, so that every line has an
\* operation after it. Only the last can finish its plan as a conflict:
\* every operation that can is its plan's last.
N == 3
Ops == 1..N
Local == {1}

VARIABLES status, plan, remote, run

vars == <<status, plan, remote, run>>

\* Retiring a plan completes all its operations.
AllCompleted == [i \in Ops |-> "Completed"]

Init ==
    /\ status = [i \in Ops |-> "Pending"]
    /\ plan = "Pending"
    /\ remote = [i \in Ops |-> "Before"]
    /\ run = [i \in Ops |-> "out"]

Begin ==
    /\ plan = "Pending"
    /\ \A i \in Ops : run[i] = "out"
    /\ run' = [run EXCEPT ![1] = "recorded"]
    /\ UNCHANGED <<status, plan, remote>>

Advance(i) ==
    /\ i + 1 \in Ops
    /\ run[i] = "passed"
    /\ run[i + 1] = "out"
    /\ run' = [run EXCEPT ![i + 1] = "recorded"]
    /\ UNCHANGED <<status, plan, remote>>

Skip(i) ==
    /\ run[i] = "recorded"
    /\ status[i] = "Completed"
    /\ run' = [run EXCEPT ![i] = "passed"]
    /\ UNCHANGED <<status, plan, remote>>

Apply(i) ==
    /\ run[i] = "recorded"
    /\ status[i] = "Pending"
    /\ run' = [run EXCEPT ![i] = "applying"]
    /\ UNCHANGED <<status, plan, remote>>

\* Dropbox applies the conditional mutation, and the pass ends before the
\* journal hears of it.
Send(i) ==
    /\ run[i] = "applying"
    /\ i \notin Local
    /\ remote[i] = "Before"
    /\ remote' = [remote EXCEPT ![i] = "After"]
    /\ UNCHANGED <<status, plan, run>>

\* Dropbox applies the mutation, or holds a resent one's effect already;
\* the journal completes the operation at once, the last one its plan.
Complete(i) ==
    /\ run[i] = "applying"
    /\ i \notin Local
    /\ remote[i] \in {"Before", "After"}
    /\ remote' = [remote EXCEPT ![i] = "After"]
    /\ status' = [status EXCEPT ![i] = "Completed"]
    /\ plan' = IF i = N THEN "Completed" ELSE plan
    /\ run' = [run EXCEPT ![i] = "passed"]

\* Another client changed the path: both sides are kept and the plan
\* retires as their conflict.
Conflict(i) ==
    /\ run[i] = "applying"
    /\ i = N
    /\ i \notin Local
    /\ remote[i] = "Other"
    /\ status' = AllCompleted
    /\ plan' = "Retired"
    /\ run' = [run EXCEPT ![i] = "passed"]
    /\ UNCHANGED remote

\* The operation stays pending: its outcome is unknown, or STOP-REMOTE
\* holds the plan until a retry time, which this model, without a clock,
\* takes as a later pass. Or the plan retires for a fresh observation.
Block(i) ==
    /\ run[i] = "applying"
    /\ i \notin Local
    /\ \/ UNCHANGED <<status, plan>>
       \/ status' = AllCompleted /\ plan' = "Retired"
    /\ run' = [run EXCEPT ![i] = "stopped"]
    /\ UNCHANGED remote

Yield(i) ==
    /\ run[i] = "applying"
    /\ i \in Local
    /\ run' = [run EXCEPT ![i] = "yielded"]
    /\ UNCHANGED <<status, plan, remote>>

\* The pass ends: its last operation passed, one stopped or yielded, a
\* call threw, or the daemon stopped.
End ==
    /\ \E i \in Ops : run[i] # "out"
    /\ run' = [i \in Ops |-> "out"]
    /\ UNCHANGED <<status, plan, remote>>

\* Between passes, local replay completes a local operation whose
\* predecessors completed.
LocalReplay(i) ==
    /\ i \in Local
    /\ plan = "Pending"
    /\ status[i] = "Pending"
    /\ \A j \in Ops : run[j] = "out" /\ (j < i => status[j] = "Completed")
    /\ status' = [status EXCEPT ![i] = "Completed"]
    /\ plan' = IF i = N THEN "Completed" ELSE plan
    /\ UNCHANGED <<remote, run>>

\* Another Dropbox client changes a pending operation's path.
Edit(i) ==
    /\ i \notin Local
    /\ status[i] = "Pending"
    /\ remote[i] # "Other"
    /\ remote' = [remote EXCEPT ![i] = "Other"]
    /\ UNCHANGED <<status, plan, run>>

\* The steps REMOTE-LIFECYCLE's lines take on operation i. The pass,
\* Dropbox, local replay and another client act outside them.
Run(i) ==
    \/ Skip(i) \/ Apply(i) \/ Complete(i) \/ Conflict(i) \/ Block(i)
    \/ Yield(i)

Next ==
    \/ Begin
    \/ End
    \/ \E i \in Ops :
        \/ Run(i) \/ Advance(i) \/ Send(i) \/ LocalReplay(i) \/ Edit(i)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ status \in [Ops -> {"Pending", "Completed"}]
    /\ plan \in {"Pending", "Completed", "Retired"}
    /\ remote \in [Ops -> {"Before", "After", "Other"}]
    /\ run \in [Ops -> {"out", "recorded", "applying", "passed", "stopped",
                        "yielded"}]

\* A pass skips a completed operation: the journal completes one only once
\* Dropbox holds its effect, or when its plan retired.
CompletionFollowsEffect ==
    \A i \in Ops \ Local :
        status[i] = "Completed" => remote[i] = "After" \/ plan = "Retired"

\* An operation that stops or yields holds back the rest of its plan.
OperationsInOrder ==
    \A i, j \in Ops : i < j /\ remote[j] = "After" => status[i] = "Completed"

\* Nothing reaches Dropbox for a plan that completed or retired.
PendingSends ==
    \A i \in Ops :
        remote[i] # "After" /\ remote'[i] = "After" => plan = "Pending"

OnlyPendingPlansSend == [][PendingSends]_vars

=============================================================================
