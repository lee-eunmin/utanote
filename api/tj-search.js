const cheerio = require('cheerio');

// Official TJ Media accompaniment search page. Per CLAUDE.md-adjacent task
// rules this is the ONLY source — no Kumyoung, no unofficial APIs.
const TJ_SEARCH_URL = 'https://www.tjmedia.com/song/accompaniment_search';

const REQUEST_TIMEOUT_MS = 8000;
const CACHE_TTL_MS = 5 * 60 * 1000;
const CACHE_MAX_ENTRIES = 200;

// Per-lambda-instance cache so repeated searches for the same term within a
// warm instance don't re-hit TJ. This is a courtesy layer only — the
// Cache-Control header below is what actually protects TJ at the CDN edge.
const cache = new Map();

function getCached(key) {
  const entry = cache.get(key);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    cache.delete(key);
    return null;
  }
  return entry.value;
}

function setCached(key, value) {
  if (cache.size >= CACHE_MAX_ENTRIES) {
    const oldestKey = cache.keys().next().value;
    cache.delete(oldestKey);
  }
  cache.set(key, { value, expiresAt: Date.now() + CACHE_TTL_MS });
}

function setCorsHeaders(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

/// Parses a TJ Media accompaniment_search results page into normalized
/// {songNumber, title, artist} rows, deduplicated by songNumber.
///
/// TJ renders one "grid-container list" per matched row, repeated across
/// several category sections (title/singer/lyricist/composer/song
/// number/medley) on an integrated (strType=0) search. We read every such
/// row across the whole page rather than a single section, since the task
/// asks to search across everything TJ returns for the query in one request.
function parseResults(html) {
  const $ = cheerio.load(html);
  const results = [];
  const seen = new Set();

  $('ul.grid-container.list').each((_, el) => {
    const row = $(el);
    const songNumber = row.find('.grid-item.pos-type .num2').first().text().trim();
    const title = row.find('.grid-item.title3 p span').first().text().trim();
    const artist = row.find('.grid-item.title4.singer span').first().text().trim();

    if (!songNumber || !title || seen.has(songNumber)) return;
    seen.add(songNumber);
    results.push({ songNumber, title, artist: artist || '' });
  });

  return results;
}

async function fetchTjHtml(query) {
  const params = new URLSearchParams({
    pageNo: '1',
    pageRowCnt: '15',
    strSotrGubun: 'ASC',
    strSortType: '',
    nationType: '',
    strType: '0', // 통합검색 (integrated): matches title/singer/lyricist/composer/song number/medley in one request.
    searchTxt: query,
  });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(`${TJ_SEARCH_URL}?${params.toString()}`, {
      signal: controller.signal,
      headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; UtaNoteSearch/1.0)',
        Accept: 'text/html',
      },
    });

    if (!response.ok) {
      throw new Error(`TJ Media returned HTTP ${response.status}`);
    }

    return await response.text();
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = async (req, res) => {
  setCorsHeaders(res);

  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }

  if (req.method !== 'GET') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const rawQuery = req.query ? req.query.q : undefined;
  const query = typeof rawQuery === 'string' ? rawQuery.trim() : '';

  if (!query) {
    res.status(400).json({ error: 'Query parameter "q" is required' });
    return;
  }

  // TJ's own front-end strips whitespace from searchTxt before submitting.
  const tjQuery = query.replace(/\s+/g, '');
  const cacheKey = tjQuery.toLowerCase();

  const cached = getCached(cacheKey);
  if (cached) {
    res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=60');
    res.status(200).json({ results: cached });
    return;
  }

  let html;
  try {
    html = await fetchTjHtml(tjQuery);
  } catch (err) {
    res.status(502).json({ error: 'Unable to reach TJ Media search' });
    return;
  }

  let results;
  try {
    results = parseResults(html);
  } catch (err) {
    res.status(500).json({ error: 'Unable to parse TJ Media search results' });
    return;
  }

  setCached(cacheKey, results);
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=60');
  res.status(200).json({ results });
};

// Exposed for fixture-based unit testing (see test/api/tj-search.test.js).
// Vercel only uses the default export above as the request handler.
module.exports.parseResults = parseResults;
