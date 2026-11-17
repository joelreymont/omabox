---- MODULE ServiceDrive ----
\* One drive of the Omabox user unit toward a goal: DRIVING in
\* src/service.f, Rust's ServiceCommands::drive_recorded. phase is the
\* table's state and Step its input. systemd may change the unit between
\* any two calls, so an observation reads any state. A step that throws
\* ends the drive in "failed", no table state: an observation, or a stop,
\* clear or launch before its command was spawned or after. spawned holds
\* the steps whose command was spawned: the record's acted is
\* spawned # {}, its launched phase = "launched".
States == {"Running", "Starting", "Failed", "Stopping", "Stopped"}
None == "None"
Option == States \cup {None}
Live == {"Running", "Starting"}
Holding == Live \cup {"Stopping"}
Goals == {"Start", "Restart", "Recover", "Halt", "Release", "Restore"}
Commands == {"stop", "clear", "start", "restart"}
Open == {"initial", "seen", "after-stop", "settled", "cleared"}

VARIABLES goal, before, phase, first, last, spawned
vars == <<goal, before, phase, first, last, spawned>>

Init ==
    /\ goal \in Goals
    /\ before \in IF goal = "Restore" THEN Option ELSE {None}
    /\ phase = "initial"
    /\ first = None
    /\ last = None
    /\ spawned = {}

\* Rust's next, the SENSE words AT-INITIAL to AT-CLEARED: the step goal g,
\* restoring b, takes from phase p with u the state last observed.
Due(p, g, b, u) ==
    CASE p = "initial" ->
            (CASE g \in {"Start", "Restart"} -> "clear"
               [] g = "Restore" -> IF b \in Live THEN "clear" ELSE "done"
               [] OTHER -> "observe")
      [] p = "seen" ->
            (CASE g \in {"Recover", "Halt"} /\ u = "Failed" -> "clear"
               [] g = "Recover" /\ u = "Stopping" -> "stop"
               [] g \in {"Halt", "Release"} /\ u \in Holding -> "stop"
               [] OTHER -> "done")
      [] p = "after-stop" ->
            IF g \in {"Recover", "Halt"} THEN "observe" ELSE "done"
      [] p = "settled" ->
            IF g \in {"Recover", "Halt"} /\ u = "Failed"
            THEN "clear" ELSE "done"
      [] p = "cleared" ->
            (CASE g = "Restart" -> "restart"
               [] g \in {"Halt", "Release"} -> "done"
               [] OTHER -> "start")

Step == Due(phase, goal, before, last)

\* OBSERVE-FIRST reads the state before any change, OBSERVE the state
\* after the stop.
Observe ==
    /\ Step = "observe"
    /\ \E u \in States :
        /\ last' = u
        /\ first' = IF phase = "initial" THEN u ELSE first
    /\ phase' = IF phase = "initial" THEN "seen" ELSE "settled"
    /\ UNCHANGED <<goal, before, spawned>>

\* STOP, CLEAR, START or RESTART: the command was spawned and succeeded.
Act ==
    /\ Step \in Commands
    /\ spawned' = spawned \cup {Step}
    /\ phase' = CASE Step = "stop" -> "after-stop"
                  [] Step = "clear" -> "cleared"
                  [] OTHER -> "launched"
    /\ UNCHANGED <<goal, before, first, last>>

Finish ==
    /\ Step = "done"
    /\ phase' = "reached"
    /\ UNCHANGED <<goal, before, first, last, spawned>>

\* The step threw: an observation, or a command before it was spawned
\* (E-START-COMMAND) or after.
Fail ==
    /\ Step # "done"
    /\ \/ spawned' = spawned
       \/ Step \in Commands /\ spawned' = spawned \cup {Step}
    /\ phase' = "failed"
    /\ UNCHANGED <<goal, before, first, last>>

Next == phase \in Open /\ (Observe \/ Act \/ Finish \/ Fail)
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ goal \in Goals
    /\ before \in Option
    /\ phase \in Open \cup {"launched", "reached", "failed"}
    /\ first \in Option
    /\ last \in Option
    /\ spawned \subseteq Commands

\* AT-SEEN and AT-SETTLED read the state the drive observed: in seen the
\* first, before any change; in settled one read after the stop.
Observed ==
    /\ phase = "seen" => last \in States /\ last = first /\ spawned = {}
    /\ phase = "settled" => last \in States /\ "stop" \in spawned

\* The goal asks for a start or restart: to start or restart, to recover
\* a unit last observed failed, to restore one observed live before.
Asked ==
    \/ goal \in {"Start", "Restart"}
    \/ goal = "Recover" /\ last = "Failed"
    \/ goal = "Restore" /\ before \in Live

Launches == spawned \cap {"start", "restart"}

\* A start or restart is spawned only where the goal asks, after a clear
\* of the start limit, and only a restart goal restarts.
LaunchAsked ==
    Launches # {} =>
        /\ Asked
        /\ "clear" \in spawned
        /\ Launches = IF goal = "Restart" THEN {"restart"} ELSE {"start"}

\* A release spawns only a stop, and only of a unit it first observed
\* holding the instance lock: a failed state stays for a later recover,
\* and a restore puts back the first state.
ReleaseStops ==
    goal = "Release" =>
        spawned \subseteq {"stop"} /\ (spawned # {} => first \in Holding)

\* A drive that ends without failure or launch was not asked for one; a
\* halt or release stopped a unit it first observed holding the lock, and
\* a halt cleared a failed state it last observed.
Reached ==
    phase = "reached" =>
        /\ ~Asked
        /\ goal \in {"Halt", "Release"} /\ first \in Holding
           => "stop" \in spawned
        /\ goal = "Halt" /\ last = "Failed" => "clear" \in spawned
====
