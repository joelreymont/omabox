---- MODULE ReleaseWindow ----
\* A change while the Omabox user unit is released: RELEASING in
\* src/omabox.f, Rust's change_while_released, then CLOSING, the
\* window's end. state is the tables' state; Input is RELEASING's input
\* and Heard CLOSING's. The release drive has run when the machine
\* starts; each step (the release drive, the change, the restore drive)
\* answered ok or failed. SIGINT, SIGTERM and SIGHUP are caught from just
\* before the release drive until the window closes, so one may be
\* pending at the start and one may arrive until Close; after it a
\* signal takes its default. The sense of released and changing takes a
\* pending signal, as Close's RELEASE does, and a signal taken stays the
\* outcome of every later state: Input is interrupted from then on.
\* Heard tells a signal taken apart by the window's end: the service
\* restored, or not restarted with the change made (kept) or not (unmade).
Codes == {"ok", "failed"}
None == "None"
Signals == {"none", "pending", "taken"}
Open == {"released", "changing"}
Ends == {"decided", "died"}
Closed == {"closed"} \cup Ends

VARIABLES state, release, change, restore, signal
vars == <<state, release, change, restore, signal>>

Init ==
    /\ state = "released"
    /\ release \in Codes
    /\ change = None
    /\ restore = None
    /\ signal \in {"none", "pending"}

\* The sense word AT-STEP: the outcome of a step that answered code k,
\* with the signal g.
Outcome(k, g) ==
    IF g # "none" THEN "interrupted"
    ELSE IF k = "failed" THEN "failed" ELSE "ok"

\* The code the state p reads: the release's until the change runs.
Code(p) ==
    CASE p = "released" -> release
      [] p = "changing" -> change

Input == Outcome(Code(state), signal)

\* The sense word AT-CLOSED, over the signal g, the change's code c and
\* the restore's code r.
Hears(g, c, r) ==
    IF g # "taken" THEN "quiet"
    ELSE IF r = "ok" THEN "signaled"
    ELSE IF c = "ok" THEN "kept"
    ELSE "unmade"

Heard == Hears(signal, change, restore)

\* TAKEN, and Close's RELEASE: a pending signal is kept.
Took == signal' = IF signal = "pending" THEN "taken" ELSE signal

\* The CLI is sent a caught signal; the stub writes it to the pipe.
Arrive ==
    /\ state \in Open \cup {"restoring"}
    /\ signal = "none"
    /\ signal' = "pending"
    /\ UNCHANGED <<state, release, change, restore>>

\* CHANGE: runs only after a release that answered ok, uninterrupted.
Change ==
    /\ state = "released"
    /\ Input = "ok"
    /\ change' \in Codes
    /\ state' = "changing"
    /\ Took
    /\ UNCHANGED <<release, restore>>

\* RESTORE: after a failed or interrupted release, and after any change;
\* the window's last step.
Restore ==
    /\ \/ state = "released" /\ Input \in {"failed", "interrupted"}
       \/ state = "changing"
    /\ restore' \in Codes
    /\ state' = "restoring"
    /\ Took
    /\ UNCHANGED <<release, change>>

\* RELEASE closes the window: the signals take their default again, and
\* a signal delivered after the last TAKE is taken.
Close ==
    /\ state = "restoring"
    /\ state' = "closed"
    /\ Took
    /\ UNCHANGED <<release, change, restore>>

\* DECIDE: the change's end is told; SIGNALED: the CLI dies of the signal
\* taken, whose default RELEASE put back; KEPT and UNMADE tell the kept or
\* unmade change's end, then die as SIGNALED does.
Finish ==
    /\ state = "closed"
    /\ state' = IF Heard = "quiet" THEN "decided" ELSE "died"
    /\ UNCHANGED <<release, change, restore, signal>>

Next == Arrive \/ Change \/ Restore \/ Close \/ Finish
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state \in Open \cup {"restoring"} \cup Closed
    /\ release \in Codes
    /\ change \in Codes \cup {None}
    /\ restore \in Codes \cup {None}
    /\ signal \in Signals

\* The change runs only after a release that answered ok.
ChangesReleased == change # None => release = "ok"

\* No change starts once a signal is delivered.
StopsAtBoundary == [][state = "released" /\ state' = "changing" => signal = "none"]_vars

\* Every path out of the window runs the restore drive first.
Restores == state \in Closed => restore # None

\* The window ends by dying exactly when a signal was taken, and no signal
\* delivered while it was caught goes unanswered.
DiesOfSignal ==
    state \in Ends =>
        /\ state = "died" <=> signal = "taken"
        /\ signal # "pending"
====
