/// A user-defined folder used to group songs together.
///
/// Mirrors the existing `folders` table from the legacy `songbook.db`.
class Folder {
  final int? id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Stable cross-device id (UUID v4) for future cloud sync — see
  /// [Song.syncId]. SQLite only; not part of [toMap]/[fromMap] (Web JSON).
  final String? syncId;

  const Folder({
    this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.syncId,
  });

  Folder copyWith({
    int? id,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? syncId,
  }) {
    return Folder(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncId: syncId ?? this.syncId,
    );
  }

  /// Map form used by the web JSON store. Unchanged by sync readiness.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Folder.fromMap(Map<String, dynamic> map) {
    return Folder(
      id: map['id'] as int?,
      name: map['name'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  /// Row form for the SQLite (Android) `folders` table.
  Map<String, Object?> toDbMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (syncId != null) 'sync_id': syncId,
    };
  }

  factory Folder.fromDbMap(Map<String, Object?> map) {
    return Folder(
      id: map['id'] as int?,
      name: map['name'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      syncId: map['sync_id'] as String?,
    );
  }
}
