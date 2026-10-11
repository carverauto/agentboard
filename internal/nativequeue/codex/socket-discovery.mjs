// Read-only rust-v0.162.0 rendezvous validation. Never repair, lock or start a daemon.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

const fail = () => { throw new Error('Codex socket discovery unverified'); };
const boundedPath = value => typeof value === 'string' && Buffer.byteLength(value) <= 4096 &&
  !/[\x00-\x1f\x7f]/.test(value) && path.isAbsolute(value) && path.resolve(value) === value;
const stamp = s => {
  for (const key of ['dev', 'ino', 'uid', 'mode', 'nlink'])
    if (!(typeof s[key] === 'bigint' && s[key] >= 0n) && !(Number.isSafeInteger(s[key]) && s[key] >= 0)) fail();
  return Object.freeze({ dev: String(s.dev), ino: String(s.ino), uid: String(s.uid), mode: String(s.mode), nlink: String(s.nlink) });
};

/** io is only a metadata-fixture seam. Production always uses node:fs. */
export function inspectCodexSocket(codexHome, { io = fs } = {}) {
  if (typeof process.geteuid !== 'function' || !boundedPath(codexHome)) fail();
  const uid = process.geteuid();
  function canonical(file) {
    // Reject non-UTF-8 names rather than hashing replacement characters.
    const bytes = io.realpathSync(file, { encoding: 'buffer' });
    const value = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (!boundedPath(value)) fail();
    return value;
  }
  function capture() {
    const entries = [];
    const stat = file => {
      const s = io.lstatSync(file, { bigint: true });
      entries.push([file, stamp(s)]);
      return s;
    };
    function ancestry(file) {
      let current = path.parse(file).root;
      for (const part of ['', ...file.slice(current.length).split('/').filter(Boolean)]) {
        if (part) current = path.join(current, part);
        const s = stat(current);
        if (!s.isDirectory() || s.isSymbolicLink() || ![uid, 0].includes(Number(s.uid)) ||
            ((Number(s.mode) & 0o022) !== 0 && (Number(s.mode) & 0o1000) === 0)) fail();
      }
    }
    const home = canonical(codexHome);
    ancestry(home);
    const parent = path.join(home, 'app-server-control');
    ancestry(parent);
    const advertisedPath = path.join(parent, 'app-server-control.sock');
    // The official alias alone is a symlink; all canonical ancestry is checked.
    const alias = stat(advertisedPath);
    if (!alias.isSymbolicLink() || Number(alias.uid) !== uid || Number(alias.nlink) !== 1) fail();
    const temporaryRoot = canonical('/tmp'); // Never TMPDIR or an environment override.
    ancestry(temporaryRoot);
    const privateRoot = path.join(temporaryRoot, `codex-daemon-${uid}`);
    const directory = stat(privateRoot);
    if (!directory.isDirectory() || directory.isSymbolicLink() || Number(directory.uid) !== uid ||
        (Number(directory.mode) & 0o7777) !== 0o700) fail();
    const digest = createHash('sha256').update(Buffer.from(advertisedPath, 'utf8')).digest('hex');
    const targetPath = path.join(privateRoot, digest);
    if (io.readlinkSync(advertisedPath, { encoding: 'utf8' }) !== targetPath) fail();
    const socket = stat(targetPath);
    if (!socket.isSocket() || socket.isSymbolicLink() || Number(socket.uid) !== uid ||
        (Number(socket.mode) & 0o7777) !== 0o600 || Number(socket.nlink) !== 1) fail();
    return { descriptor: { advertisedPath, targetPath, uid, alias: stamp(alias), socket: stamp(socket) }, entries };
  }
  const initial = capture();
  const fingerprint = JSON.stringify(initial);
  const descriptor = Object.freeze({ ...initial.descriptor });
  function check() { if (JSON.stringify(capture()) !== fingerprint) fail(); }
  check(); // Reject substitution during discovery, without mutating either entry.
  return Object.freeze({ descriptor, check });
}
