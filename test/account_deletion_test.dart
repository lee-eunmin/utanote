import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/account/account_deletion.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';
import 'package:utanote/storage/android/sqlite_sync_store.dart';
import 'package:utanote/storage/observed_local_storage.dart';
import 'package:utanote/sync/account_data_deletion.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/sync/manual_sync.dart';
import 'package:utanote/ui/backup_prompt.dart';

import 'support/sync_fakes.dart';

/// Phase B-5: "계정 및 클라우드 데이터 삭제". Real SQLite + the fake cloud.
/// Re-authentication → hard-delete the uid's cloud documents (batched,
/// resumable) → delete the Auth user → unbind locally. Local songs/folders
/// are never deleted; nothing of another uid is ever touched; no sync runs
/// while a deletion is in progress or unfinished.

const _uid = 'uid-alice';
const _alice = AccountUser(uid: _uid, email: 'alice@example.com');
const _bobUid = 'uid-bob';
const _debounce = Duration(milliseconds: 60);

/// Like production's binding source: uid, email hint, explicit release.
class _Bound
    implements BoundAccountSource, BoundAccountEmailSource, PreviousBindingRelease {
  final SqliteLocalStorage storage;
  _Bound(this.storage);

  SqliteLocalSyncStore get _sync => storage.syncStore as SqliteLocalSyncStore;

  int releases = 0;

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();

  @override
  Future<String?> readBoundAccountEmailHint() =>
      _sync.readBoundAccountEmailHint();

  @override
  Future<void> releasePreviousBinding({required String expectedBoundUid}) {
    releases++;
    return _sync.releasePreviousBinding(expectedBoundUid: expectedBoundUid);
  }
}

class _MemoryPrefs implements BackupPromptPrefs {
  int? value;

  @override
  Future<int?> snoozedAtMs() async => value;

  @override
  Future<void> setSnoozedAtMs(int utcMs) async => value = utcMs;
}

/// Everything one device needs, wired like `startAccount` does.
class _World {
  final SqliteLocalStorage storage;
  final FakeCloudBackend cloud;
  final FakeAuth auth;
  final AccountController account;
  final CloudSyncController sync;
  final AccountDeletionController deletion;
  final FakeDeletionAuth deletionAuth;
  final FakeCloudEraser eraser;
  final ObservedLocalStorage ui;
  int completedCalls = 0;

  _World({
    required this.storage,
    required this.cloud,
    required this.auth,
    required this.account,
    required this.sync,
    required this.deletion,
    required this.deletionAuth,
    required this.eraser,
    required this.ui,
  });

  SqliteLocalSyncStore get store => storage.syncStore as SqliteLocalSyncStore;

  int aliceDocs() =>
      cloud.docCount(_uid, CloudCollections.songs) +
      cloud.docCount(_uid, CloudCollections.folders) +
      cloud.docCount(_uid, CloudCollections.folderSongs);

  int bobDocs() =>
      cloud.docCount(_bobUid, CloudCollections.songs) +
      cloud.docCount(_bobUid, CloudCollections.folders) +
      cloud.docCount(_bobUid, CloudCollections.folderSongs);

  Future<String?> meta(String key) =>
      readSyncMeta(storage.databaseForTesting, key);
}

void main() {
  late Directory root;
  var counter = 0;
  final opened = <SqliteLocalStorage>[];
  final disposers = <void Function()>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('utanote_account_delete_');
  });

  tearDown(() async {
    for (final d in disposers.reversed) {
      d();
    }
    disposers.clear();
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
  });

  final day = DateTime.parse('2024-01-01T00:00:00.000');
  Song song(String title, {String number = '1', bool favorite = false}) =>
      Song(
        karaokeType: 'TJ',
        songNumber: number,
        title: title,
        favorite: favorite,
        keyType: '남키',
        keyOffset: 2,
        difficulty: '어려움',
        practiceStatus: '연습 중',
        searchAliases: const ['별칭'],
        createdAt: day,
        updatedAt: day,
      );
  Folder folder(String name) =>
      Folder(name: name, createdAt: day, updatedAt: day);

  Future<SqliteLocalStorage> open(String dir) async {
    await Directory(dir).create(recursive: true);
    await databaseFactory.setDatabasesPath(dir);
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  /// A device with songs, folders, memberships, a deleted song and a
  /// removed membership, connected to alice; plus bob's data in the cloud.
  Future<(String, FakeCloudBackend)> boundDevice({int extraSongs = 0}) async {
    final dir = p.join(root.path, 'd${counter++}');
    final cloud = FakeCloudBackend();
    final s = await open(dir);
    final a = await s.songs.create(song('곡 A', number: '101', favorite: true));
    final b = await s.songs.create(song('곡 B', number: '102'));
    final c = await s.songs.create(song('곡 C', number: '103'));
    for (var i = 0; i < extraSongs; i++) {
      await s.songs.create(song('추가 $i', number: '${200 + i}'));
    }
    final f1 = await s.folders.create(folder('애창곡'));
    final f2 = await s.folders.create(folder('빈 폴더'));
    await s.folders.addSong(f1.id!, a.id!);
    await s.folders.addSong(f1.id!, b.id!);
    await s.folders.removeSong(f1.id!, b.id!); // removal tombstone
    await s.songs.delete(c.id!); // song tombstone
    expect(f2.id, isNotNull);
    await InitialSyncEngine(store: s.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.upload, email: _alice.email);
    await s.close();
    opened.remove(s);
    cloud.seed(
      _bobUid,
      CloudDocCodec.putSong('bob-song-1', songData('밥의 곡'), 1),
    );
    cloud.seed(
      _bobUid,
      CloudDocCodec.putFolder('bob-folder-1', folderData('밥 폴더'), 1),
    );
    return (dir, cloud);
  }

  /// App start on [dir] with [cloud], signed in as alice (restored
  /// session), automatic sync on.
  Future<_World> start(
    String dir,
    FakeCloudBackend cloud, {
    AccountUser user = _alice,
  }) async {
    final s = await open(dir);
    final auth = FakeAuth(user);
    final account = AccountController(gateway: auth, boundAccount: _Bound(s));
    final sync = CloudSyncController(
      engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
      manual: ManualSyncEngine(store: s.syncStore, backend: cloud),
      account: account,
      autoSync: const AutoSyncConfig(debounce: _debounce),
    );
    account.cloudSync = sync;
    final deletionAuth = FakeDeletionAuth(user);
    final eraser = FakeCloudEraser(cloud, batchSize: 3);
    late _World w;
    final deletion = AccountDeletionController(
      account: account,
      auth: deletionAuth,
      store: s.syncStore as AccountDeletionStore,
      eraser: eraser,
      onCompleted: () async => w.completedCalls++,
    );
    account.deletion = deletion;
    deletionAuth.onDeleted = () => auth.users.add(null);
    deletionAuth.cloudDocCount = () =>
        cloud.docCount(_uid, CloudCollections.songs) +
        cloud.docCount(_uid, CloudCollections.folders) +
        cloud.docCount(_uid, CloudCollections.folderSongs);
    final ui = ObservedLocalStorage(s, onUserDataChanged: sync.onLocalDataChanged);
    w = _World(
      storage: s,
      cloud: cloud,
      auth: auth,
      account: account,
      sync: sync,
      deletion: deletion,
      deletionAuth: deletionAuth,
      eraser: eraser,
      ui: ui,
    );
    disposers.add(() {
      deletion.dispose();
      sync.dispose();
      account.dispose();
    });
    await deletion.load();
    await account.start();
    auth.users.add(user);
    for (var i = 0; i < 50 && account.phase == AccountPhase.signedOut; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _idle(w);
    return w;
  }

  /// Rows without `sync_dirty` (which deletion is allowed to change).
  Future<Map<String, List<Map<String, Object?>>>> data(SqliteLocalStorage s) async {
    final t = await dumpUserTables(s.databaseForTesting);
    return {
      for (final e in t.entries)
        e.key: [
          for (final r in e.value) Map.of(r)..remove('sync_dirty'),
        ],
    };
  }

  Future<void> expectAllDirty(SqliteLocalStorage s) async {
    for (final table in ['songs', 'folders', 'folder_songs', 'sync_tombstones']) {
      final clean = await s.databaseForTesting
          .query(table, where: 'sync_dirty != ${SyncDirty.dirty}');
      expect(clean, isEmpty, reason: '$table rows must need upload');
    }
  }

  // -------------------------------------------------------------------------
  group('successful deletion', () {
    test('cloud data hard-deleted, then Auth user, then local unbind', () async {
      final (dir, cloud) = await boundDevice(extraSongs: 4);
      final w = await start(dir, cloud);
      expect(w.sync.phase, CloudSyncPhase.connected);
      final before = await data(w.storage);
      final beforeMeta = await dumpSyncMeta(w.storage.databaseForTesting);
      final aliceBefore = w.aliceDocs();
      expect(aliceBefore, greaterThan(0));

      await w.deletion.deleteAccount();

      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.deletion.message, isNull);
      // Re-authenticated once; Auth deleted only after the cloud was empty.
      expect(w.deletionAuth.reauthCalls, 1);
      expect(w.deletionAuth.deleteCalls, 1);
      expect(w.deletionAuth.cloudDocsAtAuthDelete, 0);
      expect(w.deletionAuth.googleEnded, 1);
      // Cloud: alice gone for good (no tombstone documents), bob untouched.
      expect(w.aliceDocs(), 0);
      expect(w.bobDocs(), 2);
      expect(w.eraser.uidsTouched, [_uid]);
      // Batches of at most 3 (the configured size).
      expect(w.eraser.batchSizes, isNotEmpty);
      expect(w.eraser.batchSizes.every((n) => n <= 3), isTrue);
      expect(w.eraser.batchSizes.reduce((a, b) => a + b), aliceBefore);

      // Local data: every row and field kept (incl. sync ids, memo,
      // tombstones, revisions); only "needs upload" changed.
      expect(await data(w.storage), before);
      await expectAllDirty(w.storage);
      expect((await w.storage.songs.getAll()).length, 6);
      expect((await w.storage.folders.getAll()).length, 2);

      // Binding and sync bookkeeping removed.
      // Spelled out (not taken from SyncMetaKeys lists) on purpose.
      for (final key in const [
        'account_uid',
        'account_email_hint',
        'last_successful_sync_at_ms',
        'initial_sync_state',
        'initial_sync_mode',
        'initial_sync_uid',
        'initial_sync_error',
        'pull_cursor_songs_ms',
        'pull_cursor_folders_ms',
        'pull_cursor_folder_songs_ms',
        'account_deletion_state',
        'account_deletion_uid',
        'account_deletion_started_at_ms',
        'account_deletion_deleted_docs',
      ]) {
        expect(await w.meta(key), isNull, reason: key);
      }
      // Kept: the safety-backup records (the backup files stay too).
      expect(await w.meta(SyncMetaKeys.preCloudSyncBackupFile), isNotNull);
      // Set before deletion, so the check above really proves removal.
      expect(beforeMeta['pull_cursor_folder_songs_ms'], isNotNull);
      expect(beforeMeta['account_email_hint'], isNotNull);
      expect(beforeMeta['last_successful_sync_at_ms'], isNotNull);
      expect(await w.storage.readBoundAccountUid(), isNull);
      expect(await w.store.readPendingAccountDeletion(), isNull);

      // Signed out; sync idle and allowed again (nothing to run).
      await _idle(w);
      expect(w.account.phase, AccountPhase.signedOut);
      expect(w.sync.phase, CloudSyncPhase.unavailable);
      expect(w.sync.suspended, isFalse);
      expect(w.sync.lastSyncAtMs, isNull);
      expect(w.deletion.completedThisLaunch, isTrue);
      expect(w.completedCalls, 1);
    });

    test('after deletion no automatic sync runs, even after edits', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.deletion.deleteAccount();
      final runs = w.sync.syncRuns;
      final commits = cloud.commitCount;
      await w.ui.songs.create(song('삭제 후 추가'));
      w.sync.onAppResumed();
      await w.sync.syncNow();
      await _idle(w);
      expect(w.sync.syncRuns, runs);
      expect(cloud.commitCount, commits);
      expect(w.aliceDocs(), 0);
    });

    test('a new account can back the device up again (first upload)', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.deletion.deleteAccount();
      final localSongs = await w.storage.songs.getAll();

      const carol = AccountUser(uid: 'uid-carol', email: 'carol@example.com');
      w.auth.next = carol;
      await w.account.signIn();
      expect(w.account.phase, AccountPhase.signedIn);
      expect(w.account.linkStatus, AccountLinkStatus.unlinked);
      expect(w.sync.phase, CloudSyncPhase.notConnected);

      await w.sync.startSetup();
      expect(w.sync.phase, CloudSyncPhase.connected);
      expect(await w.storage.readBoundAccountUid(), 'uid-carol');
      for (final s in localSongs) {
        final doc = cloud.docOf('uid-carol', CloudCollections.songs, s.syncId!);
        expect(doc, isNotNull, reason: s.title);
        expect(doc!['deleted'], isFalse);
      }
      expect(cloud.docCount('uid-carol', CloudCollections.folders), 2);
      expect(w.aliceDocs(), 0); // the deleted account stays empty
    });

    test('same Google account re-created (new uid): this device backs up again',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.deletion.deleteAccount();
      // Firebase gives the re-created account a new uid. This device was
      // unbound by the deletion, so it is simply "not connected".
      const reborn = AccountUser(uid: 'uid-alice-2', email: 'Alice@Example.com');
      w.auth.next = reborn;
      await w.account.signIn();
      expect(w.account.linkStatus, AccountLinkStatus.unlinked);
      await w.sync.startSetup();
      expect(w.sync.phase, CloudSyncPhase.connected);
      // 2 live songs + the deletion marker of the locally deleted song.
      expect(cloud.docCount('uid-alice-2', CloudCollections.songs), 3);
      // The deleted uid stays blocked and empty.
      expect(cloud.blockedUids, contains(_uid));
      expect(w.aliceDocs(), 0);
    });
  });

  // -------------------------------------------------------------------------
  group('re-authentication', () {
    Future<void> expectNothingDeleted(_World w, int docs) async {
      expect(w.aliceDocs(), docs);
      expect(w.eraser.calls, 0);
      expect(w.deletionAuth.deleteCalls, 0);
      expect(await w.store.readPendingAccountDeletion(), isNull);
      expect(await w.storage.readBoundAccountUid(), _uid);
      expect(w.account.phase, AccountPhase.signedIn);
      expect(w.sync.suspended, isFalse); // sync resumes
      expect(w.sync.phase, CloudSyncPhase.connected);
    }

    test('cancelled: nothing is deleted, sync resumes', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.deletionAuth.reauthError = const AccountSignInCancelled();
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.idle);
      expect(w.deletion.message, isNull);
      await expectNothingDeleted(w, docs);
    });

    test('failure: nothing is deleted, message shown', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.deletionAuth.reauthError =
          const AccountSignInFailure('네트워크 연결을 확인한 뒤 다시 시도해 주세요.');
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('아무것도 삭제하지 않았어요'));
      await expectNothingDeleted(w, docs);
    });

    test('a different Google account (uid mismatch) stops immediately', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.deletionAuth.reauthUser = const AccountUser(uid: _bobUid);
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('지금 로그인한 계정과 달라요'));
      await expectNothingDeleted(w, docs);
      expect(w.bobDocs(), 2);
    });

    test('Firebase "user-mismatch" stops immediately', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.deletionAuth.reauthError = const AccountReauthMismatch();
      await w.deletion.deleteAccount();
      expect(w.deletion.message, contains('지금 로그인한 계정과 달라요'));
      await expectNothingDeleted(w, docs);
    });

    test('Firebase current user differs from the app user: stops', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.deletionAuth.currentUid = _bobUid;
      await w.deletion.deleteAccount();
      await expectNothingDeleted(w, docs);
    });

    test('signed out: deleteAccount does nothing', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.account.signOut();
      await w.deletion.deleteAccount();
      expect(w.deletionAuth.reauthCalls, 0);
      expect(w.eraser.calls, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('failures keep state and can be retried', () {
    test('first batch fails: nothing deleted, sync blocked, retry completes',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      final before = await data(w.storage);
      w.eraser.failOnBatch = 1;

      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('네트워크'));
      expect(w.aliceDocs(), docs);
      expect(w.deletionAuth.deleteCalls, 0);
      final pending = await w.store.readPendingAccountDeletion();
      expect(pending?.uid, _uid);
      expect(pending?.stage, AccountDeletionStage.cloudDeleting);
      expect(await w.storage.readBoundAccountUid(), _uid); // still bound
      expect(w.account.phase, AccountPhase.signedIn);
      expect(w.sync.suspended, isTrue);
      expect(await data(w.storage), before);

      w.eraser.failOnBatch = null;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
      expect(w.deletionAuth.reauthCalls, 2); // re-authenticated again
      expect(await w.storage.readBoundAccountUid(), isNull);
      expect(await data(w.storage), before);
    });

    test('fails after some batches: progress kept, retry deletes the rest',
        () async {
      final (dir, cloud) = await boundDevice(extraSongs: 6);
      final w = await start(dir, cloud);
      w.eraser.failOnBatch = 3;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('중간에 멈췄어요'));
      final pending = await w.store.readPendingAccountDeletion();
      expect(pending?.stage, AccountDeletionStage.cloudDeleting);
      // Two batches committed before the failure; their count is kept.
      expect(w.eraser.batchSizes.length, 2);
      expect(
        pending?.deletedDocs,
        w.eraser.batchSizes.reduce((a, b) => a + b),
      );
      expect(pending!.deletedDocs, greaterThan(0));
      expect(w.aliceDocs(), greaterThan(0));
      expect(w.deletionAuth.deleteCalls, 0);

      w.eraser.failOnBatch = null;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
      expect(w.bobDocs(), 2);
    });

    test('Auth deletion fails: cloud already deleted (said so), retry works',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      w.deletionAuth.deleteError = const AccountDeletionAuthException(
        AccountDeletionAuthErrorKind.network,
        'offline',
      );
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('클라우드 백업은 삭제됐지만'));
      expect(w.aliceDocs(), 0);
      expect(
        (await w.store.readPendingAccountDeletion())?.stage,
        AccountDeletionStage.cloudDeleted,
      );
      expect(w.account.phase, AccountPhase.signedIn);
      expect(await w.storage.readBoundAccountUid(), _uid);
      expect(w.sync.suspended, isTrue);

      w.deletionAuth.deleteError = null;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.deletionAuth.deleteCalls, 2);
      expect(await w.storage.readBoundAccountUid(), isNull);
      expect(w.account.phase, AccountPhase.signedOut);
    });

    test('Auth deletion needs a recent login: asks to verify again', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      w.deletionAuth.deleteError = const AccountDeletionAuthException(
        AccountDeletionAuthErrorKind.requiresRecentLogin,
        'requires-recent-login',
      );
      await w.deletion.deleteAccount();
      expect(w.deletion.message, contains('다시 본인 확인이 필요해요'));
    });

    test('unexpected eraser error: reported, nothing crashes', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      w.eraser.failOnBatch = 1;
      w.eraser.error = StateError('boom');
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect((await w.storage.songs.getAll()).length, 2);
    });
  });

  // -------------------------------------------------------------------------
  group('app closed in the middle', () {
    Future<void> restart(_World w) async {
      w.deletion.dispose();
      w.sync.dispose();
      w.account.dispose();
      disposers.clear();
      await w.storage.close();
      opened.remove(w.storage);
    }

    test('after a partial cloud delete: sync stays off, resume finishes',
        () async {
      final (dir, cloud) = await boundDevice(extraSongs: 6);
      var w = await start(dir, cloud);
      final before = await data(w.storage);
      w.eraser.failOnBatch = 2;
      await w.deletion.deleteAccount();
      final left = w.aliceDocs();
      expect(left, greaterThan(0));
      await restart(w);

      // Next launch: the restored session on the still-bound device must
      // not sync (that would re-upload into the cloud being deleted).
      final commits = cloud.commitCount;
      w = await start(dir, cloud);
      expect(w.deletion.pending?.uid, _uid);
      expect(w.sync.suspended, isTrue);
      await w.ui.songs.create(song('재시작 후 추가'));
      w.sync.onAppResumed();
      await w.sync.syncNow();
      await _idle(w);
      expect(w.sync.syncRuns, 0);
      expect(cloud.commitCount, commits);
      expect(w.aliceDocs(), left);

      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
      final after = await data(w.storage);
      expect(after['folders'], before['folders']);
      expect(after['folder_songs'], before['folder_songs']);
      expect(after['songs']!.length, before['songs']!.length + 1);
    });

    test('after the Auth user was deleted: next start finishes locally',
        () async {
      final (dir, cloud) = await boundDevice();
      var w = await start(dir, cloud);
      final before = await data(w.storage);
      // Simulate a crash right after Auth deletion (stage recorded, local
      // cleanup not done).
      await w.store.markAccountDeletionStarted(_uid);
      await w.store.recordAccountDeletionProgress(
        _uid,
        stage: AccountDeletionStage.authDeleted,
      );
      await restart(w);

      w = await start(dir, cloud);
      expect(w.deletion.pending, isNull);
      expect(await w.storage.readBoundAccountUid(), isNull);
      expect(await w.store.readPendingAccountDeletion(), isNull);
      expect(await data(w.storage), before);
      await expectAllDirty(w.storage);
      expect(w.sync.suspended, isFalse);
      expect(w.deletion.completedThisLaunch, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('sync is stopped during deletion', () {
    test('no automatic or manual sync while re-authenticating', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final runs = w.sync.syncRuns;
      final commits = cloud.commitCount;
      w.deletionAuth.reauthGate = Completer<void>();
      final running = w.deletion.deleteAccount();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(w.deletion.status, AccountDeletionStatus.reauthenticating);
      expect(w.sync.suspended, isTrue);

      await w.ui.songs.create(song('삭제 중 추가'));
      w.sync.onAppResumed();
      await w.sync.syncNow();
      await w.sync.startSetup();
      await Future<void>.delayed(_debounce * 3);
      expect(w.sync.syncRuns, runs);
      expect(cloud.commitCount, commits);

      w.deletionAuth.reauthGate!.complete();
      await running;
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
      expect(cloud.commitCount, commits);
    });

    test('a debounced sync scheduled before deletion never fires', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final runs = w.sync.syncRuns;
      await w.ui.songs.create(song('직전 수정')); // debounce timer armed
      await w.deletion.deleteAccount();
      await Future<void>.delayed(_debounce * 3);
      expect(w.sync.syncRuns, runs);
      expect(w.aliceDocs(), 0);
    });

    test('a sync already running finishes before anything is deleted', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      cloud.fetchGate = Completer<void>();
      unawaited(w.sync.syncNow());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(w.sync.busy, isTrue);

      final deleting = w.deletion.deleteAccount();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(w.deletionAuth.reauthCalls, 0); // waiting for the sync
      expect(w.eraser.calls, 0);

      cloud.fetchGate!.complete();
      cloud.fetchGate = null;
      await deleting;
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
    });

    test('engines refuse to run while a deletion is pending', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.store.markAccountDeletionStarted(_uid);
      final commits = cloud.commitCount;
      await expectLater(
        ManualSyncEngine(store: w.store, backend: cloud).syncNow(_uid),
        throwsA(isA<ManualSyncFailure>().having(
          (f) => f.kind,
          'kind',
          ManualSyncFailureKind.accountDeletionPending,
        )),
      );
      await expectLater(
        InitialSyncEngine(store: w.store, backend: cloud).assess(_uid),
        throwsA(isA<InitialSyncFailure>()),
      );
      await expectLater(
        w.store.applyIncremental(
          uid: _uid,
          apply: (_, _) async => const IncrementalApplyOutcome(),
        ),
        throwsA(isA<SyncBlockedByAccountDeletion>()),
      );
      await expectLater(
        w.store.markInitialSyncStarted(_uid, 'upload'),
        throwsA(isA<SyncBlockedByAccountDeletion>()),
      );
      expect(cloud.commitCount, commits);
    });
  });

  // -------------------------------------------------------------------------
  group('local store', () {
    test('cannot start a deletion for another account than the bound one',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await expectLater(
        w.store.markAccountDeletionStarted(_bobUid),
        throwsA(isA<StateError>()),
      );
      expect(await w.store.readPendingAccountDeletion(), isNull);
    });

    test('finishing requires a pending deletion of the same account', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await expectLater(
        w.store.finishAccountDeletion(_uid),
        throwsA(isA<StateError>()),
      );
      await w.store.markAccountDeletionStarted(_uid);
      await expectLater(
        w.store.finishAccountDeletion(_bobUid),
        throwsA(isA<StateError>()),
      );
      expect(await w.storage.readBoundAccountUid(), _uid);
    });

    test('stage only moves forward', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.store.markAccountDeletionStarted(_uid);
      await w.store.recordAccountDeletionProgress(
        _uid,
        stage: AccountDeletionStage.cloudDeleted,
      );
      await w.store.recordAccountDeletionProgress(
        _uid,
        stage: AccountDeletionStage.cloudDeleting,
      );
      await w.store.markAccountDeletionStarted(_uid); // resume keeps stage
      expect(
        (await w.store.readPendingAccountDeletion())?.stage,
        AccountDeletionStage.cloudDeleted,
      );
    });

    test('an unbound, signed-in device can delete its account too', () async {
      final dir = p.join(root.path, 'd${counter++}');
      final cloud = FakeCloudBackend();
      // Another device uploaded alice's data; this one never connected.
      cloud.seed(_uid, CloudDocCodec.putSong('alice-remote', songData('원격'), 1));
      final s = await open(dir);
      await s.songs.create(song('이 기기 곡'));
      await s.close();
      opened.remove(s);
      final w = await start(dir, cloud);
      expect(w.sync.phase, CloudSyncPhase.notConnected);
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
      expect((await w.storage.songs.getAll()).single.title, '이 기기 곡');
    });
  });

  // -------------------------------------------------------------------------
  group('backup prompt and sign-out', () {
    test('backup prompt is not shown right after deleting the account',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      await w.deletion.deleteAccount();
      final prefs = _MemoryPrefs(); // not snoozed
      final action = await evaluateBackupPrompt(
        account: w.account,
        storage: w.storage,
        prefs: prefs,
        nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      expect(action, isNull);
      expect(w.completedCalls, 1); // main.dart snoozes the prompt here
    });

    test('backup prompt is not shown while a deletion is unfinished', () async {
      final dir = p.join(root.path, 'd${counter++}');
      final cloud = FakeCloudBackend();
      final s = await open(dir);
      await s.songs.create(song('곡'));
      await (s.syncStore as SqliteLocalSyncStore)
          .markAccountDeletionStarted(_uid);
      await s.close();
      opened.remove(s);
      final w = await start(dir, cloud);
      await w.account.signOut();
      final action = await evaluateBackupPrompt(
        account: w.account,
        storage: w.storage,
        prefs: _MemoryPrefs(),
        nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      expect(w.deletion.pending, isNotNull);
      expect(action, isNull);
    });

    test('sign-out is unchanged: binding, data and cloud all kept', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      final before = await dumpUserTables(w.storage.databaseForTesting);
      await w.account.signOut();
      expect(w.account.phase, AccountPhase.signedOut);
      expect(await w.storage.readBoundAccountUid(), _uid);
      expect(await w.meta(SyncMetaKeys.lastSuccessfulSyncAtMs), isNotNull);
      expect(await dumpUserTables(w.storage.databaseForTesting), before);
      expect(w.aliceDocs(), docs);
      expect(w.eraser.calls, 0);
      expect(w.deletionAuth.deleteCalls, 0);
      expect(w.deletion.completedThisLaunch, isFalse);
    });
  });
  // -------------------------------------------------------------------------
  // Phase B-5.1: deletion block
  // -------------------------------------------------------------------------

  /// A second device of alice: restores alice's cloud and starts the app.
  Future<_World> secondDevice(FakeCloudBackend cloud) async {
    final dir = p.join(root.path, 'd${counter++}');
    final s = await open(dir);
    await InitialSyncEngine(store: s.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.restore, email: _alice.email);
    await s.close();
    opened.remove(s);
    return start(dir, cloud);
  }

  group('deletion block', () {
    test('cloud documents are deleted only after the block is confirmed',
        () async {
      final (dir, cloud) = await boundDevice(extraSongs: 4);
      final w = await start(dir, cloud);
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.eraser.events.first, 'block');
      expect(w.eraser.events.where((e) => e == 'block').length, 1);
      expect(w.eraser.events.skip(1).every((e) => e == 'batch'), isTrue);
      // The block stays after success (only the uid; no user content).
      expect(cloud.blockedUids, {_uid});
      expect(w.bobDocs(), 2);
    });

    test('block creation fails: zero user documents deleted, sync resumes',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      final before = await data(w.storage);
      w.eraser.blockError = const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'offline',
      );
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('아무것도 삭제하지 않았어요'));
      expect(w.aliceDocs(), docs);
      expect(w.eraser.calls, 0); // hard delete never started
      expect(w.deletionAuth.deleteCalls, 0);
      expect(cloud.blockedUids, isEmpty);
      // Confirmed "no block": the local record is dropped, sync resumes.
      expect(await w.store.readPendingAccountDeletion(), isNull);
      expect(w.deletion.pending, isNull);
      expect(w.sync.suspended, isFalse);
      expect(await w.storage.readBoundAccountUid(), _uid);
      expect(await data(w.storage), before);
    });

    test(
        'block created but the call failed: stays pending, nothing deleted, '
        'retry completes', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.eraser.blockCreatedThenError = true;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.failed);
      expect(w.deletion.message, contains('계정 삭제 계속하기'));
      expect(w.aliceDocs(), docs);
      expect(w.eraser.calls, 0);
      expect(
        (await w.store.readPendingAccountDeletion())?.stage,
        AccountDeletionStage.blocking,
      );
      expect(w.sync.suspended, isTrue); // the uid is blocked in the cloud
      w.eraser.blockCreatedThenError = false;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.aliceDocs(), 0);
    });

    test('block state unknown (check fails too): stays pending, nothing deleted',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final docs = w.aliceDocs();
      w.eraser.blockError = const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'offline',
      );
      w.eraser.blockCheckError = const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'offline',
      );
      await w.deletion.deleteAccount();
      expect(w.aliceDocs(), docs);
      expect(w.eraser.calls, 0);
      expect(await w.store.readPendingAccountDeletion(), isNotNull);
      expect(w.sync.suspended, isTrue);
    });

    test('a stale device can neither upload nor update after the block',
        () async {
      final (dir, cloud) = await boundDevice();
      final a = await start(dir, cloud);
      final b = await secondDevice(cloud);
      expect(b.sync.phase, CloudSyncPhase.connected);
      final bSongs = await b.storage.songs.getAll();

      await a.deletion.deleteAccount();
      expect(a.aliceDocs(), 0);

      // Device B still has a (stale) session for the deleted uid.
      await b.ui.songs.create(song('B 새 곡'));
      await b.ui.songs.update(bSongs.first.copyWith(title: 'B 수정'));
      await b.sync.syncNow();
      await _idle(b);
      expect(b.sync.manualStatus, ManualSyncStatus.failed);
      expect(a.aliceDocs(), 0); // nothing re-created
      // B's local data is intact and still marked for upload.
      final titles = (await b.storage.songs.getAll()).map((s) => s.title);
      expect(titles, containsAll(['B 새 곡', 'B 수정']));
      final dirty = await b.storage.databaseForTesting
          .query('songs', where: 'sync_dirty = 1');
      expect(dirty.length, greaterThanOrEqualTo(2));
    });

    test(
        'partial delete then failure: block kept, stale writes refused, '
        'retry finishes', () async {
      final (dir, cloud) = await boundDevice(extraSongs: 6);
      final a = await start(dir, cloud);
      final b = await secondDevice(cloud);
      a.eraser.failOnBatch = 2;
      await a.deletion.deleteAccount();
      expect(a.deletion.status, AccountDeletionStatus.failed);
      final left = a.aliceDocs();
      expect(left, greaterThan(0));
      expect(cloud.blockedUids, {_uid});

      await b.ui.songs.create(song('삭제 중 B 업로드'));
      await b.sync.syncNow();
      await _idle(b);
      expect(a.aliceDocs(), left); // refused

      a.eraser.failOnBatch = null;
      await a.deletion.deleteAccount();
      expect(a.deletion.status, AccountDeletionStatus.completed);
      expect(a.aliceDocs(), 0);
      expect(cloud.blockedUids, {_uid});
    });

    test('Auth deletion fails: block kept, retry deletes the Auth user',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      w.deletionAuth.deleteError = const AccountDeletionAuthException(
        AccountDeletionAuthErrorKind.requiresRecentLogin,
        'requires-recent-login',
      );
      await w.deletion.deleteAccount();
      expect(w.deletion.message, contains('클라우드 백업은 삭제됐지만'));
      expect(cloud.blockedUids, {_uid});
      w.deletionAuth.deleteError = null;
      await w.deletion.deleteAccount();
      expect(w.deletion.status, AccountDeletionStatus.completed);
      expect(w.deletionAuth.reauthCalls, 2);
      expect(w.eraser.blockCalls, 2); // re-confirmed, never overwritten
      expect(cloud.blockedUids, {_uid});
      await expectAllDirty(w.storage);
      expect((await w.storage.songs.getAll()).length, 2);
    });
  });

  // -------------------------------------------------------------------------
  // Phase B-5.1: stale binding on another device (same Google account)
  // -------------------------------------------------------------------------
  group('stale binding, same Google account (new uid)', () {
    const reborn = AccountUser(uid: 'uid-alice-2', email: 'ALICE@example.com');

    test('offers the explicit release; nothing changes before approval',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud, user: reborn);
      final before = await data(w.storage);
      expect(w.account.phase, AccountPhase.signedIn);
      expect(w.account.linkStatus, AccountLinkStatus.previousAccountSameEmail);
      expect(w.account.canSync, isFalse);
      expect(w.sync.phase, CloudSyncPhase.unavailable);
      final commits = cloud.commitCount;
      await w.sync.syncNow();
      await w.sync.startSetup();
      await _idle(w);
      expect(cloud.commitCount, commits); // no automatic upload/merge
      expect(cloud.docCount(reborn.uid, CloudCollections.songs), 0);
      // No automatic reset: binding and data untouched.
      expect(await w.storage.readBoundAccountUid(), _uid);
      expect(await w.meta(SyncMetaKeys.lastSuccessfulSyncAtMs), isNotNull);
      expect(await data(w.storage), before);
      expect(
        await w.storage.databaseForTesting
            .query('songs', where: 'sync_dirty = 1'),
        isEmpty,
      );
    });

    test(
        'after approval: only binding meta cleared, data kept, all dirty; '
        'new uid can do the first connection', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud, user: reborn);
      final before = await data(w.storage);
      final commits = cloud.commitCount;

      expect(await w.account.releasePreviousCloudBinding(), isTrue);

      expect(await data(w.storage), before); // songs/folders/ids kept
      await expectAllDirty(w.storage);
      for (final key in const [
        'account_uid',
        'account_email_hint',
        'last_successful_sync_at_ms',
        'initial_sync_state',
        'initial_sync_mode',
        'initial_sync_uid',
        'pull_cursor_songs_ms',
        'pull_cursor_folders_ms',
        'pull_cursor_folder_songs_ms',
        'account_deletion_state',
      ]) {
        expect(await w.meta(key), isNull, reason: key);
      }
      expect(await w.meta(SyncMetaKeys.preCloudSyncBackupFile), isNotNull);
      expect(w.account.linkStatus, AccountLinkStatus.unlinked);
      expect(w.sync.phase, CloudSyncPhase.notConnected);
      await _idle(w);
      expect(cloud.commitCount, commits); // still nothing uploaded

      await w.sync.startSetup(); // the user starts the B-3 flow
      expect(w.sync.phase, CloudSyncPhase.connected);
      expect(await w.storage.readBoundAccountUid(), reborn.uid);
      expect(
        cloud.docCount(reborn.uid, CloudCollections.songs),
        greaterThan(0),
      );
    });

    test('release also clears a stale deletion record of the old uid',
        () async {
      final (dir, cloud) = await boundDevice();
      final s = await open(dir);
      await (s.syncStore as SqliteLocalSyncStore)
          .markAccountDeletionStarted(_uid);
      await s.close();
      opened.remove(s);
      final w = await start(dir, cloud, user: reborn);
      expect(w.sync.suspended, isTrue);
      expect(await w.account.releasePreviousCloudBinding(), isTrue);
      expect(w.deletion.pending, isNull);
      expect(w.sync.suspended, isFalse);
      expect(w.sync.phase, CloudSyncPhase.notConnected);
    });

    test('different email: blocked as before, no release offered', () async {
      final (dir, cloud) = await boundDevice();
      const other = AccountUser(uid: 'uid-zed', email: 'zed@example.com');
      final w = await start(dir, cloud, user: other);
      expect(w.account.phase, AccountPhase.signedOut);
      expect(
        w.account.message,
        contains('다른 Google 계정의 백업에 연결되어 있어요'),
      );
      expect(await w.account.releasePreviousCloudBinding(), isFalse);
      expect(await w.storage.readBoundAccountUid(), _uid);
    });

    test('binding without an email hint: blocked (never guessed)', () async {
      final (dir, cloud) = await boundDevice();
      final s = await open(dir);
      await s.databaseForTesting.delete(
        'sync_meta',
        where: 'key = ?',
        whereArgs: [SyncMetaKeys.accountEmailHint],
      );
      await s.close();
      opened.remove(s);
      final w = await start(dir, cloud, user: reborn);
      expect(w.account.phase, AccountPhase.signedOut);
      expect(await w.storage.readBoundAccountUid(), _uid);
    });

    test('release is refused outside that state (no change)', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud); // same uid: normal bound device
      expect(await w.account.releasePreviousCloudBinding(), isFalse);
      expect(await w.storage.readBoundAccountUid(), _uid);
      await expectLater(
        w.store.releasePreviousBinding(expectedBoundUid: 'uid-other'),
        throwsA(isA<StateError>()),
      );
      expect(await w.storage.readBoundAccountUid(), _uid);
    });

    test('email comparison ignores case and spaces only', () {
      expect(
        sameAccountEmail('Alice@Example.com', ' alice@example.com '),
        isTrue,
      );
      expect(
        sameAccountEmail('alice@example.com', 'alice2@example.com'),
        isFalse,
      );
      expect(sameAccountEmail(null, 'a@b.c'), isFalse);
      expect(sameAccountEmail('', ''), isFalse);
    });
  });
  // -------------------------------------------------------------------------
  // Sync result lifecycle: a failure belongs to its account/binding
  // -------------------------------------------------------------------------
  group('sync error state follows the account/binding', () {
    const reborn = AccountUser(uid: 'uid-alice-2', email: 'alice@example.com');
    const offline = CloudSyncBackendException(
      CloudSyncErrorKind.network,
      'offline',
    );

    test(
        'old uid denied (stale device) → same email, new uid → release → '
        'new first backup: no old failure shown', () async {
      final (dir, cloud) = await boundDevice();
      final a = await start(dir, cloud);
      final b = await secondDevice(cloud);
      await a.deletion.deleteAccount();
      await b.ui.songs.create(song('B 오래된 세션'));
      await b.sync.syncNow(); // refused by the deletion block
      await _idle(b);
      expect(b.sync.manualStatus, ManualSyncStatus.failed);
      expect(b.sync.manualMessage, isNotNull);

      await b.account.signOut();
      b.auth.next = reborn;
      final before = await data(b.storage);
      await b.account.signIn();
      expect(b.account.linkStatus, AccountLinkStatus.previousAccountSameEmail);
      // Before approval: nothing local changes, nothing syncs, and the old
      // uid's failure is not presented for the new uid.
      expect(await b.storage.readBoundAccountUid(), _uid);
      expect(await data(b.storage), before);
      expect(b.sync.manualStatus, ManualSyncStatus.idle);
      expect(b.sync.manualMessage, isNull);

      expect(await b.account.releasePreviousCloudBinding(), isTrue);
      await b.sync.startSetup();
      expect(b.sync.phase, CloudSyncPhase.connected);
      expect(await b.storage.readBoundAccountUid(), reborn.uid);
      expect(b.sync.manualStatus, ManualSyncStatus.idle);
      expect(b.sync.manualMessage, isNull);
      expect(b.sync.lastSyncAtMs, isNotNull); // the new binding's own time
    });

    test('old uid failure → account deleted → new uid first binding: clean',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      cloud.fetchError = offline;
      await w.sync.syncNow();
      expect(w.sync.manualStatus, ManualSyncStatus.failed);
      cloud.fetchError = null;
      await w.deletion.deleteAccount();
      const carol = AccountUser(uid: 'uid-carol', email: 'carol@example.com');
      w.auth.next = carol;
      await w.account.signIn();
      await w.sync.startSetup();
      expect(w.sync.phase, CloudSyncPhase.connected);
      expect(w.sync.manualStatus, ManualSyncStatus.idle);
      expect(w.sync.manualMessage, isNull);
    });

    test('a failure of the current uid stays shown (not hidden)', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      cloud.fetchError = offline;
      await w.sync.syncNow();
      expect(w.sync.manualStatus, ManualSyncStatus.failed);
      final message = w.sync.manualMessage;
      expect(message, contains('동기화하지 못했어요'));
      // Same account: re-reading the link (an account event) keeps it,
      // and so does the failure backoff (no immediate automatic re-run).
      final runs = w.sync.syncRuns;
      await w.account.refreshLink();
      expect(w.sync.manualStatus, ManualSyncStatus.failed);
      expect(w.sync.manualMessage, message);
      w.sync.onAppResumed();
      await _idle(w);
      expect(w.sync.syncRuns, runs);
      expect(w.sync.manualStatus, ManualSyncStatus.failed);
      expect(w.sync.manualMessage, message);
    });

    test('a later success of the current uid removes the failure', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      cloud.fetchError = offline;
      await w.sync.syncNow();
      expect(w.sync.manualStatus, ManualSyncStatus.failed);
      cloud.fetchError = null;
      await w.sync.syncNow();
      expect(w.sync.manualStatus, ManualSyncStatus.succeeded);
      expect(w.sync.manualMessage, isNull);
    });

    test('sign-out and back in with the same account still syncs', () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      final runs = w.sync.syncRuns;
      await w.account.signOut();
      expect(w.sync.phase, CloudSyncPhase.unavailable);
      w.auth.next = _alice;
      await w.account.signIn();
      await _idle(w);
      expect(w.sync.phase, CloudSyncPhase.connected);
      await w.sync.syncNow();
      expect(w.sync.manualStatus, ManualSyncStatus.succeeded);
      expect(w.sync.syncRuns, greaterThan(runs));
    });

    test('a run finishing after the account changed leaves no result',
        () async {
      final (dir, cloud) = await boundDevice();
      final w = await start(dir, cloud);
      cloud.fetchGate = Completer<void>();
      cloud.fetchError = offline;
      unawaited(w.sync.syncNow());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(w.sync.busy, isTrue);
      await w.account.signOut();
      cloud.fetchGate!.complete();
      cloud.fetchGate = null;
      await _idle(w);
      expect(w.sync.manualStatus, ManualSyncStatus.idle);
      expect(w.sync.manualMessage, isNull);
      cloud.fetchError = null;
    });
  });
}

/// Lets timers, debounces and runs finish.
Future<void> _idle(_World w) async {
  await Future<void>.delayed(_debounce * 2);
  for (var i = 0; i < 200 && (w.sync.busy || w.deletion.busy); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}
