import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/ads/list_ad_source.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/theme/app_theme.dart';
import 'package:utanote/ui/song_list_screen.dart';
import 'package:utanote/ui/widgets/song_card.dart';
import 'package:utanote/ui/widgets/song_list_entries.dart';

/// Stands in for the Android native-ad source so placement and song
/// interactions can be tested without the ads plugin/platform views.
class _FakeAdSource implements ListAdSource {
  bool disposed = false;

  @override
  Widget buildAd(BuildContext context, int slot) =>
      SizedBox(key: ValueKey('ad-$slot'), height: 60, child: Text('AD $slot'));

  @override
  void dispose() => disposed = true;
}

Song _song(int n) => Song(
  id: n,
  karaokeType: 'TJ',
  songNumber: '$n',
  title: _title(n),
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

String _title(int n) => 'Song ${n.toString().padLeft(2, '0')}';

void main() {
  group('buildSongListEntries', () {
    List<int> adIndexes(List<SongListEntry> entries) => [
      for (var i = 0; i < entries.length; i++)
        if (entries[i] is AdEntry) i,
    ];

    test('no ads for fewer than 10 songs, and never before the first', () {
      for (var count = 0; count < 10; count++) {
        final entries = buildSongListEntries(
          List.generate(count, (i) => _song(i + 1)),
          adInterval: 10,
        );
        expect(entries.whereType<AdEntry>(), isEmpty, reason: '$count songs');
      }
      final entries = buildSongListEntries(
        List.generate(35, (i) => _song(i + 1)),
        adInterval: 10,
      );
      expect(entries.first, isA<SongEntry>());
    });

    test('places one ad after song 10, 20, 30, ...', () {
      final entries = buildSongListEntries(
        List.generate(35, (i) => _song(i + 1)),
        adInterval: 10,
      );
      // 10 songs, ad, 10 songs, ad, 10 songs, ad, 5 songs.
      expect(adIndexes(entries), [10, 21, 32]);
      expect(entries.whereType<AdEntry>().map((e) => e.slot), [0, 1, 2]);
      expect(entries, hasLength(38));
    });

    test('keeps every song, in order, with ads only as separate entries', () {
      final songs = List.generate(25, (i) => _song(i + 1));
      final entries = buildSongListEntries(songs, adInterval: 10);
      expect(entries.whereType<SongEntry>().map((e) => e.song).toList(), songs);
    });

    test('placement is relative to the (filtered) list it is given', () {
      final filtered = [for (var n = 1; n <= 30; n += 2) _song(n)]; // 15
      final entries = buildSongListEntries(filtered, adInterval: 10);
      expect(adIndexes(entries), [10]);
      expect((entries[9] as SongEntry).song.id, 19);
      expect((entries[11] as SongEntry).song.id, 21);
    });

    test('null interval produces songs only', () {
      final entries = buildSongListEntries(
        List.generate(30, (i) => _song(i + 1)),
      );
      expect(entries.whereType<AdEntry>(), isEmpty);
      expect(entries, hasLength(30));
    });
  });

  group('SongListScreen with ads', () {
    late LocalStorage storage;
    late _FakeAdSource ads;

    /// Adds songs 1..[count] so the list shows them as Song 01, 02, ...
    /// top-to-bottom (newest-first ordering ⇒ song 1 is newest).
    Future<void> seed(int count) async {
      final t0 = DateTime(2024, 1, 1);
      for (var n = count; n >= 1; n--) {
        final at = t0.add(Duration(minutes: count - n));
        await storage.songs.create(
          Song(
            karaokeType: 'TJ',
            songNumber: '${1000 + n}',
            title: _title(n),
            createdAt: at,
            updatedAt: at,
          ),
        );
      }
    }

    Future<void> pumpScreen(WidgetTester tester) async {
      // Tall viewport so the whole lazily-built list is laid out at once.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: SongListScreen(storage: storage, adSourceFactory: () => ads),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder cardFor(int n) => find.ancestor(
      of: find.text(_title(n)),
      matching: find.byType(SongCard),
    );

    double topOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

    setUp(() async {
      storage = InMemoryLocalStorage();
      await storage.init();
      ads = _FakeAdSource();
    });

    testWidgets('inserts ads after song 10 and 20 only', (tester) async {
      await seed(25);
      await pumpScreen(tester);

      expect(find.text('AD 0'), findsOneWidget);
      expect(find.text('AD 1'), findsOneWidget);
      expect(find.text('AD 2'), findsNothing);

      final ad0 = topOf(tester, find.text('AD 0'));
      expect(ad0, greaterThan(topOf(tester, cardFor(10))));
      expect(ad0, lessThan(topOf(tester, cardFor(11))));
      final ad1 = topOf(tester, find.text('AD 1'));
      expect(ad1, greaterThan(topOf(tester, cardFor(20))));
      expect(ad1, lessThan(topOf(tester, cardFor(21))));
      // Nothing above the first song.
      expect(ad0, greaterThan(topOf(tester, cardFor(1))));
    });

    testWidgets('no ads when 10 or fewer songs precede the slot', (
      tester,
    ) async {
      await seed(9);
      await pumpScreen(tester);
      expect(find.textContaining('AD '), findsNothing);
    });

    testWidgets('search re-computes placement from the filtered list', (
      tester,
    ) async {
      await seed(25);
      await pumpScreen(tester);

      // "Song 0" matches Song 01..09 only → 9 songs → no ad.
      await tester.enterText(
        find.byKey(const Key('songSearchField')),
        'Song 0',
      );
      await tester.pumpAndSettle();
      expect(find.byType(SongCard), findsNWidgets(9));
      expect(find.textContaining('AD '), findsNothing);

      // "Song 1" matches Song 10..19 → ad after the 10th (last) match.
      await tester.enterText(
        find.byKey(const Key('songSearchField')),
        'Song 1',
      );
      await tester.pumpAndSettle();
      expect(find.byType(SongCard), findsNWidgets(10));
      expect(find.text('AD 0'), findsOneWidget);
      expect(
        topOf(tester, find.text('AD 0')),
        greaterThan(topOf(tester, cardFor(19))),
      );
    });

    testWidgets('tapping a song after an ad opens that song', (tester) async {
      await seed(25);
      await pumpScreen(tester);

      await tester.tap(find.text(_title(11)));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const Key('songTitleField')),
      );
      expect(field.controller!.text, _title(11));
    });

    testWidgets('long-press after an ad selects exactly that song', (
      tester,
    ) async {
      await seed(25);
      await pumpScreen(tester);

      await tester.longPress(find.text(_title(21)));
      await tester.pumpAndSettle();

      final selected = tester
          .widgetList<SongCard>(find.byType(SongCard))
          .where((c) => c.selected)
          .map((c) => c.song.title);
      expect(selected, [_title(21)]);
    });

    testWidgets('favorite after an ad updates exactly that song', (
      tester,
    ) async {
      await seed(25);
      await pumpScreen(tester);

      await tester.tap(
        find.descendant(
          of: cardFor(12),
          matching: find.byIcon(Icons.favorite_border_rounded),
        ),
      );
      await tester.pumpAndSettle();

      final favorites = (await storage.songs.getAll())
          .where((s) => s.favorite)
          .map((s) => s.title);
      expect(favorites, [_title(12)]);
    });

    testWidgets('disposes the ad source with the screen', (tester) async {
      await seed(12);
      await pumpScreen(tester);
      expect(ads.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(ads.disposed, isTrue);
    });
  });
}
