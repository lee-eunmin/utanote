import 'dart:async';

import 'package:flutter/material.dart';

import '../models/tj_search_result.dart';
import '../services/tj_search_service.dart';
import '../theme/app_theme.dart';
import 'widgets/app_header.dart';
import 'widgets/responsive_center.dart';

const _debounceDuration = Duration(milliseconds: 450);
const _minQueryLength = 2;

/// The "TJ 검색" tab: search TJ Media's official accompaniment catalog via
/// the `/api/tj-search` proxy (see api/tj-search.js) and display results.
///
/// This screen only *displays* TJ results — it never writes to the local
/// songs database. Saving a result into the library is a separate,
/// not-yet-built feature (see the disabled trailing affordance on each row).
class TjSearchScreen extends StatefulWidget {
  final TjSearchService? service;

  const TjSearchScreen({super.key, this.service});

  @override
  State<TjSearchScreen> createState() => _TjSearchScreenState();
}

class _TjSearchScreenState extends State<TjSearchScreen> {
  late final TjSearchService _service;
  final _controller = TextEditingController();
  Timer? _debounce;

  // Guards against an older, slower request overwriting a newer one's result.
  int _requestId = 0;

  List<TjSearchResult> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? TjSearchService();
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
      itemBuilder: (context, index) => _TjResultTile(result: _results[index]),
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
/// local library. The trailing "+" is a save-to-library affordance that is
/// intentionally disabled — that feature isn't built yet.
class _TjResultTile extends StatelessWidget {
  final TjSearchResult result;

  const _TjResultTile({required this.result});

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
          // Save-to-library affordance — visual only, not wired up yet.
          IgnorePointer(
            child: Opacity(
              opacity: 0.4,
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
          ),
        ],
      ),
    );
  }
}
