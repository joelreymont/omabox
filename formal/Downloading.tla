------------------------------ MODULE Downloading ------------------------------
\* One files/download transfer as DOWNLOADING (src/dropbox.f) reads it. The
\* first chunk's status and CHECKED decide whether the body reaches the
\* reader, which asks up to room bytes a read and may return at any time;
\* the server may send fewer than Size bytes, Size, or one more, and the
\* transfer may fail at any read. The transfer ends once: by its last read,
\* or by closing its connection, which the overrun and unread lines' ABANDON
\* and READ-OUT for a throw do. A throw ends the run.
EXTENDS Naturals

Size == 2
Bytes == 1..2
Finals == {"answered", "drained", "lost", "cancelled", "overran", "short"}
Min(a, b) == IF a < b THEN a ELSE b

VARIABLES step, transfer, first, left, total, buffered, reader, thrown
vars == <<step, transfer, first, left, total, buffered, reader, thrown>>

Init ==
    /\ step = "opened"
    /\ transfer = "flight"
    /\ first \in {"good", "bad", "other"}
    /\ left = 0
    /\ total = 0
    /\ buffered = 0
    /\ reader = "idle"
    /\ thrown = FALSE

\* The transfer's last read, a response or a failure, ends it in t.
Last(s, t) ==
    /\ ~thrown
    /\ step = s
    /\ step' = t
    /\ transfer' = "ended"
    /\ UNCHANGED <<first, left, total, buffered, reader, thrown>>

\* A 2xx first chunk CHECKED passes goes to the reader.
Passed(n) ==
    /\ ~thrown
    /\ step = "opened"
    /\ first = "good"
    /\ step' = "streaming"
    /\ left' = n
    /\ reader' = "reading"
    /\ UNCHANGED <<transfer, first, total, buffered, thrown>>

\* Another status's chunks go to the answer buffer.
Buffer(s) ==
    /\ ~thrown
    /\ step = s
    /\ first = "other"
    /\ buffered < 2
    /\ step' = "buffering"
    /\ buffered' = buffered + 1
    /\ UNCHANGED <<transfer, first, left, total, reader, thrown>>

\* A read of room bytes: those held, or once all are taken a new chunk's,
\* the body at most one byte past Size.
Reads == ~thrown /\ step = "streaming" /\ reader = "reading"
Chunks == IF left > 0 THEN {left} ELSE {n \in Bytes : total + n <= Size + 1}

Held(room) ==
    /\ Reads
    /\ \E n \in Chunks :
          /\ total + Min(room, n) <= Size
          /\ total' = total + Min(room, n)
          /\ left' = n - Min(room, n)
    /\ UNCHANGED <<step, transfer, first, buffered, reader, thrown>>

\* A read that would take a byte past Size abandons the transfer.
Overrun(room) ==
    /\ Reads
    /\ \E n \in Chunks : total + Min(room, n) > Size
    /\ step' = "overran"
    /\ transfer' = "abandoned"
    /\ UNCHANGED <<first, left, total, buffered, reader, thrown>>

\* Every byte taken, the transfer's last read ends the body.
Drain == Reads /\ left = 0 /\ total = Size /\ Last("streaming", "drained")
Short == Reads /\ left = 0 /\ total # Size /\ Last("streaming", "short")
Lose == Reads /\ left = 0 /\ Last("streaming", "lost")

Return ==
    /\ ~thrown
    /\ reader = "reading"
    /\ reader' = "returned"
    /\ UNCHANGED <<step, transfer, first, left, total, buffered, thrown>>

\* BODIED abandons a transfer its returned reader left in flight.
Unread ==
    /\ ~thrown
    /\ step = "streaming"
    /\ reader = "returned"
    /\ step' = "cancelled"
    /\ transfer' = "abandoned"
    /\ UNCHANGED <<first, left, total, buffered, reader, thrown>>

\* A throw from CHECKED, an action or the reader leaves READ-OUT, which
\* abandons the transfer unless the machine is final.
Throw ==
    /\ ~thrown
    /\ (step \in {"opened", "buffering"} \/ reader = "reading")
    /\ thrown' = TRUE
    /\ transfer' = IF step \in Finals THEN transfer ELSE "abandoned"
    /\ UNCHANGED <<step, first, left, total, buffered, reader>>

\* The steps DOWNLOADING's lines take. The reader returns, and a throw
\* leaves READ-OUT, outside them.
Run ==
    \/ \E n \in Bytes : Passed(n)
    \/ Buffer("opened")
    \/ Buffer("buffering")
    \/ Last("opened", "answered")
    \/ Last("opened", "lost")
    \/ Last("buffering", "answered")
    \/ Last("buffering", "lost")
    \/ \E room \in Bytes : Held(room)
    \/ \E room \in Bytes : Overrun(room)
    \/ Drain
    \/ Short
    \/ Lose
    \/ Unread

Next == Run \/ Return \/ Throw

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ step \in {"opened", "streaming", "buffering"} \cup Finals
    /\ transfer \in {"flight", "ended", "abandoned"}
    /\ first \in {"good", "bad", "other"}
    /\ left \in 0..2
    /\ total \in 0..Size + 1
    /\ buffered \in 0..2
    /\ reader \in {"idle", "reading", "returned"}
    /\ thrown \in BOOLEAN

\* READ-OUT closes the connection of just the transfers in flight: FINAL?
\* holds just when the transfer ended, cancelled or overran.
FinalIsEnded ==
    transfer = IF step \in {"cancelled", "overran"} THEN "abandoned"
               ELSE IF step \in Finals THEN "ended"
               ELSE IF thrown THEN "abandoned"
               ELSE "flight"

\* No byte of the file reaches the reader before CHECKED passed, nor the
\* answer buffer, whose start REPORT logs.
CheckedFirst ==
    /\ reader # "idle" => first = "good"
    /\ buffered > 0 => first = "other"

\* The reader takes no byte past the file's end; SETTLED answers done only
\* for a body drained whole or one its reader left.
Sized ==
    /\ total <= Size
    /\ step = "drained" => total = Size
    /\ step = "cancelled" => reader = "returned"
=============================================================================
