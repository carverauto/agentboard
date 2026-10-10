defmodule Agentboard.Delivery.PublicationRecoveryFinding do
  @moduledoc "Audit-only branch recovery disposition; neither a PR author nor a publication grant."
  use Ash.Resource,
    domain: Agentboard.Delivery,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshEvents.Events]

  alias Agentboard.Board.Operations, as: Ops
  alias Agentboard.Decisions.Request
  require Ash.Query
  @actor %{"agent" => "ci-accountability", "model" => "system", "harness" => "ash"}

  events do
    event_log(Agentboard.Board.AuditEvent)
    create_timestamp(:observed_at)
  end

  actions do
    create :record do
      accept([:id, :binding_id, :facts, :observed_at])
    end
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false)
    attribute(:binding_id, :uuid)
    attribute(:facts, :map, allow_nil?: false)
    attribute(:observed_at, :utc_datetime_usec, allow_nil?: false)
  end

  def retain(task, mapping, reason, candidates, stamp) do
    urls = candidates |> Enum.map(& &1.url) |> Enum.sort()

    digest =
      :crypto.hash(:sha256, Jason.encode!([mapping.binding_id, reason, urls, task.pr_url]))
      |> Base.encode16(case: :lower)

    gate = "publication-recovery:" <> digest

    prior =
      Request |> Ash.Query.filter(task_id == ^task.id and gate_ref == ^gate) |> Ash.read_one!()

    unless prior do
      request =
        Ops.create(
          Request,
          :create,
          %{
            id: Ash.UUID.generate(),
            task_id: task.id,
            requester_id: @actor["agent"],
            kind: "blocked_decision",
            gate_ref: gate,
            question: "Unlinked publication: #{reason}. Captain attribution required.",
            findings:
              Jason.encode!(%{
                binding_id: mapping.binding_id,
                repository: mapping.repository,
                branch: mapping.branch,
                urls: urls,
                existing_url: task.pr_url,
                declared_bound_by_id: mapping.declared_bound_by_id,
                pr_author: "unknown"
              }),
            options: [],
            status: "open",
            created_at: stamp,
            updated_at: stamp
          },
          @actor
        )

      record(
        mapping.binding_id,
        %{
          "disposition" => reason,
          "urls" => urls,
          "task_id" => task.id,
          "decision_id" => request.id,
          "pr_author" => "unknown"
        },
        stamp
      )
    end

    :finding
  end

  def record(binding_id, facts, stamp),
    do:
      Ops.create(
        __MODULE__,
        :record,
        %{id: Ash.UUID.generate(), binding_id: binding_id, facts: facts, observed_at: stamp},
        @actor
      )
end
