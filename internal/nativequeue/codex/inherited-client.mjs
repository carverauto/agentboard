// Explicit durable-conversation profile. No discovery, dial, credentials or daemon lifecycle.
// FD 3 is the EXACT socket verified by the trusted Go owner. FD 4/5 are private
// anonymous owner control pipes; metadata from an arbitrary file is not accepted.
import fs from 'node:fs';
import net from 'node:net';
import { performance } from 'node:perf_hooks';
import { openCodexAdvisoryRpcWire } from './rpc-wire.mjs';
import { validateOwnerResponse } from './owner-control.mjs';

const fail = () => new Error('Inherited native owner unavailable or retired; effects may be unknown');
const token = v => typeof v === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const positive = v => Number.isSafeInteger(v) && v > 0;
function frozen(v) { if (v && typeof v === 'object') { Object.values(v).forEach(frozen); Object.freeze(v); } return v; }
function stamp(fd) {
  const s = fs.fstatSync(fd, { bigint: true });
  if (!s.isSocket()) throw fail();
  return { dev: String(s.dev), ino: String(s.ino) };
}

/**
 * Call only in a trusted child created by owner.Owner.Start. The caller pins the
 * approval ID and server authority revision independently of received pipe data.
 * Peer/build proof belongs to the Go owner; schema approval/enrollment belongs to
 * its caller. This module never claims native loaded-thread incarnation proof.
 * The strict connectCodexRpcClient API continues rejecting this identity profile.
 */
export async function connectInheritedCodexAdvisory({ approvalId, authorityRevision, timeoutMs = 5000, lifetimeMs = 30000 } = {}) {
  if (!token(approvalId) || !positive(authorityRevision) ||
      !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000 ||
      !Number.isSafeInteger(lifetimeMs) || lifetimeMs < 1 || lifetimeMs > 30000) throw fail();
  let stream, control, timer, heartbeat, initialTimer, retired = false, client;
  let retirementReason = null, retiredAt = null;
  let sequence = 0, pending = null, snapshot = null, fingerprint = null, deadline = 0, buffered = Buffer.alloc(0), total = 0;
  const callbacks = new Set();
  let resolveInitial, rejectInitial;
  const initial = new Promise((resolve, reject) => { resolveInitial = resolve; rejectInitial = reject; });
  initial.catch(() => {});
  function retire(reason = 'closed') {
    if (retired) return;
    retirementReason = reason; retiredAt = performance.now();
    retired = true; snapshot = null; deadline = 0;
    clearTimeout(timer); clearTimeout(initialTimer); clearInterval(heartbeat);
    // Invalidate identity before rejecting pending native operations.
    for (const callback of [...callbacks]) { try { callback(); } catch {} }
    callbacks.clear(); rejectInitial(fail());
    try { control?.destroy(); } catch {}
    try { stream?.destroy(); } catch {}
    for (const fd of stream ? [5] : control ? [3, 5] : [3, 4, 5]) { try { fs.closeSync(fd); } catch {} }
  }
  function alive() {
    if (retired) return false;
    if (!snapshot || performance.now() >= deadline) { retire('lease_expired'); return false; }
    try {
      const actual = stamp(3);
      if (actual.dev !== snapshot.socket.dev || actual.ino !== snapshot.socket.ino) throw fail();
    } catch { retire('socket_changed'); return false; }
    return true;
  }
  function challenge() {
    if (retired || pending) return;
    if (++sequence > 1024) { retire('challenge_limit'); return; }
    pending = { sequence, started: performance.now() };
    try { fs.writeSync(5, JSON.stringify({ type: 'attest', challenge: sequence }) + '\n'); }
    catch { retire('control_write_failed'); }
  }
  try {
    stamp(3);
    for (const fd of [4, 5]) if (!fs.fstatSync(fd).isFIFO()) throw fail();
    control = fs.createReadStream(null, { fd: 4, autoClose: true, highWaterMark: 4096 });
    control.on('error', () => retire('control_error')); control.on('end', () => retire('control_eof')); control.on('close', () => retire('control_closed'));
    control.on('data', chunk => {
      if (retired) return;
      try {
        total += chunk.length;
        if (total > 1 << 20 || buffered.length + chunk.length > 16384) throw fail();
        buffered = Buffer.concat([buffered, chunk]);
        for (;;) {
          const end = buffered.indexOf(10);
          if (end < 0) break;
          if (end > 8192 || !pending) throw fail();
          const accepted = validateOwnerResponse(buffered.subarray(0, end), {
            pending, approvalId, authorityRevision, fingerprint, previousDeadline: deadline, now: performance.now(),
          });
          buffered = buffered.subarray(end + 1);
          pending = null; fingerprint = accepted.fingerprint;
          snapshot = accepted.snapshot; deadline = accepted.deadline;
          clearTimeout(timer); timer = setTimeout(() => retire('lease_expired'), Math.max(1, deadline - performance.now()));
          if (!alive()) throw fail();
          resolveInitial();
        }
        if (buffered.length > 8192) throw fail();
      } catch { retire(deadline && performance.now() >= deadline ? 'lease_expired' : 'control_response_rejected'); }
    });
    initialTimer = setTimeout(() => retire('initial_timeout'), Math.min(timeoutMs, 1000));
    challenge(); await initial; clearTimeout(initialTimer);
    // Construct only the inherited native socket. No net.createConnection exists.
    stream = new net.Socket({ fd: 3, readable: true, writable: true });
    const descriptor = frozen({ inherited: true, socket: snapshot.socket, approvalId, authorityRevision });
    const evidence = {
      current() { return alive() ? snapshot.identity : null; },
      bindConnection({ stream: actual }) { return actual === stream && alive(); },
      verifyConnection() { return alive(); },
      subscribeRetirement(callback) {
        if (retired) callback(); else callbacks.add(callback);
        return () => callbacks.delete(callback);
      },
    };
    const boundary = { descriptor, check() { if (!alive()) throw fail(); } };
    heartbeat = setInterval(challenge, 50);
    let used = false;
    client = await openCodexAdvisoryRpcWire({ evidence, boundary, timeoutMs, lifetimeMs,
      connect() { if (used || !alive()) throw fail(); used = true; return stream; } });
    stream.once('close', () => retire('native_closed'));
    // Prove the approved durable target actually exists on THIS connection.
    // This metadata check is not an atomic loaded-session generation fence.
    const recipient = snapshot.identity.recipient;
    const reply = await client.request({ id: 'advisory-recipient', method: 'thread/read', params: { threadId: recipient.threadId, includeTurns: false } });
    const thread = reply.result?.thread;
    if (reply.error || thread?.id !== recipient.threadId || thread.ephemeral !== false || !['cli', 'vscode', 'exec', 'appServer'].includes(thread.source)) throw fail();
    return Object.freeze({ identity: client.identity, request: client.request,
      // Bounded local diagnostics only: no descriptor, peer data, source or credentials.
      diagnostics() { return Object.freeze({ retired, retirementReason, sequence, pendingSequence: pending?.sequence ?? null,
        leaseRemainingMs: retired ? 0 : Math.max(0, Math.ceil(deadline - performance.now())),
        retiredAgoMs: retiredAt === null ? null : Math.max(0, Math.floor(performance.now() - retiredAt)) }); },
      close() { retire(); client.close(); } });
  } catch { retire('initialization_failed'); throw fail(); }
}
