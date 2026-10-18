import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One-time safety copy of `songbook.db`, taken before the first open that
/// migrates it to [targetVersion].
///
/// Why a file copy and not `VACUUM INTO`: sqflite on Android uses the OS's
/// SQLite (`android.database.sqlite`). `VACUUM INTO` needs SQLite 3.27,
/// which Android only ships from API 30, while this app supports API 24+
/// (SQLite 3.9) — it would fail on Android 7–10. A file-level copy is
/// consistent as long as no connection is writing, which holds here: this
/// runs before the app opens the database at all. The `-wal` / `-journal`
/// side files are copied too, because on WAL-mode databases (Android 9+
/// compatibility WAL) recently committed rows can live only in `-wal`.
///
/// Safety properties:
/// - The original database and its side files are only ever *read*.
/// - The copy goes to a temp name, is verified with `PRAGMA quick_check`,
///   and only then renamed to [preSyncBackupFileName]. A failure at any step
///   deletes only the temp files this function created.
/// - Runs at most once successfully: skipped when the backup already
///   exists, when the database doesn't exist yet (fresh install), or when
///   the database header already reports `user_version >= targetVersion`.
/// - Never deleted by the app. Removing it is a decision for after a
///   confirmed successful cloud sync, not part of this code.
const String preSyncBackupFileName = 'songbook.pre_sync_v3.backup.db';

enum PreMigrationBackupStatus {
  /// No database file yet — fresh install, nothing to back up.
  notNeededFreshInstall,

  /// Database is already at (or beyond) the target version.
  notNeededAlreadyMigrated,

  /// A backup from an earlier launch already exists; left untouched.
  alreadyExists,

  /// A new verified backup was written this launch.
  created,

  /// Backing up failed. The original database was not modified.
  failed,
}

class PreMigrationBackupResult {
  final PreMigrationBackupStatus status;
  final String? backupPath;
  final Object? error;

  const PreMigrationBackupResult(this.status, {this.backupPath, this.error});
}

/// Side files SQLite may keep next to a database. `-shm` is deliberately
/// not copied: it's a rebuildable index into `-wal`, and a stale copy is
/// worse than none.
const List<String> _copiedSidecarSuffixes = ['-wal', '-journal'];
const List<String> _allSidecarSuffixes = ['-wal', '-journal', '-shm'];

Future<PreMigrationBackupResult> backupBeforeMigrationIfNeeded({
  required String databasePath,
  required int targetVersion,
}) async {
  final dbFile = File(databasePath);
  final backupPath = p.join(p.dirname(databasePath), preSyncBackupFileName);

  try {
    if (!await dbFile.exists()) {
      return const PreMigrationBackupResult(
        PreMigrationBackupStatus.notNeededFreshInstall,
      );
    }
    if (await File(backupPath).exists()) {
      return PreMigrationBackupResult(
        PreMigrationBackupStatus.alreadyExists,
        backupPath: backupPath,
      );
    }
    final version = await readSqliteHeaderUserVersion(databasePath);
    if (version != null && version >= targetVersion) {
      return const PreMigrationBackupResult(
        PreMigrationBackupStatus.notNeededAlreadyMigrated,
      );
    }
  } catch (e) {
    debugPrint('[songbook.db] pre-migration backup check failed: $e');
    return PreMigrationBackupResult(PreMigrationBackupStatus.failed, error: e);
  }

  final tempPath = '$backupPath.tmp';
  try {
    await _deleteOwnFiles(tempPath);

    await dbFile.copy(tempPath);
    for (final suffix in _copiedSidecarSuffixes) {
      final sidecar = File('$databasePath$suffix');
      if (await sidecar.exists()) {
        await sidecar.copy('$tempPath$suffix');
      }
    }

    // Open the *copy* to verify it (and fold any copied -wal/-journal into
    // it, exactly as SQLite would for the original on its next open).
    final copy = await openDatabase(tempPath, singleInstance: false);
    try {
      final check = await copy.rawQuery('PRAGMA quick_check');
      final result = check.isEmpty ? null : check.first.values.first;
      if (result != 'ok') {
        throw StateError('quick_check on backup returned: $result');
      }
    } finally {
      await copy.close();
    }

    for (final suffix in _allSidecarSuffixes) {
      final leftover = File('$tempPath$suffix');
      if (await leftover.exists()) await leftover.delete();
    }
    await File(tempPath).rename(backupPath);
    return PreMigrationBackupResult(
      PreMigrationBackupStatus.created,
      backupPath: backupPath,
    );
  } catch (e) {
    debugPrint('[songbook.db] pre-migration backup failed: $e');
    try {
      await _deleteOwnFiles(tempPath);
    } catch (_) {
      // Best effort; a leftover temp file is harmless and is replaced on
      // the next attempt.
    }
    return PreMigrationBackupResult(PreMigrationBackupStatus.failed, error: e);
  }
}

/// Deletes the temp backup file and its side files. Only ever called with
/// this module's own temp path — never the real database.
Future<void> _deleteOwnFiles(String tempPath) async {
  for (final path in [tempPath, for (final s in _allSidecarSuffixes) '$tempPath$s']) {
    final entity = File(path);
    if (await entity.exists()) await entity.delete();
  }
}

/// Reads `PRAGMA user_version` straight from the SQLite file header
/// (big-endian int32 at byte offset 60) without opening a connection, so
/// checking it can't modify the file. Returns null if the file isn't a
/// readable SQLite database.
///
/// In WAL mode the header can lag behind the latest commit; that only ever
/// makes it report an *older* version, which errs toward taking a backup.
Future<int?> readSqliteHeaderUserVersion(String path) async {
  final raf = await File(path).open();
  try {
    final header = await raf.read(100);
    if (header.length < 100) return null;
    const magic = 'SQLite format 3\u0000';
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic.codeUnitAt(i)) return null;
    }
    return ByteData.sublistView(header).getInt32(60, Endian.big);
  } finally {
    await raf.close();
  }
}
