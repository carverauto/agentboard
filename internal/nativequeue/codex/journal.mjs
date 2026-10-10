// Native acceptance evidence only. This is not a wake ledger or recovery loop.
import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

const LIMIT = 65536;
const fail = message => { throw new Error(message); };
const same = (a, b) => a.dev === b.dev && a.ino === b.ino;

export function createJournal(root, { io = fs } = {}) {
  if (typeof process.getuid !== 'function' || !path.isAbsolute(root) || path.resolve(root) !== root) fail('Private absolute journal root required');
  const uid = process.getuid();
  function protectedStat(file, directory = false) {
    const s = io.lstatSync(file);
    if (s.isSymbolicLink() || !(directory ? s.isDirectory() : s.isFile()) || s.uid !== uid || (s.mode & 0o7777) !== (directory ? 0o700 : 0o600) || (!directory && s.nlink !== 1)) fail('Foreign or unprotected native evidence');
    return s;
  }
  // Reject symlinked ancestors too, including an otherwise-private root reached
  // through a symlink. No mkdir/chmod/ownership repair is performed here.
  function rootStat() {
    function ancestor(file) {
      const s = io.lstatSync(file);
      // Root-owned system paths are trusted. Writable shared ancestors are safe
      // only with sticky deletion protection (e.g. /tmp); every traversed entry
      // must still be owned by us or root. Reject foreign-owned ancestors even
      // when currently read-only: their owner could change that permission.
      if (s.isSymbolicLink() || !s.isDirectory() || ![uid, 0].includes(s.uid) ||
          ((s.mode & 0o022) && !(s.mode & 0o1000))) fail('Untrusted journal path ancestry');
    }
    let current = path.parse(root).root;
    ancestor(current);
    for (const part of root.slice(current.length).split('/').filter(Boolean)) {
      current = path.join(current, part);
      ancestor(current);
    }
    return protectedStat(root, true);
  }
  const originalRoot = rootStat();
  function checkRoot() { if (!same(rootStat(), originalRoot)) fail('Journal root changed'); }
  function paths(attemptId) {
    if (typeof attemptId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(attemptId)) fail('Invalid attempt ID');
    const key = createHash('sha256').update(attemptId).digest('hex');
    return { record: path.join(root, key + '.json'), lock: path.join(root, key + '.lock') };
  }
  function optionalStat(file) {
    try { return protectedStat(file); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  function openChecked(file, flags, expected) {
    const fd = io.openSync(file, flags | fs.constants.O_NOFOLLOW, 0o600);
    try {
      const s = io.fstatSync(fd);
      if (!s.isFile() || s.uid !== uid || (s.mode & 0o7777) !== 0o600 || s.nlink !== 1 || (expected && !same(expected, s))) fail('Native evidence changed or unprotected');
      return fd;
    } catch (error) { io.closeSync(fd); throw error; }
  }
  function syncRoot() {
    checkRoot();
    const fd = io.openSync(root, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    try { if (!same(io.fstatSync(fd), originalRoot)) fail('Journal root changed'); io.fsyncSync(fd); }
    finally { io.closeSync(fd); }
  }
  function load(attemptId) {
    checkRoot();
    const file = paths(attemptId).record, s = optionalStat(file);
    if (!s) return null;
    if (s.size > LIMIT) fail('Native evidence exceeds bound');
    const fd = openChecked(file, fs.constants.O_RDONLY, s);
    try {
      // Read a fixed-size buffer rather than an unbounded file after stat.
      const bytes = Buffer.alloc(LIMIT + 1);
      const size = io.readSync(fd, bytes, 0, bytes.length, 0);
      if (size > LIMIT || io.fstatSync(fd).size !== size) fail('Native evidence exceeds bound or changed');
      const record = JSON.parse(bytes.subarray(0, size).toString('utf8'));
      if (record === null || typeof record !== 'object' || Array.isArray(record)) fail('Invalid native evidence object');
      // A writer can be between rename and directory fsync, or have failed that
      // sync. Visibility alone is not durable acceptance. Each reader establishes
      // its own persistence barrier, including historical reads with a stale lock.
      io.fsyncSync(fd);
      syncRoot();
      if (!same(protectedStat(file), s)) fail('Native evidence changed during durable read');
      return record;
    } finally { io.closeSync(fd); }
  }
  const held = new Map();
  function save(attemptId, value) {
    checkRoot();
    const lock = held.get(attemptId);
    if (!lock || !same(protectedStat(paths(attemptId).lock), lock)) fail('Attempt lock required');
    const file = paths(attemptId).record;
    optionalStat(file); // Never replace a foreign/unprotected file.
    const data = JSON.stringify(value);
    if (Buffer.byteLength(data) > LIMIT) fail('Native evidence exceeds bound');
    const temporary = path.join(root, '.queue-' + randomUUID());
    const fd = openChecked(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL);
    try { io.writeFileSync(fd, data); io.fsyncSync(fd); }
    catch (error) { try { io.unlinkSync(temporary); } catch {} throw error; }
    finally { io.closeSync(fd); }
    try {
      checkRoot(); optionalStat(file);
      io.renameSync(temporary, file);
      syncRoot();
    } finally { try { io.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
  }
  async function withLock(attemptId, fn) {
    checkRoot();
    const file = paths(attemptId).lock;
    // No PID-based stale lock deletion: a crash must not enable a duplicate add.
    // An operator may resolve custody separately, preserving the record.
    const fd = openChecked(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL);
    const identity = io.fstatSync(fd);
    held.set(attemptId, identity);
    try { io.writeFileSync(fd, JSON.stringify({ version: 1, pid: process.pid })); io.fsyncSync(fd); syncRoot(); return await fn(); }
    finally {
      held.delete(attemptId); io.closeSync(fd);
      checkRoot();
      if (!same(protectedStat(file), identity)) fail('Attempt lock changed');
      io.unlinkSync(file); syncRoot();
    }
  }
  return Object.freeze({ paths, load, save, withLock });
}
