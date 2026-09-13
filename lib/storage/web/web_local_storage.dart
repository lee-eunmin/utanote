import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/folder.dart';
import '../../models/song.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';

/// Keys in browser localStorage (via shared_preferences' web implementation).
/// Data here is per-browser/per-origin only — there is no server, login, or
/// sync, matching the "no remote user database" requirement for Web.
const String _songsKey = 'utanote.songs.v1';
const String _foldersKey = 'utanote.folders.v1';
const String _folderSongsKey = 'utanote.folder_songs.v1';

/// folder_id -> list of song_ids, stored as a JSON map of string lists.
/// Shared by [_WebSongRepository] (to clean up on song deletion) and
/// [_WebFolderRepository] (the primary owner), since both need to read and
/// write the same underlying localStorage key.
Map<String, List<int>> _readFolderSongsMap(SharedPreferences prefs) {
  final raw = prefs.getString(_folderSongsKey);
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded.map(
    (key, value) => MapEntry(key, (value as List).cast<int>()),
  );
}

Future<void> _writeFolderSongsMap(
  SharedPreferences prefs,
  Map<String, List<int>> map,
) async {
  await prefs.setString(_folderSongsKey, jsonEncode(map));
}

Set<int> _readExistingSongIds(SharedPreferences prefs) {
  final raw = prefs.getString(_songsKey);
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw) as List<dynamic>;
  return decoded
      .map((e) => (e as Map<String, dynamic>)['id'] as int?)
      .whereType<int>()
      .toSet();
}

/// Removes folder_songs entries left over from song deletions that predate
/// this fix (a song was deleted without also deleting its folder_songs
/// entry, leaving folder counts overstated). Only ever drops references to
/// song ids that no longer exist — never touches songs or folders
/// themselves. Cheap and safe to re-run on every init.
Future<void> _cleanupOrphanedFolderSongs(SharedPreferences prefs) async {
  final folderSongs = _readFolderSongsMap(prefs);
  final existingIds = _readExistingSongIds(prefs);
  var changed = false;
  for (final entry in folderSongs.entries) {
    final before = entry.value.length;
    entry.value.removeWhere((id) => !existingIds.contains(id));
    if (entry.value.length != before) changed = true;
  }
  if (changed) {
    await _writeFolderSongsMap(prefs, folderSongs);
  }
}

LocalStorage createLocalStorage() => WebLocalStorage();

class WebLocalStorage implements LocalStorage {
  SharedPreferences? _prefs;
  SongRepository? _songs;
  FolderRepository? _folders;

  @override
  Future<void> init() async {
    if (_prefs != null) return;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    _songs = _WebSongRepository(prefs);
    _folders = _WebFolderRepository(prefs);
    await _cleanupOrphanedFolderSongs(prefs);
  }

  @override
  SongRepository get songs {
    final repo = _songs;
    if (repo == null) {
      throw StateError('WebLocalStorage.init() must be awaited first.');
    }
    return repo;
  }

  @override
  FolderRepository get folders {
    final repo = _folders;
    if (repo == null) {
      throw StateError('WebLocalStorage.init() must be awaited first.');
    }
    return repo;
  }
}

class _WebSongRepository implements SongRepository {
  final SharedPreferences _prefs;

  _WebSongRepository(this._prefs);

  List<Song> _readAll() {
    final raw = _prefs.getString(_songsKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => Song.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _writeAll(List<Song> songs) async {
    final encoded = jsonEncode(songs.map((s) => s.toMap()).toList());
    await _prefs.setString(_songsKey, encoded);
  }

  @override
  Future<List<Song>> getAll() async {
    final songs = _readAll();
    songs.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return songs;
  }

  @override
  Future<Song?> getById(int id) async {
    final songs = _readAll();
    for (final song in songs) {
      if (song.id == id) return song;
    }
    return null;
  }

  @override
  Future<Song> create(Song song) async {
    final songs = _readAll();
    final nextId = songs.isEmpty
        ? 1
        : songs.map((s) => s.id ?? 0).reduce((a, b) => a > b ? a : b) + 1;
    final created = song.copyWith(id: nextId);
    songs.add(created);
    await _writeAll(songs);
    return created;
  }

  @override
  Future<void> update(Song song) async {
    if (song.id == null) {
      throw ArgumentError('Cannot update a song without an id.');
    }
    final songs = _readAll();
    final index = songs.indexWhere((s) => s.id == song.id);
    if (index == -1) return;
    songs[index] = song;
    await _writeAll(songs);
  }

  @override
  Future<void> delete(int id) async {
    final songs = _readAll()..removeWhere((s) => s.id == id);
    await _writeAll(songs);

    // Also drop this song's folder_songs membership, or folder counts keep
    // counting a song that no longer exists.
    final folderSongs = _readFolderSongsMap(_prefs);
    var changed = false;
    for (final entry in folderSongs.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((songId) => songId == id);
      if (entry.value.length != before) changed = true;
    }
    if (changed) {
      await _writeFolderSongsMap(_prefs, folderSongs);
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

class _WebFolderRepository implements FolderRepository {
  final SharedPreferences _prefs;

  _WebFolderRepository(this._prefs);

  List<Folder> _readFolders() {
    final raw = _prefs.getString(_foldersKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => Folder.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _writeFolders(List<Folder> folders) async {
    final encoded = jsonEncode(folders.map((f) => f.toMap()).toList());
    await _prefs.setString(_foldersKey, encoded);
  }

  @override
  Future<List<Folder>> getAll() async {
    final folders = _readFolders();
    folders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return folders;
  }

  @override
  Future<Folder> create(Folder folder) async {
    final folders = _readFolders();
    final nextId = folders.isEmpty
        ? 1
        : folders.map((f) => f.id ?? 0).reduce((a, b) => a > b ? a : b) + 1;
    final created = folder.copyWith(id: nextId);
    folders.add(created);
    await _writeFolders(folders);
    return created;
  }

  @override
  Future<void> update(Folder folder) async {
    if (folder.id == null) {
      throw ArgumentError('Cannot update a folder without an id.');
    }
    final folders = _readFolders();
    final index = folders.indexWhere((f) => f.id == folder.id);
    if (index == -1) return;
    folders[index] = folder;
    await _writeFolders(folders);
  }

  @override
  Future<void> delete(int id) async {
    final folders = _readFolders()..removeWhere((f) => f.id == id);
    await _writeFolders(folders);
    final folderSongs = _readFolderSongsMap(_prefs)..remove(id.toString());
    await _writeFolderSongsMap(_prefs, folderSongs);
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    final folderSongs = _readFolderSongsMap(_prefs);
    final key = folderId.toString();
    final songIds = folderSongs[key] ?? [];
    if (!songIds.contains(songId)) {
      songIds.add(songId);
    }
    folderSongs[key] = songIds;
    await _writeFolderSongsMap(_prefs, folderSongs);
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    final folderSongs = _readFolderSongsMap(_prefs);
    final key = folderId.toString();
    final songIds = folderSongs[key] ?? [];
    songIds.remove(songId);
    folderSongs[key] = songIds;
    await _writeFolderSongsMap(_prefs, folderSongs);
  }

  @override
  Future<List<int>> getSongIds(int folderId) async {
    // Filtered against currently-existing songs so a folder_songs entry
    // left over from a song deletion (e.g. one that predates this fix,
    // before the on-init cleanup runs) never counts as a member.
    final ids = _readFolderSongsMap(_prefs)[folderId.toString()] ?? [];
    if (ids.isEmpty) return ids;
    final existingIds = _readExistingSongIds(_prefs);
    return ids.where(existingIds.contains).toList();
  }
}
