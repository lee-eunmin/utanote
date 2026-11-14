/// A single row returned by the `/api/tj-search` proxy — a normalized view
/// of a TJ Media accompaniment search hit. This is intentionally *not* the
/// [Song] model: it has no local id, no favorite/status/key fields, and
/// isn't backed by the songs database. See CLAUDE.md — saving one of these
/// into the local library is a separate, not-yet-built feature.
class TjSearchResult {
  final String songNumber;
  final String title;
  final String artist;

  /// TJ marks this row as the MR version (its own song number). Shown as a
  /// badge in TJ search only; never stored with a local song. False when the
  /// API response has no `isMr` (older proxy) or anything but `true`.
  final bool isMr;

  const TjSearchResult({
    required this.songNumber,
    required this.title,
    required this.artist,
    this.isMr = false,
  });

  factory TjSearchResult.fromJson(Map<String, dynamic> json) {
    return TjSearchResult(
      songNumber: (json['songNumber'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      artist: (json['artist'] as String?) ?? '',
      isMr: json['isMr'] == true,
    );
  }
}
