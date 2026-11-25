---- MODULE LocalWatch ----
\* LOCAL's watch of a sync root's folders: WATCHING in src/local.f.
\* state is the table's state and ev the event of the step a move takes,
\* None for a move that steps nothing. Each folder has a journal record
\* (none, clean, stirred, or listed or tried by the running scan) and a
\* kernel watch while the instance is open. A change in a folder queues
\* an event when it is watched, else none; an overflow drops the event
\* and queues a loss; a folder replaced loses its watch and queues an
\* ignored event. Hearing stirs, forgets or steps lost. A scan starts
\* per the table, lists every folder unless armed, then only the folders
\* not clean, adds each one's watch before listing it (a listing that
\* fails leaves it tried, stirred once the scan ends), and publishes or
\* is abandoned; a scan that throws ends with no step. dirty holds the
\* folders changed since their last published listing, fresh those the
\* running scan listed with no change since.
EXTENDS FiniteSets
Folders == {"root", "a"}
States == {"blind", "arming", "armed"}
Events ==
    {"start", "due", "published", "refused", "abandoned", "lost", "doubt"}
None == "none"
Records == {"none", "clean", "stirred", "listed", "tried"}
Phases == {"idle", "starting", "opening", "listing"}

VARIABLES state, ev, rec, watched, queued, forgot, overflow,
          dirty, fresh, phase, todo
vars == <<state, ev, rec, watched, queued, forgot, overflow,
          dirty, fresh, phase, todo>>
kernel == <<watched, queued, forgot, overflow>>

\* The machine: a scan's start arms a blind watch, a publication arms an
\* arming one, and an armed one stays armed while scans start under the
\* hour, publish or are abandoned; anything else blinds it.
Moved(s, e) ==
    CASE s = "blind" -> IF e = "start" THEN "arming" ELSE "blind"
      [] s = "arming" -> IF e = "published" THEN "armed" ELSE "blind"
      [] s = "armed" ->
            IF e \in {"start", "published", "abandoned"}
            THEN "armed" ELSE "blind"

NoRecords == [f \in Folders |-> "none"]
Unwatched == [f \in Folders |-> FALSE]

\* A step on e; r is the records after it unless it blinds the watch,
\* which closes the instance and forgets every record, or arms it,
\* which forgets every record.
Step(e, r) ==
    LET s == Moved(state, e) IN
    /\ state' = s
    /\ ev' = e
    /\ IF \/ s = "blind" /\ state # "blind"
          \/ s = "arming" /\ state = "blind"
       THEN /\ rec' = NoRecords
            /\ watched' = Unwatched
            /\ queued' = {} /\ forgot' = {} /\ overflow' = FALSE
       ELSE /\ rec' = r
            /\ UNCHANGED kernel

Init ==
    /\ state = "blind"
    /\ ev = None
    /\ rec = NoRecords
    /\ watched = Unwatched
    /\ queued = {} /\ forgot = {} /\ overflow = FALSE
    /\ dirty \in [Folders -> BOOLEAN]
    /\ fresh = Unwatched
    /\ phase = "idle"
    /\ todo = {}

Changed(f) ==
    /\ dirty' = [dirty EXCEPT ![f] = TRUE]
    /\ fresh' = [fresh EXCEPT ![f] = FALSE]

\* A change in f; its event is queued only while f is watched.
Change(f) ==
    /\ Changed(f)
    /\ queued' = IF watched[f] THEN queued \cup {f} ELSE queued
    /\ ev' = None
    /\ UNCHANGED <<state, rec, watched, forgot, overflow, phase, todo>>

\* A change whose event the full queue dropped.
Overflow(f) ==
    /\ state # "blind"
    /\ Changed(f)
    /\ overflow' = TRUE
    /\ ev' = None
    /\ UNCHANGED <<state, rec, watched, queued, forgot, phase, todo>>

\* f replaced: the kernel drops its watch and queues IN-IGNORED.
Replace(f) ==
    /\ watched[f]
    /\ Changed(f)
    /\ watched' = [watched EXCEPT ![f] = FALSE]
    /\ forgot' = forgot \cup {f}
    /\ ev' = None
    /\ UNCHANGED <<state, rec, queued, overflow, phase, todo>>

Heard(f) ==
    CASE f \in forgot -> "none"
      [] f \in queued /\ rec[f] # "none" -> "stirred"
      [] OTHER -> rec[f]

\* WATCH-HEAR: a loss steps lost; else each event stirs or forgets.
Hear ==
    /\ queued # {} \/ forgot # {} \/ overflow
    /\ IF overflow
       THEN Step("lost", rec)
       ELSE /\ rec' = [f \in Folders |-> Heard(f)]
            /\ queued' = {} /\ forgot' = {}
            /\ ev' = None
            /\ UNCHANGED <<state, watched, overflow>>
    /\ UNCHANGED <<dirty, fresh, phase, todo>>

\* A read failure, an unmount, or a root self-event.
Lose ==
    /\ state # "blind"
    /\ Step("lost", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo>>

Doubt ==
    /\ Step("doubt", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo>>

Begin ==
    /\ phase = "idle"
    /\ phase' = "starting"
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, fresh, todo>>

\* WATCH-STARTED: armed, a step on start or, past the hour, due; one
\* still armed lists the folders not clean.
StartArmed ==
    /\ phase = "starting" /\ state = "armed"
    /\ \E e \in {"start", "due"} :
        /\ Step(e, rec)
        /\ IF Moved(state, e) = "armed"
           THEN phase' = "listing"
                /\ todo' = {f \in Folders : rec[f] # "clean"}
           ELSE phase' = "opening" /\ todo' = {}
    /\ UNCHANGED <<dirty, fresh>>

StartArming ==
    /\ phase = "starting" /\ state = "arming"
    /\ Step("start", rec)
    /\ phase' = "opening"
    /\ UNCHANGED <<dirty, fresh, todo>>

StartBlind ==
    /\ phase = "starting" /\ state = "blind"
    /\ phase' = "opening"
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, fresh, todo>>

\* A new instance, or a refused one; either way every folder is listed.
Open ==
    /\ phase = "opening"
    /\ \E e \in {"start", "refused"} : Step(e, rec)
    /\ phase' = "listing"
    /\ todo' = Folders
    /\ UNCHANGED <<dirty, fresh>>

Listed(f) ==
    /\ todo' = todo \ {f}
    /\ fresh' = [fresh EXCEPT ![f] = TRUE]
    /\ UNCHANGED <<dirty, phase>>

\* f's watch added, then f listed; a blind watch adds none.
List(f) ==
    /\ phase = "listing" /\ f \in todo
    /\ state # "blind"
    /\ watched' = [watched EXCEPT ![f] = TRUE]
    /\ rec' = [rec EXCEPT ![f] = "listed"]
    /\ ev' = None
    /\ UNCHANGED <<state, queued, forgot, overflow>>
    /\ Listed(f)

ListBlind(f) ==
    /\ phase = "listing" /\ f \in todo
    /\ state = "blind"
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel>>
    /\ Listed(f)

\* f's watch added, then its listing fails: f is tried, not listed.
ListFailed(f) ==
    /\ phase = "listing" /\ f \in todo
    /\ state # "blind"
    /\ watched' = [watched EXCEPT ![f] = TRUE]
    /\ rec' = [rec EXCEPT ![f] = "tried"]
    /\ ev' = None
    /\ todo' = todo \ {f}
    /\ UNCHANGED <<state, queued, forgot, overflow>>
    /\ UNCHANGED <<dirty, fresh, phase>>

\* inotify refuses f's watch; f is still listed.
Refuse(f) ==
    /\ phase = "listing" /\ f \in todo
    /\ state # "blind"
    /\ Step("refused", rec)
    /\ Listed(f)

Cleaned(f) ==
    CASE rec[f] = "listed" -> "clean"
      [] rec[f] = "tried" -> "stirred"
      [] OTHER -> rec[f]
Restirred(f) ==
    IF rec[f] \in {"listed", "tried"} THEN "stirred" ELSE rec[f]

Ended ==
    /\ phase' = "idle" /\ todo' = {}
    /\ fresh' = Unwatched

\* PUBLISH-SCAN's commit cleans what the scan listed and stirs what it
\* tried.
Publish ==
    /\ phase = "listing" /\ todo = {}
    /\ Step("published", [f \in Folders |-> Cleaned(f)])
    /\ dirty' = [f \in Folders |-> dirty[f] /\ ~fresh[f]]
    /\ Ended

\* WITH-SCAN stirs again what an unpublished scan listed or tried.
Abandon ==
    /\ phase = "listing"
    /\ Step("abandoned", [f \in Folders |-> Restirred(f)])
    /\ UNCHANGED dirty
    /\ Ended

Throw ==
    /\ phase = "listing"
    /\ rec' = [f \in Folders |-> Restirred(f)]
    /\ ev' = None
    /\ UNCHANGED <<state, kernel, dirty>>
    /\ Ended

Next ==
    \/ \E f \in Folders :
        Change(f) \/ Overflow(f) \/ Replace(f)
        \/ List(f) \/ ListFailed(f) \/ ListBlind(f) \/ Refuse(f)
    \/ Hear \/ Lose \/ Doubt
    \/ Begin \/ StartArmed \/ StartArming \/ StartBlind \/ Open
    \/ Publish \/ Abandon \/ Throw
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state \in States
    /\ ev \in Events \cup {None}
    /\ rec \in [Folders -> Records]
    /\ watched \in [Folders -> BOOLEAN]
    /\ queued \subseteq Folders /\ forgot \subseteq Folders
    /\ overflow \in BOOLEAN
    /\ dirty \in [Folders -> BOOLEAN]
    /\ fresh \in [Folders -> BOOLEAN]
    /\ phase \in Phases
    /\ todo \subseteq Folders

\* Only a published scan cleans a record, and a blind watch holds none.
Clean ==
    /\ state = "blind" => rec = NoRecords /\ watched = Unwatched
    /\ \A f \in Folders : rec[f] = "clean" => state = "armed"

\* No change hides behind a clean record: a folder changed since its
\* last published listing is not clean, or the kernel still holds an
\* event for it or a loss, so the next scan lists it again.
Unhidden ==
    \A f \in Folders :
        dirty[f] /\ rec[f] = "clean" =>
            f \in queued \cup forgot \/ overflow

====
