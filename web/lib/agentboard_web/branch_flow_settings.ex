defmodule AgentboardWeb.BranchFlowSettings do
  @moduledoc "Captain pin editor with server-held revision, exact-request reconciliation and explicit discard."
  use Phoenix.Component
  alias Agentboard.Captain
  alias Agentboard.Delivery.BranchFlow.{Inventory, Settings}

  @events ~w(open_branch_flow_settings set_branch_flow_pin move_branch_flow_pin remove_branch_flow_pin search_branch_flow_pins page_branch_flow_pins save_branch_flow_pins reload_branch_flow_pins close_branch_flow_pins reconcile_branch_flow_pins retry_branch_flow_pins confirm_branch_flow_discard cancel_branch_flow_discard)
  def events, do: @events

  def init(socket),
    do: assign(socket, branch_flow_form: nil, branch_flow_pending: nil, branch_flow_error: nil)

  def handle_event(event, params, socket) do
    cond do
      not Captain.authorized?(socket.assigns.capability) ->
        assign(socket,
          branch_flow_form: nil,
          branch_flow_pending: nil,
          branch_flow_error: "Captain access required for PR branch-flow settings."
        )

      not valid_event_params?(event, params) ->
        assign(socket,
          branch_flow_error:
            "Only pin controls can be edited; captain authority, revision and save key are server-held."
        )

      true ->
        event(event, params, socket)
    end
  end

  defp event("open_branch_flow_settings", _, %{assigns: %{branch_flow_form: nil}} = socket) do
    case socket.assigns.branch_flow_pending do
      nil ->
        load(socket)

      pending ->
        # Dismissal hides the editor, not an unresolved receipt. A deliberate
        # reopen must establish the old outcome before minting a new save key.
        socket
        |> assign(branch_flow_form: %{pending | confirmation: nil}, branch_flow_pending: nil)
        |> reconcile()
    end
  end

  # All reads and writes are synchronous in this LiveView process. A queued
  # response cannot re-open a dismissed editor or overwrite a newer draft.
  defp event("open_branch_flow_settings", _, socket), do: socket
  defp event(_, _, %{assigns: %{branch_flow_form: nil}} = socket), do: socket

  defp event("set_branch_flow_pin", %{"repository" => repo, "selected" => selected}, socket) do
    form = socket.assigns.branch_flow_form
    selected? = repo in form.draft

    cond do
      not editable?(form) ->
        socket

      selected == "false" ->
        edit(socket, List.delete(form.draft, repo))

      selected? ->
        socket

      length(form.draft) >= 5 ->
        error(
          socket,
          "Choose at most five pinned repositories. Remove a pin before adding another."
        )

      form.chooser.error != nil ->
        error(
          socket,
          "Repository inventory is unavailable; retry the search before selecting a repository."
        )

      not Enum.any?(form.chooser.repositories, &(&1.repository == repo)) ->
        error(socket, "Choose an eligible repository from the current search page.")

      true ->
        socket = edit(socket, form.draft ++ [repo])
        update_form(socket, &%{&1 | availability: Map.put(&1.availability, repo, true)})
    end
  end

  defp event("remove_branch_flow_pin", %{"repository" => repo}, socket) do
    form = socket.assigns.branch_flow_form
    if editable?(form), do: edit(socket, List.delete(form.draft, repo)), else: socket
  end

  defp event("move_branch_flow_pin", %{"repository" => repo, "direction" => direction}, socket) do
    form = socket.assigns.branch_flow_form
    index = Enum.find_index(form.draft, &(&1 == repo))
    target = if is_integer(index), do: index + if(direction == "up", do: -1, else: 1)

    if editable?(form) and is_integer(target) and target >= 0 and target < length(form.draft) do
      other = Enum.at(form.draft, target)
      edit(socket, form.draft |> List.replace_at(target, repo) |> List.replace_at(index, other))
    else
      socket
    end
  end

  defp event("search_branch_flow_pins", %{"chooser_q" => query}, socket) do
    if String.length(query) <= 120 do
      search(socket, query, nil)
    else
      error(socket, "Search must be at most 120 characters.")
    end
  end

  defp event("page_branch_flow_pins", %{"direction" => direction}, socket) do
    form = socket.assigns.branch_flow_form

    cursor =
      if direction == "next", do: form.chooser.next_cursor, else: form.chooser.previous_cursor

    if is_binary(cursor), do: search(socket, form.query, cursor), else: socket
  end

  defp event("save_branch_flow_pins", _, socket) do
    form = socket.assigns.branch_flow_form

    cond do
      form.state != :editing or not dirty?(form) ->
        socket

      form.confirmation != nil ->
        socket

      Enum.any?(form.draft, &(Map.get(form.availability, &1) != true)) ->
        error(
          socket,
          "Remove unavailable pins explicitly before saving. No saved pin has been changed."
        )

      true ->
        submit(socket, %{
          "revision" => form.revision,
          "idempotency_key" => form.idempotency_key,
          "pinned_repositories" => form.draft
        })
    end
  end

  defp event("retry_branch_flow_pins", _, socket) do
    case socket.assigns.branch_flow_form do
      %{state: :retry_ready, submitted: request, confirmation: nil} when is_map(request) ->
        submit(socket, request)

      _ ->
        socket
    end
  end

  defp event("reconcile_branch_flow_pins", _, socket) do
    if socket.assigns.branch_flow_form.state in [:uncertain, :retry_ready],
      do: reconcile(socket),
      else: socket
  end

  defp event("close_branch_flow_pins", _, socket), do: request_discard(socket, :close)
  defp event("reload_branch_flow_pins", _, socket), do: request_discard(socket, :reload)

  defp event("cancel_branch_flow_discard", _, socket),
    do: update_form(socket, &%{&1 | confirmation: nil})

  defp event("confirm_branch_flow_discard", _, socket) do
    case socket.assigns.branch_flow_form.confirmation do
      :close ->
        close(socket)

      :reload ->
        if socket.assigns.branch_flow_form.state == :retry_ready do
          reconciled = reconcile(socket)

          if reconciled.assigns.branch_flow_form &&
               reconciled.assigns.branch_flow_form.state == :retry_ready,
             do: load(reconciled),
             else: reconciled
        else
          load(socket)
        end

      _ ->
        socket
    end
  end

  defp event(_, _, socket), do: socket

  defp request_discard(socket, action) do
    form = socket.assigns.branch_flow_form

    cond do
      action == :reload and form.state == :uncertain ->
        # An unconfirmed request cannot be replaced by a new revision/key, even
        # through Reload. Reconcile first; an unavailable read keeps it intact.
        reconcile(socket)

      dirty?(form) ->
        update_form(socket, &%{&1 | confirmation: action})

      action == :close ->
        close(socket)

      true ->
        load(socket)
    end
  end

  defp close(socket) do
    form = socket.assigns.branch_flow_form
    pending = if form.state in [:uncertain, :retry_ready], do: form
    assign(socket, branch_flow_form: nil, branch_flow_pending: pending, branch_flow_error: nil)
  end

  defp load(socket) do
    case settings_call(:show, [socket.assigns.capability]) do
      {:ok, %{"settings" => config, "availability" => availability}} ->
        if valid_config?(config) and is_map(availability) do
          form = %{
            config: config,
            editor_generation: System.unique_integer([:positive]),
            revision: config["revision"],
            idempotency_key: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
            draft: config["pinned_repositories"],
            availability: availability,
            query: "",
            chooser: chooser(%{}),
            state: :editing,
            submitted: nil,
            committed: nil,
            confirmation: nil
          }

          assign(socket, branch_flow_form: form, branch_flow_pending: nil, branch_flow_error: nil)
        else
          error(
            socket,
            "Saved pins could not be read. The last loaded configuration and draft are unchanged."
          )
        end

      {:error, "forbidden", _} ->
        forbidden(socket)

      _ ->
        error(
          socket,
          "Saved pins are unavailable. The last loaded configuration and draft are unchanged; this is not an empty pin list."
        )
    end
  end

  defp search(socket, query, cursor) do
    result = chooser(%{"chooser_q" => query, "chooser_cursor" => cursor})
    update_form(socket, &%{&1 | query: query, chooser: result})
  end

  defp edit(socket, draft) do
    socket
    |> update_form(&%{&1 | draft: draft, confirmation: nil})
    |> error(nil)
  end

  defp submit(socket, request) do
    socket = update_form(socket, &%{&1 | submitted: request})

    case settings_call(:replace, [socket.assigns.capability, request]) do
      {:ok, %{"settings" => config, "replayed" => false}} ->
        if valid_config?(config) do
          saved(socket, config, config, socket.assigns.branch_flow_form.availability)
        else
          uncertain(socket)
        end

      {:ok, %{"replayed" => true}} ->
        # A replay receipt may predate a later captain's configuration. Never
        # label the original receipt as the latest settings: read both first.
        socket |> update_form(&%{&1 | state: :uncertain}) |> reconcile()

      {:error, "conflict", message} ->
        conflict(socket, message)

      {:error, "forbidden", _} ->
        forbidden(socket)

      {:error, code, message} when code in ["invalid_input", "not_found"] ->
        socket |> update_form(&%{&1 | state: :editing, submitted: nil}) |> error(message)

      _ ->
        uncertain(socket)
    end
  end

  defp reconcile(socket) do
    form = socket.assigns.branch_flow_form

    case settings_call(:reconcile, [socket.assigns.capability, form.submitted]) do
      {:ok,
       %{
         "status" => "committed",
         "settings" => current,
         "committed_settings" => committed,
         "availability" => availability
       }} ->
        if valid_config?(current) and valid_config?(committed) and is_map(availability),
          do: saved(socket, current, committed, availability),
          else: uncertain(socket)

      {:ok, %{"status" => "retry_safe", "settings" => current}} ->
        if valid_config?(current) and current["revision"] == form.revision do
          socket
          |> update_form(&%{&1 | state: :retry_ready, confirmation: nil})
          |> error(
            "Read-only reconciliation found no committed receipt and the expected revision is unchanged. You may retry the exact submitted save."
          )
        else
          uncertain(socket)
        end

      {:ok, %{"status" => "conflict"}} ->
        conflict(socket, "The persisted revision changed before your save could be confirmed.")

      {:error, "conflict", message} ->
        conflict(socket, message)

      {:error, "forbidden", _} ->
        forbidden(socket)

      _ ->
        uncertain(socket)
    end
  end

  defp saved(socket, current, committed, availability) do
    socket
    |> update_form(
      &%{
        &1
        | config: current,
          draft: current["pinned_repositories"],
          availability: availability,
          state: :saved,
          committed: committed,
          confirmation: nil
      }
    )
    |> error(nil)
  end

  defp uncertain(socket) do
    socket
    |> update_form(&%{&1 | state: :uncertain, confirmation: nil})
    |> error(
      "Save outcome unconfirmed. The exact submitted request and key are retained. Reconcile from saved state before any retry; unavailable reads do not mean the save failed."
    )
  end

  defp conflict(socket, message) do
    socket
    |> update_form(&%{&1 | state: :conflict, confirmation: nil})
    |> error(
      "Save conflict: #{message} Your draft is kept. Reload is explicit and discards it only after confirmation."
    )
  end

  defp forbidden(socket),
    do:
      assign(socket,
        branch_flow_form: nil,
        branch_flow_pending: nil,
        branch_flow_error: "Captain access required for PR branch-flow settings."
      )

  defp settings_call(operation, args) do
    service = Application.get_env(:agentboard, :branch_flow_settings_service, Settings)
    apply(service, operation, args)
  rescue
    _ -> {:error, "unavailable", "Settings unavailable."}
  catch
    :exit, _ -> {:error, "unavailable", "Settings unavailable."}
  end

  defp chooser(params) do
    service = Application.get_env(:agentboard, :branch_flow_inventory_service, Inventory)
    apply(service, :chooser, [params])
  rescue
    _ -> unavailable_chooser()
  catch
    :exit, _ -> unavailable_chooser()
  end

  defp unavailable_chooser,
    do: %{
      repositories: [],
      next_cursor: nil,
      previous_cursor: nil,
      total: nil,
      error: "Repository inventory unavailable; no empty inventory is implied."
    }

  defp valid_config?(%{"revision" => revision, "pinned_repositories" => pins}),
    do:
      is_integer(revision) and revision >= 0 and is_list(pins) and length(pins) <= 5 and
        Enum.all?(pins, &is_binary/1) and length(Enum.uniq(pins)) == length(pins)

  defp valid_config?(_), do: false

  defp update_form(socket, fun),
    do: assign(socket, branch_flow_form: fun.(socket.assigns.branch_flow_form))

  defp error(socket, message), do: assign(socket, branch_flow_error: message)
  defp editable?(form), do: form.state == :editing and form.confirmation == nil
  def dirty?(nil), do: false

  def dirty?(form),
    do:
      form.draft != form.config["pinned_repositories"] or
        form.state in [:uncertain, :retry_ready, :conflict]

  defp valid_event_params?(event, params) when is_map(params) do
    fields =
      case event do
        "set_branch_flow_pin" -> ~w(repository selected)
        "move_branch_flow_pin" -> ~w(repository direction)
        "remove_branch_flow_pin" -> ~w(repository)
        "search_branch_flow_pins" -> ~w(chooser_q)
        "page_branch_flow_pins" -> ~w(direction)
        _ -> []
      end

    # LiveView click payloads include the DOM button/input's empty value.
    # It is transport metadata, never a desired field or authority source.
    supplied = Map.drop(params, ["_target", "value"])
    transport_valid = Map.get(params, "value", "") == ""

    transport_valid and Enum.sort(Map.keys(supplied)) == Enum.sort(fields) and
      Enum.all?(Map.values(supplied), &is_binary/1) and
      (not Map.has_key?(supplied, "repository") or byte_size(supplied["repository"]) <= 256) and
      (event != "set_branch_flow_pin" or supplied["selected"] in ["true", "false"]) and
      (event != "move_branch_flow_pin" or supplied["direction"] in ["up", "down"]) and
      (event != "page_branch_flow_pins" or supplied["direction"] in ["next", "previous"])
  end

  defp valid_event_params?(_, _), do: false

  defp count(value) when is_integer(value), do: Integer.to_string(value)
  defp count(_), do: "Count unavailable"

  def pin_id(repository), do: "branch-flow-pin-" <> Base.url_encode64(repository, padding: false)

  def panel(assigns) do
    ~H"""
    <section id="branch-flow-settings" class="settings-panel my-5" aria-labelledby="branch-flow-settings-heading">
      <h2 id="branch-flow-settings-heading">PR branch flow</h2>
      <p>Pin up to five locally tracked repositories in captain order. Pins change display only: they do not enroll repositories, change schedules, or acknowledge retained red workflow obligations.</p>
      <p class="text-muted">Integration roles and intake changes are not available in this slice. The branch-flow presentation rollout is controlled separately.</p>
      <p :if={@error} id="branch-flow-settings-error" class="notice danger" role="alert">{@error}</p>
      <%= if Captain.authorized?(@capability) do %>
        <button :if={!@form} id="branch-flow-open" type="button" phx-click="open_branch_flow_settings" phx-disable-with="Loading…">Edit pinned repositories</button>
        <div :if={@form} id="branch-flow-pin-editor" phx-hook="BranchFlowPinEditor" data-dirty={to_string(dirty?(@form))} data-editor-generation={@form.editor_generation} data-state={@form.state} data-revision={@form.config["revision"]}>
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h3 id="branch-flow-pin-editor-heading" tabindex="-1">Pinned repository order</h3>
            <button id="branch-flow-close" type="button" phx-click="close_branch_flow_pins" class="text-button">Close pin editor</button>
          </div>
          <p>Loaded revision {@form.config["revision"]} · {length(@form.draft)} of 5 pins selected. Search and paging keep your selected order. Changes are saved only with Save.</p>
          <p :if={@form.state == :saved} id="branch-flow-saved" class="notice healthy" role="status">
            Your save was committed at revision {@form.committed["revision"]}.
            <%= if @form.config["revision"] != @form.committed["revision"] do %>
              A later configuration is now saved at revision {@form.config["revision"]}; the list below shows that later configuration.
            <% else %>
              This is the confirmed saved snapshot. Reload to edit again.
            <% end %>
          </p>
          <div :if={@form.confirmation} id="branch-flow-discard-confirmation" role="alertdialog" aria-labelledby="branch-flow-discard-heading" aria-describedby="branch-flow-discard-description" class="notice warning my-3">
            <h4 id="branch-flow-discard-heading">Discard this local draft?</h4>
            <p id="branch-flow-discard-description">{if @form.confirmation == :close, do: "Close the editor", else: "Reload the latest saved configuration"} and discard unsaved changes. Any save already accepted by the server remains saved; closing does not undo it. An unconfirmed submitted request is retained for read-only reconciliation when you reopen this editor.</p>
            <button id="branch-flow-discard-cancel" type="button" phx-click="cancel_branch_flow_discard">Keep editing</button>
            <button id="branch-flow-discard-confirm" type="button" phx-click="confirm_branch_flow_discard">Discard draft and {if @form.confirmation == :close, do: "close", else: "reload"}</button>
          </div>
          <ol id="branch-flow-selected-pins" class="my-3 space-y-3" aria-label="Selected repository pin order">
            <li :for={{repository, index} <- Enum.with_index(@form.draft)} data-selected-pin={repository} class="rounded border border-line p-3">
              <p class="break-all">{index + 1}. {repository}</p>
              <p :if={Map.get(@form.availability, repository) != true} class="notice warning">Unavailable saved pin. Its identity is preserved until you explicitly remove it; saving while it remains is blocked.</p>
              <div class="flex flex-wrap gap-2">
                <button type="button" phx-click="move_branch_flow_pin" phx-value-repository={repository} phx-value-direction="up" data-pin-edit="true" disabled={!editable?(@form) or index == 0} aria-label={"Move #{repository} up"}>Move up</button>
                <button type="button" phx-click="move_branch_flow_pin" phx-value-repository={repository} phx-value-direction="down" data-pin-edit="true" disabled={!editable?(@form) or index == length(@form.draft) - 1} aria-label={"Move #{repository} down"}>Move down</button>
                <button type="button" phx-click="remove_branch_flow_pin" phx-value-repository={repository} data-pin-edit="true" disabled={!editable?(@form)} aria-label={"Remove #{repository} pin"}>Remove</button>
              </div>
            </li>
          </ol>
          <p :if={@form.draft == []}>No pins selected. Eligible repositories will use busiest tracked-open ranking.</p>
          <form id="branch-flow-pin-search" phx-submit="search_branch_flow_pins" class="settings-form">
            <label for="branch-flow-pin-query">Search tracked repositories</label>
            <input id="branch-flow-pin-query" name="chooser_q" value={@form.query} maxlength="120" />
            <button type="submit" phx-disable-with="Searching…">Search repositories</button>
          </form>
          <p :if={@form.chooser.error} id="branch-flow-pin-inventory-error" class="notice warning" role="alert">{@form.chooser.error} Your selected pins are unchanged.</p>
          <fieldset id="branch-flow-pin-chooser" class="my-3" disabled={!editable?(@form)}>
            <legend>Available tracked repositories, up to 20 per page</legend>
            <label :for={row <- @form.chooser.repositories} for={pin_id(row.repository)} data-chooser-repository={row.repository} class="my-2 flex min-h-11 items-center gap-2 break-all">
              <input id={pin_id(row.repository)} type="checkbox" value="" phx-click="set_branch_flow_pin" phx-value-repository={row.repository} phx-value-selected={if row.repository in @form.draft, do: "false", else: "true"} checked={row.repository in @form.draft} disabled={row.repository not in @form.draft and length(@form.draft) >= 5} data-pin-edit="true" />
              <span>{row.repository} · {count(row.open_count)} tracked open · {count(row.unknown_lifecycle_count)} lifecycle unknown · {count(row.red_count)} retained red; branch health unknown</span>
            </label>
          </fieldset>
          <p :if={!@form.chooser.error and @form.chooser.repositories == []}>No tracked repositories match this search. Selected pins are unchanged.</p>
          <p :if={is_integer(@form.chooser.total)}>Showing {length(@form.chooser.repositories)} of {@form.chooser.total} matching tracked repositories.</p>
          <nav aria-label="Pin repository search pages" class="my-3 flex flex-wrap gap-3">
            <button id="branch-flow-pin-previous" type="button" phx-click="page_branch_flow_pins" phx-value-direction="previous" disabled={is_nil(@form.chooser.previous_cursor)}>Previous repositories</button>
            <button id="branch-flow-pin-next" type="button" phx-click="page_branch_flow_pins" phx-value-direction="next" disabled={is_nil(@form.chooser.next_cursor)}>Next repositories</button>
          </nav>
          <div class="my-3 flex flex-wrap gap-3">
            <button :if={@form.state == :editing} id="branch-flow-save" type="button" phx-click="save_branch_flow_pins" phx-disable-with="Saving…" disabled={!dirty?(@form) or @form.confirmation != nil}>Save pinned repositories</button>
            <button :if={@form.state in [:uncertain, :retry_ready]} id="branch-flow-reconcile" type="button" phx-click="reconcile_branch_flow_pins" phx-disable-with="Checking saved state…">Reconcile saved state (read-only)</button>
            <button :if={@form.state == :retry_ready} id="branch-flow-retry" type="button" phx-click="retry_branch_flow_pins" phx-disable-with="Retrying exact save…" disabled={@form.confirmation != nil}>Retry exact submitted save</button>
            <button id="branch-flow-reload" type="button" phx-click="reload_branch_flow_pins" phx-disable-with="Loading…">{if @form.state == :uncertain, do: "Reconcile before reload", else: "Reload saved pins"}</button>
          </div>
          <p class="text-muted">Saved snapshot: revision {@form.config["revision"]} · changed by {@form.config["changed_by"] || "Not yet saved"} · updated {@form.config["updated_at"] || "Not yet saved"}. Reload is explicit; nothing auto-saves.</p>
        </div>
      <% else %>
        <p>Unlock captain controls to view or change pinned repositories.</p>
      <% end %>
    </section>
    """
  end
end
