"""Column totals and independent navigation through the real LiveView wire boundary."""
import base64
import re
import urllib.request
from pathlib import Path
import json
import os
import subprocess
from html.parser import HTMLParser
from liveview_client import RenderedView

base = os.environ['AGENTBOARD_URL']
env = dict(os.environ, AGENT_ID='paging-worker', AGENTBOARD_HARNESS='codex', AGENTBOARD_MODEL='fixture')

def ab(*args):
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (args, result.stderr)
    return json.loads(result.stdout)

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

class BoardView(RenderedView):
    def __init__(self, path):
        super().__init__(base, path)
    def read(self):
        return Columns(self.document).columns
    def request(self, event, payload):
        super().request(event, payload)
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
