import 'dart:math';

import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../ads/ads_consent_controller.dart';
import '../ads/list_ad_source.dart';
import '../models/song.dart';
import '../models/song_options.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'song_bulk_actions.dart';
import 'song_edit_sheet.dart';
import 'song_shuffle.dart';
import 'song_status_filter.dart';
import 'widgets/account_button.dart';
import 'widgets/animated_song_list.dart';
import 'widgets/app_header.dart';
import 'widgets/filter_chip_bar.dart';
import 'widgets/pickers.dart';
import 'widgets/privacy_options_button.dart';
import 'widgets/responsive_center.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/song_card.dart';
import 'widgets/songbook_account_card.dart';

const _filterAll = kSongFilterAll;
const _filterFavorite = '즐겨찾기';
const _filterOptions = [
  _filterAll,
  _filterFavorite,
  ...kPracticeStatusFilterOrder,
];

/// The main "노래 목록" tab: search, filter chips, and the animated list of
/// songs. Never reads or exposes [Song.memo]; search matches
/// song_number/title/artist/searchAliases via [SongRepository.search].
class SongListScreen extends StatefulWidget {
  final LocalStorage storage;

  /// Supplies in-list native ads (Android/iOS). Null → no ads.
  final ListAdSourceFactory? adSourceFactory;

  /// Ad consent state (Android/iOS); drives the privacy settings entry.
  final AdsConsentController? adsConsent;

  /// Google sign-in state (Android only). Null → no account entry.
  final AccountController? account;

  /// Random source for "랜덤 정렬". Tests pass a seeded one; null → a new
  /// unseeded [Random] per screen.
  final Random? shuffleRandom;

  const SongListScreen({
    super.key,
    required this.storage,
    this.adSourceFactory,
    this.adsConsent,
    this.account,
    this.shuffleRandom,
  });

  @override
  State<SongListScreen> createState() => SongListScreenState();
}

class SongListScreenState extends State<SongListScreen> {
  final _searchController = TextEditingController();

  List<Song> _allMatching = [];
  List<Song> _displayed = [];
  String _filter = _filterAll;
  bool _loading = true;
  int _totalCount = 0;
  final Set<int> _selected = {};
  ListAdSource? _ads;

  /// Current "랜덤 정렬", or null for the default 곡 추가순. Lives only in
  /// this State (never persisted), so every app start begins unshuffled.
  SongShuffleOrder? _shuffle;
  late final Random _shuffleRandom;

  bool get _selectionMode => _selected.isNotEmpty;

  /// 0 = default order; increments on every random-button tap.
  @visibleForTesting
  int get shuffleGeneration => _shuffle?.generation ?? 0;

  @override
  void initState() {
    super.initState();
    _shuffleRandom = widget.shuffleRandom ?? Random();
    _ads = widget.adSourceFactory?.call();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _ads?.dispose();
    super.dispose();
  }

  /// Re-reads songs from the repository. Called on init, after local edits,
  /// and by [AppShell] when this tab becomes visible, so a song added or
  /// changed from another tab (e.g. TJ 검색) is reflected without needing a
  /// manual refresh.
  Future<void> refresh() => _reload();

  Future<void> _reload() async {
    final query = _searchController.text.trim();
    final all = await widget.storage.songs.getAll();
    final base = query.isEmpty ? all : await widget.storage.songs.search(query);
    if (!mounted) return;
    setState(() {
      _allMatching = base;
      _displayed = _arrange(base);
      _totalCount = all.length;
      _loading = false;
    });
  }

  List<Song> _applyFilter(List<Song> songs) {
    switch (_filter) {
      case _filterFavorite:
        return songs.where((s) => s.favorite).toList();
      case _filterAll:
        return songs;
      default:
        return filterSongsByPracticeStatus(songs, _filter);
    }
  }

  /// search result → filter → random order (if active). The random step
  /// works on a copy, never on [_allMatching] itself.
  List<Song> _arrange(List<Song> searched) {
    final filtered = _applyFilter(searched);
    return _shuffle?.apply(filtered) ?? filtered;
  }

  void _onFilterChanged(String filter) {
    setState(() {
      _filter = filter;
      _displayed = _arrange(_allMatching);
    });
  }

  void _onShufflePressed() {
    setState(() {
      _shuffle = SongShuffleOrder(
        generation: shuffleGeneration + 1,
        random: _shuffleRandom,
      );
      _displayed = _arrange(_allMatching);
    });
  }

  Future<void> _toggleFavorite(Song song) async {
    await widget.storage.songs.update(
      song.copyWith(favorite: !song.favorite, updatedAt: DateTime.now()),
    );
    await _reload();
  }

  void _toggleSelected(Song song) {
    final id = song.id;
    if (id == null) return;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _openEditor({Song? existing}) async {
    await showSongEditSheet(
      context: context,
      storage: widget.storage,
      existing: existing,
    );
    await _reload();
  }

  Future<void> _bulkAddToFolder() async {
    final folders = await widget.storage.folders.getAll();
    if (!mounted) return;
    final folderId = await pickFolderDialog(context, folders);
    if (folderId == null) return;
    await addSongsToFolder(widget.storage, _selected, folderId);
    _clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('폴더에 추가했습니다.')));
    }
  }

  Future<void> _bulkChangeStatus() async {
    final status = await pickStatusDialog(context);
    if (status == null) return;
    await setPracticeStatusForSongs(
      widget.storage,
      _allMatching,
      _selected,
      status,
    );
    _clearSelection();
    await _reload();
  }

  Future<void> _bulkDelete() async {
    final confirmed = await confirmDialog(
      context,
      title: '노래 삭제',
      message: '선택한 ${_selected.length}곡을 삭제할까요?',
    );
    if (!confirmed) return;
    await deleteSongs(widget.storage, _selected);
    _clearSelection();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ResponsiveCenter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                AppHeader(
                  subtitle: '$_totalCount곡',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AccountButton(
                        account: widget.account,
                        onSheetClosed: _reload,
                      ),
                      PrivacyOptionsButton(consent: widget.adsConsent),
                      HeaderIconButton(
                        key: const Key('addSongButton'),
                        icon: Icons.add_rounded,
                        onPressed: () => _openEditor(),
                      ),
                    ],
                  ),
                ),
                TextField(
                  key: const Key('songSearchField'),
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: '노래 · 가수 · 번호 검색',
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                  ),
                  onChanged: (_) => _reload(),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FilterChipBar(
                        options: _filterOptions,
                        selected: _filter,
                        onSelected: _onFilterChanged,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ShuffleButton(
                      active: _shuffle != null,
                      onPressed: _onShufflePressed,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : AnimatedSongList(
                          songs: _displayed,
                          adBuilder: _ads?.buildAd,
                          empty: const Center(child: Text('노래가 없습니다.')),
                          itemBuilder: (context, song) {
                            final selected =
                                song.id != null && _selected.contains(song.id);
                            return SongCard(
                              song: song,
                              selectionMode: _selectionMode,
                              selected: selected,
                              onTap: () {
                                if (_selectionMode) {
                                  _toggleSelected(song);
                                } else {
                                  _openEditor(existing: song);
                                }
                              },
                              onLongPress: () => _toggleSelected(song),
                              onFavoriteToggle: (_) => _toggleFavorite(song),
                            );
                          },
                        ),
                ),
                // No songs at all (new install, reinstall, everything
                // deleted): keep sign-in / restore / backup reachable.
                if (!_loading && _totalCount == 0)
                  SongbookAccountCard(account: widget.account),
                SelectionActionBar(
                  visible: _selectionMode,
                  count: _selected.length,
                  onClose: _clearSelection,
                  actions: [
                    SelectionAction(
                      icon: Icons.create_new_folder_rounded,
                      label: '폴더에 추가',
                      onTap: _bulkAddToFolder,
                    ),
                    SelectionAction(
                      icon: Icons.flag_rounded,
                      label: '상태 변경',
                      onTap: _bulkChangeStatus,
                    ),
                    SelectionAction(
                      icon: Icons.delete_rounded,
                      label: '삭제',
                      destructive: true,
                      onTap: _bulkDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact "랜덤 정렬" button at the right end of the filter row. Every tap
/// creates a new random order; tinted while a random order is active.
class _ShuffleButton extends StatelessWidget {
  final bool active;
  final VoidCallback onPressed;

  const _ShuffleButton({required this.active, required this.onPressed});

  static const double _size = 28;

  /// [FilterChipBar] centers "text + 6px gap + 2px underline" in its row,
  /// so the label text sits (6 + 2) / 2 = 4px above the row's center. Shift
  /// the button by the same amount so its center lines up with the text.
  /// Paint/hit-test only: the row's layout (and its width) is unchanged.
  static const double _textCenterOffset = -(6 + 2) / 2;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, _textCenterOffset),
      child: Tooltip(
        message: '랜덤 정렬',
        child: Material(
          key: const Key('shuffleSongsButton'),
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: _size,
              child: Center(
                child: Icon(
                  Icons.shuffle_rounded,
                  size: 17,
                  color: active ? AppColors.accent : AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
