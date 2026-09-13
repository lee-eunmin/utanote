import 'package:flutter/material.dart';

import '../storage/local_storage.dart';
import 'folders_screen.dart';
import 'song_list_screen.dart';
import 'tj_search_placeholder_screen.dart';
import 'widgets/app_bottom_nav.dart';

/// Application shell: bottom navigation across the three top-level
/// destinations. Each tab keeps its own state via [IndexedStack].
class AppShell extends StatefulWidget {
  final LocalStorage storage;

  const AppShell({super.key, required this.storage});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      SongListScreen(storage: widget.storage),
      FoldersScreen(storage: widget.storage),
      const TjSearchPlaceholderScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: AppBottomNav(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}
