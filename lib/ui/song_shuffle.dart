import 'dart:math';

import '../models/song.dart';

/// One "랜덤 정렬" request on the main song list.
///
/// Created only when the user taps the random button. Each song gets a
/// random sort key the first time it is seen and keeps it for the lifetime
/// of this object, so rebuilds, reloads, filter and search changes all show
/// the same relative order until the next tap creates a new instance.
///
/// UI/session state only: nothing here is stored or synced, and [apply]
/// never modifies its input list.
class SongShuffleOrder {
  /// 1 for the first tap in this screen session, 2 for the next, ...
  final int generation;

  /// Source of the per-song sort keys.
  final Random random;

  final Map<int, double> _keys = {};

  SongShuffleOrder({required this.generation, required this.random});

  double _keyFor(int id) => _keys.putIfAbsent(id, random.nextDouble);

  /// A shuffled copy of [songs]: same songs, no additions or duplicates.
  /// Songs without an id (never the case for stored songs) go last in their
  /// original order.
  List<Song> apply(List<Song> songs) {
    final withId = <Song>[];
    final withoutId = <Song>[];
    for (final song in songs) {
      (song.id == null ? withoutId : withId).add(song);
    }
    // Assign keys in input order so a given Random sequence is reproducible.
    for (final song in withId) {
      _keyFor(song.id!);
    }
    withId.sort((a, b) {
      final byKey = _keys[a.id]!.compareTo(_keys[b.id]!);
      return byKey != 0 ? byKey : a.id!.compareTo(b.id!);
    });
    return [...withId, ...withoutId];
  }
}
