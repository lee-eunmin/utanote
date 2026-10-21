/// Pure decision logic of the initial cloud sync: given what the device has
/// and what the cloud has, decide what to upload, what to apply locally and
/// which local rows end up matching the cloud.
///
/// The same rules serve every mode — a first upload (cloud empty), a
/// restore (device empty) and a user-approved merge:
/// - Identity is the sync id (memberships: folderSyncId_songSyncId).
///   Similar-looking songs with different ids are both kept; nothing is
///   de-duplicated by title/artist/number.
/// - A deletion on either side always wins, and a deleted cloud document is
///   never written back as live.
/// - Otherwise the newer change wins (`updatedAtMs`; legacy rows without
///   `sync_updated_at_ms` fall back to their `updated_at` string). On a tie
///   the cloud wins. Identical content is left alone on both sides.
/// - A deleted song or folder takes its folder memberships with it.
library;

import '../models/folder.dart';
import '../models/song.dart';
import '../storage/cloud_apply.dart';
import 'cloud_sync_backend.dart';
import 'local_sync_store.dart';
import 'sync_records.dart';

class LocalApplyPlan {
  final List<CloudSong> songUpserts = [];
  final List<CloudFolder> folderUpserts = [];
  final List<CloudMembership> membershipUpserts = [];

  /// sync id → deletedAtMs
  final Map<String, int> songDeletions = {};
  final Map<String, int> folderDeletions = {};
  final List<CloudMembership> membershipRemovals = [];

  bool get isEmpty =>
      songUpserts.isEmpty &&
      folderUpserts.isEmpty &&
      membershipUpserts.isEmpty &&
      songDeletions.isEmpty &&
      folderDeletions.isEmpty &&
      membershipRemovals.isEmpty;
}

class InitialSyncPlan {
  /// Documents to write to the cloud, songs and folders before
  /// memberships, live writes before deletion markers.
  final List<CloudWrite> cloudWrites;

  /// Cloud data that wins locally (applied through the clean path).
  final LocalApplyPlan localApply;

  /// Local rows that will match the cloud once [cloudWrites] succeed.
  final List<SyncDirtyToken> cleanTokens;

  const InitialSyncPlan({
    required this.cloudWrites,
    required this.localApply,
    required this.cleanTokens,
  });

  Set<String> get uploadedEntityKeys =>
      {for (final w in cloudWrites) w.entityKey};
}

/// Effective change time of a local row: `sync_updated_at_ms`, else the
/// legacy timestamp string, else 0.
int effectiveLocalMs(int? syncUpdatedAtMs, String legacyTimestamp) =>
    syncUpdatedAtMs ?? parseTimestampMs(legacyTimestamp) ?? 0;

int? parseTimestampMs(String value) =>
    DateTime.tryParse(value)?.toUtc().millisecondsSinceEpoch;

InitialSyncPlan buildInitialSyncPlan(
  LocalSyncSnapshot local,
  CloudSnapshot cloud, {
  required int nowMs,
}) {
  final liveWrites = <CloudWrite>[];
  final membershipWrites = <CloudWrite>[];
  final deletionWrites = <CloudWrite>[];
  final apply = LocalApplyPlan();
  final tokens = <SyncDirtyToken>[];

  // ---- songs --------------------------------------------------------------
  final deadSongs = <String, int>{}; // id → deletedAtMs
  final liveSongs = <String>{};
  for (final id in {
    ...local.songs.keys,
    ...local.songTombstones.keys,
    ...cloud.songs.keys,
  }) {
    final l = local.songs[id];
    final lt = local.songTombstones[id];
    final c = cloud.songs[id];

    if (lt != null || (c != null && c.deleted)) {
      if (c != null && c.deleted) {
        final at = c.deletedAtMs ?? c.updatedAtMs;
        deadSongs[id] = at;
        if (l != null || lt == null) apply.songDeletions[id] = at;
        if (lt != null) tokens.add(SyncDirtyToken.tombstone(lt));
      } else {
        deadSongs[id] = lt!.deletedAtMs;
        deletionWrites.add(CloudDocCodec.deleteSong(id, lt.deletedAtMs));
        tokens.add(SyncDirtyToken.tombstone(lt));
        if (l != null) apply.songDeletions[id] = lt.deletedAtMs;
      }
      continue;
    }

    liveSongs.add(id);
    final cLive = c != null && c.isLive ? c : null;
    if (l != null && cLive != null) {
      if (l.data == cLive.data!) {
        tokens.add(SyncDirtyToken.song(id, l.syncUpdatedAtMs));
      } else if (effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt) >
          cLive.updatedAtMs) {
        _pushSong(l, liveWrites, tokens);
      } else {
        apply.songUpserts.add(cLive);
      }
    } else if (l != null) {
      _pushSong(l, liveWrites, tokens);
    } else if (cLive != null) {
      apply.songUpserts.add(cLive);
    }
  }

  // ---- folders ------------------------------------------------------------
  final deadFolders = <String, int>{};
  final liveFolders = <String>{};
  for (final id in {
    ...local.folders.keys,
    ...local.folderTombstones.keys,
    ...cloud.folders.keys,
  }) {
    final l = local.folders[id];
    final lt = local.folderTombstones[id];
    final c = cloud.folders[id];

    if (lt != null || (c != null && c.deleted)) {
      if (c != null && c.deleted) {
        final at = c.deletedAtMs ?? c.updatedAtMs;
        deadFolders[id] = at;
        if (l != null || lt == null) apply.folderDeletions[id] = at;
        if (lt != null) tokens.add(SyncDirtyToken.tombstone(lt));
      } else {
        deadFolders[id] = lt!.deletedAtMs;
        deletionWrites.add(CloudDocCodec.deleteFolder(id, lt.deletedAtMs));
        tokens.add(SyncDirtyToken.tombstone(lt));
        if (l != null) apply.folderDeletions[id] = lt.deletedAtMs;
      }
      continue;
    }

    liveFolders.add(id);
    final cLive = c != null && c.isLive ? c : null;
    if (l != null && cLive != null) {
      if (l.data == cLive.data!) {
        tokens.add(SyncDirtyToken.folder(id, l.syncUpdatedAtMs));
      } else if (effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt) >
          cLive.updatedAtMs) {
        _pushFolder(l, liveWrites, tokens);
      } else {
        apply.folderUpserts.add(cLive);
      }
    } else if (l != null) {
      _pushFolder(l, liveWrites, tokens);
    } else if (cLive != null) {
      apply.folderUpserts.add(cLive);
    }
  }

  // ---- memberships --------------------------------------------------------
  for (final key in {
    ...local.memberships.keys,
    ...local.membershipTombstones.keys,
    ...cloud.memberships.keys,
  }) {
    final l = local.memberships[key];
    final lt = local.membershipTombstones[key];
    final c = cloud.memberships[key];
    final folderId = l?.folderSyncId ?? c?.folderSyncId ?? lt!.syncId;
    final songId = l?.songSyncId ?? c?.songSyncId ?? lt!.relatedSyncId;

    // A deleted (or entirely unknown) song/folder takes the membership
    // with it. Local rows of a dead parent are removed by its deletion.
    final parentDead =
        deadSongs.containsKey(songId) || deadFolders.containsKey(folderId);
    final parentMissing =
        !liveSongs.contains(songId) || !liveFolders.contains(folderId);
    if (parentDead || parentMissing) {
      if (c != null && !c.deleted) {
        final at = deadSongs[songId] ??
            deadFolders[folderId] ??
            lt?.deletedAtMs ??
            nowMs;
        deletionWrites.add(CloudDocCodec.deleteMembership(folderId, songId, at));
      }
      if (lt != null) tokens.add(SyncDirtyToken.tombstone(lt));
      continue;
    }

    if (lt != null || (c != null && c.deleted)) {
      if (c != null && c.deleted) {
        // Applied even with no local row: records the removal locally.
        if (lt == null) apply.membershipRemovals.add(c);
        if (lt != null) tokens.add(SyncDirtyToken.tombstone(lt));
      } else {
        deletionWrites.add(
          CloudDocCodec.deleteMembership(folderId, songId, lt!.deletedAtMs),
        );
        tokens.add(SyncDirtyToken.tombstone(lt));
      }
      continue;
    }

    final cLive = c != null && c.isLive ? c : null;
    if (l != null && cLive != null) {
      if (l.addedAt == cLive.addedAt) {
        tokens.add(
          SyncDirtyToken.membership(folderId, songId, l.syncUpdatedAtMs),
        );
      } else if (effectiveLocalMs(l.syncUpdatedAtMs, l.addedAt) >
          cLive.updatedAtMs) {
        _pushMembership(l, membershipWrites, tokens);
      } else {
        apply.membershipUpserts.add(cLive);
      }
    } else if (l != null) {
      _pushMembership(l, membershipWrites, tokens);
    } else if (cLive != null) {
      apply.membershipUpserts.add(cLive);
    }
  }

  return InitialSyncPlan(
    cloudWrites: [...liveWrites, ...membershipWrites, ...deletionWrites],
    localApply: apply,
    cleanTokens: tokens,
  );
}

void _pushSong(
  LocalSongRow l,
  List<CloudWrite> writes,
  List<SyncDirtyToken> tokens,
) {
  writes.add(
    CloudDocCodec.putSong(
      l.syncId,
      l.data,
      effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt),
    ),
  );
  tokens.add(SyncDirtyToken.song(l.syncId, l.syncUpdatedAtMs));
}

void _pushFolder(
  LocalFolderRow l,
  List<CloudWrite> writes,
  List<SyncDirtyToken> tokens,
) {
  writes.add(
    CloudDocCodec.putFolder(
      l.syncId,
      l.data,
      effectiveLocalMs(l.syncUpdatedAtMs, l.data.updatedAt),
    ),
  );
  tokens.add(SyncDirtyToken.folder(l.syncId, l.syncUpdatedAtMs));
}

void _pushMembership(
  LocalMembershipRow l,
  List<CloudWrite> writes,
  List<SyncDirtyToken> tokens,
) {
  writes.add(
    CloudDocCodec.putMembership(
      l.folderSyncId,
      l.songSyncId,
      l.addedAt,
      effectiveLocalMs(l.syncUpdatedAtMs, l.addedAt),
    ),
  );
  tokens.add(
    SyncDirtyToken.membership(l.folderSyncId, l.songSyncId, l.syncUpdatedAtMs),
  );
}

/// Applies [plan] through the clean cloud-apply path, skipping anything
/// whose entity key is in [skipEntityKeys] (rows this run uploaded: the
/// cloud now holds the local version). Order: songs, folders, deletions,
/// then memberships, so a membership is only created under live parents.
Future<void> applyLocalPlan(
  CloudApplyWriter writer,
  LocalApplyPlan plan, {
  Set<String> skipEntityKeys = const {},
}) async {
  for (final c in plan.songUpserts) {
    if (skipEntityKeys.contains(songEntityKey(c.syncId))) continue;
    await writer.upsertSong(
      songFromCloud(c),
      updatedAtMs: c.updatedAtMs,
    );
  }
  for (final c in plan.folderUpserts) {
    if (skipEntityKeys.contains(folderEntityKey(c.syncId))) continue;
    await writer.upsertFolder(
      folderFromCloud(c),
      updatedAtMs: c.updatedAtMs,
    );
  }
  for (final e in plan.songDeletions.entries) {
    await writer.applySongDeletion(e.key, deletedAtMs: e.value);
  }
  for (final e in plan.folderDeletions.entries) {
    await writer.applyFolderDeletion(e.key, deletedAtMs: e.value);
  }
  for (final c in plan.membershipUpserts) {
    if (skipEntityKeys.contains(membershipEntityKey(c.key))) continue;
    await writer.upsertFolderSong(
      folderSyncId: c.folderSyncId,
      songSyncId: c.songSyncId,
      addedAt: _parseDate(c.addedAt!, c.updatedAtMs),
      updatedAtMs: c.updatedAtMs,
    );
  }
  for (final c in plan.membershipRemovals) {
    await writer.applyFolderSongRemoval(
      folderSyncId: c.folderSyncId,
      songSyncId: c.songSyncId,
      deletedAtMs: c.deletedAtMs ?? c.updatedAtMs,
    );
  }
}

Song songFromCloud(CloudSong c) {
  final d = c.data!;
  return Song(
    karaokeType: d.karaokeType,
    songNumber: d.songNumber,
    title: d.title,
    artist: d.artist,
    keyType: d.keyType,
    keyOffset: d.keyOffset,
    difficulty: d.difficulty,
    practiceStatus: d.practiceStatus,
    memo: d.memo,
    favorite: d.favorite,
    searchAliases: d.searchAliases,
    createdAt: _parseDate(d.createdAt, c.updatedAtMs),
    updatedAt: _parseDate(d.updatedAt, c.updatedAtMs),
    syncId: c.syncId,
  );
}

Folder folderFromCloud(CloudFolder c) {
  final d = c.data!;
  return Folder(
    name: d.name,
    createdAt: _parseDate(d.createdAt, c.updatedAtMs),
    updatedAt: _parseDate(d.updatedAt, c.updatedAtMs),
    syncId: c.syncId,
  );
}

DateTime _parseDate(String value, int fallbackMs) =>
    DateTime.tryParse(value) ??
    DateTime.fromMillisecondsSinceEpoch(fallbackMs);

/// Whether a local tombstone/row set "knows" every cloud document, i.e. the
/// cloud holds nothing that didn't come from this device. Used to resume an
/// interrupted first upload without asking the user to merge.
bool cloudIsSubsetOfLocal(LocalSyncSnapshot local, CloudSnapshot cloud) {
  bool knownSong(String id) =>
      local.songs.containsKey(id) || local.songTombstones.containsKey(id);
  bool knownFolder(String id) =>
      local.folders.containsKey(id) || local.folderTombstones.containsKey(id);
  return cloud.songs.keys.every(knownSong) &&
      cloud.folders.keys.every(knownFolder) &&
      cloud.memberships.values.every(
        (m) => knownSong(m.songSyncId) && knownFolder(m.folderSyncId),
      );
}

/// Whether a deletion on one side would remove live data on the other.
bool hasCrossDeletions(LocalSyncSnapshot local, CloudSnapshot cloud) {
  for (final id in local.songTombstones.keys) {
    if (cloud.songs[id]?.isLive ?? false) return true;
  }
  for (final id in local.folderTombstones.keys) {
    if (cloud.folders[id]?.isLive ?? false) return true;
  }
  for (final key in local.membershipTombstones.keys) {
    if (cloud.memberships[key]?.isLive ?? false) return true;
  }
  for (final s in cloud.songs.values) {
    if (s.deleted && local.songs.containsKey(s.syncId)) return true;
  }
  for (final f in cloud.folders.values) {
    if (f.deleted && local.folders.containsKey(f.syncId)) return true;
  }
  for (final m in cloud.memberships.values) {
    if (m.deleted && local.memberships.containsKey(m.key)) return true;
  }
  return false;
}
