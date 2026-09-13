import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/models/tj_search_result.dart';
import 'package:utanote/services/tj_search_service.dart';
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

  testWidgets('does not search until at least 2 characters are entered', (
    tester,
  ) async {
    var callCount = 0;
    final service = _FakeTjSearchService((query) async {
      callCount++;
      return const [];
    });

    await tester.pumpWidget(wrap(TjSearchScreen(service: service)));
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

    await tester.pumpWidget(wrap(TjSearchScreen(service: service)));
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

    await tester.pumpWidget(wrap(TjSearchScreen(service: service)));
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아이유');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(callCount, 1);
  });

  testWidgets('shows an empty state when a search finds nothing', (
    tester,
  ) async {
    final service = _FakeTjSearchService((query) async => const []);

    await tester.pumpWidget(wrap(TjSearchScreen(service: service)));
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

    await tester.pumpWidget(wrap(TjSearchScreen(service: service)));
    await tester.enterText(find.byKey(const Key('tjSearchField')), '아이유');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('TJ 검색 서버에 연결할 수 없어요. 네트워크를 확인해주세요.'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();

    expect(find.text('복구됨'), findsOneWidget);
  });
}
