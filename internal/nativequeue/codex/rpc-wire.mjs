// Private connection state machine, also exercised with invented Duplex peers.
// RFC6455 parsing, masking and UTF-8 validation belong to pinned ws, never here.
import WebSocket from 'ws';

const RESPONSE_LIMIT = 262144;
const REQUEST_LIMIT = 8192;
const MAX_PENDING = 8;
const MAX_REQUESTS = 128;
const MAX_NOTIFICATIONS = 128;
const MAX_WIRE_BYTES = 4 * 1024 * 1024;
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const exact = (v, keys) => object(v) && Object.keys(v).sort().join(',') === [...keys].sort().join(',');
const token = v => typeof v === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
const idValid = v => typeof v === 'string' ? token(v) : Number.isSafeInteger(v) && v >= 0;
const failure = () => new Error('Codex RPC connection unverified or retired; effects may be unknown');
function freeze(v) { if (object(v) || Array.isArray(v)) { Object.values(v).forEach(freeze); Object.freeze(v); } return v; }
function snapshot(value, limit = RESPONSE_LIMIT) {
  const text = JSON.stringify(value);
  if (typeof text !== 'string' || Buffer.byteLength(text) > limit) throw failure();
  return freeze(JSON.parse(text));
}
function canonical(v) {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (object(v)) return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  return JSON.stringify(v);
}
function validIdentity(value, advisory = false) {
  const e = value?.endpoint, r = value?.recipient;
  return exact(value, ['endpoint', 'recipient']) &&
    exact(e, ['serverId', 'endpointId', 'generation', 'profile', 'nativeVersion', 'protocolSource', 'schemaSha256', 'experimentalApi', 'queueApi']) &&
    ['serverId', 'endpointId', 'generation'].every(k => token(e[k])) && e.profile === (advisory ? 'codex-durable-advisory-v1' : 'codex-native-queue-v1') &&
    e.nativeVersion === '0.162.0' && e.protocolSource === 'rust-v0.162.0' && /^[0-9a-f]{64}$/.test(e.schemaSha256) &&
    e.experimentalApi === true && e.queueApi === true &&
    uuid(r?.threadId) && r.persistent === true && r.topLevel === true && (advisory
      ? exact(r, ['threadId', 'identityKind', 'enrollmentRevision', 'bindingEpoch', 'persistent', 'topLevel']) &&
        r.identityKind === 'durable-conversation-v1' && [r.enrollmentRevision, r.bindingEpoch].every(n => Number.isSafeInteger(n) && n > 0)
      : exact(r, ['threadId', 'incarnation', 'persistent', 'topLevel']) && token(r.incarnation));
}
export function requireEvidence(evidence) { return checkedEvidence(evidence, false); }
function checkedEvidence(evidence, advisory) {
  try {
    if (!evidence || !['current', 'bindConnection', 'verifyConnection', 'subscribeRetirement'].every(k => typeof evidence[k] === 'function')) throw failure();
    const value = snapshot(evidence.current());
    if (!validIdentity(value, advisory)) throw failure();
    return value;
  } catch { throw failure(); } // Never surface private provider diagnostics.
}
function validRequest(request, threadId) {
  if (!exact(request, ['id', 'method', 'params']) || !idValid(request.id) || request.id === 'initialize') return false;
  const p = request.params;
  if (p?.threadId !== threadId) return false;
  switch (request.method) {
    case 'thread/read': return exact(p, ['threadId', 'includeTurns']) && p.includeTurns === false;
    case 'thread/queue/list': return exact(p, ['threadId', 'cursor', 'limit']) &&
      (p.cursor === null || typeof p.cursor === 'string' && /^(0|[1-9][0-9]{0,9})$/.test(p.cursor)) && Number.isSafeInteger(p.limit) && p.limit >= 1 && p.limit <= 100;
    case 'thread/queue/add': return exact(p, ['threadId', 'input', 'clientUserMessageId']) && uuid(p.clientUserMessageId) &&
      Array.isArray(p.input) && p.input.length === 1 && exact(p.input[0], ['type', 'text', 'text_elements']) &&
      p.input[0].type === 'text' && typeof p.input[0].text === 'string' && Buffer.byteLength(p.input[0].text) <= 4096 &&
      Array.isArray(p.input[0].text_elements) && p.input[0].text_elements.length === 0;
    default: return false;
  }
}
function validInitialization(result) {
  return exact(result, ['userAgent', 'codexHome', 'platformFamily', 'platformOs']) &&
    ['userAgent', 'codexHome', 'platformFamily', 'platformOs'].every(k => typeof result[k] === 'string' &&
      result[k].length > 0 && Buffer.byteLength(result[k]) <= 4096 && !/[\x00-\x1f\x7f]/.test(result[k]));
}

/**
 * Internal seam: connect is one checked stream, never a pool or reconnecter.
 * evidence is a trusted existing runtime owner's lease, not caller wire data.
 * Its verifyConnection must independently bind the peer/lifetime/build/schema
 * and enrolled recipient to this connection. Path/userAgent alone cannot do so.
 * The pre-initialize call (initialize:null) explicitly authorizes native side
 * effects. The strict factory has no production provider. The separate advisory
 * factory is used by the inherited-stream owner bridge with enrollment fencing.
 */
export function openCodexRpcWire(options = {}) { return openWire(options, false); }
// A separate opt-in contract: enrollment epoch is NOT a native thread lifetime.
export function openCodexAdvisoryRpcWire(options = {}) { return openWire(options, true); }
async function openWire({ connect, boundary, evidence, timeoutMs = 5000, lifetimeMs = 30000 } = {}, advisory) {
  if (typeof connect !== 'function' || typeof boundary?.check !== 'function' ||
      !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000 ||
      !Number.isSafeInteger(lifetimeMs) || lifetimeMs < 1 || lifetimeMs > 60000) throw failure();
  const expected = checkedEvidence(evidence, advisory);
  const expectedText = canonical(expected);
  const socketDescriptor = snapshot(boundary.descriptor);
  // A local object-identity fence only. Never substitute it for native generation.
  const connection = Object.freeze({});
  let initialize = null, state = 'connecting', ws, socket, unsubscribe;
  let bytes = 0, notifications = 0, dialed = false;
  let deadline, lifetime, observer;
  const pending = new Map(), used = new Set(['initialize']);
  let resolveReady, rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  // The rejection is always observed even if a synchronous subscription retires.
  ready.catch(() => {});
  function retire() {
    if (state === 'retired') return;
    state = 'retired'; // Identity is gone BEFORE callbacks, promise rejection or I/O.
    clearTimeout(deadline); clearTimeout(lifetime); clearInterval(observer);
    const cleanup = unsubscribe; unsubscribe = undefined;
    try { cleanup?.(); } catch {}
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(failure()); }
    pending.clear();
    rejectReady(failure());
    // Hard close our connection only; no close handshake wait or daemon RPC.
    try { ws?.terminate(); } catch {}
    try { socket?.destroy(); } catch {}
  }
  function current() {
    if (state === 'retired') throw failure();
    try {
      boundary.check();
      if (canonical(checkedEvidence(evidence, advisory)) !== expectedText ||
          evidence.verifyConnection(Object.freeze({ connection, socket: socketDescriptor, initialize })) !== true || state === 'retired') throw failure();
    } catch { retire(); throw failure(); }
  }
  function identity() {
    if (state !== 'ready') return null;
    try { current(); return expected; } catch { return null; }
  }
  function send(value, callback = () => {}) {
    current();
    const text = JSON.stringify(value);
    if (Buffer.byteLength(text) > REQUEST_LIMIT || ws?.readyState !== WebSocket.OPEN || ws.bufferedAmount > REQUEST_LIMIT * MAX_PENDING) throw failure();
    ws.send(text, { binary: false, compress: false }, error => {
      if (error) { retire(); return; }
      if (state === 'retired') return;
      try { current(); callback(); } catch { retire(); }
    });
  }
  function request(value) {
    if (state !== 'ready') return Promise.reject(failure());
    let request;
    try {
      current(); request = snapshot(value, REQUEST_LIMIT);
      if (!validRequest(request, expected.recipient.threadId) || used.has(request.id) || used.size >= MAX_REQUESTS + 1 || pending.size >= MAX_PENDING) throw failure();
      current(); // Snapshot hooks cannot resurrect a synchronously retired client.
    } catch { return Promise.reject(failure()); }
    // Never reuse IDs, including rejected/error responses. Bounded lifetime set.
    used.add(request.id);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(retire, timeoutMs);
      pending.set(request.id, { resolve, reject, timer });
      try { send(request); } catch { retire(); }
    });
  }
  const client = Object.freeze({ identity, request, close: retire });
  try {
    current(); // Includes pre-connect side-effect approval.
    const cleanup = evidence.subscribeRetirement(retire);
    if (typeof cleanup !== 'function') throw failure();
    if (state === 'retired') { cleanup(); throw failure(); }
    unsubscribe = cleanup;
    current();
    deadline = setTimeout(retire, timeoutMs); // Covers connect + HTTP + initialize + initialized flush.
    lifetime = setTimeout(retire, lifetimeMs); // Includes partial frames/idle notification drips.
    observer = setInterval(() => { try { current(); } catch {} }, Math.min(100, timeoutMs));
    ws = new WebSocket('ws://localhost/rpc', {
      createConnection() {
        if (dialed || state === 'retired') throw failure();
        dialed = true;
        current(); socket = connect();
        if (state === 'retired') { socket?.destroy(); throw failure(); }
        if (!socket || typeof socket.on !== 'function' || typeof socket.destroy !== 'function') throw failure();
        socket.on('error', retire);
        socket.on('close', retire);
        socket.prependListener('data', chunk => {
          bytes += chunk.length;
          if (bytes > MAX_WIRE_BYTES) retire();
        });
        return socket;
      },
      maxHeaderSize: 8192,
      handshakeTimeout: timeoutMs,
      followRedirects: false,
      perMessageDeflate: false,
      maxPayload: RESPONSE_LIMIT,
      maxFragments: 128,
      maxBufferedChunks: 128,
      skipUTF8Validation: false,
      autoPong: false,
      closeTimeout: 1,
      allowSynchronousEvents: true,
    });
    ws.on('error', retire);
    ws.on('close', retire);
    ws.on('unexpected-response', (_request, response) => { response.destroy(); retire(); });
    // Control traffic has no application purpose for this bounded client. Never
    // answer a ping or any JSON-RPC request from a shared daemon.
    ws.on('ping', retire); ws.on('pong', retire);
    ws.on('open', () => {
      try {
        current();
        if (evidence.bindConnection(Object.freeze({ connection, stream: socket, socket: socketDescriptor })) !== true) throw failure();
        current(); state = 'initializing';
        send({ id: 'initialize', method: 'initialize', params: {
          clientInfo: { name: 'agentboard_native_queue', version: '0.1.0' },
          capabilities: { experimentalApi: true },
        } });
      } catch { retire(); }
    });
    ws.on('message', (data, binary) => {
      if (state === 'retired') return;
      try {
        current();
        if (binary || !Buffer.isBuffer(data) || data.length > RESPONSE_LIMIT) throw failure();
        const message = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(data));
        if (!object(message) || Object.hasOwn(message, 'jsonrpc') && message.jsonrpc !== '2.0') throw failure();
        if (Object.hasOwn(message, 'method')) {
          // Server requests, including approvals/auth, get NO response or error.
          if (Object.hasOwn(message, 'id') || !Object.keys(message).every(k => ['method', 'params', 'jsonrpc', 'emittedAtMs'].includes(k)) ||
              typeof message.method !== 'string' || message.method.length === 0 || message.method.length > 256 ||
              Object.hasOwn(message, 'emittedAtMs') && !Number.isSafeInteger(message.emittedAtMs) || ++notifications > MAX_NOTIFICATIONS) throw failure();
          return; // Discard bounded notifications; never enqueue or execute them.
        }
        if (!Object.hasOwn(message, 'id') || !idValid(message.id) || !Object.keys(message).every(k => ['id', 'result', 'error', 'jsonrpc'].includes(k)) ||
            Object.hasOwn(message, 'result') === Object.hasOwn(message, 'error')) throw failure();
        if (Object.hasOwn(message, 'error') && (!object(message.error) || !Number.isSafeInteger(message.error.code) || typeof message.error.message !== 'string')) throw failure();
        if (state === 'initializing') {
          if (message.id !== 'initialize' || !validInitialization(message.result)) throw failure();
          initialize = snapshot(message.result);
          current(); // Owner must now bind the actual initialized connection.
          state = 'initializing-notification';
          send({ method: 'initialized' }, () => {
            if (state !== 'initializing-notification') throw failure();
            current(); clearTimeout(deadline); state = 'ready'; resolveReady(client);
          });
          return;
        }
        if (state !== 'ready') throw failure();
        const entry = pending.get(message.id);
        if (!entry) throw failure();
        current();
        pending.delete(message.id); clearTimeout(entry.timer);
        entry.resolve(freeze(message)); // Preserve raw correlated result/error envelope.
      } catch { retire(); }
    });
  } catch { retire(); }
  return ready;
}
