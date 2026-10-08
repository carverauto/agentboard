// Execute the production application bootstrap. SDK stand-ins capture its public
// hook registration; they do not implement open-state preservation or patching.
import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import vm from 'node:vm'

let registered, connected = false
class LiveSocket {
  constructor(path, socket, options) { registered = options.hooks }
  connect() { connected = true }
}
const context = vm.createContext({document: {querySelector: () => null}})
const sdk = new Map([
  ['phoenix_html', new vm.SyntheticModule([], () => {}, {context})],
  ['phoenix', new vm.SyntheticModule(['Socket'], function() { this.setExport('Socket', class {}) }, {context})],
  ['phoenix_live_view', new vm.SyntheticModule(['LiveSocket'], function() { this.setExport('LiveSocket', LiveSocket) }, {context})],
])
const app = new vm.SourceTextModule(await readFile(process.argv[2], 'utf8'), {context})
await app.link(name => { assert.ok(sdk.has(name), `Unexpected SDK import ${name}`); return sdk.get(name) })
await app.evaluate()
assert.ok(connected)
const hook = registered.CompletedCard
assert.equal(typeof hook.beforeUpdate, 'function')
assert.equal(typeof hook.updated, 'function')

// LiveView calls beforeUpdate before patching an element and updated afterward.
// A patch drops server-untracked `open` while replacing the findings text.
const a = {el: {open: true, textContent: 'original findings'}}
const b = {el: {open: false, textContent: 'other decision'}}
for (let revision = 1; revision <= 3; revision++) {
  hook.beforeUpdate.call(a)
  hook.beforeUpdate.call(b)
  a.el.open = false
  b.el.open = false
  a.el.textContent = `new findings ${revision}`
  hook.updated.call(a)
  hook.updated.call(b)
  assert.equal(a.el.open, true, 'opened findings collapsed during a patch')
  assert.equal(b.el.open, false, 'a different decision inherited the open state')
  assert.equal(a.el.textContent, `new findings ${revision}`, 'content was frozen')
}
// The user can close it, and subsequent patches must respect that choice too.
a.el.open = false
hook.beforeUpdate.call(a)
a.el.open = true
hook.updated.call(a)
assert.equal(a.el.open, false)
console.log('Production-registered details hook preserves independent user state across three patches and allows changed findings')
