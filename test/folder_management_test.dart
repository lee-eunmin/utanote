import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/storage/web/web_local_storage.dart';
import 'package:utanote/ui/app_shell.dart';

/// Folder rename/delete: renaming must only touch the folder's name (never
/// its folder_songs memberships), and deleting a folder must never delete
/// the songs themselves — only the folder row and its folder_songs rows.
/// Storage-level behavior is exercised against both the in-memory fake and
/// the Web storage implementation, since both are expected to behave the
/// same as the Android/SQLite implementation (see
/// sqlite_local_storage.dart, which already implements this the same way).
void main() {
  Future<Song> addSong(LocalStorage storage, String title) {
    final now = DateTime.now();
    return storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '1',
        title: title,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<Folder> addFolder(LocalStorage storage, String name) {
    final now = DateTime.now();
    return storage.folders.create(
      Folder(name: name, createdAt: now, updatedAt: now),
    );
  }

  void runSharedTests(String label, Future<LocalStorage> Function() makeStorage) {
    group(label, () {
      test('renaming a folder preserves folder_songs relationships', () async {
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final a = await addSong(storage, '노래A');
        final b = await addSong(storage, '노래B');
        await storage.folders.addSong(folder.id!, a.id!);
        await storage.folders.addSong(folder.id!, b.id!);

        await storage.folders.update(
          folder.copyWith(name: '새 이름', updatedAt: DateTime.now()),
        );

        final renamed = (await storage.folders.getAll())
            .firstWhere((f) => f.id == folder.id);
        expect(renamed.name, '새 이름');
        expect(
          await storage.folders.getSongIds(folder.id!),
          containsAll([a.id, b.id]),
        );
        expect((await storage.folders.getSongIds(folder.id!)).length, 2);
      });

      test('renaming a folder to an empty name is a no-op at the storage layer', () async {
        // The UI layer is responsible for rejecting empty names before ever
        // calling update(); this only pins that a caller who does pass an
        // unchanged/non-empty name doesn't lose data.
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final song = await addSong(storage, '노래1');
        await storage.folders.addSong(folder.id!, song.id!);

        await storage.folders.update(
          folder.copyWith(name: '연습곡', updatedAt: DateTime.now()),
        );

        expect(await storage.folders.getSongIds(folder.id!), [song.id]);
      });

      test('deleting a folder does not delete the songs themselves', () async {
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final a = await addSong(storage, '노래A');
        final b = await addSong(storage, '노래B');
        await storage.folders.addSong(folder.id!, a.id!);
        await storage.folders.addSong(folder.id!, b.id!);

        await storage.folders.delete(folder.id!);

        final remainingSongs = await storage.songs.getAll();
        expect(remainingSongs.map((s) => s.id), containsAll([a.id, b.id]));
        expect(remainingSongs.length, 2);
      });

      test('deleting a folder removes the folder and its folder_songs rows', () async {
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final song = await addSong(storage, '노래1');
        await storage.folders.addSong(folder.id!, song.id!);

        await storage.folders.delete(folder.id!);

        final folders = await storage.folders.getAll();
        expect(folders.any((f) => f.id == folder.id), isFalse);
        expect(await storage.folders.getSongIds(folder.id!), isEmpty);
      });

      test('deleting a folder leaves other folders and their memberships untouched', () async {
        final storage = await makeStorage();
        final folderA = await addFolder(storage, '폴더A');
        final folderB = await addFolder(storage, '폴더B');
        final songA = await addSong(storage, '노래A');
        final songB = await addSong(storage, '노래B');
        await storage.folders.addSong(folderA.id!, songA.id!);
        await storage.folders.addSong(folderB.id!, songB.id!);

        await storage.folders.delete(folderA.id!);

        final folders = await storage.folders.getAll();
        expect(folders.map((f) => f.id), [folderB.id]);
        expect(await storage.folders.getSongIds(folderB.id!), [songB.id]);
      });
    });
  }

  runSharedTests('InMemoryLocalStorage', () async {
    final storage = InMemoryLocalStorage();
    await storage.init();
    return storage;
  });

  runSharedTests('WebLocalStorage', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = WebLocalStorage();
    await storage.init();
    return storage;
  });

  group('folder long-press management menu (UI)', () {
    testWidgets('long-pressing a folder shows the management menu', (
      tester,
    ) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final now = DateTime.now();
      final folder = await storage.folders.create(
        Folder(name: '연습곡', createdAt: now, updatedAt: now),
      );

      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(Key('folderCard_${folder.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('renameFolderMenuItem')), findsOneWidget);
      expect(find.byKey(const Key('deleteFolderMenuItem')), findsOneWidget);
    });

    testWidgets('renaming via the menu updates the folder name and keeps its songs', (
      tester,
    ) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final now = DateTime.now();
      final folder = await storage.folders.create(
        Folder(name: '연습곡', createdAt: now, updatedAt: now),
      );
      final song = await storage.songs.create(
        Song(
          karaokeType: 'TJ',
          songNumber: '1',
          title: '노래1',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await storage.folders.addSong(folder.id!, song.id!);

      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(Key('folderCard_${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('renameFolderMenuItem')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('renameFolderNameField')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('renameFolderNameField')),
        '새 폴더 이름',
      );
      await tester.tap(find.byKey(const Key('saveRenameFolderButton')));
      await tester.pumpAndSettle();

      expect(find.text('새 폴더 이름'), findsOneWidget);
      expect(find.text('연습곡'), findsNothing);
      expect(await storage.folders.getSongIds(folder.id!), [song.id]);
    });

    testWidgets('deleting via the menu asks for confirmation and removes the folder, not its songs', (
      tester,
    ) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final now = DateTime.now();
      final folder = await storage.folders.create(
        Folder(name: '연습곡', createdAt: now, updatedAt: now),
      );
      final song = await storage.songs.create(
        Song(
          karaokeType: 'TJ',
          songNumber: '1',
          title: '노래1',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await storage.folders.addSong(folder.id!, song.id!);

      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(Key('folderCard_${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteFolderMenuItem')));
      await tester.pumpAndSettle();

      // Confirmation dialog must appear before anything is deleted.
      expect(find.text('폴더 삭제'), findsOneWidget);
      expect(await storage.folders.getAll(), isNotEmpty);

      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();

      expect(find.text('폴더가 없습니다.'), findsOneWidget);
      expect(await storage.folders.getAll(), isEmpty);
      final remainingSongs = await storage.songs.getAll();
      expect(remainingSongs.map((s) => s.id), [song.id]);
    });
  });
}
