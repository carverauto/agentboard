import assert from 'node:assert/strict';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { createJournal } from './codex/journal.mjs';
import { setTimeout as sleep } from 'node:timers/promises';
import { connectInheritedCodexAdvisory } from './codex/inherited-client.mjs';
import { createCodexQueueTransport, createCodexAdvisoryTransport } from './codex/transport.mjs';
import { requireEvidence } from './codex/rpc-wire.mjs';
import { createWakeAdvisory, parseWakeAdvisoryFrame } from './codex/advisory-mapping.mjs';
const fsync = fs.fsyncSync;
let fsyncCount = 0, fsyncTotalMs = 0, fsyncMaxMs = 0;
fs.fsyncSync = function (...args) { const start = performance.now(); try { return fsync.apply(this, args); } finally { const elapsed = performance.now() - start; fsyncCount++; fsyncTotalMs += elapsed; fsyncMaxMs = Math.max(fsyncMaxMs, elapsed); } };
const [mode, journalDir] = process.argv.slice(2);
if (mode === 'wrong-fd') { fs.closeSync(3); }
let client;
try {
  client = await connectInheritedCodexAdvisory({ approvalId: mode === 'wrong-approval' ? 'foreign' : 'invented-fixture', authorityRevision: 1 });
} catch {
  if (['wrong-approval', 'wrong-fd', 'fd-substitution', 'expired'].includes(mode)) { console.log('refused'); process.exit(0); }
  throw new Error('unexpected initial refusal');
}
const identity = client.identity();
assert.equal(identity.recipient.identityKind, 'durable-conversation-v1');
assert.equal(Object.hasOwn(identity.recipient, 'incarnation'), false);
assert.match(identity.endpoint.generation, /^process:[a-f0-9]{64}$/);
const evidence = { current: () => identity, bindConnection: () => true, verifyConnection: () => true, subscribeRetirement: () => () => {} };
assert.throws(() => requireEvidence(evidence));
assert.throws(() => createCodexQueueTransport({ client, ...identity, journalDir }));
const transport = createCodexAdvisoryTransport({ client, ...identity, journalDir, timeoutMs: 1500 });
assert.equal((await transport.inspect()).compatible, true);
const callback = { attempt_id: '22222222-2222-4222-8222-222222222222', intent_id: '33333333-3333-4333-8333-333333333333', reason_hash: 'b'.repeat(64), payload_hash: 'c'.repeat(64), recipient: { agent_id: 'invented-worker', host_id: 'invented-host', repo: 'fixture/owner', enrollment_revision: identity.recipient.enrollmentRevision, binding_epoch: identity.recipient.bindingEpoch, session_id: 'invented-binding', adapter_generation: 'invented-generation' } };
const manifest = { manifest_version: 1, worker_id: callback.recipient.agent_id, host_id: callback.recipient.host_id, enrollment_revision: callback.recipient.enrollment_revision, binding_epoch: callback.recipient.binding_epoch, session_id: callback.recipient.session_id, pane_id: callback.recipient.adapter_generation, initialize_approved: true, ...identity };
const serverOrigin = 'https://agentboard.example.com';
const attempt = createWakeAdvisory({ reservation: { ...callback, protocol_revision: 1, effect: 'wake.nudge' }, batch: { attempt_id: callback.attempt_id, worker_id: manifest.worker_id, binding_epoch: manifest.binding_epoch, dispatch_generation: 7 }, manifest, serverOrigin });
if (mode === 'lose-add') {
  console.log('submitting');
  const result = await transport.submit(attempt);
  assert.equal(result.outcome, 'uncertain');
  const again = await transport.submit(attempt);
  assert.equal(again.outcome, 'uncertain');
  assert.equal(again.reason, 'retained_submitting_evidence');
  client.close(); console.log('uncertain-no-replay');
} else {
  const started = performance.now();
  const result = await transport.submit(attempt);
  console.error(JSON.stringify({ fixture: mode, outcome: result.outcome, reason: result.reason ?? null,
    journalPhase: createJournal(journalDir).load(attempt.attemptId)?.phase ?? null,
    submitMs: performance.now() - started, fsyncCount, fsyncTotalMs, fsyncMaxMs, owner: client.diagnostics() }));
  assert.equal(result.outcome, 'accepted');
  const retained = createJournal(journalDir).load(callback.attempt_id);
  assert.deepEqual(retained.attempt.wakeCallback, callback);
  assert.deepEqual(parseWakeAdvisoryFrame(retained.frame, { manifest, serverOrigin }), callback);
  assert.equal((await transport.submit(attempt)).historical, true);
  // Explicit barrier: acceptance and durable historical evidence must both pass
  // before the Go parent may close the owner pipe or retire the owner.
  console.log('accepted');
  if (mode === 'retire' || mode === 'lease' || mode === 'pipe-eof') {
    // Observation budget only; the immutable owner deadline is never extended.
    for (let i = 0; i < 325 && client.identity(); i++) await sleep(20);
    assert.equal(client.identity(), null);
    await assert.rejects(client.request({ id: 'after-retire', method: 'thread/read', params: { threadId: identity.recipient.threadId, includeTurns: false } }));
    assert.equal((await transport.submit(attempt)).historical, true);
    console.log('retired-history-retained');
  }
  client.close();
}
