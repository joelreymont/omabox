--------------------------- MODULE DownloadExecutor ---------------------------

EXTENDS FiniteSets, Naturals, TLC

CONSTANTS Paths, Workers, Slots

ASSUME /\ Cardinality(Paths) = 3
       /\ Cardinality(Workers) = 2
       /\ Cardinality(Slots) = 2

NoPath == "NoPath"
JobStates == {
    "Pending", "Queued", "Active", "Staged",
    "Installed", "Failed", "Blocked", "Cancelled", "Completed"
}
PlanStates == {"Pending", "Blocked", "Completed"}

VARIABLES job, plan, workerPath, slotPath, cancelled, failure, running,
    rootActive, unrooted

vars == <<job, plan, workerPath, slotPath, cancelled, failure, running,
    rootActive, unrooted>>

Init ==
    /\ job = [path \in Paths |-> "Pending"]
    /\ plan = [path \in Paths |-> "Pending"]
    /\ workerPath = [worker \in Workers |-> NoPath]
    /\ slotPath = [slot \in Slots |-> NoPath]
    /\ cancelled = FALSE
    /\ failure = FALSE
    /\ running = TRUE
    /\ rootActive = TRUE
    /\ unrooted = {}

Queue(path) ==
    /\ running
    /\ ~cancelled
    /\ plan[path] = "Pending"
    /\ job[path] = "Pending"
    /\ job' = [job EXCEPT ![path] = "Queued"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running,
        rootActive, unrooted>>

Start(path, worker, slot) ==
    /\ running
    /\ ~cancelled
    /\ job[path] = "Queued"
    /\ workerPath[worker] = NoPath
    /\ slotPath[slot] = NoPath
    /\ job' = [job EXCEPT ![path] = "Active"]
    /\ workerPath' = [workerPath EXCEPT ![worker] = path]
    /\ slotPath' = [slotPath EXCEPT ![slot] = path]
    /\ UNCHANGED <<plan, cancelled, failure, running, rootActive, unrooted>>

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
    /\ UNCHANGED <<plan, cancelled, failure, running, rootActive, unrooted>>

FinishFailure(path) ==
    /\ running
    /\ job[path] = "Active"
    /\ job' = [job EXCEPT ![path] = "Failed"]
    /\ Release(path)
    /\ cancelled' = TRUE
    /\ failure' = TRUE
    /\ UNCHANGED <<plan, running, rootActive, unrooted>>

\* Dropbox rejected the download of this one path outright. The executor
\* records a BlockReason against that plan and stops working on it, without
\* retry and without touching the batch, so unrelated downloads keep running.
\* Blocking at install time is modeled by the replay lane.
FinishPermanent(path) ==
    /\ running
    /\ job[path] = "Active"
    /\ job' = [job EXCEPT ![path] = "Blocked"]
    /\ plan' = [plan EXCEPT ![path] = "Blocked"]
    /\ Release(path)
    /\ UNCHANGED <<cancelled, failure, running, rootActive, unrooted>>

\* The reconciler decides a blocked plan is worth another attempt, either
\* because its retry deadline passed or because the path changed. Until it
\* does, the durable block outlives every crash.
Unblock(path) ==
    /\ running
    /\ plan[path] = "Blocked"
    /\ plan' = [plan EXCEPT ![path] = "Pending"]
    /\ job' = [job EXCEPT ![path] = "Pending"]
    /\ UNCHANGED <<workerPath, slotPath, cancelled, failure, running,
        rootActive, unrooted>>

CancelQueued(path) ==
    /\ running
    /\ cancelled
    /\ job[path] = "Queued"
    /\ job' = [job EXCEPT ![path] = "Cancelled"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running,
        rootActive, unrooted>>

\* A staged download installs only while the configured root is still the
\* journal's active one; otherwise it stays staged and its plan pending.
Install(path) ==
    /\ running
    /\ rootActive
    /\ job[path] = "Staged"
    /\ job' = [job EXCEPT ![path] = "Installed"]
    /\ UNCHANGED <<plan, workerPath, slotPath, cancelled, failure, running,
        rootActive, unrooted>>

\* Before it installs a staged download the executor checks the root; one
\* it finds no longer active it leaves staged, its plan pending, and a
\* later pass under the active root installs it.
Unroot(path) ==
    /\ running
    /\ ~rootActive
    /\ job[path] = "Staged"
    /\ path \notin unrooted
    /\ unrooted' = unrooted \cup {path}
    /\ UNCHANGED <<job, plan, workerPath, slotPath, cancelled, failure,
        running, rootActive>>

Complete(path) ==
    /\ running
    /\ job[path] = "Installed"
    /\ job' = [job EXCEPT ![path] = "Completed"]
    /\ plan' = [plan EXCEPT ![path] = "Completed"]
    /\ UNCHANGED <<workerPath, slotPath, cancelled, failure, running,
        rootActive, unrooted>>

ReportFailure ==
    /\ running
    /\ cancelled
    /\ failure
    /\ \A path \in Paths: job[path] \notin {"Queued", "Active"}
    /\ job' = [path \in Paths |->
        IF job[path] \in {"Failed", "Cancelled"} THEN "Pending" ELSE job[path]]
    /\ cancelled' = FALSE
    /\ failure' = FALSE
    /\ UNCHANGED <<plan, workerPath, slotPath, running, rootActive, unrooted>>

Crash ==
    /\ running
    /\ job' = [path \in Paths |->
        IF job[path] \in {"Queued", "Active", "Failed", "Blocked", "Cancelled"}
        THEN "Pending"
        ELSE job[path]]
    /\ workerPath' = [worker \in Workers |-> NoPath]
    /\ slotPath' = [slot \in Slots |-> NoPath]
    /\ cancelled' = FALSE
    /\ failure' = FALSE
    /\ running' = FALSE
    /\ UNCHANGED <<plan, rootActive, unrooted>>

\* The user can move or replace the configured root at any time, and put
\* it back.
RootChange ==
    /\ rootActive' = ~rootActive
    /\ UNCHANGED <<job, plan, workerPath, slotPath, cancelled, failure,
        running, unrooted>>

Restart ==
    /\ ~running
    /\ running' = TRUE
    /\ UNCHANGED <<job, plan, workerPath, slotPath, cancelled, failure,
        rootActive, unrooted>>

Next ==
    \/ \E path \in Paths: Queue(path)
    \/ \E path \in Paths, worker \in Workers, slot \in Slots:
        Start(path, worker, slot)
    \/ \E path \in Paths: FinishSuccess(path)
    \/ \E path \in Paths: FinishFailure(path)
    \/ \E path \in Paths: FinishPermanent(path)
    \/ \E path \in Paths: Unblock(path)
    \/ \E path \in Paths: CancelQueued(path)
    \/ \E path \in Paths: Install(path)
    \/ \E path \in Paths: Unroot(path)
    \/ \E path \in Paths: Complete(path)
    \/ ReportFailure
    \/ Crash
    \/ RootChange
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
    /\ rootActive \in BOOLEAN
    /\ unrooted \subseteq Paths

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

\* A permanent rejection is confined to its own path: it blocks that plan,
\* cancels nothing, and leaves every other job and plan exactly as it was.
PermanentFailureIsolated ==
    \A path \in Paths:
        (job[path] # "Blocked" /\ job'[path] = "Blocked")
        => /\ cancelled' = cancelled
           /\ failure' = failure
           /\ plan'[path] = "Blocked"
           /\ \A other \in Paths \ {path}:
                /\ job'[other] = job[other]
                /\ plan'[other] = plan[other]

\* No worker ever picks up a path whose plan is blocked. Not the executor's
\* own retry, and not the queue after a crash has reset the job: only the
\* reconciler's Unblock returns the plan to pending first.
BlockedNotRetried ==
    \A path \in Paths:
        plan[path] = "Blocked" => job'[path] \notin {"Queued", "Active"}

\* A crash resets the job but never the block. Only a step that stops the
\* daemon leaves running false, so this constrains exactly the crash.
BlockOutlivesCrash ==
    \A path \in Paths:
        (plan[path] = "Blocked" /\ ~running') => plan'[path] = "Blocked"

\* Nothing installs under a root that is no longer the active one.
InstallRooted ==
    \A path \in Paths:
        (job[path] # "Installed" /\ job'[path] = "Installed") => rootActive

\* Under a root that is no longer active, a staged download stays staged
\* and its plan pending.
UnrootedStaged ==
    \A path \in Paths:
        (job[path] = "Staged" /\ ~rootActive)
        => (job'[path] = "Staged" /\ plan'[path] = "Pending")

CompletedIsStable == [][CompletedStable]_vars

StagedWorkIsPreserved == [][StagedStable]_vars

PermanentFailureSparesSiblings == [][PermanentFailureIsolated]_vars

BlockedWorkIsNotRetried == [][BlockedNotRetried]_vars

BlockedPlansOutliveCrashes == [][BlockOutlivesCrash]_vars

InstallsOnlyUnderActiveRoot == [][InstallRooted]_vars

UnrootedWorkStaysStaged == [][UnrootedStaged]_vars

=============================================================================
