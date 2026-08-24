-------------------------- MODULE DownloadLifecycle --------------------------

CONSTANT Paths

ASSUME Paths # {}

JournalStates == {"None", "Pending", "Completed"}
Runners == {"Stopped", "Running"}
Baselines == {"Absent", "Present"}

VARIABLES journal, stage, installed, installedFromVerifiedStage, baseline, runner

vars == <<journal, stage, installed, installedFromVerifiedStage, baseline, runner>>
durable == <<journal, stage, installed, installedFromVerifiedStage, baseline>>

Init ==
    /\ journal = [path \in Paths |-> "None"]
    /\ stage = [path \in Paths |-> "Missing"]
    /\ installed = [path \in Paths |-> FALSE]
    /\ installedFromVerifiedStage = [path \in Paths |-> FALSE]
    /\ baseline = [path \in Paths |-> "Absent"]
    /\ runner = "Stopped"

Start ==
    /\ runner = "Stopped"
    /\ runner' = "Running"
    /\ UNCHANGED durable

RecordPlan(path) ==
    /\ runner = "Running"
    /\ journal[path] = "None"
    /\ journal' = [journal EXCEPT ![path] = "Pending"]
    /\ UNCHANGED <<stage, installed, installedFromVerifiedStage, baseline, runner>>

VerifyStage(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ stage[path] = "Missing"
    /\ installed[path] = FALSE
    /\ stage' = [stage EXCEPT ![path] = "Verified"]
    /\ UNCHANGED <<journal, installed, installedFromVerifiedStage, baseline, runner>>

Install(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ stage[path] = "Verified"
    /\ installed[path] = FALSE
    /\ stage' = [stage EXCEPT ![path] = "Missing"]
    /\ installed' = [installed EXCEPT ![path] = TRUE]
    /\ installedFromVerifiedStage' =
        [installedFromVerifiedStage EXCEPT ![path] = TRUE]
    /\ UNCHANGED <<journal, baseline, runner>>

Complete(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ installed[path]
    /\ journal' = [journal EXCEPT ![path] = "Completed"]
    /\ baseline' = [baseline EXCEPT ![path] = "Present"]
    /\ UNCHANGED <<stage, installed, installedFromVerifiedStage, runner>>

Crash ==
    /\ runner = "Running"
    /\ runner' = "Stopped"
    /\ UNCHANGED durable

Next ==
    \/ Start
    \/ Crash
    \/ \E path \in Paths:
        \/ RecordPlan(path)
        \/ VerifyStage(path)
        \/ Install(path)
        \/ Complete(path)
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ journal \in [Paths -> JournalStates]
    /\ stage \in [Paths -> {"Missing", "Verified"}]
    /\ installed \in [Paths -> BOOLEAN]
    /\ installedFromVerifiedStage \in [Paths -> BOOLEAN]
    /\ baseline \in [Paths -> Baselines]
    /\ runner \in Runners

NoEffectBeforePlan ==
    \A path \in Paths:
        (stage[path] = "Verified" \/ installed[path]) => journal[path] # "None"

NeverInstallUnverified ==
    \A path \in Paths: installed[path] => installedFromVerifiedStage[path]

NeverCompleteBeforeInstall ==
    \A path \in Paths: journal[path] = "Completed" => installed[path]

BaselineMatchesCompletion ==
    \A path \in Paths:
        (baseline[path] = "Present") <=> (journal[path] = "Completed")

=============================================================================
