import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import "./app.css"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const QuotaDialog = {
  mounted() {
    this.returnFocus = document.getElementById(this.el.dataset.returnFocus)
    this.onCancel = event => { event.preventDefault(); this.pushEvent("close_quota", {}) }
    this.onBackdrop = event => {
      const rect = this.el.getBoundingClientRect()
      if (event.target === this.el && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) this.pushEvent("close_quota", {})
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
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: {QuotaDialog, CompletedCard}})
liveSocket.connect()
