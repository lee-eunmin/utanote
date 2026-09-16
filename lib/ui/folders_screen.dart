import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'folder_detail_screen.dart';
import 'widgets/app_header.dart';
import 'widgets/pickers.dart';
import 'widgets/responsive_center.dart';

/// The "폴더" tab: a responsive two-column grid of folder cards, plus a
/// clear "새 폴더" action. Keeps the existing many-to-many folder_songs
/// data model — this screen only reads/writes via [FolderRepository].
class FoldersScreen extends StatefulWidget {
  final LocalStorage storage;

  const FoldersScreen({super.key, required this.storage});

  @override
  State<FoldersScreen> createState() => FoldersScreenState();
}

class FoldersScreenState extends State<FoldersScreen> {
  List<Folder> _folders = [];
  Map<int, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Re-reads folders and their song counts from the repository. Called on
  /// init and by [AppShell] when this tab becomes visible, so a folder
  /// change made from another tab (e.g. adding/deleting a song) is reflected
  /// without needing a manual refresh.
  Future<void> refresh() => _reload();

  Future<void> _reload() async {
    setState(() => _loading = true);
    final folders = await widget.storage.folders.getAll();
    final counts = <int, int>{};
    for (final folder in folders) {
      final id = folder.id;
      if (id != null) {
        counts[id] = (await widget.storage.folders.getSongIds(id)).length;
      }
    }
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewFolderDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    final now = DateTime.now();
    await widget.storage.folders.create(
      Folder(name: name.trim(), createdAt: now, updatedAt: now),
    );
    await _reload();
  }

  Future<void> _openFolder(Folder folder) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FolderDetailScreen(storage: widget.storage, folder: folder),
      ),
    );
    await _reload();
  }

  /// Long-press management menu for a folder card, mirroring the song list's
  /// long-press flow: a low-chrome bottom sheet with the available actions.
  Future<void> _showFolderMenu(Folder folder) async {
    final action = await showModalBottomSheet<_FolderMenuAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _FolderManagementSheet(folder: folder),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _FolderMenuAction.rename:
        await _renameFolder(folder);
      case _FolderMenuAction.delete:
        await _deleteFolder(folder);
    }
  }

  Future<void> _renameFolder(Folder folder) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameFolderDialog(initialName: folder.name),
    );
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    // Only the name (and updatedAt) changes here — id/createdAt are carried
    // over unchanged, and folder_songs rows key off the folder id, which
    // never changes, so existing memberships are untouched.
    await widget.storage.folders.update(
      folder.copyWith(name: trimmed, updatedAt: DateTime.now()),
    );
    await _reload();
  }

  Future<void> _deleteFolder(Folder folder) async {
    final id = folder.id;
    if (id == null) return;
    final confirmed = await confirmDialog(
      context,
      title: '폴더 삭제',
      message: '이 폴더를 삭제할까요?',
    );
    if (!confirmed) return;
    // FolderRepository.delete only removes the folder row and its
    // folder_songs membership rows — the songs themselves are never touched.
    await widget.storage.folders.delete(id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ResponsiveCenter(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        sliver: SliverToBoxAdapter(
                          child: AppHeader(
                            subtitle: '폴더 ${_folders.length}개',
                            trailing: HeaderIconButton(
                              key: const Key('newFolderButton'),
                              icon: Icons.create_new_folder_rounded,
                              onPressed: _createFolder,
                            ),
                          ),
                        ),
                      ),
                      if (_folders.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyFolders(),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 2.6,
                                ),
                            delegate: SliverChildBuilderDelegate((context, i) {
                              final folder = _folders[i];
                              return _FolderCard(
                                folder: folder,
                                count: _counts[folder.id] ?? 0,
                                onTap: () => _openFolder(folder),
                                onLongPress: () => _showFolderMenu(folder),
                              );
                            }, childCount: _folders.length),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _EmptyFolders extends StatelessWidget {
  const _EmptyFolders();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 40,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: 12),
            Text('폴더가 없습니다.', style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  final Folder folder;
  final int count;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _FolderCard({
    required this.folder,
    required this.count,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final accent = folderAccentColor(folder.name);
    return Material(
      key: Key('folderCard_${folder.id}'),
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.folder_rounded, color: accent, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count곡',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('새 폴더'),
      content: TextField(
        key: const Key('newFolderNameField'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '폴더 이름'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('createFolderButton'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}

enum _FolderMenuAction { rename, delete }

/// Long-press management menu for a folder card: a low-chrome bottom sheet
/// with rename/delete, matching the app's existing bottom-sheet styling
/// (see [showSongEditSheet]) rather than a plain [PopupMenuButton].
class _FolderManagementSheet extends StatelessWidget {
  final Folder folder;

  const _FolderManagementSheet({required this.folder});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.sheetTitle,
              ),
            ),
            const SizedBox(height: 8),
            _FolderMenuTile(
              key: const Key('renameFolderMenuItem'),
              icon: Icons.edit_rounded,
              label: '이름 변경',
              onTap: () => Navigator.of(
                context,
              ).pop(_FolderMenuAction.rename),
            ),
            _FolderMenuTile(
              key: const Key('deleteFolderMenuItem'),
              icon: Icons.delete_rounded,
              label: '삭제',
              destructive: true,
              onTap: () => Navigator.of(
                context,
              ).pop(_FolderMenuAction.delete),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderMenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onTap;

  const _FolderMenuTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.danger : AppColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rename dialog pre-filled with the folder's current name. Only the name
/// changes on save — the folder's id (and therefore its folder_songs
/// memberships) is untouched.
class _RenameFolderDialog extends StatefulWidget {
  final String initialName;

  const _RenameFolderDialog({required this.initialName});

  @override
  State<_RenameFolderDialog> createState() => _RenameFolderDialogState();
}

class _RenameFolderDialogState extends State<_RenameFolderDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('이름 변경'),
      content: TextField(
        key: const Key('renameFolderNameField'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '폴더 이름'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('saveRenameFolderButton'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
