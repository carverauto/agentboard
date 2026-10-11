// Unregistered connect-only client. No CLI, daemon lifecycle, enrollment or fallback.
import net from 'node:net';
import { inspectCodexSocket } from './socket-discovery.mjs';
import { openCodexRpcWire, requireEvidence } from './rpc-wire.mjs';

/**
 * No evidence provider is shipped. Calling initialize has native subscription
 * and process metadata side effects; owner approval/proof is required before dial.
 * A version string, socket inode or PID is not connected-peer/lifetime evidence.
 */
export async function connectCodexRpcClient({ codexHome, evidence, timeoutMs = 5000, lifetimeMs = 30000 } = {}) {
  requireEvidence(evidence); // No filesystem probing or connection without the seam.
  const boundary = inspectCodexSocket(codexHome);
  return openCodexRpcWire({
    boundary, evidence, timeoutMs, lifetimeMs,
    connect() {
      boundary.check();
      const socket = net.createConnection({ path: boundary.descriptor.targetPath });
      // Recheck before HTTP bytes can be flushed to the connected socket.
      socket.prependOnceListener('connect', () => {
        try { boundary.check(); } catch { socket.destroy(new Error('Codex socket changed')); }
      });
      return socket;
    },
  });
}
