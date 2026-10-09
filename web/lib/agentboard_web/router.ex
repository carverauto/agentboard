defmodule AgentboardWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"], length: 16_384)
    plug(:fetch_session)
    plug(AgentboardWeb.Plugs.FrontendAuth)
    plug(:put_root_layout, html: {AgentboardWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AgentboardWeb do
    pipe_through(:browser)

    live_session :authenticated, on_mount: [{AgentboardWeb.FrontendAuthLive, :default}] do
      live("/", BoardLive, :board)
      live("/tasks/:id", BoardLive, :task)
      live("/prs", PRLive, :index)
      live("/prs/:id", PRLive, :detail)
      live("/agents", BoardLive, :agents)
      live("/messages", BoardLive, :messages)
      live("/quota", BoardLive, :quota)
      live("/context", ContextLive, :index)
      live("/context/:id", ContextLive, :entry)
      live("/archive", BoardLive, :archive)
      live("/settings", SettingsLive)
    end
  end

  pipeline :captain_control do
    plug(AgentboardWeb.Plugs.RateLimit)
  end

  scope "/auth", AgentboardWeb do
    pipe_through(:browser)
    post("/logout", FrontendAuthController, :logout)
    get("/reauthenticate", FrontendAuthController, :reauthenticate)
  end

  scope "/settings", AgentboardWeb do
    pipe_through([:browser, :captain_control])
    post("/unlock", CaptainController, :unlock)
    post("/lock", CaptainController, :lock)
    post("/agent-tokens/:action", AgentTokenController, :browser_mutate)
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
    plug(:fetch_session)
    plug(AgentboardWeb.Plugs.FrontendAuth)
  end

  scope "/documents", AgentboardWeb do
    pipe_through(:documents)
    get("/:id", DocumentController, :show)
    get("/:id/html", DocumentController, :content)
    get("/:id/download", DocumentController, :download)
  end

  pipeline :compatible do
    plug(AgentboardWeb.Plugs.Compatibility)
    plug(AgentboardWeb.Plugs.AgentAuth)
  end

  pipeline :github_hook do
    plug(AgentboardWeb.Plugs.RateLimit)
    plug(:accepts, ["json"])
  end

  scope "/api/v1/hooks", AgentboardWeb do
    pipe_through([:github_hook, :compatible])
    post("/github", WorkflowHookController, :create)
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
    post("/workers/provision", WorkerController, :provision)
    post("/workers/:worker_id/resolve_attempt", WorkerController, :resolve_attempt)
    post("/obligations/:id/responsibility", WorkerController, :responsibility)
    post("/workers/:worker_id/revoke", WorkerController, :revoke)
    get("/workers/:worker_id/:operation", WorkerController, :operate)
    post("/workers/:worker_id/attempts/:attempt_id/:operation", WorkerController, :operate)
    post("/workers/:worker_id/:operation", WorkerController, :operate)
    get("/hosts/:host_id/wake-intents/:worker_id", WorkerController, :wake)
    post("/hosts/:host_id/wake-intents/:worker_id/:operation", WorkerController, :wake)
    get("/decisions/wakes", DecisionController, :wakes)
    post("/decisions/wakes/:id/:action", DecisionController, :wake_mutate)
    get("/decisions/waiting", DecisionController, :waiting)
    post("/decisions/promote", DecisionController, :promote)
    get("/decisions", DecisionController, :index)
    post("/decisions", DecisionController, :create)
    get("/decisions/:id", DecisionController, :show)
    post("/decisions/:id/:action", DecisionController, :mutate)
    get("/prs", APIController, :prs)
    get("/prs/:id", APIController, :pr)
    post("/prs/:id/duplicate-decision", APIController, :duplicate_decision)
    get("/quota", APIController, :quota)
    post("/quota", APIController, :push_quota)
    get("/context/search", APIController, :context_search)
    get("/context/feed", APIController, :context_feed)
    get("/context/:id", APIController, :context_show)
    post("/context", APIController, :context_publish)
    post("/context/:id/ack", APIController, :context_ack)
    get("/fleets/:id/loadout", FleetLoadoutController, :show)
    put("/fleets/:id/loadout", FleetLoadoutController, :replace)
    get("/agents/:id/scope", APIController, :seat_scope)
    put("/agents/:id/scope", APIController, :set_seat_scope)
    get("/availability", APIController, :availability)
    post("/availability", APIController, :set_availability)
    post("/messages/task-orders", APIController, :broadcast_orders)
    get("/auth/observations", AgentTokenController, :report)
    get("/agents/:id/tokens", AgentTokenController, :list)
    post("/agents/:id/tokens/:action", AgentTokenController, :mutate)
    get("/agents", APIController, :agents)
    post("/agents/register", APIController, :register)
    post("/agents/:id/heartbeat", APIController, :heartbeat)
    post("/agents/:id/retire", APIController, :retire)
    post("/agents/:id/restore", APIController, :restore)
    get("/agents/:id", APIController, :agent)
    get("/tasks", APIController, :tasks)
    get("/settings/archive", CaptainController, :settings)
    patch("/settings/archive", CaptainController, :save)
    post("/tasks/:id/archive", CaptainController, :archive)
    post("/tasks/:id/restore", CaptainController, :restore)
    post("/tasks", APIController, :create)
    get("/messages", APIController, :messages)
    post("/messages", APIController, :send_message)
    post("/messages/:id/read", APIController, :read_message)
    get("/tasks/:id/documents", APIController, :documents)
    post("/tasks/:id/documents", APIController, :push_document)
    post("/conversations/send", ConversationController, :send)
    get("/conversations/reads", ConversationController, :reads)
    get("/conversations/diagnostics", ConversationController, :diagnostics)

    post(
      "/conversations/coverage/:agent_id/:channel_id",
      ConversationController,
      :report_coverage
    )

    get("/conversations/coverage/:agent_id/:channel_id", ConversationController, :coverage)
    get("/tasks/:id", APIController, :task)
    patch("/tasks/:id", APIController, :edit)
    post("/tasks/:id/:action", APIController, :mutate)
  end
end
