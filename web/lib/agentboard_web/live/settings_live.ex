defmodule AgentboardWeb.SettingsLive do
  use Phoenix.LiveView, layout: false
  alias Agentboard.{Captain, Housekeeping}

  def mount(_params, session, socket) do
    socket = assign(socket, policy: nil, capability: session["captain"], error: nil, saved: false)
    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  def handle_event("save", params, socket) do
    with true <- Captain.authorized?(socket.assigns.capability),
         true <- is_map(socket.assigns.policy),
         {days, ""} <- Integer.parse(params["retention_days"] || ""),
         {hours, ""} <- Integer.parse(params["interval_hours"] || ""),
         {:ok, _policy} <-
           Housekeeping.save(Captain.actor(), %{
             "enabled" => params["enabled"] == "true",
             "retention_days" => days,
             "interval_hours" => hours,
             "revision" => socket.assigns.policy.revision
           }) do
      {:noreply, socket |> assign(saved: true, error: nil) |> load()}
    else
      {:error, _, message} ->
        {:noreply, socket |> assign(error: message, saved: false) |> load()}

      _ ->
        {:noreply,
         assign(socket, error: "Captain access and valid settings required", saved: false)}
    end
  end

  defp load(socket) do
    case Housekeeping.settings() do
      {:ok, policy} -> assign(socket, policy: policy)
      {:error, _, message} -> assign(socket, error: message)
    end
  end

  def render(assigns) do
    ~H"""
    <main id="settings-view">
      <div class="page-title"><h1>Settings</h1><a href="/archive">Browse archived tasks</a></div>
      <p :if={@error} class="notice danger" role="alert">{@error}</p>
      <p :if={@saved} class="notice healthy" role="status">Archive policy saved.</p>
      <p :if={!@policy} class="notice">Connecting to the board…</p>
      <section :if={@policy} class="settings-panel">
        <h2>Completed task archive</h2>
        <p>Keep Done cards visible for a while, then move them into the archive. History, documentation, ownership and PR links remain available.</p>
        <%= if Captain.authorized?(@capability) do %>
          <form phx-submit="save" class="settings-form">
            <label class="check"><input name="enabled" type="checkbox" value="true" checked={@policy.enabled} /> Automatically archive Done tasks</label>
            <label>Keep completed cards for <span><input name="retention_days" type="number" min="1" max="3650" value={@policy.retention_days} required /> days</span></label>
            <label>Archive schedule <select name="interval_hours"><option value="1" selected={@policy.interval_hours==1}>Every hour</option><option value="24" selected={@policy.interval_hours==24}>Every day</option><option value="168" selected={@policy.interval_hours==168}>Every week</option></select></label>
            <p>Runs on the server. The first sweep happens one selected interval after saving. Restoring a card restarts its retention period.</p>
            <button type="submit" phx-disable-with="Saving…">Save archive policy</button>
          </form>
          <form action="/settings/lock" method="post"><input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} /><button type="submit" class="text-button">Lock captain controls</button></form>
        <% else %>
          <p class="notice">Captain controls are locked. Current policy: {if @policy.enabled, do: "Enabled", else: "Off"}; keep cards {@policy.retention_days} days, sweep every {@policy.interval_hours} hours.</p>
          <form :if={Captain.configured?()} action="/settings/unlock" method="post" class="settings-form">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <label>Captain token <input name="token" type="password" autocomplete="current-password" required /></label><button type="submit">Unlock captain controls</button>
          </form>
          <p :if={!Captain.configured?()}>An operator needs to configure captain access before changes can be made.</p>
        <% end %>
        <dl><dt>Next sweep</dt><dd>{@policy.next_run_at || "Not scheduled"}</dd><dt>Last sweep</dt><dd>{@policy.last_run_at || "Never"}</dd><dt>Cards archived last sweep</dt><dd>{@policy.last_archived_count}</dd></dl>
      </section>
    </main>
    """
  end
end

