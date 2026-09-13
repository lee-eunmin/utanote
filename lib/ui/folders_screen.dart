import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'folder_detail_screen.dart';
import 'widgets/app_header.dart';
import 'widgets/responsive_center.dart';

/// The "폴더" tab: a responsive two-column grid of folder cards, plus a
/// clear "새 폴더" action. Keeps the existing many-to-many folder_songs
/// data model — this screen only reads/writes via [FolderRepository].
class FoldersScreen extends StatefulWidget {
  final LocalStorage storage;

  const FoldersScreen({super.key, required this.storage});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  List<Folder> _folders = [];
  Map<int, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

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

  const _FolderCard({
    required this.folder,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = folderAccentColor(folder.name);
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
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
