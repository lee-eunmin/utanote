import 'dart:math';

/// Generates and validates the stable, device-independent ids used to
/// identify a song/folder across devices once cloud sync exists.
///
/// These sit *next to* the local integer primary keys (which stay the
/// in-app identity and the `folder_songs` join key) — they never replace
/// them. Format: a random (version 4) UUID, e.g.
/// `3f2b8c1e-9a4d-4e7b-b1c2-0d9e8f7a6b5c`. 122 random bits from the OS
/// CSPRNG, so collisions between devices are not a practical concern.
final Random _secureRandom = Random.secure();

String generateSyncId() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A stored sync id counts as present if it is non-null and non-empty.
/// Only rows failing this check ever get a new id generated — an existing
/// id is never rewritten.
bool hasSyncId(String? value) => value != null && value.isNotEmpty;

/// Current UTC time as epoch milliseconds — the format for every
/// sync-related timestamp (`sync_updated_at_ms`, `deleted_at_ms`, ...).
/// Timezone-independent, unlike the legacy local-time `created_at` /
/// `updated_at` strings, which are left exactly as they are.
int nowUtcMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
