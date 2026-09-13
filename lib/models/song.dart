import 'dart:convert';

/// The app's default song ordering: newest-created first ([Song.createdAt]
/// descending), falling back to [Song.id] descending as a stable
/// tie-breaker when two songs share the same `created_at`. Never uses
/// [Song.updatedAt] — editing a song must not move it in this ordering.
/// Shared by every [LocalStorage] implementation (Android/Web/in-memory) so
/// they all sort the same way.
int compareSongsNewestFirst(Song a, Song b) {
  final byCreatedAt = b.createdAt.compareTo(a.createdAt);
  if (byCreatedAt != 0) return byCreatedAt;
  return (b.id ?? 0).compareTo(a.id ?? 0);
}

/// A single song entry.
///
/// Mirrors the existing `songs` table from the legacy (FlutterFlow) Android
/// app's `songbook.db` so the new app can read and write that data without
/// loss. See CLAUDE.md for the compatibility rules around this schema.
///
/// [memo] is kept only for backward compatibility with existing user data.
/// It is intentionally never shown or edited in the new UI — see
/// [searchAliases] for the field that replaces it in search.
class Song {
  final int? id;
  final String karaokeType;
  final String songNumber;
  final String title;
  final String? artist;
  final String? keyType;
  final int keyOffset;
  final String? difficulty;
  final String? practiceStatus;

  /// Legacy free-text memo. Preserved but never surfaced in the new UI.
  final String? memo;

  /// Alternate search terms for the song (e.g. transliterations, aliases in
  /// another script). Distinct from [memo] and never populated from it.
  final List<String> searchAliases;

  final bool favorite;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Song({
    this.id,
    required this.karaokeType,
    required this.songNumber,
    required this.title,
    this.artist,
    this.keyType,
    this.keyOffset = 0,
    this.difficulty,
    this.practiceStatus,
    this.memo,
    this.searchAliases = const [],
    this.favorite = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Song copyWith({
    int? id,
    String? karaokeType,
    String? songNumber,
    String? title,
    String? artist,
    String? keyType,
    int? keyOffset,
    String? difficulty,
    String? practiceStatus,
    String? memo,
    List<String>? searchAliases,
    bool? favorite,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Song(
      id: id ?? this.id,
      karaokeType: karaokeType ?? this.karaokeType,
      songNumber: songNumber ?? this.songNumber,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      keyType: keyType ?? this.keyType,
      keyOffset: keyOffset ?? this.keyOffset,
      difficulty: difficulty ?? this.difficulty,
      practiceStatus: practiceStatus ?? this.practiceStatus,
      memo: memo ?? this.memo,
      searchAliases: searchAliases ?? this.searchAliases,
      favorite: favorite ?? this.favorite,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Map form used by the web JSON store, where [searchAliases] is a plain
  /// list rather than an encoded string.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'karaoke_type': karaokeType,
      'song_number': songNumber,
      'title': title,
      'artist': artist,
      'key_type': keyType,
      'key_offset': keyOffset,
      'difficulty': difficulty,
      'practice_status': practiceStatus,
      'memo': memo,
      'search_aliases': searchAliases,
      'favorite': favorite,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as int?,
      karaokeType: map['karaoke_type'] as String,
      songNumber: map['song_number'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String?,
      keyType: map['key_type'] as String?,
      keyOffset: (map['key_offset'] as num?)?.toInt() ?? 0,
      difficulty: map['difficulty'] as String?,
      practiceStatus: map['practice_status'] as String?,
      memo: map['memo'] as String?,
      searchAliases: (map['search_aliases'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      favorite: map['favorite'] is bool
          ? map['favorite'] as bool
          : (map['favorite'] as num?) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  /// Row form used by the SQLite (Android) store, matching the existing
  /// `songs` table exactly. [searchAliases] is JSON-encoded into the
  /// `search_aliases` TEXT column and [favorite] is stored as 0/1.
  Map<String, Object?> toDbMap() {
    return {
      if (id != null) 'id': id,
      'karaoke_type': karaokeType,
      'song_number': songNumber,
      'title': title,
      'artist': artist,
      'key_type': keyType,
      'key_offset': keyOffset,
      'difficulty': difficulty,
      'practice_status': practiceStatus,
      'memo': memo,
      'search_aliases': jsonEncode(searchAliases),
      'favorite': favorite ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Song.fromDbMap(Map<String, Object?> map) {
    final rawAliases = map['search_aliases'] as String?;
    List<String> aliases = const [];
    if (rawAliases != null && rawAliases.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawAliases);
        if (decoded is List) {
          aliases = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {
        // Defensive: if a row somehow has non-JSON content in this column,
        // don't crash the whole song list over it.
        aliases = const [];
      }
    }
    return Song(
      id: map['id'] as int?,
      karaokeType: map['karaoke_type'] as String,
      songNumber: map['song_number'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String?,
      keyType: map['key_type'] as String?,
      keyOffset: (map['key_offset'] as int?) ?? 0,
      difficulty: map['difficulty'] as String?,
      practiceStatus: map['practice_status'] as String?,
      memo: map['memo'] as String?,
      searchAliases: aliases,
      favorite: (map['favorite'] as int?) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
