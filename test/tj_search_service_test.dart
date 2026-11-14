import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:utanote/services/tj_search_service.dart';

/// The TJ search proxy address must work without any --dart-define (a plain
/// `flutter build appbundle --release` once shipped with an empty address).
/// Tests run without TJ_API_BASE_URL, so they see the build default.
void main() {
  const production = 'https://utanote-git-main-utanote.vercel.app';

  /// Records the requested URLs and answers with an empty result list.
  MockClient recording(List<Uri> requested) => MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          jsonEncode({'results': <Object>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

  test('no dart-define: the production proxy is the default', () {
    expect(kDefaultTjApiBaseUrl, production);
    expect(kTjApiBaseUrl, production);
    expect(kTjApiBaseUrl, isNotEmpty);
    final uri = Uri.parse(kTjApiBaseUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, isNotEmpty);
    expect(kTjApiBaseUrl.endsWith('/'), isFalse);
    expect(TjSearchService().baseUrl, production);
  });

  test('search calls <production>/api/tj-search?q=...', () async {
    final requested = <Uri>[];
    final service = TjSearchService(client: recording(requested));
    await service.search('夜に駆ける');
    await service.search('12345');

    expect(requested, hasLength(2));
    expect(
      requested.first.toString(),
      '$production/api/tj-search?q=${Uri.encodeQueryComponent('夜に駆ける')}',
    );
    expect(requested.first.origin, production);
    expect(requested.first.path, '/api/tj-search');
    expect(requested.first.queryParameters, {'q': '夜に駆ける'});
    expect(requested.last.toString(), '$production/api/tj-search?q=12345');
  });

  test('an explicit base URL still overrides the default', () async {
    final requested = <Uri>[];
    final service = TjSearchService(
      baseUrl: 'http://localhost:3000',
      client: recording(requested),
    );
    await service.search('abc');
    expect(
      requested.single.toString(),
      'http://localhost:3000/api/tj-search?q=abc',
    );
  });

  test('isMr: true / false / missing (older proxy) / not a bool', () async {
    final service = TjSearchService(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'results': [
              {'songNumber': '62239', 'title': '좋은 날', 'artist': 'IU', 'isMr': true},
              {'songNumber': '33393', 'title': '좋은 날', 'artist': 'IU', 'isMr': false},
              {'songNumber': '28834', 'title': 'さよならエレジー', 'artist': '菅田将暉'},
              {'songNumber': '1', 'title': 'x', 'artist': 'y', 'isMr': 'true'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final results = await service.search('좋은날');
    expect(
      results.map((r) => (r.songNumber, r.title, r.artist, r.isMr)).toList(),
      [
        ('62239', '좋은 날', 'IU', true),
        ('33393', '좋은 날', 'IU', false),
        ('28834', 'さよならエレジー', '菅田将暉', false),
        ('1', 'x', 'y', false),
      ],
    );
  });

  test('an empty address is still reported, not requested', () async {
    final requested = <Uri>[];
    final service = TjSearchService(baseUrl: '', client: recording(requested));
    await expectLater(
      service.search('abc'),
      throwsA(isA<TjSearchException>().having(
        (e) => e.message,
        'message',
        contains('TJ_API_BASE_URL'),
      )),
    );
    expect(requested, isEmpty);
  });
}
