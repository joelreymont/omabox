------------------------- MODULE ScanCoordination -------------------------

EXTENDS FiniteSets, TLC

CONSTANT Workers

WorkerStates == {"Downloading", "Ready", "Promoting", "Staged"}
ScanStates == {"Requested", "Scanning", "Published"}

VARIABLES workerState, scanState

vars == <<workerState, scanState>>

Init ==
    /\ workerState = [worker \in Workers |-> "Downloading"]
    /\ scanState = "Requested"

FinishDownload(worker) ==
    /\ workerState[worker] = "Downloading"
    /\ workerState' = [workerState EXCEPT ![worker] = "Ready"]
    /\ UNCHANGED scanState

BeginPromotion(worker) ==
    /\ workerState[worker] = "Ready"
    /\ scanState # "Scanning"
    /\ workerState' = [workerState EXCEPT ![worker] = "Promoting"]
    /\ UNCHANGED scanState

FinishPromotion(worker) ==
    /\ workerState[worker] = "Promoting"
    /\ workerState' = [workerState EXCEPT ![worker] = "Staged"]
    /\ UNCHANGED scanState

BeginScan ==
    /\ scanState = "Requested"
    /\ \A worker \in Workers: workerState[worker] # "Promoting"
    /\ scanState' = "Scanning"
    /\ UNCHANGED workerState

PublishScan ==
    /\ scanState = "Scanning"
    /\ scanState' = "Published"
    /\ UNCHANGED workerState

Next ==
    \/ \E worker \in Workers: FinishDownload(worker)
    \/ \E worker \in Workers: BeginPromotion(worker)
    \/ \E worker \in Workers: FinishPromotion(worker)
    \/ BeginScan
    \/ PublishScan

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(BeginScan)
    /\ WF_vars(PublishScan)
    /\ \A worker \in Workers: WF_vars(FinishPromotion(worker))

TypeOK ==
    /\ workerState \in [Workers -> WorkerStates]
    /\ scanState \in ScanStates

ScanExcludesPromotion ==
    scanState = "Scanning" =>
        \A worker \in Workers: workerState[worker] # "Promoting"

ScanEventuallyPublishes ==
    scanState = "Requested" ~> scanState = "Published"

=============================================================================
