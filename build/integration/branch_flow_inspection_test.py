"""Observed PR relationships against TLS PostgreSQL and a production release.

Only invented, isolated fixture records are written. Product interactions are
read-only and checked against a full business/evidence fingerprint and TLS
provider spy. LiveView messages use the real protocol and rendered DOM; this is
not real-browser, keyboard, focus, or screen-reader proof.
"""
import hashlib
import json
import urllib.parse
import uuid
from contextlib import contextmanager

from branch_flow_test import (
    BASE, EXACT_BASE, EXACT_HEAD, HEAD, NEW_HEAD, OLDEST_REPO, OUTPUT, URL,
    BranchView, UnexpectedProvider, attr_values, get, identity, insert_prs,
    insert_workflows, pager, params_expr, path, provider_requests, quote, rpc,
    side_effects, snapshot, sql, value,
)
from provider_fixture import tls_provider

FOCUS = 'inspection/focus'
PIN = 'inspection/pinned'
OTHER = 'inspection/other'
FOCAL_COUNT = 48
CAP = 10
ORDERED_NUMBERS = sorted(range(1, FOCAL_COUNT + 1), key=lambda number: identity(FOCUS, number))
EARLY = [number for number in ORDERED_NUMBERS[:20] if number not in (1, 2, 3)]
LATE = [number for number in ORDERED_NUMBERS[40:] if number not in (1, 2, 3)]
MIXED_CHILD, ONPAGE_PARENT, UNIQUE_CHILD = EARLY[:3]
OFFPAGE_PARENT, UNIQUE_PARENT = LATE[:2]


def expression(params=None, selected=None, mode='topology'):
    options = [] if selected is None else [
        'inspection_id: ' + json.dumps(selected),
        'inspection_mode: ' + json.dumps(mode),
    ]
    return ('Agentboard.Delivery.BranchFlow.list(' + params_expr(params or {}) +
            ', [' + ', '.join(options) + '])')


def project(params=None, selected=None, mode='topology'):
    result = value('case ' + expression(params, selected, mode) + ' do '
                   '{:ok, data} -> data; other -> %{fixture_error: inspect(other)} end')
    assert 'fixture_error' not in result, result
    return result


def relation_ids(data):
    return [row['id'] for row in data['topology']['relations']]


def table_ids(data):
    return [row['pr']['id'] for row in data['table']['prs']]


def fingerprint():
    result = side_effects()
    # Include immutable evidence, user configuration/history, branch watches and
    # audit receipts, beyond the existing producer/business mutation checks.
    for table in ('delivery_pull_requests', 'delivery_ci_snapshots',
                  'delivery_base_watches', 'delivery_task_links',
                  'delivery_duplicate_findings', 'decision_requests',
                  'branch_flow_configuration', 'branch_flow_configuration_versions',
                  'branch_flow_receipts', 'board_action_events'):
        result[table] = sql("SELECT count(*)::text || ':' || coalesce(md5(string_agg(" +
            "to_jsonb(t)::text, ',' ORDER BY to_jsonb(t)::text)), '') FROM " + table + ' t')
    return result


@contextmanager
def readonly():
    before = fingerprint()
    yield
    after = fingerprint()
    assert after == before, {key: (before[key], after[key]) for key in before if before[key] != after[key]}
    assert not provider_requests, provider_requests


def append_snapshot(pr_id, *, changes=None, payload=None, poll_changes=None):
    """Append producer evidence; snapshots remain immutable throughout the suite."""
    changes = changes or {}
    snapshot_id = str(uuid.uuid4())
    fields = ['pull_request_id', 'generation', 'observed_at', 'head_sha', 'base_sha',
              'lifecycle', 'ci_state', 'payload']
    overrides = dict(changes)
    target_pr = overrides.get('pull_request_id', quote(pr_id))
    generation = int(sql('SELECT COALESCE(max(generation),0)+1 FROM delivery_ci_snapshots WHERE pull_request_id=' + target_pr))
    overrides.setdefault('generation', str(generation))
    if payload is not None:
        overrides['payload'] = quote(json.dumps(payload, ensure_ascii=False)) + '::jsonb'
    poll_updates = {'snapshot_id': quote(snapshot_id), 'generation': str(generation), **(poll_changes or {})}
    sql('INSERT INTO delivery_ci_snapshots (id,' + ','.join(fields) + ') SELECT ' +
        quote(snapshot_id) + ',' + ','.join(overrides.get(field, 'c.' + field) for field in fields) +
        ' FROM delivery_ci_snapshots c JOIN delivery_poll_states s ON s.snapshot_id=c.id WHERE s.id=' +
        quote(pr_id) + '; UPDATE delivery_poll_states SET ' +
        ','.join(key + '=' + val for key, val in poll_updates.items()) +
        ' WHERE id=' + quote(pr_id))
    return snapshot_id


def restore_poll(pr_id, state):
    sql('UPDATE delivery_poll_states SET ' + ','.join(
        key + '=' + quote(state[key]) for key in ('snapshot_id', 'generation', 'head_sha',
            'base_sha', 'observed_at', 'base_ref', 'expected_base_sha', 'ci_state', 'enabled')) +
        ' WHERE id=' + quote(pr_id))


def poll(pr_id):
    return json.loads(sql('SELECT to_jsonb(s) FROM delivery_poll_states s WHERE id=' + quote(pr_id)))


def seed():
    fixtures = [(FOCUS, number, {}) for number in range(1, FOCAL_COUNT + 1)]
    fixtures.extend((repo, number, {}) for repo, count in [(PIN, 2), (OTHER, 8),
        ('inspection/third', 7), ('inspection/fourth', 6), ('inspection/fifth', 5)]
        for number in range(1, count + 1))
    fixtures.extend((f'chooser/repo-{number:02}', 1, {'lifecycle': 'closed', 'enabled': False})
                    for number in range(24))
    fixtures.extend([(FOCUS, 90, {'lifecycle': 'merged', 'enabled': False}),
                     (FOCUS, 91, {'lifecycle': 'closed', 'enabled': False})])
    insert_prs(fixtures)
    insert_workflows()
    # Promote eligible immutable snapshots with proof-bearing passing policy.
    for number in range(1, FOCAL_COUNT + 1):
        passing = dict(base_ref='main', head_ref='feature/' + str(number), head_repo=FOCUS,
                       mergeable=True, mergeable_state='clean', policy='verified',
                       coverage='complete_head', tested_ref='head', attempts=[])
        append_snapshot(identity(FOCUS, number), payload=passing, changes={'ci_state': "'passing'"},
                        poll_changes={'ci_state': "'passing'"})
    selected = identity(FOCUS, 1)
    attempts = [dict(identity='failure-' + str(i), provider_id=str(1000 + i),
        kind='check_run', name='Retained failing check ' + str(i), status='completed',
        conclusion='failure', latest=i != 0,
        source_url=f'https://github.com/{FOCUS}/actions/runs/{i + 1}',
        details_url=f'https://github.com/{FOCUS}/actions/runs/{i + 1}/job/1',
        unbounded_log='not-for-preview-' + ('x' * 1000)) for i in range(15)]
    attempts.insert(0, dict(identity='success-hidden', conclusion='success', latest=True))
    payload = dict(base_ref=EXACT_BASE, head_ref=EXACT_HEAD,
                   head_repo='fork-author/shared', mergeable=False,
                   mergeable_state='dirty', draft=False, policy='unknown', attempts=attempts)
    append_snapshot(selected, payload=payload, changes={'ci_state': "'failing'"},
                    poll_changes={'base_ref': quote(EXACT_BASE), 'ci_state': "'failing'"})
    # Fork identities cannot collapse merely because their ref labels match.
    for number, fork in [(2, 'fork-two/shared'), (3, 'fork-three/shared')]:
        current = json.loads(sql('SELECT c.payload FROM delivery_ci_snapshots c '
            'JOIN delivery_poll_states s ON c.id=s.snapshot_id WHERE s.id=' + quote(identity(FOCUS, number))))
        append_snapshot(identity(FOCUS, number), payload=dict(current, head_repo=fork, head_ref='same-ref'))
    # One matching head is already on page and another is outside it. This
    # cannot be advertised as a unique continuation to the off-page PR.
    for number, ref, side in [(ONPAGE_PARENT, 'mixed-parent', 'head'),
                              (OFFPAGE_PARENT, 'mixed-parent', 'head'),
                              (MIXED_CHILD, 'mixed-parent', 'base'),
                              (UNIQUE_PARENT, 'unique-parent', 'head'),
                              (UNIQUE_CHILD, 'unique-parent', 'base')]:
        ident = identity(FOCUS, number)
        current = json.loads(sql('SELECT c.payload FROM delivery_ci_snapshots c '
            'JOIN delivery_poll_states s ON c.id=s.snapshot_id WHERE s.id=' + quote(ident)))
        current[side + '_ref'] = ref
        append_snapshot(ident, payload=current,
                        changes={'head_sha': quote(BASE)} if side == 'head' else None,
                        poll_changes={'head_sha': quote(BASE)} if side == 'head' else {'base_ref': quote(ref)})
    # Source custody is retained independently of mutable repair responsibility.
    for index in range(15):
        task = 'inspection-source-' + str(index)
        sql('INSERT INTO tasks (id,title,status) VALUES (' + quote(task) + ",'Fixture source','open'); " +
            'INSERT INTO delivery_task_links (task_id,pull_request_id,attribution,recorded_at) VALUES (' +
            quote(task) + ',' + quote(selected) + ",'unknown',now()+interval '" + str(index) + " seconds')")
    observed = poll(selected)['snapshot_id']
    sql('INSERT INTO delivery_obligations (id,pull_request_id,episode,repair_task_id,responsible_id,state,snapshot_id,evidence_urls,head_sha,last_progress_at,next_reminder_at,reminder_generation,window_at,reminders,created_at) VALUES (' +
        ','.join(map(quote, [str(uuid.uuid4()), selected, 1, 'inspection-source-0', 'ci-accountability', 'open', observed])) +
        ',ARRAY[]::text[],' + quote(HEAD) + ",now()-interval '1 hour',now()-interval '1 minute',1,now(),0,now())")
    sql('INSERT INTO delivery_rebase_follow_ups (id,pull_request_id,head_sha,base_sha,snapshot_id,repair_task_id,responsible_id,created_at) VALUES (' +
        ','.join(map(quote, [str(uuid.uuid4()), selected, HEAD, BASE, observed, 'inspection-source-1', 'ci-accountability'])) + ',now())')
    sql("INSERT INTO branch_flow_configuration (id,revision,pinned_repositories,changed_by,updated_at) " +
        "VALUES ('branch-flow',1,ARRAY[" + quote(PIN) + "],'captain',now())")
    return selected


def assert_global(data):
    assert data['cards'][0]['repository'] == PIN, data['cards']
    assert len(data['cards']) == 5
    assert sum(len(card['relations']) for card in data['cards']) <= 15
    assert data['attention']['oldest']['id'] == OLDEST_REPO + '/1'
    assert data['attention']['total'] == 11 and len(data['attention']['runs']) <= 10
    assert data['attention']['enabled'] is False
    for section in ('table', 'topology', 'attention', 'chooser'):
        if data.get(section):
            assert data[section]['projection_revision'] == data['projection_revision']


def assert_unproven(relation):
    assert relation['metadata_available'] is False, relation
    assert relation['fresh'] is False and relation['source_currentness_error'], relation
    assert relation['ci_state'] not in ('passing',) and relation['merge_state'] != 'mergeable', relation
    for field in ('head_ref', 'head_repo', 'head_sha', 'base_ref', 'base_sha'):
        assert relation[field] is None, (field, relation)


def verify_projection(selected):
    params = {'repo': FOCUS}
    with readonly():
        first = project(params)
        assert_global(first)
        assert first['topology']['total'] == FOCAL_COUNT
        assert len(relation_ids(first)) == 20 and first['topology']['next_cursor']
        assert first['table']['total'] == FOCAL_COUNT
        mixed = next(row for row in first['topology']['relations'] if row['id'] == identity(FOCUS, MIXED_CHILD))
        assert mixed['off_page_parent_ambiguous'] is True and mixed['off_page_parent'] is None, mixed
        unique = next(row for row in first['topology']['relations'] if row['id'] == identity(FOCUS, UNIQUE_CHILD))
        assert unique['off_page_parent']['id'] == identity(FOCUS, UNIQUE_PARENT), unique
        assert unique['off_page_parent']['head_repo'] == FOCUS
        assert unique['off_page_parent']['head_ref'] == 'unique-parent' and unique['off_page_parent']['head_sha'] == BASE
        second = project(dict(params, topology_cursor=first['topology']['next_cursor']))
        third = project(dict(params, topology_cursor=second['topology']['next_cursor']))
        assert len(relation_ids(second)) == 20 and len(relation_ids(third)) == 8
        assert not third['topology']['next_cursor']
        all_ids = relation_ids(first) + relation_ids(second) + relation_ids(third)
        assert len(set(all_ids)) == FOCAL_COUNT and all_ids == sorted(all_ids)
        assert relation_ids(project(dict(params, topology_cursor=second['topology']['previous_cursor']))) == relation_ids(first)
        assert table_ids(second) == table_ids(first), 'Topology cursor moved table'
        table_second = project(dict(params, cursor=first['table']['next_cursor']))
        assert relation_ids(table_second) == relation_ids(first), 'Table cursor moved topology'
        filtered = project(dict(params, q='NO_MATCHING_PR', show_terminal='true',
                                topology_cursor=first['topology']['next_cursor']))
        assert not table_ids(filtered) and relation_ids(filtered) == relation_ids(second)
        invalid = project(dict(params, topology_cursor='invalid'))
        assert invalid['topology']['error'] and not relation_ids(invalid)
        assert table_ids(invalid) == table_ids(first)
        malformed = project({'repo': {'name': FOCUS}})
        assert malformed['table']['error'] and not table_ids(malformed)
        assert malformed['topology']['error'] and not relation_ids(malformed)
        changed = project({'repo': OTHER, 'topology_cursor': first['topology']['next_cursor']})
        assert changed['topology']['error'] and not relation_ids(changed)
        mismatched_cursor = project(dict(params, topology_cursor=first['table']['next_cursor']))
        assert mismatched_cursor['topology']['error']
        exact = project({'repo': FOCUS, 'node_kind': 'base', 'node': EXACT_BASE}, selected)
        assert relation_ids(exact) == [selected]
        detail = exact['inspection']
        assert detail['available'] and detail['id'] == selected
        assert detail['relation']['base_ref'] == EXACT_BASE and detail['relation']['head_ref'] == EXACT_HEAD
        assert detail['relation']['head_repo'] == 'fork-author/shared'
        assert detail['relation']['head_sha'] == HEAD and detail['relation']['base_sha'] == BASE
        assert detail['relation']['title'] is None and detail['relation']['numeric_divergence'] is None
        assert detail['relation']['ci_state'] == 'failing' and detail['relation']['merge_state'] == 'conflicting'
        assert len(detail['failures']) == CAP and detail['failures_truncated']
        assert len(detail['sources']) == CAP and detail['sources_truncated']
        assert [source['task_id'] for source in detail['sources']] == ['inspection-source-' + str(i) for i in range(CAP)]
        assert all(row['conclusion'] == 'failure' for row in detail['failures'])
        assert detail['failures'][0]['latest'] is False
        assert 'unbounded_log' not in json.dumps(detail)
        assert detail['detail_path'] == '/prs/' + selected
        assert detail['record']['obligation']['responsible_id'] == 'ci-accountability'
        assert detail['record']['rebase_follow_up']['repair_task_id'] == 'inspection-source-1'
        assert detail['record']['overdue'] is True
        for number, fork in [(2, 'fork-two/shared'), (3, 'fork-three/shared')]:
            result = project({'repo': FOCUS, 'node_kind': 'pr', 'node': identity(FOCUS, number)})
            relation = result['topology']['relations'][0]
            assert relation['head_ref'] == 'same-ref' and relation['head_repo'] == fork
            assert result['table']['prs'][0]['relation'] == relation
        offpage = project(params, relation_ids(third)[0])['inspection']
        assert offpage['available'] is False and offpage['error']
        assert offpage['record'] is None and not offpage['failures'] and not offpage['sources']
        for ident in ['invalid', identity(OTHER, 1)]:
            denied = project(params, ident)['inspection']
            assert denied['available'] is False and denied['record'] is None
        for data in (first, second, third, filtered, changed, exact):
            assert_global(data)
    return first


def verify_source_guards(selected):
    original = poll(selected)
    params = {'repo': FOCUS, 'node_kind': 'pr', 'node': selected}
    variants = [
        ('pr', {'pull_request_id': quote(identity(FOCUS, 2))}, None),
        ('head', {'head_sha': quote(NEW_HEAD)}, None),
        ('base', {'base_sha': quote(NEW_HEAD)}, None),
        ('time', {'observed_at': "c.observed_at-interval '1 second'"}, None),
        ('generation', {}, {'generation': str(original['generation'])}),
        ('ref', {'payload': "jsonb_set(c.payload,'{base_ref}','\"unproven/ref\"'::jsonb)"}, None),
        ('snapshot', {}, {'snapshot_id': 'NULL'}),
    ]
    for name, changes, poll_changes in variants:
        try:
            append_snapshot(selected, changes=changes, poll_changes=poll_changes)
            with readonly():
                data = project(params, selected)
                detail = data['inspection']
                assert detail['available'], (name, detail)
                for relation in (data['topology']['relations'][0], data['table']['prs'][0]['relation'], detail['relation']):
                    assert_unproven(relation)
                    assert relation['ci_state'] == 'failing', 'Retained red was cleared by ' + name
                assert detail['failures'] == [], 'Unqualified failure payload leaked: ' + name
                assert len(detail['sources']) == CAP, 'Immutable source attribution disappeared'
        finally:
            restore_poll(selected, original)
    # The overview sample shares the same guard: a mismatched formerly green
    # first-slot PR cannot keep a passing/mergeable cue in any of the surfaces.
    overview_id = identity(FOCUS, ORDERED_NUMBERS[0])
    overview_poll = poll(overview_id)
    try:
        sql('UPDATE delivery_poll_states SET head_sha=' + quote(NEW_HEAD) + ' WHERE id=' + quote(overview_id))
        with readonly():
            data = project({'repo': FOCUS, 'node_kind': 'pr', 'node': overview_id}, overview_id)
            card = next(card for card in data['cards'] if card['repository'] == FOCUS)
            sample = next(row for row in card['relations'] if row['id'] == overview_id)
            for relation in (sample, data['topology']['relations'][0], data['table']['prs'][0]['relation'], data['inspection']['relation']):
                assert_unproven(relation)
                assert relation['ci_state'] == 'unknown'
    finally:
        restore_poll(overview_id, overview_poll)
    # All surfaces use the authoritative watch tip even before invalidation has
    # updated the poll state's fallback expected SHA.
    watch_id = hashlib.sha256(':'.join(FOCUS.split('/') + [EXACT_BASE]).encode()).hexdigest()
    sql('INSERT INTO delivery_base_watches (id,owner,repo,ref,head_sha,next_poll_at,last_success_at,revision) VALUES (' +
        ','.join(map(quote, [watch_id, *FOCUS.split('/'), EXACT_BASE, NEW_HEAD])) + ",now()+interval '1 day',now(),1)")
    with readonly():
        data = project(params, selected)
        assert poll(selected)['expected_base_sha'] == BASE
        for relation in (data['topology']['relations'][0], data['table']['prs'][0]['relation'], data['inspection']['relation']):
            assert relation['expected_base_sha'] == NEW_HEAD
            assert relation['metadata_available'] and not relation['fresh']
            assert relation['ci_state'] == 'failing'
    sql('UPDATE delivery_base_watches SET head_sha=' + quote(BASE) + ',revision=2 WHERE id=' + quote(watch_id))


class InspectionView(BranchView):
    def intent(self, **values):
        root = self.dom.find('id', 'pr-view')
        return dict(route_generation=root.attributes['data-route-generation'],
                    client_generation=str(int(root.attributes['data-client-generation']) + 1), **values)

    def inspect(self, ident, mode='topology'):
        self.event('inspect_pr', self.intent(id=ident, mode=mode))
        assert self.inspected == [ident], (ident, self.dom.text)

    @property
    def inspected(self):
        return attr_values(self.dom, 'data-branch-inspection')

    def dismiss(self):
        generation = self.dom.find('id', 'pr-view').attributes['data-inspection-generation']
        self.event('close_inspection', self.intent(generation=generation))
        assert not self.inspected

    def toggle(self, name):
        self.event('toggle_branch_' + name, self.intent())


def assert_four_columns(view):
    # The drawer is an additional body row spanning the unchanged four columns.
    rows = view.dom.findall('data-branch-pr')
    assert rows
    for row in rows:
        assert len([child for child in row.children if child.tag == 'td']) == 4
    drawers = view.dom.findall('id', 'branch-inspection-row')
    assert len(drawers) <= 1
    if drawers:
        cells = [child for child in drawers[0].children if child.tag == 'td']
        assert len(cells) == 1 and cells[0].attributes.get('colspan') == '4'


def verify_liveview(selected, first):
    with readonly():
        malformed = get('/prs?repo[name]=' + urllib.parse.quote(FOCUS, safe=''))
        assert 'Invalid repository' in malformed and 'role="alert"' in malformed
        view = InspectionView(path(repo=FOCUS))
        ids = relation_ids(first)
        assert len(attr_values(view.dom, 'data-branch-topology-relation')) == 20
        assert_four_columns(view)
        chooser_before = attr_values(view.dom, 'data-branch-chooser-repo')
        view.click_link(pager(view.dom, 'branch-chooser-pagination', 'Next'))
        assert not set(chooser_before) & set(attr_values(view.dom, 'data-branch-chooser-repo'))
        assert attr_values(view.dom, 'data-branch-topology-relation') == ids
        assert attr_values(view.dom, 'data-branch-pr') == table_ids(first)
        view.event('search_repositories', urllib.parse.urlencode({'chooser_q': 'chooser/repo-'}), kind='form')
        assert len(attr_values(view.dom, 'data-branch-chooser-repo')) == 20
        assert attr_values(view.dom, 'data-branch-topology-relation') == ids
        view.patch(path(repo=FOCUS))
        view.inspect(ids[0])
        old_close = view.intent(generation=view.dom.find('id', 'pr-view').attributes['data-inspection-generation'])
        old_select = view.intent(id=ids[0], mode='topology')
        # A newer client intent can arrive ahead of a previously dispatched one.
        newer = view.intent(id=ids[1], mode='topology')
        newer['client_generation'] = str(int(newer['client_generation']) + 1)
        view.event('inspect_pr', newer)
        assert view.inspected == [ids[1]]
        view.event('inspect_pr', old_select)
        view.event('close_inspection', old_close)
        assert view.inspected == [ids[1]], 'Delayed selection/close replaced newer inspection'
        view.event('close_inspection', view.intent(generation=old_close['generation']))
        assert view.inspected == [ids[1]], 'Close with stale selection generation dismissed a newer inspection'
        view.dismiss()
        view.event('inspect_pr', old_select)
        assert not view.inspected, 'Dismissed inspection reopened from delayed intent'
        view.inspect(ids[0], 'table')
        assert_four_columns(view)
        assert view.dom.find('id', 'branch-inspection').attributes['role'] == 'region'
        view.inspect(ids[1], 'table')
        assert len(view.dom.findall('id', 'branch-inspection-row')) == 1
        view.event('inspect_pr', view.intent(id=ids[1], mode='table'))
        assert not view.inspected, 'Repeated table disclosure did not close its drawer'
        view.inspect(ids[1], 'table')
        view.toggle('glyphs')
        assert not view.inspected and not attr_values(view.dom, 'data-branch-glyph')
        view.event('inspect_pr', view.intent(id=ids[0], mode='table'))
        assert not view.inspected, 'Hidden glyphs accepted a table inspection'
        view.toggle('glyphs')
        assert len(attr_values(view.dom, 'data-branch-glyph')) == 20
        view.inspect(ids[0])
        view.toggle('graph')
        assert not view.dom.findall('id', 'branch-relationship-graph')
        assert len(attr_values(view.dom, 'data-branch-topology-relation')) == 20
        assert view.inspected == [ids[0]], 'Hiding decorative graph dropped text inspection'
        view.toggle('graph')
        view.refresh()
        assert view.inspected == [ids[0]]
        route_stale = view.intent(id=ids[0], mode='topology')
        view.click_link(pager(view.dom, 'branch-topology-pagination', 'Next'))
        topology_route = view.route
        assert not view.inspected
        assert attr_values(view.dom, 'data-branch-pr') == table_ids(first)
        second_ids = attr_values(view.dom, 'data-branch-topology-relation')
        assert len(second_ids) == 20 and not set(second_ids) & set(ids)
        view.event('inspect_pr', route_stale)
        assert not view.inspected, 'Old route intent reopened an inspection'
        view.click_link(pager(view.dom, 'branch-table-pagination', 'Next'))
        assert attr_values(view.dom, 'data-branch-topology-relation') == second_ids
        view.click_link(pager(view.dom, 'branch-attention-pagination', 'Next'))
        assert attr_values(view.dom, 'data-branch-run') == [OLDEST_REPO + '/11']
        assert OLDEST_REPO in view.dom.find('id', 'branch-oldest-failure').text
        view.inspect(second_ids[0])
        view.event('search_prs', urllib.parse.urlencode({'q': 'NO_MATCHING_PR'}), kind='form')
        assert not view.inspected and not attr_values(view.dom, 'data-branch-pr')
        assert attr_values(view.dom, 'data-branch-topology-relation') == second_ids
        view.patch(path(repo=OTHER))
        assert len(attr_values(view.dom, 'data-branch-topology-relation')) == 8
        # Exact live_patch messages reconstruct Back/Forward URL state. No real
        # browser was driven and this intentionally makes no focus claim.
        view.patch(topology_route)
        assert attr_values(view.dom, 'data-branch-topology-relation') == second_ids
        assert not view.inspected
        view.patch(path(repo=FOCUS, node_kind='pr', node=selected))
        view.inspect(selected)
        panel = view.dom.find('id', 'branch-inspection')
        assert EXACT_BASE in panel.text and EXACT_HEAD in panel.text
        assert len(panel.findall('data-branch-failure-source')) == CAP
        assert len(panel.findall('data-branch-submission-source')) == CAP
        assert 'ci-accountability' in panel.text and 'Overdue' in panel.text
        assert panel.attributes['role'] == 'dialog' and panel.attributes['aria-modal'] == 'false'
        snapshot(view, 'branch-inspection-topology')
        view.dismiss()
        view.inspect(selected, 'table')
        assert_four_columns(view)
        snapshot(view, 'branch-inspection-drawer')
        view.close()
        rejoined = InspectionView(topology_route)
        assert attr_values(rejoined.dom, 'data-branch-topology-relation') == second_ids
        assert not rejoined.inspected, 'Session-only inspection persisted across rejoin'
        rejoined.close()


def verify_refresh_invalidation(selected):
    route = path(repo=FOCUS, node_kind='pr', node=selected)
    view = InspectionView(route)
    view.inspect(selected)
    original = poll(selected)
    try:
        sql('UPDATE delivery_poll_states SET head_sha=' + quote(NEW_HEAD) + ' WHERE id=' + quote(selected))
        with readonly():
            view.refresh()
            assert view.inspected == [selected]
            panel = view.dom.find('id', 'branch-inspection')
            assert 'Exact snapshot proof missing or mismatched' in panel.text
            assert 'Fresh observation' not in panel.text and EXACT_HEAD not in panel.text
            assert not panel.findall('data-branch-failure-source')
        append_snapshot(selected, changes={'head_sha': quote(NEW_HEAD)})
        with readonly():
            view.refresh()
            panel = view.dom.find('id', 'branch-inspection')
            assert NEW_HEAD in panel.text and EXACT_HEAD in panel.text
            assert 'exact source matched' in panel.text
        sql('UPDATE delivery_poll_states SET enabled=false WHERE id=' + quote(selected))
        with readonly():
            view.refresh()
            assert not view.inspected and not attr_values(view.dom, 'data-branch-topology-relation')
            assert view.dom.find('id', 'branch-inspection-status').text
    finally:
        restore_poll(selected, original)
        view.close()
    # A whole transaction failure must degrade retained success cues as well as
    # close its inspection, while preserving global oldest retained red.
    failing = InspectionView(path(repo=FOCUS))
    selected_visible = attr_values(failing.dom, 'data-branch-topology-relation')[0]
    failing.inspect(selected_visible)
    before = fingerprint()
    sql('ALTER TABLE delivery_poll_states RENAME TO inspection_fixture_missing_poll;')
    try:
        failing.refresh()
        assert not failing.inspected
        assert failing.dom.findall('role', 'alert')
        assert 'Fresh observation' not in failing.dom.text
        assert 'CI passing' not in failing.dom.text and 'Merge mergeable' not in failing.dom.text
        assert OLDEST_REPO in failing.dom.find('id', 'branch-oldest-failure').text
        snapshot(failing, 'branch-inspection-read-error')
    finally:
        sql('ALTER TABLE inspection_fixture_missing_poll RENAME TO delivery_poll_states;')
    failing.patch(path(repo=FOCUS))
    assert len(attr_values(failing.dom, 'data-branch-topology-relation')) == 20
    failing.close()
    assert fingerprint() == before and not provider_requests


def section_metrics(queries):
    """Inclusive measured query spans, using actual section savepoints.

    Nested count/source queries belong to both their own section and its parent.
    Counts include the section's SAVEPOINT/RELEASE statements, like the full-read
    budget. These are observed database timings, not inferred route deltas.
    """
    stack, result = [], {}
    for query in queries:
        statement = query['sql'].strip()
        if statement.startswith('SAVEPOINT branch_flow_'):
            stack.append(statement.removeprefix('SAVEPOINT branch_flow_'))
        for section in stack:
            entry = result.setdefault(section, dict(query_count=0, returned_rows=0, database_microseconds=0))
            entry['query_count'] += 1
            entry['returned_rows'] += query['rows']
            entry['database_microseconds'] += query['microseconds']
        if statement.startswith('RELEASE SAVEPOINT branch_flow_'):
            assert stack.pop() == statement.removeprefix('RELEASE SAVEPOINT branch_flow_')
    assert not stack
    return result


def metrics(name, params=None, selected=None, mode='topology'):
    script = r'''
      marker = make_ref()
      owner = self()
      handler = "branch-inspection-fixture-" <> Integer.to_string(System.unique_integer([:positive]))
      prefix = Agentboard.Repo.config()[:telemetry_prefix] || [:agentboard, :repo]
      :ok = :telemetry.attach(handler, prefix ++ [:query], fn _, measurements, metadata, {pid, ref} ->
        if self() == pid, do: send(pid, {ref, measurements, metadata})
      end, {owner, marker})
      started = System.monotonic_time()
      result = try do PROJECTION after :telemetry.detach(handler) end
      elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      collect = fn collect, acc ->
        receive do {^marker, measurements, metadata} -> collect.(collect, [{measurements, metadata} | acc])
        after 0 -> Enum.reverse(acc) end
      end
      queries = collect.(collect, [])
      records = Enum.map(queries, fn {measurements, metadata} ->
        rows = case metadata.result do {:ok, %{num_rows: count}} when is_integer(count) -> count; _ -> 0 end
        %{sql: metadata.query, rows: rows,
          microseconds: System.convert_time_unit(measurements.total_time, :native, :microsecond)}
      end)
      plans = queries |> Enum.uniq_by(fn {_, m} -> m.query end)
        |> Enum.filter(fn {_, m} -> Regex.match?(~r/^\s*(SELECT|WITH)\b/i, m.query) end)
        |> Enum.map(fn {_, m} ->
          case Agentboard.Repo.statement("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> m.query, m.params,
                                        timeout: 10_000) do
            {:ok, %{rows: rows}} -> %{sql: m.query, plan: rows}
            {:error, error} -> %{sql: m.query, error: Exception.message(error)}
          end
        end)
      case result do
        {:ok, data} -> %{elapsed_microseconds: elapsed, query_count: length(records),
          returned_rows: Enum.sum(Enum.map(records, & &1.rows)), queries: records, plans: plans,
          inventory_count: data.inventory_count, card_count: length(data.cards),
          table_count: length(data.table.prs), topology_count: if(data.topology, do: length(data.topology.relations), else: 0),
          failure_count: if(data.inspection, do: length(data.inspection.failures), else: 0),
          source_count: if(data.inspection, do: length(data.inspection.sources), else: 0)}
        other -> %{fixture_error: inspect(other)}
      end
    '''.replace('PROJECTION', expression(params, selected, mode))
    result = value('(fn -> ' + script + ' end).()')
    assert 'fixture_error' not in result, result
    assert result['query_count'] > 0 and result['plans']
    assert not any('error' in plan for plan in result['plans']), result['plans']
    assert result['card_count'] == 5 and result['table_count'] <= 20
    assert result['topology_count'] <= 20 and result['failure_count'] <= CAP and result['source_count'] <= CAP
    result['sections'] = section_metrics(result['queries'])
    for section in ('inspection_failures', 'inspection_sources'):
        if section in result['sections']:
            assert result['sections'][section]['returned_rows'] <= CAP + 1, (section, result['sections'][section])
    (OUTPUT / (name + '-query-budget.json')).write_text(json.dumps(result, indent=2))
    return result


def verify_scale(selected):
    params = {'repo': FOCUS, 'node_kind': 'pr', 'node': selected}
    sections = [('overview', {}, None, 'topology'),
                ('focused', {'repo': FOCUS}, None, 'topology'),
                ('inspection', params, selected, 'topology'),
                ('drawer', params, selected, 'table')]
    with readonly():
        small = {name: metrics('branch-inspection-small-' + name, p, ident, mode)
                 for name, p, ident, mode in sections}
    insert_prs([(f'load/repo-{repo:04}', number, {}) for repo in range(1000)
                for number in range(1, 11)])
    sql('ANALYZE delivery_pull_requests; ANALYZE delivery_poll_states; '
        'ANALYZE delivery_ci_snapshots; ANALYZE delivery_workflow_runs; ANALYZE delivery_task_links;')
    with readonly():
        large = {name: metrics('branch-inspection-large-' + name, p, ident, mode)
                 for name, p, ident, mode in sections}
        for name in small:
            assert large[name]['inventory_count'] == small[name]['inventory_count'] + 1000
            assert large[name]['query_count'] <= small[name]['query_count'] + 15, (name, small[name]['query_count'], large[name]['query_count'])
            assert large[name]['returned_rows'] <= small[name]['returned_rows'] + 100, (name, small[name]['returned_rows'], large[name]['returned_rows'])
        assert large['focused']['topology_count'] == 20
        assert large['inspection']['failure_count'] == CAP and large['inspection']['source_count'] == CAP
        view = InspectionView(path(repo=FOCUS))
        assert len(attr_values(view.dom, 'data-branch-topology-relation')) == 20
        assert len(attr_values(view.dom, 'data-branch-pr')) == 20
        assert attr_values(view.dom, 'data-branch-repo')[0] == PIN
        assert_four_columns(view)
        snapshot(view, 'branch-inspection-large')
        view.close()
    keys = ('query_count', 'returned_rows', 'elapsed_microseconds')
    summary = {size: {name: {key: data[key] for key in keys} for name, data in results.items()}
               for size, results in [('small', small), ('large', large)]}
    for size, results in [('small', small), ('large', large)]:
        for name, data in results.items():
            summary[size][name]['sections'] = {key: section for key, section in data['sections'].items()
                if key.startswith(('topology', 'inspection'))}
    (OUTPUT / 'branch-inspection-query-summary.json').write_text(json.dumps(summary, indent=2))
    print('Observed relationship query budgets:', json.dumps(summary))


def run():
    assert urllib.parse.urlparse(URL).hostname in ('127.0.0.1', 'localhost')
    assert sql("SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls "
               "FROM pg_roles WHERE rolname=current_user") == 't'
    assert sql('SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()') == 't', 'TLS database fixture required'
    assert sql('SELECT count(*) FROM delivery_pull_requests') == '0', 'Fresh isolated database required'
    rpc('for queue <- [:delivery_scheduler, :delivery_polling, :delivery_discovery, :cooperation] do '
        'Oban.stop_queue(queue: queue) end; '
        'Application.put_env(:agentboard, :cooperation_enabled, false); '
        'Application.put_env(:agentboard, :pr_observation_enabled, false); '
        ':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); '
        'Application.put_env(:agentboard, :branch_flow_enabled, true)')
    selected = seed()
    with tls_provider(UnexpectedProvider) as (provider, ca, _):
        rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(provider) +
            ', ca_file: ' + json.dumps(ca) + ', token: "invented-inspection-fixture"])')
        first = verify_projection(selected)
        print('Projection, bounded sources and independent cursors passed', flush=True)
        verify_source_guards(selected)
        print('Exact source and authoritative base guards passed', flush=True)
        verify_liveview(selected, first)
        verify_refresh_invalidation(selected)
        print('LiveView protocol, generation fencing and refresh invalidation passed', flush=True)
        verify_scale(selected)
        assert not provider_requests
    print('Observed PR relationship bounds, source guards, current base watch, independent cursors, '
          'inspection invalidation, read-only protocol interactions, scale and EXPLAIN checks passed. '
          'No real-browser, keyboard, focus or screen-reader proof is claimed.')


if __name__ == '__main__':
    run()
