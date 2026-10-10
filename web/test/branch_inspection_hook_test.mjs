import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import vm from "node:vm"

// Event ordering of the production hook, without a simulated browser claim.
const app = readFileSync(new URL("../assets/app.js", import.meta.url), "utf8")
const source = app.split("const BranchFlowView = ")[1].split("// Settings uses")[0]

function fixture() {
  const listeners = new Map(), focused = [], sent = []
  let panel = null, reloads = 0
  const elements = new Map()
  const body = {}
  const document = {body, activeElement: body,
    getElementById: id => elements.get(id) || null,
    addEventListener: (name, fn) => listeners.set(`document-${name}`, fn),
    removeEventListener: name => listeners.delete(`document-${name}`)}
  const make = (id, dataset = {}) => {
    const element = {id, dataset, disabled: false, hidden: false,
      focus() { focused.push(id); document.activeElement = this },
      contains(target) { return target === this || target?.parent === this }}
    elements.set(id, element)
    return element
  }
  make("branch-table-heading"); make("branch-topology-heading"); make("branch-inspection-heading")
  const el = {dataset: {clientGeneration: "0", routeGeneration: "1", inspectionGeneration: "1"},
    querySelector: selector => selector === "[data-branch-inspection]" ? panel : elements.get(selector.slice(1)) || null,
    contains: target => !!target && elements.has(target.id),
    addEventListener: (name, fn) => listeners.set(`el-${name}`, fn),
    removeEventListener: name => listeners.delete(`el-${name}`)}
  const window = {addEventListener: (name, fn) => listeners.set(`window-${name}`, fn),
    removeEventListener: name => listeners.delete(`window-${name}`),
    location: {href: "https://example.test/prs?repo=fixture%2Frepo", reload: () => reloads++}}
  const hook = vm.runInNewContext(`(${source.trim()})`, {window, document, URL})
  const ctx = {...hook, el, handleEvent() {}, pushEvent: (event, data) => sent.push({event, ...data})}
  ctx.mounted()
  function target(control, kind) {
    return {...control, closest: selector => {
      if (selector === "[data-branch-inspect]" || selector === "[data-branch-inspect], [data-branch-toggle]") return kind === "inspect" ? control : kind === "toggle" && selector.includes(",") ? control : null
      if (selector === "[data-branch-close]") return kind === "close" ? control : null
      if (selector === "[data-branch-toggle]") return kind === "toggle" ? control : null
      if (selector === "a[href]") return kind === "link" ? control : null
      return null
    }}
  }
  return {ctx, el, focused, sent, listeners, document, elements, reloads: () => reloads,
    get panel() { return panel },
    click(id, mode = "topology") {
      const button = make(`${mode === "table" ? "branch-disclose" : "branch-node"}-${id}`, {branchInspect: id, mode})
      listeners.get("el-click")({target: target(button, "inspect")})
      return button
    },
    close() { listeners.get("el-click")({target: target(make("branch-inspection-close", {branchClose: "true"}), "close")}) },
    escape() { let prevented = false; listeners.get("el-keydown")({key: "Escape", preventDefault() { prevented = true }}); return prevented },
    outside() { const button = make("outside"); document.activeElement = button; listeners.get("document-pointerdown")({target: target(button, "outside")}); return button },
    link({href = "https://example.test/prs?repo=fixture%2Fother", modified = false, newTab = false} = {}) { const control = make("navigate"); control.href = href; control.target = newTab ? "_blank" : ""; listeners.get("el-click")({target: target(control, "link"), metaKey: modified}) },
    toggle(event) { listeners.get("el-click")({target: target(make("toggle", {branchToggle: event}), "toggle")}) },
    patch({id, mode = "topology", client = 0, generation = 2, route = "1"} = {}) {
      Object.assign(el.dataset, {clientGeneration: String(client), inspectionGeneration: String(generation), routeGeneration: String(route), selectedInspection: id || "", inspectionMode: id ? mode : ""})
      panel = id ? make("branch-inspection", {branchInspection: id, mode}) : null
      ctx.updated()
    }
  }
}

test("open focuses a nonmodal heading once; refresh preserves focus", () => {
  const f = fixture(); f.click("a"); f.patch({id: "a", client: 1})
  assert.deepEqual(f.focused, ["branch-inspection-heading"])
  f.patch({id: "a", client: 1}); assert.equal(f.focused.length, 1)
  assert.equal(f.sent[0].event, "inspect_pr")
  assert.equal(f.sent[0].route_generation, "1")
})

test("rapid A to B replacement suppresses late A and focuses only B", () => {
  const f = fixture(); f.click("a"); f.click("b")
  f.patch({id: "a", client: 1}); assert.equal(f.panel.hidden, true); assert.equal(f.focused.length, 0)
  f.patch({id: "b", client: 2, generation: 3}); assert.equal(f.panel.hidden, false); assert.equal(f.focused.length, 1)
})

test("Escape before an open response suppresses late content and cannot reopen", () => {
  const f = fixture(); f.click("a"); assert.equal(f.escape(), true)
  assert.equal(f.sent.at(-1).event, "close_inspection"); assert.equal(f.sent.at(-1).id, "a")
  f.patch({id: "a", client: 1}); assert.equal(f.panel.hidden, true); assert.equal(f.focused.length, 0)
  f.patch({client: 2, generation: 3}); assert.deepEqual(f.focused, ["branch-node-a"])
  f.patch({client: 2, generation: 3}); assert.equal(f.focused.length, 1)
})

test("Close restores the invoking disclosure; same-row click toggles without stealing focus", () => {
  const f = fixture(); f.click("a", "table"); f.patch({id: "a", mode: "table", client: 1})
  f.close(); f.patch({client: 2, generation: 3}); assert.equal(f.focused.at(-1), "branch-disclose-a")
  const g = fixture(); g.click("a", "table"); g.patch({id: "a", mode: "table", client: 1}); g.click("a", "table")
  g.patch({id: "a", mode: "table", client: 1}); assert.equal(g.panel.hidden, true)
  g.patch({client: 2, generation: 3}); assert.equal(g.focused.length, 1)
})

test("outside pointer dismissal preserves the clicked control and its focus", () => {
  const f = fixture(); f.click("a"); f.patch({id: "a", client: 1}); const outside = f.outside()
  f.patch({client: 2, generation: 3}); assert.equal(f.document.activeElement, outside); assert.equal(f.focused.length, 1)
})

test("route navigation suppresses a pending panel; new route never restores old focus", () => {
  const f = fixture(); f.click("a"); f.link(); f.patch({id: "a", client: 1})
  assert.equal(f.panel.hidden, true); assert.equal(f.focused.length, 0)
  f.patch({client: 1, route: "2"}); assert.equal(f.focused.length, 0)
  f.click("b"); f.patch({id: "b", client: 2, route: "2"}); assert.equal(f.focused.length, 1)
})

test("Back/Forward and restored document cache do not revive dismissed content", () => {
  const f = fixture(); f.click("a"); f.listeners.get("window-popstate")(); f.patch({id: "a", client: 1})
  assert.equal(f.panel.hidden, true); assert.equal(f.focused.length, 0)
  f.listeners.get("window-pageshow")({persisted: true}); assert.equal(f.reloads(), 1)
})

test("removal of focused PR uses a stable fallback when the invoker no longer exists", () => {
  const f = fixture(); f.click("a"); f.patch({id: "a", client: 1}); f.elements.delete("branch-node-a")
  f.document.activeElement = f.document.body; f.patch({client: 1, generation: 3})
  assert.equal(f.focused.at(-1), "branch-topology-heading")
})

test("glyph hiding suppresses a queued drawer and teardown removes listeners", () => {
  const f = fixture(); f.click("a", "table"); f.toggle("toggle_branch_glyphs")
  f.patch({id: "a", mode: "table", client: 1}); assert.equal(f.panel.hidden, true)
  f.patch({client: 2, generation: 3}); assert.equal(f.focused.length, 0)
  f.ctx.destroyed(); assert.equal(f.listeners.size, 0)
})


test("same-route, hash and modified links never latch navigation suppression", () => {
  for (const options of [{href: "https://example.test/prs?repo=fixture%2Frepo"}, {href: "https://example.test/prs?repo=fixture%2Frepo#branch-table-heading"}, {modified: true}, {newTab: true}]) {
    const f = fixture(); f.link(options); f.click("b"); f.patch({id: "b", client: 1})
    assert.equal(f.panel.hidden, false); assert.equal(f.focused.length, 1)
  }
})
