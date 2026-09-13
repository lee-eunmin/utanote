import 'package:flutter/material.dart';

import '../models/song.dart';
import '../storage/local_storage.dart';

/// Temporary, unstyled screen for this stage only.
///
/// It exists purely to prove the storage layer works end-to-end: creating
/// songs, persisting them across reload/restart, saving search aliases, and
/// searching by them (including song_number/title/artist). It intentionally
/// never shows the legacy `memo` field. Real visual design comes later.
class SongListScreen extends StatefulWidget {
  final LocalStorage storage;

  const SongListScreen({super.key, required this.storage});

  @override
  State<SongListScreen> createState() => _SongListScreenState();
}

class _SongListScreenState extends State<SongListScreen> {
  final _songNumberController = TextEditingController();
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();
  final _aliasesController = TextEditingController();
  final _searchController = TextEditingController();

  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _songNumberController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _aliasesController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final query = _searchController.text.trim();
    final songs = query.isEmpty
        ? await widget.storage.songs.getAll()
        : await widget.storage.songs.search(query);
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  List<String> _parseAliases(String raw) {
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _addSong() async {
    final songNumber = _songNumberController.text.trim();
    final title = _titleController.text.trim();
    if (songNumber.isEmpty || title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song number and title are required.')),
      );
      return;
    }
    final now = DateTime.now();
    final song = Song(
      karaokeType: 'TJ',
      songNumber: songNumber,
      title: title,
      artist: _artistController.text.trim().isEmpty
          ? null
          : _artistController.text.trim(),
      searchAliases: _parseAliases(_aliasesController.text),
      createdAt: now,
      updatedAt: now,
    );
    await widget.storage.songs.create(song);
    _songNumberController.clear();
    _titleController.clear();
    _artistController.clear();
    _aliasesController.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UtaNote (temporary test screen)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add song', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _songNumberController,
                    decoration: const InputDecoration(
                      labelText: 'Song number *',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Title *'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _artistController,
              decoration: const InputDecoration(labelText: 'Artist'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _aliasesController,
              decoration: const InputDecoration(
                labelText: 'Search aliases (comma-separated)',
                hintText: 'e.g. 밤을 달리다, 요루니카케루',
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _addSong,
              child: const Text('Add song'),
            ),
            const Divider(height: 32),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search (song number / title / artist / alias)',
                suffixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => _reload(),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Expanded(
                child: _songs.isEmpty
                    ? const Center(child: Text('No songs yet.'))
                    : ListView.builder(
                        itemCount: _songs.length,
                        itemBuilder: (context, index) {
                          final song = _songs[index];
                          final subtitleParts = [
                            song.songNumber,
                            if (song.artist != null) song.artist!,
                            if (song.searchAliases.isNotEmpty)
                              'aliases: ${song.searchAliases.join(", ")}',
                          ];
                          return ListTile(
                            title: Text(song.title),
                            subtitle: Text(subtitleParts.join(' · ')),
                          );
                        },
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
