import '../models/folder.dart';
import '../models/song.dart';
import 'folder_repository.dart';
import 'local_storage.dart';
import 'song_repository.dart';

/// Wraps the storage the UI writes through and calls [onUserDataChanged]
/// after every completed user write: song create/update/delete, folder
/// create/rename/delete, and adding/removing a song to/from a folder.
///
/// Reads (lists, search, folder members) never notify, so browsing,
/// searching, filtering and switching tabs are not sync triggers. Writes
/// that come from the cloud go through the sync layer's own store, not
/// this wrapper, so applying a pull never schedules another sync.
class ObservedLocalStorage implements LocalStorage {
  final LocalStorage inner;
  final void Function() onUserDataChanged;

  late final SongRepository _songs =
      _ObservedSongs(inner, () => onUserDataChanged());
  late final FolderRepository _folders =
      _ObservedFolders(inner, () => onUserDataChanged());

  ObservedLocalStorage(this.inner, {required this.onUserDataChanged});

  @override
  Future<void> init() => inner.init();

  @override
  SongRepository get songs => _songs;

  @override
  FolderRepository get folders => _folders;
}

class _ObservedSongs implements SongRepository {
  final LocalStorage _storage;
  final void Function() _changed;

  _ObservedSongs(this._storage, this._changed);

  SongRepository get _inner => _storage.songs;

  @override
  Future<List<Song>> getAll() => _inner.getAll();

  @override
  Future<Song?> getById(int id) => _inner.getById(id);

  @override
  Future<List<Song>> search(String query) => _inner.search(query);

  @override
  Future<Song> create(Song song) async {
    final created = await _inner.create(song);
    _changed();
    return created;
  }

  @override
  Future<void> update(Song song) async {
    await _inner.update(song);
    _changed();
  }

  @override
  Future<void> delete(int id) async {
    await _inner.delete(id);
    _changed();
  }
}

class _ObservedFolders implements FolderRepository {
  final LocalStorage _storage;
  final void Function() _changed;

  _ObservedFolders(this._storage, this._changed);

  FolderRepository get _inner => _storage.folders;

  @override
  Future<List<Folder>> getAll() => _inner.getAll();

  @override
  Future<List<int>> getSongIds(int folderId) => _inner.getSongIds(folderId);

  @override
  Future<Folder> create(Folder folder) async {
    final created = await _inner.create(folder);
    _changed();
    return created;
  }

  @override
  Future<void> update(Folder folder) async {
    await _inner.update(folder);
    _changed();
  }

  @override
  Future<void> delete(int id) async {
    await _inner.delete(id);
    _changed();
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    await _inner.addSong(folderId, songId);
    _changed();
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    await _inner.removeSong(folderId, songId);
    _changed();
  }
}
