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
    this.handleEvent("branch-flow-focus", ({id}) => {
      const target = document.getElementById(id)
      if (target && this.el.contains(target)) target.focus()
    })
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
