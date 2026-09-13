import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../models/song.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'song_bulk_actions.dart';
import 'song_edit_sheet.dart';
import 'widgets/animated_song_list.dart';
import 'widgets/pickers.dart';
import 'widgets/responsive_center.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/song_card.dart';

/// Detail view for a single folder: back navigation, name, song count,
/// search within the folder, and the folder's songs. Multi-select mirrors
/// the song list's action bar, scoped to this folder's membership.
class FolderDetailScreen extends StatefulWidget {
  final LocalStorage storage;
  final Folder folder;

  const FolderDetailScreen({
    super.key,
    required this.storage,
    required this.folder,
  });

  @override
  State<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends State<FolderDetailScreen> {
  final _searchController = TextEditingController();

  List<Song> _allInFolder = [];
  List<Song> _displayed = [];
  bool _loading = true;
  final Set<int> _selected = {};

  bool get _selectionMode => _selected.isNotEmpty;
  int? get _folderId => widget.folder.id;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final folderId = _folderId;
    final ids = folderId == null
        ? <int>[]
        : await widget.storage.folders.getSongIds(folderId);
    final idSet = ids.toSet();
    final all = await widget.storage.songs.getAll();
    final songs = all.where((s) => idSet.contains(s.id)).toList();
    if (!mounted) return;
    setState(() {
      _allInFolder = songs;
      _displayed = _applySearch(songs);
      _loading = false;
    });
  }

  List<Song> _applySearch(List<Song> songs) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return songs;
    return songs.where((s) {
      if (s.songNumber.toLowerCase().contains(query)) return true;
      if (s.title.toLowerCase().contains(query)) return true;
      if ((s.artist ?? '').toLowerCase().contains(query)) return true;
      return s.searchAliases.any((a) => a.toLowerCase().contains(query));
    }).toList();
  }

  void _onSearchChanged() {
    setState(() => _displayed = _applySearch(_allInFolder));
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

  Future<void> _bulkRemoveFromFolder() async {
    final folderId = _folderId;
    if (folderId == null) return;
    await removeSongsFromFolder(widget.storage, _selected, folderId);
    _clearSelection();
    await _reload();
  }

  Future<void> _bulkChangeStatus() async {
    final status = await pickStatusDialog(context);
    if (status == null) return;
    await setPracticeStatusForSongs(
      widget.storage,
      _allInFolder,
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
      message: '선택한 ${_selected.length}곡을 완전히 삭제할까요?',
    );
    if (!confirmed) return;
    await deleteSongs(widget.storage, _selected);
    _clearSelection();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.folder.name,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 2),
            Text('${_allInFolder.length}곡', style: AppTextStyles.meta),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: AppColors.hairline),
        ),
      ),
      body: ResponsiveCenter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            children: [
              TextField(
                key: const Key('folderSearchField'),
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '폴더 내 검색',
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                ),
                onChanged: (_) => _onSearchChanged(),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedSongList(
                        songs: _displayed,
                        empty: const Center(child: Text('이 폴더에 노래가 없습니다.')),
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
                                showSongEditSheet(
                                  context: context,
                                  storage: widget.storage,
                                  existing: song,
                                ).then((_) => _reload());
                              }
                            },
                            onLongPress: () => _toggleSelected(song),
                            onFavoriteToggle: (fav) async {
                              await widget.storage.songs.update(
                                song.copyWith(
                                  favorite: fav,
                                  updatedAt: DateTime.now(),
                                ),
                              );
                              await _reload();
                            },
                          );
                        },
                      ),
              ),
              SelectionActionBar(
                visible: _selectionMode,
                count: _selected.length,
                onClose: _clearSelection,
                actions: [
                  SelectionAction(
                    icon: Icons.folder_off_rounded,
                    label: '폴더에서 제거',
                    onTap: _bulkRemoveFromFolder,
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
    );
  }
}
