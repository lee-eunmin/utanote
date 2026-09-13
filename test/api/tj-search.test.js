const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { parseResults } = require('../../api/tj-search.js');

function loadFixture(name) {
  return fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
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
