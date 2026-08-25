use omabox::model::{
    Baseline, Conflict, ContentIdentity, Decision, DirectoryCollision, DropboxRevision, LocalFile,
    LocalObservation, Observation, Operation, RemoteFile, RemoteObservation, UnknownReason,
};
use omabox::planner::plan;
use proptest::prelude::*;

fn content_strategy() -> impl Strategy<Value = ContentIdentity> {
    "[a-z]{1,8}".prop_map(ContentIdentity::new)
}

fn revision_strategy() -> impl Strategy<Value = DropboxRevision> {
    "[a-z0-9]{1,8}".prop_map(DropboxRevision::new)
}

fn local_file_strategy() -> impl Strategy<Value = LocalFile> {
    content_strategy().prop_map(LocalFile::new)
}

fn remote_file_strategy() -> impl Strategy<Value = RemoteFile> {
    (content_strategy(), revision_strategy())
        .prop_map(|(content, revision)| RemoteFile::new(content, revision))
}

fn baseline_strategy() -> impl Strategy<Value = Baseline> {
    prop_oneof![
        Just(Baseline::Absent),
        Just(Baseline::Directory),
        remote_file_strategy().prop_map(Baseline::Present),
    ]
}

fn unknown_reason_strategy() -> impl Strategy<Value = UnknownReason> {
    prop_oneof![
        Just(UnknownReason::Incomplete),
        Just(UnknownReason::Inaccessible),
        Just(UnknownReason::Unavailable),
        Just(UnknownReason::Stale),
        Just(UnknownReason::CursorReset),
        Just(UnknownReason::Unsupported),
    ]
}

fn local_observation_strategy() -> impl Strategy<Value = LocalObservation> {
    prop_oneof![
        local_file_strategy().prop_map(Observation::Present),
        Just(Observation::Directory),
        Just(Observation::ConfirmedAbsent),
        unknown_reason_strategy().prop_map(Observation::Unknown),
    ]
}

fn remote_observation_strategy() -> impl Strategy<Value = RemoteObservation> {
    prop_oneof![
        remote_file_strategy().prop_map(Observation::Present),
        Just(Observation::Directory),
        Just(Observation::ConfirmedAbsent),
        unknown_reason_strategy().prop_map(Observation::Unknown),
    ]
}

fn observation_sequence_strategy()
-> impl Strategy<Value = Vec<(LocalObservation, RemoteObservation)>> {
    prop::collection::vec(
        (local_observation_strategy(), remote_observation_strategy()),
        1..16,
    )
}

fn unknown_observation_strategy() -> impl Strategy<Value = (LocalObservation, RemoteObservation)> {
    prop_oneof![
        (unknown_reason_strategy(), remote_observation_strategy())
            .prop_map(|(reason, remote)| (Observation::Unknown(reason), remote)),
        (local_observation_strategy(), unknown_reason_strategy())
            .prop_map(|(local, reason)| (local, Observation::Unknown(reason))),
    ]
}

proptest! {
    #[test]
    fn unknown_state_always_blocks_without_deleting(
        baseline in baseline_strategy(),
        observations in prop::collection::vec(unknown_observation_strategy(), 1..16),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            prop_assert!(matches!(decision, Decision::Blocked(_)));
        }
    }

    #[test]
    fn no_op_carries_the_completely_observed_baseline(
        baseline in baseline_strategy(),
        observations in observation_sequence_strategy(),
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
        baseline in baseline_strategy(),
        observations in observation_sequence_strategy(),
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
    fn destructive_operations_follow_payload_preservation(
        baseline in baseline_strategy(),
        observations in observation_sequence_strategy(),
    ) {
        for (local, remote) in observations {
            let decision = plan(&baseline, &local, &remote);
            if let Decision::Operations(operation_plan) = decision {
                let mut previous: Option<&Operation> = None;
                for operation in operation_plan.operations() {
                    match (previous, operation) {
                        (
                            Some(Operation::PreserveLocal { file }),
                            Operation::ReplaceLocal { expected_content, .. }
                            | Operation::DeleteLocal { expected_content },
                        ) => prop_assert_eq!(&file.content, expected_content),
                        (
                            Some(Operation::PreserveRemote { file }),
                            Operation::ReplaceRemote { expected_revision, .. }
                            | Operation::DeleteRemote { expected_revision },
                        ) => prop_assert_eq!(&file.revision, expected_revision),
                        (
                            _,
                            Operation::ReplaceLocal { .. }
                            | Operation::DeleteLocal { .. }
                            | Operation::ReplaceRemote { .. }
                            | Operation::DeleteRemote { .. },
                        ) => prop_assert!(false, "destructive operation was not preceded by preservation"),
                        _ => {}
                    }
                    previous = Some(operation);
                }
            }
        }
    }

    #[test]
    fn replaying_the_same_observations_is_idempotent(
        baseline in baseline_strategy(),
        observations in observation_sequence_strategy(),
    ) {
        for (local, remote) in observations {
            let first = plan(&baseline, &local, &remote);
            let replay = plan(&baseline, &local, &remote);
            prop_assert_eq!(first, replay);
        }
    }

    #[test]
    fn conflicts_retain_every_present_payload(
        baseline in baseline_strategy(),
        observations in observation_sequence_strategy(),
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
        baseline in baseline_strategy(),
        local in local_observation_strategy(),
    ) {
        let decision = plan(&baseline, &local, &Observation::Directory);
        if let Decision::Operations(operations) = decision {
            let safe = operations.operations().iter().all(|operation| {
                !matches!(operation, Operation::DeleteRemote { .. })
            });
            prop_assert!(safe);
        }
    }

    #[test]
    fn directory_file_collisions_retain_the_exact_file_description(
        baseline in baseline_strategy(),
        local in local_file_strategy(),
        remote in remote_file_strategy(),
    ) {
        prop_assert_eq!(
            plan(
                &baseline,
                &Observation::Present(local.clone()),
                &Observation::Directory,
            ),
            Decision::DirectoryCollision(DirectoryCollision::LocalFileRemoteDirectory { local })
        );
        prop_assert_eq!(
            plan(
                &baseline,
                &Observation::Directory,
                &Observation::Present(remote.clone()),
            ),
            Decision::DirectoryCollision(DirectoryCollision::LocalDirectoryRemoteFile { remote })
        );
    }
}
