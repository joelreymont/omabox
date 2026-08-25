--------------------------- MODULE DownloadExecutor ---------------------------

EXTENDS FiniteSets, Naturals, TLC

CONSTANTS Paths, Workers, Slots

ASSUME /\ Cardinality(Paths) = 3
       /\ Cardinality(Workers) = 2
       /\ Cardinality(Slots) = 2

NoPath == "NoPath"
JobStates == {
    "Pending", "Queued", "Active", "Staged",
    "Installed", "Failed", "Cancelled", "Completed"
}
PlanStates == {"Pending", "Completed"}

VARIABLES job, plan, workerPath, slotPath, cancelled, failure, running

vars == <<job, plan, workerPath, slotPath, cancelled, failure, running>>

Init ==
    /\ job = [path \in Paths |-> "Pending"]
    /\ plan = [path \in Paths |-> "Pending"]
    /\ workerPath = [worker \in Workers |-> NoPath]
    /\ slotPath = [slot \in Slots |-> NoPath]
    /\ cancelled = FALSE
    /\ failure = FALSE
    /\ running = TRUE

Queue(path) ==
    /\ running
    /\ ~cancelled
    /\ job[path] = "Pending"
    /\ job' = [job EXCEPT ![path] = "Queued"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running>>

Start(path, worker, slot) ==
    /\ running
    /\ ~cancelled
    /\ job[path] = "Queued"
    /\ workerPath[worker] = NoPath
    /\ slotPath[slot] = NoPath
    /\ job' = [job EXCEPT ![path] = "Active"]
    /\ workerPath' = [workerPath EXCEPT ![worker] = path]
    /\ slotPath' = [slotPath EXCEPT ![slot] = path]
    /\ UNCHANGED <<plan, cancelled, failure, running>>

Release(path) ==
    /\ workerPath' = [worker \in Workers |->
        IF workerPath[worker] = path THEN NoPath ELSE workerPath[worker]]
    /\ slotPath' = [slot \in Slots |->
        IF slotPath[slot] = path THEN NoPath ELSE slotPath[slot]]

FinishSuccess(path) ==
    /\ running
    /\ job[path] = "Active"
    /\ job' = [job EXCEPT ![path] = "Staged"]
    /\ Release(path)
    /\ UNCHANGED <<plan, cancelled, failure, running>>

FinishFailure(path) ==
    /\ running
    /\ job[path] = "Active"
    /\ job' = [job EXCEPT ![path] = "Failed"]
    /\ Release(path)
    /\ cancelled' = TRUE
    /\ failure' = TRUE
    /\ UNCHANGED <<plan, running>>

CancelQueued(path) ==
    /\ running
    /\ cancelled
    /\ job[path] = "Queued"
    /\ job' = [job EXCEPT ![path] = "Cancelled"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running>>

Install(path) ==
    /\ running
    /\ job[path] = "Staged"
    /\ job' = [job EXCEPT ![path] = "Installed"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running>>

Complete(path) ==
    /\ running
    /\ job[path] = "Installed"
    /\ job' = [job EXCEPT ![path] = "Completed"]
    /\ plan' = [plan EXCEPT ![path] = "Completed"]
    /\ UNCHANGED <<workerPath, slotPath, cancelled, failure, running>>

ReportFailure ==
    /\ running
    /\ cancelled
    /\ failure
    /\ \A path \in Paths: job[path] \notin {"Queued", "Active"}
    /\ job' = [path \in Paths |->
        IF job[path] \in {"Failed", "Cancelled"} THEN "Pending" ELSE job[path]]
    /\ cancelled' = FALSE
    /\ failure' = FALSE
    /\ UNCHANGED <<plan, workerPath, slotPath, running>>

Crash ==
    /\ running
    /\ job' = [path \in Paths |->
        IF job[path] \in {"Queued", "Active", "Failed", "Cancelled"}
        THEN "Pending"
        ELSE job[path]]
    /\ workerPath' = [worker \in Workers |-> NoPath]
    /\ slotPath' = [slot \in Slots |-> NoPath]
    /\ cancelled' = FALSE
    /\ failure' = FALSE
    /\ running' = FALSE
    /\ UNCHANGED plan

Restart ==
    /\ ~running
    /\ running' = TRUE
    /\ UNCHANGED <<job, plan, workerPath, slotPath, cancelled, failure>>

Next ==
    \/ \E path \in Paths: Queue(path)
    \/ \E path \in Paths, worker \in Workers, slot \in Slots:
        Start(path, worker, slot)
    \/ \E path \in Paths: FinishSuccess(path)
    \/ \E path \in Paths: FinishFailure(path)
    \/ \E path \in Paths: CancelQueued(path)
    \/ \E path \in Paths: Install(path)
    \/ \E path \in Paths: Complete(path)
    \/ ReportFailure
    \/ Crash
    \/ Restart

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ job \in [Paths -> JobStates]
    /\ plan \in [Paths -> PlanStates]
    /\ workerPath \in [Workers -> Paths \cup {NoPath}]
    /\ slotPath \in [Slots -> Paths \cup {NoPath}]
    /\ cancelled \in BOOLEAN
    /\ failure \in BOOLEAN
    /\ running \in BOOLEAN

UniqueAssignments ==
    /\ \A path \in Paths:
        Cardinality({worker \in Workers: workerPath[worker] = path}) <= 1
    /\ \A path \in Paths:
        Cardinality({slot \in Slots: slotPath[slot] = path}) <= 1

ActiveAssignments ==
    /\ \A path \in Paths:
        (job[path] = "Active")
        <=> Cardinality({worker \in Workers: workerPath[worker] = path}) = 1
    /\ \A path \in Paths:
        (job[path] = "Active")
        <=> Cardinality({slot \in Slots: slotPath[slot] = path}) = 1

BoundedConcurrency ==
    /\ Cardinality({path \in Paths: job[path] = "Active"})
        <= Cardinality(Workers)
    /\ Cardinality({path \in Paths: job[path] = "Active"})
        <= Cardinality(Slots)

PlansAuthorizeWork ==
    \A path \in Paths:
        (job[path] = "Completed") <=> (plan[path] = "Completed")

CancellationHasFailure == cancelled => failure

CompletedStable ==
    \A path \in Paths:
        job[path] = "Completed" => job'[path] = "Completed"

StagedStable ==
    \A path \in Paths:
        job[path] = "Staged" => job'[path] \in {"Staged", "Installed"}

CompletedIsStable == [][CompletedStable]_vars

StagedWorkIsPreserved == [][StagedStable]_vars

=============================================================================
