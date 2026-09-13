/// A single row returned by the `/api/tj-search` proxy — a normalized view
/// of a TJ Media accompaniment search hit. This is intentionally *not* the
/// [Song] model: it has no local id, no favorite/status/key fields, and
/// isn't backed by the songs database. See CLAUDE.md — saving one of these
/// into the local library is a separate, not-yet-built feature.
class TjSearchResult {
  final String songNumber;
  final String title;
  final String artist;

  const TjSearchResult({
    required this.songNumber,
    required this.title,
    required this.artist,
  });

  factory TjSearchResult.fromJson(Map<String, dynamic> json) {
    return TjSearchResult(
      songNumber: (json['songNumber'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      artist: (json['artist'] as String?) ?? '',
    );
  }
}
