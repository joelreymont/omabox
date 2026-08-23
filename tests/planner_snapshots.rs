use omabox::model::{
    Baseline, ContentIdentity, Decision, DropboxRevision, LocalFile, Observation, RemoteFile,
    UnknownReason,
};
use omabox::planner::plan;

fn content(value: &str) -> ContentIdentity {
    ContentIdentity::new(value)
}

fn local(value: &str) -> Observation<LocalFile> {
    Observation::Present(LocalFile::new(content(value)))
}

fn remote(value: &str, revision: &str) -> Observation<RemoteFile> {
    Observation::Present(RemoteFile::new(
        content(value),
        DropboxRevision::new(revision),
    ))
}

fn present_baseline(value: &str, revision: &str) -> Baseline {
    Baseline::Present(RemoteFile::new(
        content(value),
        DropboxRevision::new(revision),
    ))
}

#[test]
fn human_readable_planner_decisions() {
    let baseline = present_baseline("baseline", "baseline-revision");
    let scenarios: [(&str, Decision); 10] = [
        (
            "initial local file",
            plan(
                &Baseline::Absent,
                &local("local"),
                &Observation::ConfirmedAbsent,
            ),
        ),
        (
            "initial remote file",
            plan(
                &Baseline::Absent,
                &Observation::ConfirmedAbsent,
                &remote("remote", "remote-revision"),
            ),
        ),
        (
            "unchanged",
            plan(
                &baseline,
                &local("baseline"),
                &remote("baseline", "current-revision"),
            ),
        ),
        (
            "local edit",
            plan(
                &baseline,
                &local("local-edit"),
                &remote("baseline", "current-revision"),
            ),
        ),
        (
            "remote edit",
            plan(
                &baseline,
                &local("baseline"),
                &remote("remote-edit", "remote-revision"),
            ),
        ),
        (
            "explicit local deletion",
            plan(
                &baseline,
                &Observation::ConfirmedAbsent,
                &remote("baseline", "current-revision"),
            ),
        ),
        (
            "explicit remote deletion",
            plan(&baseline, &local("baseline"), &Observation::ConfirmedAbsent),
        ),
        (
            "inaccessible local state",
            plan(
                &baseline,
                &Observation::Unknown(UnknownReason::Inaccessible),
                &Observation::ConfirmedAbsent,
            ),
        ),
        (
            "stale remote state",
            plan(
                &baseline,
                &Observation::ConfirmedAbsent,
                &Observation::Unknown(UnknownReason::Stale),
            ),
        ),
        (
            "simultaneous conflicting edits",
            plan(
                &baseline,
                &local("local-edit"),
                &remote("remote-edit", "remote-revision"),
            ),
        ),
    ];

    let mut rendered = String::new();
    for (name, decision) in scenarios {
        rendered.push_str(name);
        rendered.push('\n');
        rendered.push_str(&decision.to_string());
        rendered.push_str("\n\n");
    }

    insta::assert_snapshot!(rendered);
}
