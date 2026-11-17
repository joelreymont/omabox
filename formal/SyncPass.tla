------------------------------ MODULE SyncPass ------------------------------
\* One reconciliation pass, SYNC-PASS in src/reconcile.f. Its steps are
\* the table's lines: Ok is a word's ok, Fresh its fresh and Unroot its
\* root-changed, each free wherever the table has the line. SyncBehavior.tla
\* models what PLAN and APPLY do to one path.

Words == {
    "settling", "recovering", "observing", "listing", "deciding", "applying"
}
States == Words \cup {"complete", "stale", "unrooted"}
\* The words that change the root or Dropbox: RECOVER and APPLY replay
\* plans, PLAN makes conflict copies.
Effects == {"recovering", "deciding", "applying"}
\* The scan and the listing, which an effect makes stale.
Views == {"observing", "listing"}

\* made: the words that answered ok, less the views an effect has made
\* stale since.
VARIABLES at, made

vars == <<at, made>>

Init ==
    /\ at = "settling"
    /\ made = {}

Ok(s, t) ==
    /\ at = s
    /\ at' = t
    /\ made' = (IF s \in Effects THEN made \ Views ELSE made) \cup {s}

Fresh(s) ==
    /\ at = s
    /\ at' = "stale"
    /\ UNCHANGED made

Unroot(s) ==
    /\ at = s
    /\ at' = "unrooted"
    /\ UNCHANGED made

Next ==
    \/ Ok("settling", "recovering")
    \/ Ok("recovering", "observing")
    \/ Ok("observing", "listing")
    \/ Ok("listing", "deciding")
    \/ Ok("deciding", "applying")
    \/ Ok("applying", "complete")
    \/ \E s \in {"settling", "observing", "deciding", "applying"} : Fresh(s)
    \/ \E s \in Words : Unroot(s)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ at \in States
    /\ made \subseteq Words

\* PLAN decides from a published scan and a refreshed listing, both taken
\* after the pass last changed the root or Dropbox.
PlanOnCurrentViews == at = "deciding" => Views \subseteq made

\* FINISH reports the pass's replays and planning and removes the upload
\* stages no recorded plan holds.
FinishAfterFullPass ==
    at = "complete" => {"recovering", "deciding", "applying"} \subseteq made

=============================================================================
