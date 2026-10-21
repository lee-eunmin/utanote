import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../ads/ads_consent_controller.dart';
import '../ads/list_ad_source.dart';
import '../storage/local_storage.dart';
import '../sync/cloud_sync_controller.dart';
import 'folders_screen.dart';
import 'song_list_screen.dart';
import 'tj_search_screen.dart';
import 'widgets/app_bottom_nav.dart';

/// Application shell: bottom navigation across the three top-level
/// destinations. Each tab keeps its own state via [IndexedStack].
class AppShell extends StatefulWidget {
  final LocalStorage storage;
  final ListAdSourceFactory? songListAdSourceFactory;
  final AdsConsentController? adsConsent;
  final AccountController? account;

  const AppShell({
    super.key,
    required this.storage,
    this.songListAdSourceFactory,
    this.adsConsent,
    this.account,
  });

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

  CloudSyncController? _cloudSync;
  int _seenDataVersion = 0;

  @override
  void initState() {
    super.initState();
    _attachCloudSync();
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account?.cloudSync != widget.account?.cloudSync) {
      _cloudSync?.removeListener(_onCloudSync);
      _attachCloudSync();
    }
  }

  @override
  void dispose() {
    _cloudSync?.removeListener(_onCloudSync);
    super.dispose();
  }

  void _attachCloudSync() {
    _cloudSync = widget.account?.cloudSync;
    _seenDataVersion = _cloudSync?.dataVersion ?? 0;
    _cloudSync?.addListener(_onCloudSync);
  }

  /// A sync/restore changed local songs or folders: every tab reloads from
  /// the repository right away (they all stay alive in the IndexedStack).
  void _onCloudSync() {
    final version = _cloudSync?.dataVersion ?? 0;
    if (version == _seenDataVersion) return;
    _seenDataVersion = version;
    _songListKey.currentState?.refresh();
    _foldersKey.currentState?.refresh();
    _tjSearchKey.currentState?.refreshAddedSongs();
  }

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
      SongListScreen(
        key: _songListKey,
        storage: widget.storage,
        adSourceFactory: widget.songListAdSourceFactory,
        adsConsent: widget.adsConsent,
        account: widget.account,
      ),
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
