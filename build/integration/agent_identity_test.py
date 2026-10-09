"""Full IDs and advisory registration across the real CLI, API and LiveView wire."""
import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

from liveview_client import RenderedView

base = os.environ['AGENTBOARD_URL']
owner = 'codex-repo_with_underscores-agent-a'
legacy = 'agent-a'
captain = 'identity-fixture-captain-capability-0123456789'


def ab(actor, *args, warning=False):
    env = dict(os.environ, AGENT_ID=actor, AGENTBOARD_MODEL='fixture', AGENTBOARD_HARNESS='codex')
    result = subprocess.run([os.environ['AB_BINARY'], '--json', *args], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (args, result.stderr)
    if warning:
        assert json.loads(result.stderr)['warning']['code'] == 'agent_id_naming', result.stderr
    else:
        assert not result.stderr, result.stderr
    return json.loads(result.stdout)


class Identities(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.links = {}
        self.current = None
        self.in_code = False
        self.feed(document)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'a' and attrs.get('aria-label', '').startswith('View tasks owned by '):
            self.current = attrs['href']
            self.links[self.current] = {'label': attrs['aria-label'], 'text': '', 'class': ''}
        if tag == 'code' and self.current:
            self.in_code = True
            self.links[self.current]['class'] = attrs.get('class', '')

    def handle_endtag(self, tag):
        if tag == 'code':
            self.in_code = False
        if tag == 'a':
            self.current = None

    def handle_data(self, data):
        if self.current and self.in_code:
            self.links[self.current]['text'] += data


def check_identity(document, actor, path='/'):
    href = path + '?' + urllib.parse.urlencode({'owner': actor})
    identity = Identities(document).links[href]
    assert identity['label'] == 'View tasks owned by ' + actor
    assert identity['text'] == actor
    assert 'select-all' in identity['class']
    assert '[overflow-wrap:anywhere]' in identity['class']
    return href


for actor in (owner, legacy):
    registered = ab(actor, 'agent', 'register', '--name', 'Friendly worker', warning=actor == legacy)
    assert registered['agent']['id'] == actor
    assert registered['agent']['harness'] == 'codex'
    shown = ab(actor, 'agent', 'show', actor)['agent']
    assert shown['scope']['state'] == 'unmanaged' and shown['scope']['allowed_repos'] == []

for actor, task in ((owner, 'identity-owned'), (legacy, 'identity-other')):
    ab(actor, 'task', 'create', '--id', task, '--title', 'Identity fixture ' + task, '--repo', 'fixture/actual-repo')
    ab(actor, 'task', 'claim', task)

# The retained legacy registration is not renamed or rejected on refresh either.
assert ab(legacy, 'agent', 'register', warning=True)['agent']['id'] == legacy
roster = RenderedView(base, '/agents')
for actor in (owner, legacy):
    check_identity(roster.document, actor)
assert 'Friendly worker' in roster.document
roster.close()

board = RenderedView(base, '/')
href = check_identity(board.document, owner)
check_identity(board.document, legacy)
# Repeat filter and return navigation through actual LiveView patches. No state
# mutation or identity parsing can turn an owner filter into a repository filter.
for _ in range(2):
    board.request('live_patch', {'url': base + href})
    check_identity(board.document, owner)
    assert 'Identity fixture identity-owned' in board.document
    assert 'Identity fixture identity-other' not in board.document
    assert 'fixture/actual-repo' in board.document
    board.request('live_patch', {'url': base + '/'})
    check_identity(board.document, legacy)
    assert 'Identity fixture identity-other' in board.document
board.close()

# Full reloads of the native anchor target and task detail preserve the ID.
for path in (href, '/tasks/identity-owned'):
    view = RenderedView(base, path)
    check_identity(view.document, owner)
    view.close()

ab(owner, 'task', 'update', 'identity-owned', '--status', 'done', '--body', 'Synthetic completion')
completed = RenderedView(base, href)
check_identity(completed.document, owner)
assert 'completed-identity-owned' in completed.document
completed.close()
rpc = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc',
                      f'Application.put_env(:agentboard, :captain_token, {json.dumps(captain)})'],
                     capture_output=True, text=True, timeout=30)
assert rpc.returncode == 0, (rpc.stdout, rpc.stderr)
request = urllib.request.Request(base + '/api/v1/tasks/identity-owned/archive',
                                 data=b'{"revision":0}', headers={
                                     'Content-Type': 'application/json', 'Authorization': 'Bearer ' + captain})
with urllib.request.urlopen(request, timeout=15) as response:
    assert response.status == 200
for path in ('/archive', '/archive?' + urllib.parse.urlencode({'owner': owner}), '/tasks/identity-owned'):
    view = RenderedView(base, path)
    check_identity(view.document, owner, '/archive')
    view.close()

# Verify the deployed CSS includes the actual selection and wrap utilities.
with urllib.request.urlopen(base + '/agents', timeout=15) as response:
    layout = response.read().decode()
css_paths = re.findall(r'<link[^>]*href="([^"]+\.css[^"]*)"', layout)
assert css_paths
styles = []
for path in css_paths:
    with urllib.request.urlopen(base + path, timeout=15) as response:
        styles.append(response.read().decode())
css = '\n'.join(styles)
assert 'user-select:all' in css and 'overflow-wrap:anywhere' in css
output = Path(os.environ['TEST_UNDECLARED_OUTPUTS_DIR'])
output.mkdir(parents=True, exist_ok=True)
(output / 'agent-identity-roster.html').write_text(
    '<!doctype html><html lang="en"><meta charset="utf-8"><title>Agent identity fixture</title>'
    '<style>' + css + '</style><body>' + roster.document + '</body></html>')
print('Agent identity warnings, exact JSON IDs, unmanaged scopes, full selectable links, repeated owner navigation, task detail and archive routes passed')
