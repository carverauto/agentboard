import {readFileSync} from 'node:fs'
import Rendered from 'liveview-rendered'
// The SDK selects the browser's structuredClone; Node provides the same API.
globalThis.window = globalThis
const {initial, diffs} = JSON.parse(readFileSync(0, 'utf8'))
const rendered = new Rendered('fixture-view', initial)
// Consume every render in wire order: the SDK resolves and removes each diff's
// template table while rendering. Full snapshots disable its DOM-skip shortcut.
const snapshot = () => rendered.recursiveToString(rendered.get(), undefined, undefined, false, {}).buffer
let html = snapshot()
for (const diff of diffs) { rendered.mergeDiff(diff); html = snapshot() }
process.stdout.write(html)
