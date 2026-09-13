# UtaNote (Karaoke Songbook) — Compatibility Rules

This is a from-scratch Flutter rewrite of an existing, published FlutterFlow
Android app. The rewrite must be able to **replace** the existing Google Play
app in-place without losing any existing user's data. The rules below exist
to protect that. Read them before touching Android config or the storage
layer.

## 1. Android `applicationId` must stay exactly `com.eungman.UTANOTE`

- Set in `android/app/build.gradle.kts` → `defaultConfig.applicationId`.
- This is the Google Play package identity for the already-published app.
  Any change — including casing — makes Android/Play treat it as a
  different app, orphaning existing installs and their local data.
- The Gradle `namespace` and the Kotlin source package
  (`android/app/src/main/kotlin/com/eungman/utanote/...`) are intentionally
  **lowercase** and different from `applicationId`. That's fine and
  unrelated: `namespace`/package only affect generated `R`/source layout,
  not the Play identity. Do not "fix" this mismatch.
- Signing config is untouched (still debug-signed) — do not change signing
  until explicitly asked to.

## 2. The Android database file must stay `songbook.db`

- Opened via `getDatabasesPath()` + `songbook.db` in
  `lib/storage/android/sqlite_local_storage.dart`.
- Opening any other filename means a fresh, empty database instead of the
  existing one — silent data loss for every upgrading user.

## 3. Never destroy existing columns/tables/rows

- The legacy `songs`, `folders`, `folder_songs` schema (see below) must
  keep working as-is. Migrations may only **add** columns/tables, never
  drop, rename, or rewrite existing ones.
- `onUpgrade` in `sqlite_local_storage.dart` is additive-only. It also
  re-checks column existence in `onOpen` on every launch (via
  `PRAGMA table_info`) rather than trusting `oldVersion` alone — this
  protects against the on-disk `user_version` not matching our
  expectations for a database that predates this rewrite.
- If you need a new column/table, add it the same way: `ALTER TABLE ...
  ADD COLUMN` / `CREATE TABLE IF NOT EXISTS`, guarded by an existence
  check, never a destructive rebuild.

## 4. Legacy schema reference

```sql
CREATE TABLE songs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    karaoke_type TEXT NOT NULL,
    song_number TEXT NOT NULL,
    title TEXT NOT NULL,
    artist TEXT,
    key_type TEXT,
    key_offset INTEGER DEFAULT 0,
    difficulty TEXT,
    practice_status TEXT,
    memo TEXT,
    favorite INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
    -- search_aliases TEXT  (added by this rewrite, see below)
);

CREATE TABLE folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE folder_songs (
    folder_id INTEGER NOT NULL,
    song_id INTEGER NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (folder_id, song_id)
);
```

- `karaoke_type` must not be removed. Existing rows may have `'KY'`; the
  app is becoming TJ-focused but must keep KY rows readable. New songs
  created in-app default to `'TJ'`.
- `memo` must not be removed or backfilled automatically. It is preserved
  on the model (`Song.memo`) purely for legacy data integrity and is
  **never shown or editable in the UI**.
- `search_aliases` (new, nullable TEXT) replaces memo's role in search.
  It is added via migration, stored as a JSON-encoded string array
  (e.g. `["밤을 달리다","요루니카케루"]`), and is **never** populated from
  `memo` automatically — aliases are a distinct, user-entered concept.
  Search matches `song_number`, `title`, `artist`, and `search_aliases`.

## 5. Storage architecture

- `lib/storage/local_storage.dart` — platform-agnostic `LocalStorage`
  interface bundling `SongRepository` + `FolderRepository`.
- `lib/storage/local_storage_factory.dart` — conditional export that
  picks the implementation at compile time:
  - `dart.library.io` present → Android → `lib/storage/android/sqlite_local_storage.dart` (sqflite, `songbook.db`).
  - otherwise → Web → `lib/storage/web/web_local_storage.dart`
    (`shared_preferences`, i.e. browser `localStorage`; JSON-encoded songs/folders; per-browser only, no login/Firebase/Supabase/remote sync).
- `lib/storage/memory/in_memory_local_storage.dart` — pure-Dart fake used
  by tests, so tests don't need platform channels.
- Do not import the Android (`sqflite`) implementation from code that also
  needs to compile for Web, or vice versa — that's the whole point of the
  conditional-export factory. Always depend on the `LocalStorage` /
  `SongRepository` / `FolderRepository` interfaces, not a concrete class.

## 6. Current state / what's NOT built yet

- `lib/ui/song_list_screen.dart` is a **temporary, unstyled** screen that
  only proves create/search/persist works end-to-end. Real UI/visual
  design is intentionally deferred until reference screenshots are
  provided.
- No TJ website search or any external/network API is implemented yet.
- No login, Firebase, Supabase, or remote/user database — and none should
  be added without an explicit decision to change that.
