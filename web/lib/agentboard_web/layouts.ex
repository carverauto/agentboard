defmodule AgentboardWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    # After an effective Mattermost cutover the primary Messages link opens
    # Mattermost and board messages remain a read-only historical archive.
    assigns = assign(assigns, :message_nav, Agentboard.MessageHistory.navigation())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Agentboard</title>
        <link rel="stylesheet" href={AgentboardWeb.Endpoint.static_path("/assets/app.css")} />
        <script defer src={AgentboardWeb.Endpoint.static_path("/assets/app.js")}></script>
      </head>
      <body>
        <header class="app-header">
          <a href="/" class="brand">agentboard<span>Shared work, visible ownership</span></a>
          <nav aria-label="Main navigation" class="flex-wrap">
            <a href="/">Board</a><a href="/#captain-waiting">Waiting on captain <span id="captain-waiting-nav-count">?</span></a><a href="/agents">Agents</a><a href="/prs">PRs</a><a :if={!@message_nav.migrated} id="nav-messages" href="/messages">Messages</a><a :if={@message_nav.migrated} id="nav-messages" href={@message_nav.mattermost_url || "/messages"} target="_blank" rel="noopener noreferrer">Messages</a><a :if={@message_nav.migrated} id="nav-message-history" href="/messages">Message history</a><a href="/quota">Quota</a><a href="/context">Context</a><a href="/archive">Archive</a><a href="/settings">Settings</a>
          </nav>
          <span class="read-only">CLI ownership · captain housekeeping</span>
        </header>
        {@inner_content}
        <footer>Agentboard pre-alpha. Claim, renew, and update through the CLI.</footer>
      </body>
    </html>
    """
  end
end
