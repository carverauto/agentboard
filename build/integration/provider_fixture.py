"""Invented HTTPS provider transport shared by packaged-release fixtures."""
from contextlib import contextmanager
import http.server
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading


@contextmanager
def tls_provider(handler):
    with tempfile.TemporaryDirectory() as temp:
        key, cert, ca, ca_key, csr = [str(Path(temp) / name) for name in
                                    ('key.pem', 'cert.pem', 'ca.pem', 'ca-key.pem', 'csr.pem')]
        def openssl(*args):
            subprocess.run(['openssl', *args], check=True, capture_output=True)
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-keyout', ca_key, '-out', ca, '-subj', '/CN=Fixture CA',
                '-addext', 'basicConstraints=critical,CA:TRUE')
        openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                '-out', csr, '-subj', '/CN=fixture-provider')
        extensions = Path(temp) / 'extensions.txt'
        extensions.write_text('subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n'
                              'keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
        openssl('x509', '-req', '-in', csr, '-CA', ca, '-CAkey', ca_key,
                '-CAcreateserial', '-out', cert, '-days', '1', '-extfile', str(extensions))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            yield f'https://127.0.0.1:{server.server_port}', ca, server
        finally:
            server.shutdown()
            server.server_close()
