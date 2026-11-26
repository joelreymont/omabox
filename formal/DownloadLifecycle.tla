-------------------------- MODULE DownloadLifecycle --------------------------

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Paths, Slots, Roots, MaxBlocks, MaxOperations

ASSUME /\ Cardinality(Paths) = 2
       /\ Cardinality(Slots) = 4
       /\ Cardinality(Roots) = 2
       /\ MaxBlocks = 2
       /\ MaxOperations = 2

NoPath == "NoPath"
NoRoot == "NoRoot"
SlotKinds == {"Free", "Known", "Unknown"}
Responses == {"Idle", "Exact", "Wrong"}
JournalStates == {"None", "Pending", "Completed"}
Baselines == {"Absent", "Present"}
Runners == {"Stopped", "Running"}
Offsets == 0..MaxBlocks
Operations == 1..MaxOperations
InitialRoot == CHOOSE root \in Roots: TRUE
ChangedRoot == CHOOSE root \in Roots: root # InitialRoot

VARIABLES
    journal, planRoot, planOp, nextOp, currentRoot,
    slotKind, slotPath, slotRoot, slotOp,
    written, durableBytes, advertised, contentGood, advertisedGood,
    userOwned,
    response, responseStart, fullyVerified,
    stage, stageRoot, stageOp, stageFromFullVerification,
    installed, installedFromFullVerification, baseline, runner,
    endedOp

vars ==
    <<journal, planRoot, planOp, nextOp, currentRoot,
      slotKind, slotPath, slotRoot, slotOp,
      written, durableBytes, advertised, contentGood, advertisedGood,
      userOwned,
      response, responseStart, fullyVerified,
      stage, stageRoot, stageOp, stageFromFullVerification,
      installed, installedFromFullVerification, baseline, runner, endedOp>>

ModelSymmetry ==
    { [value \in Slots \cup Paths |->
        IF value \in Slots THEN slotPermutation[value]
        ELSE pathPermutation[value]]
      : slotPermutation \in Permutations(Slots),
        pathPermutation \in Permutations(Paths) }

CurrentSlotFor(path, slot) ==
    /\ journal[path] = "Pending"
    /\ slotKind[slot] = "Known"
    /\ slotPath[slot] = path
    /\ slotRoot[slot] = planRoot[path]
    /\ slotOp[slot] = planOp[path]

CurrentSlot(slot) ==
    \E path \in Paths: CurrentSlotFor(path, slot)

Init ==
    /\ journal = [path \in Paths |-> "None"]
    /\ planRoot = [path \in Paths |-> NoRoot]
    /\ planOp = [path \in Paths |-> 0]
    /\ nextOp = [path \in Paths |-> 1]
    /\ currentRoot = InitialRoot
    /\ slotKind = [slot \in Slots |-> "Free"]
    /\ slotPath = [slot \in Slots |-> NoPath]
    /\ slotRoot = [slot \in Slots |-> NoRoot]
    /\ slotOp = [slot \in Slots |-> 0]
    /\ written = [slot \in Slots |-> 0]
    /\ durableBytes = [slot \in Slots |-> 0]
    /\ advertised = [slot \in Slots |-> 0]
    /\ contentGood = [slot \in Slots |-> TRUE]
    /\ advertisedGood = [slot \in Slots |-> TRUE]
    /\ userOwned = {}
    /\ response = [slot \in Slots |-> "Idle"]
    /\ responseStart = [slot \in Slots |-> 0]
    /\ fullyVerified = [slot \in Slots |-> FALSE]
    /\ stage = [path \in Paths |-> "Missing"]
    /\ stageRoot = [path \in Paths |-> NoRoot]
    /\ stageOp = [path \in Paths |-> 0]
    /\ stageFromFullVerification = [path \in Paths |-> FALSE]
    /\ installed = [path \in Paths |-> FALSE]
    /\ installedFromFullVerification = [path \in Paths |-> FALSE]
    /\ baseline = [path \in Paths |-> "Absent"]
    /\ runner = "Stopped"
    /\ endedOp = [path \in Paths |-> 0]

Start ==
    /\ runner = "Stopped"
    /\ runner' = "Running"
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, endedOp>>

\* Omabox keeps nothing of an old root: activation forgets every ended
\* plan, and a verified stage in the old root stays there.
SwitchRoot ==
    /\ runner = "Running"
    /\ \A path \in Paths: journal[path] # "Pending"
    /\ currentRoot = InitialRoot
    /\ currentRoot' = ChangedRoot
    /\ endedOp' = [path \in Paths |-> 0]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner>>

RecordPlan(path) ==
    /\ runner = "Running"
    /\ journal[path] = "None"
    /\ nextOp[path] \in Operations
    /\ journal' = [journal EXCEPT ![path] = "Pending"]
    /\ planRoot' = [planRoot EXCEPT ![path] = currentRoot]
    /\ planOp' = [planOp EXCEPT ![path] = nextOp[path]]
    /\ nextOp' = [nextOp EXCEPT ![path] = @ + 1]
    /\ UNCHANGED
        <<currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

\* Superseding or ending one plan without its install leaves its known
\* partial durable and stale, and its verified stage, if any, beside its
\* target. The journal keeps the ended plan's record, endedOp, through
\* every prune and crash until ForgetEnded. Work for another path
\* continues independently.
AbandonPlan(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ ~installed[path]
    /\ endedOp[path] = 0
    /\ \A slot \in Slots:
        slotPath[slot] = path => response[slot] = "Idle"
    /\ journal' = [journal EXCEPT ![path] = "None"]
    /\ planRoot' = [planRoot EXCEPT ![path] = NoRoot]
    /\ planOp' = [planOp EXCEPT ![path] = 0]
    /\ endedOp' = [endedOp EXCEPT ![path] = planOp[path]]
    /\ fullyVerified' = [slot \in Slots |->
        IF slotPath[slot] = path THEN FALSE ELSE fullyVerified[slot]]
    /\ UNCHANGED
        <<nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner>>

\* FINISH removes the ended plan's verified stage in the current root and
\* syncs its directory; the journal still keeps the ended plan's record.
RemoveEndedStage(path) ==
    /\ runner = "Running"
    /\ endedOp[path] # 0
    /\ stage[path] = "Verified"
    /\ stageOp[path] = endedOp[path]
    /\ stageRoot[path] = currentRoot
    /\ stage' = [stage EXCEPT ![path] = "Missing"]
    /\ stageRoot' = [stageRoot EXCEPT ![path] = NoRoot]
    /\ stageOp' = [stageOp EXCEPT ![path] = 0]
    /\ stageFromFullVerification' =
        [stageFromFullVerification EXCEPT ![path] = FALSE]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

\* FINISH then forgets the ended plan's record once no verified stage of
\* that plan remains.
ForgetEnded(path) ==
    /\ runner = "Running"
    /\ endedOp[path] # 0
    /\ ~(stage[path] = "Verified" /\ stageOp[path] = endedOp[path])
    /\ endedOp' = [endedOp EXCEPT ![path] = 0]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner>>

\* A stage in another root is out of view: the current root's stage lives
\* in another directory, so staging there overwrites the model's stage.
NoCurrentStage(path) ==
    stage[path] = "Missing" \/ stageRoot[path] # currentRoot

LeaseSlot(path, slot) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ NoCurrentStage(path)
    /\ ~installed[path]
    /\ \A other \in Slots: ~CurrentSlotFor(path, other)
    /\ slotKind[slot] = "Free"
    /\ slotKind' = [slotKind EXCEPT ![slot] = "Known"]
    /\ slotPath' = [slotPath EXCEPT ![slot] = path]
    /\ slotRoot' = [slotRoot EXCEPT ![slot] = planRoot[path]]
    /\ slotOp' = [slotOp EXCEPT ![slot] = planOp[path]]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

\* An unrecognized existing slot belongs to the user or another process. Once
\* observed, no lifecycle action may rename, truncate, or remove it.
OccupyUnknownSlot(slot) ==
    /\ runner = "Running"
    /\ \E path \in Paths: journal[path] = "Pending"
    /\ slotKind[slot] = "Free"
    /\ slotKind' = [slotKind EXCEPT ![slot] = "Unknown"]
    /\ userOwned' = userOwned \cup {slot}
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

OpenRange(path, slot, start) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Idle"
    /\ ~fullyVerified[slot]
    /\ written[slot] < MaxBlocks
    /\ written[slot] = durableBytes[slot]
    /\ durableBytes[slot] = advertised[slot]
    /\ response' =
        [response EXCEPT ![slot] = IF start = advertised[slot]
                                        THEN "Exact" ELSE "Wrong"]
    /\ responseStart' = [responseStart EXCEPT ![slot] = start]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

AppendBlock(path, slot, good) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Exact"
    /\ written[slot] < MaxBlocks
    /\ written' = [written EXCEPT ![slot] = @ + 1]
    /\ contentGood' = [contentGood EXCEPT ![slot] = @ /\ good]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          durableBytes, advertised, advertisedGood, userOwned,
          response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

SyncData(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Exact"
    /\ durableBytes[slot] < written[slot]
    /\ durableBytes' = [durableBytes EXCEPT ![slot] = written[slot]]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, advertised, contentGood, advertisedGood, userOwned,
          response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

\* Data reaches durable storage before its resumable offset is advertised.
AdvertiseCheckpoint(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Exact"
    /\ durableBytes[slot] = written[slot]
    /\ advertised[slot] < durableBytes[slot]
    /\ advertised' = [advertised EXCEPT ![slot] = durableBytes[slot]]
    /\ advertisedGood' = [advertisedGood EXCEPT ![slot] = contentGood[slot]]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, contentGood, userOwned,
          response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

CloseExactRange(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Exact"
    /\ written[slot] = durableBytes[slot]
    /\ durableBytes[slot] = advertised[slot]
    /\ response' = [response EXCEPT ![slot] = "Idle"]
    /\ responseStart' = [responseStart EXCEPT ![slot] = 0]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

RejectWrongRange(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Wrong"
    /\ response' = [response EXCEPT ![slot] = "Idle"]
    /\ responseStart' = [responseStart EXCEPT ![slot] = 0]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

VerifyFullContent(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ response[slot] = "Idle"
    /\ written[slot] = MaxBlocks
    /\ durableBytes[slot] = MaxBlocks
    /\ advertised[slot] = MaxBlocks
    /\ contentGood[slot]
    /\ fullyVerified' = [fullyVerified EXCEPT ![slot] = TRUE]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

ClearKnownSlot(slot) ==
    /\ slotKind' = [slotKind EXCEPT ![slot] = "Free"]
    /\ slotPath' = [slotPath EXCEPT ![slot] = NoPath]
    /\ slotRoot' = [slotRoot EXCEPT ![slot] = NoRoot]
    /\ slotOp' = [slotOp EXCEPT ![slot] = 0]
    /\ written' = [written EXCEPT ![slot] = 0]
    /\ durableBytes' = [durableBytes EXCEPT ![slot] = 0]
    /\ advertised' = [advertised EXCEPT ![slot] = 0]
    /\ contentGood' = [contentGood EXCEPT ![slot] = TRUE]
    /\ advertisedGood' = [advertisedGood EXCEPT ![slot] = TRUE]
    /\ response' = [response EXCEPT ![slot] = "Idle"]
    /\ responseStart' = [responseStart EXCEPT ![slot] = 0]
    /\ fullyVerified' = [fullyVerified EXCEPT ![slot] = FALSE]

\* A pending operation can reclaim a known stale slot. A slot still current
\* for either pending path, or an unknown occupant, cannot enter this action.
DiscardStaleSlot(path, slot) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ slotKind[slot] = "Known"
    /\ ~CurrentSlot(slot)
    /\ ClearKnownSlot(slot)
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot, userOwned,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

\* This durable boundary abstracts both a same-filesystem rename and a
\* completed cross-filesystem copy. A crash occurs before or after it.
PromoteVerifiedSlot(path, slot) ==
    /\ runner = "Running"
    /\ CurrentSlotFor(path, slot)
    /\ fullyVerified[slot]
    /\ NoCurrentStage(path)
    /\ ClearKnownSlot(slot)
    /\ stage' = [stage EXCEPT ![path] = "Verified"]
    /\ stageRoot' = [stageRoot EXCEPT ![path] = planRoot[path]]
    /\ stageOp' = [stageOp EXCEPT ![path] = planOp[path]]
    /\ stageFromFullVerification' =
        [stageFromFullVerification EXCEPT ![path] = TRUE]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot, userOwned,
          installed, installedFromFullVerification, baseline, runner, endedOp>>

Install(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ stage[path] = "Verified"
    /\ stageRoot[path] = planRoot[path]
    /\ stageOp[path] = planOp[path]
    /\ stageFromFullVerification[path]
    /\ ~installed[path]
    /\ stage' = [stage EXCEPT ![path] = "Missing"]
    /\ stageRoot' = [stageRoot EXCEPT ![path] = NoRoot]
    /\ stageOp' = [stageOp EXCEPT ![path] = 0]
    /\ stageFromFullVerification' =
        [stageFromFullVerification EXCEPT ![path] = FALSE]
    /\ installed' = [installed EXCEPT ![path] = TRUE]
    /\ installedFromFullVerification' =
        [installedFromFullVerification EXCEPT ![path] = TRUE]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          baseline, runner, endedOp>>

Complete(path) ==
    /\ runner = "Running"
    /\ journal[path] = "Pending"
    /\ installed[path]
    /\ journal' = [journal EXCEPT ![path] = "Completed"]
    /\ baseline' = [baseline EXCEPT ![path] = "Present"]
    /\ UNCHANGED
        <<planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          written, durableBytes, advertised, contentGood, advertisedGood,
          userOwned, response, responseStart, fullyVerified,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, runner, endedOp>>

\* Recovery trusts only the advertised checkpoint. Both synchronized but
\* unadvertised bytes and unsynchronized tail bytes are truncated for every
\* in-flight download.
Crash ==
    /\ runner = "Running"
    /\ runner' = "Stopped"
    /\ written' = [slot \in Slots |->
        IF slotKind[slot] = "Known" THEN advertised[slot] ELSE 0]
    /\ durableBytes' = [slot \in Slots |->
        IF slotKind[slot] = "Known" THEN advertised[slot] ELSE 0]
    /\ contentGood' = [slot \in Slots |->
        IF slotKind[slot] = "Known" THEN advertisedGood[slot] ELSE TRUE]
    /\ response' = [slot \in Slots |-> "Idle"]
    /\ responseStart' = [slot \in Slots |-> 0]
    /\ fullyVerified' = [slot \in Slots |-> FALSE]
    /\ UNCHANGED
        <<journal, planRoot, planOp, nextOp, currentRoot,
          slotKind, slotPath, slotRoot, slotOp,
          advertised, advertisedGood, userOwned,
          stage, stageRoot, stageOp, stageFromFullVerification,
          installed, installedFromFullVerification, baseline, endedOp>>

Next ==
    \/ Start
    \/ Crash
    \/ SwitchRoot
    \/ \E path \in Paths:
        \/ RecordPlan(path)
        \/ AbandonPlan(path)
        \/ RemoveEndedStage(path)
        \/ ForgetEnded(path)
        \/ Install(path)
        \/ Complete(path)
    \/ \E slot \in Slots: OccupyUnknownSlot(slot)
    \/ \E path \in Paths, slot \in Slots:
        \/ LeaseSlot(path, slot)
        \/ SyncData(path, slot)
        \/ AdvertiseCheckpoint(path, slot)
        \/ CloseExactRange(path, slot)
        \/ RejectWrongRange(path, slot)
        \/ VerifyFullContent(path, slot)
        \/ DiscardStaleSlot(path, slot)
        \/ PromoteVerifiedSlot(path, slot)
    \/ \E path \in Paths, slot \in Slots, start \in Offsets:
        OpenRange(path, slot, start)
    \/ \E path \in Paths, slot \in Slots, good \in BOOLEAN:
        AppendBlock(path, slot, good)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ journal \in [Paths -> JournalStates]
    /\ planRoot \in [Paths -> Roots \cup {NoRoot}]
    /\ planOp \in [Paths -> 0..MaxOperations]
    /\ nextOp \in [Paths -> 1..(MaxOperations + 1)]
    /\ currentRoot \in Roots
    /\ slotKind \in [Slots -> SlotKinds]
    /\ slotPath \in [Slots -> Paths \cup {NoPath}]
    /\ slotRoot \in [Slots -> Roots \cup {NoRoot}]
    /\ slotOp \in [Slots -> 0..MaxOperations]
    /\ written \in [Slots -> Offsets]
    /\ durableBytes \in [Slots -> Offsets]
    /\ advertised \in [Slots -> Offsets]
    /\ contentGood \in [Slots -> BOOLEAN]
    /\ advertisedGood \in [Slots -> BOOLEAN]
    /\ userOwned \subseteq Slots
    /\ response \in [Slots -> Responses]
    /\ responseStart \in [Slots -> Offsets]
    /\ fullyVerified \in [Slots -> BOOLEAN]
    /\ stage \in [Paths -> {"Missing", "Verified"}]
    /\ stageRoot \in [Paths -> Roots \cup {NoRoot}]
    /\ stageOp \in [Paths -> 0..MaxOperations]
    /\ stageFromFullVerification \in [Paths -> BOOLEAN]
    /\ installed \in [Paths -> BOOLEAN]
    /\ installedFromFullVerification \in [Paths -> BOOLEAN]
    /\ baseline \in [Paths -> Baselines]
    /\ runner \in Runners
    /\ endedOp \in [Paths -> 0..MaxOperations]

PlansWellFormed ==
    \A path \in Paths:
        /\ (journal[path] = "None") =>
            /\ planRoot[path] = NoRoot
            /\ planOp[path] = 0
            /\ (stage[path] = "Missing" \/ stageRoot[path] # currentRoot
                \/ endedOp[path] # 0)
            /\ ~installed[path]
            /\ baseline[path] = "Absent"
        /\ (journal[path] # "None") =>
            /\ planRoot[path] \in Roots
            /\ planOp[path] \in Operations
            /\ planOp[path] < nextOp[path]
        /\ (endedOp[path] # 0) =>
            /\ endedOp[path] < nextOp[path]
            /\ endedOp[path] # planOp[path]

SlotsWellFormed ==
    \A slot \in Slots:
        /\ (slotKind[slot] = "Known") =>
            /\ slotPath[slot] \in Paths
            /\ slotRoot[slot] \in Roots
            /\ slotOp[slot] \in Operations
            /\ advertised[slot] <= durableBytes[slot]
            /\ durableBytes[slot] <= written[slot]
        /\ (slotKind[slot] # "Known") =>
            /\ slotPath[slot] = NoPath
            /\ slotRoot[slot] = NoRoot
            /\ slotOp[slot] = 0
            /\ written[slot] = 0
            /\ durableBytes[slot] = 0
            /\ advertised[slot] = 0
            /\ contentGood[slot]
            /\ advertisedGood[slot]
            /\ response[slot] = "Idle"
            /\ responseStart[slot] = 0
            /\ ~fullyVerified[slot]

AtMostOneCurrentSlotPerPath ==
    \A path \in Paths:
        Cardinality({slot \in Slots: CurrentSlotFor(path, slot)}) <= 1

DurableOffsetsDoNotOutrunData ==
    \A slot \in Slots:
        advertised[slot] <= durableBytes[slot]
        /\ durableBytes[slot] <= written[slot]

StoppedAtAdvertisedCheckpoint ==
    runner = "Stopped" =>
        \A slot \in Slots:
            written[slot] = advertised[slot]
            /\ durableBytes[slot] = advertised[slot]

ExactRangeContinuation ==
    \A slot \in Slots:
        /\ (response[slot] = "Wrong") =>
            /\ responseStart[slot] # advertised[slot]
            /\ written[slot] = advertised[slot]
            /\ durableBytes[slot] = advertised[slot]
        /\ (response[slot] = "Exact") =>
            /\ responseStart[slot] <= advertised[slot]
            /\ advertised[slot] <= written[slot]

PendingOperationsAuthorizeEffects ==
    /\ \A path \in Paths:
        (stage[path] = "Verified" /\ stageOp[path] = planOp[path]) =>
            /\ journal[path] = "Pending"
            /\ stageRoot[path] = planRoot[path]
            /\ stageFromFullVerification[path]
    /\ \A slot \in Slots:
        (response[slot] # "Idle" \/ fullyVerified[slot]) => CurrentSlot(slot)

StaleBindingsCannotAdvance ==
    \A slot \in Slots:
        fullyVerified[slot] =>
            /\ CurrentSlot(slot)
            /\ response[slot] = "Idle"
            /\ written[slot] = MaxBlocks
            /\ advertised[slot] = MaxBlocks
            /\ contentGood[slot]

\* Every verified stage in the current root has a plan record: its live
\* plan's, or the ended plan's the journal keeps until RemoveEndedStage
\* removes the stage.
VerifiedStagesHaveRecords ==
    \A path \in Paths:
        (stage[path] = "Verified" /\ stageRoot[path] = currentRoot) =>
            \/ /\ journal[path] = "Pending"
               /\ stageOp[path] = planOp[path]
            \/ /\ endedOp[path] # 0
               /\ stageOp[path] = endedOp[path]

UnknownOccupantsArePreserved ==
    userOwned \subseteq {slot \in Slots : slotKind[slot] = "Unknown"}

StagesWellFormed ==
    \A path \in Paths:
        /\ (stage[path] = "Missing") =>
            /\ stageRoot[path] = NoRoot
            /\ stageOp[path] = 0
            /\ ~stageFromFullVerification[path]
        /\ (stage[path] = "Verified") => stageFromFullVerification[path]

UnverifiedBytesAreNeverInstalled ==
    \A path \in Paths:
        installed[path] => installedFromFullVerification[path]

CompletionImpliesInstalledBaseline ==
    \A path \in Paths:
        /\ (journal[path] = "Completed") => installed[path]
        /\ (baseline[path] = "Present") <=> (journal[path] = "Completed")

=============================================================================
