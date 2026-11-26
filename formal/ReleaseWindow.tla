---- MODULE ReleaseWindow ----
\* A change while the Omabox user unit is released: RELEASING in
\* src/omabox.f, Rust's change_while_released, then CLOSING, the
\* window's end. state is the tables' state; Input is RELEASING's input
\* and Heard CLOSING's. The release drive has run when the machine
\* starts; each step (the release drive, the change, the restore drive,
\* the recovery drive) answered ok or failed, and the restore drive
\* launched the unit or not. The recovery drive runs last, only when
\* Due: no signal taken, the change made and the restore ok without a
\* launch. SIGINT, SIGTERM and SIGHUP are caught from just before the
\* release drive until the window closes, so one may be pending at the
\* start and one may arrive until Close; after it a signal takes its
\* default. The sense of released, changing and restoring takes a
\* pending signal, as Close's RELEASE does, and a signal taken stays the
\* outcome of every later state: Input is interrupted from then on in an
\* open state, and skip in restoring. Heard tells the window's ends
\* apart by the signal, whether the service is back (the restore ok and
\* the recovery not failed) and whether the change was made.
Codes == {"ok", "failed"}
None == "None"
Signals == {"none", "pending", "taken"}
Open == {"released", "changing"}
Ends == {"decided", "died"}
Closed == {"closed"} \cup Ends

VARIABLES state, release, change, restore, launched, recover, signal
vars == <<state, release, change, restore, launched, recover, signal>>

Init ==
    /\ state = "released"
    /\ release \in Codes
    /\ change = None
    /\ restore = None
    /\ launched = FALSE
    /\ recover = None
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

\* The sense word AT-RESTORED, over the signal g, the change's code c,
\* the restore's code r and whether the restore launched the unit, b.
Recovery(g, c, r, b) ==
    IF g = "none" /\ c = "ok" /\ r = "ok" /\ ~b THEN "due" ELSE "skip"

Input ==
    IF state = "restoring" THEN Recovery(signal, change, restore, launched)
    ELSE Outcome(Code(state), signal)

Due == Recovery(signal, change, restore, launched) = "due"

\* The sense word AT-CLOSED, over the signal g, the change's code c, the
\* restore's code r and the recovery's code v.
Hears(g, c, r, v) ==
    LET back == r = "ok" /\ v # "failed"
        made == c = "ok"
    IN  IF g # "taken" THEN
            IF back /\ made THEN "done"
            ELSE IF back THEN "refused"
            ELSE IF made THEN "stuck"
            ELSE "broken"
        ELSE IF back THEN "signaled"
        ELSE IF made THEN "kept"
        ELSE "unmade"

Heard == Hears(signal, change, restore, recover)

\* TAKEN, and Close's RELEASE: a pending signal is kept.
Took == signal' = IF signal = "pending" THEN "taken" ELSE signal

\* The CLI is sent a caught signal; the stub writes it to the pipe.
Arrive ==
    /\ state \in Open \cup {"restoring", "recovered"}
    /\ signal = "none"
    /\ signal' = "pending"
    /\ UNCHANGED <<state, release, change, restore, launched, recover>>

\* CHANGE: runs only after a release that answered ok, uninterrupted.
Change ==
    /\ state = "released"
    /\ Input = "ok"
    /\ change' \in Codes
    /\ state' = "changing"
    /\ Took
    /\ UNCHANGED <<release, restore, launched, recover>>

\* RESTORE: after a failed or interrupted release, and after any change.
Restore ==
    /\ \/ state = "released" /\ Input \in {"failed", "interrupted"}
       \/ state = "changing"
    /\ restore' \in Codes
    /\ launched' \in BOOLEAN
    /\ state' = "restoring"
    /\ Took
    /\ UNCHANGED <<release, change, recover>>

\* RECOVER when Due, else its skip: the window's last step.
Recover ==
    /\ state = "restoring"
    /\ IF Due THEN recover' \in Codes ELSE recover' = None
    /\ state' = "recovered"
    /\ Took
    /\ UNCHANGED <<release, change, restore, launched>>

\* RELEASE closes the window: the signals take their default again, and
\* a signal delivered after the last TAKE is taken.
Close ==
    /\ state = "recovered"
    /\ state' = "closed"
    /\ Took
    /\ UNCHANGED <<release, change, restore, launched, recover>>

\* With no signal taken the change's end is told: DONE, REFUSED, STUCK
\* or BROKEN; with one taken the CLI dies of it, whose default RELEASE
\* put back: SIGNALED, or KEPT and UNMADE, which tell the kept or unmade
\* change's end, then die as SIGNALED does.
Finish ==
    /\ state = "closed"
    /\ state' = IF signal # "taken" THEN "decided" ELSE "died"
    /\ UNCHANGED <<release, change, restore, launched, recover, signal>>

Next == Arrive \/ Change \/ Restore \/ Recover \/ Close \/ Finish
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state \in Open \cup {"restoring", "recovered"} \cup Closed
    /\ release \in Codes
    /\ change \in Codes \cup {None}
    /\ restore \in Codes \cup {None}
    /\ launched \in BOOLEAN
    /\ recover \in Codes \cup {None}
    /\ signal \in Signals

\* The change runs only after a release that answered ok.
ChangesReleased == change # None => release = "ok"

\* No change starts once a signal is delivered.
StopsAtBoundary == [][state = "released" /\ state' = "changing" => signal = "none"]_vars
RecoversUninterrupted == [][state = "restoring" /\ recover' # None => signal = "none"]_vars

\* Every path out of the window runs the restore drive first.
Restores == state \in Closed => restore # None

\* The recovery drive runs only after a made change and a restore that
\* answered ok without launching the unit.
RecoversOnlyWhenDue ==
    recover # None => change = "ok" /\ restore = "ok" /\ ~launched

\* The window ends by dying exactly when a signal was taken, and no signal
\* delivered while it was caught goes unanswered.
DiesOfSignal ==
    state \in Ends =>
        /\ state = "died" <=> signal = "taken"
        /\ signal # "pending"
====
