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

export function register(on) {
  on('session.start', async ($, event, next) => {
    lifecycle += 1;
    try { owner = undefined; await bind($); } catch { owner = undefined; }
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
    const current = await bind($).catch(() => undefined);
    if (!current) return next(event);
    try {
      const result = await request($, 'take', current);
      if (owner !== current || next.signal.aborted || await $.session.id() !== current.session_id) return next(event);
      if (result?.body) return next({ ...event, context: [...(event.context ?? []), result.body] });
    } catch { /* Delivery failure must never block or rewrite the user's prompt. */ }
    return next(event);
  });
}
