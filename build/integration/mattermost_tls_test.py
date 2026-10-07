"""Transport TLS acceptance: wildcard trust and wrong-host rejection.

A local TLS stub presents generated certificates for the loopback name
`localhost`: once with a wildcard SAN the client must accept, once with an
unrelated name it must reject. All proof runs against the packaged release;
no verification bypass exists anywhere in the path.
"""
import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = 'fixture-bot-token'


class Stub(BaseHTTPRequestHandler):
    server_version = 'FixtureMattermostTLS/1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path != '/api/v4/system/ping':
            body = b'{"message":"unknown fixture path"}'
            self.send_response(404)
        elif self.headers.get('Authorization') != f'Bearer {TOKEN}':
            body = b'{"message":"invalid credentials"}'
            self.send_response(401)
        else:
            body = b'{"status":"OK"}'
            self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def openssl(*args):
    result = subprocess.run(['openssl', *args], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (args, result.stderr)


root = tempfile.mkdtemp(prefix='mm-tls-')
ca_key = os.path.join(root, 'ca.key')
ca_crt = os.path.join(root, 'ca.crt')
openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-keyout', ca_key, '-out', ca_crt, '-subj', '/CN=fixture-ca')


def server_cert(name, sans):
    key = os.path.join(root, f'{name}.key')
    csr = os.path.join(root, f'{name}.csr')
    crt = os.path.join(root, f'{name}.crt')
    ext = os.path.join(root, f'{name}.ext')
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
            '-out', csr, '-subj', f'/CN={name}')
    with open(ext, 'w') as f:
        f.write('subjectAltName=' + ','.join(sans) + '\n')
    openssl('x509', '-req', '-in', csr, '-CA', ca_crt, '-CAkey', ca_key,
            '-CAcreateserial', '-days', '1', '-out', crt, '-extfile', ext)
    return crt, key


# `*` matches the single-label loopback name; nothing else may verify.
wild_crt, wild_key = server_cert('wild', ['DNS:*'])
wrong_crt, wrong_key = server_cert('wrong', ['DNS:wrong.invalid'])


class DualStack(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def serve(crt, key, ready):
    server = DualStack(('::', 0, 0, 0), Stub)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(crt, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    ready.append(server.server_address[1])
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


wild_ready, wrong_ready = [], []
wild_server = serve(wild_crt, wild_key, wild_ready)
wrong_server = serve(wrong_crt, wrong_key, wrong_ready)


def rpc(expression):
    result = subprocess.run([os.environ['AGENTBOARD_BIN'], 'rpc', expression],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return result.stdout


rpc(f'Application.put_env(:agentboard, :mattermost_ca_file, "{ca_crt}")')

# A wildcard presented for the loopback name verifies against our CA.
out = rpc(f'IO.inspect(Agentboard.Mattermost.Transport.ping(%{{token: "{TOKEN}", base_url: "https://localhost:{wild_ready[0]}", channel_id: "unused"}}), label: "WILDCARD")')
assert '"status" => "OK"' in out, out

# A valid-chain certificate for the wrong name is rejected, not bypassed.
out = rpc(f'IO.inspect(Agentboard.Mattermost.Transport.ping(%{{token: "{TOKEN}", base_url: "https://localhost:{wrong_ready[0]}", channel_id: "unused"}}), label: "WRONGHOST")')
assert 'OK' not in out, out

# A non-loopback plain-HTTP destination is refused before any byte is sent.
out = rpc('IO.inspect(Agentboard.Mattermost.Transport.ping(%{token: "x", base_url: "http://mattermost.example:8065", channel_id: "unused"}), label: "FORBIDDEN")')
assert 'forbidden_destination' in out, out

wild_server.shutdown()
wrong_server.shutdown()
print('Transport TLS: wildcard acceptance, wrong-host rejection and destination restriction passed')
