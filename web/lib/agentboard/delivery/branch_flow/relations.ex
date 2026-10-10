defmodule Agentboard.Delivery.BranchFlow.Relations do
  @moduledoc "Exact-source, bounded observed PR relationships; never commit ancestry or merge paths."
  alias Agentboard.{Repo, SeatScope}
  alias Agentboard.Delivery.{PullRequest, Reads}
  require Ash.Query

  # This binding is shared by SQL selection and the pure consumer guard. Every
  # surface uses qualify/1, including overview, topology, table and inspection.
  @bindings [
    {"id", "snapshot_id", "poll"},
    {"pull_request_id", "id", "pr"},
    {"head_sha", "head_sha", "poll"},
    {"base_sha", "base_sha", "poll"},
    {"observed_at", "observed_at", "poll"},
    {"generation", "generation", "poll"}
  ]
  @matched Enum.map_join(@bindings, " AND ", fn {source, target, scope} ->
             "c." <> source <> "=" <> if(scope == "pr", do: "p.", else: "s.") <> target
           end) <> " AND c.payload->>'base_ref'=s.base_ref"
  @source_error "Exact snapshot proof missing or mismatched (PR, head, base, observation, generation or ref). Retained failure obligations are unchanged."
  @failure_fields ~w(identity provider_id kind name status conclusion started_at completed_at source_url details_url latest)a

  def matched_sql, do: @matched

  @doc "Fail closed unless all persisted snapshot bindings match this PR and poll revision."
  def source_matches?(pr, poll, snapshot) when is_map(pr) and is_map(poll) and is_map(snapshot) do
    Enum.all?(@bindings, fn {source, target, scope} ->
      left = value(snapshot, source)
      right = value(if(scope == "pr", do: pr, else: poll), target)
      not is_nil(left) and not is_nil(right) and comparable(left) == comparable(right)
    end) and
      not is_nil(value(poll, "base_ref")) and
      value(value(snapshot, "payload"), "base_ref") == value(poll, "base_ref")
  end

  def source_matches?(_, _, _), do: false

  @doc "Use existing authoritative CI/base qualification, then apply exact-source proof uniformly."
  def qualify(row) do
    snapshot = Map.get(row, :snapshot_source)
    matched = source_matches?(row.pr, row.poll, snapshot)
    retained_failure = value(row.poll, "ci_state") == "failing"

    row =
      cond do
        not matched ->
          Map.merge(row, %{
            fresh: false,
            ci_state: if(retained_failure, do: "failing", else: "unknown"),
            merge_state: if(row.merge_state == "conflicting", do: "stale", else: "unknown"),
            mergeable: nil,
            mergeable_state: nil,
            base_ref: nil,
            draft: nil,
            source_currentness_error: @source_error
          })

        retained_failure ->
          Map.merge(row, %{ci_state: "failing", source_currentness_error: nil})

        true ->
          Map.put(row, :source_currentness_error, nil)
      end

    row
    |> Map.put(:relation, relation(row, snapshot, matched))
    |> Map.delete(:snapshot_source)
  end

  defp relation(row, snapshot, matched) do
    payload = if matched, do: value(snapshot, "payload"), else: %{}
    repository = row.pr["owner"] <> "/" <> row.pr["repo"]

    %{
      id: row.pr["id"],
      number: row.pr["number"],
      url: row.pr["url"],
      repository: repository,
      base_repo: repository,
      base_ref: value(payload, "base_ref"),
      base_sha: if(matched, do: value(snapshot, "base_sha")),
      head_repo: value(payload, "head_repo"),
      head_ref: value(payload, "head_ref"),
      head_sha: if(matched, do: value(snapshot, "head_sha")),
      expected_base_sha: row.expected_base_sha,
      observed_at: row.observed_at,
      snapshot_id: value(snapshot, "id"),
      snapshot_generation: value(snapshot, "generation"),
      poll_generation: value(row.poll, "generation"),
      metadata_available: matched,
      fresh: row.fresh,
      ci_state: row.ci_state,
      merge_state: row.merge_state,
      mergeable: row.mergeable,
      mergeable_state: row.mergeable_state,
      draft: row.draft,
      lifecycle: value(row.poll, "lifecycle"),
      last_error: value(row.poll, "last_error"),
      source_currentness_error: row.source_currentness_error,
      title: nil,
      numeric_divergence: nil,
      off_page_parent: nil,
      off_page_parent_ambiguous: false
    }
  end

  @doc "Load only compact evidence for an already bounded canonical-id selection."
  def load(ids, stamp)
  def load([], _stamp), do: []

  def load(ids, stamp) when is_list(ids) and length(ids) <= 20 do
    PullRequest
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(20)
    |> Ash.read!()
    |> Reads.observations(as_of: stamp)
    |> Enum.map(&qualify(&1).relation)
  end

  @doc "One nonrecursive exact endpoint lookup per page; ambiguity counts on- and off-page matches."
  def with_continuations(relations) when is_list(relations) and length(relations) <= 20 do
    complete = Enum.filter(relations, &complete_base?/1)

    if complete == [] do
      relations
    else
      %{rows: rows} =
        Repo.statement!(
          """
          SELECT wanted.id,parent.id,parent.url,parent.number,parent.repository,
            parent.head_repo,parent.head_ref,parent.head_sha
          FROM unnest($1::text[],$2::text[],$3::text[],$4::text[])
            wanted(id,repository,base_ref,base_sha)
          CROSS JOIN LATERAL (
            SELECT p.id,p.url,p.number,p.owner || '/' || p.repo AS repository,
              c.payload->>'head_repo' AS head_repo,c.payload->>'head_ref' AS head_ref,c.head_sha
            FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
            JOIN delivery_ci_snapshots c ON #{@matched}
            WHERE s.enabled AND s.lifecycle='open'
              AND p.owner || '/' || p.repo=wanted.repository
              AND c.payload->>'head_repo'=wanted.repository
              AND c.payload->>'head_ref'=wanted.base_ref AND c.head_sha=wanted.base_sha
            ORDER BY p.id LIMIT 2
          ) parent ORDER BY wanted.id,parent.id
          """,
          [
            Enum.map(complete, & &1.id),
            Enum.map(complete, & &1.base_repo),
            Enum.map(complete, & &1.base_ref),
            Enum.map(complete, & &1.base_sha)
          ]
        )

      by_id = Enum.group_by(rows, &hd/1)
      page_ids = MapSet.new(relations, & &1.id)

      Enum.map(relations, fn relation ->
        case Map.get(by_id, relation.id, []) do
          [[_, id, url, number, repository, head_repo, head_ref, head_sha]] ->
            if MapSet.member?(page_ids, id) do
              relation
            else
              Map.put(relation, :off_page_parent, %{
                id: id,
                url: url,
                number: number,
                repository: repository,
                head_repo: head_repo,
                head_ref: head_ref,
                head_sha: head_sha
              })
            end

          [_, _] ->
            Map.put(relation, :off_page_parent_ambiguous, true)

          _ ->
            relation
        end
      end)
    end
  end

  defp complete_base?(relation) do
    relation.metadata_available and
      SeatScope.canonical_repo(relation.base_repo) == relation.base_repo and
      is_binary(relation.base_ref) and is_binary(relation.base_sha)
  end

  @doc "At most ten retained failed attempt summaries plus a truncation sentinel, never full payload."
  def failures(id) do
    %{rows: rows} =
      Repo.statement!(
        """
        SELECT attempt.item
        FROM delivery_pull_requests p JOIN delivery_poll_states s ON s.id=p.id
        JOIN delivery_ci_snapshots c ON #{@matched}
        CROSS JOIN LATERAL jsonb_array_elements(
          CASE WHEN jsonb_typeof(c.payload->'attempts')='array' THEN c.payload->'attempts' ELSE '[]'::jsonb END
        ) WITH ORDINALITY attempt(item,ordinality)
        WHERE p.id=$1 AND attempt.item->>'conclusion'
          IN ('failure','error','timed_out','cancelled','action_required','startup_failure')
        ORDER BY attempt.ordinality LIMIT 11
        """,
        [id]
      )

    failures =
      rows
      |> Enum.take(10)
      |> Enum.map(fn [attempt] ->
        Map.new(@failure_fields, &{&1, attempt[Atom.to_string(&1)]})
      end)

    {failures, length(rows) > 10}
  end

  defp value(nil, _), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))

  defp value(_, _), do: nil

  defp comparable(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp comparable(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_unix(time, :microsecond)
      _ -> value
    end
  end

  defp comparable(value), do: value
end
