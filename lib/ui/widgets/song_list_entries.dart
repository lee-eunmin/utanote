import '../../models/song.dart';

/// One in-list native ad after every this-many songs in the main song list.
const kSongListAdInterval = 10;

/// A row of the main song list: either a real [Song] or an ad slot.
///
/// Ads are a separate type, never a [Song], so song callbacks (tap, edit,
/// long-press, favorite) can only ever receive a song from a [SongEntry].
sealed class SongListEntry {
  const SongListEntry();

  /// Identity used to diff the list between rebuilds.
  Object get diffKey;
}

final class SongEntry extends SongListEntry {
  final Song song;

  const SongEntry(this.song);

  @override
  Object get diffKey => (#song, song.id);
}

final class AdEntry extends SongListEntry {
  /// 0-based ad slot: slot `n` sits right after song `(n + 1) * interval`.
  final int slot;

  const AdEntry(this.slot);

  @override
  Object get diffKey => (#ad, slot);
}

/// Interleaves ad slots into [songs]: one [AdEntry] after every
/// [adInterval]-th song (after song 10, 20, 30, ... by default), never before
/// the first song. Placement is computed from the already searched/filtered
/// list, so slot positions are always relative to what is actually shown.
/// A null [adInterval] produces songs only.
List<SongListEntry> buildSongListEntries(List<Song> songs, {int? adInterval}) {
  assert(adInterval == null || adInterval > 0);
  final entries = <SongListEntry>[];
  for (var i = 0; i < songs.length; i++) {
    entries.add(SongEntry(songs[i]));
    if (adInterval != null && (i + 1) % adInterval == 0) {
      entries.add(AdEntry((i + 1) ~/ adInterval - 1));
    }
  }
  return entries;
}
