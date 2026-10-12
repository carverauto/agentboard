// Pure validation of an OWNER pipe response, not proof that its sender is trusted.
// The inherited client alone supplies the private pipes and actual FD stamp.
const exact = (v, keys) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).sort().join(',') === [...keys].sort().join(',');
const positive = v => Number.isSafeInteger(v) && v > 0;
const decimal = v => typeof v === 'string' && /^(0|[1-9][0-9]{0,30})$/.test(v);
const fail = () => { throw new Error('Owner control response unavailable or retired'); };
function freeze(v) { if (v && typeof v === 'object') { Object.values(v).forEach(freeze); Object.freeze(v); } return v; }
export function validateOwnerResponse(bytes, { pending, approvalId, authorityRevision, fingerprint, previousDeadline, now }) {
  if (!Buffer.isBuffer(bytes) || bytes.length > 8192 || !pending || !Number.isFinite(now) || !Number.isFinite(pending.started) ||
      now < pending.started || (fingerprint !== null && now >= previousDeadline)) fail();
  const message = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!exact(message, ['type', 'challenge', 'validForMs', 'approvalId', 'authorityRevision', 'identity', 'socket']) ||
      message.type !== 'attestation' || message.challenge !== pending.sequence || message.approvalId !== approvalId || message.authorityRevision !== authorityRevision ||
      !positive(message.validForMs) || message.validForMs > 250 || !exact(message.socket, ['dev', 'ino']) || !decimal(message.socket.dev) || !decimal(message.socket.ino)) fail();
  const nextFingerprint = JSON.stringify([message.identity, message.socket]);
  if (fingerprint !== null && fingerprint !== nextFingerprint) fail();
  // Transit/processing time reduces validity. Receiving a reply never restarts it.
  const deadline = pending.started + message.validForMs;
  if (now >= deadline) fail();
  return Object.freeze({ snapshot: freeze(message), fingerprint: nextFingerprint, deadline });
}
