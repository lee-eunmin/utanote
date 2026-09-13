import '../models/song.dart';

/// Storage-agnostic interface for reading and writing songs.
///
/// Implementations must never expose or write [Song.memo] from the UI layer;
/// it exists purely to preserve legacy data. Search must match
/// song_number, title, artist, and searchAliases.
abstract class SongRepository {
  /// Returns all songs ordered newest-created first — see
  /// [compareSongsNewestFirst]. Editing a song must never change its
  /// position here; only `create()` and `created_at` do.
  Future<List<Song>> getAll();

  Future<Song?> getById(int id);

  /// Inserts [song] and returns it with the assigned [Song.id].
  Future<Song> create(Song song);

  Future<void> update(Song song);

  Future<void> delete(int id);

  /// Case-insensitive substring search across song_number, title, artist,
  /// and searchAliases. Results preserve the same newest-first ordering as
  /// [getAll].
  Future<List<Song>> search(String query);
}
