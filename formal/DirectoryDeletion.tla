------------------------- MODULE DirectoryDeletion -------------------------

EXTENDS TLC

(***************************************************************************
 One synchronized directory `d` holding one synchronized file `d/c`. The user
 deletes the local tree while another Dropbox client may write `d/c` once,
 either rewriting it or creating it anew after the daemon deleted it.

 Dropbox deletes a folder together with everything inside it. The daemon
 therefore plans a remote directory delete only while its durable inventory
 holds nothing beneath the path, and `DropboxClient::delete_folder` lists the
 folder immediately before `delete_v2` and gives up when an entry appears.
 That probe and delete are one atomic step here; the window Dropbox's API
 leaves between them is outside the model.

 A pass refreshes the inventory before it plans anything, so planning steps
 require `observed`, which the daemon's own Dropbox effects clear and
 `Observe` sets. A write by the other client does not clear it: the daemon
 cannot know, and planning on that stale inventory is the case the probe
 exists for.

 Each action abstracts one step of the daemon. Effects and their journal
 completions are separate steps, so every run also covers replay after a
 crash between an applied Dropbox effect and its journal completion.
 ***************************************************************************)

Dirs == {"Present", "Absent"}
RemoteFiles == {"Absent", "Base", "New"}
LocalFiles == {"Absent", "Base", "Remote"}
DirBaselines == {"Directory", "Absent"}
FileBaselines == {"Absent", "Base", "New"}
DirPlans == {"None", "DeleteRemoteDirectory"}
FilePlans == {"None", "DeleteRemote", "InstallLocal"}

VARIABLES
    localDir, localFile,    \* the sync root; "Remote" holds Dropbox content the user never deleted
    remoteDir, remoteFile,  \* Dropbox; "New" is content the local side never synchronized
    invDir, invFile,        \* the durable remote inventory refreshed at the start of a pass
    observed,               \* the inventory was refreshed since the daemon's last Dropbox effect
    baseDir, baseFile,      \* durable baselines
    planDir, planFile,      \* durable pending plans
    conflict,               \* a LocalDeletionRemoteEdit conflict was recorded for d/c
    userDeleted,            \* the user removed the local tree
    written                 \* the other client wrote d/c

vars ==
    <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
      baseDir, baseFile, planDir, planFile, conflict, userDeleted, written>>

Init ==
    /\ localDir = "Present" /\ localFile = "Base"
    /\ remoteDir = "Present" /\ remoteFile = "Base"
    /\ invDir = "Present" /\ invFile = "Base" /\ observed = TRUE
    /\ baseDir = "Directory" /\ baseFile = "Base"
    /\ planDir = "None" /\ planFile = "None"
    /\ conflict = FALSE /\ userDeleted = FALSE /\ written = FALSE

\* The user removes the whole local tree.
UserDelete ==
    /\ ~userDeleted
    /\ localDir' = "Absent"
    /\ localFile' = "Absent"
    /\ userDeleted' = TRUE
    /\ UNCHANGED
        <<remoteDir, remoteFile, invDir, invFile, observed, baseDir, baseFile,
          planDir, planFile, conflict, written>>

\* Another Dropbox client writes d/c once; creating it re-creates d.
RemoteWrite ==
    /\ ~written
    /\ remoteFile' = "New"
    /\ remoteDir' = "Present"
    /\ written' = TRUE
    /\ UNCHANGED
        <<localDir, localFile, invDir, invFile, observed, baseDir, baseFile,
          planDir, planFile, conflict, userDeleted>>

\* DropboxClient::refresh_inventory at the start of a pass.
Observe ==
    /\ invDir' = remoteDir
    /\ invFile' = remoteFile
    /\ observed' = TRUE
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, baseDir, baseFile,
          planDir, planFile, conflict, userDeleted, written>>

\* planner::plan for d/c: (Present(base), ConfirmedAbsent, Present(base)) -> DeleteRemote.
PlanFileDelete ==
    /\ observed
    /\ planFile = "None" /\ ~conflict
    /\ baseFile = "Base" /\ localFile = "Absent" /\ invFile = "Base"
    /\ planFile' = "DeleteRemote"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseDir, baseFile, planDir, conflict, userDeleted, written>>

\* planner::plan for d/c: (Present(base), ConfirmedAbsent, Present(new)) ->
\* Conflict::LocalDeletionRemoteEdit; reconcile::prepare_conflict copies the
\* Dropbox payload beneath d, which brings d back to hold it.
PlanFileConflict ==
    /\ observed
    /\ planFile = "None" /\ ~conflict
    /\ baseFile = "Base" /\ localFile = "Absent" /\ invFile = "New"
    /\ localFile' = "Remote"
    /\ localDir' = "Present"
    /\ conflict' = TRUE
    /\ UNCHANGED
        <<remoteDir, remoteFile, invDir, invFile, observed, baseDir, baseFile,
          planDir, planFile, userDeleted, written>>

\* planner::plan for d/c: (Present(base), ConfirmedAbsent, ConfirmedAbsent) ->
\* NoOp BothAbsent; reconcile supersedes a pending plan whose decision changed.
NoOpFile ==
    /\ observed
    /\ baseFile = "Base" /\ localFile = "Absent" /\ invFile = "Absent"
    /\ baseFile' = "Absent"
    /\ planFile' = "None"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseDir, planDir, conflict, userDeleted, written>>

\* planner::plan for d/c: (Absent, ConfirmedAbsent, Present(new)) -> InstallLocal.
PlanInstall ==
    /\ observed
    /\ planFile = "None"
    /\ baseFile = "Absent" /\ localFile = "Absent" /\ invFile = "New"
    /\ planFile' = "InstallLocal"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseDir, baseFile, planDir, conflict, userDeleted, written>>

\* recovery::replay_local_plans_at, InstallLocal: the verified download lands
\* beneath d and brings d back to hold it. The download may wait for a while
\* first, which is the stuttering before this step.
LandInstall ==
    /\ planFile = "InstallLocal"
    /\ localFile' = "Remote"
    /\ localDir' = "Present"
    /\ baseFile' = "New"
    /\ planFile' = "None"
    /\ UNCHANGED
        <<remoteDir, remoteFile, invDir, invFile, observed, baseDir, planDir,
          conflict, userDeleted, written>>

\* planner::plan for d: (Absent, ConfirmedAbsent, Directory) -> CreateLocalDirectory,
\* the ordinary arrival of a Dropbox folder the journal has forgotten;
\* recovery::replay_local_plans_at creates it and completes the plan.
CreateLocalDir ==
    /\ observed
    /\ baseDir = "Absent" /\ localDir = "Absent" /\ invDir = "Present"
    /\ localDir' = "Present"
    /\ baseDir' = "Directory"
    /\ UNCHANGED
        <<localFile, remoteDir, remoteFile, invDir, invFile, observed, baseFile,
          planDir, planFile, conflict, userDeleted, written>>

\* recovery::replay_remote_operations_at, DeleteRemote through
\* DropboxClient::delete_file, conditional on the observed revision.
ApplyFileDelete ==
    /\ planFile = "DeleteRemote"
    /\ \/ \* the revision still matches: the effect applies
          /\ remoteFile = "Base"
          /\ remoteFile' = "Absent"
          /\ observed' = FALSE
          /\ UNCHANGED <<localDir, localFile, baseFile, planFile, conflict>>
       \/ \* ApiOutcome::Absent on replay: the journal completes
          /\ remoteFile = "Absent"
          /\ baseFile' = "Absent"
          /\ planFile' = "None"
          /\ UNCHANGED <<localDir, localFile, remoteFile, observed, conflict>>
       \/ \* PreconditionChanged(File): recovery::apply_delete_mutation
          \* materializes the Dropbox payload and records the conflict
          /\ remoteFile = "New"
          /\ localFile' = "Remote"
          /\ localDir' = "Present"
          /\ conflict' = TRUE
          /\ planFile' = "None"
          /\ UNCHANGED <<remoteFile, observed, baseFile>>
    /\ UNCHANGED
        <<remoteDir, invDir, invFile, baseDir, planDir, userDeleted, written>>

\* planner::plan for d: (Directory, ConfirmedAbsent, Directory) with
\* RemoteSubtree::Empty -> DeleteRemoteDirectory.
PlanDirDelete ==
    /\ observed
    /\ planDir = "None"
    /\ baseDir = "Directory" /\ localDir = "Absent"
    /\ invDir = "Present" /\ invFile = "Absent"
    /\ planDir' = "DeleteRemoteDirectory"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseDir, baseFile, planFile, conflict, userDeleted, written>>

\* planner::plan for d with RemoteSubtree::Occupied ->
\* Blocked(RemoteDirectoryOccupied); reconcile retires the pending delete.
RetireDirPlan ==
    /\ observed
    /\ planDir = "DeleteRemoteDirectory"
    /\ localDir = "Absent" /\ invDir = "Present" /\ invFile # "Absent"
    /\ planDir' = "None"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseDir, baseFile, planFile, conflict, userDeleted, written>>

\* recovery::replay_remote_operations_at, DeleteRemoteDirectory through
\* DropboxClient::delete_folder: probe_folder, then delete_v2 only when empty.
ApplyDirDelete ==
    /\ planDir = "DeleteRemoteDirectory"
    /\ \/ \* FolderProbe::Absent on replay: the journal completes
          /\ remoteDir = "Absent"
          /\ baseDir' = "Absent"
          /\ planDir' = "None"
          /\ UNCHANGED <<remoteDir, observed>>
       \/ \* FolderProbe::Occupied: PreconditionChanged(Folder) retires the plan
          /\ remoteDir = "Present" /\ remoteFile # "Absent"
          /\ planDir' = "None"
          /\ UNCHANGED <<remoteDir, observed, baseDir>>
       \/ \* FolderProbe::Empty: delete_v2 removes the empty folder
          /\ remoteDir = "Present" /\ remoteFile = "Absent"
          /\ remoteDir' = "Absent"
          /\ observed' = FALSE
          /\ UNCHANGED <<baseDir, planDir>>
    /\ UNCHANGED
        <<localDir, localFile, remoteFile, invDir, invFile, baseFile,
          planFile, conflict, userDeleted, written>>

\* planner::plan for d: (Directory, ConfirmedAbsent, ConfirmedAbsent) ->
\* NoOp BothAbsent; reconcile supersedes a pending plan whose decision changed.
NoOpDir ==
    /\ observed
    /\ baseDir = "Directory" /\ localDir = "Absent" /\ invDir = "Absent"
    /\ baseDir' = "Absent"
    /\ planDir' = "None"
    /\ UNCHANGED
        <<localDir, localFile, remoteDir, remoteFile, invDir, invFile, observed,
          baseFile, planFile, conflict, userDeleted, written>>

Daemon ==
    \/ Observe
    \/ PlanFileDelete
    \/ PlanFileConflict
    \/ NoOpFile
    \/ PlanInstall
    \/ LandInstall
    \/ CreateLocalDir
    \/ ApplyFileDelete
    \/ PlanDirDelete
    \/ RetireDirPlan
    \/ ApplyDirDelete
    \/ NoOpDir

Next ==
    \/ UserDelete
    \/ RemoteWrite
    \/ Daemon

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Observe)
    /\ WF_vars(PlanFileDelete)
    /\ WF_vars(PlanFileConflict)
    /\ WF_vars(NoOpFile)
    /\ WF_vars(PlanInstall)
    /\ WF_vars(LandInstall)
    /\ WF_vars(CreateLocalDir)
    /\ WF_vars(ApplyFileDelete)
    /\ WF_vars(PlanDirDelete)
    /\ WF_vars(RetireDirPlan)
    /\ WF_vars(ApplyDirDelete)
    /\ WF_vars(NoOpDir)

TypeOK ==
    /\ localDir \in Dirs
    /\ localFile \in LocalFiles
    /\ remoteDir \in Dirs
    /\ remoteFile \in RemoteFiles
    /\ invDir \in Dirs
    /\ invFile \in RemoteFiles
    /\ observed \in BOOLEAN
    /\ baseDir \in DirBaselines
    /\ baseFile \in FileBaselines
    /\ planDir \in DirPlans
    /\ planFile \in FilePlans
    /\ conflict \in BOOLEAN
    /\ userDeleted \in BOOLEAN
    /\ written \in BOOLEAN

\* A remote directory delete is planned only from an inventory that holds
\* nothing beneath the path. The plan may outlive one refresh that finds a
\* new entry; reconcile then retires it, and the probe inside delete_folder
\* guards the effect in the meantime.
DirectoryPlanRestsOnEmptyInventory ==
    [][(planDir = "None" /\ planDir' = "DeleteRemoteDirectory") => invFile = "Absent"]_vars

\* The daemon never brings a locally deleted directory back for its own sake;
\* it returns only holding, or about to hold, Dropbox content the user never
\* deleted.
NoEmptyResurrection ==
    (userDeleted /\ localDir = "Present") => (localFile = "Remote" \/ invFile = "New")

\* Content the local side never synchronized survives on Dropbox.
UnsynchronizedContentSurvives ==
    written => remoteFile = "New"

\* No daemon step deletes a Dropbox folder that still holds an entry.
FolderDeleteNeverRecursive ==
    [][~(remoteDir = "Present" /\ remoteDir' = "Absent" /\ remoteFile # "Absent")]_vars

\* No daemon step deletes Dropbox content the local side never synchronized.
DaemonDeletesOnlySynchronizedContent ==
    [][~(remoteFile = "New" /\ remoteFile' = "Absent")]_vars

\* A local deletion propagates completely unless a remote write overtakes it.
DeletionPropagates ==
    (userDeleted /\ ~written) ~>
        \/ written
        \/ /\ remoteDir = "Absent" /\ remoteFile = "Absent"
           /\ baseDir = "Absent" /\ baseFile = "Absent"
           /\ localDir = "Absent" /\ localFile = "Absent"

\* A raced deletion settles with the Dropbox payload held on both sides and
\* no plan left pending.
RacePreservesThePayload ==
    (userDeleted /\ written) ~>
        (remoteDir = "Present" /\ remoteFile = "New"
         /\ localDir = "Present" /\ localFile = "Remote"
         /\ planDir = "None" /\ planFile = "None")

=============================================================================
