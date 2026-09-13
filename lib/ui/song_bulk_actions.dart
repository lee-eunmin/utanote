import '../models/song.dart';
import '../storage/local_storage.dart';

/// Bulk operations shared by the song list and folder detail screens'
/// multi-select action bars.
Future<void> addSongsToFolder(
  LocalStorage storage,
  Set<int> songIds,
  int folderId,
) async {
  for (final id in songIds) {
    await storage.folders.addSong(folderId, id);
  }
}

Future<void> removeSongsFromFolder(
  LocalStorage storage,
  Set<int> songIds,
  int folderId,
) async {
  for (final id in songIds) {
    await storage.folders.removeSong(folderId, id);
  }
}

Future<void> setPracticeStatusForSongs(
  LocalStorage storage,
  List<Song> allSongs,
  Set<int> songIds,
  String status,
) async {
  final now = DateTime.now();
  for (final song in allSongs) {
    if (songIds.contains(song.id)) {
      await storage.songs.update(
        song.copyWith(practiceStatus: status, updatedAt: now),
      );
    }
  }
}

Future<void> deleteSongs(LocalStorage storage, Set<int> songIds) async {
  for (final id in songIds) {
    await storage.songs.delete(id);
  }
}
