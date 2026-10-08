// Exercise the hook registered by the production bootstrap. SDK stand-ins only
// capture registration; event routing, cleanup and focus come from app.js.
import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import vm from 'node:vm'
let registered
const origins = new Map()
class LiveSocket {
  constructor(_path, _socket, options) { registered = options.hooks }
  connect() {}
}
const context = vm.createContext({document: {
  querySelector: () => null, getElementById: id => origins.get(id)
}})
const sdk = new Map([
  ['phoenix_html', new vm.SyntheticModule([], () => {}, {context})],
  ['phoenix', new vm.SyntheticModule(['Socket'], function() { this.setExport('Socket', class {}) }, {context})],
  ['phoenix_live_view', new vm.SyntheticModule(['LiveSocket'], function() { this.setExport('LiveSocket', LiveSocket) }, {context})],
])
const app = new vm.SourceTextModule(await readFile(process.argv[2], 'utf8'), {context})
await app.link(name => { assert.ok(sdk.has(name)); return sdk.get(name) })
await app.evaluate()
const hook = registered.QuotaDialog
for (const [closeEvent, expected] of [[undefined, 'close_quota'], ['close_availability', 'close_availability']]) {
  const listeners = new Map(), events = []
  let shown = 0, closed = 0, focused = 0
  const origin = {isConnected: true, focus() { focused++ }}
  origins.set('fixture-origin', origin)
  const el = {
    dataset: {returnFocus: 'fixture-origin', closeEvent},
    addEventListener(name, callback) { listeners.set(name, callback) },
    removeEventListener(name, callback) { assert.equal(listeners.get(name), callback); listeners.delete(name) },
    getBoundingClientRect() { return {left: 20, right: 120, top: 20, bottom: 120} },
    showModal() { shown++ }, close() { closed++ },
  }
  const instance = {el, pushEvent(name, _payload) { events.push(name) }}
  hook.mounted.call(instance)
  assert.equal(shown, 1)
  let prevented = false
  listeners.get('cancel')({preventDefault() { prevented = true }})
  assert.ok(prevented, 'Escape must wait for the server to remove the dialog')
  assert.deepEqual(events, [expected])
  listeners.get('click')({target: el, clientX: 50, clientY: 50})
  listeners.get('click')({target: {}, clientX: 0, clientY: 0})
  assert.equal(events.length, 1, 'Dialog content clicks must not dismiss')
  listeners.get('click')({target: el, clientX: 0, clientY: 0})
  assert.deepEqual(events, [expected, expected])
  hook.destroyed.call(instance)
  assert.equal(listeners.size, 0)
  assert.equal(closed, 1)
  assert.equal(focused, 1)
}
console.log('Registered dialog hook routes quota and availability dismissal, contains content clicks, removes listeners and restores focus')
