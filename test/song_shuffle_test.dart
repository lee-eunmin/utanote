import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/models/song.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/storage/observed_local_storage.dart';
import 'package:utanote/ui/song_list_screen.dart';
import 'package:utanote/ui/song_shuffle.dart';
import 'package:utanote/ui/widgets/filter_chip_bar.dart';
import 'package:utanote/ui/widgets/song_card.dart';

/// "랜덤 정렬" on the main song list: UI/session-only ordering applied after
/// search and filter, regenerated only by the random button.
void main() {
  final t0 = DateTime(2024, 1, 1);

  Future<Song> addSong(
    LocalStorage storage,
    String title, {
    required int minute,
    String? status,
  }) {
    final at = t0.add(Duration(minutes: minute));
    return storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '${100 + minute}',
        title: title,
        practiceStatus: status,
        createdAt: at,
        updatedAt: at,
      ),
    );
  }

  Song song(int id) => Song(
    id: id,
    karaokeType: 'TJ',
    songNumber: '$id',
    title: 'S$id',
    createdAt: t0,
    updatedAt: t0,
  );

  group('SongShuffleOrder', () {
    test('returns a copy with the same songs, no loss or duplicates', () {
      final input = List.generate(30, (i) => song(i + 1));
      final before = List.of(input);
      final shuffled = SongShuffleOrder(
        generation: 1,
        random: Random(7),
      ).apply(input);

      expect(identical(shuffled, input), isFalse);
      expect(input, before, reason: 'input list must not be reordered');
      expect(shuffled.length, input.length);
      expect(shuffled.map((s) => s.id).toSet().length, input.length);
      expect(shuffled.map((s) => s.id).toSet(), input.map((s) => s.id).toSet());
    });

    test('same instance always yields the same order (subset-stable)', () {
      final order = SongShuffleOrder(generation: 1, random: Random(3));
      final input = List.generate(20, (i) => song(i + 1));
      final first = order.apply(input).map((s) => s.id).toList();
      final again = order.apply(input).map((s) => s.id).toList();
      expect(again, first);

      // A filtered subset keeps the same relative order.
      final subset = input.where((s) => s.id!.isEven).toList();
      expect(
        order.apply(subset).map((s) => s.id).toList(),
        first.where((id) => id!.isEven).toList(),
      );
    });

    test('a new instance draws fresh keys from the random source', () {
      final input = List.generate(20, (i) => song(i + 1));
      // Same seeded stream: the second order uses the next 20 draws.
      final random = Random(11);
      final a = SongShuffleOrder(generation: 1, random: random).apply(input);
      final b = SongShuffleOrder(generation: 2, random: random).apply(input);

      final reference = Random(11);
      for (var i = 0; i < 20; i++) {
        reference.nextDouble();
      }
      final keys = {for (final s in input) s.id!: reference.nextDouble()};
      final expectedB = List.of(input)
        ..sort((x, y) => keys[x.id]!.compareTo(keys[y.id]!));

      expect(b.map((s) => s.id).toList(), expectedB.map((s) => s.id).toList());
      expect(a.length, b.length);
    });
  });

  group('노래 목록 랜덤 정렬', () {
    Widget wrap(Widget child) => MaterialApp(home: child);

    List<String> visibleTitles(WidgetTester tester) {
      final cards = tester.widgetList<SongCard>(find.byType(SongCard)).toList();
      final withY = [
        for (final c in cards)
          (c.song.title, tester.getTopLeft(find.byWidget(c)).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final e in withY) e.$1];
    }

    Future<InMemoryLocalStorage> seed(int count) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      for (var i = 0; i < count; i++) {
        await addSong(storage, 'Song $i', minute: i);
      }
      return storage;
    }

    Future<void> tapShuffle(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('shuffleSongsButton')));
      await tester.pumpAndSettle();
    }

    testWidgets('A/H: a fresh screen starts in default 곡 추가순', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = await seed(5);
      final key = GlobalKey<SongListScreenState>();
      await tester.pumpWidget(wrap(SongListScreen(key: key, storage: storage)));
      await tester.pumpAndSettle();

      expect(key.currentState!.shuffleGeneration, 0);
      expect(visibleTitles(tester), [
        'Song 4',
        'Song 3',
        'Song 2',
        'Song 1',
        'Song 0',
      ]);

      // Shuffle, then rebuild the app from scratch (new session state).
      await tapShuffle(tester);
      expect(key.currentState!.shuffleGeneration, 1);
      await tester.pumpWidget(const SizedBox());
      final key2 = GlobalKey<SongListScreenState>();
      await tester.pumpWidget(
        wrap(SongListScreen(key: key2, storage: storage)),
      );
      await tester.pumpAndSettle();
      expect(key2.currentState!.shuffleGeneration, 0);
      expect(visibleTitles(tester).first, 'Song 4');
      expect(visibleTitles(tester).last, 'Song 0');
    });

    testWidgets('button has the 랜덤 정렬 tooltip and fits a small screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = await seed(2);
      await tester.pumpWidget(wrap(SongListScreen(storage: storage)));
      await tester.pumpAndSettle();

      expect(find.byTooltip('랜덤 정렬'), findsOneWidget);
      expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Right of the filter chips.
      expect(
        tester.getTopLeft(find.byKey(const Key('shuffleSongsButton'))).dx,
        greaterThan(tester.getTopLeft(find.text('전체')).dx),
      );
    });

    testWidgets(
      'B/C: shuffling keeps every song once; each tap is a new order',
      (tester) async {
        tester.view.physicalSize = const Size(800, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final storage = await seed(8);
        final key = GlobalKey<SongListScreenState>();
        await tester.pumpWidget(
          wrap(
            SongListScreen(
              key: key,
              storage: storage,
              shuffleRandom: Random(1),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final original = visibleTitles(tester);

        await tapShuffle(tester);
        final first = visibleTitles(tester);
        expect(first.length, original.length);
        expect(first.toSet(), original.toSet());
        expect(first.toSet().length, first.length);
        expect(key.currentState!.shuffleGeneration, 1);

        await tapShuffle(tester);
        final second = visibleTitles(tester);
        expect(second.toSet(), original.toSet());
        expect(second.length, original.length);
        expect(key.currentState!.shuffleGeneration, 2);
      },
    );

    testWidgets('D: rebuilds, reloads and filter changes keep the order', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = await seed(8);
      final key = GlobalKey<SongListScreenState>();
      await tester.pumpWidget(
        wrap(
          SongListScreen(key: key, storage: storage, shuffleRandom: Random(5)),
        ),
      );
      await tester.pumpAndSettle();
      await tapShuffle(tester);
      final shuffled = visibleTitles(tester);

      // Plain rebuild of the same widget tree.
      await tester.pumpWidget(
        wrap(
          SongListScreen(key: key, storage: storage, shuffleRandom: Random(5)),
        ),
      );
      await tester.pumpAndSettle();
      expect(visibleTitles(tester), shuffled);

      // Reload from storage (e.g. tab switch / sync).
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(visibleTitles(tester), shuffled);

      // Filter away and back.
      await tester.tap(find.text('즐겨찾기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('전체'));
      await tester.pumpAndSettle();
      expect(visibleTitles(tester), shuffled);
      expect(key.currentState!.shuffleGeneration, 1);
    });

    testWidgets('E: 연습 중 filter + random shows only 연습 중 songs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = InMemoryLocalStorage();
      await storage.init();
      for (var i = 0; i < 9; i++) {
        await addSong(
          storage,
          'Song $i',
          minute: i,
          status: ['연습 전', '연습 중', '완료'][i % 3],
        );
      }
      final practicing = {'Song 1', 'Song 4', 'Song 7'};

      await tester.pumpWidget(
        wrap(SongListScreen(storage: storage, shuffleRandom: Random(2))),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(FilterChipBar),
          matching: find.text('연습 중'),
        ),
      );
      await tester.pumpAndSettle();
      await tapShuffle(tester);

      final titles = visibleTitles(tester);
      expect(titles.length, 3);
      expect(titles.toSet(), practicing);

      // Back to 전체: all songs, once each.
      await tester.tap(find.text('전체'));
      await tester.pumpAndSettle();
      final all = visibleTitles(tester);
      expect(all.length, 9);
      expect(all.toSet().length, 9);
    });

    testWidgets('F: search + random never shows songs outside the results', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = InMemoryLocalStorage();
      await storage.init();
      await addSong(storage, 'Apple One', minute: 0);
      await addSong(storage, 'Banana', minute: 1);
      await addSong(storage, 'Apple Two', minute: 2);
      await addSong(storage, 'Cherry', minute: 3);
      await addSong(storage, 'Apple Three', minute: 4);

      await tester.pumpWidget(
        wrap(SongListScreen(storage: storage, shuffleRandom: Random(9))),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('songSearchField')), 'Apple');
      await tester.pumpAndSettle();
      await tapShuffle(tester);

      final titles = visibleTitles(tester);
      expect(titles.toSet(), {'Apple One', 'Apple Two', 'Apple Three'});
      expect(titles.length, 3);
    });

    testWidgets('G: shuffling writes nothing and leaves song data untouched', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final inner = await seed(6);
      var writes = 0;
      final storage = ObservedLocalStorage(
        inner,
        onUserDataChanged: () => writes++,
      );
      final before = (await inner.songs.getAll())
          .map((s) => s.toMap())
          .toList();

      await tester.pumpWidget(
        wrap(SongListScreen(storage: storage, shuffleRandom: Random(4))),
      );
      await tester.pumpAndSettle();
      await tapShuffle(tester);
      await tapShuffle(tester);

      expect(writes, 0);
      final after = (await inner.songs.getAll()).map((s) => s.toMap()).toList();
      expect(after, before, reason: 'same rows, order, created/updated_at');
    });
  });
}
