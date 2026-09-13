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

// TJ category codes for strType. These are NOT a combinable bitmask despite
// the power-of-two values (verified against the live endpoint: strType=3
// returns no result section at all) — each search hits exactly one category.
const TJ_STR_TYPE = {
  TITLE: '1',
  ARTIST: '2',
  SONG_NUMBER: '16',
};

// TJ renders each category as its own "곡 제목 / 가수 / 작사가 / 작곡가 /
// 곡 번호 / 메들리" section (a div.music-search-list with an <h2> heading),
// each containing its own "grid-container list" rows. Requesting a single
// strType is *usually* enough to get back only that one section, but we
// still gate parsing on the heading text itself rather than trusting that —
// so a lyricist/composer/medley section can never contribute rows even if
// TJ ever renders more than the requested category on the same response.
// Headings are compared with whitespace stripped ("곡 번호" vs "곡번호").
const TJ_SECTION_HEADING = {
  TITLE: '곡제목',
  ARTIST: '가수',
  SONG_NUMBER: '곡번호',
};

function normalizeHeading(text) {
  return text.replace(/\s+/g, '');
}

/// Parses only the rows that live under the TJ result section whose <h2>
/// heading matches `category` (one of the TJ_SECTION_HEADING keys), into
/// normalized {songNumber, title, artist} rows, deduplicated by songNumber.
/// Rows under any other section — including 작사가/작곡가/메들리 — are
/// never read, regardless of what else is present on the page.
function parseSection(html, category) {
  const expectedHeading = TJ_SECTION_HEADING[category];
  const $ = cheerio.load(html);
  const results = [];
  const seen = new Set();

  $('div.music-search-list').each((_, sectionEl) => {
    const section = $(sectionEl);
    const heading = normalizeHeading(section.find('h2').first().text());
    if (heading !== expectedHeading) return;

    section.find('ul.grid-container.list').each((_, el) => {
      const row = $(el);
      const songNumber = row.find('.grid-item.pos-type .num2').first().text().trim();
      const title = row.find('.grid-item.title3 p span').first().text().trim();
      const artist = row.find('.grid-item.title4.singer span').first().text().trim();

      if (!songNumber || !title || seen.has(songNumber)) return;
      seen.add(songNumber);
      results.push({ songNumber, title, artist: artist || '' });
    });
  });

  return results;
}

async function fetchTjHtml(query, strType) {
  const params = new URLSearchParams({
    pageNo: '1',
    pageRowCnt: '15',
    strSotrGubun: 'ASC',
    strSortType: '',
    nationType: '',
    strType,
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

async function searchByCategory(query, category) {
  const html = await fetchTjHtml(query, TJ_STR_TYPE[category]);
  try {
    return parseSection(html, category);
  } catch (err) {
    err.isParseError = true;
    throw err;
  }
}

// Lowercases and strips all whitespace so "아이유" / " 아이 유 " / "AIU"-style
// spacing/case differences don't affect comparison. Deliberately more
// aggressive than normalizeHeading (which only collapses whitespace) since
// this is for query/title/artist comparison, not exact heading matching.
function normalizeForMatch(text) {
  return (text || '').toLowerCase().replace(/\s+/g, '');
}

// Tier for a TITLE-search result, based on how the normalized title relates
// to the normalized query. (ARTIST-search results never go through this —
// see rankBySource — because literal comparison against the displayed
// artist string is not a reliable relevance signal for them.)
//   0 = normalized title exactly equals the query
//   2 = normalized title contains the query
//   3 = broad TJ title-search fallback (matched for some other reason —
//       alias, romanization, lyrics, etc.)
function titleTier(result, normQuery) {
  const normTitle = normalizeForMatch(result.title);
  if (normTitle === normQuery) return 0;
  if (normTitle.includes(normQuery)) return 2;
  return 3;
}

// Source-aware relevance ranking. Merges TJ's TITLE and ARTIST category
// results into one deduplicated-by-songNumber list, ranked as:
//   Tier 0 - TITLE-search result whose normalized title == query
//   Tier 1 - ANY result returned by TJ's ARTIST search
//   Tier 2 - TITLE-search result whose normalized title contains query
//   Tier 3 - remaining broad TITLE-search fallback results
//
// Tier 1 deliberately does NOT require the displayed artist string to
// literally match the query. TJ's own ARTIST search already resolves
// aliases/transliterations on its end — e.g. searching "아이유" can match a
// song whose displayed artist is "IU" — so a literal artist-string
// comparison here would defeat the point of using TJ's ARTIST category at
// all and drop exactly the results it exists to surface. Trusting "TJ's
// ARTIST search returned this" as the relevance signal (rather than
// re-deriving it from the artist string) is what makes this source-aware
// rather than literal-match-based.
//
// If a songNumber appears in both categories, only one copy is kept, at
// whichever tier is better (lower). Within a tier, TJ's original order is
// preserved.
function rankBySource(titleResults, artistResults, query) {
  const normQuery = normalizeForMatch(query);
  const bySongNumber = new Map();

  const consider = (result, tier, order) => {
    const existing = bySongNumber.get(result.songNumber);
    if (!existing || tier < existing.tier) {
      bySongNumber.set(result.songNumber, { result, tier, order });
    }
  };

  titleResults.forEach((result, index) => {
    consider(result, titleTier(result, normQuery), index);
  });
  // Every ARTIST-search result lands in tier 1, regardless of its literal
  // artist string (see doc comment above).
  artistResults.forEach((result, index) => {
    consider(result, 1, titleResults.length + index);
  });

  return [...bySongNumber.values()]
    .sort((a, b) => a.tier - b.tier || a.order - b.order)
    .map((entry) => entry.result);
}

/// Searches only the categories relevant to our app (title, artist, song
/// number) so TJ's lyricist/composer/medley-only matches — which our API
/// doesn't expose and would otherwise look like irrelevant noise — never
/// appear in the response. Merged, deduplicated by songNumber, and ranked
/// by source-aware relevance (see rankBySource) so an exact title match or
/// any artist-search hit sorts before TJ's broader title-only fuzzy
/// matches.
///
/// This deliberately does NOT add literal post-filtering on top of TJ's own
/// title/artist matching — TJ's artist search can surface useful aliases or
/// romanizations that a literal substring filter would drop. Reordering by
/// relevance keeps those results reachable while putting obviously-relevant
/// songs first.
async function searchRelevant(query) {
  const isNumeric = /^\d+$/.test(query);

  if (isNumeric) {
    return searchByCategory(query, 'SONG_NUMBER');
  }

  const [titleResults, artistResults] = await Promise.all([
    searchByCategory(query, 'TITLE'),
    searchByCategory(query, 'ARTIST'),
  ]);

  return rankBySource(titleResults, artistResults, query);
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

  let results;
  try {
    results = await searchRelevant(tjQuery);
  } catch (err) {
    if (err.isParseError) {
      res.status(500).json({ error: 'Unable to parse TJ Media search results' });
    } else {
      res.status(502).json({ error: 'Unable to reach TJ Media search' });
    }
    return;
  }

  setCached(cacheKey, results);
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=60');
  res.status(200).json({ results });
};

// Exposed for fixture-based unit testing (see test/api/tj-search.test.js).
// Vercel only uses the default export above as the request handler.
module.exports.parseSection = parseSection;
module.exports.searchRelevant = searchRelevant;
module.exports.TJ_STR_TYPE = TJ_STR_TYPE;
module.exports.rankBySource = rankBySource;
