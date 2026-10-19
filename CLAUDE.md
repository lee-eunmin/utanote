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
- Release builds are signed with the upload key from `android/key.properties`
  (`signingConfigs.release`). Do not change signing config or keys unless
  explicitly asked to.

## 2. The Android database file must stay `songbook.db`

- Opened via `getDatabasesPath()` + `songbook.db` in
  `lib/storage/android/sqlite_local_storage.dart`.
- Opening any other filename means a fresh, empty database instead of the
  existing one — silent data loss for every upgrading user.

## 3. Never destroy existing columns/tables/rows

- The legacy `songs`, `folders`, `folder_songs` schema (see below) must
  keep working as-is. Migrations may only **add** columns/tables, never
  drop, rename, or rewrite existing ones.
- Current schema version is **4** (`kSongbookDatabaseVersion` in
  `lib/storage/android/sqlite_schema.dart`). The legacy app's database has
  `user_version` 0, so sqflite runs `onCreate` (not `onUpgrade`) for
  upgrading users. All schema work therefore lives in one idempotent,
  additive-only `ensureSchema()` that runs from `onCreate`, `onUpgrade`
  **and** `onOpen` (every launch), checking existence via `PRAGMA
  table_info` / `sqlite_master` instead of trusting `oldVersion`.
- If you need a new column/table, add it to `ensureSchema()` the same way:
  `ALTER TABLE ... ADD COLUMN` / `CREATE TABLE IF NOT EXISTS`, guarded by an
  existence check, never a destructive rebuild.
- Before the first open that migrates an older database, a one-time copy
  `songbook.pre_sync_v3.backup.db` is made next to `songbook.db`
  (`sqlite_pre_migration_backup.dart`; file copy, not `VACUUM INTO`, which
  Android < 11 can't run). The app never deletes it.

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
    -- sync_id TEXT, sync_updated_at_ms INTEGER  (v3, see section 7)
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

- UI: song list, folders, and TJ search tabs (`lib/ui/`). TJ search goes
  through the `/api/tj-search` proxy (`api/tj-search.js`); AdMob native ads
  on Android.
- No login, Firebase, Supabase, or remote/user database yet — and none
  should be added without an explicit decision to change that.

## 7. Cloud-sync readiness (schema v3–v4, Android only, no network code)

- `songs.sync_id` / `folders.sync_id`: UUID v4 (`lib/storage/sync_id.dart`),
  unique-indexed, backfilled only where NULL/empty, assigned on create and
  never changed afterwards. Local integer ids stay the in-app identity and
  the `folder_songs` join key.
- `sync_updated_at_ms` (UTC epoch ms) on songs/folders/folder_songs, set on
  writes. Left NULL for untouched legacy rows; legacy `created_at` /
  `updated_at` strings are never rewritten or converted.
- `sync_tombstones(entity_type, sync_id, related_sync_id, deleted_at_ms)`:
  rows are still hard-deleted; deletes of songs/folders and removals of a
  song from a folder are recorded here in the same transaction.
- `sync_meta(key, value)`: account/sync keys are reserved but empty
  (`SyncMetaKeys`). The legacy orphan `folder_songs` cleanup runs once and
  is skipped while `sync_apply_in_progress` is set.
- v4: `sync_dirty INTEGER NOT NULL DEFAULT 1` on `songs`, `folders`,
  `folder_songs`, `sync_tombstones` (pre-v4 rows start dirty = "needs
  upload"). User writes through the repositories always set 1; only
  `SqliteLocalStorage.cloudApply` (`lib/storage/cloud_apply.dart`) writes
  0. The path decides, never `sync_apply_in_progress`. Cloud upserts never
  revive a song/folder that has a local tombstone.
- The pre-v3 backup (`songbook.pre_sync_v3.backup.db`) is pinned to
  target v3 (`kPreSyncBackupTargetVersion`); a separate
  `songbook.pre_cloud_sync_v4.backup.db` is planned before the first cloud
  upload (not built yet).
- Web storage is unchanged (no sync ids yet).
