defmodule Agentboard.Evidence.Operations do
  @moduledoc "Immutable evidence publication through Ash in the board ownership transaction."
  alias Agentboard.Board.Operations
  alias Agentboard.Board.Resources.Task

  alias Agentboard.Evidence.Resources.{
    Document,
    QuotaReport,
    QuotaObservation,
    QuotaWindow,
    QuotaScope
  }

  require Ash.Query

  def document(id, actor, data, digest) do
    Operations.transaction(fn ->
      Operations.identity!(actor)
      Operations.lock_task(id)
      task = Operations.fetch!(Task, id, "Task not found")

      existing =
        Document
        |> Ash.Query.filter(
          task_id == ^id and source_agent_id == ^actor["agent"] and digest == ^digest
        )
        |> Ash.read_one!()

      if existing do
        %{"document" => metadata(existing), "idempotent" => true}
      else
        stamp = Operations.now()

        unless task.status in ~w(in_progress blocked review) and
                 task.assignee_id == actor["agent"] and
                 DateTime.compare(task.claim_expires_at, stamp) == :gt,
               do:
                 Operations.reject("conflict", "Documentation upload requires a live task owner")

        count = Document |> Ash.Query.filter(task_id == ^id) |> Ash.count!()

        if count >= 100,
          do: Operations.reject("invalid_input", "Task already has 100 documentation versions")

        attrs =
          Map.merge(data, %{
            "task_id" => id,
            "source_agent_id" => actor["agent"],
            "model" => actor["model"],
            "harness" => actor["harness"],
            "digest" => digest,
            "created_at" => stamp
          })

        document = Operations.create(Document, :create, attrs, actor)

        Operations.update(
          task,
          :documentation,
          %{revision: task.revision + 1, updated_at: stamp},
          actor,
          task.revision
        )

        Operations.project_event(
          id,
          actor,
          "note",
          "Documentation: " <> document.title,
          task.revision,
          task.revision + 1,
          %{
            document_id: document.id,
            document_kind: document.kind,
            digest: document.digest,
            pr_url: document.pr_url
          },
          stamp
        )

        %{"document" => metadata(document), "idempotent" => false}
      end
    end)
  end

  def documents(id) do
    case Ash.get(Task, id, not_found_error?: false) do
      {:ok, nil} ->
        {:error, "not_found", "Record not found"}

      {:ok, _} ->
        with {:ok, records} <-
               Document
               |> Ash.Query.filter(task_id == ^id)
               |> Ash.Query.sort(id: :desc)
               |> Ash.read() do
          {:ok, %{"documents" => Enum.map(records, &metadata/1)}}
        else
          _ -> {:error, "unavailable", "Board database is unavailable"}
        end

      _ ->
        {:error, "unavailable", "Board database is unavailable"}
    end
  end

  def fetch_document(id) do
    fields = Ash.Resource.Info.attributes(Document) |> Enum.map(& &1.name)

    case Document |> Ash.Query.filter(id == ^id) |> Ash.Query.select(fields) |> Ash.read_one() do
      {:ok, nil} -> {:error, "not_found", "Record not found"}
      {:ok, record} -> {:ok, Map.put(metadata(record), "html", record.html)}
      _ -> {:error, "unavailable", "Board database is unavailable"}
    end
  end

  def quota(actor, report, providers, digest) do
    Operations.transaction(fn ->
      Operations.identity!(actor)

      <<key::signed-64, _::binary>> =
        :crypto.hash(:sha256, "quota:" <> actor["agent"] <> ":" <> digest)

      Ecto.Adapters.SQL.query!(Agentboard.Repo, "SELECT pg_advisory_xact_lock($1)", [key])

      existing =
        QuotaReport
        |> Ash.Query.filter(source_agent_id == ^actor["agent"] and digest == ^digest)
        |> Ash.read_one!()

      if existing do
        %{"report" => metadata(existing), "idempotent" => true}
      else
        {:ok, generated, _} = DateTime.from_iso8601(report["generatedAt"])

        result =
          Operations.create(
            QuotaReport,
            :create,
            %{
              source_agent_id: actor["agent"],
              model: actor["model"],
              harness: actor["harness"],
              digest: digest,
              schema_version: report["schemaVersion"],
              generated_at: generated,
              ingested_at: Operations.now(),
              raw: report
            },
            actor
          )

        for provider <- providers do
          observation =
            Operations.create(
              QuotaObservation,
              :create,
              %{
                report_id: result.id,
                provider: provider["provider"],
                account_key: provider["account_key"],
                provider_data: provider
              },
              actor
            )

          for window <- provider["windows"] do
            Operations.create(
              QuotaWindow,
              :create,
              %{observation_id: observation.id, window_id: window["id"], data: window},
              actor
            )
          end

          for scope <- get_in(provider, ["quota_semantics", "effective_availability"]) || [] do
            Operations.create(
              QuotaScope,
              :create,
              %{observation_id: observation.id, scope: scope["scope"], data: scope},
              actor
            )
          end
        end

        Ecto.Adapters.SQL.query!(Agentboard.Repo, "SELECT pg_notify('ab_quota',$1)", [
          Jason.encode!(%{id: result.id})
        ])

        %{"report" => metadata(result), "idempotent" => false}
      end
    end)
  end

  defp metadata(record) do
    fields =
      Ash.Resource.Info.attributes(record.__struct__)
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in [:html, :raw]))

    record |> Map.take(fields) |> Jason.encode!() |> Jason.decode!()
  end
end

