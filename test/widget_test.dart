import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/main.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';

void main() {
  testWidgets(
    'creates a song via the add sheet and finds it again by search alias',
    (WidgetTester tester) async {
      final storage = InMemoryLocalStorage();
      await storage.init();

      await tester.pumpWidget(UtaNoteApp(storage: storage));
      await tester.pumpAndSettle();

      expect(find.text('노래가 없습니다.'), findsOneWidget);

      // Open the add-song bottom sheet.
      await tester.tap(find.byKey(const Key('addSongButton')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('songNumberField')), '12345');
      await tester.enterText(find.byKey(const Key('songTitleField')), '夜に駆ける');

      // Add two search aliases via the chip input.
      await tester.tap(find.text('+ 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('songAliasField')), '밤을 달리다');
      await tester.tap(find.byKey(const Key('confirmAliasButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+ 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('songAliasField')), '요루니카케루');
      await tester.tap(find.byKey(const Key('confirmAliasButton')));
      await tester.pumpAndSettle();

      expect(find.text('밤을 달리다'), findsOneWidget);
      expect(find.text('요루니카케루'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('saveSongButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saveSongButton')));
      await tester.pumpAndSettle();

      expect(find.text('夜に駆ける'), findsOneWidget);

      // Search by an alias that isn't part of the title/artist/number.
      await tester.enterText(
        find.byKey(const Key('songSearchField')),
        '요루니카케루',
      );
      await tester.pumpAndSettle();

      expect(find.text('夜に駆ける'), findsOneWidget);

      // Simulate reload: a fresh app instance backed by the same storage
      // should still see the persisted song.
      await tester.pumpWidget(UtaNoteApp(storage: storage));
      await tester.pumpAndSettle();
      expect(find.text('夜に駆ける'), findsOneWidget);

      // Verify the legacy memo field is preserved on the model but never
      // surfaced anywhere in the new UI.
      final songs = await storage.songs.getAll();
      expect(songs.single.memo, isNull);
      expect(songs.single.karaokeType, 'TJ');
      expect(find.textContaining('메모'), findsNothing);
    },
  );
}
