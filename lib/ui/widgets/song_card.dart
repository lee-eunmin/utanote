import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../models/song_options.dart';
import '../../theme/app_theme.dart';

/// A single song row: colored practice-status indicator, number → title →
/// artist hierarchy, a compact metadata row (key/difficulty/status), and a
/// small favorite toggle. Rows are flat with a hairline divider — a music
/// library list, not a stack of dashboard cards. Supports multi-select.
class SongCard extends StatefulWidget {
  final Song song;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFavoriteToggle;

  const SongCard({
    super.key,
    required this.song,
    this.selectionMode = false,
    this.selected = false,
    required this.onTap,
    this.onLongPress,
    this.onFavoriteToggle,
  });

  @override
  State<SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<SongCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _favController;
  late final Animation<double> _favScale;

  @override
  void initState() {
    super.initState();
    _favController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _favScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 1.3,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.3,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_favController);
  }

  @override
  void dispose() {
    _favController.dispose();
    super.dispose();
  }

  void _toggleFavorite() {
    _favController.forward(from: 0);
    widget.onFavoriteToggle?.call(!widget.song.favorite);
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      color: widget.selected ? AppColors.surfaceHigh : Colors.transparent,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.hairline)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.selectionMode) ...[
                    Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.selected
                              ? AppColors.accent
                              : Colors.transparent,
                          border: Border.all(
                            color: widget.selected
                                ? AppColors.accent
                                : AppColors.hairline,
                            width: 1.4,
                          ),
                        ),
                        child: widget.selected
                            ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.black,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: practiceStatusColor(song.practiceStatus),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                song.songNumber,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textTertiary,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            if (!widget.selectionMode)
                              ScaleTransition(
                                scale: _favScale,
                                child: _FavoriteButton(
                                  favorite: song.favorite,
                                  onTap: _toggleFavorite,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (song.artist != null && song.artist!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            song.artist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        _MetaRow(song: song),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  final bool favorite;
  final VoidCallback onTap;

  const _FavoriteButton({required this.favorite, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: 18,
          color: favorite ? AppColors.favorite : AppColors.textTertiary,
        ),
      ),
    );
  }
}

/// Compact metadata row: key/offset, difficulty, and practice status,
/// separated by small dot-leader bullets rather than colorful pills.
class _MetaRow extends StatelessWidget {
  final Song song;

  const _MetaRow({required this.song});

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      _KeyMeta(keyType: song.keyType, keyOffset: song.keyOffset),
      if (song.difficulty != null && song.difficulty!.isNotEmpty)
        _DotMeta(
          color: difficultyColor(song.difficulty),
          label: song.difficulty!,
        ),
      _DotMeta(
        color: practiceStatusColor(song.practiceStatus),
        label: song.practiceStatus ?? '연습 전',
      ),
    ];
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i != 0) const _MetaSeparator(),
          items[i],
        ],
      ],
    );
  }
}

class _MetaSeparator extends StatelessWidget {
  const _MetaSeparator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 7),
      child: Text(
        '·',
        style: TextStyle(
          fontSize: 13,
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _KeyMeta extends StatelessWidget {
  final String? keyType;
  final int keyOffset;

  const _KeyMeta({required this.keyType, required this.keyOffset});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    switch (keyType) {
      case '남키':
        icon = Icons.male_rounded;
        color = AppColors.male;
        break;
      case '여키':
        icon = Icons.female_rounded;
        color = AppColors.female;
        break;
      default:
        icon = Icons.piano_rounded;
        color = AppColors.textTertiary;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          formatKeyOffset(keyOffset),
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _DotMeta extends StatelessWidget {
  final Color color;
  final String label;

  const _DotMeta({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
