// Native acceptance evidence only. This is not a wake ledger or recovery loop.
import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

const LIMIT = 65536;
const fail = message => { throw new Error(message); };
const same = (a, b) => a.dev === b.dev && a.ino === b.ino;

// One custody algorithm, two execution drivers. The synchronous facade is for
// offline inspection and fixture setup; live transports use ONLY the async one.
function runSync(iterator) {
  let state = iterator.next();
  while (!state.done) state = iterator.next(state.value);
  return state.value;
}
async function runAsync(iterator) {
  let state = iterator.next();
  while (!state.done) {
    let value;
    try { value = await state.value; }
    catch (error) { state = iterator.throw(error); continue; }
    state = iterator.next(value);
  }
  return state.value;
}
const operations = ['lstat', 'open', 'fstat', 'close', 'fsync', 'read', 'writeFile', 'unlink', 'rename'];
export function createJournal(root, { io = fs } = {}) {
  const driver = Object.fromEntries(operations.map(name => [name, (...args) => io[name + 'Sync'](...args)]));
  const core = journalCore(root, driver);
  runSync(core.initialize());
  return Object.freeze({ paths: core.paths,
    load: id => runSync(core.load(id)), save: (id, value) => runSync(core.save(id, value)),
    withLock: (id, fn) => runAsync(core.withLock(id, fn)) });
}
export function createAsyncJournal(root, { io = fs } = {}) {
  const driver = Object.fromEntries(operations.map(name => [name, (...args) => new Promise((resolve, reject) => {
    // read's first success argument is bytesRead; the supplied fixed buffer is
    // already shared with the algorithm. No unbounded readFile is used.
    io[name](...args, (error, value) => error ? reject(error) : resolve(value));
  })]));
  const core = journalCore(root, driver);
  const ready = runAsync(core.initialize());
  // Initialization may finish before the first operation is requested.
  ready.catch(() => {});
  return Object.freeze({ paths: core.paths,
    async load(id) { await ready; return runAsync(core.load(id)); },
    async save(id, value) { const frozen = JSON.parse(JSON.stringify(value)); await ready; return runAsync(core.save(id, frozen)); },
    async withLock(id, fn) { await ready; return runAsync(core.withLock(id, fn)); } });
}

function journalCore(root, io) {
  if (typeof process.getuid !== 'function' || !path.isAbsolute(root) || path.resolve(root) !== root) fail('Private absolute journal root required');
  const uid = process.getuid();
  function* protectedStat(file, directory = false) {
    const s = (yield io.lstat(file));
    if (s.isSymbolicLink() || !(directory ? s.isDirectory() : s.isFile()) || s.uid !== uid || (s.mode & 0o7777) !== (directory ? 0o700 : 0o600) || (!directory && s.nlink !== 1)) fail('Foreign or unprotected native evidence');
    return s;
  }
  // Reject symlinked ancestors too, including an otherwise-private root reached
  // through a symlink. No mkdir/chmod/ownership repair is performed here.
  function* rootStat() {
    function* ancestor(file) {
      const s = (yield io.lstat(file));
      // Root-owned system paths are trusted. Writable shared ancestors are safe
      // only with sticky deletion protection (e.g. /tmp); every traversed entry
      // must still be owned by us or root. Reject foreign-owned ancestors even
      // when currently read-only: their owner could change that permission.
      if (s.isSymbolicLink() || !s.isDirectory() || ![uid, 0].includes(s.uid) ||
          ((s.mode & 0o022) && !(s.mode & 0o1000))) fail('Untrusted journal path ancestry');
    }
    let current = path.parse(root).root;
    (yield* ancestor(current));
    for (const part of root.slice(current.length).split('/').filter(Boolean)) {
      current = path.join(current, part);
      (yield* ancestor(current));
    }
    return (yield* protectedStat(root, true));
  }
  let originalRoot;
  function* initialize() { originalRoot = yield* rootStat(); }
  function* checkRoot() { if (!same((yield* rootStat()), originalRoot)) fail('Journal root changed'); }
  function paths(attemptId) {
    if (typeof attemptId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(attemptId)) fail('Invalid attempt ID');
    const key = createHash('sha256').update(attemptId).digest('hex');
    return { record: path.join(root, key + '.json'), lock: path.join(root, key + '.lock') };
  }
  function* optionalStat(file) {
    try { return (yield* protectedStat(file)); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  function* openChecked(file, flags, expected) {
    const fd = (yield io.open(file, flags | fs.constants.O_NOFOLLOW, 0o600));
    try {
      const s = (yield io.fstat(fd));
      if (!s.isFile() || s.uid !== uid || (s.mode & 0o7777) !== 0o600 || s.nlink !== 1 || (expected && !same(expected, s))) fail('Native evidence changed or unprotected');
      return fd;
    } catch (error) { (yield io.close(fd)); throw error; }
  }
  function* syncRoot() {
    (yield* checkRoot());
    const fd = (yield io.open(root, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW));
    try { if (!same((yield io.fstat(fd)), originalRoot)) fail('Journal root changed'); (yield io.fsync(fd)); }
    finally { (yield io.close(fd)); }
    // Async fsync yields to other operations; recheck pathname custody after it.
    yield* checkRoot();
  }
  function* load(attemptId) {
    (yield* checkRoot());
    const file = paths(attemptId).record, s = (yield* optionalStat(file));
    if (!s) return null;
    if (s.size > LIMIT) fail('Native evidence exceeds bound');
    const fd = (yield* openChecked(file, fs.constants.O_RDONLY, s));
    try {
      // Read a fixed-size buffer rather than an unbounded file after stat.
      const bytes = Buffer.alloc(LIMIT + 1);
      const size = (yield io.read(fd, bytes, 0, bytes.length, 0));
      if (size > LIMIT || (yield io.fstat(fd)).size !== size) fail('Native evidence exceeds bound or changed');
      const record = JSON.parse(bytes.subarray(0, size).toString('utf8'));
      if (record === null || typeof record !== 'object' || Array.isArray(record)) fail('Invalid native evidence object');
      // A writer can be between rename and directory fsync, or have failed that
      // sync. Visibility alone is not durable acceptance. Each reader establishes
      // its own persistence barrier, including historical reads with a stale lock.
      (yield io.fsync(fd));
      (yield* syncRoot());
      if (!same((yield* protectedStat(file)), s)) fail('Native evidence changed during durable read');
      return record;
    } finally { (yield io.close(fd)); }
  }
  const held = new Map();
  function* save(attemptId, value) {
    (yield* checkRoot());
    const lock = held.get(attemptId);
    if (!lock || !same((yield* protectedStat(paths(attemptId).lock)), lock)) fail('Attempt lock required');
    const file = paths(attemptId).record;
    (yield* optionalStat(file)); // Never replace a foreign/unprotected file.
    const data = JSON.stringify(value);
    if (Buffer.byteLength(data) > LIMIT) fail('Native evidence exceeds bound');
    const temporary = path.join(root, '.queue-' + randomUUID());
    const fd = (yield* openChecked(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL));
    try { (yield io.writeFile(fd, data)); (yield io.fsync(fd)); }
    catch (error) { try { (yield io.unlink(temporary)); } catch {} throw error; }
    finally { (yield io.close(fd)); }
    try {
      (yield* checkRoot()); (yield* optionalStat(file));
      (yield io.rename(temporary, file));
      (yield* syncRoot());
    } finally { try { (yield io.unlink(temporary)); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
    // Never let a caller cross the native-write boundary after custody changed
    // while a write/fsync was pending. A durable record alone is insufficient.
    yield* checkRoot();
    if (held.get(attemptId) !== lock || !same((yield* protectedStat(paths(attemptId).lock)), lock)) fail('Attempt lock changed during save');
  }
  function* withLock(attemptId, fn) {
    (yield* checkRoot());
    const file = paths(attemptId).lock;
    // No PID-based stale lock deletion: a crash must not enable a duplicate add.
    // An operator may resolve custody separately, preserving the record.
    const fd = (yield* openChecked(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL));
    let identity;
    try { identity = yield io.fstat(fd); }
    catch (error) { yield io.close(fd); throw error; } // Keep uncertain custody; never clear an unverified lock.
    held.set(attemptId, identity);
    try { (yield io.writeFile(fd, JSON.stringify({ version: 1, pid: process.pid }))); (yield io.fsync(fd)); (yield* syncRoot()); return yield fn(); }
    finally {
      held.delete(attemptId); (yield io.close(fd));
      (yield* checkRoot());
      if (!same((yield* protectedStat(file)), identity)) fail('Attempt lock changed');
      (yield io.unlink(file)); (yield* syncRoot());
    }
  }
  return { paths, load, save, withLock, initialize };
}
