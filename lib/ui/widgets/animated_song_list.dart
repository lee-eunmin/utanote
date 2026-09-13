import 'package:flutter/material.dart';

import '../../models/song.dart';

/// A [ListView] of songs that animates insertions/removals as [songs]
/// changes between rebuilds (e.g. from search, filtering, add/delete).
///
/// Uses Flutter's native [AnimatedList] diffing pattern: existing items are
/// matched by [Song.id], removed items fade/shrink out, and newly-present
/// items fade/grow in at their new position.
class AnimatedSongList extends StatefulWidget {
  final List<Song> songs;
  final Widget Function(BuildContext context, Song song) itemBuilder;
  final Widget empty;
  final EdgeInsetsGeometry? padding;

  const AnimatedSongList({
    super.key,
    required this.songs,
    required this.itemBuilder,
    required this.empty,
    this.padding,
  });

  @override
  State<AnimatedSongList> createState() => _AnimatedSongListState();
}

class _AnimatedSongListState extends State<AnimatedSongList> {
  static const _duration = Duration(milliseconds: 220);

  final _listKey = GlobalKey<AnimatedListState>();
  late List<Song> _displayed;

  @override
  void initState() {
    super.initState();
    _displayed = List.of(widget.songs);
  }

  @override
  void didUpdateWidget(covariant AnimatedSongList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.songs, widget.songs)) {
      _applyDiff(widget.songs);
    }
  }

  void _applyDiff(List<Song> newSongs) {
    final newIds = newSongs.map((s) => s.id).toSet();
    for (int i = _displayed.length - 1; i >= 0; i--) {
      if (!newIds.contains(_displayed[i].id)) {
        final removed = _displayed.removeAt(i);
        _listKey.currentState?.removeItem(
          i,
          (context, animation) =>
              _wrap(widget.itemBuilder(context, removed), animation),
          duration: _duration,
        );
      }
    }
    final keptIds = _displayed.map((s) => s.id).toSet();
    _displayed = List.of(newSongs);
    for (int i = 0; i < newSongs.length; i++) {
      if (!keptIds.contains(newSongs[i].id)) {
        _listKey.currentState?.insertItem(i, duration: _duration);
      }
    }
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
          _wrap(widget.itemBuilder(context, _displayed[index]), animation),
    );
  }
}
