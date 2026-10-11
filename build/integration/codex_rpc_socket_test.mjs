// Synthetic path metadata and optional invented AF_UNIX peer only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const clientPath = path.resolve(process.argv[2]);
const root = path.dirname(clientPath);
const { inspectCodexSocket } = await import(pathToFileURL(path.join(root, 'socket-discovery.mjs')));
const { connectCodexRpcClient } = await import(pathToFileURL(clientPath));
const { openCodexRpcWire } = await import(pathToFileURL(path.join(root, 'rpc-wire.mjs')));
const { createCodexQueueTransport } = await import(pathToFileURL(path.join(root, 'transport.mjs')));
const { WebSocketServer } = createRequire(clientPath)('ws');
const uid = process.geteuid();
const home = '/home/synthetic-codex';
const advertised = `${home}/app-server-control/app-server-control.sock`;
const target = '/private/tmp/codex-daemon-' + uid + '/' + createHash('sha256').update(advertised).digest('hex');
let groups = 0;
function pass(name) { groups++; console.log('ok - ' + name); }
function fixture() {
  let inode = 10;
  const table = new Map();
  function stat(type, mode, owner = uid) {
    return { dev: 1, ino: inode++, mode, uid: owner, nlink: 1,
      isDirectory: () => type === 'directory', isSymbolicLink: () => type === 'symlink', isSocket: () => type === 'socket' };
  }
  for (const directory of ['/', '/home', home, `${home}/app-server-control`, '/private', '/private/tmp', `/private/tmp/codex-daemon-${uid}`])
    table.set(directory, stat('directory', directory === '/private/tmp' ? 0o1777 : 0o700));
  table.set(advertised, stat('symlink', 0o777));
  table.set(target, stat('socket', 0o600));
  let link = target;
  const io = {
    realpathSync(file) { return Buffer.from(file === '/tmp' ? '/private/tmp' : file === '/alias/home' ? home : file); },
    lstatSync(file) { assert.ok(table.has(file), 'only exact expected path is inspected: ' + file); return table.get(file); },
    readlinkSync(file) { assert.equal(file, advertised); return link; },
  };
  return { io, table, stat, setLink(value) { link = value; } };
}
{
  const f = fixture(), binding = inspectCodexSocket('/alias/home', { io: f.io });
  assert.equal(binding.descriptor.advertisedPath, advertised);
  assert.equal(binding.descriptor.targetPath, target);
  assert.ok(Object.isFrozen(binding.descriptor.socket));
  binding.check();
  pass('canonical home and macOS /tmp alias match the pinned native SHA256 layout');
}
for (const [name, mutate] of [
  ['arbitrary alias target', f => f.setLink('/tmp/untrusted.sock')],
  ['relative alias target', f => f.setLink('../elsewhere')],
  ['foreign alias', f => { f.table.get(advertised).uid = uid + 1; }],
  ['regular advertised file', f => f.table.set(advertised, f.stat('file', 0o600))],
  ['foreign ancestor', f => { f.table.get('/home').uid = uid + 1; }],
  ['writable ancestor', f => { f.table.get('/home').mode = 0o777; }],
  ['symlinked control directory', f => f.table.set(`${home}/app-server-control`, f.stat('symlink', 0o777))],
  ['unprotected daemon directory', f => { f.table.get(`/private/tmp/codex-daemon-${uid}`).mode = 0o755; }],
  ['special-bit daemon directory', f => { f.table.get(`/private/tmp/codex-daemon-${uid}`).mode = 0o4700; }],
  ['symlinked daemon directory', f => f.table.set(`/private/tmp/codex-daemon-${uid}`, f.stat('symlink', 0o700))],
  ['foreign socket', f => { f.table.get(target).uid = uid + 1; }],
  ['writable socket', f => { f.table.get(target).mode = 0o666; }],
  ['special-bit socket', f => { f.table.get(target).mode = 0o4600; }],
  ['hard-linked socket', f => { f.table.get(target).nlink = 2; }],
  ['regular physical file', f => f.table.set(target, f.stat('file', 0o600))],
]) {
  const f = fixture(); mutate(f);
  assert.throws(() => inspectCodexSocket(home, { io: f.io }), /unverified/);
  pass('discovery rejects ' + name + ' without repair');
}
for (const entry of [advertised, target, '/home', `${home}/app-server-control`, `/private/tmp/codex-daemon-${uid}`]) {
  const f = fixture(), binding = inspectCodexSocket(home, { io: f.io });
  f.table.get(entry).ino++;
  assert.throws(binding.check, /unverified/);
}
pass('rechecks reject alias, socket and ancestry substitution');
{
  const f = fixture();
  f.table.get(target).ino = 9007199254740992n;
  const binding = inspectCodexSocket(home, { io: f.io });
  assert.equal(binding.descriptor.socket.ino, '9007199254740992');
  f.table.get(target).ino = 9007199254740993n;
  assert.throws(binding.check, /unverified/);
  f.table.get(target).ino = Number(9007199254740993n);
  assert.throws(() => inspectCodexSocket(home, { io: f.io }), /unverified/);
  pass('bigint inode identity detects adjacent replacements above 2^53');
}

{
  const f = fixture(); let reads = 0;
  const old = f.io.readlinkSync;
  f.io.readlinkSync = (...args) => { if (++reads === 2) f.table.get(target).ino++; return old(...args); };
  assert.throws(() => inspectCodexSocket(home, { io: f.io }), /unverified/);
  pass('substitution during discovery fails the second capture');
}
for (const bad of ['relative', '/home/../other', '/home/with\u0000nul']) {
  const f = fixture();
  assert.throws(() => inspectCodexSocket(bad, { io: f.io }), /unverified/);
}
await assert.rejects(connectCodexRpcClient({ codexHome: '/not/probed' }), /unverified/);
pass('invalid home and missing owner evidence fail closed');

if (process.env.CODEX_RPC_TEST_UNIX === '1') {
  // This NEVER creates or opens /tmp/codex-daemon-<uid>. Only an owned disposable
  // synthetic directory/socket is used. Discovery layout is tested above.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-rpc-fixture-'));
  fs.chmodSync(tmp, 0o700);
  const socketPath = path.join(tmp, 'synthetic.sock');
  const journalDir = path.join(tmp, 'journal'); fs.mkdirSync(journalDir, { mode: 0o700 });
  const httpServer = http.createServer();
  const server = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 8192 });
  const requests = [];
  let peer, client;
  const recipient = { threadId: '11111111-1111-4111-8111-111111111111', incarnation: 'fixture-recipient', persistent: true, topLevel: true };
  const endpoint = { serverId: 'fixture-server', endpointId: 'fixture-endpoint', generation: 'fixture-generation', profile: 'codex-native-queue-v1', nativeVersion: '0.162.0', protocolSource: 'rust-v0.162.0', schemaSha256: 'a'.repeat(64), experimentalApi: true, queueApi: true };
  const evidence = { current: () => ({ endpoint, recipient }), bindConnection: () => true, verifyConnection: () => true, subscribeRetirement: () => () => {} };
  httpServer.on('upgrade', (request, socket, head) => {
    assert.equal(request.url, '/rpc'); assert.equal(request.headers.host, 'localhost');
    assert.equal(request.headers['sec-websocket-extensions'], undefined);
    server.handleUpgrade(request, socket, head, ws => {
      peer = ws;
      ws.on('message', bytes => {
        const request = JSON.parse(bytes); requests.push(request);
        if (request.method === 'initialized') return;
        let result;
        if (request.method === 'initialize') result = { userAgent: 'synthetic/0.162.0', codexHome: tmp, platformFamily: 'unix', platformOs: 'linux' };
        else if (request.method === 'thread/read') result = { thread: { id: recipient.threadId, ephemeral: false, source: 'cli', status: { type: 'idle' } } };
        else if (request.method === 'thread/queue/add') result = { queuedSubmission: { id: '22222222-2222-4222-8222-222222222222', input: request.params.input, clientUserMessageId: request.params.clientUserMessageId } };
        else throw new Error('unexpected method');
        ws.send(JSON.stringify({ id: request.id, result }));
      });
    });
  });
  try {
    await new Promise((resolve, reject) => { httpServer.once('error', reject); httpServer.listen(socketPath, resolve); });
    fs.chmodSync(socketPath, 0o600);
    const original = fs.lstatSync(socketPath);
    const boundary = { descriptor: { synthetic: true, targetPath: socketPath }, check() {
      const current = fs.lstatSync(socketPath);
      assert.ok(current.isSocket()); assert.equal(current.ino, original.ino); assert.equal(current.dev, original.dev);
    } };
    let dials = 0;
    client = await openCodexRpcWire({ connect() { dials++; return net.createConnection(socketPath); }, boundary, evidence });
    const transport = createCodexQueueTransport({ client, endpoint, recipient, journalDir });
    assert.equal((await transport.inspect()).compatible, true);
    const attempt = { attemptId: 'unix-synthetic', source: { kind: 'wake', id: 'fixture-source', version: 'b'.repeat(64), uri: 'https://agentboard.example.com/source' }, recipient, bindingEpoch: 1, dispatchGeneration: 1 };
    const accepted = await transport.submit(attempt);
    assert.equal(accepted.outcome, 'accepted');
    client.close(); assert.equal(client.identity(), null);
    assert.equal((await transport.submit(attempt)).historical, true);
    assert.equal(dials, 1); assert.equal(requests.filter(r => r.method === 'thread/queue/add').length, 1);
    assert.deepEqual(requests.map(r => r.method), ['initialize', 'initialized', 'thread/read', 'thread/queue/add']);
    pass('real synthetic AF_UNIX HTTP/WS initialize + queue transport, durable receipt, no resend');
  } finally {
    client?.close(); peer?.terminate();
    await new Promise(resolve => server.close(resolve));
    await new Promise(resolve => httpServer.close(resolve));
    fs.rmSync(tmp, { recursive: true, force: true });
  }
} else {
  console.log('UNRUN - synthetic AF_UNIX dial (set CODEX_RPC_TEST_UNIX=1; hosted/Bazel require it)');
}
console.log(`${groups} socket fixture groups passed`);
