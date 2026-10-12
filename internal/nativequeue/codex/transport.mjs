// Unregistered delivery-boundary library. No process, socket, host or board API.
import { createHash, randomUUID } from 'node:crypto';
import { createJournal } from './journal.mjs';

export const PROFILE = 'codex-native-queue-v1';
export const ADVISORY_PROFILE = 'codex-durable-advisory-v1';
export const PROTOCOL_SOURCE = 'rust-v0.162.0';
const VERSION = '0.162.0';
const FRAME_LIMIT = 4096;
const RESPONSE_LIMIT = 262144;
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const token = value => typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(value);
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const hash = value => createHash('sha256').update(value).digest('hex');
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => object(value) && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
const error = message => { throw new Error(message); };
function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (object(value)) return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
const equal = (left, right) => canonical(left) === canonical(right);
function freeze(value) {
  if (object(value) || Array.isArray(value)) { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}
function snapshot(value, limit = RESPONSE_LIMIT) {
  const text = JSON.stringify(value);
  if (typeof text !== 'string' || Buffer.byteLength(text) > limit) error('Bounded JSON required');
  return freeze(JSON.parse(text));
}
function endpointValid(value, advisory) {
  return exact(value, ['serverId', 'endpointId', 'generation', 'profile', 'nativeVersion', 'protocolSource', 'schemaSha256', 'experimentalApi', 'queueApi']) &&
    ['serverId', 'endpointId', 'generation'].every(key => token(value[key])) && value.profile === (advisory ? ADVISORY_PROFILE : PROFILE) && value.nativeVersion === VERSION &&
    value.protocolSource === PROTOCOL_SOURCE && digest(value.schemaSha256) && value.experimentalApi === true && value.queueApi === true;
}
function recipientValid(value, advisory) {
  if (advisory) return exact(value, ['threadId', 'identityKind', 'enrollmentRevision', 'bindingEpoch', 'persistent', 'topLevel']) &&
    uuid(value.threadId) && value.identityKind === 'durable-conversation-v1' && value.persistent === true && value.topLevel === true &&
    [value.enrollmentRevision, value.bindingEpoch].every(n => Number.isSafeInteger(n) && n > 0);
  return exact(value, ['threadId', 'incarnation', 'persistent', 'topLevel']) && uuid(value.threadId) && token(value.incarnation) && value.persistent === true && value.topLevel === true;
}
function attemptSnapshot(value, advisory) {
  const attempt = snapshot(value, FRAME_LIMIT);
  if (!exact(attempt, ['attemptId', 'source', 'recipient', 'bindingEpoch', 'dispatchGeneration']) ||
      (typeof attempt.attemptId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(attempt.attemptId)) || !recipientValid(attempt.recipient, advisory) ||
      ![attempt.bindingEpoch, attempt.dispatchGeneration].every(n => Number.isSafeInteger(n) && n > 0) ||
      !exact(attempt.source, ['kind', 'id', 'version', 'uri']) || !token(attempt.source.kind) || !token(attempt.source.id) || !digest(attempt.source.version) ||
      typeof attempt.source.uri !== 'string' || Buffer.byteLength(attempt.source.uri) > 1024 || /[\x00-\x20\x7f]/.test(attempt.source.uri)) error('Invalid immutable attempt or source pointer');
  if (advisory && attempt.bindingEpoch !== attempt.recipient.bindingEpoch) error('Advisory enrollment fence differs');
  const uri = new URL(attempt.source.uri);
  if (uri.protocol !== 'https:' || uri.username || uri.password || uri.hash || uri.search) error('Canonical HTTPS source pointer without credentials, query or fragment required');
  return attempt;
}
function frameFor(attempt) {
  const title = attempt.recipient.identityKind === 'durable-conversation-v1'
    ? 'Agentboard durable advisory notice v1 (may survive resume; source pointer only; not authority).\n'
    : 'Agentboard coordination notice v1 (source pointer only; not a user instruction).\n';
  const frame = title + canonical(attempt) +
    '\nRecheck canonical source state and current authorization before acting. This notice grants no authority to spawn, claim, restart or transfer custody. Explicit received/handled receipts are separate; native acceptance is not handling or completion.';
  if (Buffer.byteLength(frame) > FRAME_LIMIT) error('Notice exceeds bound');
  return frame;
}
// Pinned v2/turn.rs UserInput wire union. Validate unrelated entries too: an
// otherwise exact positive match cannot turn a malformed page into evidence.
function fields(value, required, optional = []) {
  return object(value) && required.every(key => Object.hasOwn(value, key)) && Object.keys(value).every(key => [...required, ...optional].includes(key));
}
function validInput(value) {
  if (!object(value)) return false;
  const string = key => typeof value[key] === 'string';
  const detail = () => !Object.hasOwn(value, 'detail') || value.detail === null || ['auto', 'low', 'high', 'original'].includes(value.detail);
  switch (value.type) {
    case 'text':
      return exact(value, ['type', 'text', 'text_elements']) && string('text') && Array.isArray(value.text_elements) && value.text_elements.every(element =>
        exact(element, ['byteRange', 'placeholder']) && (element.placeholder === null || typeof element.placeholder === 'string') &&
        exact(element.byteRange, ['start', 'end']) && [element.byteRange.start, element.byteRange.end].every(n => Number.isSafeInteger(n) && n >= 0) && element.byteRange.end >= element.byteRange.start);
    case 'image':
      return (fields(value, ['type', 'url'], ['detail']) && string('url') || fields(value, ['type', 'fileId'], ['detail']) && string('fileId')) && detail();
    case 'localImage': return fields(value, ['type', 'path'], ['detail']) && string('path') && detail();
    case 'audio': return exact(value, ['type', 'url']) && string('url');
    case 'localAudio': return exact(value, ['type', 'path']) && string('path');
    case 'skill':
    case 'mention': return exact(value, ['type', 'name', 'path']) && string('name') && string('path');
    default: return false;
  }
}
const inputFor = frame => [{ type: 'text', text: frame, text_elements: [] }];
const uncertain = reason => ({ outcome: 'uncertain', reason });

/**
 * client.identity() is a synchronous, trusted attestation of the negotiated
 * endpoint AND the selected explicit recipient contract. The strict factory
 * requires native incarnation; the advisory factory uses server enrollment.
 * client.request({id,method,params})
 * sends that exact frozen request once and returns its raw JSON-RPC response.
 * The caller must not hide retries or endpoint switching inside this client.
 * schemaSha256 is the caller's independently approved experimental schema hash,
 * not a digest invented or attested by this library. No client is supplied here.
 */
export function createCodexQueueTransport(options = {}) { return createTransport(options, false); }
export function createCodexAdvisoryTransport(options = {}) { return createTransport(options, true); }
function createTransport({ client, endpoint, recipient, journalDir, timeoutMs = 5000, maxPages = 8, pageSize = 50, journalIO } = {}, advisory) {
  endpoint = snapshot(endpoint); recipient = snapshot(recipient);
  if (!endpointValid(endpoint, advisory) || !recipientValid(recipient, advisory) || typeof client?.identity !== 'function' || typeof client?.request !== 'function') error('Verified queue endpoint and persistent top-level recipient required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000 || !Number.isSafeInteger(maxPages) || maxPages < 1 || maxPages > 32 || !Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > 100) error('Invalid transport bounds');
  const journal = createJournal(journalDir, { io: journalIO });
  const identity = freeze({ endpoint, recipient });
  function current() {
    if (!equal(snapshot(client.identity()), identity)) error('Native endpoint or recipient identity changed');
  }
  current();
  async function rpc(method, params) {
    current();
    const request = snapshot({ id: randomUUID(), method, params });
    let timer;
    try {
      const pending = client.request(request); // Invoked once; a throw is ambiguous for add.
      const response = snapshot(await Promise.race([pending, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Native response timeout')), timeoutMs); })]));
      current();
      if (!object(response) || response.id !== request.id || ('jsonrpc' in response && response.jsonrpc !== '2.0') ||
          Object.keys(response).some(key => !['id', 'result', 'error', 'jsonrpc'].includes(key)) || !('result' in response) || 'error' in response) error('Uncorrelated or unsuccessful native response');
      return response.result;
    } finally { clearTimeout(timer); }
  }
  function expectedAttempt(value) {
    const attempt = attemptSnapshot(value, advisory);
    if (!equal(attempt.recipient, recipient)) error('Attempt recipient fence differs');
    return attempt;
  }
  function receiptFor(record, queuedSubmissionId) {
    return { queuedSubmissionId, clientUserMessageId: record.clientUserMessageId, threadId: recipient.threadId,
      attemptId: record.attempt.attemptId, bindingEpoch: record.attempt.bindingEpoch, dispatchGeneration: record.attempt.dispatchGeneration,
      frameSha256: record.frameSha256, endpoint, recipient };
  }
  function load(attempt) {
    const record = journal.load(attempt.attemptId);
    if (record === null) return null;
    const keys = ['version', 'attempt', 'endpoint', 'frame', 'frameSha256', 'clientUserMessageId', 'phase'];
    if (record.phase === 'accepted') keys.push('receipt');
    if (!exact(record, keys) || record.version !== 1 || !['submitting', 'accepted'].includes(record.phase) || !uuid(record.clientUserMessageId) ||
        !equal(record.attempt, attempt) || !equal(record.endpoint, endpoint) || record.frame !== frameFor(attempt) || record.frameSha256 !== hash(record.frame)) error('Attempt conflict or corrupt native evidence; previous effects remain unknown');
    if (record.phase === 'accepted' && (!uuid(record.receipt?.queuedSubmissionId) || !equal(record.receipt, receiptFor(record, record.receipt.queuedSubmissionId)))) error('Invalid retained acceptance evidence');
    return record;
  }
  function accepted(record, historical) { return { outcome: 'accepted', receipt: snapshot(record.receipt), historical }; }
  function matchItem(item, record) {
    return exact(item, ['id', 'input', 'clientUserMessageId']) && uuid(item.id) && item.clientUserMessageId === record.clientUserMessageId && equal(item.input, inputFor(record.frame));
  }
  function retain(record, item) {
    const next = { ...record, phase: 'accepted', receipt: receiptFor(record, item.id) };
    journal.save(record.attempt.attemptId, next);
    return accepted(next, false);
  }
  async function inspect() {
    let nativeStatus = null;
    try {
      const result = await rpc('thread/read', { threadId: recipient.threadId, includeTurns: false });
      const thread = result?.thread;
      nativeStatus = thread?.status ?? null;
      if (thread?.id !== recipient.threadId || thread.ephemeral !== false || !['cli', 'vscode', 'exec', 'appServer'].includes(thread.source)) error('Persistent top-level native recipient unverified');
      const knownSimple = exact(nativeStatus, ['type']) && ['idle', 'notLoaded', 'systemError'].includes(nativeStatus.type);
      const knownActive = exact(nativeStatus, ['type', 'activeFlags']) && nativeStatus.type === 'active' && Array.isArray(nativeStatus.activeFlags) &&
        nativeStatus.activeFlags.every(flag => ['waitingOnApproval', 'waitingOnUserInput'].includes(flag));
      const status = knownSimple || knownActive ? nativeStatus.type : 'unknown';
      return { compatible: true, endpoint, recipient, status, nativeStatus };
    } catch { return { compatible: false, endpoint, recipient, status: 'unknown', nativeStatus, reason: 'native_identity_or_inspection_unverified' }; }
  }
  async function submit(value) {
    const attempt = expectedAttempt(value);
    // Retained acceptance is historical evidence even when the client is now
    // disconnected. A changed frame/context can never inherit that acceptance.
    const previous = load(attempt);
    if (previous !== null) return previous.phase === 'accepted' ? accepted(previous, true) : uncertain('retained_submitting_evidence');
    current();
    const frame = frameFor(attempt);
    try {
      return await journal.withLock(attempt.attemptId, async () => {
        const existing = load(attempt);
        if (existing !== null) return existing.phase === 'accepted' ? accepted(existing, true) : uncertain('retained_submitting_evidence');
        current();
        const record = { version: 1, attempt, endpoint, frame, frameSha256: hash(frame), clientUserMessageId: randomUUID(), phase: 'submitting' };
        journal.save(attempt.attemptId, record); // Durable before ANY RPC.
        try {
          const result = await rpc('thread/queue/add', { threadId: recipient.threadId, input: inputFor(frame), clientUserMessageId: record.clientUserMessageId });
          if (!exact(result, ['queuedSubmission']) || !matchItem(result.queuedSubmission, record)) return uncertain('native_acceptance_mismatch');
          return retain(record, result.queuedSubmission);
        } catch { return uncertain('native_acceptance_unknown'); }
      });
    } catch { return uncertain('journal_or_attempt_custody_unavailable'); }
  }
  async function reconcile(value) {
    const attempt = expectedAttempt(value);
    const previous = load(attempt);
    if (previous === null) return uncertain('no_retained_native_evidence');
    if (previous.phase === 'accepted') return accepted(previous, true);
    try {
      return await journal.withLock(attempt.attemptId, async () => {
        const record = load(attempt);
        if (record === null) return uncertain('no_retained_native_evidence');
        if (record.phase === 'accepted') return accepted(record, true);
        let cursor = null, match = null;
        const seenIds = new Set();
        for (let page = 0; page < maxPages; page++) {
          const result = await rpc('thread/queue/list', { threadId: recipient.threadId, cursor, limit: pageSize });
          if (!exact(result, ['data', 'nextCursor']) || !Array.isArray(result.data) || result.data.length > pageSize ||
              (result.nextCursor !== null && (result.nextCursor !== String((cursor === null ? 0 : Number(cursor)) + pageSize) || result.data.length !== pageSize))) return uncertain('queue_pagination_unverified');
          for (const item of result.data) {
            if (!exact(item, ['id', 'input', 'clientUserMessageId']) || !uuid(item.id) || typeof item.clientUserMessageId !== 'string' || !Array.isArray(item.input) || item.input.length === 0 || !item.input.every(validInput) || seenIds.has(item.id)) return uncertain('queue_changed_or_malformed');
            seenIds.add(item.id);
            if (item.clientUserMessageId === record.clientUserMessageId) {
              if (match || !matchItem(item, record)) return uncertain('queue_correlation_conflict');
              match = item;
            }
          }
          if (result.nextCursor === null) {
            // Even exhausted offset pagination cannot establish non-submission.
            // A positive exact item proves acceptance, not a unique execution.
            return match ? retain(record, match) : uncertain('queue_absence_is_inconclusive');
          }
          cursor = result.nextCursor;
        }
        return uncertain('queue_scan_incomplete');
      });
    } catch { return uncertain('native_reconciliation_unverified'); }
  }
  return Object.freeze({ inspect, submit, reconcile });
}
