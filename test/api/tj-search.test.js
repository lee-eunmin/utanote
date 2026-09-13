const test = require('node:test');
const { mock } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  parseSection,
  searchRelevant,
  TJ_STR_TYPE,
  rankBySource,
} = require('../../api/tj-search.js');

function loadFixture(name) {
  return fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
}

// Stubs global fetch to serve canned fixture HTML based on the strType query
// param, so searchRelevant's category-selection/merge/de-dup logic can be
// tested without hitting the real TJ Media endpoint.
function stubFetchByStrType(fixturesByStrType) {
  return mock.method(global, 'fetch', async (url) => {
    const strType = new URL(url).searchParams.get('strType');
    const html = fixturesByStrType[strType];
    if (html === undefined) {
      throw new Error(`Unexpected strType requested: ${strType}`);
    }
    return { ok: true, text: async () => html };
  });
}

test('parses rows from the 곡 제목 section into normalized results, de-duped by songNumber', () => {
  const html = loadFixture('sample-results.html');
  const results = parseSection(html, 'TITLE');

  assert.equal(results.length, 2);

  const [first, second] = results;
  assert.deepEqual(first, {
    songNumber: '28834',
    title: "さよならエレジー(ドラマ'トドメの接吻' OST)",
    artist: '菅田将暉',
  });
  assert.equal(second.songNumber, '99999');
  assert.equal(second.title, '인스트루멘탈 트랙');
  // No singer text on this row falls back to an empty string, not undefined.
  assert.equal(second.artist, '');

  // Lyricist/composer text (작사가A/작곡가A) must never leak into the response.
  for (const result of results) {
    assert.equal(Object.keys(result).sort().join(','), 'artist,songNumber,title');
  }
});

test('parses rows from the 가수 section independently of the 곡 제목 section', () => {
  const html = loadFixture('sample-results.html');
  const results = parseSection(html, 'ARTIST');

  // sample-results.html's 가수 section repeats only song 28834.
  assert.deepEqual(results, [
    { songNumber: '28834', title: "さよならエレジー(ドラマ'トドメの接吻' OST)", artist: '菅田将暉' },
  ]);
});

test('returns an empty array when TJ reports no matches', () => {
  const html = loadFixture('no-results.html');
  assert.deepEqual(parseSection(html, 'TITLE'), []);
});

test('does not throw on markup with no result rows at all', () => {
  assert.deepEqual(parseSection('<html><body>unexpected</body></html>', 'TITLE'), []);
});

test('parseSection only collects rows from the matching section, never 작사가/작곡가/메들리 or the other of title/artist/곡번호', () => {
  const html = loadFixture('all-sections-results.html');

  assert.deepEqual(parseSection(html, 'TITLE'), [
    { songNumber: '10001', title: 'Title Section Song', artist: 'Title Section Artist' },
  ]);
  assert.deepEqual(parseSection(html, 'ARTIST'), [
    { songNumber: '10002', title: 'Artist Section Song', artist: 'Artist Section Artist' },
  ]);
  assert.deepEqual(parseSection(html, 'SONG_NUMBER'), [
    { songNumber: '10005', title: 'Song Number Section Song', artist: 'Song Number Section Artist' },
  ]);

  // None of our three categories may ever surface the 작사가(10003)/
  // 작곡가(10004)/메들리(10006) rows, even though they're on the same page.
  const allowedSongNumbers = new Set(['10001', '10002', '10005']);
  for (const category of ['TITLE', 'ARTIST', 'SONG_NUMBER']) {
    for (const result of parseSection(html, category)) {
      assert.ok(allowedSongNumbers.has(result.songNumber), `unexpected songNumber ${result.songNumber} leaked from a ${category} parse`);
    }
  }
});

test('searchRelevant merges title and artist categories, deduped by songNumber, for non-numeric queries', async (t) => {
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.TITLE]: loadFixture('title-only-results.html'),
    [TJ_STR_TYPE.ARTIST]: loadFixture('artist-only-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('anything');

  // 22222 and 33333 both came back from the ARTIST search (tier 1), so they
  // rank ahead of 11111, a title-only broad fallback match (tier 3). 22222
  // also appears in the TITLE results, but since ARTIST gives it the better
  // tier, it's deduped down to a single copy ranked with the ARTIST-sourced
  // results, in TJ's original ARTIST order (22222 before 33333).
  assert.deepEqual(
    results.map((r) => r.songNumber),
    ['22222', '33333', '11111']
  );
  // The de-duped 22222 has the same title either way, since both fixtures
  // agree on it.
  assert.equal(results[0].title, 'Another Title');

  // Never hit the song-number category for a non-numeric query.
  const requestedStrTypes = fetchMock.mock.calls.map(
    (call) => new URL(call.arguments[0]).searchParams.get('strType')
  );
  assert.deepEqual(requestedStrTypes.sort(), [TJ_STR_TYPE.ARTIST, TJ_STR_TYPE.TITLE].sort());
});

test('searchRelevant searches only by song number for all-digit queries', async (t) => {
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.SONG_NUMBER]: loadFixture('song-number-only-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('44444');

  assert.deepEqual(results, [{ songNumber: '44444', title: 'Numeric Match', artist: 'Some Artist' }]);
  assert.equal(fetchMock.mock.calls.length, 1);
  assert.equal(
    new URL(fetchMock.mock.calls[0].arguments[0]).searchParams.get('strType'),
    TJ_STR_TYPE.SONG_NUMBER
  );
});

test('rankBySource orders title-exact > any artist-search result > title-contains > other title fallback, preserving order within a tier', () => {
  const titleResults = [
    { songNumber: '1', title: 'Other Song', artist: 'Someone Else' }, // tier 3
    { songNumber: '3', title: 'query', artist: 'Another Artist' }, // tier 0 (title exact)
    { songNumber: '4', title: 'query song', artist: 'Yet Another' }, // tier 2 (title contains)
    { songNumber: '5', title: 'Second Other', artist: 'Nobody' }, // tier 3
  ];
  const artistResults = [
    { songNumber: '6', title: 'Unrelated', artist: 'query' }, // tier 1
    { songNumber: '2', title: 'A Title', artist: 'query Band' }, // tier 1
  ];

  const ranked = rankBySource(titleResults, artistResults, 'query');

  assert.deepEqual(
    ranked.map((r) => r.songNumber),
    ['3', '6', '2', '4', '1', '5']
  );
});

test('rankBySource ignores case and spacing differences between query and title', () => {
  const titleResults = [
    { songNumber: '1', title: 'Something', artist: 'Someone' },
    { songNumber: '2', title: '  Query  ', artist: 'Someone Else' },
  ];

  const ranked = rankBySource(titleResults, [], 'QUERY');

  assert.deepEqual(ranked.map((r) => r.songNumber), ['2', '1']);
});

test('rankBySource ranks every ARTIST-search result in tier 1 regardless of the literal artist string, not just literal query matches', () => {
  // TJ's ARTIST search itself is trusted as the relevance signal here (see
  // the doc comment on rankBySource) - a result with an artist string that
  // shares nothing with the query still outranks a broad TITLE fallback.
  const titleResults = [
    { songNumber: '1', title: 'Unrelated broad match', artist: 'Nobody' }, // tier 3
  ];
  const artistResults = [
    { songNumber: '2', title: 'Some Song', artist: 'Completely Different Name' }, // tier 1
  ];

  const ranked = rankBySource(titleResults, artistResults, 'query');

  assert.deepEqual(ranked.map((r) => r.songNumber), ['2', '1']);
});

test('rankBySource keeps a songNumber appearing in both categories once, at the better tier', () => {
  const titleResults = [
    { songNumber: '1', title: 'Unrelated Broad Title', artist: 'Someone' }, // tier 3
  ];
  const artistResults = [
    { songNumber: '1', title: 'Unrelated Broad Title', artist: 'Someone' }, // tier 1
  ];

  const ranked = rankBySource(titleResults, artistResults, 'query');

  assert.equal(ranked.length, 1);
  assert.equal(ranked[0].songNumber, '1');
});

test('searchRelevant ranks an exact artist/title match above TJ\'s broader weakly-related matches for a broad query', async (t) => {
  // Regression test for a real report: searching "아이유" returned weakly
  // related titles (그 아이 / 돌아이 / Moai / But I) ahead of the actually
  // relevant songs. Broad matches must still be returned, just ranked last.
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.TITLE]: loadFixture('broad-query-title-results.html'),
    [TJ_STR_TYPE.ARTIST]: loadFixture('broad-query-artist-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('아이유');

  // 50006: exact title match ("아이유") - tier 0. 50001: came back from the
  // ARTIST search - tier 1. The rest are TJ's broad title matches, still
  // present but ranked last, in their original TJ order.
  assert.deepEqual(
    results.map((r) => r.songNumber),
    ['50006', '50001', '50002', '50003', '50004', '50005']
  );
});

test('searchRelevant ranks an ARTIST-source alias match (TJ resolving "아이유" to displayed artist "IU") ahead of broad TITLE-source fallbacks', async (t) => {
  // Regression test for the specific case reported: TJ's ARTIST search can
  // match a Korean query to a song whose *displayed* artist name is an
  // entirely different string (e.g. an English stage name, "IU"), with no
  // literal overlap with the query at all. That result must still outrank
  // TJ's broad, weakly-related TITLE-search fallbacks (e.g. "그 아이",
  // "돌아이") rather than falling to the bottom for failing a literal
  // artist-string comparison.
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.TITLE]: loadFixture('iu-alias-title-results.html'),
    [TJ_STR_TYPE.ARTIST]: loadFixture('iu-alias-artist-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('아이유');

  // 60001 (artist "IU", from the ARTIST search) must rank ahead of 50002
  // ("그 아이") and 50003 ("돌아이"), both broad TITLE-source fallbacks.
  assert.deepEqual(
    results.map((r) => r.songNumber),
    ['60001', '50002', '50003']
  );
  assert.equal(results[0].artist, 'IU');
});

test('searchRelevant excludes lyricist/composer-only matches by construction', async (t) => {
  // Even though the fixtures include title5/title6 (lyricist/composer) text
  // on every row, parseSection never reads those fields, and searchRelevant
  // never requests TJ's lyricist/composer categories in the first place.
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.TITLE]: loadFixture('title-only-results.html'),
    [TJ_STR_TYPE.ARTIST]: loadFixture('artist-only-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('anything');

  for (const result of results) {
    assert.equal(Object.keys(result).sort().join(','), 'artist,songNumber,title');
  }
});
