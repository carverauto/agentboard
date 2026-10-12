// Subprocess adapter for the packaged server fixture. Never performs network I/O.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const { createWakeAdvisory, parseWakeAdvisoryFrame, canonicalNotice, ADVISORY_TITLE, NOTICE_SUFFIX } =
  await import(pathToFileURL(path.join(path.resolve(process.argv[2]), 'advisory-mapping.mjs')));
const raw = fs.readFileSync(0, 'utf8');
if (Buffer.byteLength(raw) > 65536) throw new Error('Bounded fixture input required');
const input = JSON.parse(raw);
const notice = createWakeAdvisory(input);
const frame = ADVISORY_TITLE + canonicalNotice(notice) + NOTICE_SUFFIX;
const callback = parseWakeAdvisoryFrame(frame, { manifest: input.manifest, serverOrigin: input.serverOrigin });
process.stdout.write(JSON.stringify({ notice, frame, callback }));
