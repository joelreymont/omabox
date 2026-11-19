---------------------------- MODULE LocalLifecycle ----------------------------
\* One pending plan's local replay: each pass runs LOCAL-LIFECYCLE
\* (src/replay.f) on the plan's operations in order. A completed one
\* passes; a pending one is applied, and passes or stops the plan. Op 1
\* stands for a non-final operation, a legacy preservation, which completes
\* at once; op Last is the final one, whose completion the pass holds and
\* commits once the plan's run ends. What APPLY answers is the
\* environment's choice; MutationLifecycle models how it gets there.

EXTENDS Naturals

Last == 2
Ops == 1..Last

VARIABLES status, baseline, confirmed, held, op, phase

vars == <<status, baseline, confirmed, held, op, phase>>

Init ==
    /\ status = [i \in Ops |-> "pending"]
    /\ baseline = "old"
    /\ confirmed = FALSE
    /\ held = FALSE
    /\ op = 1
    /\ phase = "out"

\* A pass takes the plan while its final operation is pending.
Begin ==
    /\ phase = "out"
    /\ status[Last] = "pending"
    /\ op' = 1
    /\ phase' = "recorded"
    /\ UNCHANGED <<status, baseline, confirmed, held>>

\* STATUS: a completed operation passes.
Skip ==
    /\ phase = "recorded"
    /\ status[op] = "completed"
    /\ phase' = "passed"
    /\ UNCHANGED <<status, baseline, confirmed, held, op>>

\* STATUS: a pending operation is applied.
Enter ==
    /\ phase = "recorded"
    /\ status[op] = "pending"
    /\ phase' = "applying"
    /\ UNCHANGED <<status, baseline, confirmed, held, op>>

\* APPLY confirms the effect: a non-final operation completes at once;
\* the final one's completion is held for the pass's commit.
Done ==
    /\ phase = "applying"
    /\ phase' = "passed"
    /\ IF op < Last
       THEN /\ status' = [status EXCEPT ![op] = "completed"]
            /\ UNCHANGED <<confirmed, held>>
       ELSE /\ confirmed' = TRUE
            /\ held' = TRUE
            /\ UNCHANGED status
    /\ UNCHANGED <<baseline, op>>

\* APPLY blocks the plan, which stays pending.
Block ==
    /\ phase = "applying"
    /\ phase' = "stopped"
    /\ UNCHANGED <<status, baseline, confirmed, held, op>>

\* APPLY finds the path needs a fresh observation and retires the plan:
\* every operation completed, the baseline as it was.
Retire ==
    /\ phase = "applying"
    /\ status' = [i \in Ops |-> "completed"]
    /\ phase' = "stopped"
    /\ UNCHANGED <<baseline, confirmed, held, op>>

\* REPLAY-PLAN: the next operation, once this one passed.
Advance ==
    /\ phase = "passed"
    /\ op < Last
    /\ op' = op + 1
    /\ phase' = "recorded"
    /\ UNCHANGED <<status, baseline, confirmed, held>>

\* COMMIT-PASS, once the plan's run ended: the held completion completes
\* the plan and writes its baseline in one transaction.
Commit ==
    /\ \/ phase = "stopped"
       \/ phase = "passed" /\ op = Last
    /\ IF held
       THEN /\ status' = [status EXCEPT ![Last] = "completed"]
            /\ baseline' = "new"
       ELSE UNCHANGED <<status, baseline>>
    /\ held' = FALSE
    /\ phase' = "out"
    /\ UNCHANGED <<confirmed, op>>

\* A crash, or a failure the pass passes up, ends it: the held completion
\* is lost; the journal and the disk stay.
Crash ==
    /\ phase # "out"
    /\ held' = FALSE
    /\ phase' = "out"
    /\ UNCHANGED <<status, baseline, confirmed, op>>

\* The steps LOCAL-LIFECYCLE's lines take on op. The pass begins,
\* advances, commits and crashes outside them.
Run == Skip \/ Enter \/ Done \/ Block \/ Retire

Next == Run \/ Begin \/ Advance \/ Commit \/ Crash

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ status \in [Ops -> {"pending", "completed"}]
    /\ baseline \in {"old", "new"}
    /\ confirmed \in BOOLEAN
    /\ held \in BOOLEAN
    /\ op \in Ops
    /\ phase \in {"out", "recorded", "applying", "passed", "stopped"}

\* Only a plan's first pending operation is applied. The journal refuses
\* a completion while an earlier operation is pending, and
\* COMPLETE-NONFINAL and CHECK-FINAL throw that as invalid state, so a
\* held completion finds every earlier one completed too.
InOrder ==
    /\ phase = "applying" =>
          /\ status[op] = "pending"
          /\ \A k \in 1..(op - 1) : status[k] = "completed"
    /\ held => \A k \in 1..(Last - 1) : status[k] = "completed"

\* The baseline advances only with the final operation's completion, and
\* only once an APPLY confirmed its effect.
BaselineFollowsEffect ==
    baseline = "new" => confirmed /\ status[Last] = "completed"

=============================================================================
