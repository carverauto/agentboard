import assert from 'node:assert/strict';
import fs from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { connectInheritedCodexAdvisory } from './codex/inherited-client.mjs';
import { createCodexQueueTransport, createCodexAdvisoryTransport } from './codex/transport.mjs';
import { requireEvidence } from './codex/rpc-wire.mjs';
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
const attempt = { attemptId: 'invented-attempt', recipient: identity.recipient, source: { kind: 'wake', id: 'invented-source', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source' }, bindingEpoch: 3, dispatchGeneration: 7 };
if (mode === 'lose-add') {
  console.log('submitting');
  const result = await transport.submit(attempt);
  assert.equal(result.outcome, 'uncertain');
  const again = await transport.submit(attempt);
  assert.equal(again.outcome, 'uncertain');
  assert.equal(again.reason, 'retained_submitting_evidence');
  client.close(); console.log('uncertain-no-replay');
} else {
  const result = await transport.submit(attempt); assert.equal(result.outcome, 'accepted');
  assert.equal((await transport.submit(attempt)).historical, true);
  console.log('accepted');
  if (mode === 'retire' || mode === 'lease' || mode === 'pipe-eof') {
    for (let i = 0; i < 100 && client.identity(); i++) await sleep(20);
    assert.equal(client.identity(), null);
    await assert.rejects(client.request({ id: 'after-retire', method: 'thread/read', params: { threadId: identity.recipient.threadId, includeTurns: false } }));
    assert.equal((await transport.submit(attempt)).historical, true);
    console.log('retired-history-retained');
  }
  client.close();
}
