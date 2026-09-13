import 'dart:async';

import 'package:flutter/material.dart';

import '../models/tj_search_result.dart';
import '../services/tj_search_service.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'song_edit_sheet.dart';
import 'widgets/app_header.dart';
import 'widgets/responsive_center.dart';

const _debounceDuration = Duration(milliseconds: 450);
const _minQueryLength = 2;

/// The "TJ 검색" tab: search TJ Media's official accompaniment catalog via
/// the `/api/tj-search` proxy (see api/tj-search.js) and display results.
///
/// Tapping "+" on a result opens the normal song add sheet/dialog (see
/// song_edit_sheet.dart), prefilled with that result's number/title/artist
/// and karaoke_type forced to 'TJ'. Saving goes through the same
/// [SongRepository] as every other add flow — there is no TJ-specific
/// insertion path. A result whose (karaoke_type == 'TJ', song_number) pair
/// already exists locally shows a disabled "추가됨" state instead.
class TjSearchScreen extends StatefulWidget {
  final LocalStorage storage;
  final TjSearchService? service;

  const TjSearchScreen({super.key, required this.storage, this.service});

  @override
  State<TjSearchScreen> createState() => TjSearchScreenState();
}

class TjSearchScreenState extends State<TjSearchScreen> {
  late final TjSearchService _service;
  final _controller = TextEditingController();
  Timer? _debounce;

  // Guards against an older, slower request overwriting a newer one's result.
  int _requestId = 0;

  List<TjSearchResult> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  // Song numbers of songs already saved locally with karaoke_type == 'TJ'.
  // Used to show a "추가됨" state instead of "+" for results already added.
  Set<String> _addedNumbers = const {};

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? TjSearchService();
    unawaited(refreshAddedSongs());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    if (widget.service == null) {
      _service.dispose();
    }
    super.dispose();
  }

  /// Re-reads which TJ song numbers already exist locally. Called on init,
  /// after the add sheet closes, and by [AppShell] when this tab becomes
  /// visible, so a song added elsewhere (or in a previous session) is
  /// reflected without needing a new search.
  Future<void> refreshAddedSongs() async {
    final all = await widget.storage.songs.getAll();
    if (!mounted) return;
    setState(() {
      _addedNumbers = all
          .where((s) => s.karaokeType == 'TJ')
          .map((s) => s.songNumber)
          .toSet();
    });
  }

  Future<void> _onAddTap(TjSearchResult result) async {
    // Re-check against the repository right before opening the form, so a
    // song added via another tab in the meantime isn't duplicated.
    await refreshAddedSongs();
    if (!mounted || _addedNumbers.contains(result.songNumber)) return;

    await showSongEditSheet(
      context: context,
      storage: widget.storage,
      tjResult: result,
    );
    await refreshAddedSongs();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < _minQueryLength) {
      setState(() {
        _requestId++;
        _results = const [];
        _error = null;
        _loading = false;
        _searched = false;
      });
      return;
    }
    _debounce = Timer(_debounceDuration, () => _runSearch(query));
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < _minQueryLength) return;
    _runSearch(query);
  }

  Future<void> _runSearch(String query) async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await _service.search(query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = results;
        _loading = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = e is TjSearchException ? e.message : '검색 중 오류가 발생했어요.';
        _loading = false;
        _searched = true;
      });
    }
  }

  void _retry() {
    final query = _controller.text.trim();
    if (query.length >= _minQueryLength) {
      _runSearch(query);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ResponsiveCenter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppHeader(subtitle: 'TJ 노래 검색'),
                TextField(
                  key: const Key('tjSearchField'),
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '제목 · 가수 · 곡번호 검색',
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                  ),
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSubmitted,
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 2,
                  child: _loading
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                const SizedBox(height: 8),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _TjMessageState(
        icon: Icons.wifi_off_rounded,
        title: '검색에 실패했어요',
        message: _error!,
        action: TextButton(
          onPressed: _retry,
          child: const Text('다시 시도'),
        ),
      );
    }

    if (!_searched) {
      return const _TjMessageState(
        icon: Icons.search_rounded,
        title: 'TJ 반주곡을 검색해보세요',
        message: '제목, 가수, 곡번호로 2글자 이상 입력하면 검색됩니다.',
      );
    }

    if (_results.isEmpty) {
      return const _TjMessageState(
        icon: Icons.music_off_rounded,
        title: '검색 결과가 없어요',
        message: '다른 검색어로 다시 시도해보세요.',
      );
    }

    return ListView.builder(
      key: const Key('tjSearchResultsList'),
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        final added = _addedNumbers.contains(result.songNumber);
        return _TjResultTile(
          result: result,
          added: added,
          onAdd: added ? null : () => _onAddTap(result),
        );
      },
    );
  }
}

class _TjMessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _TjMessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.meta,
            ),
            if (action != null) ...[const SizedBox(height: 4), action!],
          ],
        ),
      ),
    );
  }
}

/// A single TJ result row. Deliberately close to (but not identical to)
/// [SongCard]'s number → title → artist hierarchy: no practice-status bar,
/// key/difficulty meta, or favorite toggle, since this song isn't in the
/// local library. The trailing affordance is either a tappable "+" (opens
/// the add form) or, when [added] is true, a disabled "추가됨" badge.
class _TjResultTile extends StatelessWidget {
  final TjSearchResult result;
  final bool added;
  final VoidCallback? onAdd;

  const _TjResultTile({
    required this.result,
    required this.added,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.songNumber,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  result.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (result.artist.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    result.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (added)
            Container(
              key: Key('tjAdded_${result.songNumber}'),
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '추가됨',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textTertiary,
                ),
              ),
            )
          else
            InkWell(
              key: Key('tjAdd_${result.songNumber}'),
              onTap: onAdd,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
