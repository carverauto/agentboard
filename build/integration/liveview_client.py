"""Minimal RFC 6455/Phoenix v2 client for the deployed read-only UI boundary."""
import base64
import hashlib
import json
import os
import socket
import struct
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from http.cookies import SimpleCookie

class Page(HTMLParser):
    def __init__(self):super().__init__();self.root=None;self.csrf=None
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='meta' and attrs.get('name')=='csrf-token':self.csrf=attrs['content']
        if 'data-phx-main' in attrs:self.root=attrs

class LiveView:
    def __init__(self,base,path,cookie_header='',*,headers=None,page_document=None,expect_join=True):
        url=base+path
        cookies=SimpleCookie();cookies.load(cookie_header)
        if page_document is None:
            request_headers=dict(headers or {},Cookie=cookie_header)
            with urllib.request.urlopen(urllib.request.Request(url,headers=request_headers),timeout=10) as response:
                document=response.read().decode();cookies.load(response.headers.get('Set-Cookie',''))
        else:
            # Replay the already signed page/session directly at WebSocket join,
            # without an HTTP request silently reauthenticating the browser.
            document=page_document
        self.document=document
        page=Page();page.feed(document)
        assert page.root and page.csrf, 'Missing LiveView root/session or CSRF token'
        self.topic='lv:'+page.root['id']
        target=urllib.parse.urlparse(base)
        self.socket=socket.create_connection((target.hostname,target.port),timeout=10)
        self.buffer=b''
        self.events=[]
        key=base64.b64encode(os.urandom(16)).decode()
        cookie='; '.join(k+'='+v.value for k,v in cookies.items())
        self.cookie_header=cookie
        self.csrf=page.csrf
        endpoint='/live/websocket?vsn=2.0.0&_csrf_token='+urllib.parse.quote(page.csrf)
        headers=f'GET {endpoint} HTTP/1.1\r\nHost: {target.netloc}\r\nOrigin: {base}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nCookie: {cookie}\r\n\r\n'
        self.socket.sendall(headers.encode())
        while b'\r\n\r\n' not in self.buffer:self.buffer+=self.socket.recv(65536)
        header,self.buffer=self.buffer.split(b'\r\n\r\n',1)
        assert header.startswith(b'HTTP/1.1 101'),header.decode()
        expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert expected in header
        self.send(['1','1',self.topic,'phx_join',{'url':url,'params':{'_csrf_token':page.csrf,'_mounts':0},'session':page.root['data-phx-session'],'static':page.root.get('data-phx-static')}])
        joined=self.wait(lambda event:event[3]=='phx_reply')
        self.join_result=joined
        if expect_join:assert joined and joined[4]['status']=='ok',joined
        self.initial=joined[4]['response'].get('rendered') if joined else None
    def send(self,payload,opcode=1):
        raw=json.dumps(payload,separators=(',',':')).encode() if opcode==1 else payload
        length=len(raw);mask=os.urandom(4)
        header=bytes([0x80|opcode,0x80|min(length,126 if length<=65535 else 127)])
        if length>=126:header+=struct.pack('!H' if length<=65535 else '!Q',length)
        self.socket.sendall(header+mask+bytes(v^mask[i%4] for i,v in enumerate(raw)))
    def read(self,length):
        while len(self.buffer)<length:
            data=self.socket.recv(max(4096,length-len(self.buffer)))
            if not data:raise EOFError('LiveView connection closed')
            self.buffer+=data
        data,self.buffer=self.buffer[:length],self.buffer[length:];return data
    def receive(self,timeout):
        self.socket.settimeout(timeout)
        first,second=self.read(2);opcode=first&15;length=second&127
        if length==126:length=struct.unpack('!H',self.read(2))[0]
        if length==127:length=struct.unpack('!Q',self.read(8))[0]
        mask=self.read(4) if second&128 else None
        payload=self.read(length)
        if mask:payload=bytes(v^mask[i%4] for i,v in enumerate(payload))
        if opcode==9:self.send(payload,10);return None
        if opcode==8:raise EOFError('LiveView closed')
        assert opcode==1 and first&128, 'Unexpected fragmented/non-text frame'
        return json.loads(payload)
    def wait(self,predicate,timeout=6):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:event=self.receive(max(0.01,deadline-time.monotonic()))
            except socket.timeout:return None
            if event is not None:
                self.events.append(event)
                if predicate(event):return event
        return None
    def close(self):
        self.send(struct.pack('!H',1000),8);self.socket.close()

def contains(value,text):
    if isinstance(value,str):return text in value
    if isinstance(value,list):return any(contains(v,text) for v in value)
    if isinstance(value,dict):return any(contains(v,text) for v in value.values())
    return False


class RenderedView:
    """Real LiveView transport plus the pinned SDK's rendered-wire consumer."""
    def __init__(self, base, path, cookie_header=''):
        self.live = LiveView(base, path, cookie_header)
        self.initial = self.live.initial
        self.diffs = []
        self.ref = 1
        self.live.events.clear()
        self.document = self.render()

    def render(self):
        import subprocess
        result = subprocess.run([os.environ['FIXTURE_RENDERED_NODE'],
                                 os.environ['FIXTURE_RENDERED_BUNDLE']],
                                input=json.dumps({'initial': self.initial, 'diffs': self.diffs}),
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr
        return result.stdout

    def request(self, event, payload):
        self.ref += 1
        ref = str(self.ref)
        self.live.send(['1', ref, self.live.topic, event, payload])
        response = self.live.wait(lambda e: e[1] == ref and e[3] == 'phx_reply')
        assert response and response[4]['status'] == 'ok', response
        for received in self.live.events:
            if received[3] == 'diff':
                self.diffs.append(received[4])
        self.live.events.clear()
        diff = response[4]['response'].get('diff', {})
        if diff:
            self.diffs.append(diff)
        assert not any(key in response[4]['response'] for key in ('live_redirect', 'redirect'))
        self.document = self.render()
        return self.document

    def close(self):
        self.live.close()
