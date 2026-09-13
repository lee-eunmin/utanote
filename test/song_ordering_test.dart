import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:utanote/models/song.dart';
import 'package:utanote/models/tj_search_result.dart';
import 'package:utanote/services/tj_search_service.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/storage/web/web_local_storage.dart';
import 'package:utanote/ui/song_list_screen.dart';
import 'package:utanote/ui/tj_search_screen.dart';
import 'package:utanote/ui/widgets/song_card.dart';

/// Covers the "main 노래 목록 always shows newest-added songs first"
/// requirement: `created_at DESC, id DESC`, never `updated_at`, applied
/// identically across every [LocalStorage] implementation, and preserved
/// through search/filter. Folder ordering and TJ search-result ordering are
/// explicitly out of scope and untouched.
class _FakeTjSearchService extends TjSearchService {
  final Future<List<TjSearchResult>> Function(String query) onSearch;

  _FakeTjSearchService(this.onSearch) : super(baseUrl: 'https://fake.test');

  @override
  Future<List<TjSearchResult>> search(
    String query, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    return onSearch(query);
  }
}

void main() {
  Future<Song> addSong(
    LocalStorage storage,
    String title, {
    required DateTime createdAt,
    String songNumber = '1',
    String? artist,
  }) {
    return storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: songNumber,
        title: title,
        artist: artist,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
  }

  group('SongRepository default ordering', () {
    void runSharedTests(
      String label,
      Future<LocalStorage> Function() makeStorage,
    ) {
      group(label, () {
        test('newest created song appears first', () async {
          final storage = await makeStorage();
          final t0 = DateTime(2024, 1, 1);
          await addSong(storage, 'A', createdAt: t0);
          await addSong(storage, 'B', createdAt: t0.add(const Duration(minutes: 1)));
          await addSong(storage, 'C', createdAt: t0.add(const Duration(minutes: 2)));

          final all = await storage.songs.getAll();
          expect(all.map((s) => s.title).toList(), ['C', 'B', 'A']);
        });

        test(
          'songs with identical created_at break ties by id descending',
          () async {
            final storage = await makeStorage();
            final t0 = DateTime(2024, 1, 1);
            final x = await addSong(storage, 'X', createdAt: t0);
            final y = await addSong(storage, 'Y', createdAt: t0);

            expect(y.id, greaterThan(x.id!));
            final all = await storage.songs.getAll();
            expect(all.map((s) => s.title).toList(), ['Y', 'X']);
          },
        );

        test(
          'editing an older song does not move it above newer songs '
          '(updated_at is never used for ordering)',
          () async {
            final storage = await makeStorage();
            final t0 = DateTime(2024, 1, 1);
            final older = await addSong(storage, 'Older', createdAt: t0);
            await addSong(
              storage,
              'Newer',
              createdAt: t0.add(const Duration(days: 1)),
            );

            await storage.songs.update(
              older.copyWith(
                artist: 'edited',
                updatedAt: t0.add(const Duration(days: 30)),
              ),
            );

            final all = await storage.songs.getAll();
            expect(all.map((s) => s.title).toList(), ['Newer', 'Older']);
          },
        );

        test('search results preserve newest-first ordering', () async {
          final storage = await makeStorage();
          final t0 = DateTime(2024, 1, 1);
          await addSong(
            storage,
            'Apple Song',
            songNumber: '1',
            createdAt: t0,
          );
          await addSong(
            storage,
            'Apple Pie',
            songNumber: '2',
            createdAt: t0.add(const Duration(minutes: 1)),
          );
          await addSong(
            storage,
            'Banana',
            songNumber: '3',
            createdAt: t0.add(const Duration(minutes: 2)),
          );

          final results = await storage.songs.search('Apple');
          expect(results.map((s) => s.title).toList(), ['Apple Pie', 'Apple Song']);
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
  });

  group('노래 목록 screen ordering', () {
    Widget wrap(Widget child) => MaterialApp(home: child);

    double titleY(WidgetTester tester, String title) =>
        tester.getTopLeft(find.text(title)).dy;

    testWidgets(
      'manually added and TJ-added songs follow the same newest-first order',
      (tester) async {
        final storage = InMemoryLocalStorage();
        await storage.init();
        // An older song, standing in for something added earlier by hand.
        await addSong(storage, '기존 수동곡', createdAt: DateTime(2024, 1, 1));

        final service = _FakeTjSearchService(
          (query) async => const [
            TjSearchResult(songNumber: '999', title: 'TJ로 추가한 곡', artist: '아티스트'),
          ],
        );
        await tester.pumpWidget(
          wrap(TjSearchScreen(storage: storage, service: service)),
        );
        await tester.enterText(find.byKey(const Key('tjSearchField')), '검색');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('tjAdd_999')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
        await tester.tap(find.byKey(const Key('saveSongButton')));
        await tester.pumpAndSettle();

        await tester.pumpWidget(wrap(SongListScreen(storage: storage)));
        await tester.pumpAndSettle();

        expect(find.text('기존 수동곡'), findsOneWidget);
        expect(find.text('TJ로 추가한 곡'), findsOneWidget);
        expect(
          titleY(tester, 'TJ로 추가한 곡'),
          lessThan(titleY(tester, '기존 수동곡')),
        );
      },
    );

    testWidgets(
      'editing an older song does not move it above newer songs',
      (tester) async {
        final storage = InMemoryLocalStorage();
        await storage.init();
        final key = GlobalKey<SongListScreenState>();
        await tester.pumpWidget(
          wrap(SongListScreen(key: key, storage: storage)),
        );
        await tester.pumpAndSettle();

        Future<void> addViaUi(String number, String title) async {
          await tester.tap(find.byKey(const Key('addSongButton')));
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const Key('songNumberField')), number);
          await tester.enterText(find.byKey(const Key('songTitleField')), title);
          await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
          await tester.tap(find.byKey(const Key('saveSongButton')));
          await tester.pumpAndSettle();
        }

        await addViaUi('1', '오래된 곡');
        await addViaUi('2', '최신 곡');

        expect(
          titleY(tester, '최신 곡'),
          lessThan(titleY(tester, '오래된 곡')),
        );

        // Edit the older song without touching its created_at.
        await tester.tap(find.text('오래된 곡'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('songArtistField')),
          '수정된 아티스트',
        );
        await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
        await tester.tap(find.byKey(const Key('saveSongButton')));
        await tester.pumpAndSettle();

        expect(
          titleY(tester, '최신 곡'),
          lessThan(titleY(tester, '오래된 곡')),
        );
      },
    );

    testWidgets(
      'searching within the song list preserves newest-first order',
      (tester) async {
        final storage = InMemoryLocalStorage();
        await storage.init();
        final t0 = DateTime(2024, 1, 1);
        await addSong(storage, 'Apple Song', songNumber: '1', createdAt: t0);
        await addSong(
          storage,
          'Apple Pie',
          songNumber: '2',
          createdAt: t0.add(const Duration(minutes: 1)),
        );
        await addSong(
          storage,
          'Banana',
          songNumber: '3',
          createdAt: t0.add(const Duration(minutes: 2)),
        );

        await tester.pumpWidget(wrap(SongListScreen(storage: storage)));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('songSearchField')),
          'Apple',
        );
        await tester.pumpAndSettle();

        expect(find.text('Banana'), findsNothing);
        expect(
          titleY(tester, 'Apple Pie'),
          lessThan(titleY(tester, 'Apple Song')),
        );
      },
    );

    testWidgets(
      'the favorite filter chip preserves newest-first order',
      (tester) async {
        final storage = InMemoryLocalStorage();
        await storage.init();
        final t0 = DateTime(2024, 1, 1);
        await addSong(storage, '오래된 즐겨찾기', createdAt: t0);
        await addSong(
          storage,
          '최신 즐겨찾기',
          createdAt: t0.add(const Duration(minutes: 1)),
        );
        await addSong(
          storage,
          '즐겨찾기 아님',
          createdAt: t0.add(const Duration(minutes: 2)),
        );

        await tester.pumpWidget(wrap(SongListScreen(storage: storage)));
        await tester.pumpAndSettle();

        Future<void> favorite(String title) async {
          final button = find.descendant(
            of: find.ancestor(
              of: find.text(title),
              matching: find.byType(SongCard),
            ),
            matching: find.byIcon(Icons.favorite_border_rounded),
          );
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        await favorite('오래된 즐겨찾기');
        await favorite('최신 즐겨찾기');

        await tester.tap(find.text('즐겨찾기'));
        await tester.pumpAndSettle();

        expect(find.text('즐겨찾기 아님'), findsNothing);
        expect(
          titleY(tester, '최신 즐겨찾기'),
          lessThan(titleY(tester, '오래된 즐겨찾기')),
        );
      },
    );
  });
}
