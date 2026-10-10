// Synthetic acceptance tests for the isolated library. No native Codex, socket,
// board, runtime enrollment, or installed-version conformance is exercised.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = path.resolve(process.argv[2]);
const { createCodexQueueTransport } = await import(pathToFileURL(modulePath));
const { createJournal } = await import(pathToFileURL(path.join(path.dirname(modulePath), 'journal.mjs')));
const clone = value => JSON.parse(JSON.stringify(value));
const sha256 = value => createHash('sha256').update(value).digest('hex');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const endpoint = {
  serverId: 'server-a', endpointId: 'endpoint-a', generation: 'server-gen',
  profile: 'codex-native-queue-v1', nativeVersion: '0.162.0',
  protocolSource: 'rust-v0.162.0', schemaSha256: 'a'.repeat(64),
  experimentalApi: true, queueApi: true,
};
const recipient = {
  threadId: 'f445b660-5eac-4ea6-81b6-7cfd05961476',
  incarnation: 'recipient-gen', persistent: true, topLevel: true,
};
function attempt(name = 'one') {
  return {
    attemptId: 'attempt-' + name,
    source: { kind: 'wake', id: 'source-1', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source/1' },
    recipient: clone(recipient), bindingEpoch: 1, dispatchGeneration: 1,
  };
}
function frozen(value) {
  if (value && typeof value === 'object') {
    assert.ok(Object.isFrozen(value), 'RPC inputs are recursively frozen');
    for (const child of Object.values(value)) frozen(child);
  }
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await delay(10);
  }
  throw new Error('Required synthetic process condition did not arrive');
}
async function refused(operation) {
  let result;
  try { result = await operation(); } catch (error) {
    assert.ok(error instanceof Error);
    return;
  }
  assert.equal(result.outcome, 'uncertain', 'refusal cannot become positive acceptance');
}
function synthetic({ onAdd, onList, onRead, identity: suppliedIdentity } = {}) {
  const identity = suppliedIdentity || { endpoint: clone(endpoint), recipient: clone(recipient) };
  const calls = [], queue = [];
  const client = {
    identity: () => clone(identity),
    async request(request) {
      frozen(request);
      assert.match(request.id, UUID);
      assert.deepEqual(Object.keys(request).sort(), ['id', 'method', 'params']);
      calls.push(clone(request));
      let result;
      if (request.method === 'thread/read') {
        assert.deepEqual(request.params, { threadId: recipient.threadId, includeTurns: false });
        result = onRead ? await onRead(request) : { thread: { id: recipient.threadId, ephemeral: false, source: 'cli', status: { type: 'active', activeFlags: [] } } };
      } else if (request.method === 'thread/queue/add') {
        assert.deepEqual(Object.keys(request.params).sort(), ['clientUserMessageId', 'input', 'threadId']);
        assert.equal(request.params.threadId, recipient.threadId);
        assert.match(request.params.clientUserMessageId, UUID);
        assert.equal(request.params.input.length, 1);
        assert.deepEqual(Object.keys(request.params.input[0]).sort(), ['text', 'text_elements', 'type']);
        assert.equal(request.params.input[0].type, 'text');
        assert.deepEqual(request.params.input[0].text_elements, []);
        assert.ok(Buffer.byteLength(request.params.input[0].text) <= 4096, 'attribution frame is bounded');
        const item = { id: randomUUID(), clientUserMessageId: request.params.clientUserMessageId, input: clone(request.params.input) };
        queue.push(item);
        if (onAdd) return await onAdd(request, item);
        result = { queuedSubmission: item };
      } else if (request.method === 'thread/queue/list') {
        assert.deepEqual(Object.keys(request.params).sort(), ['cursor', 'limit', 'threadId']);
        assert.equal(request.params.threadId, recipient.threadId);
        assert.ok(request.params.cursor === null || typeof request.params.cursor === 'string');
        result = onList ? await onList(request, queue) : { data: clone(queue), nextCursor: null };
      } else {
        assert.fail('Forbidden native method: ' + request.method);
      }
      return { id: request.id, result };
    },
  };
  return { client, identity, calls, queue, adds: () => calls.filter(call => call.method === 'thread/queue/add') };
}

// Separate processes deliberately share only private files. Stdio pipes are
// sufficient to observe their exit; no IPC or AF_UNIX socket is required.
if (process.argv[3] === '--child') {
  const [mode, journalDir, marker] = process.argv.slice(4);
  const f = synthetic({ onAdd: async (request, item) => {
    fs.appendFileSync(marker, JSON.stringify({ pid: process.pid, request, item }) + '\n', { mode: 0o600 });
    if (mode === 'hold') await new Promise(resolve => {
      const timer = setInterval(() => {
        if (fs.existsSync(marker + '.release')) { clearInterval(timer); resolve(); }
      }, 10);
    });
    return { id: request.id, result: { queuedSubmission: item } };
  } });
  try {
    const t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir, timeoutMs: 30000 });
    const result = await t.submit(attempt('process'));
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (error) {
    process.stdout.write(JSON.stringify({ error: error.message }) + '\n');
  }
} else {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-codex-queue-'));
  fs.chmodSync(root, 0o700);
  const children = [];
  let caseNumber = 0;
  const cases = [];
  function directory(label) {
    const dir = path.join(root, String(++caseNumber) + '-' + label);
    fs.mkdirSync(dir, { mode: 0o700 });
    return dir;
  }
  function fixture(label, options = {}, config = {}) {
    const dir = directory(label);
    const f = synthetic(options);
    const transport = createCodexQueueTransport({ client: f.client, endpoint: clone(endpoint), recipient: clone(recipient), journalDir: dir, timeoutMs: 100, ...config });
    return { ...f, dir, transport, journal: createJournal(dir) };
  }
  async function check(name, fn) {
    await fn();
    cases.push(name);
    console.log('ok - ' + name);
  }
  function startChild(mode, dir, marker) {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), modulePath, '--child', mode, dir, marker], { stdio: ['ignore', 'pipe', 'pipe'] });
    children.push(child);
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => stdout += chunk);
    child.stderr.on('data', chunk => stderr += chunk);
    const ended = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({ code, signal, stdout, stderr }));
    });
    return { child, ended };
  }
  const markers = file => fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
  try {
    await check('durable frozen submitting evidence precedes the sole add', async () => {
      const a = attempt();
      const dir = directory('durable');
      const journal = createJournal(dir);
      const f = synthetic({ onAdd: async (request, item) => {
        const record = journal.load(a.attemptId);
        assert.equal(record.phase, 'submitting');
        assert.equal(record.version, 1);
        assert.deepEqual(record.attempt, a);
        assert.deepEqual(record.endpoint, endpoint);
        assert.equal(record.clientUserMessageId, request.params.clientUserMessageId);
        assert.equal(record.frame, request.params.input[0].text);
        assert.equal(record.frameSha256, sha256(record.frame));
        assert.ok(record.frame.includes(a.source.uri));
        for (const file of Object.values(journal.paths(a.attemptId))) assert.equal(fs.statSync(file).mode & 0o777, 0o600);
        return { id: request.id, result: { queuedSubmission: item } };
      } });
      const transport = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: dir });
      assert.deepEqual(Object.keys(transport).sort(), ['inspect', 'reconcile', 'submit']);
      assert.ok(Object.isFrozen(transport));
      const result = await transport.submit(a);
      assert.equal(result.outcome, 'accepted');
      assert.equal(result.historical, false);
      assert.deepEqual(result.receipt, {
        queuedSubmissionId: f.queue[0].id, clientUserMessageId: f.queue[0].clientUserMessageId,
        threadId: recipient.threadId, attemptId: a.attemptId, bindingEpoch: 1, dispatchGeneration: 1,
        frameSha256: sha256(f.queue[0].input[0].text), endpoint, recipient,
      });
      assert.equal(journal.load(a.attemptId).phase, 'accepted');
      assert.equal(path.basename(journal.paths(a.attemptId).record), sha256(a.attemptId) + '.json');
      assert.equal(path.basename(journal.paths(a.attemptId).lock), sha256(a.attemptId) + '.lock');
      assert.equal(fs.existsSync(journal.paths(a.attemptId).lock), false);
      assert.equal((await transport.submit(clone(a))).historical, true);
      assert.equal(f.adds().length, 1);
      assert.equal(f.calls.length, 1, 'submit does not turn an idle/status check into an atomic fence');
    });

    await check('accepted evidence remains historical after consumption, deletion, and abandoned lock', async () => {
      const f = fixture('historical'), a = attempt();
      const original = await f.transport.submit(a);
      f.queue.length = 0;
      const calls = f.calls.length;
      const retained = await f.transport.reconcile(a);
      assert.equal(retained.outcome, 'accepted');
      assert.equal(retained.historical, true);
      assert.deepEqual(retained.receipt, original.receipt);
      fs.writeFileSync(f.journal.paths(a.attemptId).lock, JSON.stringify({ pid: 2147483647 }), { mode: 0o600 });
      assert.equal((await f.transport.submit(a)).outcome, 'accepted');
      assert.equal((await f.transport.reconcile(a)).historical, true);
      assert.equal(f.calls.length, calls, 'retained positive evidence needs no mutable queue lookup');
      assert.ok(fs.existsSync(f.journal.paths(a.attemptId).lock), 'historical read never clears another custodian lock');
      const text = JSON.stringify(retained);
      for (const forbidden of ['handled', 'completed', 'received']) assert.ok(!text.includes('"' + forbidden + '"'));
    });

    await check('changed attempt fences reject replay before any native request', async () => {
      const f = fixture('fences'), a = attempt();
      await f.transport.submit(a);
      for (const change of [
        value => value.source.id = 'changed-source',
        value => value.source.kind = 'message',
        value => value.source.version = 'c'.repeat(64),
        value => value.source.uri = 'https://agentboard.example.com/source/changed',
        value => value.recipient.incarnation = 'changed-incarnation',
        value => value.recipient.threadId = randomUUID(),
        value => value.bindingEpoch++, value => value.dispatchGeneration++,
      ]) {
        const changed = clone(a); change(changed);
        await assert.rejects(async () => f.transport.submit(changed));
        await assert.rejects(async () => f.transport.reconcile(changed));
      }
      assert.equal(f.calls.length, 1);
    });

    await check('caller mutation cannot rewrite the frozen in-flight attempt or wire input', async () => {
      let release, entered;
      const started = new Promise(resolve => entered = resolve);
      const held = new Promise(resolve => release = resolve);
      const f = fixture('mutable', { onAdd: async (request, item) => {
        entered(); await held;
        return { id: request.id, result: { queuedSubmission: item } };
      } });
      const a = attempt(), original = clone(a);
      const submitted = f.transport.submit(a);
      await started;
      a.source.uri = 'https://agentboard.example.com/changed';
      a.recipient.incarnation = 'mutated'; a.bindingEpoch = 99;
      release();
      assert.equal((await submitted).outcome, 'accepted');
      assert.deepEqual(f.journal.load(original.attemptId).attempt, original);
      assert.equal((await f.transport.submit(original)).outcome, 'accepted');
      await assert.rejects(async () => f.transport.submit(a));
      assert.equal(f.adds().length, 1);
    });

    await check('constructor snapshots and canonical retries ignore caller object order', async () => {
      const f = synthetic(), declaredEndpoint = clone(endpoint), declaredRecipient = clone(recipient);
      const t = createCodexQueueTransport({ client: f.client, endpoint: declaredEndpoint, recipient: declaredRecipient, journalDir: directory('constructor-snapshot') });
      declaredEndpoint.generation = 'changed'; declaredRecipient.incarnation = 'changed';
      const a = attempt();
      const first = await t.submit(a);
      assert.equal(first.outcome, 'accepted');
      const reordered = Object.fromEntries(Object.entries(a).reverse());
      reordered.source = Object.fromEntries(Object.entries(a.source).reverse());
      reordered.recipient = Object.fromEntries(Object.entries(a.recipient).reverse());
      assert.deepEqual((await t.submit(reordered)).receipt, first.receipt);
      assert.equal(f.adds().length, 1);
      f.identity.endpoint.generation = 'disconnected-old-generation';
      const retained = await t.reconcile(a);
      assert.equal(retained.outcome, 'accepted');
      assert.equal(retained.historical, true, 'old acceptance is historical even after native identity changes');
      assert.equal(f.calls.length, 1);
    });

    await check('mutable client responses are snapshotted before identity checks and retention', async () => {
      let response;
      const f = fixture('response-snapshot', { onAdd: async (request, item) => {
        response = { id: request.id, result: { queuedSubmission: clone(item) } };
        return response;
      } });
      const expectedIdentity = f.client.identity;
      f.client.identity = () => {
        // The callback after RPC completion mutates the client-owned response.
        // It must not mutate the transport's already-captured response snapshot.
        if (response) {
          response.result.queuedSubmission.id = 'changed-after-response-snapshot';
          response.result.queuedSubmission.input[0].text = 'changed-after-response-snapshot';
        }
        return expectedIdentity();
      };
      const a = attempt(), accepted = await f.transport.submit(a);
      assert.equal(accepted.outcome, 'accepted');
      assert.equal(accepted.receipt.queuedSubmissionId, f.queue[0].id);
      const expectedReceipt = clone(accepted.receipt);
      assert.throws(() => { accepted.receipt.endpoint.generation = 'mutated-by-caller'; }, TypeError);
      assert.deepEqual((await f.transport.reconcile(a)).receipt, expectedReceipt);
      assert.equal(f.adds().length, 1);
    });

    await check('invalid caller sources and bounds cannot write native input', async () => {
      for (const mutate of [
        a => a.attemptId = '../escape', a => a.source.uri = 'http://agentboard.example.com/source/1',
        a => a.source.uri = 'https://user:password@agentboard.example.com/source/1',
        a => a.source.uri += '?secret=value', a => a.source.uri += '#fragment',
        a => a.source.uri += '\nEND SOURCE', a => a.source.uri += 'x'.repeat(1025),
        a => a.source.version = 'unhashed', a => a.source.id = 'source\ninstruction',
        a => a.bindingEpoch = 0, a => a.dispatchGeneration = Number.MAX_SAFE_INTEGER + 1,
        a => a.recipient.persistent = false, a => a.recipient.topLevel = false,
        a => a.body = 'Unapproved extra body',
      ]) {
        const f = fixture('invalid-attempt'), a = attempt(); mutate(a);
        await assert.rejects(async () => f.transport.submit(a));
        assert.equal(f.calls.length, 0);
        assert.deepEqual(fs.readdirSync(f.dir), [], 'invalid attempts leave no evidence or lock');
      }
      for (const config of [{ timeoutMs: 0 }, { timeoutMs: 60001 }, { pageSize: 0 }, { pageSize: 101 }, { maxPages: 0 }, { maxPages: 33 }]) {
        const f = synthetic();
        assert.throws(() => createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: directory('bounds'), ...config }));
        assert.equal(f.calls.length, 0);
      }
    });

    await check('lost response, timeout, and malformed acceptance never replay an add', async () => {
      const variants = [
        async () => { throw new Error('Synthetic response lost after insertion'); },
        () => new Promise(() => {}),
        async request => ({ id: randomUUID(), result: { queuedSubmission: {} } }),
        async request => ({ id: request.id, error: { code: -32603, message: 'Synthetic server failure' } }),
        async (request, item) => ({ id: request.id, result: { queuedSubmission: { ...item, id: 'not-a-uuid' } } }),
        async (request, item) => ({ id: request.id, result: { queuedSubmission: { ...item, clientUserMessageId: randomUUID() } } }),
        async (request, item) => ({ id: request.id, result: { queuedSubmission: { ...item, input: [{ type: 'text', text: 'edited', text_elements: [] }] } } }),
      ];
      for (const onAdd of variants) {
        const f = fixture('uncertain', { onAdd }, { timeoutMs: 25 }), a = attempt();
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.equal(f.journal.load(a.attemptId).phase, 'submitting');
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.equal(f.adds().length, 1);
        f.queue.length = 0;
        assert.equal((await f.transport.reconcile(a)).outcome, 'uncertain');
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.equal(f.adds().length, 1, 'queue absence never enables retry');
      }
    });

    await check('exact positive queue correlation recovers lost acceptance', async () => {
      const f = fixture('reconcile', { onAdd: async () => { throw new Error('Lost response'); } }), a = attempt();
      assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
      const recovered = await f.transport.reconcile(a);
      assert.equal(recovered.outcome, 'accepted');
      assert.equal(recovered.receipt.queuedSubmissionId, f.queue[0].id);
      assert.equal(f.journal.load(a.attemptId).phase, 'accepted');
      f.queue.length = 0;
      assert.equal((await f.transport.reconcile(a)).historical, true);
      assert.equal(f.adds().length, 1);
    });

    await check('late native callback cannot turn a timeout into acceptance or authorize replay', async () => {
      let release;
      const f = fixture('late-callback', { onAdd: (request, item) => new Promise(resolve => {
        release = () => resolve({ id: request.id, result: { queuedSubmission: item } });
      }) }, { timeoutMs: 15 });
      const a = attempt();
      assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
      release(); await delay(20);
      assert.equal(f.journal.load(a.attemptId).phase, 'submitting');
      assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
      assert.equal(f.adds().length, 1);
    });

    await check('edited, deleted, duplicate, and foreign queue entries cannot prove acceptance', async () => {
      const variants = [
        queue => queue.length = 0,
        queue => queue[0].input[0].text += ' edited',
        queue => queue.push({ ...clone(queue[0]), id: randomUUID() }),
        queue => queue.push(clone(queue[0])),
        queue => queue[0].clientUserMessageId = randomUUID(),
        queue => queue[0].id = 'short-id',
      ];
      for (const mutate of variants) {
        const f = fixture('non-proof', { onAdd: async () => { throw new Error('Lost response'); } }), a = attempt();
        await f.transport.submit(a);
        mutate(f.queue);
        assert.equal((await f.transport.reconcile(a)).outcome, 'uncertain');
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.equal(f.adds().length, 1);
      }
    });

    await check('a matching item cannot hide malformed unrelated queue input', async () => {
      for (const input of [
        [], [{}], [{ type: 'unknownFutureInput', value: 'unverified' }],
        [{ type: 'text' }], [{ type: 'text', text: 7, text_elements: [] }],
        [{ type: 'text', text: 'unrelated', text_elements: 'wrong' }],
        [{ type: 'text', text: 'unrelated', text_elements: [{}] }],
        [{ type: 'text', text: 'unrelated', text_elements: [{ byteRange: { start: -1, end: 3 }, placeholder: null }] }],
        [{ type: 'text', text: 'unrelated', text_elements: [{ byteRange: { start: 0, end: 1.5 }, placeholder: null }] }],
        [{ type: 'text', text: 'unrelated', text_elements: [{ byteRange: { start: 0, end: 3 }, placeholder: 7 }] }],
        [{ type: 'image' }], [{ type: 'image', url: 'https://example.invalid/image.png', detail: 'unsupported' }],
        [{ type: 'localImage' }], [{ type: 'audio' }], [{ type: 'localAudio' }],
        [{ type: 'skill' }], [{ type: 'mention' }],
      ]) {
        const f = fixture('malformed-unrelated-input', { onAdd: async () => { throw new Error('Lost response'); } }), a = attempt();
        await f.transport.submit(a);
        f.queue.push({ id: randomUUID(), clientUserMessageId: randomUUID(), input });
        assert.equal((await f.transport.reconcile(a)).outcome, 'uncertain', 'the whole observed queue page must meet the pinned input contract');
        assert.equal(f.journal.load(a.attemptId).phase, 'submitting');
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.equal(f.adds().length, 1);
      }
    });

    await check('valid unrelated inputs from every pinned union variant permit exact reconciliation', async () => {
      const variants = [
        { type: 'text', text: 'unrelated', text_elements: [] },
        { type: 'text', text: 'unrelated', text_elements: [{ byteRange: { start: 0, end: 9 }, placeholder: null }] },
        { type: 'text', text: 'unrelated', text_elements: [{ byteRange: { start: 0, end: 9 }, placeholder: 'unrelated' }] },
        { type: 'image', url: 'https://example.invalid/image.png' },
        { type: 'image', fileId: 'fixture-file-id', detail: null },
        { type: 'image', url: 'https://example.invalid/image.png', detail: 'auto' },
        { type: 'image', fileId: 'fixture-file-id', detail: 'low' },
        { type: 'localImage', path: '/tmp/invented-image.png', detail: 'high' },
        { type: 'localImage', path: '/tmp/invented-image.png', detail: 'original' },
        { type: 'audio', url: 'https://example.invalid/audio.wav' },
        { type: 'localAudio', path: '/tmp/invented-audio.wav' },
        { type: 'skill', name: 'fixture-skill', path: '/tmp/invented-skill/SKILL.md' },
        { type: 'mention', name: 'fixture-reference', path: '/tmp/invented-reference' },
      ];
      const f = fixture('valid-unrelated-inputs', { onAdd: async () => { throw new Error('Lost response'); } }), a = attempt();
      await f.transport.submit(a);
      for (const input of variants) f.queue.push({ id: randomUUID(), clientUserMessageId: randomUUID(), input: [input] });
      assert.equal((await f.transport.reconcile(a)).outcome, 'accepted');
      assert.equal(f.journal.load(a.attemptId).phase, 'accepted');
      assert.equal(f.adds().length, 1);
    });

    await check('bounded pagination requires exhaustion and rejects overlap or repeated cursors', async () => {
      const unrelated = () => ({ id: randomUUID(), clientUserMessageId: randomUUID(), input: [{ type: 'text', text: 'unrelated', text_elements: [] }] });
      for (const variant of ['complete', 'incomplete', 'overlap', 'cycle', 'later-error', 'offset-jump', 'short-page', 'null-page']) {
        let page = 0;
        const other = unrelated();
        const f = fixture('pages-' + variant, {
          onAdd: async () => { throw new Error('Lost response'); },
          onList: async (request, queue) => {
            assert.equal(request.params.limit, 2);
            page++;
            if (page === 1) { assert.equal(request.params.cursor, null); return { data: [clone(queue[0]), other], nextCursor: '2' }; }
            if (variant === 'later-error') throw new Error('Page lost');
            if (variant === 'overlap') return { data: [other], nextCursor: null };
            if (variant === 'cycle') return { data: [unrelated(), unrelated()], nextCursor: '2' };
            if (variant === 'offset-jump') return { data: [unrelated(), unrelated()], nextCursor: '6' };
            if (variant === 'short-page') return { data: [unrelated()], nextCursor: '4' };
            if (variant === 'null-page') return { data: null, nextCursor: null };
            if (variant === 'incomplete') return { data: [unrelated(), unrelated()], nextCursor: String(page * 2) };
            assert.equal(request.params.cursor, '2');
            return { data: [unrelated()], nextCursor: null };
          },
        }, { pageSize: 2, maxPages: 3 });
        const a = attempt(); await f.transport.submit(a);
        assert.equal((await f.transport.reconcile(a)).outcome, variant === 'complete' ? 'accepted' : 'uncertain');
        assert.ok(page <= 3);
        assert.equal(f.adds().length, 1);
      }
    });

    await check('status inspection preserves busy and unknown native states', async () => {
      for (const [nativeStatus, expectedStatus] of [
        [{ type: 'active', activeFlags: ['waitingOnApproval'] }, 'active'],
        [{ type: 'idle' }, 'idle'],
        [{ type: 'futureBusy', reason: 'new native status' }, 'unknown'],
        [{ type: 'idle', activeFlags: ['waitingOnApproval'] }, 'unknown'],
        [{ type: 'idle', unexpected: true }, 'unknown'],
        [{ type: 'active' }, 'unknown'],
        [{ type: 'active', activeFlags: 'waitingOnApproval' }, 'unknown'],
        [{ type: 'active', activeFlags: ['futureFlag'] }, 'unknown'],
        [{ type: 'active', activeFlags: ['waitingOnUserInput'], unexpected: true }, 'unknown'],
        [null, 'unknown'],
      ]) {
        const f = fixture('inspect', { onRead: async () => ({ thread: { id: recipient.threadId, ephemeral: false, source: 'cli', status: nativeStatus } }) });
        const result = await f.transport.inspect();
        assert.equal(result.compatible, true);
        assert.deepEqual(result.nativeStatus, nativeStatus);
        assert.equal(result.status, expectedStatus);
        assert.equal(f.adds().length, 0);
        assert.equal((await f.transport.submit(attempt())).outcome, 'accepted', 'busy is not a manufactured idle gate');
        assert.equal(f.adds().length, 1);
      }
    });

    await check('inspection refuses ephemeral, subagent, foreign-thread, and uncorrelated responses', async () => {
      for (const mutate of [thread => thread.id = randomUUID(), thread => thread.ephemeral = true, thread => thread.source = { subAgent: { parentThreadId: randomUUID() } }]) {
        const nativeStatus = { type: 'active', activeFlags: ['waitingOnUserInput'] };
        const thread = { id: recipient.threadId, ephemeral: false, source: 'cli', status: nativeStatus }; mutate(thread);
        const f = fixture('inspect-reject', { onRead: async () => ({ thread }) });
        const result = await f.transport.inspect();
        assert.equal(result.compatible, false);
        assert.equal(result.status, 'unknown');
        assert.deepEqual(result.nativeStatus, nativeStatus);
        assert.equal(f.adds().length, 0);
      }
      const f = synthetic();
      f.client.request = async () => ({ id: randomUUID(), result: { thread: { id: recipient.threadId, ephemeral: false, source: 'cli', status: { type: 'idle' } } } });
      const t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: directory('inspect-rpc-id') });
      assert.equal((await t.inspect()).compatible, false);
    });

    await check('identity generation changes fence callbacks and new submissions', async () => {
      for (const mutate of [id => id.endpoint.generation = 'new-server', id => id.recipient.incarnation = 'new-recipient', id => id.endpoint.schemaSha256 = 'c'.repeat(64)]) {
        let f;
        f = fixture('identity-change', { onAdd: async (request, item) => {
          mutate(f.identity);
          return { id: request.id, result: { queuedSubmission: item } };
        } });
        assert.equal((await f.transport.submit(attempt())).outcome, 'uncertain');
        await refused(() => f.transport.submit(attempt('new')));
        await refused(() => f.transport.reconcile(attempt()));
        assert.equal(f.adds().length, 1);
      }
    });

    await check('wrong protocol, version, endpoint, and recipient attestation fail closed', async () => {
      for (const mutate of [
        id => id.endpoint.nativeVersion = '0.161.0', id => id.endpoint.protocolSource = 'rust-v0.161.0',
        id => id.endpoint.profile = 'unknown-profile', id => id.endpoint.queueApi = false,
        id => id.endpoint.experimentalApi = false, id => id.endpoint.schemaSha256 = 'wrong',
        id => id.endpoint.endpointId = 'foreign-endpoint', id => id.recipient.threadId = 'short',
        id => id.recipient.persistent = false, id => id.recipient.topLevel = false,
      ]) {
        const identity = { endpoint: clone(endpoint), recipient: clone(recipient) }; mutate(identity);
        const f = synthetic({ identity });
        await refused(async () => {
          const t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: directory('mismatch') });
          return await t.submit(attempt());
        });
        assert.equal(f.calls.length, 0);
      }
    });

    await check('constructor rejects unsupported endpoint profiles before inspecting identity', async () => {
      for (const mutate of [
        value => value.nativeVersion = '0.161.0', value => value.protocolSource = 'rust-v0.161.0',
        value => value.profile = 'codex-app-server-v1', value => value.experimentalApi = false,
        value => value.queueApi = false, value => value.schemaSha256 = 'a'.repeat(63),
      ]) {
        const declared = clone(endpoint); mutate(declared);
        const f = synthetic({ identity: { endpoint: declared, recipient } });
        assert.throws(() => createCodexQueueTransport({ client: f.client, endpoint: declared, recipient, journalDir: directory('invalid-endpoint') }));
        assert.equal(f.calls.length, 0);
      }
    });

    await check('initial durable-save and fsync failures issue zero RPCs', async () => {
      for (const stage of ['write', 'rename', 'sync-1', 'sync-2', 'sync-3', 'sync-4']) {
        let syncs = 0, failed = false;
        const io = new Proxy(fs, { get(target, key) {
          const original = target[key];
          if (typeof original !== 'function') return original;
          return (...args) => {
            const fail = (stage === 'write' && key === 'writeFileSync' && String(args[1]).includes('"phase":"submitting"')) ||
              (stage === 'rename' && key === 'renameSync') ||
              (key === 'fsyncSync' && stage === 'sync-' + (++syncs));
            if (fail && !failed) { failed = true; throw new Error('Injected durable-save ' + stage + ' failure'); }
            return original.apply(target, args);
          };
        } });
        const f = synthetic(), dir = directory('storage-' + stage);
        await refused(async () => {
          const t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: dir, journalIO: io });
          return await t.submit(attempt());
        });
        assert.ok(failed, 'fixture reached intended durable boundary: ' + stage);
        assert.equal(f.calls.length, 0, 'no native request before full durable boundary');
      }
    });

    await check('failed acceptance persistence remains uncertain and cannot resend', async () => {
      let failed = false;
      const io = new Proxy(fs, { get(target, key) {
        if (key !== 'writeFileSync') return target[key];
        return (...args) => {
          if (String(args[1]).includes('"phase":"accepted"')) { failed = true; throw new Error('Injected receipt save failure'); }
          return fs.writeFileSync(...args);
        };
      } });
      const f = fixture('receipt-save', {}, { journalIO: io });
      assert.equal((await f.transport.submit(attempt())).outcome, 'uncertain');
      assert.ok(failed);
      assert.equal(f.journal.load(attempt().attemptId).phase, 'submitting');
      assert.equal((await f.transport.submit(attempt())).outcome, 'uncertain');
      assert.equal(f.adds().length, 1);
    });

    await check('receipt rename and fsync failures preserve the one-add boundary', async () => {
      for (const stage of ['rename', 'file-sync', 'root-sync', 'unlock-sync']) {
        let acceptedWrite = false, syncsAfterAcceptance = 0, failed = false;
        const io = new Proxy(fs, { get(target, key) {
          const original = target[key];
          if (typeof original !== 'function') return original;
          return (...args) => {
            if (key === 'writeFileSync' && String(args[1]).includes('"phase":"accepted"')) acceptedWrite = true;
            const sync = key === 'fsyncSync' && acceptedWrite ? ++syncsAfterAcceptance : 0;
            if (!failed && acceptedWrite && ((stage === 'rename' && key === 'renameSync') ||
                (stage === 'file-sync' && sync === 1) || (stage === 'root-sync' && sync === 2) || (stage === 'unlock-sync' && sync === 3))) {
              failed = true; throw new Error('Injected receipt ' + stage + ' failure');
            }
            return original.apply(target, args);
          };
        } });
        const f = fixture('receipt-' + stage, {}, { journalIO: io }), a = attempt();
        assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
        assert.ok(failed, 'fixture reached acceptance persistence boundary: ' + stage);
        const retainedPhase = f.journal.load(a.attemptId).phase;
        const retry = await f.transport.submit(a);
        assert.equal(retry.outcome, retainedPhase === 'accepted' ? 'accepted' : 'uncertain');
        if (retry.outcome === 'accepted') assert.equal(retry.historical, true);
        assert.equal(f.adds().length, 1);
      }
    });

    await check('visible accepted rename needs a successful read durability barrier before reuse', async () => {
      let acceptedWrite = false, acceptedRenamed = false, failDirectorySync = true, refusedBarriers = 0;
      const io = new Proxy(fs, { get(target, key) {
        const original = target[key];
        if (typeof original !== 'function') return original;
        return (...args) => {
          if (key === 'writeFileSync' && String(args[1]).includes('"phase":"accepted"')) acceptedWrite = true;
          if (key === 'fsyncSync' && acceptedRenamed && failDirectorySync && fs.fstatSync(args[0]).isDirectory()) {
            refusedBarriers++;
            throw new Error('Persistent post-rename directory durability failure');
          }
          const result = original.apply(target, args);
          if (key === 'renameSync' && acceptedWrite) acceptedRenamed = true;
          return result;
        };
      } });
      const f = fixture('accepted-read-barrier', {}, { journalIO: io }), a = attempt();
      assert.equal((await f.transport.submit(a)).outcome, 'uncertain');
      assert.ok(acceptedRenamed);
      assert.equal(JSON.parse(fs.readFileSync(f.journal.paths(a.attemptId).record, 'utf8')).phase, 'accepted', 'renamed bytes are visible without proving durability');
      const afterWriteFailure = refusedBarriers;
      await refused(() => f.transport.submit(a));
      assert.equal(refusedBarriers, afterWriteFailure + 1, 'submit independently barriers retained acceptance');
      await refused(() => f.transport.reconcile(a));
      assert.equal(refusedBarriers, afterWriteFailure + 2, 'reconcile independently barriers retained acceptance');
      assert.equal(f.adds().length, 1);
      failDirectorySync = false;
      const historical = await f.transport.submit(a);
      assert.equal(historical.outcome, 'accepted');
      assert.equal(historical.historical, true);
      assert.equal((await f.transport.reconcile(a)).historical, true);
      assert.equal(f.adds().length, 1);
    });

    await check('reader between accepted rename and writer fsync must establish its own durability', async () => {
      const dir = directory('concurrent-read-barrier'), a = attempt();
      const journal = createJournal(dir), readerClient = synthetic();
      let failReaderSync = true, readerBarriers = 0, readerAttempt;
      const readerIO = new Proxy(fs, { get(target, key) {
        if (key !== 'fsyncSync') return target[key];
        return fd => {
          if (fs.fstatSync(fd).isDirectory()) {
            readerBarriers++;
            if (failReaderSync) {
              assert.ok(fs.existsSync(journal.paths(a.attemptId).lock), 'reader observes the still-held writer custody');
              throw new Error('Independent reader directory barrier failed');
            }
          }
          return fs.fsyncSync(fd);
        };
      } });
      const reader = createCodexQueueTransport({ client: readerClient.client, endpoint, recipient, journalDir: dir, journalIO: readerIO });
      let acceptedWrite = false, readerStarted = false;
      const writerIO = new Proxy(fs, { get(target, key) {
        const original = target[key];
        if (typeof original !== 'function') return original;
        return (...args) => {
          if (key === 'writeFileSync' && String(args[1]).includes('"phase":"accepted"')) acceptedWrite = true;
          const result = original.apply(target, args);
          if (key === 'renameSync' && acceptedWrite && !readerStarted) {
            readerStarted = true;
            // Run the independent reader at the exact visibility window, before
            // returning from rename so the writer cannot yet fsync its root.
            readerAttempt = refused(() => reader.submit(a));
            assert.equal(readerBarriers, 1, 'visible acceptance cannot bypass the reader fsync barrier');
          }
          return result;
        };
      } });
      const writerClient = synthetic();
      const writer = createCodexQueueTransport({ client: writerClient.client, endpoint, recipient, journalDir: dir, journalIO: writerIO });
      assert.equal((await writer.submit(a)).outcome, 'accepted');
      assert.ok(readerStarted);
      await readerAttempt;
      assert.equal(readerClient.calls.length, 0);
      assert.equal(writerClient.adds().length, 1);
      failReaderSync = false;
      const historical = await reader.reconcile(a);
      assert.equal(historical.outcome, 'accepted');
      assert.equal(historical.historical, true);
      assert.equal(readerBarriers, 2);
      assert.equal(readerClient.calls.length, 0);
      assert.equal(writerClient.adds().length, 1);
    });

    await check('corrupt retained frame and receipt never inherit positive acceptance', async () => {
      for (const mutate of [
        record => record.frame += 'changed', record => record.frameSha256 = 'c'.repeat(64),
        record => record.clientUserMessageId = randomUUID(), record => record.receipt.threadId = randomUUID(),
        record => record.receipt.queuedSubmissionId = 'short', record => record.receipt.dispatchGeneration++,
        record => record.endpoint.generation = 'foreign-generation', record => record.phase = 'handled',
      ]) {
        const f = fixture('corrupt-retained'), a = attempt();
        await f.transport.submit(a);
        const record = f.journal.load(a.attemptId); mutate(record);
        fs.writeFileSync(f.journal.paths(a.attemptId).record, JSON.stringify(record), { mode: 0o600 });
        await assert.rejects(async () => f.transport.submit(a));
        await assert.rejects(async () => f.transport.reconcile(a));
        assert.equal(f.calls.length, 1);
      }
      const f = fixture('no-record');
      assert.equal((await f.transport.reconcile(attempt())).outcome, 'uncertain');
      assert.equal(f.calls.length, 0);
      assert.deepEqual(fs.readdirSync(f.dir), []);
    });

    await check('falsy and non-object journal JSON never masquerade as an absent attempt', async () => {
      for (const corrupt of [null, false, 0, '', [], 'corrupted', true, 7]) {
        const f = fixture('non-object-evidence'), a = attempt();
        assert.equal((await f.transport.submit(a)).outcome, 'accepted');
        const record = f.journal.paths(a.attemptId).record;
        fs.writeFileSync(record, JSON.stringify(corrupt), { mode: 0o600 });
        assert.equal(fs.statSync(record).mode & 0o777, 0o600);
        assert.throws(() => f.journal.load(a.attemptId));
        await refused(() => f.transport.submit(a));
        await refused(() => f.transport.reconcile(a));
        assert.equal(f.calls.length, 1, 'corrupt JSON cannot trigger an add or a queue lookup');
        assert.equal(f.adds().length, 1, 'a falsy record is corrupt, never missing');
        assert.equal(fs.readFileSync(record, 'utf8'), JSON.stringify(corrupt), 'corrupt retained evidence is not overwritten');
      }
    });

    await check('journal rejects missing, linked, unprotected, foreign, and replaced roots', async () => {
      assert.throws(() => createJournal(path.join(root, 'missing')));
      for (const mode of [0o755, 0o750, 0o500, 0o600, 0o000, 0o1700, 0o2700, 0o4700]) {
        const publicRoot = directory('root-mode-' + mode.toString(8)); fs.chmodSync(publicRoot, mode);
        try { assert.throws(() => createJournal(publicRoot)); }
        finally { fs.chmodSync(publicRoot, 0o700); }
      }
      const privateRoot = directory('private'), alias = path.join(root, 'symlink-root');
      fs.symlinkSync(privateRoot, alias);
      assert.throws(() => createJournal(alias));
      const nested = path.join(privateRoot, 'nested'); fs.mkdirSync(nested, { mode: 0o700 });
      assert.throws(() => createJournal(path.join(alias, 'nested')));
      const foreign = new Proxy(fs, { get(target, key) {
        if (key !== 'lstatSync') return target[key];
        return (...args) => { const stat = fs.lstatSync(...args); if (args[0] === privateRoot) stat.uid = process.getuid() + 1; return stat; };
      } });
      assert.throws(() => createJournal(privateRoot, { io: foreign }));
      const changed = directory('replace'), journal = createJournal(changed);
      fs.renameSync(changed, changed + '-old'); fs.mkdirSync(changed, { mode: 0o700 });
      assert.throws(() => journal.load('attempt-one'));
    });

    await check('journal rejects unsafe ancestors while permitting protected roots below safe sticky directories', async () => {
      for (const mode of [0o777, 0o770, 0o707]) {
        const ancestor = directory('writable-ancestor'), nested = path.join(ancestor, 'private-root');
        fs.mkdirSync(nested, { mode: 0o700 }); fs.chmodSync(ancestor, mode);
        try { assert.throws(() => createJournal(nested), 'nonsticky writable ancestor cannot protect pathname custody'); }
        finally { fs.chmodSync(ancestor, 0o700); }
      }
      const ancestor = directory('foreign-ancestor'), nested = path.join(ancestor, 'private-root');
      fs.mkdirSync(nested, { mode: 0o700 });
      const io = new Proxy(fs, { get(target, key) {
        if (key !== 'lstatSync') return target[key];
        return (...args) => { const stat = fs.lstatSync(...args); if (args[0] === ancestor) stat.uid = process.getuid() + 123; return stat; };
      } });
      assert.throws(() => createJournal(nested, { io }), 'foreign ancestor is refused even when private root is owned');
      const sticky = directory('sticky-ancestor'), safe = path.join(sticky, 'private-root');
      fs.mkdirSync(safe, { mode: 0o700 }); fs.chmodSync(sticky, 0o1777);
      try {
        const journal = createJournal(safe);
        await journal.withLock('safe-attempt', async () => journal.save('safe-attempt', { version: 1, fixture: true }));
        assert.deepEqual(journal.load('safe-attempt'), { version: 1, fixture: true });
      } finally { fs.chmodSync(sticky, 0o700); }
    });

    await check('journal rejects symlinked, hardlinked, unprotected, malformed, and oversized evidence', async () => {
      for (const variant of ['symlink', 'hardlink', 'permissions', 'special-bits', 'directory', 'malformed', 'oversized', 'foreign']) {
        const dir = directory('evidence-' + variant), journal = createJournal(dir);
        const { record } = journal.paths('attempt-one');
        const target = path.join(dir, 'target');
        if (variant === 'symlink' || variant === 'hardlink') {
          fs.writeFileSync(target, '{}', { mode: 0o600 });
          if (variant === 'symlink') fs.symlinkSync(target, record); else fs.linkSync(target, record);
        } else if (variant === 'directory') fs.mkdirSync(record, { mode: 0o700 });
        else fs.writeFileSync(record, variant === 'malformed' ? '{' : variant === 'oversized' ? 'x'.repeat(65537) : '{}', { mode: variant === 'permissions' ? 0o644 : 0o600 });
        if (variant === 'special-bits') fs.chmodSync(record, 0o4600);
        if (variant === 'foreign') {
          const io = new Proxy(fs, { get(target, key) {
            if (key !== 'lstatSync') return target[key];
            return (...args) => { const stat = fs.lstatSync(...args); if (args[0] === record) stat.uid = process.getuid() + 1; return stat; };
          } });
          assert.throws(() => createJournal(dir, { io }).load('attempt-one'));
        } else assert.throws(() => journal.load('attempt-one'));
        const f = synthetic();
        await refused(async () => {
          const t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: dir });
          return await t.submit(attempt());
        });
        assert.equal(f.calls.length, 0);
      }
      const dir = directory('lock-symlink'), journal = createJournal(dir), target = path.join(dir, 'target');
      fs.writeFileSync(target, 'untouched', { mode: 0o600 });
      fs.symlinkSync(target, journal.paths('attempt-one').lock);
      await assert.rejects(() => journal.withLock('attempt-one', async () => assert.fail('symlink lock callback')));
      assert.equal(fs.readFileSync(target, 'utf8'), 'untouched');
      assert.ok(fs.lstatSync(journal.paths('attempt-one').lock).isSymbolicLink());
      assert.throws(() => journal.save('attempt-one', {}), /lock/i);
    });

    await check('competing processes serialize one add without clearing custody', async () => {
      const dir = directory('competition'), marker = path.join(dir, 'calls.jsonl');
      const first = startChild('hold', dir, marker);
      await until(() => markers(marker).length === 1);
      const journal = createJournal(dir), lock = journal.paths('attempt-process').lock;
      const inode = fs.statSync(lock).ino;
      const second = startChild('once', dir, marker);
      const denied = await second.ended;
      assert.equal(denied.code, 0, denied.stderr);
      const result = JSON.parse(denied.stdout);
      assert.ok(result.outcome === 'uncertain' || result.error);
      assert.equal(markers(marker).length, 1);
      assert.equal(fs.statSync(lock).ino, inode);
      fs.writeFileSync(marker + '.release', '', { mode: 0o600 });
      const completed = await first.ended;
      assert.equal(completed.code, 0, completed.stderr);
      assert.equal(JSON.parse(completed.stdout).outcome, 'accepted');
      assert.equal(markers(marker).length, 1);
      const third = await startChild('once', dir, marker).ended;
      assert.equal(JSON.parse(third.stdout).outcome, 'accepted');
      assert.equal(markers(marker).length, 1);
    });

    await check('process death retains submitting evidence and never auto-clears abandoned lock', async () => {
      const dir = directory('crash'), marker = path.join(dir, 'calls.jsonl');
      const first = startChild('hold', dir, marker);
      await until(() => markers(marker).length === 1);
      first.child.kill('SIGKILL');
      const killed = await first.ended;
      assert.equal(killed.signal, 'SIGKILL');
      const journal = createJournal(dir), paths = journal.paths('attempt-process');
      assert.equal(journal.load('attempt-process').phase, 'submitting');
      const before = fs.readFileSync(paths.lock, 'utf8');
      const retry = await startChild('once', dir, marker).ended;
      const result = JSON.parse(retry.stdout);
      assert.ok(result.outcome === 'uncertain' || result.error);
      assert.equal(markers(marker).length, 1);
      assert.equal(fs.readFileSync(paths.lock, 'utf8'), before);
      const f = synthetic(), t = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: dir });
      await refused(() => t.reconcile(attempt('process')));
      assert.equal(f.calls.length, 0);
      assert.equal(fs.readFileSync(paths.lock, 'utf8'), before);
    });

    console.log(`Codex native queue: ${cases.length} fixture groups passed; synthetic RPC only, no native conformance claimed.`);
  } finally {
    for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await Promise.all(children.map(child => child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve))));
    fs.rmSync(root, { recursive: true, force: true });
  }
}
