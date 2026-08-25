-------------------------- MODULE MutationLifecycle --------------------------

EXTENDS TLC

Kinds == {"Replace", "Delete"}
JournalStates == {"None", "Pending", "Completed"}
Targets == {"Old", "Absent", "Desired", "Changed"}
Guards == {"Empty", "Old"}
Stages == {"Missing", "Verified"}
Baselines == {"Old", "Desired", "Absent"}
Runners == {"Stopped", "Running"}
NoKind == "NoKind"

VARIABLES
    journal, kind, target, guard, stage, baseline, effectConfirmed,
    desiredFromVerifiedStage, runner

vars ==
    <<journal, kind, target, guard, stage, baseline, effectConfirmed,
      desiredFromVerifiedStage, runner>>

Init ==
    /\ journal = "None"
    /\ kind = NoKind
    /\ target = "Old"
    /\ guard = "Empty"
    /\ stage = "Missing"
    /\ baseline = "Old"
    /\ effectConfirmed = FALSE
    /\ desiredFromVerifiedStage = FALSE
    /\ runner = "Stopped"

Start ==
    /\ runner = "Stopped"
    /\ runner' = "Running"
    /\ UNCHANGED
        <<journal, kind, target, guard, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage>>

RecordPlan(nextKind) ==
    /\ runner = "Running"
    /\ journal = "None"
    /\ nextKind \in Kinds
    /\ journal' = "Pending"
    /\ kind' = nextKind
    /\ UNCHANGED
        <<target, guard, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

StageReplacement ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Replace"
    /\ stage = "Missing"
    /\ ~ effectConfirmed
    /\ target # "Desired"
    /\ stage' = "Verified"
    /\ UNCHANGED
        <<journal, kind, target, guard, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

PrepareReplacement ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Replace"
    /\ stage = "Verified"
    /\ target = "Old"
    /\ guard = "Empty"
    /\ target' = "Absent"
    /\ guard' = "Old"
    /\ UNCHANGED
        <<journal, kind, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

InstallReplacement ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Replace"
    /\ stage = "Verified"
    /\ target = "Absent"
    /\ guard = "Old"
    /\ target' = "Desired"
    /\ stage' = "Missing"
    /\ desiredFromVerifiedStage' = TRUE
    /\ UNCHANGED
        <<journal, kind, guard, baseline, effectConfirmed, runner>>

FinishReplacement ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Replace"
    /\ target = "Desired"
    /\ guard = "Old"
    /\ guard' = "Empty"
    /\ effectConfirmed' = TRUE
    /\ UNCHANGED
        <<journal, kind, target, stage, baseline,
          desiredFromVerifiedStage, runner>>

ObserveFinishedReplacement ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Replace"
    /\ target = "Desired"
    /\ guard = "Empty"
    /\ effectConfirmed' = TRUE
    /\ UNCHANGED
        <<journal, kind, target, guard, stage, baseline,
          desiredFromVerifiedStage, runner>>

PrepareDeletion ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Delete"
    /\ target = "Old"
    /\ guard = "Empty"
    /\ target' = "Absent"
    /\ guard' = "Old"
    /\ UNCHANGED
        <<journal, kind, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

FinishDeletion ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Delete"
    /\ target = "Absent"
    /\ guard = "Old"
    /\ guard' = "Empty"
    /\ effectConfirmed' = TRUE
    /\ UNCHANGED
        <<journal, kind, target, stage, baseline,
          desiredFromVerifiedStage, runner>>

ObserveFinishedDeletion ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ kind = "Delete"
    /\ target = "Absent"
    /\ guard = "Empty"
    /\ effectConfirmed' = TRUE
    /\ UNCHANGED
        <<journal, kind, target, guard, stage, baseline,
          desiredFromVerifiedStage, runner>>

UserEdit ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ target \in {"Old", "Absent", "Desired"}
    /\ target' = "Changed"
    /\ UNCHANGED
        <<journal, kind, guard, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

CleanChangedGuard ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ target = "Changed"
    /\ guard = "Old"
    /\ guard' = "Empty"
    /\ UNCHANGED
        <<journal, kind, target, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage, runner>>

Complete ==
    /\ runner = "Running"
    /\ journal = "Pending"
    /\ effectConfirmed
    /\ guard = "Empty"
    /\ journal' = "Completed"
    /\ baseline' = IF kind = "Replace" THEN "Desired" ELSE "Absent"
    /\ UNCHANGED
        <<kind, target, guard, stage, effectConfirmed,
          desiredFromVerifiedStage, runner>>

Crash ==
    /\ runner = "Running"
    /\ runner' = "Stopped"
    /\ UNCHANGED
        <<journal, kind, target, guard, stage, baseline, effectConfirmed,
          desiredFromVerifiedStage>>

Next ==
    \/ Start
    \/ Crash
    \/ StageReplacement
    \/ PrepareReplacement
    \/ InstallReplacement
    \/ FinishReplacement
    \/ ObserveFinishedReplacement
    \/ PrepareDeletion
    \/ FinishDeletion
    \/ ObserveFinishedDeletion
    \/ UserEdit
    \/ CleanChangedGuard
    \/ Complete
    \/ \E nextKind \in Kinds: RecordPlan(nextKind)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ journal \in JournalStates
    /\ kind \in Kinds \cup {NoKind}
    /\ target \in Targets
    /\ guard \in Guards
    /\ stage \in Stages
    /\ baseline \in Baselines
    /\ effectConfirmed \in BOOLEAN
    /\ desiredFromVerifiedStage \in BOOLEAN
    /\ runner \in Runners

JournalAuthorizesMutation ==
    /\ (guard = "Old") => journal = "Pending"
    /\ (stage = "Verified") => journal = "Pending"
    /\ effectConfirmed => journal \in {"Pending", "Completed"}

PendingDoesNotAdvanceBaseline ==
    (journal # "Completed") => baseline = "Old"

CompletionFollowsTheDurableEffect ==
    (journal = "Completed") =>
        /\ effectConfirmed
        /\ guard = "Empty"
        /\ IF kind = "Replace"
              THEN baseline = "Desired"
              ELSE baseline = "Absent"

OnlyVerifiedBytesBecomeDesired ==
    (target = "Desired") => desiredFromVerifiedStage

DeleteNeverInstallsContent ==
    (kind = "Delete") => target # "Desired"

DisplacementNeverDuplicatesOldBytes ==
    /\ (guard = "Old") => target # "Old"
    /\ (target = "Old") => guard = "Empty"

NoRetainedGuardAfterCompletion ==
    (journal = "Completed") => guard = "Empty"

UserChangesArePreserved ==
    []((target = "Changed") => [](target = "Changed"))

=============================================================================
