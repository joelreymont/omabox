------------------------------ MODULE RemoteCopy ------------------------------
\* One remote copy of a path's Dropbox bytes, as REMOTE-COPY in
\* src/replay.f makes it, a pass at a time until its conflict is recorded.
\* name is what the copy's name holds: nothing, the remote's bytes, the
\* remote's bytes still marked as a stage, other bytes, or an entry Omabox
\* cannot replace. own is the stage staged for the copy's own name and
\* plan the one the path's download left beside it:
\* none, the remote's verified bytes, or other bytes. downloads counts the
\* download requests; run is the copy's state in the table, "out"
\* outside a pass. recorded is the conflict's record. listed says the
\* copy's own stage is recorded in the journal; live says a pass, or a
\* plan or conflict block at the path, may still install the copy.

EXTENDS Naturals

Names == {"Absent", "Want", "Marked", "Other", "Dir"}
Stages == {"None", "Verified", "Other"}

\* A refused or unverified download is asked again in a later pass.
MaxDownloads == 2

VARIABLES name, own, plan, downloads, run, recorded, listed, live

vars == <<name, own, plan, downloads, run, recorded, listed, live>>

Init ==
    /\ name \in Names
    /\ own \in Stages
    /\ plan \in Stages
    /\ downloads = 0
    /\ run = "out"
    /\ recorded = FALSE
    /\ listed = (own = "Verified")
    /\ live = TRUE

\* A pass prepares the conflict, its remote copy first at its own stage;
\* the pass holds the copy until it ends.
Begin ==
    /\ run = "out"
    /\ ~recorded
    /\ run' = "own"
    /\ live' = TRUE
    /\ UNCHANGED <<name, own, plan, downloads, recorded, listed>>

Moves(from, to) ==
    /\ run = from
    /\ run' = to
    /\ UNCHANGED <<name, own, plan, downloads, recorded, listed, live>>

\* The stage an install at state from takes, the path's when reusing,
\* else the copy's own, and the state its other bytes lead to.
Src(from) == IF from = "reusing" THEN plan ELSE own
HeldTo(from) == IF from = "reusing" THEN "fetching" ELSE "stage-held"

\* An install at state from looks at the copy's name first. The remote's
\* bytes there, marked or not, are the copy: released, then the stage
\* removed if verified; other bytes at the stage's name are kept and
\* answer held. Other bytes or an entry at the copy's name are kept.
Placed(from) ==
    /\ run = from
    /\ name \in {"Want", "Marked"}
    /\ Src(from) # "Other"
    /\ name' = "Want"
    /\ IF from = "reusing"
          THEN plan' = "None" /\ own' = own
          ELSE own' = "None" /\ plan' = plan
    /\ run' = "ready"
    /\ UNCHANGED <<downloads, recorded, listed, live>>

PlacedHeld(from) ==
    /\ run = from
    /\ name \in {"Want", "Marked"}
    /\ Src(from) = "Other"
    /\ name' = "Want"
    /\ run' = HeldTo(from)
    /\ UNCHANGED <<own, plan, downloads, recorded, listed, live>>

Changed(from) == name = "Other" /\ Moves(from, "taken")
Occupied(from) == name = "Dir" /\ Moves(from, "taken")

\* The copy's own verified stage renamed to its absent name, still marked;
\* the install's Placed ends the line, unless the pass ends first.
RenameOwn(from) ==
    /\ run = from
    /\ name = "Absent"
    /\ own = "Verified"
    /\ name' = "Marked"
    /\ own' = "None"
    /\ UNCHANGED <<plan, downloads, run, recorded, listed, live>>

OwnHeld(from) == name = "Absent" /\ own = "Other" /\ Moves(from, "stage-held")
OwnMissing(from, to) == name = "Absent" /\ own = "None" /\ Moves(from, to)

\* The path's verified stage renamed to the copy's absent name, in their
\* directory, still marked, as RenameOwn leaves it.
RenamePlan ==
    /\ run = "reusing"
    /\ name = "Absent"
    /\ plan = "Verified"
    /\ name' = "Marked"
    /\ plan' = "None"
    /\ UNCHANGED <<own, downloads, run, recorded, listed, live>>

PlanMissing == name = "Absent" /\ plan = "None" /\ Moves("reusing", "fetching")
PlanHeld == name = "Absent" /\ plan = "Other" /\ Moves("reusing", "fetching")

\* The download into the copy's own stage: one already verified there is
\* kept without a request; else Dropbox's bytes verify, do not, or Dropbox
\* refuses them for the path. Every way out records the copy's own stage
\* first, as FETCH-COPY does on entry, before its catch.
Fetches(to) ==
    /\ run = "fetching"
    /\ run' = to
    /\ listed' = TRUE
    /\ UNCHANGED <<name, own, plan, downloads, recorded, live>>

\* Unreachable: OWN found no stage at the copy's own name, and only a
\* download marks one, so nothing here makes one verified.
FetchKept == own = "Verified" /\ Fetches("installing")

\* The copy's own stage is recorded, and committed, before the request.
Asked(to) ==
    /\ run = "fetching"
    /\ own = "None"
    /\ downloads < MaxDownloads
    /\ downloads' = downloads + 1
    /\ run' = to
    /\ listed' = TRUE

FetchStaged ==
    /\ Asked("installing")
    /\ own' = "Verified"
    /\ UNCHANGED <<name, plan, recorded, live>>

FetchFailed(to) ==
    /\ Asked(to)
    /\ UNCHANGED <<name, own, plan, recorded, live>>

FetchHeld == own = "Other" /\ Fetches("stage-held")
FetchOccupied == name = "Dir" /\ Fetches("taken")

\* A ready copy lets the pass record its conflict; the copy is the user's.
Record ==
    /\ run = "ready"
    /\ recorded' = TRUE
    /\ run' = "out"
    /\ UNCHANGED <<name, own, plan, downloads, listed, live>>

\* The pass ends, at a final state or by a failure or a crash.
End ==
    /\ run # "out"
    /\ run' = "out"
    /\ UNCHANGED <<name, own, plan, downloads, recorded, listed, live>>

\* Outside a pass, the conflict is recorded or ends some other way: no
\* plan or conflict block at the path may install the copy any more.
Ends ==
    /\ run = "out"
    /\ live
    /\ live' = FALSE
    /\ UNCHANGED <<name, own, plan, downloads, run, recorded, listed>>

\* At a pass's end, the listed stage nothing may install is retired: the
\* copy's own verified stage removed, its record forgotten. Other bytes
\* are never removed.
Retire ==
    /\ run = "out"
    /\ ~live
    /\ listed
    /\ own' = IF own = "Verified" THEN "None" ELSE own
    /\ listed' = FALSE
    /\ UNCHANGED <<name, plan, downloads, run, recorded, live>>

\* The user writes a file, the remote's bytes or others, or makes a
\* directory at the copy's free name.
UserTakes ==
    /\ name = "Absent"
    /\ ~recorded
    /\ name' \in {"Want", "Other", "Dir"}
    /\ UNCHANGED <<own, plan, downloads, run, recorded, listed, live>>

\* The user writes a file at the copy's own stage name or the path's; it
\* carries no stage marker, so the install finds other bytes there.
UserStages ==
    /\ ~recorded
    /\ \/ own \in {"None", "Verified"} /\ own' = "Other" /\ plan' = plan
       \/ plan \in {"None", "Verified"} /\ plan' = "Other" /\ own' = own
    /\ UNCHANGED <<name, downloads, run, recorded, listed, live>>

\* The steps REMOTE-COPY's lines take. The pass and the user act outside
\* them.
Run ==
    \/ Placed("own") \/ PlacedHeld("own") \/ OwnMissing("own", "reusing")
    \/ OwnHeld("own") \/ Changed("own") \/ Occupied("own")
    \/ Placed("reusing") \/ PlacedHeld("reusing") \/ PlanMissing
    \/ PlanHeld \/ Changed("reusing") \/ Occupied("reusing")
    \/ FetchKept \/ FetchStaged \/ FetchFailed("unverified")
    \/ FetchFailed("refused") \/ FetchHeld \/ FetchOccupied
    \/ Placed("installing") \/ PlacedHeld("installing")
    \/ OwnMissing("installing", "lost") \/ OwnHeld("installing")
    \/ Changed("installing") \/ Occupied("installing")

\* The renames within a line, before its Placed.
Renames == RenameOwn("own") \/ RenamePlan \/ RenameOwn("installing")

Next ==
    \/ Begin \/ Run \/ Renames \/ Record \/ End \/ Ends \/ Retire
    \/ UserTakes \/ UserStages

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ name \in Names
    /\ own \in Stages
    /\ plan \in Stages
    /\ downloads \in 0..MaxDownloads
    /\ run \in {"out", "own", "reusing", "fetching", "installing", "ready",
                "taken", "stage-held", "unverified", "refused", "lost"}
    /\ recorded \in BOOLEAN
    /\ listed \in BOOLEAN
    /\ live \in BOOLEAN

\* A ready copy holds the remote's bytes at its name, released.
ReadyHoldsTheCopy == run = "ready" => name = "Want"

\* A verified stage Omabox staged is always findable: its record stands.
OwnStageListed == own = "Verified" => listed

\* The remote's verified bytes, once held, stay at a name or a stage
\* until Retire removes a stage nothing may install; the user may
\* destroy them, Omabox may not otherwise.
Held == name \in {"Want", "Marked"} \/ own = "Verified" \/ plan = "Verified"
RemoteBytesKept == [][Held => Held' \/ UserStages \/ Retire]_vars

\* Other bytes, and an entry Omabox cannot replace, are never replaced.
OthersKept ==
    [][ /\ name \in {"Other", "Dir"} => name' = name
        /\ own = "Other" => own' = "Other"
        /\ plan = "Other" => plan' = "Other" ]_vars

\* Nothing is downloaded while a verified stage holds the remote's bytes.
StagesSpareDownloads ==
    [][(own = "Verified" \/ plan = "Verified") => downloads' = downloads]_vars

\* No verified stage is lost: the install after a download finds its stage.
NeverLost == run # "lost"

=============================================================================
