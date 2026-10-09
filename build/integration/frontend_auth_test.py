"""Packaged HTTP/WebSocket authentication using disposable JOSE-generated keys.

The local fixture terminates HTTP itself, so Secure cookies are intentionally
forwarded by this test client. Production cookie security is asserted, never
disabled. No Cloudflare account, network key lookup or real credential is used.
"""
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie

from liveview_client import LiveView, Page, contains

BASE = os.environ['AGENTBOARD_URL']
CAPTAIN = 'frontend-fixture-captain-0123456789'


def rpc(expression):
    result = subprocess.run(
        [os.environ['AGENTBOARD_BIN'], 'rpc', expression],
        capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, ('Fixture RPC failed', result.stderr[-1000:])
    return result.stdout


def rpc_json(expression):
    output = rpc('value = (' + expression + '); IO.puts("FRONTEND_FIXTURE_JSON=" <> Jason.encode!(value))')
    return json.loads(next(line.split('=', 1)[1] for line in output.splitlines()
                           if line.startswith('FRONTEND_FIXTURE_JSON=')))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def request(path='/', assertion=None, cookie='', data=None, extra_headers=None):
    headers = dict(extra_headers or {})
    if assertion is not None:
        headers['Cf-Access-Jwt-Assertion'] = assertion
    if cookie:
        headers['Cookie'] = cookie
    encoded = None
    if data is not None:
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
        encoded = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(BASE + path, headers=headers, data=encoded)
    try:
        response = OPENER.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    body = response.read().decode()
    return response.status, response.headers, body


def cookie_from(headers, previous=''):
    cookies = SimpleCookie()
    cookies.load(previous)
    for value in headers.get_all('Set-Cookie', []):
        cookies.load(value)
    return '; '.join(name + '=' + value.value for name, value in cookies.items())


def page(assertion, cookie='', path='/settings'):
    status, headers, document = request(path, assertion, cookie)
    assert status == 200, ('Authenticated page failed', path, status)
    parsed = Page()
    parsed.feed(document)
    assert parsed.csrf and parsed.root
    return cookie_from(headers, cookie), parsed.csrf, document, headers


def live(assertion, path='/settings', cookie=''):
    return LiveView(BASE, path, cookie, headers={'Cf-Access-Jwt-Assertion': assertion})


def reconnect(view, accepted):
    result = LiveView(BASE, '/settings', view.cookie_header,
                      page_document=view.document, expect_join=accepted)
    if not accepted:
        assert result.join_result and result.join_result[4]['status'] == 'error'
        assert result.initial is None, 'Unauthorized reconnect disclosed rendered state'
    return result


def denied_socket(view):
    event = view.wait(lambda event: event[3] == 'redirect' or
                     (event[3] == 'phx_reply' and 'redirect' in event[4].get('response', {})), timeout=6)
    assert event and contains(event, '/auth/reauthenticate'), 'Socket was not forced through HTTP reauthentication'


def signed(changes=None, header=None, other_key=False):
    changes = json.dumps(json.dumps(changes or {}))
    header = json.dumps(json.dumps(header or {'alg': 'RS256', 'kid': 'fixture', 'typ': 'JWT'}))
    key = ':other_key' if other_key else ':key'
    return rpc_json('''
      key = :persistent_term.get({:frontend_fixture, %s})
      now = System.system_time(:second)
      claims = Map.merge(%%{"iss" => "https://fixture.cloudflareaccess.com", "aud" => ["fixture-audience"],
        "type" => "app", "sub" => "fixture-human", "email" => "human@example.com",
        "iat" => now - 1, "nbf" => now - 1, "exp" => now + 600}, Jason.decode!(%s))
      key |> JOSE.JWT.sign(Jason.decode!(%s), claims) |> JOSE.JWS.compact() |> elem(1)
    ''' % (key, changes, header))


def set_ttl(seconds):
    rpc('Application.put_env(:agentboard, :frontend_auth, Keyword.put(Application.fetch_env!(:agentboard, :frontend_auth), :session_ttl_seconds, ' + str(seconds) + '))')


rpc('''
  Application.put_env(:agentboard, :captain_token, "''' + CAPTAIN + '''")
  key = JOSE.JWK.generate_key({:rsa, 2048})
  other = JOSE.JWK.generate_key({:rsa, 2048})
  :persistent_term.put({:frontend_fixture, :key}, key)
  :persistent_term.put({:frontend_fixture, :other_key}, other)
  public = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "fixture")
  file = Path.join(System.tmp_dir!(), "frontend-fixture-jwks-#{System.unique_integer([:positive])}.json")
  File.write!(file, Jason.encode!(%{"keys" => [public]}))
  :persistent_term.put({:frontend_fixture, :jwks_file}, file)
  Application.put_env(:agentboard, :frontend_auth,
    mode: "cloudflare_access", issuer: "https://fixture.cloudflareaccess.com",
    audience: "fixture-audience", jwks_file: file,
    allowed_emails: ["human@example.com"], allowed_subjects: [], session_ttl_seconds: 300)
''')

assertion = signed()

# No dashboard, captain page, raw document or document download is public.
for path in ['/', '/tasks/missing', '/prs', '/prs/missing', '/agents', '/messages', '/quota',
             '/context', '/context/missing', '/archive', '/settings', '/auth/reauthenticate',
             '/documents/missing', '/documents/missing/html', '/documents/missing/download']:
    status, headers, _ = request(path)
    assert status == 401, ('Anonymous route admitted', path, status)
    assert headers.get('Cache-Control') == 'no-store'

assert request(extra_headers={'Cf-Access-Authenticated-User-Email': 'human@example.com'})[0] == 401
for token, status in [
        ('malformed.jwt.assertion', 401),
        (signed(other_key=True), 401),
        (signed({'aud': ['wrong-application']}), 401),
        (signed({'iss': 'https://attacker.cloudflareaccess.com'}), 401),
        (signed({'exp': 1}), 401),
        (signed({'email': 'other@example.com'}), 403),
        (signed({'common_name': 'service.access', 'sub': ''}), 401),
        (signed(header={'alg': 'RS256', 'kid': 'unknown'}), 401),
        (signed(header={'alg': 'RS256', 'kid': 'fixture', 'jku': 'https://attacker.invalid/keys'}), 401)]:
    assert request(assertion=token)[0] == status, 'Invalid signed assertion admitted'

# Authentication does not unlock captain authority. The real socket is admitted
# through its signed session without relying on cf-access headers at handshake.
cookie, csrf, document, headers = page(assertion)
set_cookie = headers.get('Set-Cookie', '')
assert 'secure' in set_cookie.lower() and 'httponly' in set_cookie.lower() and 'samesite=lax' in set_cookie.lower()
viewer = live(assertion, cookie=cookie)
assert contains(viewer.initial, 'Captain controls are locked')
assert contains(viewer.initial, 'human@example.com')
reconnected = reconnect(viewer, accepted=True)
reconnected.close()
assert request('/settings/unlock', assertion, viewer.cookie_header, {'token': CAPTAIN})[0] == 403

# Successful unlock rotates and invalidates the pre-unlock tab's handle.
status, headers, _ = request('/settings/unlock', assertion, viewer.cookie_header,
                            {'token': CAPTAIN, '_csrf_token': viewer.csrf})
assert status == 302
unlocked_cookie = cookie_from(headers, viewer.cookie_header)
denied_socket(viewer)
reconnect(viewer, accepted=False).close()
viewer.close()
first = live(assertion, cookie=unlocked_cookie)
assert contains(first.initial, 'Lock captain controls'), 'Captain unlock lost across HTTP bridge renewal'
second = live(assertion, cookie=first.cookie_header)
assert contains(second.initial, 'Lock captain controls')

# One lock revokes both existing tabs and replayed pages/cookies.
status, _, _ = request('/settings/lock', assertion, first.cookie_header, {'_csrf_token': first.csrf})
assert status == 302
denied_socket(first)
denied_socket(second)
reconnect(first, accepted=False).close()
first.close()
second.close()

# Local logout revokes an active socket and copied signed bridge. The edge's
# same-origin logout handles its own cookie; we do not attempt that external flow.
viewer = live(assertion)
status, headers, _ = request('/auth/logout', assertion, viewer.cookie_header, {'_csrf_token': viewer.csrf})
assert status == 302 and headers.get('Location') == '/cdn-cgi/access/logout'
denied_socket(viewer)
reconnect(viewer, accepted=False).close()
viewer.close()

# Quiet open sockets expire, and replaying a page cannot slide that deadline.
set_ttl(2)
viewer = live(assertion)
denied_socket(viewer)
reconnect(viewer, accepted=False).close()
viewer.close()
set_ttl(300)

# A cookie alone never authenticates HTTP. Invalid HTTP revokes that bridge too.
viewer = live(assertion)
assert request('/settings', cookie=viewer.cookie_header)[0] == 401
denied_socket(viewer)
reconnect(viewer, accepted=False).close()
viewer.close()

# Rotation removes trust immediately for HTTP with no stale cached key fallback.
rpc('File.rm!(:persistent_term.get({:frontend_fixture, :jwks_file}))')
assert request('/settings', assertion)[0] == 503
rpc('Application.put_env(:agentboard, :frontend_auth, mode: "off")')
assert request('/settings')[0] == 200

print('Frontend cryptographic assertions, all HTTP/document boundaries, CSRF, real LiveView mount/reconnect, captain rotation, multi-tab lock, logout, quiet expiry and key-file failure passed')
