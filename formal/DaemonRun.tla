------------------------------- MODULE DaemonRun -------------------------------
\* The daemon's run, DAEMON-RUN in src/daemon.f. It prepares its paths,
\* takes the instance lock, opens the journal, tells systemd it is ready,
\* validates its configuration, starts a Dropbox session and validates it,
\* then syncs and long-polls. A failure that continues waits and tries its
\* state again, a failed long poll from syncing; one that stops ends the
\* run. held is what the run has made that a later step reads; failure is
\* the last failure's disposition, continues (retry, environmental) or
\* stops (user-action, invariant), none before one; pass is how the last
\* pass that completed or met local changes ended, none before one.

States == {"preparing", "locking", "opening", "notifying", "configuring",
    "starting", "validating", "syncing", "polling", "stopped"}
Tried == States \ {"stopped"}

\* What each state's step reads or relies on: the lock keeps a second
\* daemon off the journal, readiness tells systemd both are held, and a
\* pass or a long poll runs only on a session validated against the
\* journal's binding.
Needs == [preparing |-> {}, locking |-> {"paths"},
    opening |-> {"paths", "lock"}, notifying |-> {"lock", "journal"},
    configuring |-> {"paths"}, starting |-> {"journal", "config"},
    validating |-> {"journal", "session"},
    syncing |-> {"journal", "config", "validated"},
    polling |-> {"journal", "validated"}, stopped |-> {}]

\* What each state's step makes when it succeeds.
Gives == [preparing |-> {"paths"}, locking |-> {"lock"},
    opening |-> {"journal"}, notifying |-> {}, configuring |-> {"config"},
    starting |-> {"session"}, validating |-> {"validated"},
    syncing |-> {}, polling |-> {}, stopped |-> {}]

\* Where each step that succeeds goes; a pass's are Complete and Fresh.
After == [preparing |-> "locking", locking |-> "opening",
    opening |-> "notifying", notifying |-> "configuring",
    configuring |-> "starting", starting |-> "validating",
    validating |-> "syncing", polling |-> "syncing"]

VARIABLES state, held, failure, pass

vars == <<state, held, failure, pass>>

Init ==
    /\ state = "preparing"
    /\ held = {}
    /\ failure = "none"
    /\ pass = "none"

Ok ==
    /\ state \in DOMAIN After
    /\ state' = After[state]
    /\ held' = held \cup Gives[state]
    /\ UNCHANGED <<failure, pass>>

\* A pass that completed, with or without sync errors.
Complete ==
    /\ state = "syncing"
    /\ state' = "polling"
    /\ pass' = "complete"
    /\ UNCHANGED <<held, failure>>

\* Local state changed during the pass, which runs again.
Fresh ==
    /\ state = "syncing"
    /\ pass' = "fresh"
    /\ UNCHANGED <<state, held, failure>>

Retry ==
    /\ state \in Tried
    /\ state' = IF state = "polling" THEN "syncing" ELSE state
    /\ failure' = "continues"
    /\ UNCHANGED <<held, pass>>

Stop ==
    /\ state \in Tried
    /\ state' = "stopped"
    /\ failure' = "stops"
    /\ UNCHANGED <<held, pass>>

Next == Ok \/ Complete \/ Fresh \/ Retry \/ Stop

Spec == Init /\ [][Next]_vars

\* Each step runs with what it reads made and what it makes not yet made:
\* the lock is taken, the journal opened and a session started only while
\* the run holds none.
Ordered == Needs[state] \subseteq held /\ Gives[state] \cap held = {}

\* The daemon long-polls only after a pass completed; a pass that found
\* local changes, or failed, runs again first.
PollsAfterPass == state = "polling" => pass = "complete"

\* Only a failure that stops ends the run; STOP and the exit status read
\* it.
StopsForFailure == state = "stopped" => failure = "stops"

================================================================================
