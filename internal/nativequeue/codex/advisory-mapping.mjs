// Pure, unregistered mapping from an authenticated frozen wake reservation.
// A notice is not authority. Only the existing authenticated server resolver
// decides whether its exact callback is current; no source lookup occurs here.
export const ADVISORY_TITLE = 'Agentboard durable advisory notice v1 (may survive resume; source pointer only; not authority).\n';
export const NOTICE_SUFFIX = '\nRecheck canonical source state and current authorization before acting. This notice grants no authority to spawn, claim, restart or transfer custody. Explicit received/handled receipts are separate; native acceptance is not handling or completion.';
const LIMIT = 4096;
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const exact = (v, keys) => object(v) && Object.keys(v).sort().join(',') === [...keys].sort().join(',');
const uuid = v => typeof v === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(v);
const digest = v => typeof v === 'string' && /^[a-f0-9]{64}$/.test(v);
const integer = v => Number.isSafeInteger(v) && v > 0;
const text = v => typeof v === 'string' && v.isWellFormed() && v.length > 0 && Buffer.byteLength(v) <= 240 && !/[\x00-\x1f\x7f]/.test(v) && v.trim() !== '';
const fail = () => { throw new Error('Exact frozen wake callback and approved durable recipient required'); };
export function canonicalNotice(value) {
  if (Array.isArray(value)) return '[' + value.map(canonicalNotice).join(',') + ']';
  if (object(value)) return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonicalNotice(value[k])).join(',') + '}';
  return JSON.stringify(value);
}
function frozen(value) {
  if (object(value) || Array.isArray(value)) { Object.values(value).forEach(frozen); Object.freeze(value); }
  return value;
}
function copy(value) {
  const raw = JSON.stringify(value);
  if (typeof raw !== 'string' || Buffer.byteLength(raw) > LIMIT) fail();
  return frozen(JSON.parse(raw));
}
const same = (a, b) => canonicalNotice(a) === canonicalNotice(b);
function callbackValid(c) {
  const r = c?.recipient;
  return exact(c, ['attempt_id', 'intent_id', 'reason_hash', 'payload_hash', 'recipient']) &&
    uuid(c.attempt_id) && uuid(c.intent_id) && digest(c.reason_hash) && digest(c.payload_hash) &&
    exact(r, ['agent_id', 'host_id', 'repo', 'enrollment_revision', 'binding_epoch', 'session_id', 'adapter_generation']) &&
    ['agent_id', 'host_id', 'session_id', 'adapter_generation'].every(k => text(r[k])) &&
    typeof r.repo === 'string' && /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/.test(r.repo) &&
    integer(r.enrollment_revision) && integer(r.binding_epoch);
}
function recipientValid(r) {
  return exact(r, ['threadId', 'identityKind', 'enrollmentRevision', 'bindingEpoch', 'persistent', 'topLevel']) &&
    uuid(r.threadId) && r.identityKind === 'durable-conversation-v1' && integer(r.enrollmentRevision) &&
    integer(r.bindingEpoch) && r.persistent === true && r.topLevel === true;
}
function resolverURI(origin, r) {
  let u;
  try { u = new URL(origin); } catch { fail(); }
  if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash || u.pathname !== '/' || u.origin !== origin) fail();
  return origin + '/api/v1/hosts/' + encodeURIComponent(r.host_id) + '/wake-intents/' + encodeURIComponent(r.agent_id) + '/resolve';
}
function approved(c, manifest) {
  if (!object(manifest) || !recipientValid(manifest.recipient) || manifest.manifest_version !== 1 ||
      manifest.endpoint?.profile !== 'codex-durable-advisory-v1' || manifest.initialize_approved !== true) fail();
  const r = c.recipient;
  if (r.agent_id !== manifest.worker_id || r.host_id !== manifest.host_id ||
      r.enrollment_revision !== manifest.enrollment_revision || r.binding_epoch !== manifest.binding_epoch ||
      r.session_id !== manifest.session_id || r.adapter_generation !== manifest.pane_id ||
      r.enrollment_revision !== manifest.recipient.enrollmentRevision || r.binding_epoch !== manifest.recipient.bindingEpoch) fail();
}

// Called by the transport too. Mapped attempts cannot retain a different
// callback under an otherwise identical native attempt ID or payload pointer.
export function validateMappedWakeAttempt(value) {
  if (!exact(value, ['attemptId', 'source', 'recipient', 'bindingEpoch', 'dispatchGeneration', 'wakeCallback']) ||
      !callbackValid(value.wakeCallback) || !recipientValid(value.recipient) || !integer(value.dispatchGeneration) ||
      value.attemptId !== value.wakeCallback.attempt_id || value.bindingEpoch !== value.wakeCallback.recipient.binding_epoch ||
      value.bindingEpoch !== value.recipient.bindingEpoch ||
      value.recipient.enrollmentRevision !== value.wakeCallback.recipient.enrollment_revision ||
      !exact(value.source, ['kind', 'id', 'version', 'uri']) || value.source.kind !== 'agentboard_wake_attempt' ||
      value.source.id !== value.attemptId || value.source.version !== value.wakeCallback.payload_hash) fail();
  let u;
  try { u = new URL(value.source.uri); } catch { fail(); }
  if (value.source.uri !== resolverURI(u.origin, value.wakeCallback.recipient)) fail();
  return value;
}

/** Map the actual public reservation and cooperation batch returned together
 * by wake_reserve. manifest is the independently approved immutable manifest,
 * not the latest mutable worker binding. Source versions are not converted
 * into digests: the pointer version is the frozen reservation payload hash.
 */
export function createWakeAdvisory({ reservation, batch, manifest, serverOrigin } = {}) {
  if (!object(reservation) || reservation.protocol_revision !== 1 || reservation.effect !== 'wake.nudge' || !object(batch)) fail();
  const callback = copy({ attempt_id: reservation.attempt_id, intent_id: reservation.intent_id,
    reason_hash: reservation.reason_hash, payload_hash: reservation.payload_hash, recipient: reservation.recipient });
  if (!callbackValid(callback)) fail();
  approved(callback, manifest);
  if (batch.attempt_id !== callback.attempt_id || batch.worker_id !== callback.recipient.agent_id ||
      batch.binding_epoch !== callback.recipient.binding_epoch || !integer(batch.dispatch_generation)) fail();
  const result = copy({ attemptId: callback.attempt_id,
    source: { kind: 'agentboard_wake_attempt', id: callback.attempt_id, version: callback.payload_hash,
      uri: resolverURI(serverOrigin, callback.recipient) },
    recipient: manifest.recipient, bindingEpoch: callback.recipient.binding_epoch,
    dispatchGeneration: batch.dispatch_generation, wakeCallback: callback });
  validateMappedWakeAttempt(result);
  if (Buffer.byteLength(ADVISORY_TITLE + canonicalNotice(result) + NOTICE_SUFFIX) > LIMIT) fail();
  return result;
}

/** The receiving tool supplies its trusted origin and retained approved
 * descriptor, extracts the unchanged callback, and passes it to wake-resolve
 * using the existing receipt capability. Never fetch an arbitrary notice URL.
 * Success here proves shape/binding only, not current work authorization.
 */
export function extractWakeCallback(attempt, { manifest, serverOrigin } = {}) {
  const value = copy(attempt);
  validateMappedWakeAttempt(value);
  approved(value.wakeCallback, manifest);
  if (!same(value.recipient, manifest.recipient) || value.source.uri !== resolverURI(serverOrigin, value.wakeCallback.recipient)) fail();
  return value.wakeCallback;
}

export function parseWakeAdvisoryFrame(frame, options) {
  if (typeof frame !== 'string' || Buffer.byteLength(frame) > LIMIT || !frame.startsWith(ADVISORY_TITLE) || !frame.endsWith(NOTICE_SUFFIX)) fail();
  const raw = frame.slice(ADVISORY_TITLE.length, -NOTICE_SUFFIX.length);
  let value;
  try { value = JSON.parse(raw); } catch { fail(); }
  // Exact canonical encoding also refuses duplicate keys, concatenated JSON,
  // non-finite/rounded numbers and altered framing in an untrusted notice.
  if (canonicalNotice(value) !== raw) fail();
  return extractWakeCallback(value, options);
}
