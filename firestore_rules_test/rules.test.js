// Security-rule tests for ../firestore.rules (emulator only; see README).
import { after, before, beforeEach, describe, test } from 'node:test';
import { readFileSync } from 'node:fs';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
} from 'firebase/firestore';

const PROJECT_ID = 'demo-utanote-rules';
const SONG = '11111111-1111-4111-8111-111111111111';
const SONG2 = '22222222-2222-4222-8222-222222222222';
const FOLDER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const MEMBERSHIP = FOLDER + '_' + SONG;

const liveSong = (syncId = SONG) => ({
  syncId,
  provider: 'TJ',
  songNumber: '12345',
  title: '밤을 달리다',
  artist: 'YOASOBI',
  keyType: null,
  keyOffset: 0,
  difficulty: null,
  practiceStatus: null,
  memo: null,
  favorite: false,
  searchAliases: ['요루니카케루'],
  createdAt: '2024-01-01T00:00:00.000',
  updatedAt: '2024-01-01T00:00:00.000',
  updatedAtMs: 1704067200000,
  serverUpdatedAt: serverTimestamp(),
  deleted: false,
  deletedAtMs: null,
});

const liveFolder = (syncId = FOLDER) => ({
  syncId,
  name: '애창곡',
  createdAt: '2024-01-01T00:00:00.000',
  updatedAt: '2024-01-01T00:00:00.000',
  updatedAtMs: 1704067200000,
  serverUpdatedAt: serverTimestamp(),
  deleted: false,
  deletedAtMs: null,
});

const liveMembership = (revision = 1) => ({
  folderSyncId: FOLDER,
  songSyncId: SONG,
  addedAt: '2024-01-01T00:00:00.000',
  revision,
  updatedAtMs: 1704067200000,
  serverUpdatedAt: serverTimestamp(),
  deleted: false,
  deletedAtMs: null,
});

const membershipRemoval = (revision) =>
  deletion({ folderSyncId: FOLDER, songSyncId: SONG, revision });

const deletion = (ids) => ({
  ...ids,
  deleted: true,
  deletedAtMs: 1704070000000,
  updatedAtMs: 1704070000000,
  serverUpdatedAt: serverTimestamp(),
});

let env;
const alice = () => env.authenticatedContext('alice').firestore();
const bob = () => env.authenticatedContext('bob').firestore();
const anon = () => env.unauthenticatedContext().firestore();
const songRef = (db, uid = 'alice', id = SONG) =>
  doc(db, 'users', uid, 'songs', id);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

after(async () => {
  await env?.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
});

/** Seeds alice's data with rules disabled. */
async function seedAlice() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(songRef(db), liveSong());
    await setDoc(doc(db, 'users/alice/folders', FOLDER), liveFolder());
    await setDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP), liveMembership());
  });
}

describe('owner access', () => {
  test('owner can create and read own songs, folders and memberships', async () => {
    const db = alice();
    await assertSucceeds(setDoc(songRef(db), liveSong()));
    await assertSucceeds(setDoc(doc(db, 'users/alice/folders', FOLDER), liveFolder()));
    await assertSucceeds(
      setDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP), liveMembership()),
    );
    await assertSucceeds(getDoc(songRef(db)));
    await assertSucceeds(getDocs(collection(db, 'users/alice/songs')));
    await assertSucceeds(getDocs(collection(db, 'users/alice/folders')));
    await assertSucceeds(getDocs(collection(db, 'users/alice/folderSongs')));
  });

  test('owner can record a deletion, even for a document that never existed', async () => {
    await seedAlice();
    const db = alice();
    await assertSucceeds(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
    await assertSucceeds(
      setDoc(songRef(db, 'alice', SONG2), deletion({ syncId: SONG2 }), { merge: true }),
    );
  });
});

describe('other accounts are blocked', () => {
  test('another signed-in user cannot read alice data', async () => {
    await seedAlice();
    const db = bob();
    await assertFails(getDoc(songRef(db)));
    await assertFails(getDocs(collection(db, 'users/alice/songs')));
    await assertFails(getDocs(collection(db, 'users/alice/folders')));
    await assertFails(getDocs(collection(db, 'users/alice/folderSongs')));
  });

  test('another signed-in user cannot write alice data', async () => {
    await seedAlice();
    const db = bob();
    await assertFails(setDoc(songRef(db), liveSong()));
    await assertFails(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
    await assertFails(setDoc(songRef(db, 'alice', SONG2), liveSong(SONG2)));
    await assertFails(setDoc(doc(db, 'users/alice/folders', FOLDER), liveFolder()));
    await assertFails(
      setDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP), liveMembership()),
    );
  });

  test('signed-out clients can do nothing', async () => {
    await seedAlice();
    const db = anon();
    await assertFails(getDoc(songRef(db)));
    await assertFails(getDocs(collection(db, 'users/alice/songs')));
    await assertFails(setDoc(songRef(db), liveSong()));
  });
});

describe('data integrity', () => {
  test('a deleted document cannot be revived', async () => {
    await seedAlice();
    const db = alice();
    await assertSucceeds(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
    await assertFails(setDoc(songRef(db), liveSong()));
    await assertFails(setDoc(songRef(db), { syncId: SONG, deleted: false }, { merge: true }));
    // Recording the deletion again is fine.
    await assertSucceeds(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
  });

  test('membership: removal at a new or the same revision is allowed', async () => {
    await seedAlice(); // live, revision 1
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
    // Recording the same removal again (same generation) is fine.
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
  });

  test('membership: a stale or same-revision revive is rejected', async () => {
    await seedAlice();
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
    await assertFails(setDoc(ref, liveMembership(1))); // older
    await assertFails(setDoc(ref, liveMembership(2))); // same revision
    await assertFails(setDoc(ref, { deleted: false }, { merge: true })); // keeps 2
  });

  test('membership: an explicit re-add with a higher revision is allowed', async () => {
    await seedAlice();
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
    await assertSucceeds(setDoc(ref, liveMembership(3)));
    await assertSucceeds(setDoc(ref, membershipRemoval(4), { merge: true }));
    await assertFails(setDoc(ref, liveMembership(4)));
    await assertSucceeds(setDoc(ref, liveMembership(5)));
  });

  test('membership: the revision never goes down', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users/alice/folderSongs', MEMBERSHIP), liveMembership(3));
    });
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertFails(setDoc(ref, liveMembership(2)));
    await assertFails(setDoc(ref, membershipRemoval(2), { merge: true }));
    await assertSucceeds(setDoc(ref, membershipRemoval(3), { merge: true }));
  });

  test('membership: every write needs an integer revision', async () => {
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    const noRevision = liveMembership();
    delete noRevision.revision;
    await assertFails(setDoc(ref, noRevision));
    await assertFails(setDoc(ref, liveMembership('3')));
    await assertSucceeds(setDoc(ref, liveMembership(1)));
  });

  test('membership written before revisions: deleted counts as 2', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      // Shape of a B-3 upload: no revision field.
      const legacy = deletion({ folderSyncId: FOLDER, songSyncId: SONG });
      await setDoc(doc(ctx.firestore(), 'users/alice/folderSongs', MEMBERSHIP), legacy);
    });
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertFails(setDoc(ref, liveMembership(2)));
    await assertSucceeds(setDoc(ref, liveMembership(3)));
  });

  test('another user cannot re-add into alice data, whatever the revision', async () => {
    await seedAlice();
    const ref = doc(bob(), 'users/alice/folderSongs', MEMBERSHIP);
    await assertFails(setDoc(ref, liveMembership(99)));
  });

  test('documents are never hard-deleted', async () => {
    await seedAlice();
    const db = alice();
    await assertFails(deleteDoc(songRef(db)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP)));
  });

  test('document id must match the sync id inside it', async () => {
    const db = alice();
    await assertFails(setDoc(songRef(db, 'alice', SONG2), liveSong()));
    await assertFails(setDoc(doc(db, 'users/alice/folders', SONG2), liveFolder()));
    await assertFails(
      setDoc(doc(db, 'users/alice/folderSongs', SONG + '_' + FOLDER), liveMembership()),
    );
  });

  test('the deleted flag is required', async () => {
    const db = alice();
    const noFlag = liveSong();
    delete noFlag.deleted;
    await assertFails(setDoc(songRef(db), noFlag));
  });

  test('no other paths are readable or writable', async () => {
    const db = alice();
    await assertFails(setDoc(doc(db, 'users', 'alice'), { name: 'x' }));
    await assertFails(getDoc(doc(db, 'users', 'alice')));
    await assertFails(setDoc(doc(db, 'users/alice/other', 'x'), { deleted: false }));
    await assertFails(setDoc(doc(db, 'songs', SONG), liveSong()));
  });
});
