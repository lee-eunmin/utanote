import 'package:sqflite/sqflite.dart';

import '../../models/folder.dart';
import '../../models/song.dart';
import '../cloud_apply.dart';
import '../sync_id.dart';
import 'sqlite_schema.dart';

/// SQLite implementation of [CloudApplyStore]. See that interface for the
/// contract. Every write here uses [SyncDirty.clean].
class SqliteCloudApplyStore implements CloudApplyStore {
  final Database _db;

  SqliteCloudApplyStore(this._db);

  @override
  Future<T> applyBatch<T>(
    Future<T> Function(CloudApplyWriter writer) body,
  ) {
    return _db.transaction((txn) async {
      await writeSyncMetaIfMissing(
        txn,
        SyncMetaKeys.syncApplyInProgress,
        nowUtcMs().toString(),
      );
      return body(_SqliteCloudApplyWriter(txn));
    });
  }

  @override
  Future<void> finishApply() async {
    await _db.delete(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [SyncMetaKeys.syncApplyInProgress],
    );
  }

  @override
  Future<bool> isApplyInProgress() async {
    return await readSyncMeta(_db, SyncMetaKeys.syncApplyInProgress) != null;
  }
}

class _SqliteCloudApplyWriter implements CloudApplyWriter {
  final Transaction _txn;

  _SqliteCloudApplyWriter(this._txn);

  @override
  Future<CloudApplyOutcome> upsertSong(
    Song song, {
    required int updatedAtMs,
  }) async {
    final syncId = _requireSyncId(song.syncId);
    final map = song.toDbMap()
      ..remove('id')
      ..remove('sync_id')
      ..['sync_updated_at_ms'] = updatedAtMs
      ..['sync_dirty'] = SyncDirty.clean;
    return _upsertBySyncId('songs', TombstoneEntity.song, syncId, map);
  }

  @override
  Future<CloudApplyOutcome> upsertFolder(
    Folder folder, {
    required int updatedAtMs,
  }) async {
    final syncId = _requireSyncId(folder.syncId);
    final map = folder.toDbMap()
      ..remove('id')
      ..remove('sync_id')
      ..['sync_updated_at_ms'] = updatedAtMs
      ..['sync_dirty'] = SyncDirty.clean;
    return _upsertBySyncId('folders', TombstoneEntity.folder, syncId, map);
  }

  Future<CloudApplyOutcome> _upsertBySyncId(
    String table,
    String tombstoneEntity,
    String syncId,
    Map<String, Object?> map,
  ) async {
    if (await _hasTombstone(tombstoneEntity, syncId)) {
      return CloudApplyOutcome.skippedDeleted;
    }
    final updated = await _txn.update(
      table,
      map,
      where: 'sync_id = ?',
      whereArgs: [syncId],
    );
    if (updated > 0) return CloudApplyOutcome.updated;
    await _txn.insert(table, {...map, 'sync_id': syncId});
    return CloudApplyOutcome.inserted;
  }

  @override
  Future<CloudApplyOutcome> upsertFolderSong({
    required String folderSyncId,
    required String songSyncId,
    required DateTime addedAt,
    required int updatedAtMs,
  }) async {
    final folderId = await _localIdOf('folders', folderSyncId);
    final songId = await _localIdOf('songs', songSyncId);
    if (folderId == null || songId == null) {
      return CloudApplyOutcome.skippedMissingParent;
    }
    final values = {
      'added_at': addedAt.toIso8601String(),
      'sync_updated_at_ms': updatedAtMs,
      'sync_dirty': SyncDirty.clean,
    };
    final updated = await _txn.update(
      'folder_songs',
      values,
      where: 'folder_id = ? AND song_id = ?',
      whereArgs: [folderId, songId],
    );
    if (updated == 0) {
      await _txn.insert('folder_songs', {
        'folder_id': folderId,
        'song_id': songId,
        ...values,
      });
    }
    // Same as a local re-add: the membership is live, so its removal
    // record no longer applies.
    await _txn.delete(
      'sync_tombstones',
      where: 'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
      whereArgs: [TombstoneEntity.folderSong, folderSyncId, songSyncId],
    );
    return updated > 0 ? CloudApplyOutcome.updated : CloudApplyOutcome.inserted;
  }

  @override
  Future<void> applySongDeletion(
    String syncId, {
    required int deletedAtMs,
  }) async {
    _requireSyncId(syncId);
    final id = await _localIdOf('songs', syncId);
    if (id != null) {
      await _txn.delete('folder_songs', where: 'song_id = ?', whereArgs: [id]);
      await _txn.delete('songs', where: 'id = ?', whereArgs: [id]);
    }
    await recordTombstone(
      _txn,
      TombstoneEntity.song,
      syncId,
      deletedAtMs: deletedAtMs,
      syncDirty: SyncDirty.clean,
    );
  }

  @override
  Future<void> applyFolderDeletion(
    String syncId, {
    required int deletedAtMs,
  }) async {
    _requireSyncId(syncId);
    final id = await _localIdOf('folders', syncId);
    if (id != null) {
      await _txn.delete('folder_songs', where: 'folder_id = ?', whereArgs: [id]);
      await _txn.delete('folders', where: 'id = ?', whereArgs: [id]);
    }
    await recordTombstone(
      _txn,
      TombstoneEntity.folder,
      syncId,
      deletedAtMs: deletedAtMs,
      syncDirty: SyncDirty.clean,
    );
  }

  @override
  Future<void> applyFolderSongRemoval({
    required String folderSyncId,
    required String songSyncId,
    required int deletedAtMs,
  }) async {
    _requireSyncId(folderSyncId);
    _requireSyncId(songSyncId);
    final folderId = await _localIdOf('folders', folderSyncId);
    final songId = await _localIdOf('songs', songSyncId);
    if (folderId != null && songId != null) {
      await _txn.delete(
        'folder_songs',
        where: 'folder_id = ? AND song_id = ?',
        whereArgs: [folderId, songId],
      );
    }
    await recordTombstone(
      _txn,
      TombstoneEntity.folderSong,
      folderSyncId,
      relatedSyncId: songSyncId,
      deletedAtMs: deletedAtMs,
      syncDirty: SyncDirty.clean,
    );
  }

  Future<int?> _localIdOf(String table, String syncId) async {
    final rows = await _txn.query(
      table,
      columns: ['id'],
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  Future<bool> _hasTombstone(String entityType, String syncId) async {
    final rows = await _txn.query(
      'sync_tombstones',
      columns: ['sync_id'],
      where: "entity_type = ? AND sync_id = ? AND related_sync_id = ''",
      whereArgs: [entityType, syncId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static String _requireSyncId(String? syncId) {
    if (!hasSyncId(syncId)) {
      throw ArgumentError('Cloud data must carry a sync id.');
    }
    return syncId!;
  }
}
