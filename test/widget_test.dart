import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/main.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';

void main() {
  testWidgets('creates a song and finds it again by search alias', (
    WidgetTester tester,
  ) async {
    final storage = InMemoryLocalStorage();
    await storage.init();

    await tester.pumpWidget(UtaNoteApp(storage: storage));
    await tester.pumpAndSettle();

    expect(find.text('No songs yet.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Song number *'), '12345');
    await tester.enterText(find.widgetWithText(TextField, 'Title *'), '夜に駆ける');
    await tester.enterText(
      find.widgetWithText(TextField, 'Search aliases (comma-separated)'),
      '밤을 달리다, 요루니카케루',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add song'));
    await tester.pumpAndSettle();

    expect(find.text('夜に駆ける'), findsOneWidget);
    expect(find.textContaining('aliases: 밤을 달리다, 요루니카케루'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(
        TextField,
        'Search (song number / title / artist / alias)',
      ),
      '요루니카케루',
    );
    await tester.pumpAndSettle();

    expect(find.text('夜に駆ける'), findsOneWidget);

    // Simulate reload: a fresh screen backed by the same storage instance
    // should still see the persisted song.
    await tester.pumpWidget(UtaNoteApp(storage: storage));
    await tester.pumpAndSettle();
    expect(find.text('夜に駆ける'), findsOneWidget);

    // Verify the legacy memo field is not exposed anywhere in the UI.
    final songs = await storage.songs.getAll();
    expect(songs.single.memo, isNull);
    expect(find.textContaining('memo', findRichText: true), findsNothing);
  });
}
