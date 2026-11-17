---------------------------- MODULE SyncBehavior ----------------------------

EXTENDS TLC

Scenarios == {
    "LocalCreate", "RemoteCreate", "LocalEdit", "RemoteEdit",
    "LocalDelete", "RemoteDelete", "DivergentEdits", "InitialCollision",
    "LocalDeleteRemoteEdit", "RemoteDeleteLocalEdit"
}
ConflictScenarios == {
    "DivergentEdits", "InitialCollision",
    "LocalDeleteRemoteEdit", "RemoteDeleteLocalEdit"
}
Contents == {"Absent", "Base", "Local", "LaterLocal", "Remote"}
Plans == {
    "None", "Upload", "Download", "DeleteRemote", "DeleteLocal", "Conflict"
}
Phases == {"Waiting", "Observing", "Staging", "Applying", "Materializing", "Finishing"}
Journals == {"None", "Pending", "Completed"}
NoContent == "NoContent"

VARIABLES
    scenario, local, remote, baseline, plan, phase, journal,
    observedLocal, observedRemote, uploadVerified, downloadVerified,
    localCopy, remoteCopy, conflictRecorded

vars ==
    <<scenario, local, remote, baseline, plan, phase, journal,
      observedLocal, observedRemote, uploadVerified, downloadVerified,
      localCopy, remoteCopy, conflictRecorded>>

InitialBaseline ==
    IF scenario \in {"LocalCreate", "RemoteCreate", "InitialCollision"}
    THEN "Absent"
    ELSE "Base"

InitialLocal ==
    CASE scenario \in {
            "LocalCreate", "LocalEdit", "DivergentEdits", "InitialCollision",
            "RemoteDeleteLocalEdit"
         }
            -> "Local"
      [] scenario \in {"RemoteCreate", "LocalDelete", "LocalDeleteRemoteEdit"}
            -> "Absent"
      [] OTHER -> "Base"

InitialRemote ==
    CASE scenario \in {
            "RemoteCreate", "RemoteEdit", "DivergentEdits", "InitialCollision",
            "LocalDeleteRemoteEdit"
         }
            -> "Remote"
      [] scenario \in {"LocalCreate", "RemoteDelete", "RemoteDeleteLocalEdit"}
            -> "Absent"
      [] OTHER -> "Base"

Init ==
    /\ scenario \in Scenarios
    /\ local = InitialLocal
    /\ remote = InitialRemote
    /\ baseline = InitialBaseline
    /\ plan = "None"
    /\ phase = "Waiting"
    /\ journal = "None"
    /\ observedLocal = NoContent
    /\ observedRemote = NoContent
    /\ uploadVerified = FALSE
    /\ downloadVerified = FALSE
    /\ localCopy = NoContent
    /\ remoteCopy = NoContent
    /\ conflictRecorded = FALSE

Wake ==
    /\ phase = "Waiting"
    /\ phase' = "Observing"
    /\ UNCHANGED
        <<scenario, local, remote, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

BeginPlan(nextPlan, nextPhase, nextJournal) ==
    /\ phase = "Observing"
    /\ plan' = nextPlan
    /\ phase' = nextPhase
    /\ journal' = nextJournal
    /\ observedLocal' = local
    /\ observedRemote' = remote
    /\ uploadVerified' = FALSE
    /\ downloadVerified' = FALSE
    /\ UNCHANGED
        <<scenario, local, remote, baseline, localCopy, remoteCopy,
          conflictRecorded>>

PlanUpload ==
    /\ local # "Absent"
    /\ local # baseline
    /\ remote = baseline
    /\ BeginPlan("Upload", "Staging", journal)

PlanDownload ==
    /\ remote # "Absent"
    /\ remote # baseline
    /\ local = baseline
    /\ BeginPlan("Download", "Staging", "Pending")

PlanDeleteRemote ==
    /\ baseline # "Absent"
    /\ local = "Absent"
    /\ remote = baseline
    /\ BeginPlan("DeleteRemote", "Applying", "Pending")

PlanDeleteLocal ==
    /\ baseline # "Absent"
    /\ remote = "Absent"
    /\ local = baseline
    /\ BeginPlan("DeleteLocal", "Applying", "Pending")

PlanConflict ==
    /\ local # remote
    /\ local # baseline
    /\ remote # baseline
    /\ BeginPlan("Conflict", "Materializing", journal)

PlanNoOp ==
    /\ phase = "Observing"
    /\ local = remote
    /\ baseline' = local
    /\ plan' = "None"
    /\ phase' = "Waiting"
    /\ journal' = "Completed"
    /\ observedLocal' = local
    /\ observedRemote' = remote
    /\ uploadVerified' = FALSE
    /\ downloadVerified' = FALSE
    /\ UNCHANGED
        <<scenario, local, remote, localCopy, remoteCopy, conflictRecorded>>

ChoosePlan ==
    \/ PlanUpload
    \/ PlanDownload
    \/ PlanDeleteRemote
    \/ PlanDeleteLocal
    \/ PlanConflict
    \/ PlanNoOp

StageUpload ==
    /\ phase = "Staging"
    /\ plan = "Upload"
    /\ ~ uploadVerified
    /\ local = observedLocal
    /\ uploadVerified' = TRUE
    /\ phase' = "Applying"
    /\ journal' = "Pending"
    /\ UNCHANGED
        <<scenario, local, remote, baseline, plan,
          observedLocal, observedRemote, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ChangeUploadSource ==
    /\ phase = "Staging"
    /\ plan = "Upload"
    /\ local = observedLocal
    /\ local' = "LaterLocal"
    /\ UNCHANGED
        <<scenario, remote, baseline, plan, phase, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

RetireStaleUpload ==
    /\ phase = "Staging"
    /\ plan = "Upload"
    /\ local # observedLocal
    /\ plan' = "None"
    /\ phase' = "Observing"
    /\ uploadVerified' = FALSE
    /\ UNCHANGED
        <<scenario, local, remote, baseline, journal,
          observedLocal, observedRemote, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

StageDownload ==
    /\ phase = "Staging"
    /\ plan = "Download"
    /\ ~ downloadVerified
    /\ downloadVerified' = TRUE
    /\ phase' = "Applying"
    /\ UNCHANGED
        <<scenario, local, remote, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ApplyUpload ==
    /\ phase = "Applying"
    /\ plan = "Upload"
    /\ uploadVerified
    /\ local = observedLocal
    /\ remote = observedRemote
    /\ remote' = observedLocal
    /\ phase' = "Finishing"
    /\ UNCHANGED
        <<scenario, local, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ApplyDownload ==
    /\ phase = "Applying"
    /\ plan = "Download"
    /\ downloadVerified
    /\ local = observedLocal
    /\ remote = observedRemote
    /\ local' = observedRemote
    /\ phase' = "Finishing"
    /\ UNCHANGED
        <<scenario, remote, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ApplyDeleteRemote ==
    /\ phase = "Applying"
    /\ plan = "DeleteRemote"
    /\ local = "Absent"
    /\ remote = observedRemote
    /\ remote' = "Absent"
    /\ phase' = "Finishing"
    /\ UNCHANGED
        <<scenario, local, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ApplyDeleteLocal ==
    /\ phase = "Applying"
    /\ plan = "DeleteLocal"
    /\ remote = "Absent"
    /\ local = observedLocal
    /\ local' = "Absent"
    /\ phase' = "Finishing"
    /\ UNCHANGED
        <<scenario, remote, baseline, plan, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, remoteCopy, conflictRecorded>>

ApplyEffect ==
    \/ ApplyUpload
    \/ ApplyDownload
    \/ ApplyDeleteRemote
    \/ ApplyDeleteLocal

CopyLocalConflict ==
    /\ phase = "Materializing"
    /\ plan = "Conflict"
    /\ observedLocal # "Absent"
    /\ localCopy = NoContent
    /\ localCopy' = observedLocal
    /\ UNCHANGED
        <<scenario, local, remote, baseline, plan, phase, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          remoteCopy, conflictRecorded>>

CopyRemoteConflict ==
    /\ phase = "Materializing"
    /\ plan = "Conflict"
    /\ observedRemote # "Absent"
    /\ remoteCopy = NoContent
    /\ remoteCopy' = observedRemote
    /\ UNCHANGED
        <<scenario, local, remote, baseline, plan, phase, journal,
          observedLocal, observedRemote, uploadVerified, downloadVerified,
          localCopy, conflictRecorded>>

FinishConflict ==
    /\ phase = "Materializing"
    /\ plan = "Conflict"
    /\ (observedLocal = "Absent" \/ localCopy = observedLocal)
    /\ (observedRemote = "Absent" \/ remoteCopy = observedRemote)
    /\ conflictRecorded' = TRUE
    /\ journal' = "Completed"
    /\ plan' = "None"
    /\ phase' = "Waiting"
    /\ UNCHANGED
        <<scenario, local, remote, baseline, observedLocal, observedRemote,
          uploadVerified, downloadVerified, localCopy, remoteCopy>>

FinishEffect ==
    /\ phase = "Finishing"
    /\ plan \in {"Upload", "Download", "DeleteRemote", "DeleteLocal"}
    /\ local = remote
    /\ baseline' = local
    /\ journal' = "Completed"
    /\ plan' = "None"
    /\ phase' = "Waiting"
    /\ UNCHANGED
        <<scenario, local, remote, observedLocal, observedRemote,
          uploadVerified, downloadVerified, localCopy, remoteCopy,
          conflictRecorded>>

Next ==
    \/ Wake
    \/ ChoosePlan
    \/ ChangeUploadSource
    \/ RetireStaleUpload
    \/ StageUpload
    \/ StageDownload
    \/ ApplyEffect
    \/ CopyLocalConflict
    \/ CopyRemoteConflict
    \/ FinishConflict
    \/ FinishEffect

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Wake)
    /\ WF_vars(ChoosePlan)
    /\ WF_vars(RetireStaleUpload)
    /\ WF_vars(StageUpload)
    /\ WF_vars(StageDownload)
    /\ WF_vars(ApplyEffect)
    /\ WF_vars(CopyLocalConflict)
    /\ WF_vars(CopyRemoteConflict)
    /\ WF_vars(FinishConflict)
    /\ WF_vars(FinishEffect)

TypeOK ==
    /\ scenario \in Scenarios
    /\ local \in Contents
    /\ remote \in Contents
    /\ baseline \in Contents
    /\ plan \in Plans
    /\ phase \in Phases
    /\ journal \in Journals
    /\ observedLocal \in Contents \cup {NoContent}
    /\ observedRemote \in Contents \cup {NoContent}
    /\ uploadVerified \in BOOLEAN
    /\ downloadVerified \in BOOLEAN
    /\ localCopy \in Contents \cup {NoContent}
    /\ remoteCopy \in Contents \cup {NoContent}
    /\ conflictRecorded \in BOOLEAN

\* A staged upload is private, and a conflict is recorded only once its copies exist.
JournalAuthorizesEffects ==
    phase \in {"Applying", "Finishing"} => journal = "Pending"

VerifiedTransfersOnly ==
    /\ (phase = "Finishing" /\ plan = "Upload") => uploadVerified
    /\ (phase = "Finishing" /\ plan = "Download") => downloadVerified

VerifiedUploadMatchesObservation ==
    uploadVerified => local = observedLocal

PendingKeepsBaseline ==
    (journal = "Pending") => baseline = InitialBaseline

ConflictPreservesOriginals ==
    conflictRecorded =>
        /\ local = observedLocal
        /\ remote = observedRemote
        /\ (observedLocal = "Absent" \/ localCopy = observedLocal)
        /\ (observedRemote = "Absent" \/ remoteCopy = observedRemote)

Settled ==
    IF scenario \in ConflictScenarios
    THEN conflictRecorded
    ELSE /\ journal = "Completed"
         /\ local = remote
         /\ baseline = local

AutomaticSync == <>Settled

=============================================================================
