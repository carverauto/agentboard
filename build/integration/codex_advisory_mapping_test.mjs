// Pure invented contract + durable journal fixture; no socket or credentials.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const library = path.resolve(process.argv[2]);
const { createWakeAdvisory, extractWakeCallback, parseWakeAdvisoryFrame,
  canonicalNotice, ADVISORY_TITLE, NOTICE_SUFFIX } = await import(pathToFileURL(path.join(library, 'advisory-mapping.mjs')));
const { createCodexAdvisoryTransport, createCodexQueueTransport } = await import(pathToFileURL(path.join(library, 'transport.mjs')));
const { createJournal } = await import(pathToFileURL(path.join(library, 'journal.mjs')));
const clone = v => JSON.parse(JSON.stringify(v));
const origin = 'https://agentboard.example.com';
const recipient = { threadId: '11111111-1111-4111-8111-111111111111', identityKind: 'durable-conversation-v1', enrollmentRevision: 1791774000123456, bindingEpoch: 3, persistent: true, topLevel: true };
const endpoint = { serverId: 'invented', endpointId: 'invented', generation: 'process:' + 'a'.repeat(64), profile: 'codex-durable-advisory-v1', nativeVersion: '0.162.0', protocolSource: 'rust-v0.162.0', schemaSha256: 'b'.repeat(64), experimentalApi: true, queueApi: true };
const manifest = { manifest_version: 1, worker_id: 'codex-worker', host_id: 'fixture-host', enrollment_revision: recipient.enrollmentRevision, binding_epoch: 3, session_id: 'legacy-binding-handle', pane_id: 'server-binding-handle', initialize_approved: true, endpoint, recipient };
const callback = { attempt_id: '22222222-2222-4222-8222-222222222222', intent_id: '33333333-3333-4333-8333-333333333333', reason_hash: 'c'.repeat(64), payload_hash: 'd'.repeat(64), recipient: { agent_id: manifest.worker_id, host_id: manifest.host_id, repo: 'fixture/exact-source', enrollment_revision: recipient.enrollmentRevision, binding_epoch: 3, session_id: manifest.session_id, adapter_generation: manifest.pane_id } };
const reservation = { ...callback, protocol_revision: 1, effect: 'wake.nudge', intent_revision: 9, source: { kind: 'board_message', id: '123', version: 'version-is-not-a-digest' } };
const batch = { attempt_id: callback.attempt_id, worker_id: manifest.worker_id, binding_epoch: 3, dispatch_generation: 11 };
const input = () => clone({ reservation, batch, manifest, serverOrigin: origin });
const options = () => clone({ manifest, serverOrigin: origin });
const notice = createWakeAdvisory(input());
assert.deepEqual(notice.wakeCallback, callback);
assert.equal(notice.source.version, callback.payload_hash);
assert.equal(notice.dispatchGeneration, batch.dispatch_generation);
assert.equal(notice.source.uri, origin + '/api/v1/hosts/fixture-host/wake-intents/codex-worker/resolve');
assert.equal(Object.hasOwn(notice.recipient, 'incarnation'), false);
assert.ok(Object.isFrozen(notice.wakeCallback.recipient));
assert.deepEqual(extractWakeCallback(notice, options()), callback);
const frame = ADVISORY_TITLE + canonicalNotice(notice) + NOTICE_SUFFIX;
assert.deepEqual(parseWakeAdvisoryFrame(frame, options()), callback);
// No caller mutation can change the retained exact callback.
const mutable = input();
const preserved = createWakeAdvisory(mutable);
mutable.reservation.recipient.session_id = 'current-binding-is-not-the-reservation';
mutable.manifest.recipient.threadId = '44444444-4444-4444-8444-444444444444';
assert.deepEqual(preserved.wakeCallback, callback);
assert.deepEqual(preserved.recipient, recipient);

for (const mutate of [
  x => { x.reservation.attempt_id = 'not-a-uuid'; },
  x => { x.reservation.recipient.host_id = 'foreign'; },
  x => { x.reservation.recipient.session_id = 'new-session'; },
  x => { x.reservation.recipient.adapter_generation = 'new-pane'; },
  x => { x.reservation.recipient.binding_epoch++; },
  x => { x.reservation.recipient.enrollment_revision++; },
  x => { x.reservation.recipient.extra = 'cannot-ignore'; },
  x => { x.reservation.recipient.session_id = '\ud800'; },
  x => { delete x.reservation.reason_hash; },
  x => { x.reservation.payload_hash = 'not-a-digest'; },
  x => { x.reservation.recipient.enrollment_revision = Number.MAX_SAFE_INTEGER + 1; },
  x => { x.batch.attempt_id = '44444444-4444-4444-8444-444444444444'; },
  x => { x.batch.worker_id = 'foreign'; },
  x => { x.batch.binding_epoch++; },
  x => { x.batch.dispatch_generation = 0; },
  x => { x.manifest.recipient.identityKind = 'native-incarnation'; },
  x => { x.manifest.recipient.incarnation = 'fiction'; },
  x => { x.manifest.initialize_approved = false; },
  x => { x.manifest.recipient.enrollmentRevision++; },
  x => { x.manifest.endpoint.profile = 'codex-native-queue-v1'; },
  x => { x.serverOrigin = 'http://agentboard.example.com'; },
  x => { x.serverOrigin = origin + '/'; },
  x => { x.serverOrigin = 'https://secret@agentboard.example.com'; },
  x => { x.serverOrigin = origin + '?credential=do-not-include'; },
]) { const value = input(); mutate(value); assert.throws(() => createWakeAdvisory(value)); }
for (const mutate of [
  x => { x.attemptId = '44444444-4444-4444-8444-444444444444'; },
  x => { x.wakeCallback.intent_id = 'not-a-uuid'; },
  x => { x.wakeCallback.payload_hash = 'e'.repeat(64); },
  x => { x.wakeCallback.recipient.binding_epoch++; },
  x => { x.wakeCallback.extra = true; },
  x => { delete x.wakeCallback.reason_hash; },
  x => { x.source.uri = 'https://foreign.example.com/source'; },
  x => { x.source.uri += '?token=do-not-include'; },
  x => { x.source.kind = 'arbitrary_source'; },
  x => { x.recipient.threadId = '44444444-4444-4444-8444-444444444444'; },
]) { const value = clone(notice); mutate(value); assert.throws(() => extractWakeCallback(value, options())); }
for (const badFrame of [
  frame + 'suffix', 'prefix' + frame, frame.replace('notice v1', 'notice v2'),
  ADVISORY_TITLE + JSON.stringify(notice, null, 2) + NOTICE_SUFFIX,
  frame.replace('"attemptId":', '"attemptId":"ignored-duplicate","attemptId":'),
  ADVISORY_TITLE + '[]' + NOTICE_SUFFIX, 'x'.repeat(4097),
]) assert.throws(() => parseWakeAdvisoryFrame(badFrame, options()));
assert.throws(() => parseWakeAdvisoryFrame(frame, { manifest, serverOrigin: 'https://foreign.example.com' }));
const changedManifest = clone(manifest); changedManifest.session_id = 'latest-binding';
assert.throws(() => parseWakeAdvisoryFrame(frame, { manifest: changedManifest, serverOrigin: origin }));
// URI components are explicit percent-encoded identities, not path fragments.
const punctuation = input();
punctuation.manifest.host_id = "host :/@+$&=!~*'()";
punctuation.reservation.recipient.host_id = punctuation.manifest.host_id;
const punctuationNotice = createWakeAdvisory(punctuation);
assert.ok(punctuationNotice.source.uri.includes("host%20%3A%2F%40%2B%24%26%3D!~*'()"));
assert.deepEqual(extractWakeCallback(punctuationNotice, { manifest: punctuation.manifest, serverOrigin: origin }), punctuationNotice.wakeCallback);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'advisory-mapping-'));
fs.chmodSync(root, 0o700);
let requests = 0;
let current = { endpoint, recipient };
let submittedFrame;
const client = {
  identity: () => current,
  request: async request => {
    requests++;
    assert.equal(request.method, 'thread/queue/add');
    submittedFrame = request.params.input[0].text;
    assert.deepEqual(parseWakeAdvisoryFrame(submittedFrame, options()), callback);
    return { id: request.id, result: { queuedSubmission: { id: '55555555-5555-4555-8555-555555555555', input: request.params.input, clientUserMessageId: request.params.clientUserMessageId } } };
  },
};
try {
  assert.throws(() => createCodexQueueTransport({ client, endpoint, recipient, journalDir: root }));
  const transport = createCodexAdvisoryTransport({ client, endpoint, recipient, journalDir: root });
  assert.equal((await transport.submit(notice)).outcome, 'accepted');
  assert.equal(requests, 1);
  const journal = createJournal(root);
  const record = journal.load(callback.attempt_id);
  assert.deepEqual(record.attempt.wakeCallback, callback);
  assert.equal(record.frame, submittedFrame);
  current = null;
  assert.equal((await transport.submit(notice)).historical, true);
  assert.equal(requests, 1);
  const different = clone(notice); different.wakeCallback.reason_hash = 'f'.repeat(64);
  await assert.rejects(transport.submit(different));
  assert.equal(requests, 1);
  // Retained source callback is still only an exact source-resolution input.
  // Its successful parse does not consume a receipt or grant any work action.
  assert.deepEqual(parseWakeAdvisoryFrame(record.frame, options()), callback);
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log('Durable advisory exact-callback mapping, framing and journal fixtures passed');
