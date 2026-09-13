const test = require('node:test');
const { mock } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { parseResults, searchRelevant, TJ_STR_TYPE } = require('../../api/tj-search.js');

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

test('parses rows into normalized results and de-dupes by songNumber', () => {
  const html = loadFixture('sample-results.html');
  const results = parseResults(html);

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

test('returns an empty array when TJ reports no matches', () => {
  const html = loadFixture('no-results.html');
  assert.deepEqual(parseResults(html), []);
});

test('does not throw on markup with no result rows at all', () => {
  assert.deepEqual(parseResults('<html><body>unexpected</body></html>'), []);
});

test('searchRelevant merges title and artist categories, deduped by songNumber, for non-numeric queries', async (t) => {
  const fetchMock = stubFetchByStrType({
    [TJ_STR_TYPE.TITLE]: loadFixture('title-only-results.html'),
    [TJ_STR_TYPE.ARTIST]: loadFixture('artist-only-results.html'),
  });
  t.after(() => fetchMock.mock.restore());

  const results = await searchRelevant('anything');

  // 11111 (title only), 22222 (title + artist, deduped to one), 33333 (artist only).
  assert.deepEqual(
    results.map((r) => r.songNumber),
    ['11111', '22222', '33333']
  );
  // The de-duped 22222 keeps the first (title-category) occurrence.
  assert.equal(results[1].title, 'Another Title');

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

test('searchRelevant excludes lyricist/composer-only matches by construction', async (t) => {
  // Even though the fixtures include title5/title6 (lyricist/composer) text
  // on every row, parseResults never reads those fields, and searchRelevant
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
