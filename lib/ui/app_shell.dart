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

const _songListTabIndex = 0;
const _foldersTabIndex = 1;
const _tjSearchTabIndex = 2;

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _songListKey = GlobalKey<SongListScreenState>();
  final _foldersKey = GlobalKey<FoldersScreenState>();
  final _tjSearchKey = GlobalKey<TjSearchScreenState>();

  void _onTabTap(int i) {
    setState(() => _index = i);
    // The IndexedStack keeps every tab's screen alive across switches, so
    // each top-level screen must explicitly refresh from the repository
    // when it becomes visible again — otherwise data changed from another
    // tab (a song added via TJ 검색, a folder membership change, a
    // deletion, ...) wouldn't show up until the app restarts.
    switch (i) {
      case _songListTabIndex:
        _songListKey.currentState?.refresh();
      case _foldersTabIndex:
        _foldersKey.currentState?.refresh();
      case _tjSearchTabIndex:
        _tjSearchKey.currentState?.refreshAddedSongs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      SongListScreen(key: _songListKey, storage: widget.storage),
      FoldersScreen(key: _foldersKey, storage: widget.storage),
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
