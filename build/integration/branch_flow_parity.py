"""Rich, rollback-only equivalence coverage for the persisted batch projector."""
import hashlib
import json
import uuid


def assert_batched_parity(value, sql):
    """Compare all row fields against detail in one repeatable-read snapshot.

    Fixture writes and their notifications are rolled back; no producer, provider,
    worker, credential or live-board action participates in this test.
    """
    del sql  # All setup and reads must share the same rollback-only connection.
    statements = []
    head, base, changed = 'a' * 40, 'b' * 40, 'c' * 40
    repository = 'branchflow-parity/repo'
    owner, repo = repository.split('/')
    worker_a, worker_b = 'branchflow-parity-a', 'branchflow-parity-b'

    def q(item):
        if item is None:
            return 'NULL'
        if isinstance(item, bool):
            return 'true' if item else 'false'
        return "'" + str(item).replace("'", "''") + "'"

    def uid():
        return str(uuid.uuid4())

    def insert(table, fields, values):
        statements.append(f'INSERT INTO {table} ({fields}) VALUES ({values})')

    for worker, heartbeat in ((worker_a, 'now()'), (worker_b, "now()-interval '1 hour'")):
        insert('agents', 'id,name,model,harness,last_heartbeat',
               f'{q(worker)},{q(worker)},\'fixture\',\'fixture\',{heartbeat}')
        insert('cooperation_subscriptions', 'id,host_id,repos,model,harness,paused,revoked,enrolled_at',
               f"{q(worker)},'fixture',ARRAY[{q(repository)}],'fixture','fixture',true,false,now()")
        batch, attempt = uid(), uid()
        insert('cooperation_batches', 'id,worker_id,epoch,generation,delivery_ids,payload,payload_hash,more,lease_expires_at,created_at',
               f"{q(batch)},{q(worker)},1,1,ARRAY['fixture'],'fixture','fixture',false,now()-interval '1 hour',now()")
        insert('cooperation_attempts', 'id,batch_id,worker_id,epoch,generation,idempotency_key,status,created_at,updated_at',
               f"{q(attempt)},{q(batch)},{q(worker)},1,1,'fixture',{q('reserved' if worker == worker_a else 'uncertain')},now(),now()")
        insert('cooperation_bindings', 'id,epoch,generation,capabilities,connector_state,adapter_state,active_attempt_id,reported_at,updated_at',
               f"{q(worker)},1,1,'{{}}','ready','idle',{q(attempt)},{heartbeat},now()")

    tasks = ['branchflow-parity-' + name for name in ('repair', 'rebase', 'old-rebase', 'second', 'dead')]
    for task in tasks:
        dead = task.endswith('-dead')
        insert('tasks', 'id,title,status,assignee_id,claimed_at,claim_expires_at',
               f"{q(task)},'Parity fixture',{q('done' if dead else 'in_progress')},{q(worker_a)}," +
               ("NULL,NULL" if dead else "now()-interval '1 hour',now()+interval '1 hour'"))

    ids, snapshots = [], []
    for number in range(1, 21):
        url = f'https://github.com/{repository}/pull/{number}'
        ident = hashlib.sha256(url.encode()).hexdigest()
        snapshot = uid()
        ids.append(ident)
        snapshots.append(snapshot)
        insert('delivery_pull_requests', 'id,owner,repo,number,url,created_at',
               ','.join(map(q, [ident, owner, repo, number, url])) + ',now()')
        if number == 7:  # A canonical record without a poll row.
            continue
        ref = 'unobserved' if number == 9 else ('changed' if number in (4, 18) else 'main')
        state = 'passing' if number in (5, 6, 18, 20) else 'failing'
        lifecycle = 'merged' if number in (6, 20) else ('closed' if number == 19 else 'open')
        observed = "now()-interval '1 hour'" if number in (3, 6) else 'now()'
        payload = dict(base_ref=ref, head_ref=f'feature/{number}', head_repo=repository,
                       policy='verified', coverage='complete_head', tested_ref='head',
                       mergeable=True, mergeable_state='clean', draft=(number == 11))
        if number == 12:
            payload.update(mergeable=False, mergeable_state='dirty')
        if number in (13, 14, 15, 16):
            payload['mergeable_state'] = {13: 'behind', 14: 'blocked', 15: 'unstable', 16: 'draft'}[number]
        if number == 17:
            payload['mergeable'] = None
        if number == 18:
            payload['base_watch_sha'] = changed
        insert('delivery_ci_snapshots', 'id,pull_request_id,generation,observed_at,head_sha,base_sha,lifecycle,ci_state,payload',
               f"{q(snapshot)},{q(ident)},1,{observed},{q(head)},{q(base)},{q(lifecycle)},{q(state)},{q(json.dumps(payload))}::jsonb")
        insert('delivery_poll_states', 'id,registered_at,enabled,next_poll_at,generation,ci_state,observed_at,head_sha,base_sha,base_ref,expected_base_sha,snapshot_id,lifecycle,last_error',
               f"{q(ident)},now(),true,now()+interval '1 day',1,{q(state)},{observed}," +
               ','.join(map(q, [changed if number == 8 else head, base, None if number == 10 else ref,
                               base, snapshot, lifecycle, 'policy_unknown' if number == 5 else None])))

    for ref, sha, success in [('main', base, 'now()'), ('changed', changed, 'now()'), ('unobserved', changed, 'NULL')]:
        watch = hashlib.sha256(':'.join([owner, repo, ref]).encode()).hexdigest()
        insert('delivery_base_watches', 'id,owner,repo,ref,head_sha,next_poll_at,last_success_at',
               ','.join(map(q, [watch, owner, repo, ref, sha])) + f",now()+interval '1 day',{success}")

    # Latest means latest episode, even if an older episode remains unresolved.
    obligation_ids = []
    for episode in (1, 2, 3):
        ident = uid()
        obligation_ids.append(ident)
        insert('delivery_obligations', 'id,pull_request_id,episode,repair_task_id,responsible_id,state,snapshot_id,evidence_urls,head_sha,last_progress_at,next_reminder_at,reminder_generation,window_at,reminders,resolved_at,created_at',
               ','.join(map(q, [ident, ids[0], episode, tasks[0], worker_a, 'open', snapshots[0]])) +
               f",ARRAY[]::text[],{q(head)},now(),now()-interval '1 hour',1,now(),0," +
               ('NULL' if episode == 2 else 'now()') + ',now()')

    rebase_ids = []
    for index, task in enumerate((tasks[2], tasks[1])):
        ident = uid()
        rebase_ids.append(ident)
        insert('delivery_rebase_follow_ups', 'id,pull_request_id,head_sha,base_sha,snapshot_id,repair_task_id,responsible_id,created_at,resolved_at,resolution_snapshot_id',
               ','.join(map(q, [ident, ids[0], head if index else changed, base, snapshots[0], task, worker_b])) +
               (",now()-interval '1 hour',NULL,NULL" if index == 0 else f',now(),now(),{q(snapshots[0])}'))
    insert('delivery_rebase_follow_ups', 'id,pull_request_id,head_sha,base_sha,snapshot_id,repair_task_id,responsible_id,created_at',
           ','.join(map(q, [uid(), ids[1], head, base, snapshots[1], tasks[3], worker_b])) + ',now()')

    # A dead task is older but cannot own a duplicate CTA; both PRs share one
    # linked live task and its >20 pending decisions.
    for pr in ids[:2]:
        for index, task in enumerate((tasks[4], tasks[0], tasks[1])):
            insert('delivery_task_links', 'task_id,pull_request_id,attribution,recorded_at',
                   f"{q(task)},{q(pr)},'unknown',now()-interval '{3-index} hours'")
        insert('delivery_duplicate_findings', 'id,merged_pull_request_id,basis,snapshot_id,merged_snapshot_id,created_at',
               ','.join(map(q, [pr, ids[19], 'head_branch', snapshots[ids.index(pr)], snapshots[19]])) + ',now()')

    decision_ids = []
    for index in range(23):
        ident = uid()
        decision_ids.append(ident)
        insert('decision_requests', 'id,task_id,requester_id,kind,gate_ref,question,findings,status,created_at,updated_at',
               ','.join(map(q, [ident, tasks[0], worker_a if index % 2 else worker_b, 'other',
                               f'parity-{index}', 'Fixture?', 'Fixture', 'withdrawn' if index == 22 else ('answered' if index % 2 else 'open')])) +
               f",now()+interval '{index} seconds',now()")

    # Per-PR event limit spans both repair tasks; all three delivery modes and
    # exact-marker versus markerless fallback appear in the retained 20 events.
    for index in range(23):
        event, source = uid(), f'branchflow-parity-event-{index}'
        task = tasks[index % 2]
        insert('cooperation_events', 'id,source_key,kind,repo,task_id,summary,source_url,priority,audience,route_cursor,routed,created_at',
               ','.join(map(q, [event, source, 'ci_failure', repository, task, 'Fixture', 'https://example.invalid'])) +
               f",1,ARRAY[]::text[],0,true,now()+interval '{index} seconds'")
        if index % 3 == 0:
            insert('cooperation_deliveries', 'id,event_id,worker_id,state,created_at',
                   ','.join(map(q, [uid(), event, worker_a, ['pending', 'received', 'handled'][index % 9 // 3]])) + ',now()')
        else:
            body = f'[coop-fallback source={source}] Fixture' if index % 3 == 1 else 'Markerless fixture'
            insert('messages', 'sender_id,recipient_id,model,harness,task_id,body',
                   ','.join(map(q, [worker_a, worker_a, 'fixture', 'fixture', task, body])))

    # JSON avoids interpolating fixture content as executable Elixir source.
    setup = 'Jason.decode!(' + json.dumps(json.dumps(statements)) + ')'
    id_expr = 'Jason.decode!(' + json.dumps(json.dumps(ids)) + ')'
    expression = '''
      case Agentboard.Repo.transaction(fn ->
        Agentboard.Repo.statement!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        Enum.each(SETUP, &Agentboard.Repo.statement!(&1, []))
        ids = IDS
        prs = Enum.map(ids, &Ash.get!(Agentboard.Delivery.PullRequest, &1))
        batch = Agentboard.Delivery.Reads.records(prs)
        legacy = Enum.map(ids, fn id ->
          {:ok, row} = Agentboard.Delivery.Reads.detail(id)
          Map.drop(row, [:sources, :observations, :github_budget])
        end)
        differences = Enum.zip(batch, legacy) |> Enum.with_index(1)
          |> Enum.flat_map(fn {{a,b}, index} ->
            if a == b, do: [], else: [%{row: index, batch: a, legacy: b}]
          end)
        reverse = Agentboard.Delivery.Reads.records(Enum.reverse(prs))
        repeated = Agentboard.Delivery.Reads.records([hd(prs), hd(prs)])
        Agentboard.Repo.rollback(%{differences: differences, rows: batch,
          order_preserved: reverse == Enum.reverse(batch),
          repeated_preserved: repeated == [hd(batch), hd(batch)],
          empty: Agentboard.Delivery.Reads.records([])})
      end) do
        {:error, result} -> result
        other -> %{fixture_error: inspect(other)}
      end
    '''.replace('SETUP', setup).replace('IDS', id_expr)
    result = value('(fn -> ' + expression + ' end).()')
    assert 'fixture_error' not in result, result
    assert result['differences'] == [], result['differences']
    assert result['order_preserved'] and result['repeated_preserved'] and result['empty'] == [], result
    rows = result['rows']
    assert rows[0]['obligation']['id'] == obligation_ids[-1]
    assert not rows[0]['overdue'], 'An older active episode must not replace latest resolved history'
    assert rows[0]['rebase_follow_up']['id'] == rebase_ids[-1]
    assert rows[0]['worker']['binding']['id'] == worker_a
    assert rows[1]['worker']['binding']['id'] == worker_b
    assert rows[0]['worker']['uncertainty'] and rows[0]['worker']['connector_fresh']
    assert rows[1]['worker']['uncertainty'] and not rows[1]['worker']['connector_fresh']
    assert rows[0]['worker']['paused'] and not rows[0]['worker']['revoked']
    assert rows[0]['worker']['pending'] > 0 and rows[0]['worker']['received'] > 0 and rows[0]['worker']['handled'] > 0
    assert rows[0]['duplicate_of']['decision_cta']['task_id'] == tasks[0]
    assert len(rows[0]['decisions']) == 20 and len(rows[1]['decisions']) == 20
    assert [d['id'] for d in rows[0]['decisions']] == decision_ids[:20]
    assert {d['requester_stale'] for d in rows[0]['decisions']} == {True, False}
    assert len(rows[0]['follow_up_delivery']) == 20
    assert {d['mode'] for d in rows[0]['follow_up_delivery']} == {'worker', 'inbox_fallback', 'undeliverable'}
    assert rows[2]['ci_state'] == 'stale' and rows[3]['ci_state'] == 'stale'
    assert rows[4]['ci_state'] == 'unknown' and rows[5]['ci_state'] == 'passing'
    assert rows[6]['poll'] is None and rows[6]['ci_state'] == 'unknown'
    assert rows[7]['merge_state'] == 'unknown' and rows[8]['fresh']
    assert rows[10]['draft'] and rows[11]['merge_state'] == 'conflicting'
    assert [row['merge_state'] for row in rows[12:16]] == ['behind', 'blocked', 'unstable', 'draft']
    assert rows[16]['merge_state'] == 'unknown' and rows[17]['fresh']
    assert rows[18]['merge_state'] == 'not_applicable'
    return {'rows_compared': len(rows), 'differences': 0, 'rolled_back': True,
            'latest_resolved_rows': True, 'rich_worker_duplicate_decision_delivery': True}
