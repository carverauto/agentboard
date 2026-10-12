// Pure owner-control contract tests; no FD, listener or native authority proof.
import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const { validateOwnerResponse } = await import(pathToFileURL(path.join(path.dirname(path.resolve(process.argv[2])), 'owner-control.mjs')));
const base = { type: 'attestation', challenge: 1, validForMs: 250, approvalId: 'approved-fixture', authorityRevision: 8, identity: { invented: true }, socket: { dev: '1', ino: '9223372036854775807' } };
const options = { pending: { sequence: 1, started: 100 }, approvalId: 'approved-fixture', authorityRevision: 8, fingerprint: null, previousDeadline: 0, now: 125 };
const encode = value => Buffer.from(JSON.stringify(value));
let count = 0;
const accepted = validateOwnerResponse(encode(base), options);
assert.equal(accepted.deadline, 350); assert.ok(Object.isFrozen(accepted.snapshot.identity)); count++;
for (const [name, change] of [
  ['extra fields', m => { m.extra = true; }], ['foreign approval', m => { m.approvalId = 'foreign'; }],
  ['old revision', m => { m.authorityRevision--; }], ['future revision', m => { m.authorityRevision++; }],
  ['replayed challenge', m => { m.challenge = 0; }], ['future challenge', m => { m.challenge++; }],
  ['wrong type', m => { m.type = 'renew'; }], ['oversized health lease', m => { m.validForMs = 251; }],
  ['zero health lease', m => { m.validForMs = 0; }], ['fractional health lease', m => { m.validForMs = 0.5; }],
  ['wrong inode type', m => { m.socket.ino = 7; }], ['negative inode', m => { m.socket.ino = '-1'; }],
  ['missing inode', m => { delete m.socket.ino; }], ['extra socket data', m => { m.socket.fd = 3; }],
]) {
  const value = structuredClone(base); change(value);
  assert.throws(() => validateOwnerResponse(encode(value), options), name); count++;
}
for (const overrides of [
  { pending: null }, { now: 350 }, { now: 351 }, { now: 99 },
  { fingerprint: accepted.fingerprint, previousDeadline: 124 },
  { fingerprint: accepted.fingerprint, previousDeadline: 125 },
  { fingerprint: 'changed-owner', previousDeadline: 999 },
]) { assert.throws(() => validateOwnerResponse(encode(base), { ...options, ...overrides })); count++; }
for (const invalid of [Buffer.alloc(8193), Buffer.from('{bad'), Buffer.from([0xff]), encode(null), encode([])]) {
  assert.throws(() => validateOwnerResponse(invalid, options)); count++;
}
const renewed = validateOwnerResponse(encode({ ...base, challenge: 2 }), { ...options, pending: { sequence: 2, started: 150 }, now: 160, fingerprint: accepted.fingerprint, previousDeadline: 350 });
assert.equal(renewed.deadline, 400); count++;
assert.throws(() => validateOwnerResponse(encode({ ...base, identity: { invented: 'changed' } }), { ...options, fingerprint: accepted.fingerprint, previousDeadline: 350 })); count++;
console.log(`passed ${count} pure owner-control cases (not connected-peer evidence)`);
