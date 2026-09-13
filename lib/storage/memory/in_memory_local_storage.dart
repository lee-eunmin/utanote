import '../../models/folder.dart';
import '../../models/song.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';

/// Pure-Dart, in-memory [LocalStorage] used by tests so they don't depend on
/// platform channels (sqflite) or browser APIs (shared_preferences).
///
/// The song and folder repositories share a single [_InMemoryStore], the
/// same way the Android (sqflite) and Web (shared_preferences)
/// implementations share one underlying database/prefs instance — this is
/// what lets deleting a song also clean up its folder_songs membership.
class InMemoryLocalStorage implements LocalStorage {
  final _store = _InMemoryStore();

  @override
  late final SongRepository songs = _InMemorySongRepository(_store);

  @override
  late final FolderRepository folders = _InMemoryFolderRepository(_store);

  @override
  Future<void> init() async {}
}

class _InMemoryStore {
  final List<Song> songs = [];
  int nextSongId = 1;

  final List<Folder> folders = [];
  int nextFolderId = 1;

  /// folder_id -> song_ids.
  final Map<int, Set<int>> folderSongs = {};
}

class _InMemorySongRepository implements SongRepository {
  final _InMemoryStore _store;

  _InMemorySongRepository(this._store);

  @override
  Future<List<Song>> getAll() async {
    final songs = List.of(_store.songs)..sort(compareSongsNewestFirst);
    return List.unmodifiable(songs);
  }

  @override
  Future<Song?> getById(int id) async {
    for (final song in _store.songs) {
      if (song.id == id) return song;
    }
    return null;
  }

  @override
  Future<Song> create(Song song) async {
    final created = song.copyWith(id: _store.nextSongId++);
    _store.songs.add(created);
    return created;
  }

  @override
  Future<void> update(Song song) async {
    final index = _store.songs.indexWhere((s) => s.id == song.id);
    if (index != -1) _store.songs[index] = song;
  }

  @override
  Future<void> delete(int id) async {
    _store.songs.removeWhere((s) => s.id == id);
    // Also drop this song's folder_songs membership, or folder counts keep
    // counting a song that no longer exists.
    for (final songIds in _store.folderSongs.values) {
      songIds.remove(id);
    }
  }

  @override
  Future<List<Song>> search(String query) async {
    final needle = query.toLowerCase();
    final songs = await getAll();
    return songs.where((song) {
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
  final _InMemoryStore _store;

  _InMemoryFolderRepository(this._store);

  @override
  Future<List<Folder>> getAll() async => List.unmodifiable(_store.folders);

  @override
  Future<Folder> create(Folder folder) async {
    final created = folder.copyWith(id: _store.nextFolderId++);
    _store.folders.add(created);
    return created;
  }

  @override
  Future<void> update(Folder folder) async {
    final index = _store.folders.indexWhere((f) => f.id == folder.id);
    if (index != -1) _store.folders[index] = folder;
  }

  @override
  Future<void> delete(int id) async {
    _store.folders.removeWhere((f) => f.id == id);
    _store.folderSongs.remove(id);
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    (_store.folderSongs[folderId] ??= {}).add(songId);
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    _store.folderSongs[folderId]?.remove(songId);
  }

  @override
  Future<List<int>> getSongIds(int folderId) async {
    // Filtered against currently-existing songs so a folder_songs entry
    // left over from a song deletion never counts as a member.
    final ids = _store.folderSongs[folderId];
    if (ids == null || ids.isEmpty) return const [];
    final existingIds = _store.songs.map((s) => s.id).whereType<int>().toSet();
    return ids.where(existingIds.contains).toList();
  }
}
