---- MODULE UploadSessionTable ----
\* The lines of SESSION, src/dropbox.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"single", "committed", "ended">>,
    <<"single", "untrusted", "ended">>,
    <<"single", "unsure", "ended">>,
    <<"single", "failed", "ended">>,
    <<"starting", "opened", "appending">>,
    <<"starting", "unsure", "ended">>,
    <<"starting", "failed", "ended">>,
    <<"appending", "stored", "appending">>,
    <<"appending", "complete", "finishing">>,
    <<"appending", "unsure", "appending">>,
    <<"appending", "cut", "ended">>,
    <<"appending", "gone", "restarting">>,
    <<"appending", "failed", "ended">>,
    <<"finishing", "committed", "ended">>,
    <<"finishing", "untrusted", "ended">>,
    <<"finishing", "unsure", "ended">>,
    <<"finishing", "gone", "verifying">>,
    <<"finishing", "failed", "ended">>,
    <<"verifying", "same", "ended">>,
    <<"verifying", "elsewhere", "ended">>,
    <<"verifying", "wait", "ended">>,
    <<"verifying", "other", "restarting">>,
    <<"verifying", "unlinked", "ended">>,
    <<"restarting", "once", "starting">>,
    <<"restarting", "twice", "ended">>
}
====
