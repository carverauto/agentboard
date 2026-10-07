// Claude Code 2.1.289 native mods API. Opt-in plugin loading; no settings edits.
// The MCP child owns transport, never a detached shell or a model watcher.
let owner;
let lifecycle = 0;
let eligible = false;
let eligibleSession;

async function request($, route, body) {
  const socket = await $.env.get('AGENTBOARD_CLAUDE_SOCKET');
  if (!socket) return;
  const response = await $.http.fetch('http://agentboard-native/' + route, {
    socketPath: socket + '.hooks', method: 'POST', body: JSON.stringify(body),
    headers: { 'Content-Type': 'application/json' },
  });
  if (!response.ok) throw new Error('Agentboard native boundary unavailable');
  return JSON.parse(response.text);
}

async function headless($, revision) {
  try {
    const surfaces = await $.session.surfaces();
    if (revision !== lifecycle) return false;
    return Array.isArray(surfaces) && surfaces.length === 0;
  } catch {
    return false;
  }
}

async function bind($) {
  const revision = lifecycle;
  const session = await $.session.id();
  if (revision !== lifecycle) return;
  if (owner?.session_id === session) return owner;
  // No inherited generation. Resume/fork/reload always requires explicit API bind.
  const identity = await request($, 'bind', { session_id: session });
  let adopted = false;
  try {
    if (identity && revision === lifecycle && await $.session.id() === session && revision === lifecycle) {
      owner = identity;
      adopted = true;
    }
  } finally {
    if (identity && !adopted) await request($, 'retire', identity).catch(() => undefined);
  }
  return revision === lifecycle && owner?.session_id === session ? owner : undefined;
}

async function refuse($, current, revision = lifecycle) {
  if (revision !== lifecycle) return;
  lifecycle += 1;
  owner = undefined;
  eligible = false;
  eligibleSession = undefined;
  try { if (current) await request($, 'retire', current); } catch { /* inert */ }
}

async function invalidate($, current, revision = lifecycle) {
  if (revision !== lifecycle) return;
  lifecycle += 1;
  eligible = false;
  eligibleSession = undefined;
  if (!current || owner === current) owner = current;
  try { if (current) await request($, 'invalidate', current); } catch { /* inert */ }
}

export function register(on) {
  on('session.start', async ($, event, next) => {
    const retired = owner;
    lifecycle += 1;
    const revision = lifecycle;
    owner = undefined;
    eligible = false;
    eligibleSession = undefined;
    try { if (retired) await request($, 'retire', retired); } catch { /* inert */ }
    try {
      const session = await $.session.id();
      if (revision !== lifecycle) return next(event);
      if (event?.isInteractive !== false || !(await headless($, revision))) return next(event);
      if (revision !== lifecycle) return next(event);
      const fresh = await bind($);
      if (revision !== lifecycle) return next(event);
      if (revision !== lifecycle) return next(event);
      if (!(await headless($, revision))) { await refuse($, fresh ?? owner, revision); return next(event); }
      if (revision !== lifecycle) return next(event);
      if (fresh && fresh.session_id === session) { eligible = true; eligibleSession = session; }
      else { await refuse($, fresh ?? owner); }
    } catch {
      if (revision === lifecycle) await refuse($, owner ?? retired).catch(() => undefined);
    }
    return next(event);
  });
  on('session.attach', async ($, event, next) => {
    await invalidate($, owner);
    return next(event);
  });
  on('session.end', async ($, event, next) => {
    const retired = owner;
    lifecycle += 1;
    owner = undefined; // Invalidate before awaiting any foreign middleware or I/O.
    eligible = false;
    eligibleSession = undefined;
    try { if (retired) await request($, 'retire', retired); } catch { /* inert */ }
    return next(event);
  });
  on('prompt.submit', async ($, event, next) => {
    const revision = lifecycle;
    const prior = owner;
    if (!eligible) return next(event);
    let current;
    try {
      if (!(await headless($, revision))) {
        if (revision !== lifecycle || owner !== prior) return next(event);
        await invalidate($, prior, revision);
        return next(event);
      }
      if (revision !== lifecycle || !eligible) return next(event);
      current = await bind($).catch(() => undefined);
      if (!current || revision !== lifecycle || !eligible || current.session_id !== eligibleSession) {
        if (current && current.session_id !== eligibleSession) await refuse($, current, revision).catch(() => undefined);
        return next(event);
      }
      if (!(await headless($, revision))) {
        if (revision !== lifecycle || (owner !== prior && owner !== current)) return next(event);
        await invalidate($, current, revision);
        return next(event);
      }
      if (revision !== lifecycle || !eligible || owner !== current) return next(event);
    } catch { return next(event); }
    try {
      const result = await request($, 'take', current);
      if (owner !== current || next.signal.aborted || await $.session.id() !== current.session_id) return next(event);
      if (revision !== lifecycle || !eligible) return next(event);
      if (!(await headless($, revision))) {
        if (revision !== lifecycle || (owner !== prior && owner !== current)) return next(event);
        await invalidate($, current, revision);
        return next(event);
      }
      if (revision !== lifecycle || !eligible || owner !== current) return next(event);
      if (result?.body) return next({ ...event, context: [...(event.context ?? []), result.body] });
    } catch { /* Delivery failure must never block or rewrite the user's prompt. */ }
    return next(event);
  });
}
