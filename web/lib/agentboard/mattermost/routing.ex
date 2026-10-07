defmodule Agentboard.Mattermost.Routing do
  @moduledoc """
  State-based fan-out. Pending intents are selected by state and eligibility,
  never by a numeric cursor, so lower-ID late commits and interrupted pages
  stay discoverable. A page is claimed atomically under one run ID; concurrent
  routers and restarts converge on the same pending set.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{Bridge, Outbox, SendWorker}
  alias Agentboard.Repo

  @page_size 25

  @actor %{"agent" => "mattermost-bridge", "model" => "system", "harness" => "ash"}

  # Raw SQL carries UUIDs as native binaries; Ecto casting only applies
  # through changesets.
  def uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, raw} -> raw
      :error -> id
    end
  end

  def route do
    if Bridge.enabled?() do
      Operations.transaction(fn ->
        %{rows: rows} =
          Repo.statement!(
            """
            UPDATE mattermost_outbox SET state='claimed', generation=generation+1,
              claim_run_id=gen_random_uuid(), attempts=attempts+1, updated_at=clock_timestamp()
            WHERE id IN (
              SELECT o.id FROM mattermost_outbox o
              WHERE o.next_eligible_at<=clock_timestamp()
                AND o.routing_revision=$1
                AND (
                  o.state='pending'
                  OR (o.state='claimed' AND o.updated_at<=clock_timestamp()-interval '5 minutes')
                )
                AND NOT EXISTS (
                  SELECT 1 FROM oban_jobs j
                  WHERE j.worker='Agentboard.Mattermost.SendWorker'
                    AND j.args->>'id'=o.id::text
                    AND j.state IN ('available','scheduled','executing','retryable')
                )
              ORDER BY o.next_eligible_at, o.id LIMIT $2
              FOR UPDATE SKIP LOCKED
            ) RETURNING id::text
            """,
            [Bridge.routing_revision(), @page_size]
          )

        Enum.each(rows, fn [id] ->
          %{"id" => id} |> SendWorker.new() |> Oban.insert!()
        end)

        %{claimed: length(rows)}
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, _code, message} -> {:error, message}
      end
    else
      snooze()
    end
  end

  def enqueue(id) when is_binary(id) do
    %{"id" => id} |> SendWorker.new() |> Oban.insert!()
  end

  defp snooze, do: {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}

  def actor, do: @actor
end
