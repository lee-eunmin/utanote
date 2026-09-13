import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/ui/app_shell.dart';

/// Bug 1: AppShell's IndexedStack keeps every tab's screen alive, so each
/// top-level screen must explicitly refresh when its tab becomes active
/// again instead of only loading once in initState.
void main() {
  Future<Song> addSong(InMemoryLocalStorage storage, String title) {
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

  testWidgets(
    '노래 목록 tab shows a song added while another tab was active',
    (tester) async {
      final storage = InMemoryLocalStorage();
      await storage.init();

      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();
      expect(find.text('노래가 없습니다.'), findsOneWidget);

      // Switch away from 노래 목록 so its IndexedStack entry goes offstage
      // but stays alive, then add a song directly through the repository —
      // standing in for "added via TJ 검색", which also just calls
      // storage.songs.create under the hood.
      await tester.tap(find.byKey(const Key('navTab2')));
      await tester.pumpAndSettle();
      await addSong(storage, '夜に駆ける');

      // Switching back to 노래 목록 must reload from the repository rather
      // than showing the stale (empty) state it had before we left.
      await tester.tap(find.byKey(const Key('navTab0')));
      await tester.pumpAndSettle();

      expect(find.text('夜に駆ける'), findsOneWidget);
      expect(find.text('노래가 없습니다.'), findsNothing);
    },
  );

  testWidgets(
    '폴더 tab reflects a folder/count change made while another tab was active',
    (tester) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final now = DateTime.now();
      final folder = await storage.folders.create(
        Folder(name: '연습곡', createdAt: now, updatedAt: now),
      );

      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();

      // View 폴더 once so its screen is built and alive in the IndexedStack.
      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();
      expect(find.text('0곡'), findsOneWidget);

      // Leave 폴더, change its membership from "elsewhere", then come back.
      await tester.tap(find.byKey(const Key('navTab0')));
      await tester.pumpAndSettle();
      final song = await addSong(storage, '노래1');
      await storage.folders.addSong(folder.id!, song.id!);

      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();
      expect(find.text('1곡'), findsOneWidget);
      expect(find.text('0곡'), findsNothing);

      // And the reverse direction: delete the song from elsewhere, confirm
      // the folder count drops back to 0 on the next activation.
      await tester.tap(find.byKey(const Key('navTab0')));
      await tester.pumpAndSettle();
      await storage.songs.delete(song.id!);

      await tester.tap(find.byKey(const Key('navTab1')));
      await tester.pumpAndSettle();
      expect(find.text('0곡'), findsOneWidget);
    },
  );
}
