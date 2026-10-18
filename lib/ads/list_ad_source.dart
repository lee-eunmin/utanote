import 'package:flutter/widgets.dart';

/// Supplies in-list ad widgets for a song list. Platform-agnostic: the UI
/// depends only on this interface, never on the ads plugin directly (the
/// plugin is Android-only and must not be compiled into the Web build).
abstract class ListAdSource {
  /// The ad for 0-based [slot]. Must render as zero-size while loading or
  /// after a failed load, so a missing ad never leaves a gap. Calling this
  /// repeatedly for the same slot (e.g. on rebuild) must not reload the ad.
  Widget buildAd(BuildContext context, int slot);

  /// Releases every ad this source has loaded.
  void dispose();
}

/// Creates a [ListAdSource] owned (and disposed) by a single list screen.
typedef ListAdSourceFactory = ListAdSource Function();
