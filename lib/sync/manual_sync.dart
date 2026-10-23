/// Phase B-4A: two-way incremental sync for a device that is already bound
/// to the signed-in account (`sync_meta.account_uid`). Runs only when the
/// user taps "지금 동기화" — there is no automatic trigger of any kind.
///
/// Order of one run:
/// 1. Pull: documents changed since the per-collection cursors (with a 60 s
///    overlap; re-applying a document is harmless), plus the current cloud
///    state of every locally dirty row — so a row deleted in the cloud long
///    ago is never written back as live (deletion wins, and the security
///    rules would reject the whole batch).
/// 2. Apply, in ONE local transaction (aborts unless still bound to the
///    account): deletion always wins; otherwise newer `updatedAtMs` wins,
///    a tie goes to the cloud. Cloud winners are stored clean; local
///    winners stay (or become) dirty.
/// 3. Upload the remaining dirty rows in batches of at most 400; after
///    each batch, clear `sync_dirty` only for rows still at the version
///    that was uploaded.
/// 4. Only if everything succeeded: raise the pull cursors and record the
///    sync time. On any failure the cursors stay where they were, dirty
///    rows stay dirty and the binding is untouched, so the next manual sync
///    simply retries.
///
/// SQLite stays the source of truth; Firestore's offline persistence is
/// off, so `sync_dirty` is the only record of unsent changes.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'cloud_sync_backend.dart';
import 'initial_sync_plan.dart';
import 'local_sync_store.dart';
import 'sync_records.dart';

enum ManualSyncFailureKind {
  accountMismatch,

  /// An account deletion is pending on this device (Phase B-5).
  accountDeletionPending,
  network,
  permissionDenied,
  other,
}

/// The sync did not complete. Local data is intact and still usable; dirty
/// rows remain dirty; it can be retried. [detail] is for logs only.
class ManualSyncFailure implements Exception {
  final ManualSyncFailureKind kind;
  final String detail;

  const ManualSyncFailure(this.kind, this.detail);

  @override
  String toString() => 'ManualSyncFailure(${kind.name}: $detail)';
}

class ManualSyncResult {
  /// Documents read in the pull (changed + dirty-row lookups).
  final int pulledDocuments;

  /// Local rows the cloud changed. > 0 means screens should reload.
  final int localChanges;

  final int uploadedDocuments;

  const ManualSyncResult({
    required this.pulledDocuments,
    required this.localChanges,
    required this.uploadedDocuments,
  });
}

class ManualSyncEngine {
  /// Re-read window before each cursor, so a document whose server time
  /// is slightly older than one already seen (commit ordering) is not
  /// missed.
  static const overlapMs = 60 * 1000;

  final LocalSyncStore store;
  final CloudSyncBackend backend;
  final int batchSize;
  final int Function() _now;

  ManualSyncEngine({
    required this.store,
    required this.backend,
    this.batchSize = CloudSyncBackend.maxBatchWrites,
    int Function()? now,
  })  : assert(batchSize > 0 && batchSize <= CloudSyncBackend.maxBatchWrites),
        _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  Future<int?> lastSuccessfulSyncAtMs() async =>
      (await store.readMeta()).lastSuccessfulSyncAtMs;

  /// Throws [ManualSyncFailure]. Never touches `account_uid`.
  Future<ManualSyncResult> syncNow(String uid) async {
    try {
      final meta = await store.readMeta();
      if (meta.accountDeletionPending) {
        throw const SyncBlockedByAccountDeletion();
      }
      if (meta.accountUid == null || meta.accountUid != uid) {
        throw const SyncAccountMismatch();
      }

      // 1. Pull.
      final cursors = await store.readPullCursors();
      int? since(int? cursor) => cursor == null ? null : cursor - overlapMs;
      final changed = await backend.fetchChanged(
        uid,
        songsSinceMs: since(cursors.songsMs),
        foldersSinceMs: since(cursors.foldersMs),
        folderSongsSinceMs: since(cursors.folderSongsMs),
      );

      final before = await store.readSnapshot();
      final dirty = _dirtyKeys(before);
      final missingSongs =
          dirty.songs.where((id) => !changed.songs.containsKey(id)).toList();
      final missingFolders =
          dirty.folders.where((id) => !changed.folders.containsKey(id)).toList();
      final missingMemberships = dirty.memberships
          .where((key) => !changed.memberships.containsKey(key))
          .toList();
      var view = changed;
      var looked = CloudSnapshot();
      if (missingSongs.isNotEmpty ||
          missingFolders.isNotEmpty ||
          missingMemberships.isNotEmpty) {
        looked = await backend.fetchByIds(
          uid,
          songIds: missingSongs,
          folderIds: missingFolders,
          membershipIds: missingMemberships,
        );
        view = CloudSnapshot(
          songs: {...changed.songs, ...looked.songs},
          folders: {...changed.folders, ...looked.folders},
          memberships: {...changed.memberships, ...looked.memberships},
        );
      }

      // 2. Apply.
      final localChanges = await store.applyIncremental(
        uid: uid,
        apply: (fresh, writer) async {
          final plan = planIncrementalApply(fresh, view);
          await applyLocalPlan(writer, plan.apply);
          return IncrementalApplyOutcome(
            cleanTokens: plan.cleanTokens,
            markDirty: plan.markDirty,
            localChanges: plan.localChanges,
          );
        },
      );

      // 3. Upload. Only rows whose cloud state was looked at in step 1 may
      // be written as live; a row first edited during this sync waits for
      // the next one.
      final after = await store.readSnapshot();
      final checked = <String>{
        for (final id in view.songs.keys) songEntityKey(id),
        for (final id in view.folders.keys) folderEntityKey(id),
        for (final key in view.memberships.keys) membershipEntityKey(key),
        for (final id in dirty.songs) songEntityKey(id),
        for (final id in dirty.folders) folderEntityKey(id),
        for (final key in dirty.memberships) membershipEntityKey(key),
      };
      final uploads = buildIncrementalUploads(after, view, checked);
      for (var i = 0; i < uploads.length; i += batchSize) {
        final end =
            i + batchSize < uploads.length ? i + batchSize : uploads.length;
        final batch = uploads.sublist(i, end);
        await backend.commit(uid, [for (final u in batch) u.write]);
        await store.clearSyncDirtyIfUnchanged([for (final u in batch) u.token]);
      }

      // 4. Success only: advance cursors (pulled documents only).
      await store.commitIncrementalSuccess(
        uid: uid,
        cursors: PullCursors(
          songsMs: _maxServerMs(
            cursors.songsMs,
            changed.songs.values.map((e) => e.serverUpdatedAtMs),
          ),
          foldersMs: _maxServerMs(
            cursors.foldersMs,
            changed.folders.values.map((e) => e.serverUpdatedAtMs),
          ),
          folderSongsMs: _maxServerMs(
            cursors.folderSongsMs,
            changed.memberships.values.map((e) => e.serverUpdatedAtMs),
          ),
        ),
        syncedAtMs: _now(),
      );
      return ManualSyncResult(
        pulledDocuments: changed.songs.length +
            changed.folders.length +
            changed.memberships.length +
            looked.songs.length +
            looked.folders.length +
            looked.memberships.length,
        localChanges: localChanges,
        uploadedDocuments: uploads.length,
      );
    } on SyncBlockedByAccountDeletion {
      throw const ManualSyncFailure(
        ManualSyncFailureKind.accountDeletionPending,
        'account deletion pending',
      );
    } on SyncAccountMismatch {
      throw const ManualSyncFailure(
        ManualSyncFailureKind.accountMismatch,
        'device is not bound to this account',
      );
    } on CloudSyncBackendException catch (e) {
      final failure = ManualSyncFailure(
        switch (e.kind) {
          CloudSyncErrorKind.network => ManualSyncFailureKind.network,
          CloudSyncErrorKind.permissionDenied =>
            ManualSyncFailureKind.permissionDenied,
          CloudSyncErrorKind.other => ManualSyncFailureKind.other,
        },
        e.detail,
      );
      debugPrint('[sync] manual sync failed: $failure');
      throw failure;
    } on TimeoutException catch (e) {
      throw ManualSyncFailure(ManualSyncFailureKind.network, '$e');
    } on ManualSyncFailure {
      rethrow;
    } catch (e) {
      debugPrint('[sync] manual sync failed: $e');
      throw ManualSyncFailure(ManualSyncFailureKind.other, '$e');
    }
  }

  static int? _maxServerMs(int? current, Iterable<int?> seen) {
    var best = current;
    for (final ms in seen) {
      if (ms != null && (best == null || ms > best)) best = ms;
    }
    return best;
  }
}

class _DirtyKeys {
  final List<String> songs;
  final List<String> folders;
  final List<String> memberships;

  const _DirtyKeys(this.songs, this.folders, this.memberships);
}

_DirtyKeys _dirtyKeys(LocalSyncSnapshot s) => _DirtyKeys(
      [for (final r in s.songs.values) if (r.dirty) r.syncId],
      [for (final r in s.folders.values) if (r.dirty) r.syncId],
      [for (final r in s.memberships.values) if (r.dirty) r.key],
    );

// ---------------------------------------------------------------------------
// Pure decisions
// ---------------------------------------------------------------------------

class IncrementalPlan {
  final LocalApplyPlan apply;
  final List<SyncDirtyToken> cleanTokens;
  final List<SyncDirtyToken> markDirty;
  final int localChanges;

  const IncrementalPlan({
    required this.apply,
    required this.cleanTokens,
    required this.markDirty,
    required this.localChanges,
  });
}

/// Decides, for every cloud document in [view], what happens locally.
/// Local rows the cloud didn't mention are left alone (they upload later
/// if dirty).
IncrementalPlan planIncrementalApply(
  LocalSyncSnapshot local,
  CloudSnapshot view,
) {
  final apply = LocalApplyPlan();
  final clean = <SyncDirtyToken>[];
  final markDirty = <SyncDirtyToken>[];
  var changes = 0;

  for (final c in view.songs.values) {
    final id = c.syncId;
    final l = local.songs[id];
    final lt = local.songTombstones[id];
    if (c.deleted) {
      final at = c.deletedAtMs ?? c.updatedAtMs;
      if (l != null) {
        apply.songDeletions[id] = at;
        changes++;
      } else if (lt == null) {
        apply.songDeletions[id] = at; // record it, so it can't come back
      }
      if (lt != null && lt.dirty) clean.add(SyncDirtyToken.tombstone(lt));
      continue;
    }
    if (!c.isLive) continue;
    if (lt != null) {
      // Deleted here: deletion wins and must reach the cloud.
      if (!lt.dirty) markDirty.add(SyncDirtyToken.tombstone(lt));
      continue;
    }
    if (l == null) {
      apply.songUpserts.add(c);
      changes++;
    } else if (l.data == c.data!) {
      if (l.dirty) clean.add(SyncDirtyToken.song(id, l.syncUpdatedAtMs));
    } else if (effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt) >
        c.updatedAtMs) {
      if (!l.dirty) markDirty.add(SyncDirtyToken.song(id, l.syncUpdatedAtMs));
    } else {
      apply.songUpserts.add(c);
      changes++;
    }
  }

  for (final c in view.folders.values) {
    final id = c.syncId;
    final l = local.folders[id];
    final lt = local.folderTombstones[id];
    if (c.deleted) {
      final at = c.deletedAtMs ?? c.updatedAtMs;
      if (l != null) {
        apply.folderDeletions[id] = at;
        changes++;
      } else if (lt == null) {
        apply.folderDeletions[id] = at;
      }
      if (lt != null && lt.dirty) clean.add(SyncDirtyToken.tombstone(lt));
      continue;
    }
    if (!c.isLive) continue;
    if (lt != null) {
      if (!lt.dirty) markDirty.add(SyncDirtyToken.tombstone(lt));
      continue;
    }
    if (l == null) {
      apply.folderUpserts.add(c);
      changes++;
    } else if (l.data == c.data!) {
      if (l.dirty) clean.add(SyncDirtyToken.folder(id, l.syncUpdatedAtMs));
    } else if (effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt) >
        c.updatedAtMs) {
      if (!l.dirty) {
        markDirty.add(SyncDirtyToken.folder(id, l.syncUpdatedAtMs));
      }
    } else {
      apply.folderUpserts.add(c);
      changes++;
    }
  }

  bool songGone(String id) =>
      local.songTombstones.containsKey(id) || (view.songs[id]?.deleted ?? false);
  bool folderGone(String id) =>
      local.folderTombstones.containsKey(id) ||
      (view.folders[id]?.deleted ?? false);

  for (final c in view.memberships.values) {
    final key = c.key;
    final l = local.memberships[key];
    final lt = local.membershipTombstones[key];
    final parentGone = songGone(c.songSyncId) || folderGone(c.folderSyncId);
    // A membership is never live under a deleted song/folder (the parent's
    // deletion removes local rows; nothing is recreated).
    if (!c.deleted && (!c.isLive || parentGone)) continue;
    if (l == null && lt == null) {
      if (c.deleted) {
        if (!parentGone) apply.membershipRemovals.add(c); // record it
      } else {
        apply.membershipUpserts.add(c);
        changes++;
      }
      continue;
    }
    // Revision rule: higher revision wins (an explicit re-add beats an
    // older removal); same revision → removal wins; both live → newer,
    // tie → cloud.
    switch (compareLocalMembership(l, lt, c)) {
      case MembershipWinner.same:
        if (l != null && l.dirty) {
          clean.add(SyncDirtyToken.membership(
              c.folderSyncId, c.songSyncId, l.syncUpdatedAtMs));
        }
        if (lt != null && lt.dirty) clean.add(SyncDirtyToken.tombstone(lt));
      case MembershipWinner.local:
        if (l != null && !l.dirty) {
          markDirty.add(SyncDirtyToken.membership(
              c.folderSyncId, c.songSyncId, l.syncUpdatedAtMs));
        }
        if (lt != null && !lt.dirty) {
          markDirty.add(SyncDirtyToken.tombstone(lt));
        }
      case MembershipWinner.cloud:
        if (c.deleted) {
          apply.membershipRemovals.add(c);
          if (l != null) changes++;
        } else {
          apply.membershipUpserts.add(c);
          changes++;
        }
    }
  }

  return IncrementalPlan(
    apply: apply,
    cleanTokens: clean,
    markDirty: markDirty,
    localChanges: changes,
  );
}

class PlannedUpload {
  final CloudWrite write;
  final SyncDirtyToken token;

  const PlannedUpload(this.write, this.token);
}

/// Every dirty row and tombstone of [local], as cloud writes. A live row is
/// skipped if [view] shows its document deleted (never revived) or if its
/// cloud state wasn't looked at ([checkedEntityKeys]); it then stays dirty.
/// Order: songs and folders, then memberships, then deletion markers.
List<PlannedUpload> buildIncrementalUploads(
  LocalSyncSnapshot local,
  CloudSnapshot view,
  Set<String> checkedEntityKeys,
) {
  final live = <PlannedUpload>[];
  final members = <PlannedUpload>[];
  final deletions = <PlannedUpload>[];

  for (final l in local.songs.values) {
    if (!l.dirty) continue;
    if (view.songs[l.syncId]?.deleted ?? false) continue;
    if (!checkedEntityKeys.contains(songEntityKey(l.syncId))) continue;
    live.add(PlannedUpload(
      CloudDocCodec.putSong(
        l.syncId,
        l.data,
        effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt),
      ),
      SyncDirtyToken.song(l.syncId, l.syncUpdatedAtMs),
    ));
  }
  for (final l in local.folders.values) {
    if (!l.dirty) continue;
    if (view.folders[l.syncId]?.deleted ?? false) continue;
    if (!checkedEntityKeys.contains(folderEntityKey(l.syncId))) continue;
    live.add(PlannedUpload(
      CloudDocCodec.putFolder(
        l.syncId,
        l.data,
        effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt),
      ),
      SyncDirtyToken.folder(l.syncId, l.syncUpdatedAtMs),
    ));
  }
  for (final l in local.memberships.values) {
    if (!l.dirty) continue;
    // Never over a cloud state that beats it (e.g. a removal at the same
    // or a higher revision): that would revive it, which the rules reject.
    final cloud = view.memberships[l.key];
    if (cloud != null &&
        compareLocalMembership(l, null, cloud) == MembershipWinner.cloud) {
      continue;
    }
    if (view.songs[l.songSyncId]?.deleted ?? false) continue;
    if (view.folders[l.folderSyncId]?.deleted ?? false) continue;
    if (!checkedEntityKeys.contains(membershipEntityKey(l.key))) continue;
    members.add(PlannedUpload(
      CloudDocCodec.putMembership(
        l.folderSyncId,
        l.songSyncId,
        l.addedAt,
        effectiveLocalMs(l.syncUpdatedAtMs, l.addedAt),
        revision: l.revision,
      ),
      SyncDirtyToken.membership(
          l.folderSyncId, l.songSyncId, l.syncUpdatedAtMs),
    ));
  }
  for (final t in local.songTombstones.values) {
    if (!t.dirty) continue;
    deletions.add(PlannedUpload(
      CloudDocCodec.deleteSong(t.syncId, t.deletedAtMs),
      SyncDirtyToken.tombstone(t),
    ));
  }
  for (final t in local.folderTombstones.values) {
    if (!t.dirty) continue;
    deletions.add(PlannedUpload(
      CloudDocCodec.deleteFolder(t.syncId, t.deletedAtMs),
      SyncDirtyToken.tombstone(t),
    ));
  }
  for (final t in local.membershipTombstones.values) {
    if (!t.dirty) continue;
    final cloud = view.memberships[membershipDocId(t.syncId, t.relatedSyncId)];
    if (cloud != null &&
        compareLocalMembership(null, t, cloud) == MembershipWinner.cloud) {
      continue; // a newer cloud revision (e.g. a later re-add) wins
    }
    deletions.add(PlannedUpload(
      CloudDocCodec.deleteMembership(
        t.syncId,
        t.relatedSyncId,
        t.deletedAtMs,
        revision: t.membershipRevision,
      ),
      SyncDirtyToken.tombstone(t),
    ));
  }
  return [...live, ...members, ...deletions];
}
