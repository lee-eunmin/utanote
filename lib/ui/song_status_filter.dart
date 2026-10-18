import '../models/song.dart';
import '../models/song_options.dart';

/// The "show everything" option of the song filter chip bars.
const kSongFilterAll = '전체';

/// Filter chips for screens that filter by practice status only (folder
/// detail). Same order as the main song list's status chips.
const kPracticeStatusFilterOptions = [
  kSongFilterAll,
  ...kPracticeStatusFilterOrder,
];

/// The status a song is shown with. Songs without a stored status are
/// displayed as '연습 전' by [SongCard], so they filter the same way.
String effectivePracticeStatus(Song song) =>
    song.practiceStatus ?? kPracticeStatuses.first;

/// Songs in [songs] whose practice status is [status]; all of them when
/// [status] is [kSongFilterAll]. Keeps the input order. UI-only: nothing
/// about the filter is stored.
List<Song> filterSongsByPracticeStatus(List<Song> songs, String status) {
  if (status == kSongFilterAll) return songs;
  return songs.where((s) => effectivePracticeStatus(s) == status).toList();
}
