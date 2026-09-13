import 'package:flutter/material.dart';

import '../storage/local_storage.dart';
import 'folders_screen.dart';
import 'song_list_screen.dart';
import 'tj_search_screen.dart';
import 'widgets/app_bottom_nav.dart';

/// Application shell: bottom navigation across the three top-level
/// destinations. Each tab keeps its own state via [IndexedStack].
class AppShell extends StatefulWidget {
  final LocalStorage storage;

  const AppShell({super.key, required this.storage});

  @override
  State<AppShell> createState() => _AppShellState();
}

const _tjSearchTabIndex = 2;

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _tjSearchKey = GlobalKey<TjSearchScreenState>();

  void _onTabTap(int i) {
    setState(() => _index = i);
    // The IndexedStack keeps TjSearchScreen alive across tab switches, so a
    // song added/edited from another tab wouldn't otherwise be reflected in
    // its "추가됨" state until a new search ran.
    if (i == _tjSearchTabIndex) {
      _tjSearchKey.currentState?.refreshAddedSongs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      SongListScreen(storage: widget.storage),
      FoldersScreen(storage: widget.storage),
      TjSearchScreen(key: _tjSearchKey, storage: widget.storage),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: AppBottomNav(
        currentIndex: _index,
        onTap: _onTabTap,
      ),
    );
  }
}
