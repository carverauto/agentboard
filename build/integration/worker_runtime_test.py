"""Execute the remote-built public CLI against invented HTTP/session contracts."""
import configparser
import contextlib
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import shlex
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import unittest
import xml.etree.ElementTree as ET

BINARY = os.environ['AB_BINARY']

def protected(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value) if not isinstance(value, str) else value)
    path.chmod(0o600)

def until(predicate, timeout=8):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if predicate():
            return
        time.sleep(.03)
    raise AssertionError('observable condition did not arrive')

class Fixture:
    def __init__(self, root, names=('worker-a',)):
        self.root = root
        self.states = {}
        self.calls = []
        self.posts = []
        self.submissions = []
        self.adapter_calls = []
        self.outcomes = {}
        self.adapter_states = {}
        self.adapters = []
        self.block_after_reserve = False
        self.reserved = threading.Event()
        self.release = threading.Event()
        self.fail = None
        self.lose_reserve_response = False
        self.extra_pending = []
        self.contract = {}
        self.historical = {}
        fixture = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self): self.respond()
            def do_POST(self): self.respond()
            def respond(self):
                path = self.path.split('?')[0]
                name = path.split('/')[4]
                action = path.split('/')[5:]
                fixture.calls.append((name, action, self.command, self.headers.get('Authorization')))
                if self.headers.get('X-Agentboard-Worker-Protocol') != '1':
                    raise AssertionError('protocol negotiation missing')
                if self.headers.get('Authorization') not in ('Bearer invented-host', 'Bearer invented-receipt'):
                    raise AssertionError('scoped authorization missing')
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
                state = fixture.states[name]
                value = {'protocol_revision': 1}
                if fixture.fail:
                    self.send_response(fixture.fail)
                    if fixture.fail == 429: self.send_header('Retry-After', '3600')
                    self.end_headers()
                    self.wfile.write(b'{"error":{"code":"forbidden","message":"invented-host must never appear"}}')
                    return
                if self.command == 'GET' and action == ['state']:
                    if fixture.block_after_reserve and fixture.reserved.is_set(): fixture.release.wait(5)
                    value.update(state)
                elif action == ['reserve']:
                    fixture.posts.append((name, 'reserve', body))
                    if not state['active_batch'] and fixture.contract:
                        state['active_batch'] = fixture.contract['reserve']['batch']
                    if not state['active_batch']:
                        payload = json.dumps({'source': 'ci-failure', 'summary': 'invented failing head', 'fetch_url': 'https://example.invalid/pr/7'})
                        batch = {'batch_id': 'batch-1', 'attempt_id': 'attempt-1', 'worker_id': name, 'binding_epoch': state['binding']['binding_epoch'], 'dispatch_generation': 1, 'payload_hash': hashlib.sha256(payload.encode()).hexdigest(), 'payload': payload, 'delivery_ids': ['delivery-1', 'delivery-2'], 'lease_expires_at': '2030-01-01T00:00:00Z', 'more': True}
                        state['active_batch'] = batch
                    value['batch'] = state['active_batch']
                    fixture.reserved.set()
                    if fixture.lose_reserve_response:
                        fixture.lose_reserve_response = False
                        self.close_connection = True
                        return
                elif action[-1:] == ['result']:
                    fixture.posts.append((name, 'result', body))
                    value['attempt'] = body
                elif action[-1:] == ['reconcile']:
                    fixture.posts.append((name, 'reconcile', body))
                    attempt = action[1] if len(action) == 3 else ''
                    if attempt in fixture.historical:
                        value.update(fixture.historical[attempt])
                    elif fixture.contract: value.update(fixture.contract['reconcile'])
                    else: value.update(batch=state['active_batch'], resolved=state.get('resolved', False), replay_allowed=False, deliveries=[], receipts=[], source_state={})
                elif action == ['receipts']:
                    fixture.posts.append((name, 'receipts', body))
                    value['receipt'] = body
                elif action == ['bind']:
                    fixture.posts.append((name, 'bind', body))
                    state['binding']['binding_epoch'] += 1
                    state['binding'].update(session_id=body['session_id'],pane_id=body['pane_id'])
                    value.update(binding=state['binding'], receipt_token='invented-new-receipt')
                elif action in (['pause'], ['resume'], ['unbind']):
                    fixture.posts.append((name, action[0], body))
                    state['worker']['paused'] = action == ['pause']
                    value.update(state)
                elif action == ['doctor']:
                    value.update(scope_valid=True, receipt_path='available')
                elif self.command == 'POST' and action == ['state']:
                    fixture.posts.append((name, 'health', body))
                elif action == ['pending'] and fixture.contract:
                    value.update(fixture.contract['pending'])
                else:
                    cursor = 'cursor-2' if 'cursor=' not in self.path else None
                    value.update(entries=[{'id': 'first' if cursor else 'second'}] + fixture.extra_pending, next_cursor=cursor)
                data = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError): self.wfile.write(data)
        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.bindings = []
        for name in names:
            directory = root / name
            directory.mkdir(mode=0o700)
            # Short enough for Linux and macOS AF_UNIX.
            sock = directory / 's'
            binding = dict(agent_id=name, model='fixture-model', harness='pi', host_id='fixture-host', server_id='fixture-server', session_id='session-'+name, adapter_generation='generation-'+name, adapter='pi-native-v1', socket_path=str(sock), token_file=str(directory/'token'), binding_epoch=1)
            protected(directory/'token', 'invented-host')
            protected(directory/'token.receipt', 'invented-receipt')
            self.bindings.append(binding)
            self.states[name] = dict(worker={'enabled': True, 'paused': False}, binding={'binding_epoch': 1, 'session_id': binding['session_id'], 'pane_id': binding['adapter_generation']}, active_batch=None)
            self.adapter_states[name] = 'idle'
            class Native(socketserver.StreamRequestHandler):
                def handle(self):
                    request = json.loads(self.rfile.readline())
                    current_name = self.server.name
                    fixture.adapter_calls.append((current_name, request['action']))
                    current = next(b for b in fixture.bindings if b['agent_id'] == current_name)
                    outcome = 'inspected'
                    if request['action'] == 'submit':
                        fixture.submissions.append((current_name, request['batch']))
                        if fixture.outcomes.get(current_name) == 'lost-response': return
                        if fixture.outcomes.get(current_name) == 'hang': fixture.release.wait(8)
                        outcome = fixture.outcomes.get(current_name, 'submitted')
                    elif request['action'] == 'reconcile': outcome = 'uncertain' if fixture.outcomes.get(current_name) == 'lost-response' else 'submitted'
                    value = dict(protocol=1, adapter_version='pi-native-v1', session_id=current['session_id'], generation=current['adapter_generation'], state=fixture.adapter_states[current_name], outcome=outcome, capabilities={c: {'supported': True, 'reason': 'invented adapter fixture'} for c in ['idle_wake','turn_start','tool_return','receipt','recovery']})
                    with contextlib.suppress(BrokenPipeError): self.wfile.write((json.dumps(value)+'\n').encode())
            adapter = socketserver.ThreadingUnixStreamServer(str(sock), Native)
            adapter.daemon_threads = True
            adapter.name = name
            sock.chmod(0o600)
            threading.Thread(target=adapter.serve_forever, daemon=True).start()
            self.adapters.append(adapter)
        self.config_path = root/'config.json'
        self.config = dict(version=1, url='http://127.0.0.1:'+str(self.http.server_port), journal_dir=str(root/'journal'), bindings=self.bindings)
        protected(self.config_path, self.config)

    def run(self, *args, success=True):
        result = subprocess.run([BINARY, 'worker', *args, '--config', str(self.config_path), '--json'], capture_output=True, text=True, timeout=10)
        if success:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        return result

    def serve(self):
        return subprocess.Popen([BINARY, 'worker', 'serve', '--config', str(self.config_path), '--json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    def stop(self, process):
        process.send_signal(signal.SIGTERM)
        output, error = process.communicate(timeout=4)
        assert 'invented-host' not in output+error
        assert 'invented-receipt' not in output+error
        return output
    def close(self):
        self.release.set()
        for adapter in self.adapters: adapter.shutdown(); adapter.server_close()
        self.http.shutdown(); self.http.server_close()

class WorkerRuntime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ab-', dir='/tmp')
        self.root = pathlib.Path(self.temp.name)
        self.fixtures = []
    def tearDown(self):
        for fixture in self.fixtures: fixture.close()
        self.temp.cleanup()
    def fixture(self, names=('worker-a',)):
        f = Fixture(self.root, names); self.fixtures.append(f); return f

    def test_server_supplied_protocol_fixtures_execute_through_public_cli(self):
        directory = pathlib.Path(os.environ['AB_WORKER_CONTRACT'])
        contract = {name: json.loads((directory/('worker-'+name+'-response.json')).read_text()) for name in ['state','reserve','reconcile','pending']}
        f = self.fixture(('fixture-agent',)); f.contract = contract
        f.states['fixture-agent'] = contract['state']
        binding = f.bindings[0]
        binding.update(session_id=contract['state']['binding']['session_id'], adapter_generation=contract['state']['binding']['pane_id'])
        protected(f.config_path, f.config)
        read = f.run('check-in')
        self.assertEqual(read['state'], contract['state'])
        self.assertEqual(read['pending'], [contract['pending']])
        self.assertEqual(f.posts, [])
        # Begin with no active attempt, then consume the exact frozen server envelope.
        f.states['fixture-agent']['active_batch'] = None
        process = f.serve(); until(lambda: any(p[1] == 'result' for p in f.posts)); f.stop(process)
        expected = contract['reserve']['batch']
        self.assertEqual(f.submissions[0][1]['payload'], expected['payload'])
        self.assertEqual(f.submissions[0][1]['payload_hash'], expected['payload_hash'])
        reserve_request = json.loads((directory/'worker-reserve-request.json').read_text())
        self.assertEqual([p[2] for p in f.posts if p[1] == 'reserve'][0]['binding_epoch'], reserve_request['binding_epoch'])
        f.run('ack', '--ids', ','.join(expected['delivery_ids']), '--key', 'contract-receipt')
        self.assertEqual(f.posts[-1][2]['delivery_ids'], expected['delivery_ids'])
        self.assertEqual(f.posts[-1][2]['payload_hash'], expected['payload_hash'])
        process = f.serve(); until(lambda: len([p for p in f.posts if p[1] == 'reconcile']) >= 2); f.stop(process)
        self.assertEqual(len(f.submissions), 1, 'server fixture replay_allowed false retains the attempt')

    def test_read_recovery_receipts_and_foreign_id_denial(self):
        f = self.fixture()
        value = f.run('check-in')
        for action in ['responsibilities','obligations','pending']:
            self.assertEqual(len(value[action]), 2)
        self.assertEqual(f.posts, [])
        process = f.serve()
        until(lambda: any(p[1]=='result' for p in f.posts))
        f.stop(process)
        self.assertEqual(len(f.submissions), 1)
        self.assertFalse(any(p[1]=='receipts' for p in f.posts))
        self.assertEqual([p for p in f.posts if p[1]=='result'][-1][2]['status'], 'submitted')
        journal = json.loads((self.root/'journal/worker-a.json').read_text())
        self.assertEqual(journal['phase'], 'awaiting_receipt')
        self.assertEqual((self.root/'journal/worker-a.json').stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(f.run('ack','--ids','foreign','--key','receipt-1',success=False).returncode, 0)
        f.run('ack','--kind','handled','--ids','delivery-1','--key','receipt-1')
        self.assertEqual(f.posts[-1][2]['delivery_ids'], ['delivery-1'])
        self.assertEqual(f.calls[-1][3], 'Bearer invented-receipt')
        process = f.serve(); until(lambda: len([p for p in f.posts if p[1]=='reconcile'])>=2); f.stop(process)
        self.assertEqual(len(f.submissions), 1, 'restart must not replay submitted batch')

    def test_crash_after_external_write_is_uncertain_and_not_replayed(self):
        f = self.fixture(); f.outcomes['worker-a'] = 'lost-response'
        process = f.serve(); until(lambda: any(p[1]=='result' for p in f.posts)); f.stop(process)
        self.assertEqual([p for p in f.posts if p[1]=='result'][-1][2]['status'], 'uncertain')
        process = f.serve(); until(lambda: len([p for p in f.posts if p[1]=='result'])>=2); f.stop(process)
        self.assertEqual(len(f.submissions), 1)
        self.assertEqual([p for p in f.posts if p[1]=='result'][-1][2]['status'], 'uncertain')

    def test_crash_before_external_write_recovers_positive_non_submission(self):
        f = self.fixture(); f.block_after_reserve = True
        process = f.serve(); until(lambda: (self.root/'journal/worker-a.json').exists() and json.loads((self.root/'journal/worker-a.json').read_text())['phase']=='reserved')
        process.kill(); process.communicate(timeout=3)
        self.assertEqual(f.submissions, [])
        f.block_after_reserve = False; f.release.set()
        process = f.serve(); until(lambda: any(p[1]=='result' for p in f.posts)); f.stop(process)
        self.assertEqual([p for p in f.posts if p[1]=='result'][-1][2]['status'], 'not_submitted')
        self.assertEqual(f.submissions, [])

    def test_lost_reservation_response_reuses_key_without_session_io(self):
        f = self.fixture(); f.lose_reserve_response = True
        process = f.serve()
        until(lambda: any(p[1] == 'result' for p in f.posts))
        f.stop(process)
        reserves = [p[2] for p in f.posts if p[1] == 'reserve']
        self.assertGreaterEqual(len(reserves), 2)
        self.assertEqual(len({r['idempotency_key'] for r in reserves}), 1)
        self.assertEqual([p[2]['status'] for p in f.posts if p[1] == 'result'], ['not_submitted'])
        self.assertEqual(f.submissions, [])

    def test_new_arrivals_do_not_expand_frozen_receipts_and_source_recovery_does_not_replay(self):
        f = self.fixture()
        process = f.serve(); until(lambda: any(p[1] == 'result' for p in f.posts)); f.stop(process)
        frozen = f.states['worker-a']['active_batch']
        f.extra_pending = [{'id': 'delivery-arrived-later'}]
        catchup = f.run('check-in')
        self.assertTrue(any(e['id'] == 'delivery-arrived-later' for p in catchup['pending'] for e in p['entries']))
        self.assertNotEqual(f.run('ack', '--ids', 'delivery-arrived-later', '--key', 'late', success=False).returncode, 0)
        self.assertEqual(frozen['delivery_ids'], ['delivery-1', 'delivery-2'])
        f.states['worker-a']['resolved'] = True
        process = f.serve(); until(lambda: json.loads((self.root/'journal/worker-a.json').read_text())['phase'] == 'complete'); f.stop(process)
        self.assertEqual(len(f.submissions), 1)
        self.assertFalse(any(p[1] == 'receipts' for p in f.posts), 'source recovery is not a fabricated handling receipt')

    def test_epoch_loss_cancels_inflight_io_and_retains_uncertainty(self):
        f = self.fixture(); f.outcomes['worker-a'] = 'hang'
        process = f.serve(); until(lambda: len(f.submissions) == 1)
        f.states['worker-a']['binding']['binding_epoch'] = 2
        until(lambda: any(p[1] == 'result' for p in f.posts))
        f.stop(process)
        self.assertEqual([p[2]['status'] for p in f.posts if p[1] == 'result'], ['uncertain'])
        self.assertEqual(json.loads((self.root/'journal/worker-a.json').read_text())['phase'], 'awaiting_receipt')

    def test_hung_recipient_does_not_stall_another_binding(self):
        f = self.fixture(('worker-a','worker-b')); f.outcomes['worker-a']='hang'
        process=f.serve(); until(lambda: any(p[0]=='worker-b' and p[1]=='result' for p in f.posts)); f.stop(process)
        self.assertTrue(any(s[0]=='worker-a' for s in f.submissions))
        self.assertTrue(any(s[0]=='worker-b' for s in f.submissions))

    def test_busy_composer_pause_and_epoch_loss_do_not_submit(self):
        for reason in ['occupied','blocked','unknown']:
            f=self.fixture() if not self.fixtures else self.fixtures[0]
            f.adapter_states['worker-a']=reason
            process=f.serve(); line=process.stdout.readline(); self.assertIn('deferred',line); f.stop(process)
        f.states['worker-a']['worker']['paused']=True
        process=f.serve(); line=process.stdout.readline(); self.assertIn('paused',line); f.stop(process)
        f.states['worker-a']['worker']['paused']=False
        f.states['worker-a']['binding']['binding_epoch']=2
        process=f.serve(); line=process.stdout.readline(); self.assertIn('binding epoch',line); f.stop(process)
        self.assertEqual(f.submissions,[])

    def test_429_cancellation_and_error_redaction(self):
        f=self.fixture(); f.fail=429
        process=f.serve(); until(lambda: len(f.calls)>0)
        output=f.stop(process)
        self.assertEqual(len([c for c in f.calls if c[1]==['state']]),1)
        self.assertNotIn('invented-host',output)
        f.fail=403
        result=f.run('check-in',success=False)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('invented-host',result.stdout+result.stderr)

    def test_invalid_json_payload_rejected_before_adapter_call(self):
        f = self.fixture()
        payload = 'plain text, not JSON'
        f.states['worker-a']['active_batch'] = {'batch_id': 'batch-bad', 'attempt_id': 'attempt-bad', 'worker_id': 'worker-a', 'binding_epoch': 1, 'dispatch_generation': 1, 'payload_hash': hashlib.sha256(payload.encode()).hexdigest(), 'payload': payload, 'delivery_ids': ['delivery-1'], 'lease_expires_at': '2030-01-01T00:00:00Z', 'more': False}
        process = f.serve()
        line = process.stdout.readline()
        self.assertIn('degraded', line)
        time.sleep(0.5)
        output = f.stop(process)
        self.assertIn('invalid frozen', line + output)
        self.assertEqual(f.submissions, [])
        self.assertFalse(any(p[1] == 'result' for p in f.posts))
        self.assertFalse(any(p[1] == 'receipts' for p in f.posts))
        self.assertFalse((self.root/'journal/worker-a.json').exists())

    def old_journal(self, f, attempt='attempt-old'):
        payload = json.dumps({'source': 'old-alert', 'summary': 'orphan attempt'})
        batch = {'batch_id': 'batch-old', 'attempt_id': attempt, 'worker_id': 'worker-a', 'binding_epoch': 1, 'dispatch_generation': 1, 'payload_hash': hashlib.sha256(payload.encode()).hexdigest(), 'payload': payload, 'delivery_ids': ['delivery-old'], 'lease_expires_at': '2030-01-01T00:00:00Z', 'more': False}
        old = dict(f.bindings[0]); old.update(binding_epoch=1, session_id='session-old', adapter_generation='generation-old')
        journal = {'version': 1, 'reservation_key': 'key-old', 'phase': 'awaiting_receipt', 'batch': batch, 'outcome': 'uncertain', 'reason': 'old uncertainty', 'binding': {'agent_id': 'worker-a', 'model': 'fixture-model', 'harness': 'pi', 'host_id': 'fixture-host', 'server_id': 'fixture-server', 'session_id': 'session-old', 'adapter_generation': 'generation-old', 'adapter': 'pi-native-v1', 'socket_path': old['socket_path'], 'token_file': old['token_file'], 'binding_epoch': 1}}
        (pathlib.Path(f.config['journal_dir'])/'worker-a.json').parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        protected(pathlib.Path(f.config['journal_dir'])/'worker-a.json', journal)
        f.bindings[0].update(binding_epoch=2, session_id='session-worker-a', adapter_generation='generation-worker-a')
        f.states['worker-a']['binding'] = {'binding_epoch': 2, 'session_id': 'session-worker-a', 'pane_id': 'generation-worker-a'}
        f.states['worker-a']['active_batch'] = None
        f.adapter_states['worker-a'] = 'occupied'
        protected(f.config_path, f.config)
        return batch

    def test_resolved_old_journal_retires_after_rebind_without_adapter_io(self):
        f = self.fixture(); batch = self.old_journal(f)
        f.historical[batch['attempt_id']] = {'batch': batch, 'resolved': True, 'replay_allowed': False}
        process = f.serve()
        until(lambda: (self.root/'journal/worker-a.json').exists() and json.loads((self.root/'journal/worker-a.json').read_text())['phase'] == 'complete')
        output = f.stop(process)
        self.assertIn('reconciled', output)
        self.assertEqual(f.submissions, [])
        self.assertFalse(any(p[1] == 'result' for p in f.posts))
        reconciles = [p for p in f.posts if p[1] == 'reconcile']
        self.assertTrue(reconciles)
        self.assertEqual(reconciles[0][2]['binding_epoch'], 1)
        self.assertEqual(reconciles[0][2]['payload_hash'], batch['payload_hash'])

    def test_unresolved_old_journal_stays_blocked_without_adapter_io(self):
        f = self.fixture(); batch = self.old_journal(f)
        f.historical[batch['attempt_id']] = {'batch': batch, 'resolved': False, 'replay_allowed': False}
        process = f.serve(); time.sleep(0.7)
        output = f.stop(process)
        self.assertIn('old binding', output)
        self.assertEqual(json.loads((self.root/'journal/worker-a.json').read_text())['phase'], 'awaiting_receipt')
        self.assertEqual(f.submissions, [])
        self.assertFalse(any(p[1] == 'result' for p in f.posts))
        self.assertFalse(any(p[1] == 'receipts' for p in f.posts))

    def test_historical_positive_answer_requires_original_frozen_generation_and_membership(self):
        cases = [
            ('generation', {'dispatch_generation': 2}, True, False),
            ('membership', {'delivery_ids': ['unrelated-delivery']}, True, False),
            ('missing', None, True, False),
            ('replay-generation', {'dispatch_generation': 2}, False, True),
        ]
        for name, changed, resolved, replay in cases:
            with self.subTest(name=name):
                root = self.root/name
                root.mkdir(mode=0o700)
                f = Fixture(root); self.fixtures.append(f)
                original = self.old_journal(f)
                returned = None if changed is None else dict(original, **changed)
                f.historical[original['attempt_id']] = {'batch': returned, 'resolved': resolved, 'replay_allowed': replay}
                process = f.serve()
                try:
                    report = json.loads(process.stdout.readline())
                finally:
                    f.stop(process)
                self.assertEqual(report['connector_state'], 'degraded')
                journal = json.loads((pathlib.Path(f.config['journal_dir'])/'worker-a.json').read_text())
                self.assertEqual(journal['phase'], 'awaiting_receipt')
                self.assertEqual(journal['batch'], original)
                self.assertEqual(f.adapter_calls, [])
                self.assertFalse(any(p[1] in ('result', 'receipts') for p in f.posts))
                requests = [p[2] for p in f.posts if p[1] == 'reconcile']
                self.assertEqual(requests, [{'binding_epoch': 1, 'dispatch_generation': 1, 'payload_hash': original['payload_hash']}])

    def test_install_preview_idempotence_owned_uninstall_and_foreign_preservation(self):
        f=self.fixture()
        for platform in ['darwin','linux']:
            home=self.root/platform; home.mkdir(mode=0o700)
            owned_name = 'dev.carverauto.agentboard.worker.plist' if platform == 'darwin' else 'agentboard-worker.service'
            owned_dir = home/'Library'/'LaunchAgents' if platform == 'darwin' else home/'.config'/'systemd'/'user'
            collision = owned_dir/owned_name
            collision.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            collision.write_text('foreign unit')
            before = collision.read_bytes()
            self.assertNotEqual(f.run('install','--home',str(home),'--platform',platform,'--apply',success=False).returncode, 0)
            self.assertEqual(collision.read_bytes(), before)
            collision.unlink()
            foreign=home/'foreign-hooks.json'; foreign.write_text('{"firstmate":"retained"}')
            args=['--home',str(home),'--platform',platform]
            preview=f.run('install',*args)
            self.assertFalse(preview['applied']); self.assertFalse((home/'.config'/'agentboard'/'worker'/'install.json').exists())
            installed=f.run('install',*args,'--apply')
            for file in installed['files']:
                data=pathlib.Path(file['path']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(),file['sha256'])
                self.assertNotIn(b'invented-host',data)
                self.assertNotIn(b'invented-receipt',data)
                if file['path'].endswith('.plist'):
                    info=plistlib.loads(data)
                    self.assertEqual(info['Label'],'dev.carverauto.agentboard.worker')
                    argv=info['ProgramArguments']
                    self.assertTrue(argv[0].endswith('.local/bin/agentboard'))
                    self.assertEqual(argv[1:3],['worker','serve'])
                    self.assertEqual(argv[3],'--config')
                    self.assertTrue(os.path.isabs(argv[4]))
                    self.assertTrue(info['KeepAlive'])
                    self.assertTrue(info['RunAtLoad'])
                    self.assertEqual(info['Umask'],63)
                    self.assertEqual(info['ThrottleInterval'],30)
                if file['path'].endswith('.service'):
                    parser=configparser.ConfigParser(interpolation=None)
                    parser.read_string(data.decode())
                    self.assertEqual(parser['Service']['Restart'],'on-failure')
                    self.assertEqual(parser['Service']['UMask'],'0077')
                    self.assertEqual(parser['Service']['NoNewPrivileges'].lower(),'true')
                    argv=shlex.split(parser['Service']['ExecStart'])
                    self.assertTrue(argv[0].endswith('.local/bin/agentboard'))
                    self.assertEqual(argv[1:3],['worker','serve'])
                    self.assertEqual(argv[3],'--config')
                    self.assertTrue(os.path.isabs(argv[4]))
            f.run('install',*args,'--apply')
            owned=pathlib.Path(installed['files'][0]['path']); original=owned.read_bytes(); owned.write_bytes(original+b'foreign edit')
            self.assertNotEqual(f.run('uninstall',*args,'--apply',success=False).returncode,0)
            owned.write_bytes(original)
            f.run('uninstall',*args,'--apply'); f.run('uninstall',*args,'--apply')
            self.assertEqual(foreign.read_text(),'{"firstmate":"retained"}')
            self.assertTrue(f.config_path.exists())

if __name__=='__main__': unittest.main(verbosity=2)
