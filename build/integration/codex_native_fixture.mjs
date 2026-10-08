#!/usr/bin/env node
// Invented external peers only: this fixture never implements adapter admission.
import fs from 'node:fs';
import readline from 'node:readline';
const control = () => JSON.parse(fs.readFileSync(process.env.CODEX_FIXTURE_CONTROL, 'utf8'));
const log = event => fs.appendFileSync(process.env.CODEX_FIXTURE_LOG, JSON.stringify(event) + '\n');
const args = process.argv.slice(2);
if (args[0] === '--version') {
  console.log('codex-cli ' + (control().version || '0.160.1'));
} else if (args[0] === 'worker') {
  log({ cli: args });
  const c = control();
  if (c.cli_delay) await new Promise(resolve => setTimeout(resolve, c.cli_delay));
  if (c.cli_fail) process.exitCode = 1;
  else if (args[1] === 'state') console.log(JSON.stringify({ protocol_revision: 1, state: control().state }));
  else if (args[1] === 'check-in') console.log(JSON.stringify({ protocol_revision: 1, state: control().state, responsibilities: [{ entries: [] }], obligations: [{ entries: [] }], pending: [{ entries: [] }] }));
  else if (args[1] === 'ack') console.log(JSON.stringify({ protocol_revision: 1, receipt: { kind: args[args.indexOf('--kind') + 1], ids: args[args.indexOf('--ids') + 1], key: args[args.indexOf('--key') + 1] } }));
  else process.exitCode = 1;
} else if (args[0] === 'app-server') {
  log({ launch: args });
  const input = readline.createInterface({ input: process.stdin });
  let turn = null, count = 0, toolSequence = 1000, revision = '';
  const thread = () => ({ id: 'invented-native-thread', ephemeral: control().ephemeral !== false, path: control().ephemeral === false ? '/invented/persisted-thread' : null, cliVersion: '0.160.1', status: { type: control().status || (turn ? 'active' : 'idle') } });
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  const emitTool = tool => send({ id: ++toolSequence, method: 'item/tool/call', params: { threadId: tool.thread || 'invented-native-thread', turnId: tool.turn || turn, callId: 'invented-call-' + toolSequence, tool: tool.name, arguments: tool.args, namespace: null } });
  const watcher = setInterval(() => {
    const c = control();
    if (!c.revision || c.revision === revision) return;
    revision = c.revision;
    if (c.complete && turn) { send({ method: 'turn/completed', params: { threadId: 'invented-native-thread', turn: { id: turn, status: 'completed' } } }); turn = null; }
    if (c.notify_status) send({ method: 'thread/status/changed', params: { threadId: 'invented-native-thread', status: { type: c.notify_status, ...(c.notify_status === 'active' ? { activeFlags: ['waitingOnApproval'] } : {}) } } });
    if (c.tool) emitTool(c.tool);
    if (c.approval) send({ id: 9000, method: 'item/commandExecution/requestApproval', params: { threadId: 'invented-native-thread', turnId: turn } });
    if (c.exit) process.exit(0);
  }, 10);
  input.on('line', line => {
    const r = JSON.parse(line); log({ native: r });
    if (!r.method) return;
    const result = value => send({ id: r.id, result: value });
    if (r.method === 'initialize') result({ userAgent: 'codex-cli/0.160.1', codexHome: '/invented/operator-home', platformFamily: 'unix', platformOs: 'linux' });
    else if (r.method === 'thread/start') result({ thread: thread(), model: 'fixture-model' });
    else if (r.method === 'thread/read') result({ thread: thread() });
    else if (r.method === 'turn/start') {
      turn = 'invented-turn-' + (++count);
      send({ method: 'turn/started', params: { threadId: 'invented-native-thread', turn: { id: turn, status: 'inProgress' } } });
      const mode = control().turn_response;
      if (mode === 'disconnect') { process.exit(0); return; }
      if (mode === 'lost') return;
      if (mode === 'error') { send({ id: r.id, error: { code: -32000, message: 'Invented refusal' } }); return; }
      if (mode === 'complete-first') {
        send({ method: 'turn/completed', params: { threadId: 'invented-native-thread', turn: { id: turn, status: 'completed' } } });
        send({ method: 'thread/status/changed', params: { threadId: 'invented-native-thread', status: { type: 'idle' } } });
      }
      result({ turn: { id: mode === 'wrong-turn' ? 'invented-wrong-turn' : turn, status: 'inProgress' } });
      if (mode === 'complete-first') turn = null;
    }
  });
  input.on('close', () => { clearInterval(watcher); });
} else process.exitCode = 1;
