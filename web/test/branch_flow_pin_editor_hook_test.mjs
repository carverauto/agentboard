import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import vm from "node:vm"

// Exercise the real hook without a Phoenix bundle or a browser dependency.
// Browser acceptance remains a separate test: these checks model event ordering.
const app = readFileSync(new URL("../assets/app.js", import.meta.url), "utf8")
const source = app.split("const BranchFlowPinEditor = ")[1].split("\nconst liveSocket")[0]

function fixture() {
  const listeners = new Map()
  const focused = []
  const pushed = []
  let reloaded = 0
  let confirmation = false
  const el = {
    dataset: {dirty: "false", state: "editing", editorGeneration: "1"},
    addEventListener: (name, fn) => listeners.set(`el-${name}`, fn),
    removeEventListener: name => listeners.delete(`el-${name}`),
    querySelector: selector => selector === "#branch-flow-discard-confirmation"
      ? (confirmation ? {} : null) : {focus: () => focused.push(selector)}
  }
  const window = {
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name),
    location: {reload: () => reloaded++}
  }
  const document = {getElementById: id => ({focus: () => focused.push(id)})}
  const hook = vm.runInNewContext(`(${source.trim()})`, {window, document})
  const ctx = {...hook, el, pushEvent: (name, params) => pushed.push([name, params])}
  ctx.mounted()
  return {
    ctx, el, listeners, focused, pushed,
    setConfirmation: value => { confirmation = value },
    reloaded: () => reloaded,
    click({edit = false, disabled = false, fieldsetDisabled = false, id = ""} = {}) {
      const control = {id, disabled, closest: () => fieldsetDisabled ? {} : null}
      listeners.get("el-click")({target: {closest: selector => selector === "[data-pin-edit]" ? (edit ? control : null) : control}})
    },
    unload() {
      let prevented = false
      const event = {preventDefault: () => { prevented = true }}
      listeners.get("beforeunload")(event)
      return prevented
    }
  }
}

test("clean document navigation is free; a server-confirmed dirty editor guards native navigation", () => {
  const f = fixture()
  assert.equal(f.unload(), false)
  f.el.dataset.dirty = "true"
  f.ctx.updated()
  assert.equal(f.unload(), true)
})

test("a stale search patch cannot clear a pin click's guard before the pin acknowledgement", () => {
  const f = fixture()
  f.click({edit: true})
  assert.equal(f.unload(), true)
  // A search started before the local pin click finishes with an older clean
  // draft. The pin event is still queued, so no server dirty bit is present yet.
  f.el.dataset.dirty = "false"
  f.ctx.updated()
  assert.equal(f.unload(), true)
  f.el.dataset.dirty = "true"
  f.ctx.updated()
  assert.equal(f.unload(), true)
})

test("only a confirmed reset clears pending edits, and newer local clicks survive that reset", () => {
  const f = fixture()
  f.click({edit: true})
  f.click({id: "branch-flow-reload"})
  // Failed reload or unrelated update keeps the same editor generation.
  f.ctx.updated()
  assert.equal(f.unload(), true)
  f.el.dataset.editorGeneration = "2"
  f.ctx.updated()
  assert.equal(f.unload(), false)
  f.click({edit: true})
  f.click({id: "branch-flow-reload"})
  f.click({edit: true})
  f.el.dataset.editorGeneration = "3"
  f.ctx.updated()
  assert.equal(f.unload(), true)
})

test("confirmed Save clears earlier edits but never silently clears a later local edit", () => {
  const f = fixture()
  f.click({edit: true})
  f.click({id: "branch-flow-save"})
  f.el.dataset.state = "saved"
  f.ctx.updated()
  assert.equal(f.unload(), false)
  const g = fixture()
  g.click({edit: true})
  g.click({id: "branch-flow-save"})
  g.click({edit: true})
  g.el.dataset.state = "saved"
  g.ctx.updated()
  assert.equal(g.unload(), true)
})

test("overlapping resets never let an older response consume a newer edit boundary", () => {
  const f = fixture()
  f.click({edit: true})
  f.click({id: "branch-flow-reload"})
  f.click({edit: true})
  f.click({id: "branch-flow-reload"})
  f.el.dataset.editorGeneration = "2"
  f.ctx.updated()
  assert.equal(f.unload(), true)
  f.click({edit: true})
  f.click({id: "branch-flow-reload"})
  // The late second response must settle only edit 2, never edit 3.
  f.el.dataset.editorGeneration = "3"
  f.ctx.updated()
  assert.equal(f.unload(), true)
  f.el.dataset.editorGeneration = "4"
  f.ctx.updated()
  assert.equal(f.unload(), false)
})

test("disabled edits do not arm the guard", () => {
  const f = fixture()
  f.click({edit: true, disabled: true})
  assert.equal(f.unload(), false)
  f.click({edit: true, fieldsetDisabled: true})
  assert.equal(f.unload(), false)
})

test("Escape, discard focus, listener cleanup and return focus stay local to this editor", () => {
  const f = fixture()
  assert.deepEqual(f.focused, ["#branch-flow-pin-editor-heading"])
  f.listeners.get("el-keydown")({key: "Escape", preventDefault() {}})
  assert.equal(f.pushed.at(-1)[0], "close_branch_flow_pins")
  f.setConfirmation(true)
  f.ctx.updated()
  assert.equal(f.focused.at(-1), "#branch-flow-discard-cancel")
  f.listeners.get("el-keydown")({key: "Escape", preventDefault() {}})
  assert.equal(f.pushed.at(-1)[0], "cancel_branch_flow_discard")
  f.setConfirmation(false)
  f.ctx.updated()
  assert.equal(f.focused.at(-1), "#branch-flow-close")
  f.ctx.destroyed()
  assert.equal(f.listeners.size, 0)
  assert.equal(f.focused.at(-1), "branch-flow-open")
})

test("a cached history return rereads persisted state without reviving a dismissed draft", () => {
  const f = fixture()
  f.click({edit: true})
  f.listeners.get("pageshow")({persisted: true})
  assert.equal(f.reloaded(), 1)
  assert.equal(f.unload(), false)
})
