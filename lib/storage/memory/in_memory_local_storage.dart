import '../../models/folder.dart';
import '../../models/song.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';

/// Pure-Dart, in-memory [LocalStorage] used by widget/unit tests so they
/// don't depend on platform channels (sqflite) or browser APIs
/// (shared_preferences).
class InMemoryLocalStorage implements LocalStorage {
  @override
  final SongRepository songs = _InMemorySongRepository();

  @override
  final FolderRepository folders = _InMemoryFolderRepository();

  @override
  Future<void> init() async {}
}

class _InMemorySongRepository implements SongRepository {
  final List<Song> _songs = [];
  int _nextId = 1;

  @override
  Future<List<Song>> getAll() async => List.unmodifiable(_songs);

  @override
  Future<Song?> getById(int id) async {
    for (final song in _songs) {
      if (song.id == id) return song;
    }
    return null;
  }

  @override
  Future<Song> create(Song song) async {
    final created = song.copyWith(id: _nextId++);
    _songs.add(created);
    return created;
  }

  @override
  Future<void> update(Song song) async {
    final index = _songs.indexWhere((s) => s.id == song.id);
    if (index != -1) _songs[index] = song;
  }

  @override
  Future<void> delete(int id) async {
    _songs.removeWhere((s) => s.id == id);
  }

  @override
  Future<List<Song>> search(String query) async {
    final needle = query.toLowerCase();
    return _songs.where((song) {
      if (song.songNumber.toLowerCase().contains(needle)) return true;
      if (song.title.toLowerCase().contains(needle)) return true;
      if ((song.artist ?? '').toLowerCase().contains(needle)) return true;
      return song.searchAliases.any(
        (alias) => alias.toLowerCase().contains(needle),
      );
    }).toList();
  }
}

class _InMemoryFolderRepository implements FolderRepository {
  final List<Folder> _folders = [];
  final Map<int, Set<int>> _folderSongs = {};
  int _nextId = 1;

  @override
  Future<List<Folder>> getAll() async => List.unmodifiable(_folders);

  @override
  Future<Folder> create(Folder folder) async {
    final created = folder.copyWith(id: _nextId++);
    _folders.add(created);
    return created;
  }

  @override
  Future<void> update(Folder folder) async {
    final index = _folders.indexWhere((f) => f.id == folder.id);
    if (index != -1) _folders[index] = folder;
  }

  @override
  Future<void> delete(int id) async {
    _folders.removeWhere((f) => f.id == id);
    _folderSongs.remove(id);
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    (_folderSongs[folderId] ??= {}).add(songId);
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    _folderSongs[folderId]?.remove(songId);
  }

  @override
  Future<List<int>> getSongIds(int folderId) async {
    return _folderSongs[folderId]?.toList() ?? [];
  }
}
