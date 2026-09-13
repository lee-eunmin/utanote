import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/storage/web/web_local_storage.dart';
import 'package:utanote/ui/song_bulk_actions.dart';

/// Bug 2: deleting a song must also remove every folder_songs row that
/// references it, so folder counts stay correct without an app restart.
/// Exercised against both the Web storage implementation and the in-memory
/// fake used by widget tests, since both are expected to behave the same as
/// the Android/SQLite implementation (see sqlite_local_storage.dart).
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
      test('deleting a song in a folder makes the folder count 0', () async {
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final song = await addSong(storage, '노래1');
        await storage.folders.addSong(folder.id!, song.id!);

        expect(await storage.folders.getSongIds(folder.id!), [song.id]);

        await storage.songs.delete(song.id!);

        expect(await storage.folders.getSongIds(folder.id!), isEmpty);
      });

      test(
        'the folder_songs relationship is gone, not just filtered from the count',
        () async {
          final storage = await makeStorage();
          final folder = await addFolder(storage, '연습곡');
          final song = await addSong(storage, '노래1');
          await storage.folders.addSong(folder.id!, song.id!);

          await storage.songs.delete(song.id!);

          // Re-adding a *different* song to the same folder must not somehow
          // resurrect the deleted membership or collide with it.
          final other = await addSong(storage, '노래2');
          await storage.folders.addSong(folder.id!, other.id!);
          expect(await storage.folders.getSongIds(folder.id!), [other.id]);
        },
      );

      test('bulk deletion also removes folder relationships', () async {
        final storage = await makeStorage();
        final folder = await addFolder(storage, '연습곡');
        final a = await addSong(storage, '노래A');
        final b = await addSong(storage, '노래B');
        final c = await addSong(storage, '노래C');
        await storage.folders.addSong(folder.id!, a.id!);
        await storage.folders.addSong(folder.id!, b.id!);
        await storage.folders.addSong(folder.id!, c.id!);

        await deleteSongs(storage, {a.id!, b.id!});

        expect(await storage.folders.getSongIds(folder.id!), [c.id]);
      });

      test(
        'unrelated folders and songs are untouched by another song\'s deletion',
        () async {
          final storage = await makeStorage();
          final folderA = await addFolder(storage, '폴더A');
          final folderB = await addFolder(storage, '폴더B');
          final songA = await addSong(storage, '노래A');
          final songB = await addSong(storage, '노래B');
          await storage.folders.addSong(folderA.id!, songA.id!);
          await storage.folders.addSong(folderB.id!, songB.id!);

          await storage.songs.delete(songA.id!);

          expect(await storage.folders.getSongIds(folderA.id!), isEmpty);
          expect(await storage.folders.getSongIds(folderB.id!), [songB.id]);
          final remaining = await storage.songs.getAll();
          expect(remaining.map((s) => s.id), [songB.id]);
          final folders = await storage.folders.getAll();
          expect(folders.map((f) => f.id), containsAll([folderA.id, folderB.id]));
        },
      );
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
}
