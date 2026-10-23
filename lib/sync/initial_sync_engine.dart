/// First connection of this device's data to a signed-in cloud account
/// (Phase B-3). One-shot and user-initiated: no automatic, periodic,
/// realtime or background sync exists yet.
///
/// Safety order of a run:
/// 1. Read both sides and classify (no writes).
/// 2. Make the one-time `songbook.pre_cloud_sync_v4.backup.db`. If that
///    fails, stop: nothing else happens.
/// 3. Record `initial_sync_state = in_progress` (for resuming).
/// 4. Upload the device's winning rows in batches of at most 400. Document
///    ids are deterministic, so a retry never duplicates anything.
/// 5. One local transaction: apply the cloud's winning rows (stored clean),
///    clear `sync_dirty` only for rows unchanged since step 1, and write
///    `account_uid`. A failure anywhere before or inside this step leaves
///    the local songs/folders exactly as they were and the device unbound.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'cloud_sync_backend.dart';
import 'initial_sync_plan.dart';
import 'local_sync_store.dart';
import 'sync_records.dart';

enum InitialSyncMode {
  /// Device has data, cloud has none: back the device up.
  upload,

  /// Device has no data, cloud has some: restore it.
  restore,

  /// Both have data and the user chose to combine them.
  merge,

  /// Neither has data: just bind the account.
  bindOnly,
}

extension InitialSyncModeNames on InitialSyncMode {
  String get storedName => switch (this) {
        InitialSyncMode.upload => InitialSyncModeName.upload,
        InitialSyncMode.restore => InitialSyncModeName.restore,
        InitialSyncMode.merge => InitialSyncModeName.merge,
        InitialSyncMode.bindOnly => InitialSyncModeName.bindOnly,
      };
}

enum InitialSyncAssessmentKind {
  /// Already bound to this account. Nothing to do.
  alreadyLinked,

  /// Bound to a different account. Must not sync.
  linkedToOtherAccount,

  /// Can run [InitialSyncAssessment.mode] without asking.
  ready,

  /// Both sides hold data (or one side's deletions would remove the
  /// other's data): the user must choose merge or cancel.
  needsMergeDecision,
}

class InitialSyncAssessment {
  final InitialSyncAssessmentKind kind;
  final InitialSyncMode? mode;
  final SyncDataSummary local;
  final SyncDataSummary cloud;

  const InitialSyncAssessment(
    this.kind, {
    this.mode,
    this.local = const SyncDataSummary(songs: 0, folders: 0),
    this.cloud = const SyncDataSummary(songs: 0, folders: 0),
  });
}

enum InitialSyncFailureKind { backup, network, permissionDenied, other }

/// The run did not complete. Local data is unchanged and the device is not
/// bound; it can be retried. [detail] is for logs only.
class InitialSyncFailure implements Exception {
  final InitialSyncFailureKind kind;
  final String detail;

  const InitialSyncFailure(this.kind, this.detail);

  @override
  String toString() => 'InitialSyncFailure(${kind.name}: $detail)';
}

class InitialSyncResult {
  /// Set when the run completed and the device is now bound.
  final InitialSyncMode? completedMode;

  /// Set instead when the situation changed since [InitialSyncEngine.assess]
  /// (e.g. the cloud gained data) and the user must decide first. Nothing
  /// was written.
  final InitialSyncAssessment? needsDecision;

  final int uploadedDocuments;

  const InitialSyncResult._({
    this.completedMode,
    this.needsDecision,
    this.uploadedDocuments = 0,
  });

  bool get completed => completedMode != null;
}

class InitialSyncEngine {
  final LocalSyncStore store;
  final CloudSyncBackend backend;
  final int batchSize;
  final int Function() _now;

  InitialSyncEngine({
    required this.store,
    required this.backend,
    this.batchSize = CloudSyncBackend.maxBatchWrites,
    int Function()? now,
  })  : assert(batchSize > 0 && batchSize <= CloudSyncBackend.maxBatchWrites),
        _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  /// Reads both sides and decides what a run would do. Writes nothing.
  /// Throws [InitialSyncFailure] if the cloud can't be read.
  Future<InitialSyncAssessment> assess(String uid) async {
    final meta = await store.readMeta();
    _requireNoAccountDeletion(meta);
    final bound = _bound(meta, uid);
    if (bound != null) return bound;
    final cloud = await _fetch(uid);
    final local = await store.readSnapshot();
    return _classify(uid, meta, local, cloud);
  }

  /// Runs the initial sync in [mode]. For anything but
  /// [InitialSyncMode.merge] the situation is re-checked first, and if it
  /// now needs the user's decision nothing is written and
  /// [InitialSyncResult.needsDecision] is returned.
  Future<InitialSyncResult> run(
    String uid, {
    required InitialSyncMode mode,
    String? email,
  }) async {
    final meta = await store.readMeta();
    _requireNoAccountDeletion(meta);
    final bound = _bound(meta, uid);
    if (bound != null) {
      if (bound.kind == InitialSyncAssessmentKind.alreadyLinked) {
        return const InitialSyncResult._(completedMode: InitialSyncMode.bindOnly);
      }
      throw const InitialSyncFailure(
        InitialSyncFailureKind.other,
        'device is bound to another account',
      );
    }

    final cloud = await _fetch(uid);
    final local = await store.readSnapshot();
    final assessment = _classify(uid, meta, local, cloud);
    if (mode != InitialSyncMode.merge) {
      if (assessment.kind == InitialSyncAssessmentKind.needsMergeDecision) {
        return InitialSyncResult._(needsDecision: assessment);
      }
      // A different automatic mode (e.g. the cloud was emptied) is fine:
      // the plan below is computed from the real data either way.
      if (assessment.mode != null) mode = assessment.mode!;
    }

    // 2. Safety backup. Without it, nothing else may happen.
    final backup = await store.ensurePreCloudBackup();
    if (!backup.ok) {
      throw InitialSyncFailure(
        InitialSyncFailureKind.backup,
        '${backup.error}',
      );
    }

    final modeName = mode.storedName;
    try {
      await store.markInitialSyncStarted(uid, modeName);

      final plan = buildInitialSyncPlan(local, cloud, nowMs: _now());

      // 4. Upload, batch by batch.
      final writes = plan.cloudWrites;
      for (var i = 0; i < writes.length; i += batchSize) {
        final end = i + batchSize < writes.length ? i + batchSize : writes.length;
        await _commit(uid, writes.sublist(i, end));
      }

      // 5. Local apply + dirty clear + binding, atomically. The plan is
      // recomputed on the data as it is *now* (inside the transaction), so
      // an edit made during the upload is never overwritten by the cloud.
      final uploaded = plan.uploadedEntityKeys;
      await store.commitInitialSync(
        uid: uid,
        email: email,
        mode: modeName,
        cleanTokens: plan.cleanTokens,
        apply: (fresh, writer) async {
          final again = buildInitialSyncPlan(fresh, cloud, nowMs: _now());
          await applyLocalPlan(
            writer,
            again.localApply,
            skipEntityKeys: uploaded,
          );
        },
      );
      return InitialSyncResult._(
        completedMode: mode,
        uploadedDocuments: writes.length,
      );
    } catch (e) {
      final failure = e is InitialSyncFailure
          ? e
          : InitialSyncFailure(InitialSyncFailureKind.other, '$e');
      debugPrint('[sync] initial sync failed: $failure');
      try {
        await store.markInitialSyncFailed(uid, modeName, failure.detail);
      } catch (_) {
        // Best effort; the in-progress mark already allows a retry.
      }
      throw failure;
    }
  }

  /// No first connection while an account deletion is pending (Phase B-5).
  static void _requireNoAccountDeletion(InitialSyncMeta meta) {
    if (meta.accountDeletionPending) {
      throw const InitialSyncFailure(
        InitialSyncFailureKind.other,
        'account deletion pending',
      );
    }
  }

  InitialSyncAssessment? _bound(InitialSyncMeta meta, String uid) {
    final bound = meta.accountUid;
    if (bound == null || bound.isEmpty) return null;
    return InitialSyncAssessment(
      bound == uid
          ? InitialSyncAssessmentKind.alreadyLinked
          : InitialSyncAssessmentKind.linkedToOtherAccount,
    );
  }

  InitialSyncAssessment _classify(
    String uid,
    InitialSyncMeta meta,
    LocalSyncSnapshot local,
    CloudSnapshot cloud,
  ) {
    final summaryLocal = SyncDataSummary.ofLocal(local);
    final summaryCloud = SyncDataSummary.ofCloud(cloud);
    InitialSyncAssessment ready(InitialSyncMode mode) => InitialSyncAssessment(
          InitialSyncAssessmentKind.ready,
          mode: mode,
          local: summaryLocal,
          cloud: summaryCloud,
        );

    // An interrupted first upload for this account: the cloud already has
    // part of this device's data. If everything in the cloud came from
    // here, just continue (re-uploading is idempotent).
    final resumingUpload = meta.uid == uid &&
        meta.mode == InitialSyncModeName.upload &&
        (meta.state == InitialSyncState.inProgress ||
            meta.state == InitialSyncState.failed);
    if (resumingUpload && cloudIsSubsetOfLocal(local, cloud)) {
      return ready(InitialSyncMode.upload);
    }

    final localHas = local.hasUserData;
    final cloudHas = cloud.hasLiveData;
    if ((localHas && cloudHas) || hasCrossDeletions(local, cloud)) {
      return InitialSyncAssessment(
        InitialSyncAssessmentKind.needsMergeDecision,
        local: summaryLocal,
        cloud: summaryCloud,
      );
    }
    if (cloudHas) return ready(InitialSyncMode.restore);
    // Deletions alone are still uploaded, so they keep applying later.
    if (localHas || local.hasTombstones) return ready(InitialSyncMode.upload);
    return ready(InitialSyncMode.bindOnly);
  }

  Future<CloudSnapshot> _fetch(String uid) async {
    try {
      return await backend.fetchAll(uid);
    } on CloudSyncBackendException catch (e) {
      throw InitialSyncFailure(_kindOf(e), e.detail);
    } on TimeoutException catch (e) {
      throw InitialSyncFailure(InitialSyncFailureKind.network, '$e');
    }
  }

  Future<void> _commit(String uid, List<CloudWrite> writes) async {
    try {
      await backend.commit(uid, writes);
    } on CloudSyncBackendException catch (e) {
      throw InitialSyncFailure(_kindOf(e), e.detail);
    } on TimeoutException catch (e) {
      throw InitialSyncFailure(InitialSyncFailureKind.network, '$e');
    }
  }

  static InitialSyncFailureKind _kindOf(CloudSyncBackendException e) =>
      switch (e.kind) {
        CloudSyncErrorKind.network => InitialSyncFailureKind.network,
        CloudSyncErrorKind.permissionDenied =>
          InitialSyncFailureKind.permissionDenied,
        CloudSyncErrorKind.other => InitialSyncFailureKind.other,
      };
}
