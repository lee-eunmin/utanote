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
- Cloud (Android only): user-initiated first connection (section 8),
  manual + automatic two-way sync for bound devices (sections 9–10). No
  periodic/realtime listener/background (app-closed) sync, no multi-account
  switching, no Web/iOS sync, no Supabase.

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
  `lib/sync/cloud_sync_backend.dart` (`CloudDocCodec`). Sync never
  hard-deletes (`deleted: true` + `deletedAtMs`); the only hard delete is
  account deletion (section 11). Local integer ids never go to the cloud.
  Offline persistence is off; SQLite `sync_dirty` stays the source of truth.
- Rules: `firestore.rules` (owner-only, no revive of deleted docs, hard
  delete by the owner only (account deletion), id must match sync id). Tests: `firestore_rules_test/` (emulator,
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

## 10. Automatic sync & backup prompt (Phase B-4B, Android only)

- `CloudSyncController` + `AutoSyncConfig` (set in
  `account/android/firebase_auth_gateway.dart`): automatic two-way sync,
  only while the device is bound to the signed-in account (never for an
  unbound device — that still uses "클라우드 백업 설정" only). Triggers:
  restored session on start; foreground resume (`AppLifecycleListener` in
  `AppShell`, ≥1 min since the last attempt); 5 s after the last user
  write (`ObservedLocalStorage` in `main.dart` wraps the UI storage; reads
  and cloud-apply writes never trigger). One run at a time; a data change
  or "지금 동기화" during a run → exactly one follow-up run. Failures are
  quiet (status in the account sheet only), dirty rows stay, backoff
  1→2→4…→15 min for automatic triggers; "지금 동기화" ignores throttle and
  backoff.
- Backup prompt (`lib/ui/backup_prompt.dart`, `BackupPromptGate` in
  `AppShell`): once per launch, after the first frame settles and sign-in
  has started, only if `account_uid` is absent, ≥1 song exists, sign-in is
  usable and not snoozed. "나중에"/closing → snoozed 7 days via
  SharedPreferences key `backup_prompt_snoozed_at_ms` (local UI setting,
  never synced). Signed out → "Google 계정 연결" (sign in, then the B-3
  first-connection flow in the account sheet); signed in but unbound →
  "클라우드 백업 설정" (no account picker). Never shown once bound.

## 11. Account & cloud data deletion (Phase B-5, Android only)

- Account sheet → "계정 및 클라우드 데이터 삭제" → confirmation dialog →
  `AccountDeletionController` (`lib/account/account_deletion.dart`). Not the
  same as sign-out (which never deletes anything).
- Order: suspend all sync (`CloudSyncController.suspendForAccountDeletion`,
  waits for a running run) → Google re-authentication, must be the same uid
  as the signed-in user and the bound `account_uid` (cancel/failure/mismatch
  → nothing deleted, sync resumes) → `sync_meta.account_deletion_*` marker →
  hard-delete `users/{uid}/songs|folders|folderSongs` in ≤400 batches
  (`CloudAccountDataEraser`; Firestore impl
  `lib/sync/android/firestore_account_data_eraser.dart`, separate from the
  sync backend, idempotent) → `currentUser.delete()` → one SQLite
  transaction `finishAccountDeletion` → Google disconnect + sign-out.
- While the marker exists (`account_deletion_state`: cloud_deleting /
  cloud_deleted / auth_deleted) every sync path refuses to run (controller,
  engines and store all check). Retrying resumes; `auth_deleted` is
  finished locally on the next start.
- Local songs/folders/memberships/tombstones/sync ids are kept. Removed:
  `SyncMetaKeys.cloudBindingKeys` (account_uid, email hint, cursors, last
  sync, initial sync state) and the marker; every row set `sync_dirty = 1`
  so a later first connection (any account) uploads everything again.
  Backup files and their meta keys are kept. No schema change.
- After success the backup prompt is snoozed (`onAccountDeleted` in
  `main.dart`) and not shown in the same run.
- Public deletion-request/privacy URLs: `lib/config/account_links.dart`
  (null until the web page exists).

### 11.1 Deletion safeguards (Phase B-5.1)

- Before any user document is deleted, the app creates
  `accountDeletionBlocks/{uid}` (only field: `deletedAt` = server time; no
  email/name/songs) and confirms it with a server read. Not confirmed →
  nothing is deleted (if the cloud says "no block" and the local stage is
  still `blocking`, the local marker is dropped and sync resumes). The
  block is never removed by the app.
- Rules: while the block exists, every create/update under `users/{uid}`
  is refused (stale devices with a still-valid ID token can't re-create
  data); owner hard deletes stay allowed. The block itself: owner-only
  read/create, exactly `{deletedAt: request.time}`, no update/delete.
- Another device still bound to the deleted uid: if the signed-in Google
  email equals `account_email_hint` (case-insensitive) but the uid differs
  (account re-created), `AccountLinkStatus.previousAccountSameEmail`: signed
  in, no sync, and the account sheet offers "이 기기의 이전 클라우드 연결
  해제" (confirmation dialog). Approving runs
  `SqliteLocalSyncStore.releasePreviousBinding` — the same local reset as a
  finished deletion (binding/sync meta + deletion marker removed, all rows
  dirty, data and sync ids kept); then the user starts "클라우드 백업
  설정" themselves. Different or unknown email → blocked and signed out as
  before. Nothing is ever released automatically.
