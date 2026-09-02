use std::collections::BTreeSet;
use std::error::Error;
use std::io;

use omabox::model::{
    Baseline, BlockedReason, Conflict, ContentIdentity, Decision, DirectoryCollision,
    DropboxRevision, LocalFile, LocalObservation, NoOpReason, Observation, Operation, RemoteFile,
    RemoteObservation, UnknownReason,
};
use omabox::planner::plan;
use proptest::prelude::*;
use proptest::strategy::ValueTree as _;
use proptest::test_runner::{Config, TestRunner};

/// Content is drawn from two letters so a fresh draw still collides with the
/// baseline often enough to reach the states that compare bytes.
const ALPHABET: &str = "[ab]{1,2}";

/// A baseline and the observation pairs planned against it.
type Scenario = (Baseline, Vec<(LocalObservation, RemoteObservation)>);

fn revision() -> impl Strategy<Value = DropboxRevision> {
    "[a-z0-9]{1,8}".prop_map(DropboxRevision::new)
}

fn unknown_reason() -> impl Strategy<Value = UnknownReason> {
    prop_oneof![
        Just(UnknownReason::Incomplete),
        Just(UnknownReason::Inaccessible),
        Just(UnknownReason::Unavailable),
        Just(UnknownReason::Stale),
        Just(UnknownReason::CursorReset),
        Just(UnknownReason::Unsupported),
    ]
}

/// Local content that either still matches the baseline or has been rewritten.
fn local_observation(baseline: ContentIdentity) -> impl Strategy<Value = LocalObservation> {
    let content = prop_oneof![Just(baseline), ALPHABET.prop_map(ContentIdentity::new)];
    prop_oneof![
        3 => content.prop_map(|content| Observation::Present(LocalFile::new(content))),
        2 => Just(Observation::ConfirmedAbsent),
        1 => Just(Observation::Directory),
        1 => unknown_reason().prop_map(Observation::Unknown),
    ]
}

/// The same for Dropbox, whose revision is always freshly observed so a
/// mutation carrying the baseline revision instead cannot pass unnoticed.
fn remote_observation(baseline: ContentIdentity) -> impl Strategy<Value = RemoteObservation> {
    let content = prop_oneof![Just(baseline), ALPHABET.prop_map(ContentIdentity::new)];
    prop_oneof![
        3 => (content, revision())
            .prop_map(|(content, revision)| Observation::Present(RemoteFile::new(content, revision))),
        2 => Just(Observation::ConfirmedAbsent),
        1 => Just(Observation::Directory),
        1 => unknown_reason().prop_map(Observation::Unknown),
    ]
}

/// Draw the baseline first, then observations derived from its content.
///
/// Drawing all three independently left the planner's comparisons unreachable:
/// over 50 runs of 256 cases, independent `[a-z]{1,8}` content produced
/// `ReplaceLocal` and `DeleteRemote` in 1 run each, `DeleteLocal` and
/// `NoOpReason::ContentMatches` in 2, and `ReplaceRemote` in 3, so the
/// properties about them held vacuously. Present states are weighted above
/// uncertain ones because an `Unknown` observation short-circuits to
/// `Decision::Blocked` before any comparison happens.
fn scenario() -> impl Strategy<Value = Scenario> {
    (ALPHABET.prop_map(ContentIdentity::new), revision()).prop_flat_map(|(content, revision)| {
        let common = RemoteFile::new(content.clone(), revision);
        let baseline = prop_oneof![
            2 => Just(Baseline::Present(common)),
            1 => Just(Baseline::Absent),
            1 => Just(Baseline::Directory),
        ];
        let pairs = prop::collection::vec(
            (
                local_observation(content.clone()),
                remote_observation(content),
            ),
            1..16,
        );
        (baseline, pairs)
    })
}

/// The same baselines, with at least one side of every pair uncertain.
fn uncertain_scenario() -> impl Strategy<Value = Scenario> {
    scenario().prop_flat_map(|(baseline, pairs)| {
        let uncertain = pairs.into_iter().map(|(local, remote)| {
            prop_oneof![
                unknown_reason().prop_map({
                    let remote = remote.clone();
                    move |reason| (Observation::Unknown(reason), remote.clone())
                }),
                unknown_reason().prop_map({
                    let local = local.clone();
                    move |reason| (local.clone(), Observation::Unknown(reason))
                }),
            ]
        });
        (Just(baseline), uncertain.collect::<Vec<_>>())
    })
}

/// Every outcome the planner can reach, down to the variant.
///
/// `Operation::PreserveLocal` and `Operation::PreserveRemote` are absent on
/// purpose: they decode old journals and must never be planned. The coverage
/// test compares the reached outcomes against this list exactly, so planning
/// one would fail it as surely as losing one.
const OUTCOMES: [&str; 21] = [
    "Blocked::BothUnknown",
    "Blocked::LocalUnknown",
    "Blocked::RemoteUnknown",
    "Conflict::DivergentEdits",
    "Conflict::InitialCollision",
    "Conflict::LocalDeletionRemoteEdit",
    "Conflict::RemoteDeletionLocalEdit",
    "CreateLocalDirectory",
    "CreateRemote",
    "CreateRemoteDirectory",
    "DeleteLocal",
    "DeleteLocalDirectory",
    "DeleteRemote",
    "DirectoryCollision::LocalDirectoryRemoteFile",
    "DirectoryCollision::LocalFileRemoteDirectory",
    "InstallLocal",
    "NoOp::BothAbsent",
    "NoOp::ContentMatches",
    "NoOp::DirectoriesMatch",
    "ReplaceLocal",
    "ReplaceRemote",
];

fn operation_name(operation: &Operation) -> &'static str {
    match operation {
        Operation::CreateLocalDirectory => "CreateLocalDirectory",
        Operation::CreateRemoteDirectory => "CreateRemoteDirectory",
        Operation::DeleteLocalDirectory => "DeleteLocalDirectory",
        Operation::CreateRemote { .. } => "CreateRemote",
        Operation::InstallLocal { .. } => "InstallLocal",
        Operation::PreserveLocal { .. } => "PreserveLocal",
        Operation::ReplaceLocal { .. } => "ReplaceLocal",
        Operation::DeleteLocal { .. } => "DeleteLocal",
        Operation::PreserveRemote { .. } => "PreserveRemote",
        Operation::ReplaceRemote { .. } => "ReplaceRemote",
        Operation::DeleteRemote { .. } => "DeleteRemote",
    }
}

fn record(decision: &Decision, reached: &mut BTreeSet<&'static str>) {
    match decision {
        Decision::Operations(operations) => {
            for operation in operations.operations() {
                reached.insert(operation_name(operation));
            }
        }
        Decision::NoOp(noop) => {
            reached.insert(match noop.reason() {
                NoOpReason::BothAbsent => "NoOp::BothAbsent",
                NoOpReason::ContentMatches => "NoOp::ContentMatches",
                NoOpReason::DirectoriesMatch => "NoOp::DirectoriesMatch",
            });
        }
        Decision::Blocked(blocked) => {
            reached.insert(match blocked {
                BlockedReason::LocalUnknown(_) => "Blocked::LocalUnknown",
                BlockedReason::RemoteUnknown(_) => "Blocked::RemoteUnknown",
                BlockedReason::BothUnknown { .. } => "Blocked::BothUnknown",
            });
        }
        Decision::Conflict(conflict) => {
            reached.insert(match conflict {
                Conflict::InitialCollision { .. } => "Conflict::InitialCollision",
                Conflict::DivergentEdits { .. } => "Conflict::DivergentEdits",
                Conflict::LocalDeletionRemoteEdit { .. } => "Conflict::LocalDeletionRemoteEdit",
                Conflict::RemoteDeletionLocalEdit { .. } => "Conflict::RemoteDeletionLocalEdit",
            });
        }
        Decision::DirectoryCollision(collision) => {
            reached.insert(match collision {
                DirectoryCollision::LocalFileRemoteDirectory { .. } => {
                    "DirectoryCollision::LocalFileRemoteDirectory"
                }
                DirectoryCollision::LocalDirectoryRemoteFile { .. } => {
                    "DirectoryCollision::LocalDirectoryRemoteFile"
                }
            });
        }
    }
}

/// Guard the generators themselves: a property proves nothing about a state
/// the strategy never reaches.
///
/// The sample is the same strategy and the same case count the properties
/// below run, taken from the shared proptest configuration, so `PROPTEST_CASES`
/// moves both together and what this proves reachable is what they exercise.
#[test]
fn one_run_reaches_every_planner_outcome() -> Result<(), Box<dyn Error>> {
    let config = Config {
        failure_persistence: None,
        ..Config::default()
    };
    let cases = config.cases;
    let mut runner = TestRunner::new(config);
    let scenario = scenario();
    let mut reached = BTreeSet::new();
    for _ in 0..cases {
        let (baseline, observations) = scenario
            .new_tree(&mut runner)
            .map_err(|reason| io::Error::other(reason.message().to_owned()))?
            .current();
        for (local, remote) in &observations {
            record(&plan(&baseline, local, remote), &mut reached);
        }
    }
    assert_eq!(
        reached,
        OUTCOMES.into_iter().collect::<BTreeSet<_>>(),
        "planner outcomes reached in {cases} cases"
    );
    Ok(())
}

proptest! {
    #[test]
    fn unknown_state_always_blocks_without_deleting(
        (baseline, observations) in uncertain_scenario(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            prop_assert!(matches!(decision, Decision::Blocked(_)));
        }
    }

    #[test]
    fn no_op_carries_the_completely_observed_baseline(
        (baseline, observations) in scenario(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            if let Decision::NoOp(noop) = decision {
                match (&local, &remote) {
                    (Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
                        prop_assert_eq!(noop.baseline(), &Baseline::Absent);
                    }
                    (Observation::Present(local), Observation::Present(remote)) => {
                        prop_assert_eq!(&local.content, &remote.content);
                        prop_assert_eq!(noop.baseline(), &Baseline::Present(remote.clone()));
                    }
                    (Observation::Directory, Observation::Directory) => {
                        prop_assert_eq!(noop.baseline(), &Baseline::Directory);
                    }
                    _ => prop_assert!(false, "no-op lacked a complete common observation"),
                }
            }
        }
    }

    #[test]
    fn remote_mutations_retain_the_observed_revision(
        (baseline, observations) in scenario(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            if let Decision::Operations(operation_plan) = decision {
                for operation in operation_plan.operations() {
                    match (&remote, operation) {
                        (
                            Observation::Present(remote),
                            Operation::ReplaceRemote { expected_revision, .. }
                            | Operation::DeleteRemote { expected_revision },
                        ) => prop_assert_eq!(expected_revision, &remote.revision),
                        (
                            Observation::Directory
                            | Observation::ConfirmedAbsent
                            | Observation::Unknown(_),
                            Operation::ReplaceRemote { .. } | Operation::DeleteRemote { .. },
                        ) => prop_assert!(false, "remote mutation lacked a present observation"),
                        _ => {}
                    }
                }
            }
        }
    }

    #[test]
    fn ordinary_mutations_do_not_plan_recovery_copies(
        (baseline, observations) in scenario(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            if let Decision::Operations(operation_plan) = decision {
                for operation in operation_plan.operations() {
                    prop_assert!(!matches!(
                        operation,
                        Operation::PreserveLocal { .. } | Operation::PreserveRemote { .. }
                    ), "planner emitted a legacy preservation operation");
                }
            }
        }
    }

    #[test]
    fn conflicts_retain_every_present_payload(
        (baseline, observations) in scenario(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            if let Decision::Conflict(conflict) = decision {
                let observed_local = match &local {
                    Observation::Present(file) => Some(file),
                    Observation::Directory
                    | Observation::ConfirmedAbsent
                    | Observation::Unknown(_) => None,
                };
                let observed_remote = match &remote {
                    Observation::Present(file) => Some(file),
                    Observation::Directory
                    | Observation::ConfirmedAbsent
                    | Observation::Unknown(_) => None,
                };

                prop_assert_eq!(conflict.local(), observed_local);
                prop_assert_eq!(conflict.remote(), observed_remote);
                if let Conflict::InitialCollision { local, remote }
                | Conflict::DivergentEdits { local, remote } = conflict
                {
                    prop_assert_ne!(local.content, remote.content);
                }
            }
        }
    }

    #[test]
    fn a_remote_directory_never_produces_a_remote_delete(
        (baseline, observations) in scenario(),
    ) {
        for (local, _) in observations {
            let decision = plan(&baseline, &local, &Observation::Directory);
            if let Decision::Operations(operations) = decision {
                let safe = operations.operations().iter().all(|operation| {
                    !matches!(operation, Operation::DeleteRemote { .. })
                });
                prop_assert!(safe);
            }
        }
    }

    #[test]
    fn directory_file_collisions_retain_the_exact_file_description(
        (baseline, observations) in scenario(),
    ) {
        for (local, remote) in observations {
            if let Observation::Present(local) = local {
                prop_assert_eq!(
                    plan(
                        &baseline,
                        &Observation::Present(local.clone()),
                        &Observation::Directory,
                    ),
                    Decision::DirectoryCollision(
                        DirectoryCollision::LocalFileRemoteDirectory { local },
                    )
                );
            }
            if let Observation::Present(remote) = remote {
                prop_assert_eq!(
                    plan(
                        &baseline,
                        &Observation::Directory,
                        &Observation::Present(remote.clone()),
                    ),
                    Decision::DirectoryCollision(
                        DirectoryCollision::LocalDirectoryRemoteFile { remote },
                    )
                );
            }
        }
    }
}
