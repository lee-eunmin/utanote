import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/models/song.dart';
import 'package:utanote/ui/widgets/song_card.dart';

// Regression test: after a hard refresh on Flutter Web, a saved song row
// could report "BOTTOM OVERFLOWED BY 1.00 PIXELS" (see CLAUDE.md task
// notes). This pinned the row's accent bar to an IntrinsicHeight/stretch
// layout that could mismatch the text column's real final height by a
// fractional pixel. These tests fail (via the uncaught FlutterError a
// RenderFlex overflow reports) if that regresses.
void main() {
  Song buildSong({String? title, String? artist}) {
    return Song(
      karaokeType: 'TJ',
      songNumber: '12345',
      title: title ?? 'Short Title',
      artist: artist ?? 'Short Artist',
      keyType: '남키',
      keyOffset: 2,
      difficulty: '중급',
      practiceStatus: '연습중',
      favorite: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
  }

  testWidgets('renders without overflow for long title/artist in a narrow row', (
    tester,
  ) async {
    final song = buildSong(
      title:
          'A Very Long Song Title That Should Be Ellipsized Nicely Without Overflowing',
      artist: 'An Extremely Long Artist Name That Also Needs To Be Truncated',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 220,
            child: SongCard(song: song, onTap: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final titleFinder = find.byWidgetPredicate(
      (w) => w is Text && w.data == song.title,
    );
    expect(titleFinder, findsOneWidget);
    expect(tester.widget<Text>(titleFinder).overflow, TextOverflow.ellipsis);
  });

  testWidgets('renders without overflow in selection mode', (tester) async {
    final song = buildSong();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SongCard(
            song: song,
            selectionMode: true,
            selected: true,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('renders without overflow with no artist and no difficulty', (
    tester,
  ) async {
    final song = Song(
      karaokeType: 'TJ',
      songNumber: '1',
      title: 'Solo Title',
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SongCard(song: song, onTap: () {})),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
