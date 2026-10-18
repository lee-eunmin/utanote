import 'package:flutter/material.dart';

import '../../models/song.dart';
import 'song_list_entries.dart';

/// A [ListView] of songs that animates insertions/removals as [songs]
/// changes between rebuilds (e.g. from search, filtering, add/delete).
///
/// Uses Flutter's native [AnimatedList] diffing pattern: existing items are
/// matched by [Song.id], removed items fade/shrink out, and newly-present
/// items fade/grow in at their new position.
///
/// When [adBuilder] is given, an ad slot is interleaved after every
/// [adInterval]-th song (see [buildSongListEntries]). Ads are separate
/// entries, so [itemBuilder] only ever receives real songs.
class AnimatedSongList extends StatefulWidget {
  final List<Song> songs;
  final Widget Function(BuildContext context, Song song) itemBuilder;
  final Widget empty;
  final EdgeInsetsGeometry? padding;
  final Widget Function(BuildContext context, int slot)? adBuilder;
  final int adInterval;

  const AnimatedSongList({
    super.key,
    required this.songs,
    required this.itemBuilder,
    required this.empty,
    this.padding,
    this.adBuilder,
    this.adInterval = kSongListAdInterval,
  });

  @override
  State<AnimatedSongList> createState() => _AnimatedSongListState();
}

class _AnimatedSongListState extends State<AnimatedSongList> {
  static const _duration = Duration(milliseconds: 220);

  final _listKey = GlobalKey<AnimatedListState>();
  late List<SongListEntry> _displayed;

  @override
  void initState() {
    super.initState();
    _displayed = _entriesFor(widget.songs);
  }

  @override
  void didUpdateWidget(covariant AnimatedSongList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.songs, widget.songs)) {
      _applyDiff(_entriesFor(widget.songs));
    }
  }

  List<SongListEntry> _entriesFor(List<Song> songs) => buildSongListEntries(
    songs,
    adInterval: widget.adBuilder == null ? null : widget.adInterval,
  );

  void _applyDiff(List<SongListEntry> newEntries) {
    final newKeys = newEntries.map((e) => e.diffKey).toSet();
    for (int i = _displayed.length - 1; i >= 0; i--) {
      if (!newKeys.contains(_displayed[i].diffKey)) {
        final removed = _displayed.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, animation) =>
              _wrap(_buildRemoved(context, removed), animation),
          duration: _duration,
        );
      }
    }
    final keptKeys = _displayed.map((e) => e.diffKey).toSet();
    _displayed = newEntries;
    for (int i = 0; i < newEntries.length; i++) {
      if (!keptKeys.contains(newEntries[i].diffKey)) {
        _listKey.currentState?.insertItem(i, duration: _duration);
      }
    }
  }

  Widget _buildEntry(BuildContext context, SongListEntry entry) {
    return switch (entry) {
      SongEntry(:final song) => widget.itemBuilder(context, song),
      AdEntry(:final slot) => widget.adBuilder!(context, slot),
    };
  }

  /// A removed ad collapses as empty space rather than re-building its ad
  /// view: the same ad may already be re-mounted elsewhere in the list, and
  /// a native ad view can only be attached once at a time.
  Widget _buildRemoved(BuildContext context, SongListEntry entry) {
    return switch (entry) {
      SongEntry() => _buildEntry(context, entry),
      AdEntry() => const SizedBox.shrink(),
    };
  }

  Widget _wrap(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return SizeTransition(
      sizeFactor: curved,
      child: FadeTransition(opacity: curved, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_displayed.isEmpty) {
      return widget.empty;
    }
    return AnimatedList(
      key: _listKey,
      padding: widget.padding,
      initialItemCount: _displayed.length,
      itemBuilder: (context, index, animation) =>
          _wrap(_buildEntry(context, _displayed[index]), animation),
    );
  }
}
