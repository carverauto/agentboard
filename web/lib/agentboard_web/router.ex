defmodule AgentboardWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {AgentboardWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AgentboardWeb do
    pipe_through(:browser)
    live("/", BoardLive, :board)
    live("/tasks/:id", BoardLive, :task)
    live("/agents", BoardLive, :agents)
    live("/messages", BoardLive, :messages)
    live("/quota", BoardLive, :quota)
  end

  pipeline :api do
    plug(AgentboardWeb.Plugs.RateLimit)
    plug(:accepts, ["json"])
    plug(AgentboardWeb.Plugs.JSONBody)
  end

  pipeline :watch_api do
    plug(AgentboardWeb.Plugs.RateLimit)
    plug(AgentboardWeb.Plugs.JSONBody)
  end

  pipeline :documents do
    plug(AgentboardWeb.Plugs.RateLimit)
  end

  scope "/documents", AgentboardWeb do
    pipe_through(:documents)
    get("/:id", DocumentController, :show)
    get("/:id/html", DocumentController, :content)
    get("/:id/download", DocumentController, :download)
  end

  pipeline :compatible do
    plug(AgentboardWeb.Plugs.Compatibility)
  end

  scope "/health", AgentboardWeb do
    get("/live", HealthController, :live)
    get("/ready", HealthController, :ready)
  end

  scope "/api/v1", AgentboardWeb do
    pipe_through(:api)
    get("/meta", MetaController, :show)
  end

  scope "/api/v1", AgentboardWeb do
    pipe_through([:watch_api, :compatible])
    get("/tasks/watch", WatchController, :tasks)
    get("/messages/watch", WatchController, :messages)
    get("/quota/watch", WatchController, :quota)
  end

  scope "/api/v1", AgentboardWeb do
    pipe_through([:api, :compatible])
    get("/quota", APIController, :quota)
    post("/quota", APIController, :push_quota)
    get("/agents", APIController, :agents)
    post("/agents/register", APIController, :register)
    post("/agents/:id/heartbeat", APIController, :heartbeat)
    get("/agents/:id", APIController, :agent)
    get("/tasks", APIController, :tasks)
    post("/tasks", APIController, :create)
    get("/messages", APIController, :messages)
    post("/messages", APIController, :send_message)
    post("/messages/:id/read", APIController, :read_message)
    get("/tasks/:id/documents", APIController, :documents)
    post("/tasks/:id/documents", APIController, :push_document)
    get("/tasks/:id", APIController, :task)
    patch("/tasks/:id", APIController, :edit)
    post("/tasks/:id/:action", APIController, :mutate)
  end
end

