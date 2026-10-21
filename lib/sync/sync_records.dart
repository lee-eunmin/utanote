/// Plain data types shared by the initial cloud sync (Phase B-3): what the
/// local database holds and what the cloud holds, in a form the pure-Dart
/// planner can compare. No Firestore or SQLite types appear here.
library;

/// The synced content of a song, exactly as stored. Dates are kept as the
/// raw stored strings so legacy `created_at` / `updated_at` values are
/// uploaded verbatim, never re-formatted.
class SongData {
  final String karaokeType;
  final String songNumber;
  final String title;
  final String? artist;
  final String? keyType;
  final int keyOffset;
  final String? difficulty;
  final String? practiceStatus;
  final String? memo;
  final bool favorite;
  final List<String> searchAliases;
  final String createdAt;
  final String updatedAt;

  const SongData({
    required this.karaokeType,
    required this.songNumber,
    required this.title,
    this.artist,
    this.keyType,
    this.keyOffset = 0,
    this.difficulty,
    this.practiceStatus,
    this.memo,
    this.favorite = false,
    this.searchAliases = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  bool operator ==(Object other) =>
      other is SongData &&
      other.karaokeType == karaokeType &&
      other.songNumber == songNumber &&
      other.title == title &&
      other.artist == artist &&
      other.keyType == keyType &&
      other.keyOffset == keyOffset &&
      other.difficulty == difficulty &&
      other.practiceStatus == practiceStatus &&
      other.memo == memo &&
      other.favorite == favorite &&
      _listEquals(other.searchAliases, searchAliases) &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        karaokeType,
        songNumber,
        title,
        artist,
        keyType,
        keyOffset,
        difficulty,
        practiceStatus,
        memo,
        favorite,
        Object.hashAll(searchAliases),
        createdAt,
        updatedAt,
      );
}

class FolderData {
  final String name;
  final String createdAt;
  final String updatedAt;

  const FolderData({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  bool operator ==(Object other) =>
      other is FolderData &&
      other.name == name &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(name, createdAt, updatedAt);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deterministic Firestore id of a folder membership. Sync ids are UUIDs
/// (no `_`), so the id is unambiguous. Never uses local integer ids.
String membershipDocId(String folderSyncId, String songSyncId) =>
    '${folderSyncId}_$songSyncId';

// ---------------------------------------------------------------------------
// Local side
// ---------------------------------------------------------------------------

class LocalSongRow {
  final String syncId;
  final SongData data;

  /// `sync_updated_at_ms`; NULL for legacy rows never edited since v3.
  final int? syncUpdatedAtMs;
  final bool dirty;

  const LocalSongRow({
    required this.syncId,
    required this.data,
    required this.syncUpdatedAtMs,
    required this.dirty,
  });
}

class LocalFolderRow {
  final String syncId;
  final FolderData data;
  final int? syncUpdatedAtMs;
  final bool dirty;

  const LocalFolderRow({
    required this.syncId,
    required this.data,
    required this.syncUpdatedAtMs,
    required this.dirty,
  });
}

/// Membership revision assumed when none is stored: a live membership is
/// its first add (1); a removal is at least add + remove (2). Same values
/// as the v5 local backfill, so pre-revision data compares consistently
/// on every device and in the cloud.
const int kDefaultLiveMembershipRevision = 1;
const int kDefaultRemovedMembershipRevision = 2;

class LocalMembershipRow {
  final String folderSyncId;
  final String songSyncId;
  final String addedAt;
  final int? syncUpdatedAtMs;
  final bool dirty;

  /// Membership revision (`folder_songs.revision`).
  final int revision;

  const LocalMembershipRow({
    required this.folderSyncId,
    required this.songSyncId,
    required this.addedAt,
    required this.syncUpdatedAtMs,
    required this.dirty,
    this.revision = kDefaultLiveMembershipRevision,
  });

  String get key => membershipDocId(folderSyncId, songSyncId);
}

/// A row of `sync_tombstones`. `entityType` uses the same strings as the
/// table (`song`, `folder`, `folder_song`).
class LocalTombstone {
  final String entityType;
  final String syncId;
  final String relatedSyncId;
  final int deletedAtMs;
  final bool dirty;

  /// Membership revision of a `folder_song` removal; null for song/folder
  /// tombstones.
  final int? revision;

  const LocalTombstone({
    required this.entityType,
    required this.syncId,
    required this.relatedSyncId,
    required this.deletedAtMs,
    required this.dirty,
    this.revision,
  });

  int get membershipRevision => revision ?? kDefaultRemovedMembershipRevision;
}

/// Outcome of comparing one membership's local and cloud states.
enum MembershipWinner { local, cloud, same }

/// Folder-membership conflict rule (Phase B-4A revisions):
/// 1. the higher revision wins, whatever its state — so an explicit re-add
///    (a newer revision) beats an older removal;
/// 2. same revision: a removal beats a live state (deletion wins within a
///    generation);
/// 3. same revision, both live: newer change wins, a tie goes to the cloud;
///    identical states are [MembershipWinner.same].
MembershipWinner compareMembership({
  required int localRevision,
  required bool localDeleted,
  required int localChangedMs,
  String? localAddedAt,
  required int cloudRevision,
  required bool cloudDeleted,
  required int cloudChangedMs,
  String? cloudAddedAt,
}) {
  if (localRevision != cloudRevision) {
    return localRevision > cloudRevision
        ? MembershipWinner.local
        : MembershipWinner.cloud;
  }
  if (localDeleted && cloudDeleted) return MembershipWinner.same;
  if (localDeleted) return MembershipWinner.local;
  if (cloudDeleted) return MembershipWinner.cloud;
  if (localAddedAt == cloudAddedAt) return MembershipWinner.same;
  return localChangedMs > cloudChangedMs
      ? MembershipWinner.local
      : MembershipWinner.cloud;
}

/// Everything the initial sync needs from the local database. Only
/// memberships whose song and folder both exist are included (legacy
/// orphans are not user data).
class LocalSyncSnapshot {
  final Map<String, LocalSongRow> songs;
  final Map<String, LocalFolderRow> folders;

  /// Keyed by [membershipDocId].
  final Map<String, LocalMembershipRow> memberships;

  /// Song / folder deletions keyed by sync id.
  final Map<String, LocalTombstone> songTombstones;
  final Map<String, LocalTombstone> folderTombstones;

  /// Membership removals keyed by [membershipDocId].
  final Map<String, LocalTombstone> membershipTombstones;

  const LocalSyncSnapshot({
    this.songs = const {},
    this.folders = const {},
    this.memberships = const {},
    this.songTombstones = const {},
    this.folderTombstones = const {},
    this.membershipTombstones = const {},
  });

  /// Real user data: any song, folder or (valid) membership.
  bool get hasUserData =>
      songs.isNotEmpty || folders.isNotEmpty || memberships.isNotEmpty;

  bool get hasTombstones =>
      songTombstones.isNotEmpty ||
      folderTombstones.isNotEmpty ||
      membershipTombstones.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Cloud side
// ---------------------------------------------------------------------------

class CloudSong {
  final String syncId;

  /// Null only for a deletion marker that never had content.
  final SongData? data;
  final int updatedAtMs;
  final bool deleted;
  final int? deletedAtMs;

  /// Server write time (Firestore `serverUpdatedAt`), when known.
  final int? serverUpdatedAtMs;

  const CloudSong({
    required this.syncId,
    required this.data,
    required this.updatedAtMs,
    this.deleted = false,
    this.deletedAtMs,
    this.serverUpdatedAtMs,
  });

  bool get isLive => !deleted && data != null;
}

class CloudFolder {
  final String syncId;
  final FolderData? data;
  final int updatedAtMs;
  final bool deleted;
  final int? deletedAtMs;

  /// Server write time (Firestore `serverUpdatedAt`), when known.
  final int? serverUpdatedAtMs;

  const CloudFolder({
    required this.syncId,
    required this.data,
    required this.updatedAtMs,
    this.deleted = false,
    this.deletedAtMs,
    this.serverUpdatedAtMs,
  });

  bool get isLive => !deleted && data != null;
}

class CloudMembership {
  final String folderSyncId;
  final String songSyncId;
  final String? addedAt;
  final int updatedAtMs;
  final bool deleted;
  final int? deletedAtMs;

  /// Server write time (Firestore `serverUpdatedAt`), when known.
  final int? serverUpdatedAtMs;

  /// Membership revision; documents written before revisions existed get
  /// the defaults (live 1, deleted 2) when parsed.
  final int revision;

  const CloudMembership({
    required this.folderSyncId,
    required this.songSyncId,
    required this.addedAt,
    required this.updatedAtMs,
    this.deleted = false,
    this.deletedAtMs,
    this.serverUpdatedAtMs,
    int? revision,
  }) : revision = revision ??
            (deleted
                ? kDefaultRemovedMembershipRevision
                : kDefaultLiveMembershipRevision);

  String get key => membershipDocId(folderSyncId, songSyncId);
  bool get isLive => !deleted && addedAt != null;
}

class CloudSnapshot {
  final Map<String, CloudSong> songs;
  final Map<String, CloudFolder> folders;

  /// Keyed by [membershipDocId].
  final Map<String, CloudMembership> memberships;

  const CloudSnapshot({
    this.songs = const {},
    this.folders = const {},
    this.memberships = const {},
  });

  /// Any live (not deleted) document.
  bool get hasLiveData =>
      songs.values.any((s) => s.isLive) ||
      folders.values.any((f) => f.isLive) ||
      memberships.values.any((m) => m.isLive);

  bool get isEmpty => songs.isEmpty && folders.isEmpty && memberships.isEmpty;
}

/// Live item counts, for explaining a merge to the user.
class SyncDataSummary {
  final int songs;
  final int folders;

  const SyncDataSummary({required this.songs, required this.folders});

  factory SyncDataSummary.ofLocal(LocalSyncSnapshot s) =>
      SyncDataSummary(songs: s.songs.length, folders: s.folders.length);

  factory SyncDataSummary.ofCloud(CloudSnapshot s) => SyncDataSummary(
        songs: s.songs.values.where((e) => e.isLive).length,
        folders: s.folders.values.where((e) => e.isLive).length,
      );
}
