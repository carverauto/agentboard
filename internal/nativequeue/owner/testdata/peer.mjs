// Invented native peer only, never a Codex installation.
import http from 'node:http';
import fs from 'node:fs';
import { WebSocketServer } from 'ws';
const [socket, log, mode] = process.argv.slice(2);
const server = http.createServer();
const ws = new WebSocketServer({ noServer: true, perMessageDeflate: false });
server.on('upgrade', (request, stream, head) => {
  if (request.url !== '/rpc') throw new Error('wrong route');
  ws.handleUpgrade(request, stream, head, peer => {
    peer.on('message', bytes => {
      const request = JSON.parse(bytes);
      fs.appendFileSync(log, JSON.stringify(request) + '\n');
      if (request.method === 'initialized') return;
      if (request.method === 'thread/queue/add' && mode === 'lose-add') return;
      let result;
      if (request.method === 'initialize') result = { userAgent: 'invented-owner-test', codexHome: '/invented', platformFamily: 'unix', platformOs: 'linux' };
      else if (request.method === 'thread/read') result = { thread: { id: request.params.threadId, ephemeral: false, source: 'cli', status: { type: 'idle' } } };
      else if (request.method === 'thread/queue/add') result = { queuedSubmission: { id: '22222222-2222-4222-8222-222222222222', input: request.params.input, clientUserMessageId: request.params.clientUserMessageId } };
      else if (request.method === 'thread/queue/list') result = { data: [], nextCursor: null };
      else throw new Error('unexpected method');
      peer.send(JSON.stringify({ id: request.id, result }));
    });
  });
});
server.listen(socket, () => { fs.chmodSync(socket, 0o600); console.log('ready'); });
