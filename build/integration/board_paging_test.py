"""Column totals and independent navigation through the real LiveView wire boundary."""
import base64
import copy
import re
import urllib.request
from pathlib import Path
import json
import os
import subprocess
from html.parser import HTMLParser
from liveview_client import LiveView

base = os.environ['AGENTBOARD_URL']
env = dict(os.environ, AGENT_ID='paging-worker', AGENTBOARD_HARNESS='codex', AGENTBOARD_MODEL='fixture')

def ab(*args):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (args, result.stderr)
    return json.loads(result.stdout)

# Decode the pinned Phoenix 1.1 rendered wire protocol, not implementation source.
# Static templates and keyed patches follow the upstream Rendered consumer:
# https://github.com/phoenixframework/phoenix_live_view/blob/v1.1.33/assets/js/phoenix_live_view/rendered.js
# No application behavior (filtering, counts or navigation) is simulated here.
def merge(target, source):
    if not isinstance(source, dict) or 's' in source:
        return copy.deepcopy(source)
    result = copy.deepcopy(target)
    if 'k' in source:
        old = copy.deepcopy(result.get('k', {}))
        count = source['k']['kc']
        entries = result.setdefault('k', {})
        for key, item in source['k'].items():
            if key == 'kc':
                continue
            if isinstance(item, list):
                entries[key] = merge(old[str(item[0])], item[1])
            elif isinstance(item, int):
                entries[key] = copy.deepcopy(old[str(item)])
            else:
                entries[key] = merge(entries.get(key, {}), item)
        result['k'] = {str(i): entries[str(i)] for i in range(count)} | {'kc': count}
    for key, value in source.items():
        if key != 'k':
            result[key] = merge(result.get(key, {}), value) if isinstance(value, dict) else copy.deepcopy(value)
    return result

def html(node, templates=None):
    if isinstance(node, str):
        return node
    assert isinstance(node, dict), ('Unsupported rendered value', node)
    templates = node.get('p', templates)
    statics = node['s']
    if isinstance(statics, int):
        statics = templates[str(statics)]
        node['s'] = statics
    if 'k' in node:
        rows = [node['k'][str(i)] for i in range(node['k']['kc'])]
    else:
        rows = [node]
    output = ''
    for row in rows:
        output += statics[0]
        for i, text in enumerate(statics[1:]):
            output += html(row[str(i)], templates) + text
    node.pop('p', None)
    return output

class Columns(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.columns = {}
        self.current = None
        self.counting = False
        self.feed(document)
    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == 'section' and attributes.get('class') == 'column':
            self.current = attributes['aria-label']
            self.columns[self.current] = {'ids': [], 'buttons': {}, 'total': None}
        if not self.current:
            return
        if tag == 'span' and attributes.get('class') == 'count':
            self.counting = True
        if tag == 'a' and attributes.get('href', '').startswith('/tasks/'):
            self.columns[self.current]['ids'].append(attributes['href'].removeprefix('/tasks/'))
        if tag == 'button' and attributes.get('phx-click') == 'column_page':
            self.columns[self.current]['buttons'][attributes['phx-value-direction']] = attributes
    def handle_endtag(self, tag):
        if tag == 'section':
            self.current = None
        if tag == 'span':
            self.counting = False
    def handle_data(self, data):
        if self.current and self.counting and data.strip():
            self.columns[self.current]['total'] = int(data.strip())

class BoardView:
    def __init__(self, path):
        self.live = LiveView(base, path)
        self.tree = copy.deepcopy(self.live.initial)
        self.ref = 1
        self.document = html(self.tree)
    def read(self):
        return Columns(self.document).columns
    def request(self, event, payload):
        self.ref += 1
        ref = str(self.ref)
        self.live.send(['1', ref, self.live.topic, event, payload])
        response = self.live.wait(lambda e: e[1] == ref and e[3] == 'phx_reply')
        assert response and response[4]['status'] == 'ok', response
        for received in self.live.events:
            if received[3] == 'diff':
                self.tree = merge(self.tree, received[4])
                self.document = html(self.tree)
        self.live.events.clear()
        diff = response[4]['response'].get('diff', {})
        if diff:
            self.tree = merge(self.tree, diff)
            self.document = html(self.tree)
        assert not any(key in response[4]['response'] for key in ('live_redirect', 'redirect'))
        return self.read()
    def page(self, status, direction):
        return self.request('event', {'type': 'click', 'event': 'column_page',
                                     'value': {'status': status, 'direction': direction}})
    def patch(self, path):
        return self.request('live_patch', {'url': base + path})
    def close(self):
        self.live.close()

ab('agent', 'register')
for status, size in [('done', 41), ('open', 25), ('cancelled', 3)]:
    for i in range(size):
        id = f'paging-{status}-{i:03}'
        ab('task', 'create', '--id', id, '--title', 'Paging fixture ' + id,
           '--repo', 'fixture/paging', '--priority', str(i))
        if status != 'open':
            ab('task', 'claim', id)
            ab('task', 'update', id, '--status', status, '--body', 'Invented terminal fixture')
ab('task', 'create', '--id', 'other-repo', '--title', 'Other repo', '--repo', 'fixture/other')
def snapshot(view, name):
    with urllib.request.urlopen(base + '/') as response:
        layout = response.read().decode()
    css_paths = re.findall(r'<link[^>]*href="([^"]+\.css[^"]*)"', layout)
    assert css_paths, 'Packaged CSS is missing'
    styles = []
    for path in css_paths:
        with urllib.request.urlopen(base + path) as response:
            styles.append(response.read().decode())
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Agentboard column paging — remote fixture</title><style>' + '\n'.join(styles) + '</style><body>' + view.document + '</body></html>'
    destination = Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR']) / (name + '.html')
    destination.write_text(page)
    print('PAGING_BROWSER_ARTIFACT:' + name + ':' + base64.b64encode(page.encode()).decode())

board = BoardView('/?repo=fixture%2Fpaging')
first = board.read()
assert first['Done']['total'] == 41, ('Header must show total, not 20-card page length', first['Done'])
assert first['Open']['total'] == 25 and first['Cancelled']['total'] == 3
assert first['Done']['ids'] == [f'paging-done-{i:03}' for i in range(20)]
assert len(first) == 7
snapshot(board, 'paging-first')
assert 'disabled' in first['Done']['buttons']['prev']
second = board.page('done', 'next')
assert second['Done']['ids'] == [f'paging-done-{i:03}' for i in range(20, 40)]
assert second['Done']['total'] == 41
assert {k: v for k, v in second.items() if k != 'Done'} == {k: v for k, v in first.items() if k != 'Done'}
snapshot(board, 'paging-done-second')
open_second = board.page('open', 'next')
assert open_second['Open']['ids'] == [f'paging-open-{i:03}' for i in range(20, 25)]
assert open_second['Done'] == second['Done']
last = board.page('done', 'next')
snapshot(board, 'paging-done-last')
assert last['Done']['ids'] == ['paging-done-040'] and 'disabled' in last['Done']['buttons']['next']
assert board.page('done', 'next') == last, 'Exhausted next must be a harmless no-op'
assert board.page('done', 'prev')['Done']['ids'] == second['Done']['ids']
assert board.page('done', 'prev')['Done']['ids'] == first['Done']['ids']
assert board.page('missing', 'next')['Open'] == open_second['Open']
# Filter changes reset every lane; live patches retain the same board connection.
filtered = board.patch('/?repo=fixture%2Fother')
assert filtered['Open']['ids'] == ['other-repo'] and filtered['Done']['total'] == 0
reset = board.patch('/?repo=fixture%2Fpaging&owner=paging-worker')
assert reset['Done']['ids'] == first['Done']['ids'] and reset['Open']['total'] == 0
assert reset['Done']['total'] == 41
board.close()
print('True filtered totals, independent Prev/Next, harmless invalid events and filter resets passed')
