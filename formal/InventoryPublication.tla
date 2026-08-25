------------------------ MODULE InventoryPublication ------------------------

EXTENDS FiniteSets, TLC

Scenarios == {
    "DeltaSuccess", "DeltaFailure",
    "ResetSuccess", "ResetFailure",
    "FreshSuccess", "FreshFailure", "FreshReset"
}
FreshScenarios == {"FreshSuccess", "FreshFailure", "FreshReset"}
SuccessScenarios == {"DeltaSuccess", "ResetSuccess", "FreshSuccess"}
Modes == {"None", "Delta", "Full"}
Phases == {
    "Waiting", "DeltaFirst", "DeltaSecond",
    "FullFirst", "FullSecond", "Ready",
    "Done", "Failed", "Crashed"
}
Paths == {"A", "B"}
NoCursor == "NoCursor"
Cursors == {NoCursor, "C0", "C1"}

VARIABLES
    scenario, mode, phase, buffered, durable, cursor, validated, committed

vars == <<scenario, mode, phase, buffered, durable, cursor, validated, committed>>

InitialInventory == IF scenario \in FreshScenarios THEN {} ELSE {"A"}
InitialCursor == IF scenario \in FreshScenarios THEN NoCursor ELSE "C0"

FinalInventory ==
    CASE scenario = "FreshSuccess" -> {"A", "B"}
      [] scenario \in {"DeltaSuccess", "ResetSuccess"} -> {"B"}
      [] OTHER -> InitialInventory

Init ==
    /\ scenario \in Scenarios
    /\ mode = "None"
    /\ phase = "Waiting"
    /\ buffered = {}
    /\ durable = InitialInventory
    /\ cursor = InitialCursor
    /\ validated = FALSE
    /\ committed = FALSE

Start ==
    /\ phase = "Waiting"
    /\ ~ committed
    /\ buffered' = {}
    /\ validated' = FALSE
    /\ IF scenario \in FreshScenarios
       THEN /\ mode' = "Full"
            /\ phase' = "FullFirst"
       ELSE /\ mode' = "Delta"
            /\ phase' = "DeltaFirst"
    /\ UNCHANGED <<scenario, durable, cursor, committed>>

ReadDeltaFirst ==
    /\ phase = "DeltaFirst"
    /\ scenario \in {"DeltaSuccess", "DeltaFailure"}
    /\ buffered' = {}
    /\ phase' = "DeltaSecond"
    /\ UNCHANGED
        <<scenario, mode, durable, cursor, validated, committed>>

ReadDeltaLast ==
    /\ phase = "DeltaSecond"
    /\ scenario = "DeltaSuccess"
    /\ buffered' = {"B"}
    /\ validated' = TRUE
    /\ phase' = "Ready"
    /\ UNCHANGED <<scenario, mode, durable, cursor, committed>>

FailDelta ==
    /\ phase = "DeltaSecond"
    /\ scenario = "DeltaFailure"
    /\ phase' = "Failed"
    /\ UNCHANGED
        <<scenario, mode, buffered, durable, cursor, validated, committed>>

ObserveReset ==
    /\ phase = "DeltaFirst"
    /\ scenario \in {"ResetSuccess", "ResetFailure"}
    /\ mode' = "Full"
    /\ phase' = "FullFirst"
    /\ buffered' = {}
    /\ validated' = FALSE
    /\ UNCHANGED <<scenario, durable, cursor, committed>>

ReadFullFirst ==
    /\ phase = "FullFirst"
    /\ buffered' = {"B"}
    /\ phase' = "FullSecond"
    /\ UNCHANGED
        <<scenario, mode, durable, cursor, validated, committed>>

ReadFullLast ==
    /\ phase = "FullSecond"
    /\ scenario \in {"ResetSuccess", "FreshSuccess"}
    /\ buffered' = FinalInventory
    /\ validated' = TRUE
    /\ phase' = "Ready"
    /\ UNCHANGED <<scenario, mode, durable, cursor, committed>>

FailFull ==
    /\ phase = "FullSecond"
    /\ scenario \in {"ResetFailure", "FreshFailure"}
    /\ phase' = "Failed"
    /\ UNCHANGED
        <<scenario, mode, buffered, durable, cursor, validated, committed>>

RejectFreshReset ==
    /\ phase = "FullSecond"
    /\ scenario = "FreshReset"
    /\ phase' = "Failed"
    /\ UNCHANGED
        <<scenario, mode, buffered, durable, cursor, validated, committed>>

Publish ==
    /\ phase = "Ready"
    /\ scenario \in SuccessScenarios
    /\ validated
    /\ durable' = buffered
    /\ cursor' = "C1"
    /\ committed' = TRUE
    /\ phase' = "Done"
    /\ UNCHANGED <<scenario, mode, buffered, validated>>

Crash ==
    /\ phase \in {
        "DeltaFirst", "DeltaSecond", "FullFirst", "FullSecond", "Ready"
       }
    /\ phase' = "Crashed"
    /\ UNCHANGED
        <<scenario, mode, buffered, durable, cursor, validated, committed>>

Retry ==
    /\ phase \in {"Failed", "Crashed"}
    /\ mode' = "None"
    /\ phase' = "Waiting"
    /\ buffered' = {}
    /\ validated' = FALSE
    /\ UNCHANGED <<scenario, durable, cursor, committed>>

Next ==
    \/ Start
    \/ ReadDeltaFirst
    \/ ReadDeltaLast
    \/ FailDelta
    \/ ObserveReset
    \/ ReadFullFirst
    \/ ReadFullLast
    \/ FailFull
    \/ RejectFreshReset
    \/ Publish
    \/ Crash
    \/ Retry

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ scenario \in Scenarios
    /\ mode \in Modes
    /\ phase \in Phases
    /\ buffered \in SUBSET Paths
    /\ durable \in SUBSET Paths
    /\ cursor \in Cursors
    /\ validated \in BOOLEAN
    /\ committed \in BOOLEAN

DurablePairIsAtomic ==
    \/ /\ durable = InitialInventory
       /\ cursor = InitialCursor
    \/ /\ scenario \in SuccessScenarios
       /\ committed
       /\ durable = FinalInventory
       /\ cursor = "C1"

IncompleteAttemptIsInvisible ==
    ~ committed =>
        /\ durable = InitialInventory
        /\ cursor = InitialCursor

PublicationRequiresValidation ==
    committed =>
        /\ validated
        /\ phase = "Done"
        /\ scenario \in SuccessScenarios

FailureAndCrashPreserveSnapshot ==
    phase \in {"Failed", "Crashed"} =>
        /\ durable = InitialInventory
        /\ cursor = InitialCursor

DeletionRequiresCompletePublication ==
    ("A" \in InitialInventory /\ "A" \notin durable) => committed

=============================================================================
