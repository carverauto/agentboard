// Synthetic connect-only RPC conformance. These tests never bind a socket,
// launch Codex, discover a user profile, or claim installed-version support.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { Duplex } from 'node:stream';
import { pathToFileURL } from 'node:url';

const modulePath = path.resolve(process.argv[2]);
const require = createRequire(modulePath);
const { WebSocketServer, WebSocket } = require('ws');
const { openCodexRpcWire, openCodexAdvisoryRpcWire, requireEvidence } = await import(pathToFileURL(path.join(path.dirname(modulePath), 'rpc-wire.mjs')));
const { createCodexQueueTransport, createCodexAdvisoryTransport } = await import(pathToFileURL(path.join(path.dirname(modulePath), 'transport.mjs')));
const { createJournal } = await import(pathToFileURL(path.join(path.dirname(modulePath), 'journal.mjs')));
const { connectCodexRpcClient } = await import(pathToFileURL(modulePath));

const clone = value => JSON.parse(JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const tick = () => new Promise(resolve => setImmediate(resolve));
const endpoint = {
  serverId: 'synthetic-server', endpointId: 'synthetic-endpoint', generation: 'server-gen',
  profile: 'codex-native-queue-v1', nativeVersion: '0.162.0', protocolSource: 'rust-v0.162.0',
  schemaSha256: 'a'.repeat(64), experimentalApi: true, queueApi: true,
};
const recipient = {
  threadId: 'f445b660-5eac-4ea6-81b6-7cfd05961476', incarnation: 'recipient-gen', persistent: true, topLevel: true,
};
const initialized = { userAgent: 'codex/0.162.0 synthetic', codexHome: '/synthetic/private-home', platformFamily: 'unix', platformOs: 'linux' };
const initializeRequest = {
  id: 'initialize', method: 'initialize',
  params: { clientInfo: { name: 'agentboard_native_queue', version: '0.1.0' }, capabilities: { experimentalApi: true } },
};
function rawUpgrade(request, headers = []) {
  const accept = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  return ['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Accept: ' + accept, ...headers, '', ''].join('\r\n');
}
const read = (id = randomUUID()) => ({ id, method: 'thread/read', params: { threadId: recipient.threadId, includeTurns: false } });
const list = (id = randomUUID()) => ({ id, method: 'thread/queue/list', params: { threadId: recipient.threadId, cursor: null, limit: 50 } });
const add = (id = randomUUID()) => ({
  id, method: 'thread/queue/add',
  params: { threadId: recipient.threadId, input: [{ type: 'text', text: 'synthetic source pointer', text_elements: [] }], clientUserMessageId: randomUUID() },
});
async function until(predicate, timeout = 2000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (predicate()) return;
    await delay(2);
  }
  assert.fail('Synthetic condition did not arrive before fixture deadline');
}
async function refused(operation, forbidden = []) {
  await assert.rejects(Promise.resolve().then(operation), error => {
    assert.ok(error instanceof Error);
    for (const text of forbidden) assert.ok(!error.message.includes(text), 'Internal diagnostics do not disclose peer-controlled details');
    return true;
  });
}

// The HTTP and WebSocket implementations see ordinary Duplex streams. No
// listener, TCP socket, AF_UNIX socket, native daemon, or child process exists.
class MemorySocket extends Duplex {
  constructor() {
    super();
    this.peer = null;
    this.connecting = false;
    this.holdCallbacks = false;
    this.callbacks = [];
    this.writes = [];
    this.on('error', () => {});
  }
  _read() {}
  _write(chunk, encoding, callback) {
    const data = Buffer.from(chunk);
    this.writes.push(data);
    if (!this.peer || this.peer.destroyed) { callback(new Error('Synthetic peer unavailable')); return; }
    queueMicrotask(() => { if (!this.peer.destroyed) this.peer.push(data); });
    if (this.holdCallbacks) this.callbacks.push(callback);
    else callback();
  }
  _writev(chunks, callback) {
    for (const { chunk } of chunks) {
      const data = Buffer.from(chunk);
      this.writes.push(data);
      if (!this.peer || this.peer.destroyed) { callback(new Error('Synthetic peer unavailable')); return; }
      queueMicrotask(() => { if (!this.peer.destroyed) this.peer.push(data); });
    }
    if (this.holdCallbacks) this.callbacks.push(callback);
    else callback();
  }
  _final(callback) { if (this.peer && !this.peer.destroyed) this.peer.push(null); callback(); }
  _destroy(error, callback) {
    this.release();
    if (this.peer && !this.peer.destroyed) this.peer.destroy();
    callback(error);
  }
  release() { this.holdCallbacks = false; for (const callback of this.callbacks.splice(0)) callback(); }
  setTimeout() { return this; }
  setNoDelay() { return this; }
  setKeepAlive() { return this; }
}

const fixtures = new Set();
function fixture(options = {}) {
  const clientSocket = new MemorySocket(), serverSocket = new MemorySocket();
  clientSocket.peer = serverSocket; serverSocket.peer = clientSocket;
  const httpServer = http.createServer();
  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false, autoPong: false });
  const f = {
    clientSocket, serverSocket, httpServer, wss, peer: null, client: null,
    calls: [], frames: [], steps: [], controls: [], connections: 0, checks: 0,
    identity: { endpoint: clone(endpoint), recipient: clone(recipient) },
    revoked: false, invalidBoundary: false, unsubscriptions: 0, retirement: null,
  };
  const boundary = {
    descriptor: Object.freeze({ fixture: 'in-memory-duplex', generation: 'fixture-generation' }),
    check() {
      f.checks++;
      if (f.invalidBoundary) throw new Error('PRIVATE_SYNTHETIC_PATH_CHANGED');
    },
  };
  const evidence = {
    current() { return f.revoked ? null : clone(f.identity); },
    bindConnection(value) {
      f.steps.push('bind-connected-stream');
      assert.equal(value.stream, clientSocket);
      assert.equal(value.connection, f.connectionToken);
      assert.deepEqual(value.socket, boundary.descriptor);
      f.binds = (f.binds || 0) + 1;
      return options.bindConnection ? options.bindConnection(value, f) : true;
    },
    verifyConnection(value) {
      if (!f.connectionToken) f.connectionToken = value.connection;
      assert.equal(value.connection, f.connectionToken);
      assert.ok(Object.isFrozen(value.connection));
      f.steps.push(value.initialize === null ? 'verify-before-connect' : 'verify-initialized');
      if (options.verifyConnection) return options.verifyConnection(value, f);
      if (value.initialize !== null) assert.deepEqual(value.initialize, initialized);
      return true;
    },
    subscribeRetirement(callback) {
      f.retirement = callback;
      return () => { f.unsubscriptions++; f.retirement = null; };
    },
  };
  f.evidence = evidence;
  f.revoke = () => { f.revoked = true; f.retirement?.(); };
  f.respond = (request, result = { synthetic: true }) => f.send({ id: request.id, result });
  f.send = value => { if (f.peer?.readyState === WebSocket.OPEN) f.peer.send(JSON.stringify(value)); };
  httpServer.on('upgrade', (request, socket, head) => {
    f.headers = request.headers;
    if (options.onUpgrade) { options.onUpgrade(request, socket, f); return; }
    if (options.rejectUpgrade) { socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return; }
    wss.handleUpgrade(request, socket, head, peer => {
      f.peer = peer;
      peer.on('error', () => {});
      peer.on('ping', data => f.controls.push(['ping', data.toString()]));
      peer.on('pong', data => f.controls.push(['pong', data.toString()]));
      peer.on('message', (bytes, binary) => {
        assert.equal(binary, false, 'Client sends only text JSON frames');
        const message = JSON.parse(bytes.toString());
        f.frames.push(message);
        if (message.method === 'initialize') {
          f.steps.push('initialize');
          if (options.onInitialize) options.onInitialize(message, f);
          else f.respond(message, initialized);
        } else if (message.method === 'initialized') {
          f.steps.push('initialized');
          if (options.onInitialized) options.onInitialized(message, f);
        } else {
          f.calls.push(message);
          if (options.onRequest) options.onRequest(message, f);
          else f.respond(message);
        }
      });
    });
  });
  const connect = () => {
    f.connections++;
    f.steps.push('connect');
    if (options.connectThrows) throw new Error('PRIVATE_SYNTHETIC_CONNECT_FAILURE');
    if (!options.stallHandshake) httpServer.emit('connection', serverSocket);
    options.onConnect?.(f);
    return clientSocket;
  };
  f.open = overrides => {
    const promise = (options.advisory ? openCodexAdvisoryRpcWire : openCodexRpcWire)({ connect, boundary, evidence, timeoutMs: options.timeoutMs ?? 250, lifetimeMs: options.lifetimeMs ?? 10000, ...overrides });
    // Attach immediately so intentional rejection races never cause an
    // unhandled rejection before the test checks the recorded result.
    promise.catch(() => {});
    const ready = promise.then(client => { f.client = client; return client; });
    ready.catch(() => {});
    return ready;
  };
  f.close = () => {
    f.client?.close();
    f.peer?.terminate();
    clientSocket.destroy(); serverSocket.destroy();
    wss.close(); httpServer.close(); fixtures.delete(f);
  };
  fixtures.add(f);
  return f;
}
async function opened(options = {}) { const f = fixture(options); await f.open(); return f; }
function pending(f, request = read()) {
  const result = Promise.resolve().then(() => f.client.request(request));
  result.catch(() => {});
  return result;
}
async function retiresOn(name, emit, { deadline = false } = {}) {
  await check(name, async () => {
    const f = await opened({ onRequest() {}, timeoutMs: deadline ? 35 : 1000 });
    const request = read(), result = pending(f, request);
    await until(() => f.calls.length === 1);
    await emit(f, request);
    if (!deadline) await until(() => f.client.identity() === null, 200);
    await refused(() => result);
    assert.equal(f.client.identity(), null);
    assert.equal(f.connections, 1);
    await refused(() => f.client.request(read()));
    assert.equal(f.calls.length, 1, 'Retirement never retries or emits later requests');
    f.close();
  });
}
let count = 0;
async function check(name, run) {
  let watchdog;
  try {
    await Promise.race([run(), new Promise((_, reject) => { watchdog = setTimeout(() => reject(new Error('Fixture watchdog: ' + name)), 5000); })]);
    console.log('ok - ' + name); count++;
  } finally { clearTimeout(watchdog); }
}

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-codex-rpc-'));
fs.chmodSync(temporary, 0o700);
try {
  await check('bounded initialization and evidence precede the ready identity', async () => {
    const f = await opened();
    await until(() => f.frames.length === 2);
    assert.deepEqual(f.frames, [initializeRequest, { method: 'initialized' }]);
    assert.ok(f.steps.indexOf('verify-before-connect') < f.steps.indexOf('connect'));
    assert.ok(f.steps.includes('verify-initialized'));
    assert.equal(f.binds, 1);
    assert.ok(f.steps.indexOf('bind-connected-stream') < f.steps.indexOf('initialize'));
    assert.equal(f.connections, 1);
    assert.equal(f.headers['sec-websocket-extensions'], undefined, 'Compression is not offered');
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    assert.deepEqual(Object.keys(f.client).sort(), ['close', 'identity', 'request']);
    for (const request of [read(0), list('list-1'), add('add-1')]) {
      const response = await f.client.request(request);
      assert.deepEqual(response, { id: request.id, result: { synthetic: true } });
      assert.deepEqual(f.calls.at(-1), request);
    }
    f.close();
  });

  await check('initialized notification must flush before opening resolves', async () => {
    const f = fixture({ onInitialize(request, current) {
      current.clientSocket.holdCallbacks = true;
      current.respond(request, initialized);
    } });
    let settled = false;
    const opening = f.open().then(client => { settled = true; return client; });
    opening.catch(() => {});
    await until(() => f.frames.some(frame => frame.method === 'initialized'));
    await tick();
    assert.equal(settled, false);
    f.clientSocket.release();
    await opening;
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    f.close();
  });

  await check('normal fragmented responses and concurrent out-of-order IDs correlate exactly', async () => {
    const f = await opened({ onRequest() {} });
    const a = read('string-id'), b = list(7);
    const pa = pending(f, a), pb = pending(f, b);
    await until(() => f.calls.length === 2);
    f.respond(b, { order: 2 });
    const text = JSON.stringify({ id: a.id, result: { unicode: 'snowman ☃' } });
    f.peer.send(text.slice(0, 10), { fin: false });
    f.peer.send(text.slice(10, 23), { fin: false });
    f.peer.send(text.slice(23), { fin: true });
    assert.deepEqual(await pb, { id: 7, result: { order: 2 } });
    assert.deepEqual(await pa, { id: 'string-id', result: { unicode: 'snowman ☃' } });
    f.close();
  });

  await check('raw correlated JSON-RPC errors are returned without invented success', async () => {
    const f = await opened({ onRequest(request, current) { current.send({ jsonrpc: '2.0', id: request.id, error: { code: -32000, message: 'synthetic refusal' } }); } });
    const response = await f.client.request(read('error-response'));
    assert.deepEqual(response, { jsonrpc: '2.0', id: 'error-response', error: { code: -32000, message: 'synthetic refusal' } });
    f.close();
  });

  await check('close retires identity synchronously and rejects pending work once', async () => {
    const f = await opened({ onRequest() {} });
    const result = pending(f);
    await until(() => f.calls.length === 1);
    assert.equal(f.client.close(), undefined);
    assert.equal(f.client.identity(), null);
    assert.equal(f.clientSocket.destroyed, true);
    f.client.close();
    await refused(() => result);
    await refused(() => f.client.request(read()));
    assert.equal(f.connections, 1);
    assert.equal(f.unsubscriptions, 1);
    f.close();
  });

  await check('trusted evidence revocation synchronously retires and drains pending work', async () => {
    const f = await opened({ onRequest() {} });
    const result = pending(f);
    await until(() => f.calls.length === 1);
    f.revoke();
    assert.equal(f.client.identity(), null);
    assert.equal(f.clientSocket.destroyed, true);
    await refused(() => result);
    f.close();
  });

  for (const callback of ['current', 'verifyConnection']) {
    await check('synchronous retirement from ' + callback + ' during request cannot leak a pending promise', async () => {
      const f = await opened({ onRequest() {} });
      f.evidence[callback] = () => {
        f.retirement?.();
        return callback === 'current' ? clone(f.identity) : true;
      };
      const result = f.client.request(read());
      const state = await Promise.race([result.then(() => 'resolved', () => 'rejected'), delay(200).then(() => 'pending')]);
      assert.equal(state, 'rejected', 'A callback-triggered retirement must reject rather than install new pending state');
      assert.equal(f.client.identity(), null);
      assert.equal(f.clientSocket.destroyed, true);
      assert.equal(f.calls.length, 0);
      f.close();
    });
    await check('synchronous retirement from ' + callback + ' during identity cannot return a stale identity', async () => {
      const f = await opened({ onRequest() {} });
      const result = pending(f);
      await until(() => f.calls.length === 1);
      f.evidence[callback] = () => {
        f.retirement?.();
        return callback === 'current' ? clone(f.identity) : true;
      };
      assert.equal(f.client.identity(), null);
      assert.equal(f.clientSocket.destroyed, true);
      await refused(() => result);
      assert.equal(f.calls.length, 1);
      f.close();
    });
  }

  for (const [label, invalidate] of [
    ['socket path identity change', f => { f.invalidBoundary = true; }],
    ['endpoint generation change', f => { f.identity.endpoint.generation = 'new-generation'; }],
    ['recipient incarnation change', f => { f.identity.recipient.incarnation = 'new-incarnation'; }],
  ]) await check(label + ' retires synchronously at the identity boundary', async () => {
    const f = await opened({ onRequest() {} });
    const result = pending(f);
    await until(() => f.calls.length === 1);
    invalidate(f);
    assert.equal(f.client.identity(), null);
    assert.equal(f.clientSocket.destroyed, true);
    await refused(() => result, ['PRIVATE_SYNTHETIC_PATH_CHANGED']);
    f.close();
  });

  for (const [label, options] of [
    ['connection failure', { connectThrows: true }],
    ['HTTP upgrade rejection', { rejectUpgrade: true }],
    ['stalled HTTP handshake', { stallHandshake: true, timeoutMs: 35 }],
    ['stalled initialize response', { onInitialize() {}, timeoutMs: 35 }],
    ['stalled initialized flush', { timeoutMs: 35, onInitialize(request, f) { f.clientSocket.holdCallbacks = true; f.respond(request, initialized); } }],
  ]) await check(label + ' is bounded and never redials', async () => {
    const f = fixture(options);
    const started = Date.now();
    await refused(() => f.open(), ['PRIVATE_SYNTHETIC_CONNECT_FAILURE']);
    assert.ok(Date.now() - started < 1500);
    assert.equal(f.connections, 1);
    assert.equal(f.calls.length, 0);
    f.close();
  });

  for (const [label, onUpgrade] of [
    ['HTTP redirect', (_request, socket) => socket.end('HTTP/1.1 302 Found\r\nLocation: ws://redirect.invalid/rpc\r\nContent-Length: 0\r\n\r\n')],
    ['unsolicited compression extension', (request, socket) => socket.write(rawUpgrade(request, ['Sec-WebSocket-Extensions: permessage-deflate']))],
    ['HTTP response headers over 8 KiB', (request, socket) => socket.write(rawUpgrade(request, ['X-Synthetic-Oversize: ' + 'x'.repeat(8192)]))],
  ]) await check(label + ' fails during handshake with no initialize or redial', async () => {
    const f = fixture({ timeoutMs: 1000, onUpgrade });
    const start = Date.now();
    await refused(() => f.open());
    assert.ok(Date.now() - start < 500, 'Handshake rejection must not merely wait for the initialize deadline');
    await tick();
    assert.equal(f.connections, 1);
    const outbound = Buffer.concat(f.clientSocket.writes);
    const httpEnd = outbound.indexOf('\r\n\r\n') + 4;
    assert.ok(httpEnd >= 4);
    assert.equal(outbound.length, httpEnd, 'No WebSocket initialize bytes follow a rejected HTTP upgrade');
    f.close();
  });

  for (const value of [
    null, {}, { ...initialized, userAgent: 42 }, { ...initialized, codexHome: null },
    { ...initialized, platformFamily: [] }, { ...initialized, platformOs: false },
  ]) await check('malformed initialize result fails closed: ' + JSON.stringify(value), async () => {
    const f = fixture({ onInitialize(request, current) { current.respond(request, value); } });
    await refused(() => f.open());
    assert.equal(f.frames.filter(frame => frame.method === 'initialized').length, 0);
    assert.equal(f.calls.length, 0);
    f.close();
  });

  await check('independent preconnect evidence refusal prevents a dial', async () => {
    const f = fixture({ verifyConnection() { return false; } });
    await refused(() => f.open());
    assert.equal(f.connections, 0);
    f.close();
  });
  await check('initialization cannot itself establish trusted evidence', async () => {
    const f = fixture({ verifyConnection(value) { return value.initialize === null; } });
    await refused(() => f.open());
    assert.equal(f.calls.length, 0);
    assert.equal(f.connections, 1);
    f.close();
  });
  await check('an unverified connected stream retires before initialize is sent', async () => {
    const f = fixture({ bindConnection() { return false; } });
    await refused(() => f.open());
    assert.equal(f.connections, 1);
    assert.equal(f.binds, 1);
    assert.equal(f.frames.length, 0);
    assert.equal(f.clientSocket.destroyed, true);
    f.close();
  });
  await check('the public client fails closed without an independent evidence provider', async () => {
    const lstat = fs.lstatSync;
    let probes = 0;
    fs.lstatSync = (...args) => { probes++; return lstat(...args); };
    try {
      await refused(() => connectCodexRpcClient({ codexHome: '/PRIVATE_SYNTHETIC_UNPROBED_PATH' }), ['PRIVATE_SYNTHETIC_UNPROBED_PATH']);
      assert.equal(probes, 0);
    } finally { fs.lstatSync = lstat; }
  });
  await check('a throwing evidence provider cannot disclose its private diagnostic', async () => {
    const f = fixture();
    f.evidence.current = () => { throw new Error('PRIVATE_SYNTHETIC_PROVIDER_FAILURE'); };
    await refused(() => f.open(), ['PRIVATE_SYNTHETIC_PROVIDER_FAILURE']);
    assert.equal(f.connections, 0);
    f.close();
  });
  await check('synchronous revocation during subscription prevents connection and releases the subscription', async () => {
    const f = fixture();
    f.evidence.subscribeRetirement = callback => { callback(); return () => { f.unsubscriptions++; }; };
    await refused(() => f.open());
    assert.equal(f.connections, 0);
    assert.equal(f.unsubscriptions, 1);
    f.close();
  });
  await check('an asynchronous connected-stream proof is insufficient', async () => {
    const f = fixture({ bindConnection() { return Promise.resolve(true); } });
    await refused(() => f.open());
    assert.equal(f.frames.length, 0);
    assert.equal(f.connections, 1);
    f.close();
  });
  await check('a trickle of incomplete initialize fragments cannot extend the opening deadline', async () => {
    let trickle;
    const f = fixture({ timeoutMs: 35, onInitialize(request, current) {
      const text = JSON.stringify({ id: request.id, result: initialized });
      let index = 0;
      trickle = setInterval(() => {
        if (current.peer.readyState === WebSocket.OPEN) current.peer.send(text.slice(index, ++index), { fin: false });
      }, 2);
    } });
    const start = Date.now();
    try {
      await refused(() => f.open());
      assert.ok(Date.now() - start < 500);
      assert.equal(f.connections, 1);
    } finally { clearInterval(trickle); f.close(); }
  });

  await check('outgoing request parameters are snapshotted before caller mutation', async () => {
    const f = await opened({ onRequest() {} });
    const request = add('immutable-request'), expected = clone(request);
    const result = f.client.request(request);
    request.params.input[0].text = 'changed after request';
    request.params.threadId = randomUUID();
    await until(() => f.calls.length === 1);
    assert.deepEqual(f.calls[0], expected);
    f.respond(expected, { acknowledged: true });
    assert.deepEqual(await result, { id: expected.id, result: { acknowledged: true } });
    f.close();
  });
  await check('retirement inside request toJSON cannot leak a pending promise or native write', async () => {
    const f = await opened({ onRequest() {} });
    const request = { toJSON() { f.client.close(); return read('retired-by-serialization'); } };
    const result = f.client.request(request);
    const state = await Promise.race([result.then(() => 'resolved', () => 'rejected'), delay(200).then(() => 'pending')]);
    assert.equal(state, 'rejected');
    assert.equal(f.client.identity(), null);
    assert.equal(f.clientSocket.destroyed, true);
    assert.equal(f.calls.length, 0);
    f.close();
  });
  await check('retirement inside the connect factory immediately destroys its returned stream', async () => {
    const f = fixture({ onConnect(current) { current.retirement?.(); } });
    await refused(() => f.open());
    assert.equal(f.connections, 1);
    assert.equal(f.clientSocket.destroyed, true);
    assert.equal(f.frames.length, 0);
    assert.equal(f.clientSocket.writes.length, 0);
    f.close();
  });
  await check('identity and returned response snapshots cannot be mutated by callers', async () => {
    const f = await opened();
    const identity = f.client.identity();
    assert.equal(Object.isFrozen(identity), true);
    assert.equal(Object.isFrozen(identity.endpoint), true);
    assert.throws(() => { identity.recipient.incarnation = 'changed'; }, TypeError);
    const response = await f.client.request(read());
    assert.equal(Object.isFrozen(response), true);
    assert.equal(Object.isFrozen(response.result), true);
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    f.close();
  });

  const invalidRequests = [
    ['turn/start', { ...read(), method: 'turn/start' }],
    ['approval response', { id: 'approval', result: { decision: 'accept' } }],
    ['caller initialize', { ...initializeRequest }],
    ['caller initialized', { method: 'initialized' }],
    ['extra envelope key', { ...read(), jsonrpc: '2.0' }],
    ['empty ID', read('')], ['oversized ID', read('x'.repeat(129))],
    ['negative ID', read(-1)], ['fractional ID', read(1.5)], ['unsafe ID', read(Number.MAX_SAFE_INTEGER + 1)],
    ['null ID', read(null)], ['object ID', read({ value: 1 })],
    ['foreign thread', { ...read(), params: { threadId: randomUUID(), includeTurns: false } }],
    ['read turns', { ...read(), params: { threadId: recipient.threadId, includeTurns: true } }],
    ['extra read parameter', { ...read(), params: { threadId: recipient.threadId, includeTurns: false, extra: true } }],
    ['missing read parameter', { ...read(), params: { threadId: recipient.threadId } }],
    ['zero page limit', { ...list(), params: { ...list().params, limit: 0 } }],
    ['oversized page limit', { ...list(), params: { ...list().params, limit: 101 } }],
    ['fractional page limit', { ...list(), params: { ...list().params, limit: 1.5 } }],
    ['numeric cursor', { ...list(), params: { ...list().params, cursor: 10 } }],
    ['negative cursor', { ...list(), params: { ...list().params, cursor: '-1' } }],
    ['nondecimal cursor', { ...list(), params: { ...list().params, cursor: 'next' } }],
    ['oversized frame', { ...add(), params: { ...add().params, input: [{ type: 'text', text: 'x'.repeat(4097), text_elements: [] }] } }],
    ['oversized UTF-8 frame', { ...add(), params: { ...add().params, input: [{ type: 'text', text: '☃'.repeat(1366), text_elements: [] }] } }],
    ['image input', { ...add(), params: { ...add().params, input: [{ type: 'image', url: 'https://example.invalid/image' }] } }],
    ['multiple inputs', { ...add(), params: { ...add().params, input: [...add().params.input, ...add().params.input] } }],
    ['nonempty text elements', { ...add(), params: { ...add().params, input: [{ type: 'text', text: 'x', text_elements: [{}] }] } }],
    ['non-UUID message ID', { ...add(), params: { ...add().params, clientUserMessageId: 'untrusted' } }],
  ];
  for (const [name, request] of invalidRequests) await check('request allowlist refuses ' + name + ' before any native effect', async () => {
    const f = await opened();
    await refused(() => f.client.request(request));
    assert.equal(f.calls.length, 0);
    assert.deepEqual(f.client.identity(), { endpoint, recipient }, 'Invalid local input has no native effect and does not retire the session');
    f.close();
  });

  await check('boundary values allow text exactly 4096 bytes and decimal queue cursors', async () => {
    const f = await opened();
    const request = add('x'.repeat(128));
    request.params.input[0].text = 'x'.repeat(4096);
    await f.client.request(request);
    for (const limit of [1, 100]) {
      const request = list(); request.params.limit = limit; request.params.cursor = '100';
      await f.client.request(request);
    }
    await f.client.request(read(Number.MAX_SAFE_INTEGER));
    assert.equal(f.calls.length, 4);
    f.close();
  });
  await check('completed IDs cannot be reused within a connection lifetime', async () => {
    const f = await opened();
    await f.client.request(read('used-once'));
    await refused(() => f.client.request(read('used-once')));
    assert.equal(f.calls.length, 1);
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    f.close();
  });
  await check('the fixed initialization ID cannot be reused by a queue request', async () => {
    const f = await opened();
    await refused(() => f.client.request(read('initialize')));
    assert.equal(f.calls.length, 0);
    f.close();
  });
  await check('no more than eight native requests can be pending', async () => {
    const f = await opened({ onRequest() {} });
    const results = Array.from({ length: 8 }, (_, n) => pending(f, read('pending-' + n)));
    await until(() => f.calls.length === 8);
    await refused(() => f.client.request(read('pending-9')));
    assert.equal(f.calls.length, 8);
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    f.client.close();
    await Promise.all(results.map(result => refused(() => result)));
    f.close();
  });
  await check('a connection lifetime permits at most 128 application requests', async () => {
    const f = await opened();
    for (let i = 0; i < 128; i++) await f.client.request(read(i));
    await refused(() => f.client.request(read(128)));
    assert.equal(f.calls.length, 128);
    f.close();
  });

  await retiresOn('a request deadline retires the whole connection without retry', async () => {}, { deadline: true });
  await check('an overall lifetime deadline retires an otherwise idle client', async () => {
    const f = await opened({ lifetimeMs: 65, timeoutMs: 40 });
    await until(() => f.client.identity() === null);
    assert.equal(f.clientSocket.destroyed, true);
    await refused(() => f.client.request(read()));
    assert.equal(f.connections, 1);
    f.close();
  });
  await retiresOn('a server close retires pending work', f => f.peer.close());
  await retiresOn('a transport error retires pending work with generic diagnostics', f => f.clientSocket.destroy(new Error('PRIVATE_SYNTHETIC_SOCKET_ERROR')));
  await retiresOn('a response with an unknown ID retires rather than being ignored', f => f.send({ id: 'foreign-id', result: {} }));
  await retiresOn('numeric and string response IDs are never coerced', (f, request) => f.send({ id: Number(request.id) || 123, result: {} }));
  await retiresOn('a malformed JSON message retires the client', f => f.peer.send('{"id":'));
  await retiresOn('a binary JSON message cannot be accepted as a response', (f, request) => f.peer.send(Buffer.from(JSON.stringify({ id: request.id, result: {} }))));
  await retiresOn('invalid UTF-8 text retires the client', f => f.serverSocket.write(Buffer.from([0x81, 0x02, 0xc3, 0x28])));
  await retiresOn('a response exceeding 256 KiB retires the client', (f, request) => f.send({ id: request.id, result: 'x'.repeat(262144) }));
  await retiresOn('an aggregate fragmented response exceeding 256 KiB retires the client', (f, request) => {
    const response = JSON.stringify({ id: request.id, result: 'x'.repeat(262144) });
    for (let offset = 0; offset < response.length; offset += 32768) {
      f.peer.send(response.slice(offset, offset + 32768), { fin: offset + 32768 >= response.length });
    }
  });
  await retiresOn('an unsolicited compressed RSV1 frame retires the client', f => f.serverSocket.write(Buffer.from([0xc1, 0x02, 0x7b, 0x7d])));
  for (const emittedAtMs of ['42', 1.5, null, Number.MAX_SAFE_INTEGER + 1]) {
    await retiresOn('notification emittedAtMs rejects ' + JSON.stringify(emittedAtMs), f => f.send({ method: 'synthetic/notification', params: {}, emittedAtMs }));
  }
  for (const [label, envelope] of [
    ['array envelope', () => []], ['null envelope', () => null],
    ['result and error', id => ({ id, result: {}, error: { code: -1, message: 'bad' } })],
    ['missing result or error', id => ({ id })], ['extra envelope key', id => ({ id, result: {}, metadata: {} })],
    ['wrong JSON-RPC version', id => ({ jsonrpc: '1.0', id, result: {} })],
    ['server approval request', id => ({ id: 'approve-' + id, method: 'item/commandExecution/requestApproval', params: {} })],
    ['server unknown request', id => ({ id: 'server-' + id, method: 'unknown/action', params: {} })],
  ]) await retiresOn(label + ' retires without a response to the server', (f, request) => f.send(envelope(request.id)));

  await check('a duplicate response retires a connection even after its original promise resolves', async () => {
    const f = await opened();
    await f.client.request(read('duplicate'));
    f.send({ id: 'duplicate', result: { duplicate: true } });
    await until(() => f.client.identity() === null);
    assert.equal(f.calls.length, 1);
    f.close();
  });
  for (const control of ['ping', 'pong']) await retiresOn('control ' + control + ' retires without automatic control replies', async f => {
    f.peer[control]('synthetic-control');
    await tick();
    assert.deepEqual(f.controls, []);
  });
  await retiresOn('more than 128 response fragments are bounded', (f, request) => {
    const text = JSON.stringify({ id: request.id, result: 'x'.repeat(160) });
    for (let i = 0; i < 129; i++) f.peer.send(text.slice(i, i + 1), { fin: false });
  });
  await retiresOn('more than 128 buffered partial-frame chunks are bounded', async f => {
    f.serverSocket.write(Buffer.from([0x81, 126, 0x01, 0x00]));
    for (let i = 0; i < 130 && !f.serverSocket.destroyed; i++) { f.serverSocket.write(Buffer.from('x')); await tick(); }
  });
  await check('notifications are ignored within budget and retire above 128', async () => {
    const f = await opened();
    for (let i = 0; i < 128; i++) f.send({ method: 'synthetic/notification', params: { i } });
    await f.client.request(read('after-128-notifications'));
    f.send({ method: 'synthetic/notification', params: { i: 128 } });
    await until(() => f.client.identity() === null);
    assert.equal(f.calls.length, 1);
    f.close();
  });
  await check('notifications accept optional safe-integer emittedAtMs without exposing callbacks', async () => {
    const f = await opened();
    for (const emittedAtMs of [0, -1, 1720000000000, Number.MAX_SAFE_INTEGER]) {
      f.send({ method: 'synthetic/notification', params: { synthetic: true }, emittedAtMs });
    }
    assert.deepEqual(await f.client.request(read('after-timestamped-notifications')), { id: 'after-timestamped-notifications', result: { synthetic: true } });
    assert.deepEqual(f.client.identity(), { endpoint, recipient });
    assert.equal(f.calls.length, 1);
    f.close();
  });
  await check('the total raw socket byte budget stops a bounded-message flood', async () => {
    const f = await opened();
    for (let i = 0; i < 120 && f.client.identity(); i++) {
      f.send({ method: 'synthetic/notification', params: { content: 'x'.repeat(40000) } });
      await tick();
    }
    assert.equal(f.client.identity(), null);
    assert.equal(f.calls.length, 0);
    f.close();
  });

  await check('transport journals before the sole add and preserves historical acceptance after retirement', async () => {
    const dir = path.join(temporary, 'accepted'); fs.mkdirSync(dir, { mode: 0o700 });
    const journal = createJournal(dir);
    const attempt = {
      attemptId: 'wire-integration-accepted', source: { kind: 'wake', id: 'source-1', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source/1' },
      recipient: clone(recipient), bindingEpoch: 1, dispatchGeneration: 1,
    };
    const f = await opened({ onRequest(request, current) {
      assert.equal(request.method, 'thread/queue/add');
      const retained = journal.load(attempt.attemptId);
      assert.equal(retained.phase, 'submitting');
      assert.equal(retained.clientUserMessageId, request.params.clientUserMessageId);
      assert.equal(retained.frame, request.params.input[0].text);
      current.respond(request, { queuedSubmission: { id: randomUUID(), clientUserMessageId: request.params.clientUserMessageId, input: request.params.input } });
    } });
    const transport = createCodexQueueTransport({ client: f.client, endpoint, recipient, journalDir: dir });
    const result = await transport.submit(attempt);
    assert.equal(result.outcome, 'accepted');
    assert.equal(result.historical, false);
    assert.equal(journal.load(attempt.attemptId).phase, 'accepted');
    f.revoke();
    const historical = await transport.submit(attempt);
    assert.equal(historical.outcome, 'accepted');
    assert.equal(historical.historical, true);
    assert.deepEqual(historical.receipt, result.receipt);
    assert.equal(f.calls.length, 1);
    assert.equal(f.connections, 1);
    f.close();
  });

  await check('an ambiguous add keeps durable submitting evidence and never resubmits on a fresh client', async () => {
    const dir = path.join(temporary, 'ambiguous'); fs.mkdirSync(dir, { mode: 0o700 });
    const journal = createJournal(dir);
    const attempt = {
      attemptId: 'wire-integration-ambiguous', source: { kind: 'wake', id: 'source-2', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source/2' },
      recipient: clone(recipient), bindingEpoch: 1, dispatchGeneration: 1,
    };
    let acceptedItem;
    const original = await opened({ timeoutMs: 35, onRequest(request) {
      assert.equal(request.method, 'thread/queue/add');
      acceptedItem = { id: randomUUID(), clientUserMessageId: request.params.clientUserMessageId, input: clone(request.params.input) };
    } });
    const first = createCodexQueueTransport({ client: original.client, endpoint, recipient, journalDir: dir, timeoutMs: 100 });
    assert.equal((await first.submit(attempt)).outcome, 'uncertain');
    assert.equal(journal.load(attempt.attemptId).phase, 'submitting');
    assert.equal(original.client.identity(), null);
    // A late response cannot resurrect the retired connection or turn unknown
    // acceptance into a second add. A new independently opened fixture only lists.
    original.send({ id: original.calls[0].id, result: { queuedSubmission: acceptedItem } });
    await tick();
    assert.equal(original.client.identity(), null);
    const next = await opened({ onRequest(request, current) {
      assert.equal(request.method, 'thread/queue/list');
      current.respond(request, { data: [acceptedItem], nextCursor: null });
    } });
    const second = createCodexQueueTransport({ client: next.client, endpoint, recipient, journalDir: dir });
    assert.equal((await second.submit(attempt)).outcome, 'uncertain');
    assert.equal(next.calls.length, 0);
    assert.equal((await second.reconcile(attempt)).outcome, 'accepted');
    assert.equal(journal.load(attempt.attemptId).phase, 'accepted');
    assert.equal(original.calls.length, 1);
    assert.equal(next.calls.length, 1);
    original.close(); next.close();
  });
  await check('durable advisory profile is distinct, epoch-fenced, journaled and retired', async () => {
    const dir = path.join(temporary, 'durable-advisory'); fs.mkdirSync(dir, { mode: 0o700 });
    const f = fixture({ advisory: true, onRequest(request, current) {
      current.respond(request, { queuedSubmission: { id: randomUUID(), input: request.params.input, clientUserMessageId: request.params.clientUserMessageId } });
    } });
    f.identity.endpoint.profile = 'codex-durable-advisory-v1';
    f.identity.recipient = { threadId: recipient.threadId, identityKind: 'durable-conversation-v1', enrollmentRevision: 42, bindingEpoch: 3, persistent: true, topLevel: true };
    assert.throws(() => requireEvidence(f.evidence));
    await f.open();
    assert.throws(() => createCodexQueueTransport({ client: f.client, ...f.identity, journalDir: dir }));
    const transport = createCodexAdvisoryTransport({ client: f.client, ...f.identity, journalDir: dir });
    const attempt = { attemptId: 'advisory', source: { kind: 'wake', id: 'source', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source' }, recipient: clone(f.identity.recipient), bindingEpoch: 3, dispatchGeneration: 1 };
    await assert.rejects(transport.submit({ ...attempt, bindingEpoch: 2 }));
    assert.equal(f.calls.length, 0);
    assert.equal((await transport.submit(attempt)).outcome, 'accepted');
    assert.match(f.calls[0].params.input[0].text, /durable advisory notice v1/);
    f.revoke(); assert.equal(f.client.identity(), null);
    assert.equal((await transport.submit(attempt)).historical, true);
    assert.equal(f.calls.length, 1); f.close();
  });
  for (const invalid of ['strict-recipient', 'zero-epoch', 'fake-incarnation']) {
    await check('advisory wire refuses ' + invalid + ' before connect', async () => {
      const f = fixture({ advisory: true }); f.identity.endpoint.profile = 'codex-durable-advisory-v1';
      if (invalid !== 'strict-recipient') f.identity.recipient = { threadId: recipient.threadId, identityKind: 'durable-conversation-v1', enrollmentRevision: 42, bindingEpoch: invalid === 'zero-epoch' ? 0 : 3, persistent: true, topLevel: true, ...(invalid === 'fake-incarnation' ? { incarnation: 'pretend' } : {}) };
      await refused(() => f.open()); assert.equal(f.connections, 0); f.close();
    });
  }
  console.log('passed ' + count + ' synthetic Codex RPC client cases');
} finally {
  for (const f of [...fixtures]) f.close();
  fs.rmSync(temporary, { recursive: true, force: true });
}
