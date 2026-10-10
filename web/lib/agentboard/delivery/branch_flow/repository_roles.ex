defmodule Agentboard.Delivery.BranchFlow.RepositoryRoles do
  @moduledoc "Bounded retained default-role metadata. No provider I/O or inference of branch health/tips."
  alias Agentboard.{Repo, SeatScope}
  alias Agentboard.Delivery.{ConflictPolicy, RepositoryMetadata, Scheduling}
  require Ecto.Query

  def load(repositories, stamp)
  def load([], _stamp), do: %{}

  def load(repositories, stamp) when is_list(repositories) and length(repositories) <= 7 do
    repositories = Enum.uniq(repositories)

    rows =
      Repo.all(
        Ecto.Query.from(row in RepositoryMetadata,
          where: row.id in ^repositories,
          limit: 7,
          select:
            {row,
             fragment(
               """
               EXISTS(SELECT 1 FROM delivery_pull_requests p
                 JOIN delivery_poll_states s ON s.id=p.id
                 WHERE p.owner=split_part(?,'/',1) AND p.repo=split_part(?,'/',2)
                   AND s.default_ref IS NOT NULL)
               """,
               row.id,
               row.id
             )}
        )
      )
      |> Map.new(fn {row, other_source} -> {row.id, {row, other_source}} end)

    enabled = Scheduling.enabled?()
    other_producer = ConflictPolicy.observe_defaults?()

    Map.new(repositories, fn repository ->
      {row, retained_source} = Map.get(rows, repository, {nil, false})
      {repository, qualify(repository, row, stamp, enabled, other_producer or retained_source)}
    end)
  end

  # The PR/default-watch producer introduced by #169 has not yet joined this
  # workflow generation. Never claim a unified current default while it is active
  # or after it has retained another source, even if its mode is later disabled.
  # This is a local qualification guard, not producer takeover or extra I/O.
  def qualify(repository, row, stamp, enabled, other_source \\ false) do
    matched = source_matches?(repository, row)
    observed = if matched, do: row.observed_at
    age = if observed, do: DateTime.diff(stamp, observed, :second)

    reason =
      cond do
        is_nil(row) -> "not_retained"
        not matched -> "source_mismatch"
        not enabled -> "observation_disabled"
        other_source -> "default_source_contract_pending"
        row.generation != row.source_generation -> "collection_pending_or_superseded"
        DateTime.compare(observed, stamp) == :gt -> "future_observation"
        age > 180 -> "stale"
        true -> nil
      end

    %{
      repository: repository,
      default_ref: if(is_nil(reason), do: row.default_ref),
      retained_default_ref: if(matched, do: row.default_ref),
      available: is_nil(reason),
      fresh: is_nil(reason),
      reason: reason,
      health: "unknown",
      generation: if(row, do: row.generation),
      source_generation: if(matched, do: row.source_generation),
      source_run_id: if(matched, do: row.source_run_id),
      source_run_generation: if(matched, do: row.source_run_generation),
      observed_at: observed,
      age: age,
      last_error: if(row, do: row.last_error),
      source_url:
        if(matched,
          do:
            "https://github.com/#{repository}/actions/runs/#{List.last(String.split(row.source_run_id, "/"))}"
        )
    }
  end

  def degrade(nil), do: nil

  def degrade(role),
    do:
      Map.merge(role, %{
        default_ref: nil,
        available: false,
        fresh: false,
        reason: "read_unavailable",
        health: "unknown"
      })

  defp source_matches?(repository, row) when is_map(row) do
    SeatScope.canonical_repo(repository) == repository and row.id == repository and
      RepositoryMetadata.valid_ref?(row.default_ref) and
      is_integer(row.generation) and row.generation > 0 and
      is_integer(row.source_generation) and row.source_generation > 0 and
      row.source_generation <= row.generation and
      is_integer(row.source_run_generation) and row.source_run_generation > 0 and
      is_binary(row.source_run_id) and
      Regex.match?(
        ~r/\A[1-9][0-9]*\z/,
        String.replace_prefix(String.downcase(row.source_run_id), repository <> "/", "")
      ) and
      String.starts_with?(String.downcase(row.source_run_id), repository <> "/") and
      match?(%DateTime{}, row.observed_at)
  end

  defp source_matches?(_, _), do: false
end
