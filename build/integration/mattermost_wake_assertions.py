"""Public protocol acceptance for exact Mattermost inbox-to-worker notification delivery.

Uses the packaged HTTP/WS fixture, real Phoenix and PostgreSQL, and invented
identities only. Native harness conformance and production enrollment are separate.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess


def verify_wake_delivery(fixture):
    api, sql, rpc, wait = (fixture[name] for name in ('api', 'sql', 'rpc', 'wait'))
    find, read, post, emit = (fixture[name] for name in ('find', 'read', 'post', 'emit'))
    posts, lock, tokens = (fixture[name] for name in ('POSTS', 'LOCK', 'TOKENS'))
    rpc('Application.put_env(:agentboard, :message_mode, "dual")')
    worker = 'wake-worker'
    prefix = '/workers/' + worker
    for target, repos in ((worker, ['fixture/repo']), ('wake-foreign', ['another/repo']),
                          ('wake-revoked', ['fixture/repo'])):
        api('/agents/register', dict(name=target), actor=target)
        tokens[target] = api('/workers/provision', dict(worker_id=target, host_id='wake-host', repos=repos,
            model='fixture-model', harness='codex', idempotency_key='provision-' + target), captain=True)['host_token']
    token = tokens[worker]
    capabilities = {name: dict(supported=name in ('receipt', 'recovery'), reason='Manual fixture')
                    for name in ('idle_wake', 'turn_start', 'tool_return', 'receipt', 'recovery')}
    bind = dict(expected_epoch=0, host_id='wake-host', idempotency_key='wake-bind-1',
                session_id='wake-session', pane_id='wake-generation', adapter='manual',
                adapter_version='1', capabilities=capabilities)
    receipt_token = api(prefix + '/bind', bind, token=token)['receipt_token']
    api('/workers/wake-revoked/revoke', {}, captain=True)

    # Drive the real CLI through the current-epoch receipt capability. No host
    # token file exists here, so success cannot accidentally use host authority.
    cli_root = Path(os.environ['TEST_TMPDIR']) / 'wake-cli'
    cli_root.mkdir(mode=0o700)
    cli_token_path = cli_root / 'token'
    cli_receipt_path = cli_root / 'token.receipt'
    cli_receipt_path.write_text(receipt_token)
    cli_receipt_path.chmod(0o600)
    cli_config = dict(version=1, url=os.environ['AGENTBOARD_URL'], journal_dir=str(cli_root / 'journal'),
        bindings=[dict(agent_id=worker, model='fixture-model', harness='codex', host_id='wake-host',
            server_id='wake-fixture', session_id='wake-session', adapter_generation='wake-generation',
            adapter='manual', socket_path=str(cli_root / 'unused-socket'),
            token_file=str(cli_token_path), binding_epoch=1)])
    cli_config_path = cli_root / 'config.json'
    cli_config_path.write_text(json.dumps(cli_config))
    cli_config_path.chmod(0o600)

    def cli(action, *args, refused=False):
        result = subprocess.run([os.environ['AB_BINARY'], 'worker', action,
            '--config', str(cli_config_path), '--worker-id', worker,
            '--session-id', 'wake-session', '--adapter-generation', 'wake-generation',
            '--json', *args], env=dict(os.environ, AGENT_ID=worker,
                AGENTBOARD_MODEL='fixture-model', AGENTBOARD_HARNESS='codex'),
            capture_output=True, text=True, timeout=15)
        for secret in (token, receipt_token, cli_receipt_path.read_text(), fixture.get('TOKEN', '')):
            if secret:
                assert secret not in result.stdout + result.stderr, 'CLI exposed a fixture credential'
        if refused:
            assert result.returncode != 0 and not result.stdout, 'CLI should refuse without data or handling'
            return None
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def cli_read(item, refused=False):
        return cli('mattermost-read', '--id', item['id'], '--version', item['version'], refused=refused)

    def cli_ack(item, refused=False):
        return cli('mattermost-ack', '--item', item['id'] + ':' + item['version'], refused=refused)

    def pending():
        return api(prefix + '/pending?limit=100', token=token)['deliveries']

    def send(post_id, message=None, **kwargs):
        with lock:
            posts[post_id] = post(post_id, message or '@wake-worker private source body', **kwargs)
            emit('posted', {'post': json.dumps(posts[post_id])})
        return wait(lambda: find(post_id, worker))

    def reference(item):
        return dict(id=item['id'], version=item['version'])

    def source_ack(item, status=200, credential=None):
        return api(prefix + '/mattermost_ack', dict(items=[reference(item)]),
                   token=credential or token, status=status)

    def reserve(key, epoch=1):
        return api(prefix + '/reserve', dict(binding_epoch=epoch, idempotency_key=key), token=token)

    def fences(batch):
        return {key: batch[key] for key in ('binding_epoch', 'dispatch_generation', 'payload_hash')}

    def receipt(batch, key, kind='handled', status=200, credential=None):
        return api(prefix + '/receipts', dict(fences(batch), attempt_id=batch['attempt_id'],
                   kind=kind, delivery_ids=batch['delivery_ids'], idempotency_key=key),
                   token=credential or receipt_token, status=status)

    # No matching recipient, revoked enrollment, wrong repo, own echo or bridge loop
    # may acquire a delivery. This message deliberately names all three identities.
    item = send('wake-first', '@wake-worker @wake-foreign @wake-revoked body-must-stay-remote')
    assert find('wake-first', 'wake-foreign') is None
    assert sql("SELECT count(*) FROM mattermost_inbox WHERE post_id='wake-first' AND worker_id='wake-revoked'") == '0'
    api('/workers/wake-revoked/pending', token=tokens['wake-revoked'], status=401)
    # Different worker locks may invoke the global router concurrently. Recovery
    # leaves ordinary unrouted events with that event-locked router's sole writer.
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        own = pool.submit(pending)
        peer = pool.submit(api, '/workers/worker-a/pending', token=tokens['worker-a'])
        own.result()
        peer.result()
    # Either transaction may skip the other's event row lock. The next read
    # converges without a second logical delivery or a transport error.
    events = wait(lambda: pending())
    assert api('/workers/wake-foreign/pending', token=tokens['wake-foreign'])['deliveries'] == []
    assert len(events) == 1 and events[0]['kind'] == 'mattermost_inbox', events
    assert events[0]['mattermost'] == reference(item)
    key = 'mattermost-inbox:' + item['id'] + ':' + item['version']
    assert events[0]['source_key'] == key
    assert sql("SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id WHERE e.source_key='%s'" % key) == '1'
    assert sql("SELECT audience::text FROM cooperation_events WHERE source_key='%s'" % key) == '{wake-worker}'
    assert 'body-must-stay-remote' not in json.dumps(events)
    assert 'body-must-stay-remote' not in sql("SELECT row_to_json(e)::text FROM cooperation_events e WHERE source_key='%s'" % key)
    with lock:
        emit('posted', {'post': json.dumps(posts['wake-first'])})
        posts['wake-own'] = post('wake-own', '@wake-worker own echo', user='shared-bot',
            props=dict(agent_id=worker, msg_id='wake-own-message', task_id='general'))
        emit('posted', {'post': json.dumps(posts['wake-own'])})
        posts['wake-bridge'] = post('wake-bridge', '@wake-worker bridge echo', user='shared-bot',
            props=dict(agentboard_event_marker='agentboard:task:fixture'))
        emit('posted', {'post': json.dumps(posts['wake-bridge'])})
    # A following source proves the preceding live frames were processed.
    sentinel = send('wake-sentinel')
    source_ack(sentinel)
    assert find('wake-own', worker) is None and find('wake-bridge', worker) is None
    assert len(pending()) == 1
    assert sql("SELECT count(*) FROM cooperation_events WHERE source_key='%s'" % key) == '1'

    # Captured intent remains pending with cooperation disabled; pause also prevents
    # reservation. Re-enablement uses normal frozen delivery rather than a new sender.
    rpc('Application.put_env(:agentboard, :cooperation_enabled, false)')
    assert reserve('wake-disabled')['batch'] is None
    rpc('Application.put_env(:agentboard, :cooperation_enabled, true)')
    api(prefix + '/pause', dict(binding_epoch=1), token=token)
    assert reserve('wake-paused')['batch'] is None
    api(prefix + '/resume', dict(binding_epoch=1), token=token)
    batch = reserve('wake-first-reserve')['batch']
    assert batch and json.loads(batch['payload'])['items'][0]['mattermost'] == reference(item)
    assert 'body-must-stay-remote' not in batch['payload']
    attempt = prefix + '/attempts/' + batch['attempt_id']
    api(attempt + '/result', dict(fences(batch), status='uncertain', reason='fixture lost acceptance'), token=token)
    assert reserve('wake-no-blind-replay')['batch'] is None
    assert read(item, worker)['message'].endswith('body-must-stay-remote')
    inspected = cli_read(item)['items'][0]
    assert inspected['message'].endswith('body-must-stay-remote')
    assert find('wake-first', worker)['id'] == item['id'], 'CLI body read must not acknowledge'
    invalid_version = dict(item, version='0' * 64)
    cli_read(invalid_version, refused=True)
    cli_ack(invalid_version, refused=True)
    foreign_item = fixture['inbox']('worker-b')[0][0]
    cli_read(foreign_item, refused=True)
    cli_ack(foreign_item, refused=True)
    assert find('wake-first', worker)['id'] == item['id'], 'refused CLI operations consumed own source'
    assert any(i['id'] == foreign_item['id'] for i in fixture['inbox']('worker-b')[0]), 'refused CLI operation consumed foreign source'
    receipt(batch, 'wake-received', kind='received')
    assert find('wake-first', worker) is not None, 'received must not handle source'
    # Source ack atomically reconciles the corresponding notification, even if its
    # native attempt was uncertain. Repeated ack retains the original receipt.
    sql("CREATE FUNCTION reject_wake_source_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture wake source ack failure'; END $$")
    sql("CREATE TRIGGER reject_wake_source_ack BEFORE UPDATE ON cooperation_deliveries FOR EACH ROW WHEN (NEW.worker_id='wake-worker' AND NEW.state='handled') EXECUTE FUNCTION reject_wake_source_ack()")
    source_ack(item, status=503)
    assert find('wake-first', worker)['id'] == item['id'], 'failed notification update must roll source ack back'
    sql('DROP TRIGGER reject_wake_source_ack ON cooperation_deliveries; DROP FUNCTION reject_wake_source_ack()')
    assert cli_ack(item)['handled'] == [item['id']]
    stamp = sql("SELECT handled_at FROM mattermost_inbox WHERE id='%s'" % item['id'])
    assert cli_ack(item)['handled'] == [item['id']]
    assert sql("SELECT handled_at FROM mattermost_inbox WHERE id='%s'" % item['id']) == stamp
    proof = api(attempt + '/reconcile', fences(batch), token=token)
    assert proof['resolved'] and not proof['replay_allowed'] and proof['batch']['payload'] == batch['payload']
    assert reserve('wake-after-source-ack')['batch'] is None

    # A same-time edit is a distinct source version and notification. A stale exact
    # ack cannot consume the edited source; revoked/foreign capabilities cannot act.
    with lock:
        posts['wake-first']['message'] = '@wake-worker edited source body'
        emit('post_edited', {'post': json.dumps(posts['wake-first'])})
    edited = wait(lambda: find('wake-first', worker))
    assert edited['version'] != item['version'] and edited['id'] != item['id']
    assert read(item, worker)['source_state'] == 'source_unavailable'
    assert cli_read(item)['items'][0]['source_state'] == 'source_unavailable'
    source_ack(item)
    assert find('wake-first', worker)['id'] == edited['id']
    source_ack(edited, credential=tokens['wake-foreign'], status=401)
    source_ack(edited, credential=tokens['wake-revoked'], status=401)
    new_batch = reserve('wake-edited')['batch']
    assert len(new_batch['delivery_ids']) == 1
    assert json.loads(new_batch['payload'])['items'][0]['mattermost'] == reference(edited)

    # A failed cooperation receipt must roll back the exact source receipt too.
    sql("CREATE FUNCTION reject_wake_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture wake receipt failure'; END $$")
    sql("CREATE TRIGGER reject_wake_receipt BEFORE INSERT ON cooperation_receipts FOR EACH ROW WHEN (NEW.worker_id='wake-worker') EXECUTE FUNCTION reject_wake_receipt()")
    receipt(new_batch, 'wake-edit-handle', status=503)
    assert find('wake-first', worker)['id'] == edited['id']
    assert sql("SELECT count(*) FROM cooperation_receipts WHERE idempotency_key='wake-edit-handle'") == '0'
    sql('DROP TRIGGER reject_wake_receipt ON cooperation_receipts; DROP FUNCTION reject_wake_receipt()')
    handled = receipt(new_batch, 'wake-edit-handle')['receipt']
    assert receipt(new_batch, 'wake-edit-handle')['receipt'] == handled
    assert find('wake-first', worker) is None
    assert pending() == []

    # Capture failure rolls back both inbox/version and event. The same remote post
    # can subsequently recover once; a stale owner cannot leave a wake behind.
    sql("CREATE FUNCTION reject_wake_capture() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture wake capture failure'; END $$")
    sql("CREATE TRIGGER reject_wake_capture BEFORE INSERT ON cooperation_events FOR EACH ROW WHEN (NEW.kind='mattermost_inbox' AND NEW.audience=ARRAY['wake-worker']) EXECUTE FUNCTION reject_wake_capture()")
    with lock:
        posts['wake-rollback'] = post('wake-rollback', '@wake-worker atomic source')
        emit('posted', {'post': json.dumps(posts['wake-rollback'])})
    wait(lambda: sql("SELECT reason FROM mattermost_inbound_runs") == 'store_unavailable')
    assert sql("SELECT count(*) FROM mattermost_inbox WHERE post_id='wake-rollback'") == '0'
    assert sql("SELECT count(*) FROM mattermost_post_versions WHERE post_id='wake-rollback'") == '0'
    sql('DROP TRIGGER reject_wake_capture ON cooperation_events; DROP FUNCTION reject_wake_capture()')
    recovered = wait(lambda: find('wake-rollback', worker))
    source_ack(recovered)
    assert pending() == []

    # Model a retained pre-upgrade inbox version that no current history scan can
    # return. Recovery uses metadata only and advances beyond one bounded page.
    sql("""INSERT INTO mattermost_post_versions(source,channel_id,post_id,version,user_id,root_id,update_at,delete_at,observed_at)
        SELECT p.source,p.channel_id,'wake-history-'||g,repeat('c',64),p.user_id,'',1000,0,clock_timestamp()
        FROM (SELECT * FROM mattermost_post_versions WHERE post_id='wake-first' LIMIT 1) p
        CROSS JOIN generate_series(1,105) g""")
    sql("""INSERT INTO mattermost_inbox(id,source,channel_id,post_id,version,worker_id,repo,kind,created_at)
        SELECT gen_random_uuid(),source,channel_id,post_id,version,'wake-worker','fixture/repo','note',clock_timestamp()
        FROM mattermost_post_versions WHERE post_id LIKE 'wake-history-%'""")
    historical_items = fixture['inbox'](worker)[0]
    assert len(historical_items) == 105
    missing = next(i for i in historical_items if i['post_id'] == 'wake-history-1')
    empty_key = 'mattermost-inbox:' + missing['id'] + ':' + missing['version']
    sql("""INSERT INTO cooperation_events(id,source_key,kind,repo,summary,source_url,priority,audience,route_cursor,routed,created_at)
        VALUES(gen_random_uuid(),'%s','mattermost_inbox','fixture/repo','Retained source reference',
        '/api/v1/workers/wake-worker/mattermost_inbox',2,'{}',0,true,clock_timestamp())""" % empty_key)
    first_page = pending()
    assert len(first_page) == 100
    assert sql("""SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id
        WHERE d.worker_id='wake-worker' AND d.state='pending'""") == '100'
    pending()
    assert sql("""SELECT count(*) FROM cooperation_deliveries d JOIN cooperation_events e ON e.id=d.event_id
        WHERE d.worker_id='wake-worker' AND d.state='pending'""") == '105'
    assert read(missing, worker)['source_state'] == 'source_unavailable'
    # Same post now has a current remote body/version B; stale A remains independently
    # inspectable as unavailable and is never replaced with today's text.
    with lock:
        posts['wake-history-1'] = post('wake-history-1', '@wake-worker current version B')
        emit('posted', {'post': json.dumps(posts['wake-history-1'])})
    current = wait(lambda: next((i for i in fixture['inbox'](worker)[0]
        if i['post_id'] == 'wake-history-1' and i['version'] != missing['version']), None))
    assert read(missing, worker)['source_state'] == 'source_unavailable'
    assert read(current, worker)['message'] == '@wake-worker current version B'
    # Explicit exact source handling consumes A only; B remains pending.
    for offset in range(0, len(historical_items), 50):
        api(prefix + '/mattermost_ack', dict(items=[reference(i) for i in historical_items[offset:offset + 50]]), token=token)
    assert find('wake-history-1', worker)['id'] == current['id']
    source_ack(current)
    assert pending() == []

    # Stale epoch receipt must leave the exact pending source untouched after bind.
    stale = send('wake-stale-epoch')
    stale_batch = reserve('wake-stale-batch')['batch']
    rebound = api(prefix + '/bind', dict(bind, expected_epoch=1, idempotency_key='wake-bind-2',
        pane_id='wake-generation-2'), token=token)
    # A fresh accepted receipt token with old local config must fail CurrentState
    # before source read/handling, even though token-only authorization succeeds.
    cli_receipt_path.write_text(rebound['receipt_token'])
    cli_read(stale, refused=True)
    cli_ack(stale, refused=True)
    assert find('wake-stale-epoch', worker)['id'] == stale['id']
    receipt(stale_batch, 'wake-stale-receipt', status=403)
    assert find('wake-stale-epoch', worker)['id'] == stale['id']
    source_ack(stale)
    historical = api(prefix + '/attempts/' + stale_batch['attempt_id'] + '/reconcile', fences(stale_batch), token=token)
    assert historical['historical'] and historical['resolved'] and not historical['replay_allowed']
    # This helper intentionally preserves the existing paused/uncertain/journal
    # semantics; it does not claim a native session was woken by the manual fixture.
    rpc('Application.put_env(:agentboard, :message_mode, "board")')
    print('PASS Mattermost exact CLI read/ack and generation fences, version-scoped wake capture, bounded reservation, source/receipt atomicity and recovery')
