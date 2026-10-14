defmodule Agentboard.Intake do
  @moduledoc """
  Work intake: any authorized HTTPS client files board cards and, optionally,
  GitHub issues through one idempotent contract.

  A request commits its record, every card and every pending issue intent in
  one transaction; GitHub is called afterwards by the `Intake.Issues` outbox,
  so an outage never blocks filing. An import turns existing open issues into
  cards linked to them and creates no issue; it reads GitHub first, so an
  outage fails it whole. The same request key with the same
  normalized payload replays the current view of the original request; a
  changed payload under that key conflicts. Cards are ordinary tasks.

  Off unless `AGENTBOARD_INTAKE_ENABLED=true`. Every operation requires the
  captain capability for now; scoped helper credentials are a later lane.
  Intake only files work: it never claims, assigns or coordinates.
  """
  use Ash.Domain, backwards_compatible_interface?: false

  resources do
    resource(Agentboard.Intake.Request)
    resource(Agentboard.Intake.Item)
    resource(Agentboard.Intake.Dispatcher)
  end

  alias Agentboard.Board.Operations
  alias Agentboard.Board.Resources.Task
  alias Agentboard.{Input, Repo}
  alias Agentboard.Intake.{Import, Issues, Item, Payload, Request}
  require Ash.Query

  @key_conflict "Request key was already used for a different intake payload"

  def enabled?, do: Application.get_env(:agentboard, :intake_enabled, false) == true

  # Captain-configured repositories that intake may file into, lowercased.
  def repositories, do: Application.get_env(:agentboard, :intake_repositories, [])

  def file(actor, data) do
    with {:ok, payload} <- Payload.normalize(data),
         {:ok, _} <- ensure_identity(actor) do
      digest = Payload.digest(payload["items"])

      Operations.transaction(fn ->
        lock_key(actor["agent"], payload["request_key"])

        case existing(actor["agent"], payload["request_key"]) do
          nil ->
            request = create(actor, payload, digest)
            view(request, false)

          %Request{payload_sha256: ^digest} = request ->
            view(request, true)

          _ ->
            Operations.reject("conflict", @key_conflict)
        end
      end)
    end
  end

  # GitHub is read only for a new key, before the transaction: a replay never
  # calls GitHub and a GitHub failure writes nothing.
  def import_issues(actor, data) do
    with {:ok, request} <- Payload.normalize_import(data),
         {:ok, _} <- ensure_identity(actor),
         digest = Payload.import_digest(request),
         :new <- prior(actor["agent"], request["request_key"], digest),
         :ok <- in_scope(request["repository"]),
         {:ok, selected} <- Import.select(request, &linked(request["repository"], &1)) do
      Operations.transaction(fn ->
        lock_key(actor["agent"], request["request_key"])

        case existing(actor["agent"], request["request_key"]) do
          nil -> actor |> create_import(request, digest, selected) |> view(false)
          %Request{payload_sha256: ^digest} = replay -> view(replay, true)
          _ -> Operations.reject("conflict", @key_conflict)
        end
      end)
    end
  rescue
    DBConnection.ConnectionError -> {:error, "unavailable", "Board database is unavailable"}
  end

  def show(id, actor) do
    with {:ok, request} <- visible(id, actor) do
      {:ok, view(request, false)}
    end
  end

  # Cancels the request's unstarted cards (all, or the listed item IDs).
  # Started cards and in-flight issue creates are reported, never forced.
  def cancel(id, actor, data) do
    with {:ok, selected} <- cancel_selection(data),
         {:ok, request} <- visible(id, actor) do
      Operations.transaction(fn ->
        items = lock_items(request.id)

        if selected != :all and
             not MapSet.subset?(MapSet.new(selected), MapSet.new(items, & &1.id)),
           do: Operations.reject("not_found", "Intake item not found in this request")

        outcomes =
          for item <- items, selected == :all or item.id in selected do
            {item.id, cancel_item(item, actor)}
          end

        view(request, false)
        |> Map.put("cancelled", for({id, :cancelled} <- outcomes, do: id))
        |> Map.put(
          "skipped",
          for({id, {:skipped, reason}} <- outcomes, do: %{"id" => id, "reason" => reason})
        )
      end)
    end
  end

  # Explicit decision on an unresolved issue intent: `reconcile` returns it
  # to the outbox, which scans for the marker before any new create;
  # `abandon` stops all further GitHub calls for it. The card is unchanged.
  def resolve(id, item_id, action, actor) when action in ~w(reconcile abandon) do
    with {:ok, request} <- visible(id, actor) do
      Operations.transaction(fn ->
        item =
          uuid?(item_id) &&
            Enum.find(lock_items(request.id), &(&1.id == Ecto.UUID.cast!(item_id)))

        unless item, do: Operations.reject("not_found", "Intake item not found in this request")
        resolve_item(item, action)
        view(request, false)
      end)
    end
  end

  def resolve(_id, _item_id, _action, _actor),
    do: {:error, "invalid_input", "action must be reconcile or abandon"}

  defp create(actor, payload, digest) do
    out_of_scope = Enum.reject(payload["items"], &(&1["repository"] in repositories()))

    if out_of_scope != [],
      do:
        Operations.reject(
          "forbidden",
          "Repository is outside the intake scope: " <>
            Enum.map_join(
              Enum.uniq_by(out_of_scope, & &1["repository"]),
              ", ",
              & &1["repository"]
            )
        )

    stamp = Operations.now()

    request =
      Operations.create(
        Request,
        :file,
        %{
          id: Ash.UUID.generate(),
          filer_id: actor["agent"],
          request_key: payload["request_key"],
          payload_sha256: digest,
          payload: payload,
          created_at: stamp
        },
        actor
      )

    payload["items"]
    |> Enum.with_index()
    |> Enum.each(fn {filed, position} ->
      item_id = Ash.UUID.generate()
      task_id = card_id(filed["title"], item_id)

      card = %{
        "title" => filed["title"],
        "description" => filed["body"],
        "priority" => filed["priority"],
        "repo" => filed["repository"],
        "labels" => filed["labels"]
      }

      with {:error, code, message} <- Input.task("create", card),
           do: Operations.reject(code, message)

      Operations.create_task!(task_id, actor, card)

      Operations.create(
        Item,
        :file,
        %{
          id: item_id,
          request_id: request.id,
          position: position,
          task_id: task_id,
          repository: filed["repository"],
          issue: filed["issue"],
          issue_state: if(filed["issue"], do: "pending", else: "none"),
          next_attempt_at: if(filed["issue"], do: stamp),
          created_at: stamp,
          updated_at: stamp
        },
        actor
      )

      # Inserted in the same transaction: the job exists only if the intent
      # committed. The cron sweep covers a lost or paused job.
      if filed["issue"], do: Issues.enqueue(item_id)
    end)

    request
  end

  defp prior(filer_id, key, digest) do
    case existing(filer_id, key) do
      nil -> :new
      %Request{payload_sha256: ^digest} = request -> {:ok, view(request, true)}
      _ -> {:error, "conflict", @key_conflict}
    end
  end

  defp in_scope(repository) do
    if repository in repositories(),
      do: :ok,
      else: {:error, "forbidden", "Repository is outside the intake scope: " <> repository}
  end

  # Issue number => the live card already linking that issue. Links are
  # matched case-insensitively; a cancelled card does not hold an issue.
  defp linked(_repository, []), do: %{}

  defp linked(repository, numbers) do
    urls = Enum.map(numbers, &Import.canonical_url(repository, &1))

    %{rows: rows} =
      Repo.statement!(
        "SELECT lower(issue_url), id FROM tasks WHERE lower(issue_url) = ANY($1) AND status <> 'cancelled' ORDER BY created_at, id",
        [urls]
      )

    cards = Enum.reduce(rows, %{}, fn [url, id], acc -> Map.put_new(acc, url, id) end)

    for number <- numbers,
        card = cards[Import.canonical_url(repository, number)],
        into: %{},
        do: {number, card}
  end

  # Imports into one repository serialize and read links again under that
  # lock, so concurrent imports never card the same issue twice.
  defp create_import(actor, request, digest, selected) do
    repository = request["repository"]
    lock_import(repository)
    on_board = linked(repository, Enum.map(selected.picked, & &1["issue_number"]))

    {raced, picked} =
      Enum.split_with(selected.picked, &Map.has_key?(on_board, &1["issue_number"]))

    skipped =
      selected.skipped ++
        for candidate <- raced do
          number = candidate["issue_number"]
          %{"issue_number" => number, "reason" => "already_linked", "task_id" => on_board[number]}
        end

    stamp = Operations.now()

    record =
      Operations.create(
        Request,
        :file,
        %{
          id: Ash.UUID.generate(),
          filer_id: actor["agent"],
          request_key: request["request_key"],
          payload_sha256: digest,
          payload: %{
            "request_key" => request["request_key"],
            "import" => %{
              "repository" => repository,
              "selection" => request["selection"],
              "priority" => request["priority"],
              "skipped" => skipped,
              "bounded" => selected.bounded,
              "next_page" => selected.next_page
            },
            "items" => Enum.map(picked, &Map.take(&1, ~w(issue_number issue_url title)))
          },
          created_at: stamp
        },
        actor
      )

    picked
    |> Enum.with_index()
    |> Enum.each(fn {candidate, position} ->
      item_id = Ash.UUID.generate()
      task_id = card_id(candidate["title"], item_id)

      card = %{
        "title" => candidate["title"],
        "description" => candidate["description"],
        "priority" => request["priority"],
        "repo" => repository,
        "labels" => candidate["labels"],
        "issue_url" => candidate["issue_url"]
      }

      with {:error, code, message} <- Input.task("create", card),
           do: Operations.reject(code, message)

      Operations.create_task!(task_id, actor, card)
      created = Operations.now()

      Operations.create(
        Item,
        :import,
        %{
          id: item_id,
          request_id: record.id,
          position: position,
          task_id: task_id,
          repository: repository,
          issue: true,
          issue_state: "created",
          issue_url: candidate["issue_url"],
          issue_number: candidate["issue_number"],
          reason: "imported",
          resolved_at: created,
          created_at: created,
          updated_at: created
        },
        actor
      )
    end)

    record
  end

  defp cancel_item(item, actor) do
    task = Ash.get!(Task, item.task_id)

    cond do
      not is_nil(item.cancelled_at) ->
        {:skipped, "already_cancelled"}

      item.issue_state == "creating" ->
        {:skipped, "issue_create_in_flight"}

      task.status != "open" or not is_nil(task.assignee_id) ->
        {:skipped, "card_started"}

      true ->
        case Operations.cancel_unstarted_task!(item.task_id, actor) do
          {:skipped, reason} ->
            {:skipped, reason}

          _ ->
            stamp = Operations.now()

            open_intent = item.issue_state in ["pending", "uncertain"]

            Operations.update(
              item,
              :cancel,
              %{
                issue_state: if(open_intent, do: "cancelled", else: item.issue_state),
                next_attempt_at: if(open_intent, do: nil, else: item.next_attempt_at),
                cancelled_at: stamp,
                cancelled_by: actor["agent"],
                updated_at: stamp
              },
              actor
            )

            :cancelled
        end
    end
  end

  defp resolve_item(%{cancelled_at: cancelled_at}, "reconcile") when not is_nil(cancelled_at) do
    Operations.reject(
      "conflict",
      "Cannot reconcile a cancelled intake item; cancel is terminal for the outbox"
    )
  end

  defp resolve_item(%{issue_state: "uncertain"} = item, "reconcile") do
    stamp = Operations.now()

    Operations.update(
      item,
      :resolve,
      %{
        issue_state: "pending",
        duplicate_issue_urls: [],
        reason: nil,
        last_error: "reconcile_requested",
        next_attempt_at: stamp,
        updated_at: stamp
      },
      Issues.actor()
    )

    Issues.enqueue(item.id)
  end

  defp resolve_item(%{issue_state: state} = item, "abandon")
       when state in ~w(pending uncertain) do
    stamp = Operations.now()

    Operations.update(
      item,
      :resolve,
      %{
        issue_state: "abandoned",
        reason: item.reason || "abandoned",
        next_attempt_at: nil,
        resolved_at: stamp,
        updated_at: stamp
      },
      Issues.actor()
    )
  end

  defp resolve_item(%{issue_state: state}, action),
    do:
      Operations.reject(
        "conflict",
        "Cannot #{action} an issue intent in state #{state}; reconcile applies to uncertain, abandon to pending or uncertain"
      )

  defp cancel_selection(data) when data == %{} or is_nil(data), do: {:ok, :all}

  defp cancel_selection(%{"items" => ids} = data)
       when map_size(data) == 1 and is_list(ids) and length(ids) in 1..10 do
    if Enum.all?(ids, &uuid?/1),
      do: {:ok, ids |> Enum.map(&Ecto.UUID.cast!/1) |> Enum.uniq()},
      else: {:error, "invalid_input", "items must list intake item IDs"}
  end

  defp cancel_selection(_),
    do: {:error, "invalid_input", "Cancel accepts an optional items list of 1-10 item IDs"}

  defp visible(id, actor) do
    request =
      if uuid?(id), do: Ash.get!(Request, id, not_found_error?: false), else: nil

    # Filers see their own requests; the captain sees every request.
    if request && (request.filer_id == actor["agent"] or actor["agent"] == "captain"),
      do: {:ok, request},
      else: {:error, "not_found", "Intake request not found"}
  rescue
    DBConnection.ConnectionError -> {:error, "unavailable", "Board database is unavailable"}
  end

  defp existing(filer_id, key) do
    Request
    |> Ash.Query.filter(filer_id == ^filer_id and request_key == ^key)
    |> Ash.read_one!()
  end

  defp lock_key(filer_id, key),
    do: advisory_lock("agentboard-intake:" <> filer_id <> <<0>> <> key)

  defp lock_import(repository), do: advisory_lock("agentboard-intake-import:" <> repository)

  defp advisory_lock(name) do
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, name)
    Repo.statement!("SELECT pg_advisory_xact_lock($1)", [lock])
  end

  defp lock_items(request_id) do
    Repo.statement!(
      "SELECT id FROM intake_items WHERE request_id = $1::text::uuid ORDER BY position FOR UPDATE",
      [request_id]
    )

    items(request_id)
  end

  defp items(request_id) do
    Item
    |> Ash.Query.filter(request_id == ^request_id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
  end

  defp view(request, replayed?) do
    items = items(request.id)
    task_ids = Enum.map(items, & &1.task_id)

    tasks =
      Task
      |> Ash.Query.filter(id in ^task_ids)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1})

    %{
      "intake" => %{
        "id" => request.id,
        "request_key" => request.request_key,
        "filer_id" => request.filer_id,
        "created_at" => request.created_at,
        "import" => request.payload["import"],
        "items" =>
          Enum.map(items, fn item ->
            filed = Enum.at(request.payload["items"], item.position)
            task = tasks[item.task_id]

            %{
              "id" => item.id,
              "position" => item.position,
              "task_id" => item.task_id,
              "task_status" => task && task.status,
              "repository" => item.repository,
              "title" => filed["title"],
              "issue" => item.issue,
              "issue_state" => item.issue_state,
              "issue_url" => item.issue_url,
              "issue_number" => item.issue_number,
              "duplicate_issue_urls" => item.duplicate_issue_urls,
              "reason" => item.reason,
              "last_error" => item.last_error,
              "attempts" => item.attempts,
              "next_attempt_at" => item.next_attempt_at,
              "cancelled_at" => item.cancelled_at,
              "resolved_at" => item.resolved_at,
              "updated_at" => item.updated_at
            }
          end)
      },
      "replayed" => replayed?
    }
  end

  # Cards register under the filer's identity like `task create`. The captain
  # identity is ensured the same way the captain API path ensures it.
  defp ensure_identity(%{"agent" => "captain"} = actor) do
    case Operations.registered_agent("captain", "captain") do
      {:ok, agent} -> {:ok, agent}
      _ -> Operations.register(actor, %{"name" => "Captain"})
    end
  end

  defp ensure_identity(actor), do: Operations.registered_agent(actor["agent"], actor["harness"])

  defp card_id(title, item_id) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)
      |> String.trim("-")

    suffix = item_id |> String.replace("-", "") |> String.slice(0, 12)
    if(base == "", do: "intake", else: base) <> "-" <> suffix
  end

  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
end
