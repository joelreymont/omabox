---- MODULE DownloadingFollows ----
\* Follows: every step between DOWNLOADING's states, and every step of its
\* lines (Run), one that keeps the state included, is one of its lines,
\* and every line's step moves as the line says. Out is a throw out of
\* READ-OUT, which ends the run; a fetch is never re-entered.
EXTENDS Downloading
T == INSTANCE DownloadingTable
Out == "out"
At == IF thrown THEN Out ELSE step
Walks(l) ==
    CASE l = <<"opened", "passed", "streaming">> -> \E n \in Bytes : Passed(n)
      [] l = <<"opened", "other", "buffering">> -> Buffer("opened")
      [] l = <<"opened", "response", "answered">> -> Last("opened", "answered")
      [] l = <<"opened", "failure", "lost">> -> Last("opened", "lost")
      [] l = <<"streaming", "held", "streaming">> -> \E r \in Bytes : Held(r)
      [] l = <<"streaming", "response", "drained">> -> Drain
      [] l = <<"streaming", "short", "short">> -> Short
      [] l = <<"streaming", "failure", "lost">> -> Lose
      [] l = <<"streaming", "overrun", "overran">> -> \E r \in Bytes : Overrun(r)
      [] l = <<"streaming", "unread", "cancelled">> -> Unread
      [] l = <<"buffering", "chunk", "buffering">> -> Buffer("buffering")
      [] l = <<"buffering", "response", "answered">> -> Last("buffering", "answered")
      [] l = <<"buffering", "failure", "lost">> -> Last("buffering", "lost")
Line(l) == At = l[1] /\ At' = l[3]
Follows ==
    [][ /\ (At' # At \/ Run) => \/ \E l \in T!Lines : Line(l) /\ Walks(l)
                                \/ At' = Out
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
