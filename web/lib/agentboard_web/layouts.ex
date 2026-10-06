defmodule AgentboardWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Agentboard</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/assets/app.js"></script>
      </head>
      <body>
        <header class="app-header">
          <a href="/" class="brand">agentboard<span>Shared work, visible ownership</span></a>
          <nav aria-label="Main navigation">
            <a href="/">Board</a><a href="/agents">Agents</a><a href="/messages">Messages</a><a href="/quota">Quota</a>
          </nav>
          <span class="read-only">Read-only dashboard</span>
        </header>
        {@inner_content}
        <footer>Agentboard pre-alpha. Claim, renew, and update through the CLI.</footer>
      </body>
    </html>
    """
  end
end

