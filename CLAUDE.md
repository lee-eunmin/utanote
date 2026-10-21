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
- Current schema version is **5** (`kSongbookDatabaseVersion` in
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
- Phase B-2: Firebase Auth + Google Sign-In only (`lib/account/`,
  Android only; Web gets `account_stub.dart`). Sign-in never reads/writes
  songs, folders, `sync_dirty` or `sync_meta.account_uid`; sign-out ends
  the Firebase/Google session only. A device bound to another account
  (`account_uid` ≠ signed-in uid) is signed straight back out.
  `lib/firebase_options.dart` is a placeholder until `flutterfire
  configure` overwrites it; the google-services Gradle plugin is applied
  only when `android/app/google-services.json` exists. Without config the
  app runs normally with sign-in hidden.
- Phase B-3 (Android only): user-initiated **first cloud connection**
  only — see section 8. No automatic/periodic/realtime/background sync,
  no multi-account switching, no Web/iOS sync, no Supabase.

## 7. Cloud-sync readiness (schema v3–v4, Android only)

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
- `sync_meta(key, value)`: account/sync keys (`SyncMetaKeys`) are written
  only by the B-3 first connection (section 8). The legacy orphan `folder_songs` cleanup runs once and
  is skipped while `sync_apply_in_progress` is set.
- v4: `sync_dirty INTEGER NOT NULL DEFAULT 1` on `songs`, `folders`,
  `folder_songs`, `sync_tombstones` (pre-v4 rows start dirty = "needs
  upload"). User writes through the repositories always set 1; only
  `SqliteLocalStorage.cloudApply` (`lib/storage/cloud_apply.dart`) writes
  0. The path decides, never `sync_apply_in_progress`. Cloud upserts never
  revive a song/folder that has a local tombstone.
- The pre-v3 backup (`songbook.pre_sync_v3.backup.db`) is pinned to
  target v3 (`kPreSyncBackupTargetVersion`) and never touched by B-3.
- Web storage is unchanged (no sync ids yet).

## 8. First cloud connection (Phase B-3, Android only)

- Firestore: `users/{uid}/songs/{songSyncId}`, `users/{uid}/folders/{folderSyncId}`,
  `users/{uid}/folderSongs/{folderSyncId}_{songSyncId}`. Format in
  `lib/sync/cloud_sync_backend.dart` (`CloudDocCodec`). Never hard-deleted
  (`deleted: true` + `deletedAtMs`); local integer ids never go to the cloud.
  Offline persistence is off; SQLite `sync_dirty` stays the source of truth.
- Rules: `firestore.rules` (owner-only, no revive of deleted docs, no hard
  delete, id must match sync id). Tests: `firestore_rules_test/` (emulator,
  `demo-` project only). Rules are deployed by the user, never automatically.
- Pure-Dart engine `lib/sync/initial_sync_engine.dart` + planner
  `initial_sync_plan.dart`; SQLite side `lib/storage/android/sqlite_sync_store.dart`;
  Firestore side `lib/sync/android/firestore_cloud_sync_backend.dart`.
- Order: classify → `songbook.pre_cloud_sync_v4.backup.db` (once, never
  overwritten; failure aborts) → `initial_sync_state=in_progress` → upload
  (≤400/batch) → ONE SQLite transaction: apply cloud winners (clean),
  guarded dirty clear, write `account_uid`. Local data is untouched on failure.
- Both sides with data → user picks 합치기/취소 only. Merge: same sync id →
  deletion wins, else newer `updatedAtMs` (legacy NULL → `updated_at`), tie
  → cloud. Different ids are never de-duplicated.
- `sync_dirty` is cleared only via `clearSyncDirtyIfUnchanged` tokens
  (version at snapshot time must still match).
- `account_uid` is written only after a fully successful run; sign-out never
  clears it.

## 9. Manual two-way sync (Phase B-4A, Android only)

- "지금 동기화" in the account sheet, only for a bound device. Still no
  automatic trigger (start/resume/edit) of any kind.
- `lib/sync/manual_sync.dart` (`ManualSyncEngine`): pull changed docs per
  collection since `pull_cursor_{songs,folders,folder_songs}_ms`
  (`serverUpdatedAt`, 60 s overlap; no cursor = full read) + look up the
  cloud state of every locally dirty row → one SQLite transaction (aborts
  unless `account_uid` == signed-in uid) applying deletion-wins /
  newer-wins / tie-to-cloud → upload dirty rows (≤400/batch, guarded dirty
  clear per batch) → only on full success raise cursors and
  `last_successful_sync_at_ms`.
- Songs/folders: a live row is never uploaded over a cloud `deleted: true`
  doc (deletion always wins; the rules would reject the whole batch).
- Folder memberships use **revisions** (schema v5): `folder_songs.revision`
  (live) and `sync_tombstones.revision` (removal, `folder_song` rows only);
  cloud field `revision`. Every user change is the next revision (add 1,
  remove 2, re-add 3, ...). Winner: higher revision; same revision →
  removal; both live → newer, tie → cloud (`compareMembership` in
  `lib/sync/sync_records.dart`). A deleted song/folder still takes its
  memberships with it regardless of revision. Pre-v5 data: live = 1,
  removal = 2 (local backfill and cloud parse default), which keeps the old
  "removal beats live" outcome for legacy data. Rules: revision never goes
  down; a removed membership becomes live only with a higher revision.
- Screens reload through `AppShell` when `CloudSyncController.dataVersion`
  changes.
