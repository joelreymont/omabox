---------------------------- MODULE UploadSession ----------------------------
\* One UPLOAD as SESSION (src/dropbox.f) runs it: each step is one of its
\* lines, the state's sense word calling Dropbox and the line taking the
\* answer as its input. size is the stage in chunks: one goes in a
\* files/upload, more through a session's start, an append a chunk and a
\* finish. remote is "after" once Dropbox holds the upload's complete entry
\* at its path; offset is the chunks the run's session holds. Dropbox takes
\* an append only at that offset, and commits only the whole stage over the
\* revision COMMIT+ names; strict_conflict refuses a commit onto the
\* upload's own content. A call may have acted though its answer does not
\* say so, a session may be gone at any call, and get_metadata may not show
\* an upload Dropbox holds; another client's edit reaches the run only so.
\* A throw leaves UPLOAD with no answer and is not a step.
EXTENDS Naturals

VARIABLES step, size, remote, offset, accepted, resent, restarted, answer
vars == <<step, size, remote, offset, accepted, resent, restarted, answer>>

\* FIRST: a stage of one chunk goes single.
Init ==
    /\ size \in 1..2
    /\ step = IF size = 1 THEN "single" ELSE "starting"
    /\ remote = "before"
    /\ offset = 0
    /\ accepted = 0
    /\ resent = FALSE
    /\ restarted = FALSE
    /\ answer = "none"

\* A call that can commit: a files/upload, or a finish of a session that
\* holds the whole stage, while the path holds the revision COMMIT+ names.
Commits == remote = "before" /\ (step = "single" \/ offset = size)
\* What Dropbox holds after a call that may have acted.
Maybe == remote' \in IF Commits THEN {remote, "after"} ELSE {remote}
\* What the session holds after an append that may have been taken.
Taken == offset' \in IF offset = accepted THEN {offset, offset + 1} ELSE {offset}
\* An append answered done, or HELD?: incorrect_offset at the chunk's end,
\* an earlier unsure send having stored it.
Took ==
    \/ offset = accepted /\ offset' = offset + 1
    \/ offset = accepted + 1 /\ offset' = offset
\* CHUNK-ADVANCE.
Advance(t) == accepted' = accepted + 1 /\ resent' = FALSE /\ step' = t /\ UNCHANGED answer
\* REWIND.
Rewind == accepted' = 0 /\ resent' = FALSE /\ step' = "starting" /\ UNCHANGED answer
\* The ANSWER- words; ANSWER-DONE also counts the whole stage accepted.
End(a) ==
    /\ step' = "ended"
    /\ answer' = a
    /\ accepted' = IF a = "done" THEN size ELSE accepted

\* SEND-SENSE and FINISH-SENSE: a 2xx answer is committed when UPLOADED?
\* finds the upload's complete entry at its path with its content hash.
Commit(e) ==
    CASE e = "committed" -> Commits /\ remote' = "after" /\ End("done")
      [] e = "untrusted" -> Commits /\ Maybe /\ End("unverified")
      [] e = "unsure" -> Maybe /\ End("unverified")
      [] e = "failed" -> Maybe /\ End("reply")

Send(e) ==
    /\ step = "single"
    /\ Commit(e)
    /\ UNCHANGED <<size, offset, resent, restarted>>

Start(e) ==
    /\ step = "starting"
    /\ CASE e = "opened" -> offset' = 0 /\ step' = "appending" /\ UNCHANGED <<accepted, answer>>
         [] e = "unsure" -> End("unverified") /\ UNCHANGED offset
         [] e = "failed" -> End("reply") /\ UNCHANGED offset
    /\ UNCHANGED <<size, remote, resent, restarted>>

\* APPEND-SENSE sends the chunk after accepted; UNSURE-AGAIN resends it once.
Append(e) ==
    /\ step = "appending"
    /\ CASE e = "stored" -> Took /\ accepted + 1 < size /\ Advance("appending")
         [] e = "complete" -> Took /\ accepted + 1 = size /\ Advance("finishing")
         [] e = "unsure" -> ~resent /\ resent' = TRUE /\ Taken /\ step' = "appending" /\ UNCHANGED <<accepted, answer>>
         [] e = "cut" -> resent /\ Taken /\ End("unverified") /\ UNCHANGED resent
         [] e = "gone" -> step' = "restarting" /\ UNCHANGED <<offset, accepted, resent, answer>>
         [] e = "failed" -> Taken /\ End("reply") /\ UNCHANGED resent
    /\ UNCHANGED <<size, remote, restarted>>

\* FINISH-GONE?: lookup_failed, the session gone, which a finish Dropbox
\* took may leave.
Finish(e) ==
    /\ step = "finishing"
    /\ IF e = "gone" THEN Maybe /\ step' = "verifying" /\ UNCHANGED <<accepted, answer>>
                     ELSE Commit(e)
    /\ UNCHANGED <<size, offset, resent, restarted>>

\* CONFIRM-SENSE: same only for the upload's complete entry at its path.
Confirm(e) ==
    /\ step = "verifying"
    /\ CASE e = "same" -> remote = "after" /\ End("done")
         [] e = "elsewhere" -> End("mismatch")
         [] e = "wait" -> End("reply")
         [] e = "other" -> step' = "restarting" /\ UNCHANGED <<accepted, answer>>
         [] e = "unlinked" -> End("unlinked")
    /\ UNCHANGED <<size, remote, offset, resent, restarted>>

\* RESTART-SENSE allows one restart.
Restart(e) ==
    /\ step = "restarting"
    /\ CASE e = "once" -> ~restarted /\ restarted' = TRUE /\ Rewind
         [] e = "twice" -> restarted /\ End("unverified") /\ UNCHANGED <<restarted, resent>>
    /\ UNCHANGED <<size, remote, offset>>

Next ==
    \/ \E e \in {"committed", "untrusted", "unsure", "failed"} : Send(e)
    \/ \E e \in {"opened", "unsure", "failed"} : Start(e)
    \/ \E e \in {"stored", "complete", "unsure", "cut", "gone", "failed"} : Append(e)
    \/ \E e \in {"committed", "untrusted", "unsure", "gone", "failed"} : Finish(e)
    \/ \E e \in {"same", "elsewhere", "wait", "other", "unlinked"} : Confirm(e)
    \/ \E e \in {"once", "twice"} : Restart(e)

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ step \in {"single", "starting", "appending", "finishing", "verifying", "restarting", "ended"}
    /\ size \in 1..2
    /\ remote \in {"before", "after"}
    /\ offset \in 0..2
    /\ accepted \in 0..2
    /\ resent \in BOOLEAN
    /\ restarted \in BOOLEAN
    /\ answer \in {"none", "done", "unverified", "reply", "mismatch", "unlinked"}

\* UPLOAD answers done, on which the replay completes the operation, only
\* while Dropbox holds the upload's complete entry at its path.
Verified == answer = "done" => remote = "after"

\* The run counts as accepted, and SHOW reports, only chunks its session
\* holds: HELD? adopts an offset only at the chunk's end, and an unsure
\* append advances nothing.
Accepted == step \in {"appending", "finishing"} => accepted <= offset

\* UNSURE-AGAIN resends a chunk once and RESTART-SENSE restarts once, so
\* DRIVE's loop ends.
Ends == <>(step = "ended")
=============================================================================
