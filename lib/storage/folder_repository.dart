import '../models/folder.dart';

/// Storage-agnostic interface for reading and writing folders, and managing
/// which songs belong to them.
abstract class FolderRepository {
  Future<List<Folder>> getAll();

  Future<Folder> create(Folder folder);

  Future<void> update(Folder folder);

  Future<void> delete(int id);

  Future<void> addSong(int folderId, int songId);

  Future<void> removeSong(int folderId, int songId);

  Future<List<int>> getSongIds(int folderId);
}
