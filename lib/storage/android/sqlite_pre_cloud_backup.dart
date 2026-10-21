import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One-time safety copy taken right before this device's data is first
/// connected to a cloud account (first upload / restore / merge).
///
/// Separate from `songbook.pre_sync_v3.backup.db`, which is never touched.
/// Never overwritten once it exists, and never deleted by the app.
const String preCloudSyncBackupFileName = 'songbook.pre_cloud_sync_v4.backup.db';

enum PreCloudBackupOutcome { created, alreadyExists, failed }

class PreCloudBackupAttempt {
  final PreCloudBackupOutcome outcome;
  final String backupPath;
  final Object? error;

  const PreCloudBackupAttempt(this.outcome, this.backupPath, {this.error});
}

const List<String> _copiedSidecarSuffixes = ['-wal', '-journal'];
const List<String> _allSidecarSuffixes = ['-wal', '-journal', '-shm'];
const List<String> _verifiedTables = [
  'songs',
  'folders',
  'folder_songs',
  'sync_tombstones',
];

/// Copies the open database at [databasePath] to
/// [preCloudSyncBackupFileName] next to it, unless that file exists.
///
/// The database is open (unlike the pre-v3 backup, which runs before the
/// first open), so the copy is made inside a write transaction on [db]:
/// that holds SQLite's write lock, so no commit or WAL checkpoint can
/// change the files mid-copy, and every app write waits until the copy is
/// done. The main file plus `-wal` / `-journal` are copied (recent commits
/// may live only in `-wal`), exactly like the pre-v3 backup.
///
/// The copy goes to a temp name, is opened and checked (`PRAGMA
/// quick_check`, and the same row counts as the live database had during
/// the copy), and only then renamed into place. On any failure only the
/// temp files this function created are removed; the live database is only
/// ever read. Never throws.
Future<PreCloudBackupAttempt> createPreCloudSyncBackupIfMissing({
  required Database db,
  required String databasePath,
}) async {
  final backupPath =
      p.join(p.dirname(databasePath), preCloudSyncBackupFileName);
  final tempPath = '$backupPath.tmp';
  try {
    if (await File(backupPath).exists()) {
      return PreCloudBackupAttempt(
        PreCloudBackupOutcome.alreadyExists,
        backupPath,
      );
    }
    await _deleteOwnFiles(tempPath);

    final expectedCounts = <String, int>{};
    await db.transaction((txn) async {
      for (final table in _verifiedTables) {
        final rows = await txn.rawQuery('SELECT COUNT(*) AS n FROM $table');
        expectedCounts[table] = rows.first['n'] as int;
      }
      await File(databasePath).copy(tempPath);
      for (final suffix in _copiedSidecarSuffixes) {
        final sidecar = File('$databasePath$suffix');
        if (await sidecar.exists()) {
          await sidecar.copy('$tempPath$suffix');
        }
      }
    });

    final copy = await openDatabase(tempPath, singleInstance: false);
    try {
      final check = await copy.rawQuery('PRAGMA quick_check');
      final result = check.isEmpty ? null : check.first.values.first;
      if (result != 'ok') {
        throw StateError('quick_check on backup returned: $result');
      }
      for (final table in _verifiedTables) {
        final rows = await copy.rawQuery('SELECT COUNT(*) AS n FROM $table');
        final n = rows.first['n'] as int;
        if (n != expectedCounts[table]) {
          throw StateError(
            'backup $table has $n rows, expected ${expectedCounts[table]}',
          );
        }
      }
    } finally {
      await copy.close();
    }

    for (final suffix in _allSidecarSuffixes) {
      final leftover = File('$tempPath$suffix');
      if (await leftover.exists()) await leftover.delete();
    }
    await File(tempPath).rename(backupPath);
    return PreCloudBackupAttempt(PreCloudBackupOutcome.created, backupPath);
  } catch (e) {
    debugPrint('[songbook.db] pre-cloud-sync backup failed: $e');
    try {
      await _deleteOwnFiles(tempPath);
    } catch (_) {
      // Best effort; replaced on the next attempt.
    }
    return PreCloudBackupAttempt(
      PreCloudBackupOutcome.failed,
      backupPath,
      error: e,
    );
  }
}

/// Only ever called with this module's own temp path.
Future<void> _deleteOwnFiles(String tempPath) async {
  for (final path in [
    tempPath,
    for (final s in _allSidecarSuffixes) '$tempPath$s',
  ]) {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
