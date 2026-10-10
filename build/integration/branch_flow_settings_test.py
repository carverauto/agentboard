"""Captain pin settings against real PostgreSQL, release RPC and LiveView.

Run alone in a fresh, disposable normal-role database. All identities, repository
names, capabilities and provider endpoints are synthetic. The companion schema
suite owns schema-36/marker-99 upgrades; this suite owns write custody, immutable
receipts/history, interrupted saves and bounded pin-aware reads. It is a rendered
protocol regression, not an actual browser keyboard or screen-reader test.
"""
import concurrent.futures
import http.cookiejar
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from contextlib import contextmanager

# This module has a guarded main. Importing its fixture helpers never runs its
# independent large history-retaining regression or mutates the database.
from branch_flow_test import (
    URL, OLDEST_REPO, BranchView, Document, UnexpectedProvider, attr_values,
    get, identity, insert_prs, insert_workflows, params_expr, projection,
    provider_requests, quote, rpc, snapshot, sql, value,
)
from liveview_client import Page, RenderedView
from provider_fixture import tls_provider

CAPTAIN = 'fixture-branch-pin-captain-capability-0123456789'
ROTATED = 'fixture-branch-pin-rotated-capability-9876543210'
SERVICE = 'Agentboard.Delivery.BranchFlow.Settings'
CONFIG_LOCK = 1_853_001
TABLES = ['branch_flow_configuration', 'branch_flow_configuration_versions',
          'branch_flow_receipts']
EVIDENCE = TABLES + ['board_action_events']
A, B, C, D, E = ['pins/' + name for name in ('alpha', 'beta', 'gamma', 'delta', 'epsilon')]
TERMINAL, UNKNOWN, DISABLED = 'pins/terminal', 'pins/unknown', 'pins/disabled'
MALFORMED = ['Pins/legacy', '-pins/legacy', 'pins/.', 'pins/..', 'pins/' + 'x' * 252]


def outcome(expression):
    return ('case (' + expression + ') do '
            '{:ok, data} -> %{ok: data}; '
            '{:error, code, message} -> %{error: code, message: message}; '
            'other -> %{unexpected: inspect(other)} end')


def capability(*, expires=None):
    expression = 'Agentboard.Captain.authenticate(' + json.dumps(CAPTAIN) + ')'
    if expires is not None:
        expression += ' |> Map.put("expires", System.system_time(:second) + ' + str(expires) + ')'
    return value(expression)


def service(method, data=None, *, cap=None, expected='ok'):
    args = params_expr(cap if cap is not None else capability())
    if method != 'show':
        args += ', ' + params_expr(data)
    result = value(outcome(SERVICE + '.' + method + '(' + args + ')'))
    assert 'unexpected' not in result, result
    if expected is None:
        return result
    if expected == 'ok':
        assert 'ok' in result, result
        return result['ok']
    assert result.get('error') == expected, (expected, result)
    return result


def request(revision, key, pins=None):
    return {'revision': revision, 'idempotency_key': key,
            'pinned_repositories': [] if pins is None else pins}


def show(**kwargs):
    return service('show', **kwargs)


def replace(data, **kwargs):
    return service('replace', data, **kwargs)


def reconcile(data, **kwargs):
    return service('reconcile', data, **kwargs)


def rows(tables=EVIDENCE):
    return {table: sql('SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'
                      "'[]'::jsonb) FROM \"" + table + '\" t') for table in tables}


def count(table):
    return int(sql('SELECT count(*) FROM "' + table + '"'))


def state(result, revision=None, pins=None):
    current = result['settings']
    if revision is not None:
        assert current['revision'] == revision, current
    if pins is not None:
        assert current['pinned_repositories'] == pins, current
    if current['revision']:
        assert current['changed_by'] == 'captain' and current['updated_at'], current
    else:
        assert current['changed_by'] is None and current['updated_at'] is None, current
    return current


def next_save(key, pins):
    return replace(request(state(show())['revision'], key, pins))


@contextmanager
def locked(statement):
    """Hold a real PostgreSQL transaction lock until the context exits."""
    process = subprocess.Popen([os.environ['FIXTURE_PSQL'], '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        process.stdin.write("BEGIN; " + statement + "; SELECT 'fixture-lock-ready';\n")
        process.stdin.flush()
        while process.stdout.readline().strip() != 'fixture-lock-ready':
            assert process.poll() is None, process.stderr.read()
        yield process
    finally:
        if process.poll() is None:
            process.stdin.write('COMMIT;\n')
            process.stdin.flush()
            process.stdin.close()
            assert process.wait(timeout=10) == 0, process.stderr.read()


def waiting(futures, *, pattern='pg_advisory_xact_lock', count_waiters=1):
    deadline = time.monotonic() + 15
    while int(sql("SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() "
                  "AND wait_event_type='Lock' AND query LIKE " + quote('%' + pattern + '%'))) < count_waiters:
        assert time.monotonic() < deadline and not any(f.done() for f in futures), \
            ('Expected real blocked PostgreSQL caller', pattern, [f.done() for f in futures])
        time.sleep(0.025)


@contextmanager
def rejected_receipt():
    """Fail after config/audit writes, before receipt commit. No product hooks."""
    sql("CREATE FUNCTION branch_pin_fixture_reject_receipt() RETURNS trigger LANGUAGE plpgsql "
        "AS $$ BEGIN RAISE EXCEPTION 'fixture receipt insertion failure'; END $$; "
        "CREATE TRIGGER branch_pin_fixture_receipt_failure BEFORE INSERT ON branch_flow_receipts "
        "FOR EACH ROW EXECUTE FUNCTION branch_pin_fixture_reject_receipt();")
    try:
        yield
    finally:
        sql('DROP TRIGGER branch_pin_fixture_receipt_failure ON branch_flow_receipts; '
            'DROP FUNCTION branch_pin_fixture_reject_receipt();')



@contextmanager
def delayed_receipt():
    """A real last-write wait proves the final authority fence rolls back audit."""
    sql("CREATE FUNCTION branch_pin_fixture_delay_receipt() RETURNS trigger LANGUAGE plpgsql "
        "AS $$ BEGIN PERFORM pg_advisory_xact_lock(1853999); RETURN NEW; END $$; "
        "CREATE TRIGGER branch_pin_fixture_receipt_delay BEFORE INSERT ON branch_flow_receipts "
        "FOR EACH ROW EXECUTE FUNCTION branch_pin_fixture_delay_receipt();")
    try:
        yield
    finally:
        sql('DROP TRIGGER branch_pin_fixture_receipt_delay ON branch_flow_receipts; '
            'DROP FUNCTION branch_pin_fixture_delay_receipt();')


def verify_validation():
    base = request(0, 'validation', [A])
    invalid = [None, [], 'settings', {}, {'revision': 0}]
    invalid += [{key: val for key, val in base.items() if key != absent} for absent in base]
    invalid += [dict(base, **{field: val}) for field, val in [
        ('actor', 'spoof'), ('changed_by', 'spoof'), ('enabled', True),
        ('roles', {}), ('integration_branch', 'main'), ('availability', {})]]
    invalid += [dict(base, revision=val) for val in [None, True, -1, 0.1, '0', 2147483647, 10**30]]
    invalid += [dict(base, idempotency_key=val) for val in
                [None, 1, '', ' ', ' padded', 'padded ', 'x' * 129, 'é' * 65,
                 'line\nbreak', 'nul\x00key', 'del\x7fkey', 'c1\x85key', 'format\u200bkey']]
    invalid += [dict(base, pinned_repositories=val) for val in
                [None, {}, '', [None], [1], [A, A], [A, 'PINS/alpha'], ['PINS/alpha'],
                 [' ' + A], [A + ' '], ['https://github.com/' + A], ['pins/*'],
                 ['pins'], ['pins/a/b'], ['pins/..'], ['pins/\nrepo'],
                 ['pins/' + 'a' * 300], [A, B, C, D, E, TERMINAL]]]
    before = rows()
    expression = ('Enum.map(' + params_expr(invalid) + ', fn data -> ' +
                  outcome(SERVICE + '.replace(' + params_expr(capability()) + ', data)') + ' end)')
    results = value(expression)
    assert len(results) == len(invalid)
    for data, result in zip(invalid, results):
        assert result.get('error') == 'invalid_input', (data, result)
    assert rows() == before, 'Validation wrote config, receipt or audit'
    for ineligible in [DISABLED, 'branchflow/queued', 'branchflow/ignored', 'pins/missing']:
        result = replace(request(0, 'unknown-' + ineligible.replace('/', '-'), [ineligible]), expected=None)
        assert result.get('error') == 'invalid_input', (ineligible, result)
    assert rows() == before
    for cap in [{}, {'role': 'captain'}, {'proof': 'f' * 64, 'expires': 2**31},
                capability(expires=-1), {'proof': CAPTAIN, 'expires': 2**31}]:
        show(cap=cap, expected='forbidden')
        replace(base, cap=cap, expected='forbidden')
        reconcile(base, cap=cap, expected='forbidden')
    assert rows() == before, 'Forged capability mutated settings'


def verify_cas_and_receipts():
    for label, revision in [('first', 0), ('existing', 1)]:
        before = rows()
        old_history = count(TABLES[1])
        old_receipts = count(TABLES[2])
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            with locked('SELECT pg_advisory_xact_lock(' + str(CONFIG_LOCK) + ')'):
                futures = [pool.submit(replace, request(revision, label + '-' + str(i), [repo]),
                                       expected=None) for i, repo in enumerate([A, B])]
                waiting(futures, count_waiters=2)
            results = [future.result(timeout=30) for future in futures]
        assert sorted('ok' if 'ok' in result else result['error'] for result in results) == ['conflict', 'ok'], results
        winner = next(result['ok'] for result in results if 'ok' in result)
        assert state(winner, revision + 1) == state(show())
        assert winner['replayed'] is False
        assert count(TABLES[1]) == old_history + 1 and count(TABLES[2]) == old_receipts + 1
        assert rows() != before
    original_request = request(2, 'ordered-original', [B, A])
    original = replace(original_request)
    state(original, 3, [B, A])
    before = rows()
    assert replace(original_request) == dict(original, replayed=True)
    replace(dict(original_request, pinned_repositories=[A, B]), expected='conflict')
    replace(dict(original_request, revision=3), expected='conflict')
    replace(request(2, 'stale-new-key', [C]), expected='conflict')
    assert rows() == before
    assert sql("SELECT provenance->>'agent' FROM branch_flow_configuration_versions "
               "WHERE version_source_id='branch-flow' ORDER BY version_inserted_at DESC LIMIT 1") == 'captain'
    latest = next_save('later-editor', [C])
    before = rows()
    assert replace(original_request) == dict(original, replayed=True), 'Replay substituted current settings'
    recovered = reconcile(original_request)
    assert recovered['status'] == 'committed' and recovered['replayed'] is True, recovered
    assert recovered['committed_settings'] == original['settings'], recovered
    assert recovered['settings'] == latest['settings'], recovered
    assert recovered['committed_settings']['revision'] < recovered['settings']['revision']
    missing = request(latest['settings']['revision'], 'not-yet-sent', [D])
    safe = reconcile(missing)
    assert safe['status'] == 'retry_safe' and safe['committed_settings'] is None, safe
    stale = reconcile(dict(missing, revision=0))
    assert stale['status'] == 'conflict' and stale['committed_settings'] is None, stale
    reconcile(dict(original_request, pinned_repositories=[E]), expected='conflict')
    assert rows() == before, 'Reconciliation changed persistent evidence'
    identical = request(latest['settings']['revision'], 'simultaneous-identical', [D, C])
    old_history, old_receipts = count(TABLES[1]), count(TABLES[2])
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        with locked('SELECT pg_advisory_xact_lock(' + str(CONFIG_LOCK) + ')'):
            futures = [pool.submit(replace, identical) for _ in range(2)]
            waiting(futures, count_waiters=2)
        results = [future.result(timeout=30) for future in futures]
    assert sorted(result['replayed'] for result in results) == [False, True]
    assert results[0]['settings'] == results[1]['settings']
    assert count(TABLES[1]) == old_history + 1 and count(TABLES[2]) == old_receipts + 1
    # Simulate a committed response that the caller never consumes. Read-only
    # reconciliation must recover it exactly even when a later writer has won.
    lost = request(state(show())['revision'], 'lost-accepted-response', [E, D])
    replace(lost)
    intervening = next_save('after-lost-response', [A])
    before = rows()
    result = reconcile(lost)
    assert result['status'] == 'committed'
    assert result['committed_settings']['pinned_repositories'] == [E, D]
    assert result['settings'] == intervening['settings']
    assert rows() == before


def verify_authority_custody():
    # Block both before capability recheck (advisory lock) and after it
    # (eligibility table read). Authority must still be current at the write.
    for boundary, statement, pattern in [
        ('config', 'SELECT pg_advisory_xact_lock(' + str(CONFIG_LOCK) + ')', 'pg_advisory_xact_lock'),
        ('inventory', 'LOCK TABLE delivery_poll_states IN ACCESS EXCLUSIVE MODE', 'delivery_poll_states'),
    ]:
        for change in ['expires', 'rotates']:
            before = rows()
            data = request(state(show())['revision'], boundary + '-' + change, [A])
            cap = capability(expires=4 if change == 'expires' else None)
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                try:
                    with locked(statement):
                        writer = pool.submit(replace, data, cap=cap, expected='forbidden')
                        waiting([writer], pattern=pattern)
                        if change == 'expires':
                            while time.time() <= cap['expires']:
                                time.sleep(0.05)
                        else:
                            rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(ROTATED) + ')')
                        assert not writer.done(), 'Writer escaped the deliberately held lock'
                    writer.result(timeout=30)
                finally:
                    rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
            assert rows() == before, (boundary, change, 'Unauthorized partial write')


    with delayed_receipt():
        for change in ['expires', 'rotates']:
            before = rows()
            data = request(state(show())['revision'], 'receipt-wait-' + change, [A])
            cap = capability(expires=4 if change == 'expires' else None)
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                try:
                    with locked('SELECT pg_advisory_xact_lock(1853999)'):
                        writer = pool.submit(replace, data, cap=cap, expected='forbidden')
                        waiting([writer], pattern='branch_flow_receipts')
                        if change == 'expires':
                            while time.time() <= cap['expires']:
                                time.sleep(0.05)
                        else:
                            rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(ROTATED) + ')')
                        assert not writer.done()
                    writer.result(timeout=30)
                finally:
                    rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
            assert rows() == before, (change, 'Capability expired/rotated during receipt insertion committed audit')


def verify_rollback_and_reconcile():
    data = request(state(show())['revision'], 'receipt-failure', [C, B])
    before = rows()
    with rejected_receipt():
        failed = replace(data, expected=None)
        assert failed.get('error') == 'unavailable', failed
    assert rows() == before, 'Receipt failure partially committed config, version or action event'
    assert reconcile(data)['status'] == 'retry_safe'
    assert rows() == before
    accepted = replace(data)
    assert accepted['settings']['revision'] == data['revision'] + 1
    before = rows()
    # Reconciliation failure may neither claim success nor quietly retry a write.
    sql('ALTER TABLE branch_flow_receipts RENAME TO branch_pin_fixture_missing_receipts')
    try:
        failed = reconcile(data, expected=None)
        assert failed.get('error') == 'unavailable', failed
    finally:
        sql('ALTER TABLE branch_pin_fixture_missing_receipts RENAME TO branch_flow_receipts')
    assert rows() == before
    assert reconcile(data)['committed_settings'] == accepted['settings']
    next_save('k' * 128, [A, B, C, D, E])
    next_save('é' * 64, [])


def card_repositories(data):
    return [card['repository'] for card in data['cards']]


def verify_projection():
    # Pins occupy the front, overlap is excluded, and remaining positions use
    # full-inventory open counts rather than the selected table or chooser page.
    for pins, expected in [([], [A, B, C, D, E]),
                           ([E, B], [E, B, A, C, D]),
                           ([TERMINAL, UNKNOWN, OLDEST_REPO, C, A],
                            [TERMINAL, UNKNOWN, OLDEST_REPO, C, A])]:
        saved = next_save('ranking-' + str(len(pins)), pins)
        before = rows()
        data = projection()
        assert card_repositories(data) == expected, data['cards']
        assert data['ranked_repositories'] == expected
        assert data['settings_revision'] == saved['settings']['revision']
        assert len(data['cards']) == 5 and sum(len(card['relations']) for card in data['cards']) <= 15
        assert len(data['chooser']['repositories']) == 20
        assert len(data['table']['prs']) <= 20 and len(data['attention']['runs']) == 10
        assert data['attention']['enabled'] is False
        selected = projection({'repo': TERMINAL, 'chooser_q': 'chooser/repo'})
        assert card_repositories(selected) == expected
        assert selected['inventory_count'] == data['inventory_count']
        assert len(selected['chooser']['repositories']) == 20
        assert data['attention']['oldest']['repository'] == OLDEST_REPO
        assert rows() == before, 'Projection materialized or repaired configuration'
    saved = next_save('unknown-pin-retained', [UNKNOWN, E])
    held = card_repositories(projection())
    sql('UPDATE delivery_poll_states SET enabled=false WHERE id=' + quote(identity(UNKNOWN, 1)))
    before = rows()
    latest = show()
    assert state(latest) == saved['settings'], 'Read silently removed an unavailable pin'
    assert latest['availability'][UNKNOWN] is False
    assert card_repositories(projection()) == [E, A, B, C, D]
    unavailable = replace(request(saved['settings']['revision'], 'unknown-still-selected', [UNKNOWN, E]), expected=None)
    assert unavailable.get('error') == 'invalid_input', unavailable
    assert rows() == before
    # Existing card custody retains the explicit placeholder until Apply.
    data = value('case Agentboard.Delivery.BranchFlow.list(%{}, card_repositories: ' +
                 params_expr(held) + ') do {:ok, result} -> result end')
    assert card_repositories(data) == held
    assert data['cards'][0]['repository'] == UNKNOWN and data['cards'][0]['available'] is False
    assert data['ranked_repositories'] == [E, A, B, C, D]
    assert rows() == before
    repaired = next_save('explicit-pin-repair', [E])
    assert state(repaired)['pinned_repositories'] == [E]
    # Renaming/unavailability is exact local identity; no similar repository is
    # inferred to inherit the old pin.
    insert_prs([('pins/unknown-new', 1, {})])
    before = rows()
    assert state(show())['pinned_repositories'] == [E]
    assert rows() == before




def verify_projection_failures_and_snapshot():
    # Settings failure stays distinct from a valid empty configuration. Existing
    # card custody survives; an initial fallback is explicitly degraded.
    prior = state(show())
    held = card_repositories(projection())
    before = rows()
    sql('ALTER TABLE branch_flow_configuration RENAME TO branch_pin_fixture_missing_configuration')
    try:
        data = projection()
        assert data['settings']['available'] is False
        assert data['settings_revision'] is None and data['settings']['pinned_repositories'] is None
        assert data['settings']['error'] and len(data['cards']) == 5
        assert len(data['table']['prs']) == 20 and data['table']['error'] is None
        assert len(data['attention']['runs']) == 10 and data['attention']['error'] is None
        assert data['attention']['oldest']['repository'] == OLDEST_REPO
        assert data['attention']['total'] == 11
        retained = value('case Agentboard.Delivery.BranchFlow.list(%{}, card_repositories: ' +
                         params_expr(held) + ') do {:ok, result} -> result end')
        assert card_repositories(retained) == retained['ranked_repositories'] == held
        assert len(retained['table']['prs']) == 20 and retained['table']['error'] is None
        assert len(retained['attention']['runs']) == 10
        assert retained['attention']['oldest']['repository'] == OLDEST_REPO
        view = BranchView()
        assert 'pin order unavailable' in view.dom.text.lower()
        view.close()
    finally:
        sql('ALTER TABLE branch_pin_fixture_missing_configuration RENAME TO branch_flow_configuration')
    assert rows() == before and state(show()) == prior

    # Only the aggregate red-count dependency is broken: eligibility remains
    # readable, so eligible pins still precede bounded alphabetical fallback.
    sql('ALTER TABLE delivery_workflow_runs RENAME COLUMN failed_at TO branch_pin_fixture_failed_at')
    try:
        data = projection()
        assert data['settings']['available'] is True and data['settings_revision'] == prior['revision']
        assert data['inventory']['error'] and data['inventory_count'] is None
        assert card_repositories(data) == [E, OLDEST_REPO, 'chooser/repo-00', 'chooser/repo-01', 'chooser/repo-02']
        assert all(card['counts_available'] is False for card in data['cards'])
        assert len(data['chooser']['repositories']) <= 20 and data['chooser']['error']
    finally:
        sql('ALTER TABLE delivery_workflow_runs RENAME COLUMN branch_pin_fixture_failed_at TO failed_at')
    assert rows() == before

    # Hold rich projection expansion after its repeatable-read snapshot exists.
    # A fully audited concurrent settings save can commit while the read waits;
    # that read must keep its old revision and card order all the way through.
    cap = capability()
    with concurrent.futures.ThreadPoolExecutor(1) as pool:
        with locked('LOCK TABLE delivery_ci_snapshots IN ACCESS EXCLUSIVE MODE'):
            reader = pool.submit(projection)
            waiting([reader], pattern='delivery_ci_snapshots')
            newer = replace(request(prior['revision'], 'snapshot-concurrent-writer', [B, E]), cap=cap)
        old_snapshot = reader.result(timeout=30)
    assert old_snapshot['settings_revision'] == prior['revision']
    assert card_repositories(old_snapshot) == held
    assert old_snapshot['settings']['pinned_repositories'] == prior['pinned_repositories']
    fresh = projection()
    assert fresh['settings_revision'] == newer['settings']['revision']
    assert card_repositories(fresh) == [B, E, A, C, D]
    next_save('snapshot-fixture-restored', [E])


def settings_cookie():
    jar = http.cookiejar.CookieJar()
    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    with browser.open(URL + '/settings', timeout=20) as response:
        page = Page()
        page.feed(response.read().decode())
    with browser.open(urllib.request.Request(URL + '/settings/unlock', data=urllib.parse.urlencode(
            {'token': CAPTAIN, '_csrf_token': page.csrf}).encode()), timeout=20) as response:
        assert response.status == 200
    return '; '.join(cookie.name + '=' + cookie.value for cookie in jar)


class SettingsView(RenderedView):
    def __init__(self, cookie=''):
        super().__init__(URL, '/settings', cookie)

    @property
    def dom(self):
        return Document(self.document).root

    @property
    def pins(self):
        return attr_values(self.dom, 'data-selected-pin')

    @property
    def editor(self):
        return self.dom.find('id', 'branch-flow-pin-editor').attributes

    def event(self, event, values=None):
        # The actual pinned LiveView SDK's extractMeta includes HTMLButtonElement
        # value (empty here), and the checkbox's explicitly rendered value ''. It omits value
        # for an unchecked checkbox. Keep the protocol fixture browser-realistic.
        values = dict(values or {})
        if event == 'set_branch_flow_pin':
            if values.get('selected') == 'true':
                values['value'] = ''
        else:
            values['value'] = ''
        self.request('event', {'type': 'click', 'event': event, 'value': values})
        return self.dom

    def search(self, query):
        self.request('event', {'type': 'form', 'event': 'search_branch_flow_pins',
                              'value': urllib.parse.urlencode({'chooser_q': query})})
        return self.dom

    def select(self, repository, selected=True):
        return self.event('set_branch_flow_pin', {'repository': repository,
                                                  'selected': str(selected).lower()})


def verify_liveview():
    before = rows()
    public = SettingsView()
    assert not public.dom.findall('id', 'branch-flow-open')
    for event, params in [('open_branch_flow_settings', {}),
                          ('set_branch_flow_pin', {'repository': A, 'selected': 'true'}),
                          ('save_branch_flow_pins', {}), ('reconcile_branch_flow_pins', {})]:
        public.event(event, params)
        assert not public.dom.findall('id', 'branch-flow-pin-editor')
    assert 'Captain access required' in public.document
    public.close()
    assert rows() == before

    cookie = settings_cookie()
    ui = SettingsView(cookie)
    assert ui.dom.findall('id', 'branch-flow-open')
    ui.event('open_branch_flow_settings')
    loaded = state(show())
    assert ui.pins == loaded['pinned_repositories'] == [E]
    assert ui.editor['data-state'] == 'editing' and ui.editor['data-dirty'] == 'false'
    assert int(ui.editor['data-revision']) == loaded['revision']
    assert len(attr_values(ui.dom, 'data-chooser-repository')) == 20
    # Authority, revision and key never come from event parameters, including
    # checkbox/control events that otherwise look valid.
    before = rows()
    for forged in [{'actor': 'spoof'}, {'changed_by': 'spoof'}, {'revision': '0'},
                   {'idempotency_key': 'browser-supplied'}, {'pinned_repositories': [A]}]:
        ui.event('save_branch_flow_pins', forged)
        assert ui.pins == [E]
        assert 'server-held' in ui.document
    ui.event('set_branch_flow_pin', {'repository': A, 'selected': 'true', 'actor': 'captain'})
    assert ui.pins == [E] and rows() == before

    # Selection and ordering survive real chooser paging. A repeated checkbox
    # request is idempotent, and an off-page or sixth repository cannot sneak in.
    ui.search('chooser/repo')
    assert len(attr_values(ui.dom, 'data-chooser-repository')) == 20
    ui.select('chooser/repo-00')
    ui.event('page_branch_flow_pins', {'direction': 'next'})
    assert len(attr_values(ui.dom, 'data-chooser-repository')) == 5
    ui.select('chooser/repo-20')
    ui.select('chooser/repo-20')
    assert ui.pins == [E, 'chooser/repo-00', 'chooser/repo-20']
    ui.select(A)
    assert ui.pins == [E, 'chooser/repo-00', 'chooser/repo-20']
    ui.search('pins/')
    ui.select(A)
    ui.select(B)
    five = [E, 'chooser/repo-00', 'chooser/repo-20', A, B]
    assert ui.pins == five
    ui.select(C)
    assert ui.pins == five and 'at most five' in ui.document
    assert len(set(ui.pins)) == 5
    first = ui.dom.find('data-selected-pin', E)
    last = ui.dom.find('data-selected-pin', B)
    assert 'disabled' in first.find('aria-label', 'Move ' + E + ' up').attributes
    assert 'disabled' in last.find('aria-label', 'Move ' + B + ' down').attributes
    ui.event('move_branch_flow_pin', {'repository': A, 'direction': 'up'})
    assert ui.pins == [E, 'chooser/repo-00', A, 'chooser/repo-20', B]
    ui.event('remove_branch_flow_pin', {'repository': B})
    ui.select(C)
    assert ui.pins[-1] == C and len(ui.pins) == 5
    draft = ui.pins
    assert ui.editor['data-dirty'] == 'true'
    ui.event('close_branch_flow_pins')
    assert ui.dom.findall('id', 'branch-flow-discard-confirmation') and ui.pins == draft
    ui.event('cancel_branch_flow_discard')
    assert not ui.dom.findall('id', 'branch-flow-discard-confirmation') and ui.pins == draft
    ui.event('reload_branch_flow_pins')
    assert ui.dom.findall('id', 'branch-flow-discard-confirmation') and ui.pins == draft
    ui.event('cancel_branch_flow_discard')
    assert rows() == before, 'Search, paging, reorder or dirty-dismiss prompt autosaved'
    snapshot(ui, 'branch-flow-pin-editor-dirty')
    ui.event('close_branch_flow_pins')
    ui.event('confirm_branch_flow_discard')
    assert not ui.dom.findall('id', 'branch-flow-pin-editor') and rows() == before

    ui.event('open_branch_flow_settings')
    ui.search('pins/')
    ui.event('remove_branch_flow_pin', {'repository': E})
    ui.select(B)
    ui.select(A)
    ui.event('move_branch_flow_pin', {'repository': A, 'direction': 'up'})
    assert ui.pins == [A, B]
    ui.event('save_branch_flow_pins', {'revision': str(loaded['revision'] + 99)})
    assert rows() == before and ui.pins == [A, B]
    ui.event('save_branch_flow_pins')
    current = state(show(), loaded['revision'] + 1, [A, B])
    assert ui.editor['data-state'] == 'saved' and ui.editor['data-dirty'] == 'false'
    assert int(ui.editor['data-revision']) == current['revision']
    assert f'committed at revision {current["revision"]}' in ui.dom.text
    accepted_rows = rows()
    ui.event('save_branch_flow_pins')
    ui.event('set_branch_flow_pin', {'repository': C, 'selected': 'true'})
    assert ui.pins == [A, B] and rows() == accepted_rows, 'Queued submit/change wrote after confirmation'
    receipt = json.loads(sql("SELECT request::text FROM branch_flow_receipts ORDER BY created_at DESC LIMIT 1"))
    assert set(receipt) == {'revision', 'idempotency_key', 'pinned_repositories'}
    assert receipt['revision'] == loaded['revision'] and receipt['pinned_repositories'] == [A, B]
    assert receipt['idempotency_key'] != 'browser-supplied'
    ui.event('close_branch_flow_pins')
    ui.event('open_branch_flow_settings')
    ui.event('remove_branch_flow_pin', {'repository': B})
    original_revision = int(ui.editor['data-revision'])
    latest = next_save('ui-intervening-captain', [C])
    before = rows()
    ui.event('save_branch_flow_pins')
    assert ui.editor['data-state'] == 'conflict' and ui.pins == [A]
    assert int(ui.editor['data-revision']) == original_revision
    assert rows() == before and state(show()) == latest['settings']
    ui.event('reload_branch_flow_pins')
    assert ui.dom.findall('id', 'branch-flow-discard-confirmation') and ui.pins == [A]
    ui.event('confirm_branch_flow_discard')
    assert ui.pins == [C] and ui.editor['data-state'] == 'editing'
    assert int(ui.editor['data-revision']) == latest['settings']['revision']

    # A real SQL error at the last atomic write produces uncertainty. Controls
    # freeze the exact draft, read-only reconciliation does not retry, and only
    # an explicit same-request retry can create the next revision.
    ui.search('pins/')
    ui.select(D)
    submitted_revision = int(ui.editor['data-revision'])
    before = rows()
    with rejected_receipt():
        ui.event('save_branch_flow_pins')
    assert ui.editor['data-state'] == 'uncertain' and ui.pins == [C, D]
    assert rows() == before
    ui.event('remove_branch_flow_pin', {'repository': C})
    ui.event('save_branch_flow_pins')
    assert ui.pins == [C, D] and rows() == before
    sql('ALTER TABLE branch_flow_receipts RENAME TO branch_pin_fixture_missing_receipts')
    try:
        ui.event('reconcile_branch_flow_pins')
        assert ui.editor['data-state'] == 'uncertain' and ui.pins == [C, D]
        ui.event('reload_branch_flow_pins')
        assert ui.editor['data-state'] == 'uncertain' and ui.pins == [C, D]
    finally:
        sql('ALTER TABLE branch_pin_fixture_missing_receipts RENAME TO branch_flow_receipts')
    assert rows() == before
    ui.event('reconcile_branch_flow_pins')
    assert ui.editor['data-state'] == 'retry_ready' and ui.pins == [C, D]
    assert rows() == before, 'Reconcile retried an uncommitted save'
    ui.event('retry_branch_flow_pins')
    current = state(show(), submitted_revision + 1, [C, D])
    assert ui.editor['data-state'] == 'saved'
    accepted_rows = rows()
    ui.event('retry_branch_flow_pins')
    assert rows() == accepted_rows

    # The same uncertain/no-receipt result becomes a conflict when another
    # captain commits. It must retain this draft rather than attach a new key.
    ui.event('reload_branch_flow_pins')
    ui.event('remove_branch_flow_pin', {'repository': D})
    submitted_revision = int(ui.editor['data-revision'])
    with rejected_receipt():
        ui.event('save_branch_flow_pins')
    assert ui.editor['data-state'] == 'uncertain'
    next_save('ui-advanced-while-uncertain', [E])
    before = rows()
    ui.event('reconcile_branch_flow_pins')
    assert ui.editor['data-state'] == 'conflict' and ui.pins == [C]
    assert int(ui.editor['data-revision']) == submitted_revision and rows() == before
    ui.event('reload_branch_flow_pins')
    ui.event('confirm_branch_flow_discard')
    assert ui.pins == [E]

    # Persist an eligible exact identity, then remove its local eligibility.
    # Settings displays it unchanged and requires an explicit repair.
    sql('UPDATE delivery_poll_states SET enabled=true WHERE id=' + quote(identity(UNKNOWN, 1)))
    next_save('ui-pin-before-disappearance', [UNKNOWN, E])
    sql('UPDATE delivery_poll_states SET enabled=false WHERE id=' + quote(identity(UNKNOWN, 1)))
    ui.event('reload_branch_flow_pins')
    assert ui.pins == [UNKNOWN, E] and 'Unavailable saved pin' in ui.document
    before = rows()
    ui.event('remove_branch_flow_pin', {'repository': E})
    ui.event('save_branch_flow_pins')
    assert rows() == before and ui.pins == [UNKNOWN]
    ui.event('remove_branch_flow_pin', {'repository': UNKNOWN})
    ui.event('save_branch_flow_pins')
    state(show(), pins=[])
    assert ui.editor['data-state'] == 'saved'

    # A failed settings load is visibly unavailable, never a fabricated empty
    # configuration. Reconnecting discards only the unsaved local draft.
    ui.event('close_branch_flow_pins')
    before = rows()
    sql('ALTER TABLE branch_flow_configuration RENAME TO branch_pin_fixture_missing_configuration')
    try:
        ui.event('open_branch_flow_settings')
        assert not ui.dom.findall('id', 'branch-flow-pin-editor')
        assert 'not an empty pin list' in ui.document
    finally:
        sql('ALTER TABLE branch_pin_fixture_missing_configuration RENAME TO branch_flow_configuration')
    assert rows() == before
    ui.event('open_branch_flow_settings')
    ui.search('pins/')
    ui.select(A)
    assert ui.pins == [A] and ui.editor['data-dirty'] == 'true'
    ui.close()
    assert rows() == before, 'Disconnect autosaved a draft'
    ui = SettingsView(cookie)
    assert not ui.dom.findall('id', 'branch-flow-pin-editor')
    ui.event('open_branch_flow_settings')
    assert ui.pins == [] and ui.editor['data-dirty'] == 'false'
    assert rows() == before
    # Already-open signed captain session loses authority after real rotation.
    rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(ROTATED) + ')')
    try:
        ui.event('save_branch_flow_pins')
        assert not ui.dom.findall('id', 'branch-flow-pin-editor')
        assert 'Captain access required' in ui.document and rows() == before
    finally:
        rpc('Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + ')')
        ui.close()


def verify_immutable_evidence():
    for table, assignment in [('branch_flow_configuration_versions', 'provenance=provenance'),
                              ('branch_flow_receipts', 'idempotency_key=idempotency_key')]:
        before = rows([table])
        assert count(table) > 0
        for statement in ['UPDATE "' + table + '" SET ' + assignment,
                          'DELETE FROM "' + table + '"', 'TRUNCATE "' + table + '"']:
            result = subprocess.run([os.environ['FIXTURE_PSQL'], '-X', '-At', '-v',
                                     'ON_ERROR_STOP=1', '-c', statement],
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode != 0, 'Immutable evidence accepted: ' + statement
        assert rows([table]) == before


def run():
    assert urllib.parse.urlparse(URL).hostname in ('127.0.0.1', 'localhost')
    assert sql("SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls "
               "FROM pg_roles WHERE rolname=current_user") == 't', 'Normal DB role required'
    assert count('delivery_pull_requests') == 0, 'Run on a fresh isolated database'
    assert all(count(table) == 0 for table in TABLES), 'Migration backfilled configuration'
    assert value('Application.get_env(:agentboard, :branch_flow_enabled, false)') is False
    rpc(':ok = Supervisor.terminate_child(Agentboard.Supervisor, Oban); '
        'Application.put_env(:agentboard, :captain_token, ' + json.dumps(CAPTAIN) + '); '
        'Application.put_env(:agentboard, :cooperation_enabled, false); '
        'Application.put_env(:agentboard, :pr_observation_enabled, false)')
    before = rows()
    # Existing migrations seed the ci-accountability system identity. Settings
    # must preserve the full initial roster without enrolling a captain actor.
    initial_agents = rows(['agents'])
    assert sql("SELECT count(*) FROM agents WHERE id='captain'") == '0'
    state(show(), 0, [])
    assert rows() == before, 'Empty read materialized config or audit'
    assert rows(['agents']) == initial_agents, 'Captain read registered or changed an actor'
    fixtures = [(repository, n, {}) for repository, size in
                [(A, 9), (B, 8), (C, 7), (D, 6), (E, 5)] for n in range(1, size + 1)]
    fixtures += [(TERMINAL, 1, {'lifecycle': 'merged', 'enabled': False}),
                 (UNKNOWN, 1, {'lifecycle': None}), (DISABLED, 1, {'enabled': False})]
    fixtures += [(f'chooser/repo-{n:02}', 1, {'lifecycle': 'closed', 'enabled': False}) for n in range(25)]
    # canonical_github_pr already rejects uppercase PR identities. Prove that
    # guard without weakening it; the other lowercase malformed paths pass that
    # older DB shape but must still be excluded from the canonical pin inventory.
    uppercase = 'Pins/legacy'
    rejected = subprocess.run([os.environ['FIXTURE_PSQL'], '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c',
        'INSERT INTO delivery_pull_requests (id,owner,repo,number,url,created_at) VALUES (' +
        ','.join(map(quote, [identity(uppercase, 1), 'Pins', 'legacy', '1',
                            'https://github.com/' + uppercase + '/pull/1'])) + ',now())'],
        capture_output=True, text=True, timeout=20)
    assert rejected.returncode != 0 and 'canonical_github_pr' in rejected.stderr, rejected.stderr
    assert count('delivery_pull_requests') == 0
    # Malformed lowercase PR rows retain a deliberately high apparent open
    # count. Their presence cannot outrank real eligible repositories.
    fixtures += [(repository, n, {}) for repository in MALFORMED[1:] for n in range(1, 12)]
    insert_prs(fixtures)
    insert_workflows()
    for n, repository in enumerate(MALFORMED):
        sql('INSERT INTO delivery_workflow_runs '
            '(id,repository,run_id,requested_at,next_poll_at,observed_at,generation,workflow_id,branch,head_sha) '
            'VALUES (' + ','.join(map(quote, ['malformed-legacy-' + str(n), repository, 'legacy-' + str(n)])) +
            ",now(),now()+interval '1 day',now(),1,'legacy','main','" + 'a' * 40 + "')")
    assert value('Agentboard.Delivery.BranchFlow.Inventory.present(' + params_expr(MALFORMED) + ')') == []
    chooser = value('Agentboard.Delivery.BranchFlow.Inventory.chooser()')
    eligible = [row['repository'] for row in chooser['repositories']]
    while chooser['next_cursor']:
        chooser = value('Agentboard.Delivery.BranchFlow.Inventory.chooser(' +
                        params_expr({'chooser_cursor': chooser['next_cursor']}) + ')')
        assert len(chooser['repositories']) <= 20
        eligible += [row['repository'] for row in chooser['repositories']]
    assert not set(MALFORMED).intersection(eligible), eligible
    assert set(eligible) == {A, B, C, D, E, TERMINAL, UNKNOWN, OLDEST_REPO} | {
        f'chooser/repo-{n:02}' for n in range(25)}, eligible
    operational = sql("SELECT tablename FROM pg_tables WHERE schemaname='public' AND "
                      "tablename NOT IN ('schema_migrations','board_schema','board_action_events'," +
                      ','.join(map(quote, TABLES)) + ') ORDER BY tablename').splitlines()
    with tls_provider(UnexpectedProvider) as (provider, ca, _):
        rpc('Application.put_env(:agentboard, :github, [api_url: ' + json.dumps(provider) +
            ', ca_file: ' + json.dumps(ca) + ', token: "invented-pin-fixture"])')
        operational_before = rows(operational)
        verify_validation()
        verify_cas_and_receipts()
        verify_authority_custody()
        verify_rollback_and_reconcile()
        assert rows(operational) == operational_before, 'Settings changed operational rows or enqueued work'
        rpc('Application.put_env(:agentboard, :branch_flow_enabled, true)')
        verify_projection()
        verify_projection_failures_and_snapshot()
        # Projection fixture changes are intentional; subsequent Settings/UI
        # interactions have their own unchanged operational baseline.
        operational_before = rows(operational)
        verify_liveview()
        verify_immutable_evidence()
        assert sql("SELECT updated_at <= clock_timestamp()+interval '1 second' "
                   "AND updated_at >= clock_timestamp()-interval '10 minutes' "
                   "FROM branch_flow_configuration WHERE id='branch-flow'") == 't', \
            'Captain settings timestamp shifted away from the real UTC write instant'
        assert rows(operational) == operational_before, 'Editor changed producer/operational state'
        before = rows()
        rpc('Application.put_env(:agentboard, :branch_flow_enabled, false)')
        assert 'id="default-branch-health"' in get('/prs')
        assert 'id="branch-repositories"' not in get('/prs')
        assert rows() == before, 'Presentation rollback changed retained settings'
        assert rows(['agents']) == initial_agents, 'Settings bootstrapped or changed an identity'
        assert sql("SELECT count(*) FROM agents WHERE id='captain'") == '0'
        assert not provider_requests, provider_requests
        assert int(sql('SELECT version FROM board_schema WHERE id=1')) >= 37
    print('Captain pins: real lock custody/expiry/rotation, first/CAS races, atomic receipt rollback, '
          'immutable replay/history, read-only reconciliation, bounded pin ranking, LiveView '
          'draft/uncertain/discard flows and operational/provider isolation passed')


if __name__ == '__main__':
    run()
