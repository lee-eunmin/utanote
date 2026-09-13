import 'folder_repository.dart';
import 'song_repository.dart';

/// A platform-local persistence backend, bundling the song and folder
/// repositories that share it (e.g. a single SQLite connection).
///
/// See `local_storage_factory.dart` for how the concrete implementation is
/// selected per platform (Android uses SQLite via `songbook.db`; Web uses
/// browser local storage).
abstract class LocalStorage {
  /// Opens/prepares the backend. Must be awaited before using [songs] or
  /// [folders]. Safe to call once at app startup.
  Future<void> init();

  SongRepository get songs;

  FolderRepository get folders;
}
