---- MODULE LocalWatch ----
\* LOCAL's watch of a sync root's folders: WATCHING in src/local.f.
\* state is the table's state and ev the event of the step a move takes,
\* None for a move that steps nothing. The folders are the root, a in it
\* and b in a, so a clean folder can vouch for a child the walk skips.
\* Each has a journal record (none, clean, stirred, or listed or tried by
\* the running scan), a kernel watch while the instance is open, and a
\* published row (a directory, unknown or gone; the root has none and
\* counts as a directory) over stored rows beneath it, current unless a
\* publication dropped them. A change in a folder queues an event when it
\* is watched, else none; an overflow drops the event and queues a loss;
\* a folder replaced by a look-alike loses its watch, queues an ignored
\* event and changes its parent; one moved away during a scan, and back,
\* changes its parent, and both watches hear it. Hearing, only before a
\* scan, stirs, forgets or steps lost, as a throw while hearing does. A
\* scan starts per the table and walks: a full one from the root, an
\* armed one from each stirred record in path order; either enters a
\* folder its listing leads to unless the folder's record is clean, which
\* takes the watch the record names and a directory row. A listing adds
\* a child's watch, records it (replacing any record at its path) and
\* lists it; a child it cannot reach before the watch is added is
\* published unknown, its rows staged gone and its record left as it
\* was, and one found changing is unknown and tried. A stirred folder's
\* listing restates its own row; a stirred record already staged,
\* missing, replaced or answered by another wd stays tried, stirred once
\* the scan ends. A scan publishes what it staged, forgetting the records
\* at paths it staged gone, or is abandoned; one that throws ends with no
\* step. dirty holds the folders changed since their last published
\* listing, fresh those the running scan listed with no change since,
\* away the folder moved off its path.
EXTENDS FiniteSets
Folders == {"root", "a", "b"}
Children == {"a", "b"}
Parent == [f \in Children |-> IF f = "a" THEN "root" ELSE "a"]
Above(f) ==
    CASE f = "root" -> {}
      [] f = "a" -> {"root"}
      [] f = "b" -> {"root", "a"}
Path(f) == Above(f) \cup {f}
Below(f) == {g \in Folders : f \in Above(g)}
Kids(f) == {g \in Children : Parent[g] = f}
States == {"blind", "arming", "armed"}
Events ==
    {"start", "due", "published", "refused", "abandoned", "lost", "doubt"}
None == "none"
Records == {"none", "clean", "stirred", "listed", "tried"}
Phases == {"idle", "starting", "opening", "listing"}
Rows == {"dir", "unknown", "gone"}
\* What the running scan staged at a folder's path: nothing, its row as
\* a directory, that and the rows beneath it as its listing found them,
\* or its row unknown or gone with every row beneath it gone.
Stages == {"none", "seen", "listed", "unknown", "gone"}

VARIABLES state, ev, rec, watched, queued, forgot, overflow,
          dirty, fresh, phase, todo, row, current, staged, away
vars == <<state, ev, rec, watched, queued, forgot, overflow,
          dirty, fresh, phase, todo, row, current, staged, away>>
kernel == <<watched, queued, forgot, overflow>>
stored == <<row, current>>

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
NoStage == [f \in Folders |-> "none"]

\* A step on e; r is the records after it unless it blinds the watch,
\* which closes the instance, or arms it, which forgets every record. A
\* blind watch's records are read by nothing, so here they go at once.
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
    /\ row = [f \in Folders |-> "dir"]
    /\ current = [f \in Folders |-> TRUE]
    /\ staged = NoStage
    /\ away = {}

ChangedIn(S) ==
    /\ dirty' = [f \in Folders |-> dirty[f] \/ f \in S]
    /\ fresh' = [f \in Folders |-> fresh[f] /\ f \notin S]
Changed(f) == ChangedIn({f})

\* A change in f; its event is queued only while f is watched.
Change(f) ==
    /\ Changed(f)
    /\ queued' = IF watched[f] THEN queued \cup {f} ELSE queued
    /\ ev' = None
    /\ UNCHANGED <<state, rec, watched, forgot, overflow, phase, todo,
                   stored, staged, away>>

\* A change whose event the full queue dropped.
Overflow(f) ==
    /\ state # "blind"
    /\ Changed(f)
    /\ overflow' = TRUE
    /\ ev' = None
    /\ UNCHANGED <<state, rec, watched, queued, forgot, phase, todo,
                   stored, staged, away>>

\* f replaced at its path by a look-alike: the kernel drops its watch and
\* queues IN-IGNORED, and the parent's watch hears the entry change. Its
\* record still names the old wd. The root's replacement is Lose's.
Replace(f) ==
    /\ watched[f] /\ f \notin away
    /\ ChangedIn({f, Parent[f]})
    /\ watched' = [watched EXCEPT ![f] = FALSE]
    /\ forgot' = forgot \cup {f}
    /\ queued' =
        IF watched[Parent[f]] THEN queued \cup {Parent[f]} ELSE queued
    /\ ev' = None
    /\ UNCHANGED <<state, rec, overflow, phase, todo, stored, staged, away>>

\* f moved off its path or back: its own watch hears IN-MOVE-SELF and its
\* parent's the entry, each while watched.
Moves(f) ==
    /\ Changed(Parent[f])
    /\ queued' = queued \cup {g \in {f, Parent[f]} : watched[g]}
    /\ ev' = None
    /\ UNCHANGED <<state, rec, watched, forgot, overflow, phase, todo,
                   stored, staged>>

\* One folder at a time moves away during a scan; it may return at once.
Away(f) ==
    /\ phase = "listing" /\ away = {}
    /\ away' = {f}
    /\ Moves(f)

Back(f) ==
    /\ f \in away
    /\ away' = {}
    /\ Moves(f)

Heard(f) ==
    CASE f \in forgot -> "none"
      [] f \in queued /\ rec[f] # "none" -> "stirred"
      [] OTHER -> rec[f]

\* WATCH-HEAR, before a scan starts: a loss steps lost; else each event
\* stirs or forgets.
Hear ==
    /\ phase = "idle"
    /\ queued # {} \/ forgot # {} \/ overflow
    /\ IF overflow
       THEN Step("lost", rec)
       ELSE /\ rec' = [f \in Folders |-> Heard(f)]
            /\ queued' = {} /\ forgot' = {}
            /\ ev' = None
            /\ UNCHANGED <<state, watched, overflow>>
    /\ UNCHANGED <<dirty, fresh, phase, todo, stored, staged, away>>

\* HEARD-ALL: a throw while reading the events, whatever its code, steps
\* lost before it is rethrown, so the events it read cannot hide.
HearThrown ==
    /\ phase = "idle"
    /\ queued # {} \/ forgot # {} \/ overflow
    /\ Step("lost", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo, stored, staged, away>>

\* A read failure, an unmount, or a root self-event.
Lose ==
    /\ state # "blind"
    /\ Step("lost", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo, stored, staged, away>>

Doubt ==
    /\ Step("doubt", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo, stored, staged, away>>

Begin ==
    /\ phase = "idle"
    /\ phase' = "starting"
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, fresh, todo, stored, staged,
                   away>>

\* WATCH-STARTED: armed, a step on start or, past the hour, due; one
\* still armed walks from the stirred records.
StartArmed ==
    /\ phase = "starting" /\ state = "armed"
    /\ \E e \in {"start", "due"} :
        /\ Step(e, rec)
        /\ phase' =
            IF Moved(state, e) = "armed" THEN "listing" ELSE "opening"
    /\ UNCHANGED <<dirty, fresh, todo, stored, staged, away>>

StartArming ==
    /\ phase = "starting" /\ state = "arming"
    /\ Step("start", rec)
    /\ phase' = "opening"
    /\ UNCHANGED <<dirty, fresh, todo, stored, staged, away>>

StartBlind ==
    /\ phase = "starting" /\ state = "blind"
    /\ phase' = "opening"
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, fresh, todo, stored, staged,
                   away>>

\* A new instance, or a refused one; either way the walk is full, from
\* the root.
Open ==
    /\ phase = "opening"
    /\ \E e \in {"start", "refused"} : Step(e, rec)
    /\ phase' = "listing"
    /\ todo' = {"root"}
    /\ UNCHANGED <<dirty, fresh, stored, staged, away>>

\* WATCH-CLEAN?: f's record names the wd its watch answers, so f kept the
\* watch the record was made with, is clean, and f's row is a directory.
Vouches(f) == rec[f] = "clean" /\ row[f] = "dir" /\ watched[f]

\* f's listing staged: f's row a directory and the rows beneath it as
\* found; each child at its path waits in todo, each away child is staged
\* gone with everything beneath it.
Lists(f) ==
    LET gone == Kids(f) \cap away
        lost == gone \cup UNION {Below(g) : g \in gone}
    IN
    /\ staged' = [g \in Folders |->
        IF g = f THEN "listed"
        ELSE IF g \in lost THEN "gone" ELSE staged[g]]
    /\ fresh' = [g \in Folders |-> g = f \/ (fresh[g] /\ g \notin lost)]
    /\ todo' = (todo \ ({f} \cup lost)) \cup (Kids(f) \ gone)

\* f staged k, unknown or gone, and every row beneath it gone; nothing
\* beneath it is walked.
Unseen(f, k) ==
    LET lost == {f} \cup Below(f) IN
    /\ staged' = [g \in Folders |->
        IF g = f THEN k ELSE IF g \in lost THEN "gone" ELSE staged[g]]
    /\ fresh' = [g \in Folders |-> fresh[g] /\ g \notin lost]
    /\ todo' = todo \ lost

Visiting(f) == phase = "listing" /\ f \in todo

\* A listing meets f: a mount over it, or its stat or open failing, or f
\* away, publishes it unknown before its watch is added; its record stays
\* as it was. The root's failure throws the scan.
ListUnknown(f) ==
    /\ Visiting(f) /\ f # "root"
    /\ Unseen(f, "unknown")
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, phase, stored, away>>

\* f's watch added and f clean: its row is restated, nothing beneath it
\* walked.
ListSkipped(f) ==
    /\ Visiting(f) /\ f \notin away
    /\ state # "blind" /\ Vouches(f)
    /\ staged' = [staged EXCEPT ![f] = "seen"]
    /\ todo' = todo \ {f}
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, fresh, phase, stored, away>>

\* f's watch added: an unwatched f gets a new wd, so the old wd's pending
\* IN-IGNORED forgets no record at f.
Rewatched(f) ==
    /\ watched' = [watched EXCEPT ![f] = TRUE]
    /\ forgot' = IF watched[f] THEN forgot ELSE forgot \ {f}

\* f's watch added and recorded, replacing any record at its path, then f
\* listed.
List(f) ==
    /\ Visiting(f) /\ f \notin away
    /\ state # "blind" /\ ~Vouches(f)
    /\ Rewatched(f)
    /\ rec' = [rec EXCEPT ![f] = "listed"]
    /\ Lists(f)
    /\ ev' = None
    /\ UNCHANGED <<state, queued, overflow, dirty, phase, stored, away>>

\* f's watch added and recorded, then f found changing: f is published
\* unknown, its rows staged gone, and tried.
ListFailed(f) ==
    /\ Visiting(f) /\ f # "root" /\ f \notin away
    /\ state # "blind" /\ ~Vouches(f)
    /\ Rewatched(f)
    /\ rec' = [rec EXCEPT ![f] = "tried"]
    /\ Unseen(f, "unknown")
    /\ ev' = None
    /\ UNCHANGED <<state, queued, overflow, dirty, phase, stored, away>>

\* A blind watch adds no watch and lists f.
ListBlind(f) ==
    /\ Visiting(f) /\ f \notin away
    /\ state = "blind"
    /\ Lists(f)
    /\ ev' = None
    /\ UNCHANGED <<state, rec, kernel, dirty, phase, stored, away>>

\* inotify refuses f's watch; f is still listed.
Refuse(f) ==
    /\ Visiting(f) /\ f \notin away
    /\ state # "blind"
    /\ Step("refused", rec)
    /\ Lists(f)
    /\ UNCHANGED <<dirty, phase, stored, away>>

\* NEXT-STIRRED: the stirred record first in path byte order, once the
\* walk from the one before it is done.
Stirred(f) ==
    /\ phase = "listing" /\ todo = {}
    /\ rec[f] = "stirred"
    /\ \A g \in Above(f) : rec[g] # "stirred"

\* SCAN-STAGED?: the scan staged an observation at f's path; the root
\* has none.
Staged(f) == f # "root" /\ staged[f] # "none"
Here(f) == Path(f) \cap away = {}

\* STIRRED-LISTED leaves f tried: staged already, missing, a component
\* replaced, its open or listing failing, or another wd answering at a
\* path other than the root, whose other wd is Doubt.
StirredTried(f) ==
    /\ Stirred(f)
    /\ rec' = [rec EXCEPT ![f] = "tried"]
    /\ ev' = None
    /\ UNCHANGED <<state, kernel, dirty, fresh, phase, todo, stored,
                   staged, away>>

\* STIRRED-WATCHED: the folder opened at f's path answers its record's wd
\* and is listed, its own row restated.
StirredListed(f) ==
    /\ Stirred(f) /\ ~Staged(f) /\ Here(f)
    /\ state # "blind" /\ watched[f]
    /\ rec' = [rec EXCEPT ![f] = "listed"]
    /\ Lists(f)
    /\ ev' = None
    /\ UNCHANGED <<state, kernel, dirty, phase, stored, away>>

\* inotify refuses the opened folder's watch.
StirredRefused(f) ==
    /\ Stirred(f) /\ ~Staged(f) /\ Here(f)
    /\ state # "blind"
    /\ Step("refused", rec)
    /\ UNCHANGED <<dirty, fresh, phase, todo, stored, staged, away>>

Cleaned(f) ==
    CASE staged[f] = "gone" -> "none"
      [] rec[f] = "listed" -> "clean"
      [] rec[f] = "tried" -> "stirred"
      [] OTHER -> rec[f]
Restirred(f) ==
    IF rec[f] \in {"listed", "tried"} THEN "stirred" ELSE rec[f]
Restated(f) ==
    CASE staged[f] \in {"seen", "listed"} -> "dir"
      [] staged[f] \in {"unknown", "gone"} -> staged[f]
      [] OTHER -> row[f]
Kept(f) ==
    CASE staged[f] = "listed" -> TRUE
      [] staged[f] \in {"unknown", "gone"} -> FALSE
      [] OTHER -> current[f]

Ended ==
    /\ phase' = "idle" /\ todo' = {}
    /\ fresh' = Unwatched
    /\ staged' = NoStage

\* PUBLISH-SCAN's commit, once the walk is done and nothing is stirred,
\* publishes what the scan staged, forgets the records at paths it
\* staged gone, cleans what it listed and stirs what it tried.
Publish ==
    /\ phase = "listing" /\ todo = {}
    /\ \A f \in Folders : rec[f] # "stirred"
    /\ Step("published", [f \in Folders |-> Cleaned(f)])
    /\ row' = [f \in Folders |-> Restated(f)]
    /\ current' = [f \in Folders |-> Kept(f)]
    /\ dirty' = [f \in Folders |-> dirty[f] /\ ~fresh[f]]
    /\ Ended
    /\ UNCHANGED away

\* WITH-SCAN drops what an unpublished scan staged and stirs again what
\* it listed or tried.
Abandon ==
    /\ phase = "listing"
    /\ Step("abandoned", [f \in Folders |-> Restirred(f)])
    /\ UNCHANGED <<dirty, stored, away>>
    /\ Ended

Throw ==
    /\ phase = "listing"
    /\ rec' = [f \in Folders |-> Restirred(f)]
    /\ ev' = None
    /\ UNCHANGED <<state, kernel, dirty, stored, away>>
    /\ Ended

Next ==
    \/ \E f \in Folders :
        \/ Change(f) \/ Overflow(f)
        \/ List(f) \/ ListFailed(f) \/ ListBlind(f) \/ Refuse(f)
        \/ ListUnknown(f) \/ ListSkipped(f)
        \/ StirredTried(f) \/ StirredListed(f) \/ StirredRefused(f)
    \/ \E f \in Children : Replace(f) \/ Away(f) \/ Back(f)
    \/ Hear \/ HearThrown \/ Lose \/ Doubt
    \/ Begin \/ StartArmed \/ StartArming \/ StartBlind \/ Open
    \/ Publish \/ Abandon \/ Throw
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state \in States
    /\ ev \in Events \cup {None}
    /\ rec \in [Folders -> Records]
    /\ watched \in [Folders -> BOOLEAN]
    /\ queued \subseteq Folders /\ forgot \subseteq Children
    /\ overflow \in BOOLEAN
    /\ dirty \in [Folders -> BOOLEAN]
    /\ fresh \in [Folders -> BOOLEAN]
    /\ phase \in Phases
    /\ todo \subseteq Folders
    /\ row \in [Folders -> Rows] /\ row["root"] = "dir"
    /\ current \in [Folders -> BOOLEAN]
    /\ staged \in [Folders -> Stages]
    /\ staged["root"] \in {"none", "seen", "listed"}
    /\ away \subseteq Children

\* Only a published scan cleans a record; a blind watch holds none, as the
\* model drops what nothing reads; a clean record is never at a gone row,
\* and a folder that vouches for what the walk skips beneath it has a
\* directory row and current rows beneath it.
Clean ==
    /\ state = "blind" => rec = NoRecords /\ watched = Unwatched
    /\ \A f \in Folders :
        rec[f] = "clean" => state = "armed" /\ row[f] # "gone"
    /\ \A f \in Folders :
        Vouches(f) => current[f]

\* Once the pending events are heard: the records, f clean as WATCH-CLEAN?
\* answers, and whether the walk from a stirred record reaches f.
VouchesNext(f) == Heard(f) = "clean" /\ row[f] = "dir" /\ watched[f]
Recorded(f) ==
    \E g \in Path(f) :
        /\ Heard(g) = "stirred"
        /\ \A h \in Path(f) \ Path(g) : ~VouchesNext(h)
\* f at its path with its stored rows possibly wrong: changed since its
\* last published listing, its rows dropped, or its row not a directory.
Stale(f) ==
    Here(f) /\ (dirty[f] \/ ~current[f] \/ row[f] # "dir")
Covered(f) == \E g \in Path(f) : row[g] = "unknown"

\* No change below a clean folder stays unrecorded: before an armed
\* watch's scan, a folder whose stored rows may be wrong lies beneath an
\* unknown row, which claims nothing, or the walk from a stirred record
\* reaches it once the kernel's events are heard, or a loss is queued.
Unhidden ==
    phase = "idle" /\ state = "armed" /\ ~overflow =>
        \A f \in Folders : Stale(f) /\ ~Covered(f) => Recorded(f)

====
