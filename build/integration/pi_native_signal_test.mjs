// A Pi RPC session killed by SIGINT (Ctrl-C) or SIGHUP (closed pane) never
// emits session_shutdown. The adapter must still release its own socket and
// identity so the next session can start, and the process must still die by
// the same signal.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [node, adapter] = [process.execPath, process.argv[2]];
const child = `
import { pathToFileURL } from 'node:url';
const handlers = new Map();
const ctx = { sessionManager: { getSessionId: () => 'signal-session' }, hasUI: true, mode: 'rpc', ui: { getEditorText: () => '' }, isIdle: () => true, hasPendingMessages: () => false };
const pi = { on: (e, h) => handlers.set(e, h), registerTool: () => {}, sendUserMessage: async () => {}, exec: async () => ({ stdout: '{}', code: 0 }) };
(await import(pathToFileURL(process.argv[1]))).default(pi);
await handlers.get('session_start')({}, ctx);
process.stdout.write('ready\\n');
setInterval(() => {}, 1000);
`;

for (const signal of ['SIGINT', 'SIGHUP']) {
  const directory = fs.mkdtempSync('/tmp/ab-pi-signal-');
  fs.chmodSync(directory, 0o700);
  const socket = path.join(directory, 's');
  const proc = spawn(node, ['--input-type=module', '-e', child, adapter], {
    env: { ...process.env, AGENTBOARD_PI_PROFILE: 'exclusive-rpc', AGENTBOARD_PI_SOCKET: socket, AGENTBOARD_WORKER_CONFIG: '/invented/config.json', AGENTBOARD_WORKER_ID: 'invented-worker' },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  await new Promise((resolve, reject) => {
    proc.stdout.on('data', chunk => { if (String(chunk).includes('ready')) resolve(); });
    proc.on('exit', code => reject(new Error(`child exited early: ${code}`)));
  });
  assert.ok(fs.existsSync(socket), `${signal}: socket exists while the session runs`);
  assert.ok(fs.existsSync(socket + '.identity.json'), `${signal}: identity exists while the session runs`);
  const exited = new Promise(resolve => proc.once('exit', (code, sig) => resolve({ code, sig })));
  proc.kill(signal);
  const { code, sig } = await exited;
  assert.equal(sig, signal, `${signal}: process still terminates by the signal (code=${code})`);
  assert.ok(!fs.existsSync(socket), `${signal}: socket released`);
  assert.ok(!fs.existsSync(socket + '.identity.json'), `${signal}: identity released`);
  fs.rmSync(directory, { recursive: true, force: true });
}
console.log('Pi adapter releases its socket on SIGINT and SIGHUP and re-raises the signal');
