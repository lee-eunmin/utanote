import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/manual_sync.dart';
import 'package:utanote/sync/sync_records.dart';

import 'support/sync_fakes.dart';

/// Folder-membership revisions: a membership's every user change is a new
/// revision; the higher revision wins, a removal wins within the same
/// revision, and only a strictly newer revision may bring a removed
/// membership back (an explicit re-add).

const _uid = 'uid-alice';

void main() {
  late Directory root;
  var deviceCounter = 0;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('utanote_membership_rev_');
  });

  tearDown(() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
  });

  Future<SqliteLocalStorage> device() async {
    final dir = p.join(root.path, 'device_${deviceCounter++}');
    await Directory(dir).create(recursive: true);
    await databaseFactory.setDatabasesPath(dir);
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  Database dbOf(SqliteLocalStorage s) => s.databaseForTesting;
  Future<void> sync(SqliteLocalStorage s, FakeCloudBackend cloud) =>
      ManualSyncEngine(store: s.syncStore, backend: cloud).syncNow(_uid);

  final day = DateTime.parse('2024-01-01T00:00:00.000');

  /// Live revision of the membership, or null if not a member.
  Future<int?> liveRevision(SqliteLocalStorage s, String folderSyncId,
      String songSyncId) async {
    final rows = await dbOf(s).rawQuery('''
      SELECT fs.revision FROM folder_songs fs
      JOIN folders f ON f.id = fs.folder_id JOIN songs x ON x.id = fs.song_id
      WHERE f.sync_id = ? AND x.sync_id = ?
    ''', [folderSyncId, songSyncId]);
    return rows.isEmpty ? null : rows.first['revision'] as int;
  }

  Future<int?> removedRevision(SqliteLocalStorage s, String folderSyncId,
      String songSyncId) async {
    final rows = await dbOf(s).query('sync_tombstones',
        columns: ['revision'],
        where: "entity_type = 'folder_song' AND sync_id = ? AND related_sync_id = ?",
        whereArgs: [folderSyncId, songSyncId]);
    return rows.isEmpty ? null : rows.first['revision'] as int?;
  }

  Future<(int, int)> localIds(
      SqliteLocalStorage s, String folderSyncId, String songSyncId) async {
    final f = await dbOf(s)
        .query('folders', where: 'sync_id = ?', whereArgs: [folderSyncId]);
    final x = await dbOf(s)
        .query('songs', where: 'sync_id = ?', whereArgs: [songSyncId]);
    return (f.first['id'] as int, x.first['id'] as int);
  }

  Future<void> add(SqliteLocalStorage s, String f, String x) async {
    final (fid, sid) = await localIds(s, f, x);
    await s.folders.addSong(fid, sid);
  }

  Future<void> remove(SqliteLocalStorage s, String f, String x) async {
    final (fid, sid) = await localIds(s, f, x);
    await s.folders.removeSong(fid, sid);
  }

  Map<String, Object?> doc(FakeCloudBackend cloud, String f, String x) =>
      cloud.docOf(_uid, 'folderSongs', '${f}_$x')!;

  /// Two bound devices sharing one song in one folder (revision 1).
  Future<(SqliteLocalStorage, SqliteLocalStorage, FakeCloudBackend, String, String)>
      twoDevices() async {
    final cloud = FakeCloudBackend();
    final a = await device();
    final song = await a.songs.create(Song(
        karaokeType: 'TJ',
        songNumber: '1',
        title: '곡',
        createdAt: day,
        updatedAt: day));
    final folder = await a.folders
        .create(Folder(name: '폴더', createdAt: day, updatedAt: day));
    await a.folders.addSong(folder.id!, song.id!);
    await InitialSyncEngine(store: a.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.upload);
    final b = await device();
    await InitialSyncEngine(store: b.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.restore);
    return (a, b, cloud, folder.syncId!, song.syncId!);
  }

  // -------------------------------------------------------------------------
  group('conflict rule', () {
    MembershipWinner cmp(int lr, bool ld, int cr, bool cd,
            {int lm = 0, int cm = 0, String? la = 'x', String? ca = 'x'}) =>
        compareMembership(
          localRevision: lr,
          localDeleted: ld,
          localChangedMs: lm,
          localAddedAt: ld ? null : la,
          cloudRevision: cr,
          cloudDeleted: cd,
          cloudChangedMs: cm,
          cloudAddedAt: cd ? null : ca,
        );

    test('higher live revision beats lower deleted revision', () {
      expect(cmp(3, false, 2, true), MembershipWinner.local);
      expect(cmp(2, true, 3, false), MembershipWinner.cloud);
    });

    test('higher deleted revision beats lower live revision', () {
      expect(cmp(4, true, 3, false), MembershipWinner.local);
      expect(cmp(3, false, 4, true), MembershipWinner.cloud);
    });

    test('same revision: deleted wins (both directions)', () {
      expect(cmp(3, true, 3, false), MembershipWinner.local);
      expect(cmp(3, false, 3, true), MembershipWinner.cloud);
      expect(cmp(2, true, 2, true), MembershipWinner.same);
    });

    test('same revision, both live: newer wins, tie goes to the cloud', () {
      expect(cmp(1, false, 1, false, lm: 20, cm: 10, la: 'a', ca: 'b'),
          MembershipWinner.local);
      expect(cmp(1, false, 1, false, lm: 10, cm: 20, la: 'a', ca: 'b'),
          MembershipWinner.cloud);
      expect(cmp(1, false, 1, false, lm: 10, cm: 10, la: 'a', ca: 'b'),
          MembershipWinner.cloud);
      expect(cmp(1, false, 1, false), MembershipWinner.same);
    });

    test('cloud documents without a revision: live 1, deleted 2', () {
      final live = CloudDocCodec.parseMembership('f_s', {
        'folderSyncId': 'f',
        'songSyncId': 's',
        'addedAt': '2024-01-01T00:00:00.000',
        'deleted': false,
      })!;
      final gone = CloudDocCodec.parseMembership('f_s', {
        'folderSyncId': 'f',
        'songSyncId': 's',
        'deleted': true,
      })!;
      expect(live.revision, 1);
      expect(gone.revision, 2);
    });
  });

  // -------------------------------------------------------------------------
  group('local revisions', () {
    test('add 1 -> remove 2 -> re-add 3 -> remove 4', () async {
      final (a, _, _, f, s) = await twoDevices();
      expect(await liveRevision(a, f, s), 1);
      await remove(a, f, s);
      expect(await liveRevision(a, f, s), isNull);
      expect(await removedRevision(a, f, s), 2);
      await add(a, f, s);
      expect(await liveRevision(a, f, s), 3);
      expect(await removedRevision(a, f, s), isNull);
      await remove(a, f, s);
      expect(await removedRevision(a, f, s), 4);
    });

    test('adding an existing member or removing a non-member changes nothing',
        () async {
      final (a, _, _, f, s) = await twoDevices();
      await add(a, f, s);
      expect(await liveRevision(a, f, s), 1);
      await remove(a, f, s);
      await remove(a, f, s);
      expect(await removedRevision(a, f, s), 2);
    });
  });

  // -------------------------------------------------------------------------
  group('sync', () {
    test('removal, explicit re-add and removal again all reach the other '
        'device', () async {
      final (a, b, cloud, f, s) = await twoDevices();
      await remove(a, f, s);
      await sync(a, cloud);
      expect(doc(cloud, f, s)['deleted'], isTrue);
      expect(doc(cloud, f, s)['revision'], 2);
      await sync(b, cloud);
      expect(await liveRevision(b, f, s), isNull);
      expect(await removedRevision(b, f, s), 2);

      await add(a, f, s); // explicit re-add: revision 3
      await sync(a, cloud);
      expect(doc(cloud, f, s)['deleted'], isFalse);
      expect(doc(cloud, f, s)['revision'], 3);
      await sync(b, cloud);
      expect(await liveRevision(b, f, s), 3);

      await remove(b, f, s); // removal again, from the other device: 4
      await sync(b, cloud);
      await sync(a, cloud);
      expect(await liveRevision(a, f, s), isNull);
      expect(await removedRevision(a, f, s), 4);
      expect(doc(cloud, f, s)['revision'], 4);
    });

    test('a stale device cannot bring a removal back with an old revision',
        () async {
      final (a, b, cloud, f, s) = await twoDevices();
      await remove(a, f, s);
      await sync(a, cloud); // cloud: deleted, revision 2
      // B never saw the removal; its live revision-1 row is even marked
      // for upload.
      await dbOf(b).update('folder_songs', {'sync_dirty': 1});
      await sync(b, cloud);
      expect(await liveRevision(b, f, s), isNull); // removal (2) beat 1
      expect(doc(cloud, f, s)['deleted'], isTrue);
      expect(doc(cloud, f, s)['revision'], 2);

      // And the cloud itself refuses a stale or same-revision revive.
      for (final rev in [1, 2]) {
        await expectLater(
          cloud.commit(_uid, [
            CloudDocCodec.putMembership(f, s, '2024-01-01T00:00:00.000', 1,
                revision: rev),
          ]),
          throwsA(isA<CloudSyncBackendException>().having(
              (e) => e.kind, 'kind', CloudSyncErrorKind.permissionDenied)),
          reason: 'revision $rev',
        );
      }
      await cloud.commit(_uid, [
        CloudDocCodec.putMembership(f, s, '2024-01-01T00:00:00.000', 1,
            revision: 3),
      ]);
      expect(doc(cloud, f, s)['deleted'], isFalse);
    });

    test('same revision, live vs removed: the removal wins', () async {
      final (a, _, cloud, f, s) = await twoDevices();
      // Cloud: removed at revision 3; this device: live at revision 3.
      cloud.seed(_uid, CloudDocCodec.deleteMembership(f, s, 5, revision: 3));
      await dbOf(a).update('folder_songs', {'revision': 3, 'sync_dirty': 1});
      await sync(a, cloud);
      expect(await liveRevision(a, f, s), isNull);
      expect(await removedRevision(a, f, s), 3);
      expect(doc(cloud, f, s)['deleted'], isTrue);
    });

    test('concurrent: one device removes, the other removes and re-adds -> '
        'the re-add (higher revision) wins on both', () async {
      final (a, b, cloud, f, s) = await twoDevices();
      await remove(a, f, s); // 2
      await remove(b, f, s); // 2
      await add(b, f, s); // 3
      await sync(a, cloud);
      await sync(b, cloud);
      await sync(a, cloud);
      expect(await liveRevision(a, f, s), 3);
      expect(await liveRevision(b, f, s), 3);
      expect(doc(cloud, f, s)['deleted'], isFalse);
    });

    test('concurrent: one device re-adds, the other removes later -> the '
        'removal (higher revision) wins on both', () async {
      final (a, b, cloud, f, s) = await twoDevices();
      await remove(a, f, s); // 2
      await sync(a, cloud);
      await sync(b, cloud); // b: removed 2
      await add(a, f, s); // a: 3
      await add(b, f, s); // b: 3
      await remove(b, f, s); // b: 4
      await sync(a, cloud); // cloud live 3
      await sync(b, cloud); // b's removal 4 beats 3
      await sync(a, cloud);
      expect(await liveRevision(a, f, s), isNull);
      expect(await liveRevision(b, f, s), isNull);
      expect(doc(cloud, f, s)['revision'], 4);
      expect(doc(cloud, f, s)['deleted'], isTrue);
    });

    test('a deleted song never brings its membership back, whatever the '
        'revision', () async {
      final (a, b, cloud, f, s) = await twoDevices();
      final (_, songId) = await localIds(a, f, s);
      await a.songs.delete(songId);
      await sync(a, cloud);
      // B re-adds membership history (remove + re-add = revision 3).
      await remove(b, f, s);
      await add(b, f, s);
      await sync(b, cloud);
      expect(await liveRevision(b, f, s), isNull);
      expect(await dbOf(b).query('songs', where: 'sync_id = ?', whereArgs: [s]),
          isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('initial connection (merge)', () {
    test('a local re-add (higher revision) beats an older cloud removal',
        () async {
      final cloud = FakeCloudBackend();
      final a = await device();
      final song = await a.songs.create(Song(
          karaokeType: 'TJ',
          songNumber: '1',
          title: '곡',
          createdAt: day,
          updatedAt: day));
      final folder = await a.folders
          .create(Folder(name: '폴더', createdAt: day, updatedAt: day));
      await a.folders.addSong(folder.id!, song.id!);
      await a.folders.removeSong(folder.id!, song.id!);
      await a.folders.addSong(folder.id!, song.id!); // revision 3
      final f = folder.syncId!;
      final s = song.syncId!;
      cloud
        ..seed(_uid, CloudDocCodec.putSong(s, songData('곡', number: '1'), 1))
        ..seed(_uid, CloudDocCodec.putFolder(f, folderData('폴더'), 1))
        ..seed(_uid, CloudDocCodec.deleteMembership(f, s, 1, revision: 2));
      await InitialSyncEngine(store: a.syncStore, backend: cloud)
          .run(_uid, mode: InitialSyncMode.merge);
      expect(await liveRevision(a, f, s), 3);
      expect(doc(cloud, f, s)['deleted'], isFalse);
      expect(doc(cloud, f, s)['revision'], 3);
    });

    test('legacy (pre-revision) data keeps the old outcome: a removal beats '
        'a live membership', () async {
      final cloud = FakeCloudBackend();
      final a = await device();
      final song = await a.songs.create(Song(
          karaokeType: 'TJ',
          songNumber: '1',
          title: '곡',
          createdAt: day,
          updatedAt: day));
      final folder = await a.folders
          .create(Folder(name: '폴더', createdAt: day, updatedAt: day));
      await a.folders.addSong(folder.id!, song.id!); // live, revision 1
      final f = folder.syncId!;
      final s = song.syncId!;
      // A removal written before revisions existed (no revision field).
      cloud
        ..seed(_uid, CloudDocCodec.putSong(s, songData('곡', number: '1'), 1))
        ..seed(_uid, CloudDocCodec.putFolder(f, folderData('폴더'), 1))
        ..seed(
          _uid,
          CloudWrite(
            collection: CloudCollections.folderSongs,
            docId: '${f}_$s',
            entityKey: 'fs:${f}_$s',
            merge: false,
            data: {
              'folderSyncId': f,
              'songSyncId': s,
              'deleted': true,
              'deletedAtMs': 5,
              'updatedAtMs': 5,
            },
          ),
        );
      await InitialSyncEngine(store: a.syncStore, backend: cloud)
          .run(_uid, mode: InitialSyncMode.merge);
      expect(await liveRevision(a, f, s), isNull);
      expect(await removedRevision(a, f, s), 2);
    });
  });
}
