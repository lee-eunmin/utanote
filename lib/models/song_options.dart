/// Shared option lists for song metadata pickers in the UI layer.
///
/// These are plain display/selection values stored verbatim into the
/// existing free-text `key_type`/`difficulty`/`practice_status` columns —
/// they don't change the storage schema. See CLAUDE.md.
const List<String> kKeyTypes = ['원키', '남키', '여키'];

const List<int> kKeyOffsets = [-3, -2, -1, 0, 1, 2, 3];

const List<String> kDifficulties = ['쉬움', '보통', '어려움'];

/// Logical progression order, used in the add/edit sheet.
const List<String> kPracticeStatuses = ['연습 전', '연습 중', '완료'];

/// Display order used for the song-list filter chips.
const List<String> kPracticeStatusFilterOrder = ['완료', '연습 중', '연습 전'];

String formatKeyOffset(int offset) {
  if (offset == 0) return '0';
  return offset > 0 ? '+$offset' : '$offset';
}
