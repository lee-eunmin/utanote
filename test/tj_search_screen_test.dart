import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/main.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/models/tj_search_result.dart';
import 'package:utanote/services/tj_search_service.dart';
import 'package:utanote/storage/local_storage.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/ui/tj_search_screen.dart';

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
  Widget wrap(Widget child) => MaterialApp(home: child);

  Future<LocalStorage> newStorage() async {
    final storage = InMemoryLocalStorage();
    await storage.init();
    return storage;
  }

  testWidgets('does not search until at least 2 characters are entered', (
    tester,
  ) async {
    var callCount = 0;
    final service = _FakeTjSearchService((query) async {
      callCount++;
      return const [];
    });

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아');
    await tester.pump(const Duration(milliseconds: 500));

    expect(callCount, 0);
    expect(find.text('TJ 반주곡을 검색해보세요'), findsOneWidget);
  });

  testWidgets('debounces and then shows results for a valid query', (
    tester,
  ) async {
    var callCount = 0;
    final service = _FakeTjSearchService((query) async {
      callCount++;
      return const [
        TjSearchResult(songNumber: '28834', title: 'さよならエレジー', artist: '菅田将暉'),
      ];
    });

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '菅田');

    // Not yet — still inside the debounce window.
    await tester.pump(const Duration(milliseconds: 200));
    expect(callCount, 0);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(callCount, 1);
    expect(find.text('28834'), findsOneWidget);
    expect(find.text('さよならエレジー'), findsOneWidget);
    expect(find.text('菅田将暉'), findsOneWidget);
  });

  testWidgets('Enter key submits immediately, skipping the debounce', (
    tester,
  ) async {
    var callCount = 0;
    final service = _FakeTjSearchService((query) async {
      callCount++;
      return const [];
    });

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아이유');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(callCount, 1);
  });

  testWidgets('shows an empty state when a search finds nothing', (
    tester,
  ) async {
    final service = _FakeTjSearchService((query) async => const []);

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아이유');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('검색 결과가 없어요'), findsOneWidget);
  });

  testWidgets('shows an error state with a working retry action', (
    tester,
  ) async {
    var attempt = 0;
    final service = _FakeTjSearchService((query) async {
      attempt++;
      if (attempt == 1) {
        throw const TjSearchException('TJ 검색 서버에 연결할 수 없어요. 네트워크를 확인해주세요.');
      }
      return const [
        TjSearchResult(songNumber: '1', title: '복구됨', artist: '테스트'),
      ];
    });

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아이유');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('TJ 검색 서버에 연결할 수 없어요. 네트워크를 확인해주세요.'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();

    expect(find.text('복구됨'), findsOneWidget);
  });

  testWidgets('tapping + opens the add form prefilled from the TJ result', (
    tester,
  ) async {
    final service = _FakeTjSearchService(
      (query) async => const [
        TjSearchResult(songNumber: '28834', title: 'さよならエレジー', artist: '菅田将暉'),
      ],
    );

    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await tester.enterText(find.byKey(const Key('tjSearchField')), '菅田');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tjAdd_28834')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('songNumberField')))
          .controller!
          .text,
      '28834',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('songTitleField')))
          .controller!
          .text,
      'さよならエレジー',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('songArtistField')))
          .controller!
          .text,
      '菅田将暉',
    );
    // karaoke_type selection must not be exposed in the UI.
    expect(find.text('TJ'), findsNothing);
    expect(find.text('KY'), findsNothing);
  });

  testWidgets(
    'saving adds the song through the normal repository and updates the tile',
    (tester) async {
      final storage = await newStorage();
      final service = _FakeTjSearchService(
        (query) async => const [
          TjSearchResult(songNumber: '28834', title: 'さよならエレジー', artist: '菅田将暉'),
        ],
      );

      await tester.pumpWidget(wrap(TjSearchScreen(storage: storage, service: service)));
      await tester.enterText(find.byKey(const Key('tjSearchField')), '菅田');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tjAdd_28834')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
      await tester.tap(find.byKey(const Key('saveSongButton')));
      await tester.pumpAndSettle();

      final saved = await storage.songs.getAll();
      expect(saved.length, 1);
      expect(saved.single.karaokeType, 'TJ');
      expect(saved.single.songNumber, '28834');
      expect(saved.single.title, 'さよならエレジー');
      expect(saved.single.artist, '菅田将暉');

      // The result tile now shows the disabled "추가됨" state.
      expect(find.byKey(const Key('tjAdded_28834')), findsOneWidget);
      expect(find.byKey(const Key('tjAdd_28834')), findsNothing);
    },
  );

  // --- MR badge -----------------------------------------------------------

  const mrResults = [
    TjSearchResult(songNumber: '33393', title: '좋은 날', artist: 'IU'),
    TjSearchResult(
      songNumber: '62239',
      title: '좋은 날',
      artist: 'IU',
      isMr: true,
    ),
  ];

  Future<void> searchFor(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const Key('tjSearchField')), query);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('MR badge only on the MR version; both versions listed', (
    tester,
  ) async {
    final service = _FakeTjSearchService((query) async => mrResults);
    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: await newStorage(), service: service)),
    );
    await searchFor(tester, '좋은날');

    expect(find.text('33393'), findsOneWidget);
    expect(find.text('62239'), findsOneWidget);
    expect(find.text('좋은 날'), findsNWidgets(2));
    expect(find.byKey(const Key('tjMrBadge_62239')), findsOneWidget);
    expect(find.byKey(const Key('tjMrBadge_33393')), findsNothing);
    expect(find.text('MR'), findsOneWidget);
    // The badge sits right after the title, on the title's line.
    final title = tester.getRect(find.text('좋은 날').last);
    final badge = tester.getRect(find.byKey(const Key('tjMrBadge_62239')));
    expect(badge.left, greaterThanOrEqualTo(title.right));
    expect(badge.center.dy, closeTo(title.center.dy, 2));
    // Both keep their "+".
    expect(find.byKey(const Key('tjAdd_33393')), findsOneWidget);
    expect(find.byKey(const Key('tjAdd_62239')), findsOneWidget);
  });

  testWidgets('adding the MR version: same add flow, MR is not stored', (
    tester,
  ) async {
    final storage = await newStorage();
    final service = _FakeTjSearchService((query) async => mrResults);
    await tester.pumpWidget(
      wrap(TjSearchScreen(storage: storage, service: service)),
    );
    await searchFor(tester, '좋은날');

    await tester.tap(find.byKey(const Key('tjAdd_62239')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('songTitleField')))
          .controller!
          .text,
      '좋은 날',
    );
    await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
    await tester.tap(find.byKey(const Key('saveSongButton')));
    await tester.pumpAndSettle();

    final saved = await storage.songs.getAll();
    expect(saved.single.songNumber, '62239');
    expect(saved.single.title, '좋은 날');
    // Only the added one switches to "추가됨"; the badge stays.
    expect(find.byKey(const Key('tjAdded_62239')), findsOneWidget);
    expect(find.byKey(const Key('tjAdd_33393')), findsOneWidget);
    expect(find.byKey(const Key('tjMrBadge_62239')), findsOneWidget);
  });

  testWidgets('the song list never shows an MR badge (TJ search only)', (
    tester,
  ) async {
    final storage = await newStorage();
    final now = DateTime.now();
    // The MR version's number, added earlier from TJ search.
    await storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '62239',
        title: '좋은 날',
        artist: 'IU',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await tester.pumpWidget(UtaNoteApp(storage: storage));
    await tester.pumpAndSettle();
    expect(find.text('좋은 날'), findsOneWidget);
    expect(find.text('MR'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('tjMrBadge_'),
      ),
      findsNothing,
    );
  });

  for (final width in [320.0, 375.0, 390.0]) {
    testWidgets('${width.toInt()}pt: long MR title + "추가됨" do not overflow',
        (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = await newStorage();
      final now = DateTime.now();
      await storage.songs.create(
        Song(
          karaokeType: 'TJ',
          songNumber: '62585',
          title: '좋은 날(미스터션샤인OST)',
          artist: '멜로망스',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final service = _FakeTjSearchService(
        (query) async => const [
          TjSearchResult(
            songNumber: '62585',
            title: '좋은 날(미스터션샤인OST) 아주 긴 제목이 들어가는 경우를 위한 테스트',
            artist: '멜로망스 그리고 아주 긴 가수 이름이 이어지는 경우',
            isMr: true,
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(TjSearchScreen(storage: storage, service: service)),
      );
      await searchFor(tester, '좋은날');

      expect(tester.takeException(), isNull);
      final badge = tester.getRect(find.byKey(const Key('tjMrBadge_62585')));
      final added = tester.getRect(find.byKey(const Key('tjAdded_62585')));
      // The title gives way; the badge stays whole, left of "추가됨".
      expect(badge.width, greaterThan(16));
      expect(badge.right, lessThanOrEqualTo(added.left));
      expect(added.right, lessThanOrEqualTo(width));
    });
  }

  testWidgets('a TJ number that is already saved cannot be added twice', (
    tester,
  ) async {
    final storage = await newStorage();
    final now = DateTime.now();
    await storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '28834',
        title: '기존 제목',
        artist: '기존 아티스트',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final service = _FakeTjSearchService(
      (query) async => const [
        TjSearchResult(songNumber: '28834', title: 'さよならエレジー', artist: '菅田将暉'),
      ],
    );

    await tester.pumpWidget(wrap(TjSearchScreen(storage: storage, service: service)));
    await tester.enterText(find.byKey(const Key('tjSearchField')), '菅田');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Already shows as added, with no tappable "+" affordance.
    expect(find.byKey(const Key('tjAdded_28834')), findsOneWidget);
    expect(find.byKey(const Key('tjAdd_28834')), findsNothing);
    expect(find.text('추가됨'), findsOneWidget);

    // No add form should be reachable, so the existing data can't be
    // overwritten by the TJ result's title/artist.
    expect(find.byKey(const Key('songNumberField')), findsNothing);

    final all = await storage.songs.getAll();
    expect(all.length, 1);
    expect(all.single.title, '기존 제목');
    expect(all.single.artist, '기존 아티스트');
  });
}
