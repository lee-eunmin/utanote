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
  writeBatch,
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

  test('a removal marker still cannot be revived after a hard-delete is allowed', async () => {
    // Regression guard: allowing owner deletes must not loosen updates.
    await seedAlice();
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
    await assertFails(setDoc(ref, liveMembership(2)));
    await assertFails(setDoc(ref, membershipRemoval(1), { merge: true }));
    await assertSucceeds(setDoc(ref, liveMembership(3)));
  });

  test('no other paths are readable or writable', async () => {
    const db = alice();
    await assertFails(setDoc(doc(db, 'users', 'alice'), { name: 'x' }));
    await assertFails(getDoc(doc(db, 'users', 'alice')));
    await assertFails(setDoc(doc(db, 'users/alice/other', 'x'), { deleted: false }));
    await assertFails(setDoc(doc(db, 'songs', SONG), liveSong()));
  });
});

// Phase B-5: "계정 및 클라우드 데이터 삭제" hard-deletes the owner's documents.
describe('account deletion (hard delete)', () => {
  test('owner can hard-delete own songs, folders and memberships', async () => {
    await seedAlice();
    const db = alice();
    await assertSucceeds(deleteDoc(songRef(db)));
    await assertSucceeds(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
    await assertSucceeds(deleteDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP)));
    await assertSucceeds(getDocs(collection(db, 'users/alice/songs')));
    let left = -1;
    await env.withSecurityRulesDisabled(async (ctx) => {
      const d = ctx.firestore();
      const counts = await Promise.all(
        ['songs', 'folders', 'folderSongs'].map(
          async (c) => (await getDocs(collection(d, 'users/alice/' + c))).size,
        ),
      );
      left = counts.reduce((a, b) => a + b, 0);
    });
    if (left !== 0) throw new Error('documents left: ' + left);
  });

  test('owner can hard-delete deletion markers and missing documents', async () => {
    await seedAlice();
    const db = alice();
    await assertSucceeds(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
    await assertSucceeds(deleteDoc(songRef(db)));
    await assertSucceeds(deleteDoc(songRef(db, 'alice', SONG2))); // never existed
  });

  test('another signed-in user cannot hard-delete alice data', async () => {
    await seedAlice();
    const db = bob();
    await assertFails(deleteDoc(songRef(db)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP)));
    await assertFails(deleteDoc(songRef(db, 'alice', SONG2)));
  });

  test('signed-out clients cannot hard-delete anything', async () => {
    await seedAlice();
    const db = anon();
    await assertFails(deleteDoc(songRef(db)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP)));
  });

  test('deleting is limited to the three backup collections', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const d = ctx.firestore();
      await setDoc(doc(d, 'users', 'alice'), { name: 'x' });
      await setDoc(doc(d, 'users/alice/other', 'x'), { deleted: false });
      await setDoc(doc(d, 'songs', SONG), liveSong());
    });
    const db = alice();
    await assertFails(deleteDoc(doc(db, 'users', 'alice')));
    await assertFails(deleteDoc(doc(db, 'users/alice/other', 'x')));
    await assertFails(deleteDoc(doc(db, 'songs', SONG)));
  });

  test('alice deleting her data leaves bob data untouched', async () => {
    await seedAlice();
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(songRef(ctx.firestore(), 'bob'), liveSong());
    });
    await assertSucceeds(deleteDoc(songRef(alice())));
    await assertSucceeds(getDoc(songRef(bob(), 'bob')));
    const bobSong = await getDoc(songRef(bob(), 'bob'));
    if (!bobSong.exists()) throw new Error('bob song was deleted');
  });
});

// Phase B-5.1: accountDeletionBlocks/{uid} stops a stale device of a
// deleted account from re-creating data; owner hard deletes stay allowed.
describe('account deletion block', () => {
  const blockRef = (db, uid = 'alice') => doc(db, 'accountDeletionBlocks', uid);
  const block = () => ({ deletedAt: serverTimestamp() });

  async function seedBlock(uid = 'alice') {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(blockRef(ctx.firestore(), uid), { deletedAt: new Date() });
    });
  }

  test('no block: normal create/update works', async () => {
    await seedAlice();
    const db = alice();
    await assertSucceeds(setDoc(songRef(db, 'alice', SONG2), liveSong(SONG2)));
    await assertSucceeds(setDoc(songRef(db), { ...liveSong(), title: '수정' }));
    await assertSucceeds(
      setDoc(doc(db, 'users/alice/folders', FOLDER), { ...liveFolder(), name: '수정' }),
    );
  });

  test('a 400-write batch still passes the block check', async () => {
    const db = alice();
    const batch = writeBatch(db);
    for (let i = 0; i < 400; i++) {
      const id = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
      batch.set(songRef(db, 'alice', id), liveSong(id));
    }
    await assertSucceeds(batch.commit());
  });

  test('block: songs create and update are refused', async () => {
    await seedAlice();
    await seedBlock();
    const db = alice();
    await assertFails(setDoc(songRef(db, 'alice', SONG2), liveSong(SONG2)));
    await assertFails(setDoc(songRef(db), { ...liveSong(), title: '수정' }));
    await assertFails(setDoc(songRef(db), deletion({ syncId: SONG }), { merge: true }));
  });

  test('block: folders create and update are refused', async () => {
    await seedAlice();
    await seedBlock();
    const db = alice();
    await assertFails(setDoc(doc(db, 'users/alice/folders', SONG2), liveFolder(SONG2)));
    await assertFails(
      setDoc(doc(db, 'users/alice/folders', FOLDER), { ...liveFolder(), name: '수정' }),
    );
  });

  test('block: folderSongs create and update are refused', async () => {
    await seedBlock();
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertFails(setDoc(ref, liveMembership(1))); // create
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users/alice/folderSongs', MEMBERSHIP), liveMembership(1));
    });
    await assertFails(setDoc(ref, membershipRemoval(2), { merge: true })); // update
    await assertFails(setDoc(ref, liveMembership(5))); // update
  });

  test('block: owner hard delete is still allowed', async () => {
    await seedAlice();
    await seedBlock();
    const db = alice();
    await assertSucceeds(deleteDoc(songRef(db)));
    await assertSucceeds(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
    await assertSucceeds(deleteDoc(doc(db, 'users/alice/folderSongs', MEMBERSHIP)));
  });

  test('block: another uid still cannot delete', async () => {
    await seedAlice();
    await seedBlock();
    const db = bob();
    await assertFails(deleteDoc(songRef(db)));
    await assertFails(deleteDoc(doc(db, 'users/alice/folders', FOLDER)));
  });

  test('alice block does not affect bob', async () => {
    await seedBlock('alice');
    await assertSucceeds(setDoc(songRef(bob(), 'bob'), liveSong()));
  });

  test('owner can create own block (deletedAt = server time) and read it', async () => {
    const db = alice();
    await assertSucceeds(setDoc(blockRef(db), block()));
    await assertSucceeds(getDoc(blockRef(db)));
  });

  test('block must have exactly deletedAt as server time', async () => {
    const db = alice();
    await assertFails(setDoc(blockRef(db), {}));
    await assertFails(setDoc(blockRef(db), { deletedAt: new Date(0) }));
    await assertFails(
      setDoc(blockRef(db), { deletedAt: serverTimestamp(), email: 'alice@example.com' }),
    );
  });

  test('another uid or a signed-out client cannot create, read or touch a block', async () => {
    await assertFails(setDoc(blockRef(bob()), block()));
    await assertFails(setDoc(blockRef(anon()), block()));
    await seedBlock();
    await assertFails(getDoc(blockRef(bob())));
    await assertFails(getDoc(blockRef(anon())));
    await assertFails(setDoc(blockRef(bob()), block()));
    await assertFails(deleteDoc(blockRef(bob())));
  });

  test('an existing block cannot be overwritten, updated or deleted', async () => {
    const db = alice();
    await assertSucceeds(setDoc(blockRef(db), block()));
    await assertFails(setDoc(blockRef(db), block())); // overwrite = update
    await assertFails(setDoc(blockRef(db), { deletedAt: serverTimestamp() }, { merge: true }));
    await assertFails(deleteDoc(blockRef(db)));
  });

  test('revision rules unchanged without a block', async () => {
    await seedAlice();
    const db = alice();
    const ref = doc(db, 'users/alice/folderSongs', MEMBERSHIP);
    await assertSucceeds(setDoc(ref, membershipRemoval(2), { merge: true }));
    await assertFails(setDoc(ref, liveMembership(2)));
    await assertFails(setDoc(ref, membershipRemoval(1), { merge: true }));
    await assertSucceeds(setDoc(ref, liveMembership(3)));
  });
});
