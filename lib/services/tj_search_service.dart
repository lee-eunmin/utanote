import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/tj_search_result.dart';

/// A user-facing failure from [TjSearchService.search] — network error,
/// server error, bad/unparseable response, or missing configuration.
/// [message] is already Korean and safe to show directly in the UI.
class TjSearchException implements Exception {
  final String message;

  const TjSearchException(this.message);

  @override
  String toString() => message;
}

/// Client for the `/api/tj-search` serverless proxy (see api/tj-search.js).
/// Never talks to tjmedia.com directly — the server does that and returns
/// normalized JSON only.
///
/// [baseUrl] defaults to `--dart-define=TJ_API_BASE_URL=...` so it never
/// needs to be hardcoded to localhost; see README/deploy notes for the
/// exact flag.
class TjSearchService {
  final String baseUrl;
  final http.Client _client;

  TjSearchService({String? baseUrl, http.Client? client})
      : baseUrl =
            baseUrl ?? const String.fromEnvironment('TJ_API_BASE_URL'),
        _client = client ?? http.Client();

  Future<List<TjSearchResult>> search(
    String query, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (baseUrl.isEmpty) {
      throw const TjSearchException(
        'TJ 검색 서버 주소가 설정되지 않았어요. --dart-define=TJ_API_BASE_URL=<주소> 로 실행해주세요.',
      );
    }

    final uri = Uri.parse('$baseUrl/api/tj-search')
        .replace(queryParameters: {'q': query});

    http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw const TjSearchException('TJ 검색 응답이 지연되고 있어요. 다시 시도해주세요.');
    } catch (_) {
      throw const TjSearchException('TJ 검색 서버에 연결할 수 없어요. 네트워크를 확인해주세요.');
    }

    if (response.statusCode != 200) {
      throw TjSearchException('TJ 검색에 실패했어요. (${response.statusCode})');
    }

    final List<dynamic> rawResults;
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      rawResults = decoded['results'] as List<dynamic>? ?? const [];
    } catch (_) {
      throw const TjSearchException('TJ 검색 결과를 읽지 못했어요.');
    }

    return rawResults
        .map((e) => TjSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void dispose() => _client.close();
}
