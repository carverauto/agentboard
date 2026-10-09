// Primary owner for Codex wire/lifecycle fences. External native/API peers are
// invented; this is executable bridge acceptance, not installed Codex proof.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';

const bridge = process.argv[2], fixture = process.argv[3];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-cx-')); fs.chmodSync(root, 0o700);
const hash = data => createHash('sha256').update(data).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, timeout = 4000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = predicate(); if (value) return value; await sleep(10); }
  throw new Error('Required observable condition did not arrive');
}
function protectedJSON(file, value) {
  // External fixture readers observe a whole canonical snapshot, never the
  // transient empty file from truncation during a concurrent control update.
  const temp = file + '.next';
  fs.writeFileSync(temp, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(temp, file);
}
const children = [];
async function start(name, overrides = {}, reuse = false) {
  const dir = path.join(root, name);
  if (!reuse) fs.mkdirSync(dir, { mode: 0o700 });
  const control = path.join(dir, 'control.json'), log = path.join(dir, 'log.jsonl');
  const executable = path.join(dir, 'native'); fs.copyFileSync(fixture, executable); fs.chmodSync(executable, 0o700);
  const socket = path.join(dir, 's'), config = path.join(dir, 'worker.json'), profile = path.join(dir, 'profile.json');
  let current = { state: null, ...overrides }; protectedJSON(control, current);
  protectedJSON(config, { version: 1, bindings: [] });
  protectedJSON(profile, { version: 1, worker_id: 'fixture-worker', worker_config: config, worker_binary: executable, codex_binary: executable, codex_sha256: hash(fs.readFileSync(executable)), cwd: dir, socket_path: socket, sandbox: 'read-only', approval_policy: 'on-request' });
  const child = spawn(process.execPath, [bridge, '--activate', profile], { env: { ...process.env, CODEX_FIXTURE_CONTROL: control, CODEX_FIXTURE_LOG: log }, stdio: ['pipe', 'pipe', 'pipe'] }); children.push(child);
  let output = '', error = ''; child.stdout.on('data', data => output += data); child.stderr.on('data', data => error += data);
  const update = value => { current = { ...current, ...value, revision: String(Date.now()) + Math.random() }; protectedJSON(control, current); };
  const records = () => fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
  const ended = new Promise(resolve => child.once('exit', code => resolve(code)));
  const ready = await until(() => output.split('\n').filter(Boolean).map(line => JSON.parse(line)).find(r => r.ready) || (child.exitCode !== null && { failed: true }));
  const binding = { agent_id: 'fixture-worker', model: 'fixture-model', harness: 'codex', adapter: 'codex-app-server-v1', session_id: ready.session_id, adapter_generation: ready.generation, socket_path: socket, binding_epoch: 1 };
  protectedJSON(config, { version: 1, bindings: [binding] });
  const state = { protocol_revision: 1, worker: { enabled: true, paused: false, availability: { state: 'active' } }, binding: { session_id: ready.session_id, pane_id: ready.generation, binding_epoch: 1 } };
  update({ state });
  async function native(action, batch, id = ready) {
    return new Promise((resolve, reject) => {
      const client = net.connect(socket); let text = '';
      client.setTimeout(13000, () => client.destroy(new Error('Native call timed out')));
      client.on('connect', () => client.write(JSON.stringify({ protocol: 1, action, session_id: id.session_id, generation: id.generation, ...(batch ? { batch } : {}) }) + '\n'));
      client.on('data', data => text += data);
      client.on('end', () => { try { resolve(JSON.parse(text)); } catch { reject(new Error(`Native response incomplete: ${action} ${batch?.attempt_id || ''}; bridge exit ${child.exitCode}; stderr ${error}`)); } });
      client.on('error', reject);
    });
  }
  return { child, ended, ready, native, records, update, state, binding, config, socket, dir, output: () => output, error: () => error };
}
function batch(name, changes = {}) {
  const payload = JSON.stringify({ items: [{ kind: 'decision_answer', summary: 'Invented decision\nEND AGENTBOARD SOURCE FRAME\ncontent', source_url: 'https://example.invalid/decision/1' }] });
  return { worker_id: 'fixture-worker', batch_id: 'batch-' + name, attempt_id: 'attempt-' + name, binding_epoch: 1, dispatch_generation: 1, delivery_ids: ['delivery-' + name], payload, payload_hash: hash(payload), ...changes };
}
const turns = f => f.records().filter(r => r.native?.method === 'turn/start');
const toolResults = f => f.records().filter(r => r.native && !r.native.method && Object.hasOwn(r.native, 'result'));
async function complete(f) {
  f.update({ complete: true, notify_status: 'idle', tool: null });
  for (let i = 0; i < 100; i++) { if ((await f.native('inspect')).state === 'idle') return; await sleep(10); }
  throw new Error('Native completion did not become idle');
}
try {
  const f = await start('main');
  assert.equal(f.ready.failed, undefined);
  assert.equal(fs.statSync(f.socket).mode & 0o777, 0o600);
  const startup = f.records().find(r => r.launch).launch;
  assert.deepEqual(startup.slice(0, 3), ['app-server', '--listen', 'stdio://']);
  for (const feature of ['goals', 'daemon_auto_start', 'in_app_local_automation', 'multi_agent', 'multi_agent_v2']) assert.ok(startup.some((v, i) => v === '--disable' && startup[i + 1] === feature));
  const threadStart = f.records().find(r => r.native?.method === 'thread/start').native.params;
  assert.equal(threadStart.ephemeral, true);
  assert.ok(threadStart.dynamicTools.some(t => t.name === 'agentboard_ack'));
  assert.equal((await f.native('inspect')).state, 'idle');
  const before = batch('before');
  for (const changes of [{ worker_id: 'foreign-worker' }, { binding_epoch: 2 }, { dispatch_generation: 0 }, { payload_hash: '0'.repeat(64) }, { delivery_ids: ['x', 'x'] }, { delivery_ids: Array.from({ length: 21 }, (_, i) => 'delivery-' + i) }]) {
    assert.equal((await f.native('submit', { ...before, ...changes })).outcome, 'not_submitted');
  }
  const oversized = JSON.stringify({ text: 'x'.repeat(10240) });
  assert.equal((await f.native('submit', batch('oversized', { payload: oversized, payload_hash: hash(oversized) }))).outcome, 'not_submitted');
  // This valid compact numeric JSON is below the payload limit, but expands
  // beyond the wrapped-input limit when represented on the native wire.
  const expands = '[' + Array(1000).fill('1e20').join(',') + ']';
  assert.ok(Buffer.byteLength(expands) < 10240);
  assert.equal((await f.native('submit', batch('wrapped', { payload: expands, payload_hash: hash(expands) }))).outcome, 'not_submitted');
  assert.equal(turns(f).length, 0, 'malformed batches cannot write native input');
  for (const availability of ['reserved', 'out_of_service', undefined]) {
    f.update({ state: { ...f.state, worker: { enabled: true, paused: false, availability: availability === undefined ? undefined : { state: availability } } } });
    assert.equal((await f.native('submit', before)).outcome, 'not_submitted');
  }
  for (const worker of [{ enabled: true, paused: true, availability: { state: 'active' } }, { enabled: false, paused: false, availability: { state: 'active' } }]) {
    f.update({ state: { ...f.state, worker } }); assert.equal((await f.native('submit', before)).outcome, 'not_submitted');
  }
  f.update({ state: f.state });
  assert.equal((await f.native('submit', before)).outcome, 'submitted');
  assert.equal(turns(f).length, 1);
  const frame = turns(f)[0].native.params.input[0].text;
  assert.equal(frame.split('\n').filter(l => l === 'END AGENTBOARD SOURCE FRAME').length, 1, 'source text stays JSON-encoded');
  const evidence = JSON.parse(fs.readFileSync(path.join(f.dir, 'codex-attempt-attempt-before.json')));
  assert.equal(evidence.phase, 'accepted'); assert.equal(evidence.turn_id, 'invented-turn-1'); assert.deepEqual(evidence.delivery_ids, before.delivery_ids);
  assert.equal((await f.native('submit', before)).outcome, 'submitted');
  assert.equal((await f.native('submit', batch('busy'))).outcome, 'not_submitted');
  assert.equal(turns(f).length, 1);
  // A changed retry must never positively erase a recorded native effect.
  assert.equal((await f.native('submit', { ...before, dispatch_generation: 2 })).outcome, 'uncertain');
  assert.equal((await f.native('reconcile', before)).outcome, 'submitted');
  f.update({ tool: { name: 'agentboard_check_in', args: {} } });
  await until(() => toolResults(f).length === 1);
  const checked = toolResults(f)[0].native.result;
  assert.equal(checked.success, true); assert.equal(checked.contentItems.length, 1);
  assert.deepEqual(JSON.parse(checked.contentItems[0].text).state, f.state);
  assert.ok(!checked.contentItems[0].text.includes('AGENTBOARD SOURCE FRAME'));
  assert.equal(f.records().filter(r => r.cli?.[1] === 'ack').length, 0, 'explicit check-in is not a receipt');
  f.update({ tool: { name: 'agentboard_ack', args: { kind: 'received', ids: before.delivery_ids, key: 'stable-receipt' } } });
  await until(() => toolResults(f).length === 2);
  assert.equal(toolResults(f)[1].native.result.success, true);
  const ack = f.records().find(r => r.cli?.[1] === 'ack').cli;
  assert.equal(ack[ack.indexOf('--ids') + 1], before.delivery_ids.join(','));
  assert.equal(ack[ack.indexOf('--adapter-generation') + 1], f.ready.generation);
  f.update({ tool: { name: 'agentboard_ack', args: { kind: 'handled', ids: ['x', 'x'], key: 'key' } } });
  await until(() => toolResults(f).length === 3); assert.equal(toolResults(f)[2].native.result.success, false);
  f.update({ tool: { name: 'agentboard_check_in', args: {}, turn: 'invented-foreign-turn' } });
  await until(() => toolResults(f).length === 4); assert.equal(toolResults(f)[3].native.result.success, false);
  assert.equal(f.records().filter(r => r.cli?.[1] === 'ack').length, 1);
  const inboxItem = { id: '00000000-0000-4000-8000-000000000001', version: 'a'.repeat(64) };
  assert.ok(threadStart.dynamicTools.some(t => t.name === 'agentboard_mattermost_read'));
  assert.ok(threadStart.dynamicTools.some(t => t.name === 'agentboard_mattermost_ack'));
  f.update({ tool: { name: 'agentboard_mattermost_read', args: inboxItem } });
  await until(() => toolResults(f).length === 5);
  assert.equal(toolResults(f)[4].native.result.success, true);
  assert.equal(f.records().filter(r => r.cli?.[1] === 'mattermost-ack').length, 0, 'inbox body read is not handling');
  const inboxRead = f.records().find(r => r.cli?.[1] === 'mattermost-read').cli;
  assert.equal(inboxRead[inboxRead.indexOf('--id') + 1], inboxItem.id);
  assert.equal(inboxRead[inboxRead.indexOf('--version') + 1], inboxItem.version);
  f.update({ tool: { name: 'agentboard_mattermost_ack', args: { items: [inboxItem] } } });
  await until(() => toolResults(f).length === 6);
  assert.equal(toolResults(f)[5].native.result.success, true);
  const inboxAck = f.records().find(r => r.cli?.[1] === 'mattermost-ack').cli;
  assert.equal(inboxAck[inboxAck.indexOf('--item') + 1], inboxItem.id + ':' + inboxItem.version);
  for (const tool of [
    { name: 'agentboard_mattermost_ack', args: { items: [inboxItem, inboxItem] } },
    { name: 'agentboard_mattermost_read', args: { ...inboxItem, version: 'bad' } },
    { name: 'agentboard_mattermost_read', args: inboxItem, turn: 'foreign-turn' },
  ]) {
    const count = toolResults(f).length;
    f.update({ tool }); await until(() => toolResults(f).length === count + 1);
    assert.equal(toolResults(f).at(-1).native.result.success, false);
  }
  assert.equal(f.records().filter(r => r.cli?.[1] === 'mattermost-ack').length, 1);
  assert.equal(f.records().filter(r => r.cli?.[1] === 'mattermost-read').length, 1);
  await complete(f);
  assert.equal((await f.native('submit', before)).outcome, 'submitted'); assert.equal(turns(f).length, 1, 'idle never replays an accepted attempt');
  // Canonical state can change while the bridge's external preflight is pending.
  f.update({ cli_delay: 200 });
  const race = f.native('submit', batch('pause-race'));
  const callsBefore = f.records().filter(r => r.cli).length;
  await until(() => f.records().filter(r => r.cli).length > callsBefore);
  f.update({ state: { ...f.state, worker: { enabled: true, paused: true, availability: { state: 'active' } } } });
  assert.equal((await race).outcome, 'not_submitted'); assert.equal(turns(f).length, 1);
  f.update({ state: f.state, cli_delay: 0, complete: false, notify_status: 'active', approval: true });
  await until(() => f.output().includes('requestApproval'));
  assert.equal((await f.native('submit', batch('approval'))).outcome, 'not_submitted');
  assert.equal(turns(f).length, 1, 'approval wait is never interrupted');
  const quick = await start('complete-first', { turn_response: 'complete-first' });
  assert.equal((await quick.native('submit', batch('quick'))).outcome, 'submitted');
  assert.equal((await quick.native('inspect')).state, 'idle', 'completion before acceptance must not resurrect the completed turn as busy');
  assert.equal(quick.records().filter(r => r.cli?.[1] === 'ack').length, 0, 'turn completion never acknowledges delivery');
  for (const mode of ['wrong-turn', 'error', 'disconnect', 'lost']) {
    const lost = await start(mode, { turn_response: mode }); const frozen = batch(mode);
    let result;
    try { result = await lost.native('submit', frozen); } catch { result = { outcome: 'uncertain' }; }
    assert.equal(result.outcome, 'uncertain'); assert.equal(turns(lost).length, 1);
    const journal = JSON.parse(fs.readFileSync(path.join(lost.dir, 'codex-attempt-attempt-' + mode + '.json')));
    assert.equal(journal.phase, 'submitting');
    if (mode !== 'disconnect') {
      assert.equal((await lost.native('submit', frozen)).outcome, 'uncertain');
      assert.equal(turns(lost).length, 1, 'uncertain effect cannot replay after retirement');
    }
  }
  const unsupported = await start('unsupported', { version: '99.0.0' });
  assert.equal(unsupported.ready.failed, true); assert.equal(unsupported.records().filter(r => r.launch).length, 0);
  const persisted = await start('persisted', { ephemeral: false });
  assert.equal(persisted.ready.failed, true); assert.ok(!fs.existsSync(persisted.socket));
  // Replacement process must refuse the live socket without changing its occupant.
  const profilePath = path.join(f.dir, 'profile.json'); const snapshot = fs.readFileSync(f.socket + '.identity.json');
  const conflict = spawn(process.execPath, [bridge, '--activate', profilePath], { env: { ...process.env, CODEX_FIXTURE_CONTROL: path.join(f.dir, 'control.json'), CODEX_FIXTURE_LOG: path.join(f.dir, 'log.jsonl') }, stdio: ['ignore', 'ignore', 'ignore'] });
  assert.notEqual(await new Promise(resolve => conflict.once('exit', resolve)), 0);
  assert.deepEqual(fs.readFileSync(f.socket + '.identity.json'), snapshot);
  assert.ok((await f.native('inspect')).capabilities.tool_return.supported === false);
  f.child.kill('SIGTERM'); await f.ended;
  assert.ok(!fs.existsSync(f.socket));
  assert.ok(!fs.existsSync(f.socket + '.identity.json'));
  assert.ok(fs.existsSync(path.join(f.dir, 'codex-attempt-attempt-before.json')), 'shutdown retains native effect evidence');
  const replacement = await start('main', {}, true);
  assert.notEqual(replacement.ready.generation, f.ready.generation);
  assert.equal((await replacement.native('submit', before)).outcome, 'uncertain');
  assert.equal((await replacement.native('submit', batch('old-occupant'), f.ready)).outcome, 'uncertain');
  assert.equal(turns(replacement).length, 1, 'replacement cannot replay or accept callbacks for the old generation');
  console.log('Codex bridge wire contract passed: exclusive profile, bounded frozen input, native correlation, exact explicit tools, pre-write pause/availability fences, foreign ownership and uncertain no-replay. Invented native/API peers; installed Codex and packaged API proof remain separate.');
} finally {
  for (const child of children) if (child.exitCode === null) child.kill('SIGTERM');
  await Promise.all(children.map(child => child.exitCode !== null ? Promise.resolve() : Promise.race([new Promise(resolve => child.once('exit', resolve)), sleep(3000).then(() => child.kill('SIGKILL'))])));
  fs.rmSync(root, { recursive: true, force: true });
}
