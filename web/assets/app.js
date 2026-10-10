import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const QuotaDialog = {
  mounted() {
    this.closeEvent = this.el.dataset.closeEvent || "close_quota"
    this.returnFocus = document.getElementById(this.el.dataset.returnFocus)
    this.onCancel = event => { event.preventDefault(); this.pushEvent(this.closeEvent, {}) }
    this.onBackdrop = event => {
      const rect = this.el.getBoundingClientRect()
      if (event.target === this.el && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) this.pushEvent(this.closeEvent, {})
    }
    this.el.addEventListener("cancel", this.onCancel)
    this.el.addEventListener("click", this.onBackdrop)
    this.el.showModal()
  },
  destroyed() {
    this.el.removeEventListener("cancel", this.onCancel)
    this.el.removeEventListener("click", this.onBackdrop)
    this.el.close()
    if (this.returnFocus?.isConnected) this.returnFocus.focus()
  }
}
const CompletedCard = {
  beforeUpdate() { this.expanded = this.el.open },
  updated() { this.el.open = this.expanded }
}
const CaptainWaitingCount = {
  mounted() { this.updated() },
  updated() {
    const badge = document.getElementById("captain-waiting-nav-count")
    if (badge) badge.textContent = this.el.dataset.count || "?"
  },
  destroyed() {
    const badge = document.getElementById("captain-waiting-nav-count")
    if (badge) badge.textContent = "?"
  }
}
const BranchFlowView = {
  mounted() {
    this.sequence = Number(this.el.dataset.clientGeneration || 0)
    this.route = this.el.dataset.routeGeneration
    this.intent = null
    this.focusedSelection = null
    this.routeChanging = false
    this.returnFocus = null
    this.returnMode = null
    this.restore = false
    this.handleEvent("branch-flow-focus", ({id}) => {
      const target = document.getElementById(id)
      if (target && this.el.contains(target)) target.focus()
    })
    this.sendIntent = (event, values = {}) => {
      this.sequence = Math.max(this.sequence, Number(this.el.dataset.clientGeneration || 0)) + 1
      this.pushEvent(event, {...values, route_generation: this.el.dataset.routeGeneration, client_generation: this.sequence})
    }
    this.dismiss = restore => {
      const id = this.intent?.id || this.el.dataset.selectedInspection
      const mode = this.intent?.mode || this.el.dataset.inspectionMode
      if (!id) return
      this.restore = restore
      this.sendIntent("close_inspection", {id, mode, generation: this.el.dataset.inspectionGeneration})
      this.intent = {closed: true}
      this.suppress()
    }
    this.suppress = () => {
      const panel = this.el.querySelector("[data-branch-inspection]")
      if (!panel) return
      const pending = Number(this.el.dataset.clientGeneration || 0) < this.sequence
      const wrong = this.intent?.id && (panel.dataset.branchInspection !== this.intent.id || panel.dataset.mode !== this.intent.mode)
      panel.hidden = this.routeChanging || (pending && (!!this.intent?.closed || !!wrong))
    }
    this.navigates = event => {
      const link = event.target.closest("a[href]")
      if (!link || link.target === "_blank" || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || (event.button !== undefined && event.button !== 0)) return false
      const destination = new URL(link.href, window.location.href)
      const current = new URL(window.location.href)
      destination.searchParams.sort()
      current.searchParams.sort()
      // Same-route links and hash anchors may not invoke handle_params. Never
      // latch navigation suppression unless the actual route changes.
      return destination.origin !== current.origin || destination.pathname !== current.pathname || destination.search !== current.search
    }
    this.onClick = event => {
      const inspect = event.target.closest("[data-branch-inspect]")
      const close = event.target.closest("[data-branch-close]")
      const toggle = event.target.closest("[data-branch-toggle]")
      if (inspect && this.el.contains(inspect) && !inspect.disabled) {
        const id = inspect.dataset.branchInspect, mode = inspect.dataset.mode
        this.returnFocus = inspect.id
        this.returnMode = mode
        this.restore = false
        const same = mode === "table" && (this.intent?.id || this.el.dataset.selectedInspection) === id && (this.intent?.mode || this.el.dataset.inspectionMode) === mode && !this.intent?.closed
        this.intent = same ? {closed: true} : {id, mode}
        this.sendIntent("inspect_pr", {id, mode})
        this.suppress()
      } else if (close && this.el.contains(close)) {
        this.dismiss(true)
      } else if (toggle && this.el.contains(toggle)) {
        if (toggle.dataset.branchToggle === "toggle_branch_glyphs") {
          this.restore = false
          this.intent = {closed: true}
        }
        this.sendIntent(toggle.dataset.branchToggle)
        this.suppress()
      } else if (this.navigates(event)) {
        this.routeChanging = true
        this.intent = {closed: true}
        this.restore = false
        this.suppress()
      }
    }
    this.onKeyDown = event => {
      if (event.key === "Escape" && (this.intent?.id || this.el.dataset.selectedInspection)) {
        event.preventDefault()
        this.dismiss(true)
      }
    }
    this.onOutside = event => {
      const panel = this.el.querySelector("[data-branch-inspection]")
      if ((panel || this.intent?.id) && !panel?.contains(event.target) && !event.target.closest("[data-branch-inspect], [data-branch-toggle]")) {
        // Leave the clicked control's focus alone. Pointer dismissal never
        // prevents the click or moves focus away from its intended destination.
        this.dismiss(false)
      }
    }
    this.onPopState = () => {
      this.routeChanging = true
      this.intent = {closed: true}
      this.restore = false
      this.suppress()
    }
    this.onPageShow = event => { if (event.persisted) window.location.reload() }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeyDown)
    document.addEventListener("pointerdown", this.onOutside)
    window.addEventListener("popstate", this.onPopState)
    window.addEventListener("pageshow", this.onPageShow)
  },
  updated() {
    const route = this.el.dataset.routeGeneration
    const selected = this.el.dataset.selectedInspection || null
    const mode = this.el.dataset.inspectionMode
    const panel = this.el.querySelector("[data-branch-inspection]")
    if (route !== this.route) {
      this.route = route
      this.routeChanging = false
      this.intent = null
      this.focusedSelection = null
      this.returnFocus = null
      this.restore = false
    }
    this.suppress()
    if (Number(this.el.dataset.clientGeneration || 0) < this.sequence || this.routeChanging) return
    if (selected && panel && !panel.hidden) {
      const selection = `${mode}:${selected}`
      if (selection !== this.focusedSelection && !this.intent?.closed) {
        this.el.querySelector("#branch-inspection-heading")?.focus()
        this.focusedSelection = selection
      }
      this.intent = null
    } else if (!selected) {
      const wasSelected = this.focusedSelection
      this.focusedSelection = null
      this.intent = null
      // Restore only explicit keyboard/Close dismissal, or when a refresh
      // removed the focused inspection. Never steal an outside click's focus.
      const focusWasRemoved = wasSelected && (!document.activeElement || document.activeElement === document.body)
      if (this.restore || focusWasRemoved) {
        const invoker = document.getElementById(this.returnFocus)
        const fallback = document.getElementById(this.returnMode === "table" ? "branch-table-heading" : "branch-topology-heading") || document.getElementById("branch-table-heading")
        const target = invoker && this.el.contains(invoker) ? invoker : fallback
        target?.focus()
      }
      this.restore = false
    }
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener("pointerdown", this.onOutside)
    window.removeEventListener("popstate", this.onPopState)
    window.removeEventListener("pageshow", this.onPageShow)
  }
}
// Settings uses ordinary document links/forms and never patches its route. A
// native beforeunload guard therefore covers navigation, reload, Back and
// Forward without inserting history entries or interfering with other pages.
const BranchFlowPinEditor = {
  mounted() {
    this.pendingEdit = false
    this.editSequence = 0
    this.resolvedThrough = 0
    this.resetBoundaries = []
    this.editorGeneration = this.el.dataset.editorGeneration
    this.editorState = this.el.dataset.state
    this.allowNavigation = false
    this.hadConfirmation = false
    this.isDirty = () => !this.allowNavigation && (this.pendingEdit || this.el.dataset.dirty === "true")
    this.onBeforeUnload = event => {
      if (!this.isDirty()) return
      event.preventDefault()
      event.returnValue = ""
    }
    this.onEdit = event => {
      const control = event.target.closest("[data-pin-edit]")
      if (control && !control.disabled && !control.closest("fieldset[disabled]")) {
        this.editSequence++
        this.pendingEdit = true
      }
      const button = event.target.closest("button")
      if (button && !button.disabled && ["branch-flow-save", "branch-flow-reload", "branch-flow-discard-confirm", "branch-flow-reconcile", "branch-flow-retry"].includes(button.id)) {
        this.resetBoundaries.push(this.editSequence)
      }
    }
    this.onKeyDown = event => {
      if (event.key !== "Escape") return
      event.preventDefault()
      this.pushEvent(this.el.querySelector("#branch-flow-discard-confirmation") ? "cancel_branch_flow_discard" : "close_branch_flow_pins", {})
    }
    this.onPageShow = event => {
      // Returning from the back-forward cache is a new deliberate visit. Read
      // persisted state instead of reviving an editor the user already left.
      if (event.persisted) {
        this.allowNavigation = true
        window.location.reload()
      }
    }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    window.addEventListener("pageshow", this.onPageShow)
    this.el.addEventListener("click", this.onEdit)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.querySelector("#branch-flow-pin-editor-heading")?.focus()
  },
  updated() {
    const generation = this.el.dataset.editorGeneration
    const state = this.el.dataset.state
    if (generation !== this.editorGeneration || (state === "saved" && this.editorState !== "saved")) {
      // A successful explicit save/reload can settle only clicks already made
      // when it was requested. A slow old search diff, failed reload, or newer
      // local click must never clear the guard before its server acknowledgement.
      // Keep every request boundary in order. Failed/overlapping reset requests
      // can leave a conservative prompt, but an older response cannot consume a
      // newer reset's boundary and discard an intervening local edit.
      const boundary = this.resetBoundaries.shift()
      if (boundary !== undefined) this.resolvedThrough = Math.max(this.resolvedThrough, boundary)
    }
    this.editorGeneration = generation
    this.editorState = state
    // Conservative until an explicit confirmed reset: reverting all pins to the
    // old order may retain a prompt, but no pending draft is silently discarded.
    this.pendingEdit = this.editSequence > this.resolvedThrough
    const confirmation = this.el.querySelector("#branch-flow-discard-confirmation")
    if (confirmation && !this.hadConfirmation) this.el.querySelector("#branch-flow-discard-cancel")?.focus()
    if (!confirmation && this.hadConfirmation) this.el.querySelector("#branch-flow-close")?.focus()
    this.hadConfirmation = !!confirmation
  },
  destroyed() {
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    window.removeEventListener("pageshow", this.onPageShow)
    this.el.removeEventListener("click", this.onEdit)
    this.el.removeEventListener("keydown", this.onKeyDown)
    document.getElementById("branch-flow-open")?.focus()
  }
}
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: {QuotaDialog, CompletedCard, CaptainWaitingCount, BranchFlowView, BranchFlowPinEditor}})
liveSocket.connect()
