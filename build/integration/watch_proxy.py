"""Loopback transport fault fixture; the production API remains available."""
import select
import socket
import threading
from urllib.parse import urlparse


class WatchProxy:
    def __init__(self, upstream):
        address = urlparse(upstream)
        self.upstream = (address.hostname, address.port)
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.url = 'http://127.0.0.1:' + str(self.listener.getsockname()[1])
        self.lock = threading.Lock()
        self.connections = set()
        self.enabled = True
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                peer, _ = self.listener.accept()
            except OSError:
                return
            with self.lock:
                if not self.enabled:
                    peer.close()
                    continue
                upstream = socket.create_connection(self.upstream)
                self.connections.update((peer, upstream))
            threading.Thread(target=self.forward, args=(peer, upstream), daemon=True).start()

    def forward(self, peer, upstream):
        try:
            while True:
                ready, _, _ = select.select([peer, upstream], [], [], 1)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is peer else peer).sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            with self.lock:
                self.connections.difference_update((peer, upstream))
            peer.close()
            upstream.close()

    def disconnect(self):
        with self.lock:
            self.enabled = False
            for connection in self.connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def resume(self):
        with self.lock:
            self.enabled = True

    def close(self):
        self.disconnect()
        self.listener.close()
