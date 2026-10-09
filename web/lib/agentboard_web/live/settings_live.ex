defmodule AgentboardWeb.SettingsLive do
  use Phoenix.LiveView, layout: false
  alias Agentboard.{Captain, FleetLoadout, Housekeeping}

  @fleet_events ~w(open_fleet fleet_draft save_fleet retry_fleet reload_fleet close_fleet)
  @desired_fields ~w(seat_id agent_id harness desired_host_id desired_model desired_effort scope_revision)
  @max_draft_bytes 65_536

  def mount(_params, session, socket) do
    socket =
      assign(socket,
        policy: nil,
        capability: session["captain"],
        error: nil,
        saved: false,
        credential_records: [],
        credential_agent: nil,
        fleet_form: nil,
        fleet_error: nil
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  def handle_event("list_credentials", %{"agent_id" => id}, socket) do
    result =
      if Captain.authorized?(socket.assigns.capability),
        do: Agentboard.Auth.administer(id, "list", %{}, socket.assigns.capability),
        else: {:error, "forbidden", "Captain access required"}

    case result do
      {:ok, %{credentials: records}} ->
        {:noreply, assign(socket, credential_records: records, credential_agent: id, error: nil)}

      {:error, _, message} ->
        {:noreply, assign(socket, credential_records: [], credential_agent: nil, error: message)}
    end
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

  # Browser events never supply a fleet identity, revision, or idempotency key
  # after the editor opens. Recheck the capability, including its expiry, on every
  # event, even if the editor was already open when the session expired.
  def handle_event(event, params, socket) when event in @fleet_events do
    if Captain.authorized?(socket.assigns.capability) do
      {:noreply, fleet_event(event, params, socket)}
    else
      {:noreply,
       assign(socket, fleet_form: nil, fleet_error: "Captain access required for fleet loadouts.")}
    end
  end

  defp fleet_event("open_fleet", %{"fleet_id" => id}, socket)
       when is_binary(id) do
    cond do
      socket.assigns.fleet_form != nil ->
        assign(socket, fleet_error: "Dismiss this editor before choosing another fleet.")

      not Agentboard.Input.slug?(id) ->
        assign(socket, fleet_error: "Enter a valid fleet slug.")

      true ->
        load_fleet(socket, id)
    end
  end

  defp fleet_event("close_fleet", _params, socket),
    do: assign(socket, fleet_form: nil, fleet_error: nil)

  defp fleet_event("reload_fleet", _params, socket) do
    case socket.assigns.fleet_form do
      %{id: id} -> load_fleet(socket, id)
      _ -> socket
    end
  end

  defp fleet_event("fleet_draft", params, socket) do
    case socket.assigns.fleet_form do
      %{state: :editing} = form ->
        case draft_text(params) do
          {:ok, text} -> assign(socket, fleet_form: %{form | seats_json: text}, fleet_error: nil)
          {:error, message} -> assign(socket, fleet_error: message)
        end

      _ ->
        socket
    end
  end

  defp fleet_event("save_fleet", params, socket) do
    case socket.assigns.fleet_form do
      %{state: :editing} = form ->
        with {:ok, text} <- draft_text(params) do
          form = %{form | seats_json: text}
          socket = assign(socket, fleet_form: form, fleet_error: nil)

          with {:ok, seats} when is_list(seats) <- Jason.decode(text),
               {:ok, request} <-
                 FleetLoadout.validate(%{
                   "revision" => form.revision,
                   "idempotency_key" => form.idempotency_key,
                   "seats" => seats
                 }) do
            submit_fleet(socket, request)
          else
            {:error, _, message} -> assign(socket, fleet_error: message)
            _ -> assign(socket, fleet_error: "Seats must be a valid JSON array.")
          end
        else
          {:error, message} -> assign(socket, fleet_error: message)
        end

      # A queued duplicate submit cannot create another revision, and cannot
      # mutate the exact request retained after an uncertain result.
      _ ->
        socket
    end
  end

  defp fleet_event("retry_fleet", _params, socket) do
    case socket.assigns.fleet_form do
      %{state: :uncertain, submitted: request} when is_map(request) ->
        submit_fleet(socket, request)

      _ ->
        socket
    end
  end

  defp fleet_event(_event, _params, socket), do: socket

  defp draft_text(params) when is_map(params) do
    text = params["seats_json"]

    cond do
      Enum.any?(Map.keys(params), &(&1 not in ["seats_json", "_target"])) ->
        {:error, "Only desired seats can be edited; fleet identity and revision are server-held."}

      not is_binary(text) ->
        {:error, "Supply the desired seats as JSON text."}

      byte_size(text) > @max_draft_bytes ->
        {:error, "Desired seats JSON must be at most 65,536 bytes (maximum 32 seats)."}

      true ->
        {:ok, text}
    end
  end

  defp draft_text(_), do: {:error, "Supply the desired seats as JSON text."}

  defp load_fleet(socket, id) do
    case fleet_call(:show, [id, socket.assigns.capability]) do
      {:ok, %{"loadout" => loadout}} ->
        form = %{
          id: id,
          revision: loadout["revision"],
          idempotency_key: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
          seats_json: desired_json(loadout),
          loadout: loadout,
          submitted: nil,
          state: :editing,
          replayed: false
        }

        assign(socket, fleet_form: form, fleet_error: nil)

      {:error, "forbidden", _message} ->
        assign(socket,
          fleet_form: nil,
          fleet_error: "Captain access required for fleet loadouts."
        )

      {:error, _code, message} ->
        assign(socket, fleet_error: message)
    end
  end

  defp submit_fleet(socket, request) do
    form = socket.assigns.fleet_form
    result = fleet_call(:replace, [form.id, socket.assigns.capability, request])

    case result do
      {:ok, %{"loadout" => loadout} = response} ->
        assign(socket,
          fleet_form: %{
            form
            | loadout: loadout,
              revision: loadout["revision"],
              seats_json: desired_json(loadout),
              submitted: request,
              state: :saved,
              replayed: response["replayed"] == true
          },
          fleet_error: nil
        )

      {:error, "conflict", message} ->
        assign(socket,
          fleet_form: %{form | submitted: request, state: :conflict},
          fleet_error:
            "Save conflict: #{message} Your draft is kept. Review it before explicitly reloading the latest configuration; reload discards this draft."
        )

      {:error, "forbidden", _message} ->
        assign(socket,
          fleet_form: nil,
          fleet_error: "Captain access required for fleet loadouts."
        )

      {:error, code, message} when code in ["invalid_input", "not_found"] ->
        assign(socket, fleet_error: message)

      {:error, _code, _message} ->
        assign(socket,
          fleet_form: %{form | submitted: request, state: :uncertain},
          fleet_error:
            "The save result is unconfirmed. Your exact submitted request is retained. Retry it safely, or reload to inspect the committed configuration."
        )
    end
  end

  # Only trusted server configuration can replace this module (unit-test seam).
  # Validation is deliberately always the real FleetLoadout validator.
  defp fleet_call(operation, args) do
    service = Application.get_env(:agentboard, :fleet_loadout_service, FleetLoadout)

    apply(service, operation, args)
  rescue
    _ -> {:error, "unavailable", "Fleet loadouts are temporarily unavailable."}
  catch
    :exit, _ -> {:error, "unavailable", "Fleet loadouts are temporarily unavailable."}
  end

  defp desired_json(loadout),
    do:
      Jason.encode!(Enum.map(loadout["seats"] || [], &Map.take(&1, @desired_fields)),
        pretty: true
      )

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
      <section :if={assigns[:frontend_identity]} class="settings-panel">
        <p>Signed in as {@frontend_identity.email}. Captain controls are unlocked separately.</p>
        <form action="/auth/logout" method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button type="submit" class="text-button">Sign out</button>
        </form>
      </section>
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
      <.fleet_loadout_panel capability={@capability} form={@fleet_form} error={@fleet_error} />
      <section class="settings-panel" id="agent-token-settings">
        <h2>Agent API credentials</h2>
        <p>Authentication mode: {Agentboard.Auth.mode()}. Board credentials are separate from worker and Mattermost credentials.</p>
        <%= if Captain.authorized?(@capability) do %>
          <form action="/settings/agent-tokens/issue" method="post" class="settings-form">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <label>Registered agent ID <input name="agent_id" required /></label><button type="submit">Issue credential download</button>
          </form>
          <form action="/settings/agent-tokens/rotate" method="post" class="settings-form">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <label>Registered agent ID <input name="agent_id" required /></label><button type="submit">Rotate and download once</button>
          </form>
          <form action="/settings/agent-tokens/revoke" method="post" class="settings-form">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <label>Registered agent ID <input name="agent_id" required /></label><button type="submit">Revoke active credentials</button>
          </form>
          <p>The captain handles the download. Set its permissions to 0600 before use; the CLI rejects other permissions. Prefer the CLI --out flow for direct protected custody. Tokens are never retained in this page.</p>
          <form phx-submit="list_credentials" class="settings-form"><label>Registered agent ID <input name="agent_id" required /></label><button type="submit">List credential metadata</button></form>
          <div :if={@credential_agent}><h3>Credentials for {@credential_agent}</h3><p :if={@credential_records==[]}>No credentials issued.</p><dl :for={row <- @credential_records}><dt>Fingerprint</dt><dd>{row.fingerprint}</dd><dt>Scope / issuer</dt><dd>{row.scope} / {row.issuer}</dd><dt>Created</dt><dd>{row.created_at}</dd><dt>Last used</dt><dd>{row.last_used_at || "Never"}</dd><dt>Revoked</dt><dd>{row.revoked_at || "Active"}</dd></dl></div>
        <% else %>
          <p>Unlock captain controls to administer credentials.</p>
        <% end %>
      </section>
    </main>
    """
  end

  def fleet_loadout_panel(assigns) do
    ~H"""
    <section id="fleet-loadout-settings" class="settings-panel my-5">
      <h2>Fleet loadouts</h2>
      <p>Store desired configuration for a named fleet. Every loadout is disabled and not activatable. Saving does not start workers, change agent observations, or authorize automatic work.</p>
      <p>Model catalog: unverified. Host readiness: unverified. Desired model, effort, and host values are configuration intent only.</p>
      <p :if={@error} id="fleet-loadout-error" class="notice danger" role="alert">{@error}</p>
      <%= if Captain.authorized?(@capability) do %>
        <form :if={!@form} id="fleet-select" phx-submit="open_fleet" class="settings-form">
          <label>Fleet slug <input name="fleet_id" maxlength="128" placeholder="engineering" required /></label>
          <button type="submit" phx-disable-with="Loading…">Load fleet</button>
        </form>
        <div :if={@form} id="fleet-loadout-editor">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h3>Fleet {@form.id}</h3>
            <button type="button" phx-click="close_fleet" class="text-button">Dismiss editor</button>
          </div>
          <p class="my-3">Expected revision {@form.revision}. Disabled · Not activatable</p>
          <p :if={@form.state == :saved} class="notice healthy" role="status">
            Configuration saved at revision {@form.revision}. {if @form.replayed, do: "The original save was confirmed; no additional update was made.", else: "No workers were started."}
          </p>
          <form id="fleet-loadout-form" phx-change="fleet_draft" phx-submit="save_fleet" class="settings-form">
            <label for="fleet-seats-json">Desired seats (JSON array, maximum 32)</label>
            <p id="fleet-seats-help">Each seat must contain exactly seat_id, agent_id, harness, desired_host_id, desired_model, desired_effort, and scope_revision. Use the current canonical scope revision shown below, or consult the Agents roster when adding a seat. Scope policy itself is read-only here. An empty array removes all configured seats.</p>
            <textarea id="fleet-seats-json" name="seats_json" rows="18" maxlength="65536" spellcheck="false" aria-describedby="fleet-seats-help" readonly={@form.state != :editing} class="w-full min-w-0 rounded border border-line bg-canvas p-3 font-mono text-sm text-ink focus:outline-2 focus:outline-accent">{@form.seats_json}</textarea>
            <button :if={@form.state == :editing} type="submit" phx-disable-with="Saving configuration…">Save disabled configuration</button>
          </form>
          <div class="my-3 flex flex-wrap gap-3">
            <button :if={@form.state == :uncertain} type="button" phx-click="retry_fleet" phx-disable-with="Confirming…">Retry exact submitted save</button>
            <button type="button" phx-click="reload_fleet" phx-disable-with="Loading…">
              {if @form.state == :saved, do: "Reload to edit again", else: "Discard draft and reload latest"}
            </button>
          </div>
          <h3>Loaded configuration and observed state</h3>
          <p class="my-2 text-sm text-muted">Snapshot from the latest successful load or save response. A replay confirms the original response; reload to refresh observations. Unsaved JSON edits appear only in the editor above.</p>
          <dl>
            <dt>Configured seats</dt><dd>{@form.loadout["seat_count"]}</dd>
            <dt>Changed by</dt><dd>{@form.loadout["changed_by"] || "Not yet saved"}</dd>
            <dt>Updated at</dt><dd>{@form.loadout["updated_at"] || "Not yet saved"}</dd>
          </dl>
          <p :if={@form.loadout["seats"] == []} class="my-3">No configured seats.</p>
          <article :for={seat <- @form.loadout["seats"]} class="my-4 rounded border border-line p-3">
            <h3>Seat {seat["seat_id"]}</h3>
            <dl>
              <dt>Agent / harness</dt><dd>{seat["agent_id"]} / {seat["harness"]}</dd>
              <dt>Desired host</dt><dd>{seat["desired_host_id"]} (unverified)</dd>
              <dt>Desired model</dt><dd>{seat["desired_model"]} (catalog unverified)</dd>
              <dt>Desired effort</dt><dd>{seat["desired_effort"]} (unverified)</dd>
              <dt>Observed model</dt><dd>{seat["observed_model"] || "Not observed"}</dd>
              <dt>Observed retired at</dt><dd>{seat["observed_retired_at"] || "No retirement observed"}</dd>
              <dt>Desired scope revision</dt><dd>{seat["scope_revision"]}</dd>
              <dt>Current scope revision</dt><dd>{seat["current_scope_revision"]}</dd>
            </dl>
            <p :if={seat["scope_revision"] != seat["current_scope_revision"]} class="notice warning my-3">Scope has changed since this seat configuration was saved. Review the canonical policy and its current revision before saving.</p>
            <details class="mt-3">
              <summary>Canonical current scope (read-only)</summary>
              <pre class="mt-2 overflow-auto whitespace-pre-wrap break-words text-xs">{Jason.encode!(seat["scope"], pretty: true)}</pre>
            </details>
          </article>
        </div>
      <% else %>
        <p>Unlock captain controls to view or change fleet loadouts.</p>
      <% end %>
    </section>
    """
  end
end
