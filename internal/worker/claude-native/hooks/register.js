// Claude Code 2.1.289 native mods API. Opt-in plugin loading; no settings edits.
// The MCP child owns transport, never a detached shell or a model watcher.
let owner;
let lifecycle = 0;

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

async function proven($, event) {
  if (event?.isInteractive) return false;
  if (typeof $.session?.surfaces !== 'function') return false;
  try {
    const surfaces = await $.session.surfaces();
    if (Array.isArray(surfaces)) return surfaces.length === 0;
    return !surfaces;
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
  if (identity && revision === lifecycle && await $.session.id() === session && revision === lifecycle) owner = identity;
  else if (identity) await request($, 'retire', identity).catch(() => undefined);
  return revision === lifecycle && owner?.session_id === session ? owner : undefined;
}

async function refuse($, current) {
  lifecycle += 1;
  owner = undefined;
  try { if (current) await request($, 'retire', current); } catch { /* inert */ }
}

export function register(on) {
  on('session.start', async ($, event, next) => {
    lifecycle += 1;
    try { owner = undefined; if (await proven($, event)) await bind($); } catch { owner = undefined; }
    return next(event);
  });
  on('session.end', async ($, event, next) => {
    const retired = owner;
    lifecycle += 1;
    owner = undefined; // Invalidate before awaiting any foreign middleware or I/O.
    try { if (retired) await request($, 'retire', retired); } catch { /* inert */ }
    return next(event);
  });
  on('prompt.submit', async ($, event, next) => {
    let current;
    try {
      if (!(await proven($, event))) { await refuse($, owner); return next(event); }
      current = await bind($).catch(() => undefined);
    } catch { return next(event); }
    if (!current) return next(event);
    try {
      const result = await request($, 'take', current);
      if (owner !== current || next.signal.aborted || await $.session.id() !== current.session_id) return next(event);
      if (!(await proven($, event).catch(() => false))) { await refuse($, current); return next(event); }
      if (result?.body) return next({ ...event, context: [...(event.context ?? []), result.body] });
    } catch { /* Delivery failure must never block or rewrite the user's prompt. */ }
    return next(event);
  });
}
