//! Deterministic, side-effect-free reconciliation decisions for one path.

use crate::model::{
    Baseline, BlockedReason, Conflict, Decision, DirectoryCollision, LocalObservation,
    NoOpDecision, NoOpReason, Observation, Operation, OperationPlan, RemoteObservation,
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
        (_, Observation::Present(local), Observation::Directory) => {
            Decision::DirectoryCollision(DirectoryCollision::LocalFileRemoteDirectory {
                local: local.clone(),
            })
        }
        (_, Observation::Directory, Observation::Present(remote)) => {
            Decision::DirectoryCollision(DirectoryCollision::LocalDirectoryRemoteFile {
                remote: remote.clone(),
            })
        }
        (_, Observation::Directory, Observation::Directory) => Decision::NoOp(NoOpDecision::new(
            NoOpReason::DirectoriesMatch,
            Baseline::Directory,
        )),
        (Baseline::Absent, Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
            Decision::NoOp(NoOpDecision::new(NoOpReason::BothAbsent, Baseline::Absent))
        }
        (Baseline::Absent, Observation::Directory, Observation::ConfirmedAbsent) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateRemoteDirectory]))
        }
        (Baseline::Absent, Observation::ConfirmedAbsent, Observation::Directory) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateLocalDirectory]))
        }
        (Baseline::Absent, Observation::Present(local), Observation::ConfirmedAbsent) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateRemote {
                content: local.content.clone(),
            }]))
        }
        (Baseline::Absent, Observation::ConfirmedAbsent, Observation::Present(remote)) => {
            Decision::Operations(OperationPlan::new(vec![Operation::InstallLocal {
                source: remote.clone(),
            }]))
        }
        (Baseline::Absent, Observation::Present(local), Observation::Present(remote))
            if local.content == remote.content =>
        {
            Decision::NoOp(NoOpDecision::new(
                NoOpReason::ContentMatches,
                Baseline::Present(remote.clone()),
            ))
        }
        (Baseline::Absent, Observation::Present(local), Observation::Present(remote)) => {
            Decision::Conflict(Conflict::InitialCollision {
                local: local.clone(),
                remote: remote.clone(),
            })
        }
        (Baseline::Directory, Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
            Decision::NoOp(NoOpDecision::new(NoOpReason::BothAbsent, Baseline::Absent))
        }
        (Baseline::Directory, Observation::Directory, Observation::ConfirmedAbsent) => {
            Decision::Operations(OperationPlan::new(vec![Operation::DeleteLocalDirectory]))
        }
        (Baseline::Directory, Observation::ConfirmedAbsent, Observation::Directory) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateLocalDirectory]))
        }
        (Baseline::Directory, Observation::Present(local), Observation::ConfirmedAbsent) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateRemote {
                content: local.content.clone(),
            }]))
        }
        (Baseline::Directory, Observation::ConfirmedAbsent, Observation::Present(remote)) => {
            Decision::Operations(OperationPlan::new(vec![Operation::InstallLocal {
                source: remote.clone(),
            }]))
        }
        (Baseline::Directory, Observation::Present(local), Observation::Present(remote))
            if local.content == remote.content =>
        {
            Decision::NoOp(NoOpDecision::new(
                NoOpReason::ContentMatches,
                Baseline::Present(remote.clone()),
            ))
        }
        (Baseline::Directory, Observation::Present(local), Observation::Present(remote)) => {
            Decision::Conflict(Conflict::InitialCollision {
                local: local.clone(),
                remote: remote.clone(),
            })
        }
        (Baseline::Present(_), Observation::ConfirmedAbsent, Observation::ConfirmedAbsent) => {
            Decision::NoOp(NoOpDecision::new(NoOpReason::BothAbsent, Baseline::Absent))
        }
        (Baseline::Present(_), Observation::Directory, Observation::ConfirmedAbsent) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateRemoteDirectory]))
        }
        (Baseline::Present(_), Observation::ConfirmedAbsent, Observation::Directory) => {
            Decision::Operations(OperationPlan::new(vec![Operation::CreateLocalDirectory]))
        }
        (Baseline::Present(_), Observation::Present(local), Observation::Present(remote))
            if local.content == remote.content =>
        {
            Decision::NoOp(NoOpDecision::new(
                NoOpReason::ContentMatches,
                Baseline::Present(remote.clone()),
            ))
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::Present(remote),
        ) if local.content != baseline.content && remote.content == baseline.content => {
            Decision::Operations(OperationPlan::new(vec![Operation::ReplaceRemote {
                content: local.content.clone(),
                expected_revision: remote.revision.clone(),
            }]))
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::Present(remote),
        ) if local.content == baseline.content && remote.content != baseline.content => {
            Decision::Operations(OperationPlan::new(vec![Operation::ReplaceLocal {
                source: remote.clone(),
                expected_content: local.content.clone(),
            }]))
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
        ) if remote.content == baseline.content => {
            Decision::Operations(OperationPlan::new(vec![Operation::DeleteRemote {
                expected_revision: remote.revision.clone(),
            }]))
        }
        (Baseline::Present(_), Observation::ConfirmedAbsent, Observation::Present(remote)) => {
            Decision::Conflict(Conflict::LocalDeletionRemoteEdit {
                remote: remote.clone(),
            })
        }
        (
            Baseline::Present(baseline),
            Observation::Present(local),
            Observation::ConfirmedAbsent,
        ) if local.content == baseline.content => {
            Decision::Operations(OperationPlan::new(vec![Operation::DeleteLocal {
                expected_content: local.content.clone(),
            }]))
        }
        (Baseline::Present(_), Observation::Present(local), Observation::ConfirmedAbsent) => {
            Decision::Conflict(Conflict::RemoteDeletionLocalEdit {
                local: local.clone(),
            })
        }
    }
}
