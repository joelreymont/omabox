//! Deterministic, side-effect-free reconciliation decisions for one path.

use crate::model::{
    Baseline, BlockedReason, Conflict, Decision, LocalObservation, NoOpReason, Observation,
    Operation, RemoteObservation,
};

/// Plan the next safe action for one path.
///
/// Unknown observations are handled before all other transitions, so they can
/// never be reinterpreted as absence or produce a deletion.
#[must_use]
pub fn plan(baseline: &Baseline, local: &LocalObservation, remote: &RemoteObservation) -> Decision {
    match (baseline, local, remote) {
        (_, Observation::Unknown(local), Observation::Unknown(remote)) => {
            Decision::Blocked(BlockedReason::BothUnknown {
                local: *local,
                remote: *remote,
            })
        }
        (_, Observation::Unknown(reason), _) => {
            Decision::Blocked(BlockedReason::LocalUnknown(*reason))
        }
        (_, _, Observation::Unknown(reason)) => {
            Decision::Blocked(BlockedReason::RemoteUnknown(*reason))
        }
        (Baseline::Absent, Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
            Decision::NoOp(NoOpReason::BothAbsent)
        }
        (Baseline::Absent, Observation::Present(local), Observation::ConfirmedAbsent) => {
            Decision::Operations(vec![Operation::CreateRemote {
                content: local.content.clone(),
            }])
        }
        (Baseline::Absent, Observation::ConfirmedAbsent, Observation::Present(remote)) => {
            Decision::Operations(vec![Operation::InstallLocal {
                source: remote.clone(),
            }])
        }
        (Baseline::Absent, Observation::Present(local), Observation::Present(remote))
            if local.content == remote.content =>
        {
            Decision::NoOp(NoOpReason::ContentMatches)
        }
        (Baseline::Absent, Observation::Present(local), Observation::Present(remote)) => {
            Decision::Conflict(Conflict::InitialCollision {
                local: local.clone(),
                remote: remote.clone(),
            })
        }
        (Baseline::Present(_), Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
            Decision::NoOp(NoOpReason::BothAbsent)
        }
        (Baseline::Present(_), Observation::Present(local), Observation::Present(remote))
            if local.content == remote.content =>
        {
            Decision::NoOp(NoOpReason::ContentMatches)
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::Present(remote),
        ) if local.content != baseline.content && remote.content == baseline.content => {
            Decision::Operations(vec![
                Operation::PreserveRemote {
                    file: remote.clone(),
                },
                Operation::ReplaceRemote {
                    content: local.content.clone(),
                    expected_revision: remote.revision.clone(),
                },
            ])
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::Present(remote),
        ) if local.content == baseline.content && remote.content != baseline.content => {
            Decision::Operations(vec![
                Operation::PreserveLocal {
                    file: local.clone(),
                },
                Operation::ReplaceLocal {
                    source: remote.clone(),
                    expected_content: local.content.clone(),
                },
            ])
        }
        (Baseline::Present(_), Observation::Present(local), Observation::Present(remote)) => {
            Decision::Conflict(Conflict::DivergentEdits {
                local: local.clone(),
                remote: remote.clone(),
            })
        }
        (
            Baseline::Present(baseline),
            Observation::ConfirmedAbsent,
            Observation::Present(remote),
        ) if remote.content == baseline.content => Decision::Operations(vec![
            Operation::PreserveRemote {
                file: remote.clone(),
            },
            Operation::DeleteRemote {
                expected_revision: remote.revision.clone(),
            },
        ]),
        (Baseline::Present(_), Observation::ConfirmedAbsent, Observation::Present(remote)) => {
            Decision::Conflict(Conflict::LocalDeletionRemoteEdit {
                remote: remote.clone(),
            })
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::ConfirmedAbsent,
        ) if local.content == baseline.content => Decision::Operations(vec![
            Operation::PreserveLocal {
                file: local.clone(),
            },
            Operation::DeleteLocal {
                expected_content: local.content.clone(),
            },
        ]),
        (Baseline::Present(_), Observation::Present(local), Observation::ConfirmedAbsent) => {
            Decision::Conflict(Conflict::RemoteDeletionLocalEdit {
                local: local.clone(),
            })
        }
    }
}
