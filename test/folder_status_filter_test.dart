import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/ui/app_shell.dart';
import 'package:utanote/ui/folder_detail_screen.dart';
import 'package:utanote/ui/song_list_screen.dart';
import 'package:utanote/ui/song_status_filter.dart';
import 'package:utanote/ui/widgets/choice_chip_row.dart';
import 'package:utanote/ui/widgets/filter_chip_bar.dart';

/// Practice-status filter on the folder detail screen: scoped to the
/// folder's own songs, UI-only (starts at '전체' for every folder), and
/// re-applied immediately after a song's status is edited.
void main() {
  late LocalStorage storage;
  late Folder folderA;
  late Folder folderB;

  Future<Song> addSong(String title, String? status, {Folder? into}) async {
    final now = DateTime.now();
    final song = await storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '${title.hashCode.abs() % 100000}',
        title: title,
        practiceStatus: status,
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (into != null) await storage.folders.addSong(into.id!, song.id!);
    return song;
  }

  Future<Folder> addFolder(String name) {
    final now = DateTime.now();
    return storage.folders.create(
      Folder(name: name, createdAt: now, updatedAt: now),
    );
  }

  setUp(() async {
    storage = InMemoryLocalStorage();
    await storage.init();
    folderA = await addFolder('폴더A');
    folderB = await addFolder('폴더B');
    await addSong('A전1', '연습 전', into: folderA);
    await addSong('A전2', null, into: folderA); // legacy: no status stored
    await addSong('A중1', '연습 중', into: folderA);
    await addSong('A완1', '완료', into: folderA);
    // Same statuses in another folder and outside any folder — must never
    // show up in folder A.
    await addSong('B완1', '완료', into: folderB);
    await addSong('B중1', '연습 중', into: folderB);
    await addSong('없음완1', '완료');
  });

  Finder chip(String label) => find.descendant(
    of: find.byKey(const Key('folderStatusFilterBar')),
    matching: find.text(label),
  );

  Future<void> pumpFolder(WidgetTester tester, Folder folder) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FolderDetailScreen(storage: storage, folder: folder),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectStatus(WidgetTester tester, String label) async {
    await tester.tap(chip(label));
    await tester.pumpAndSettle();
  }

  void expectTitles(List<String> visible, List<String> hidden) {
    for (final t in visible) {
      expect(find.text(t), findsOneWidget, reason: '$t should be visible');
    }
    for (final t in hidden) {
      expect(find.text(t), findsNothing, reason: '$t should be hidden');
    }
  }

  const otherFolderSongs = ['B완1', 'B중1', '없음완1'];

  group('filterSongsByPracticeStatus', () {
    Song s(String title, String? status) => Song(
      karaokeType: 'TJ',
      songNumber: '1',
      title: title,
      practiceStatus: status,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

    test('전체 returns the same list; null status counts as 연습 전', () {
      final songs = [s('a', '완료'), s('b', null), s('c', '연습 중')];
      expect(filterSongsByPracticeStatus(songs, kSongFilterAll), same(songs));
      expect(filterSongsByPracticeStatus(songs, '연습 전').map((x) => x.title), [
        'b',
      ]);
      expect(filterSongsByPracticeStatus(songs, '완료').map((x) => x.title), [
        'a',
      ]);
    });
  });

  group('folder detail status filter', () {
    testWidgets('defaults to 전체 and shows every song in the folder', (
      tester,
    ) async {
      await pumpFolder(tester, folderA);

      final bar = tester.widget<FilterChipBar>(
        find.byKey(const Key('folderStatusFilterBar')),
      );
      expect(bar.selected, kSongFilterAll);
      expect(bar.options, ['전체', '완료', '연습 중', '연습 전']);
      expectTitles(['A전1', 'A전2', 'A중1', 'A완1'], otherFolderSongs);
    });

    testWidgets('연습 전 shows only this folder\'s not-started songs', (
      tester,
    ) async {
      await pumpFolder(tester, folderA);
      await selectStatus(tester, '연습 전');
      expectTitles(['A전1', 'A전2'], ['A중1', 'A완1', ...otherFolderSongs]);
    });

    testWidgets('연습 중 shows only this folder\'s in-progress songs', (
      tester,
    ) async {
      await pumpFolder(tester, folderA);
      await selectStatus(tester, '연습 중');
      expectTitles(['A중1'], ['A전1', 'A전2', 'A완1', ...otherFolderSongs]);
    });

    testWidgets('완료 shows only this folder\'s finished songs', (tester) async {
      await pumpFolder(tester, folderA);
      await selectStatus(tester, '완료');
      expectTitles(['A완1'], ['A전1', 'A전2', 'A중1', ...otherFolderSongs]);
    });

    testWidgets('back to 전체 restores the whole folder', (tester) async {
      await pumpFolder(tester, folderA);
      await selectStatus(tester, '완료');
      await selectStatus(tester, '전체');
      expectTitles(['A전1', 'A전2', 'A중1', 'A완1'], otherFolderSongs);
    });

    testWidgets('editing a song\'s status re-filters immediately', (
      tester,
    ) async {
      await pumpFolder(tester, folderA);
      await selectStatus(tester, '연습 중');
      expectTitles(['A중1'], []);

      await tester.tap(find.text('A중1'));
      await tester.pumpAndSettle();
      final doneChip = find.descendant(
        of: find.byType(ChoiceChipRow<String>),
        matching: find.text('완료'),
      );
      await tester.ensureVisible(doneChip);
      await tester.pumpAndSettle();
      await tester.tap(doneChip);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
      await tester.tap(find.byKey(const Key('saveSongButton')));
      await tester.pumpAndSettle();

      expect(find.text('A중1'), findsNothing);
      expect(find.text('해당 상태의 곡이 없습니다.'), findsOneWidget);
      final saved = (await storage.songs.getAll()).firstWhere(
        (s) => s.title == 'A중1',
      );
      expect(saved.practiceStatus, '완료');

      // It now shows under 완료, and is still in the folder.
      await selectStatus(tester, '완료');
      expectTitles(['A중1', 'A완1'], ['B완1', '없음완1']);
    });

    testWidgets('empty filter result vs. empty folder messages differ', (
      tester,
    ) async {
      final onlyDone = await addFolder('완료만');
      await addSong('완료곡', '완료', into: onlyDone);
      await pumpFolder(tester, onlyDone);
      await selectStatus(tester, '연습 중');
      expect(find.text('해당 상태의 곡이 없습니다.'), findsOneWidget);
      expect(find.text('이 폴더에 노래가 없습니다.'), findsNothing);

      final empty = await addFolder('빈 폴더');
      await pumpFolder(tester, empty);
      expect(find.text('이 폴더에 노래가 없습니다.'), findsOneWidget);
      await selectStatus(tester, '완료');
      expect(find.text('이 폴더에 노래가 없습니다.'), findsOneWidget);
      expect(find.text('해당 상태의 곡이 없습니다.'), findsNothing);
    });

    testWidgets('opening another folder starts at 전체 again', (tester) async {
      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('folderCard_${folderA.id}')));
      await tester.pumpAndSettle();
      await selectStatus(tester, '완료');
      expectTitles(['A완1'], ['A중1']);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folderCard_${folderB.id}')));
      await tester.pumpAndSettle();

      final bar = tester.widget<FilterChipBar>(
        find.byKey(const Key('folderStatusFilterBar')),
      );
      expect(bar.selected, kSongFilterAll);
      expectTitles(['B완1', 'B중1'], ['A완1', '없음완1']);

      // And re-opening folder A also starts fresh.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folderCard_${folderA.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChipBar>(
              find.byKey(const Key('folderStatusFilterBar')),
            )
            .selected,
        kSongFilterAll,
      );
      expectTitles(['A전1', 'A전2', 'A중1', 'A완1'], ['B완1']);
    });
  });

  group('main song list filter (regression)', () {
    Finder mainChip(String label) => find.descendant(
      of: find.byType(FilterChipBar),
      matching: find.text(label),
    );

    testWidgets('status and favorite chips still filter all songs', (
      tester,
    ) async {
      final fav = (await storage.songs.getAll()).firstWhere(
        (s) => s.title == 'B중1',
      );
      await storage.songs.update(fav.copyWith(favorite: true));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SongListScreen(storage: storage)),
        ),
      );
      await tester.pumpAndSettle();

      final bar = tester.widget<FilterChipBar>(find.byType(FilterChipBar));
      expect(bar.options, ['전체', '즐겨찾기', '완료', '연습 중', '연습 전']);

      await tester.tap(mainChip('완료'));
      await tester.pumpAndSettle();
      expectTitles(['A완1', 'B완1', '없음완1'], ['A중1', 'B중1', 'A전2']);

      await tester.tap(mainChip('연습 중'));
      await tester.pumpAndSettle();
      expectTitles(['A중1', 'B중1'], ['A완1', 'A전1']);

      await tester.tap(mainChip('즐겨찾기'));
      await tester.pumpAndSettle();
      expectTitles(['B중1'], ['A중1', 'A완1']);

      await tester.tap(mainChip('전체'));
      await tester.pumpAndSettle();
      expectTitles(['없음완1', 'B중1', 'B완1'], []);
    });
  });
}
