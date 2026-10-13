defmodule Agentboard.Intake.Issues do
  @moduledoc """
  GitHub issue outbox for intake items.

  The board transaction commits the card and a `pending` intent first. A
  worker then claims the intent in a short transaction, talks to GitHub with
  no transaction open, and commits the outcome fenced on its claim:

    * once any create may have reached GitHub (`attempts > 0`), issues
      created by the intake credential since that attempt are listed for the
      item's hidden marker before another create, and a single match is
      adopted instead of creating a duplicate;
    * transient failures (outage, rate limit, lost response) leave the
      intent `pending` with a backoff;
    * a creator lookup that cannot finish, definitive rejections, a marker
      on more than one issue, or a repository removed from the intake scope
      park it `uncertain` with a reason until the filer or captain
      reconciles or abandons it.

  A created issue is linked to the card by the `system-intake` identity,
  never over a link someone else made.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Intake
  alias Agentboard.Intake.{Github, IssueWorker, Item}
  alias Agentboard.Repo

  @actor %{"agent" => "system-intake", "model" => "system", "harness" => "ash"}
  # A `creating` claim older than this lost its worker and is claimable again;
  # its attempt count forces a marker scan first.
  @claim_lease_s 300
  @max_backoff_s 900
  @sweep_limit 25
  # Subtracted from the first create attempt so a skewed GitHub clock still
  # includes the issue that attempt stored.
  @scan_slack_s 600

  def actor, do: @actor

  # Cron sweep: enqueue every due or orphaned intent. Job uniqueness keeps
  # one job per item; the claim below is the real fence.
  def dispatch_due do
    if Intake.enabled?() do
      %{rows: rows} =
        Repo.statement!(
          """
          SELECT id::text FROM intake_items
          WHERE cancelled_at IS NULL AND next_attempt_at <= clock_timestamp()
            AND (issue_state = 'pending'
              OR (issue_state = 'creating' AND claimed_at <= clock_timestamp() - ($1::integer * interval '1 second')))
          ORDER BY next_attempt_at, id LIMIT $2
          """,
          [@claim_lease_s, @sweep_limit]
        )

      Enum.each(rows, fn [id] -> enqueue(id) end)
      {:ok, %{enqueued: length(rows)}}
    else
      {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 60)}
    end
  end

  def enqueue(id), do: %{"id" => id} |> IssueWorker.new() |> Oban.insert!()

  def process(id) when is_binary(id) do
    cond do
      not Intake.enabled?() -> {:ok, %{"skipped" => "intake_disabled"}}
      claim = claim(id) -> {:ok, run(claim)}
      true -> {:ok, %{"skipped" => "not_due"}}
    end
  end

  defp claim(id) do
    %{rows: rows} =
      Repo.statement!(
        """
        UPDATE intake_items i SET issue_state = 'creating', generation = generation + 1,
          claim_run_id = gen_random_uuid(), claimed_at = clock_timestamp(), updated_at = clock_timestamp()
        FROM intake_requests r
        WHERE i.id = $1::text::uuid AND r.id = i.request_id AND i.cancelled_at IS NULL
          AND i.next_attempt_at <= clock_timestamp()
          AND (i.issue_state = 'pending'
            OR (i.issue_state = 'creating' AND i.claimed_at <= clock_timestamp() - ($2::integer * interval '1 second')))
        RETURNING i.id::text, i.generation, i.claim_run_id::text, i.repository, i.attempts,
          i.created_at, i.first_attempt_at, r.payload -> 'items' -> i.position
        """,
        [id, @claim_lease_s]
      )

    case rows do
      [[id, generation, run_id, repository, attempts, created_at, first_attempt_at, filed]] ->
        %{
          id: id,
          generation: generation,
          claim_run_id: run_id,
          repository: repository,
          attempts: attempts,
          created_at: created_at,
          first_attempt_at: first_attempt_at,
          filed: filed
        }

      [] ->
        nil
    end
  end

  defp run(claim) do
    cond do
      claim.repository not in Intake.repositories() ->
        park(claim, "repository_out_of_scope", nil)

      # Nothing can reach GitHub, so no attempt is counted.
      not Github.configured?() ->
        defer(claim, "github_unconfigured", 300)

      claim.attempts > 0 ->
        since = DateTime.add(claim.first_attempt_at || claim.created_at, -@scan_slack_s)

        case Github.find_marker(claim.repository, Github.marker(claim.id), since) do
          {:ok, []} ->
            create(claim)

          {:ok, [issue]} ->
            adopt(claim, issue)

          {:ok, issues} ->
            park(claim, "duplicate_marker", Enum.map(issues, & &1.url))

          {:incomplete, issues} ->
            park(claim, "marker_search_incomplete", Enum.map(issues, & &1.url))

          {:retry, reason, seconds} ->
            defer(claim, reason, seconds)

          {:rejected, reason} ->
            park(claim, reason, nil)
        end

      true ->
        create(claim)
    end
  end

  defp create(claim) do
    case count_attempt(claim) do
      :ok ->
        filed = claim.filed
        body = String.trim(filed["body"] <> "\n\n" <> Github.marker(claim.id))

        case Github.create_issue(claim.repository, filed["title"], body, filed["labels"]) do
          {:ok, issue} -> adopt(claim, issue)
          {:retry, reason, seconds} -> defer(claim, reason, seconds)
          {:rejected, reason} -> park(claim, reason, nil)
        end

      :stale ->
        %{"state" => "stale_claim"}
    end
  end

  # Durably records that a create may reach GitHub before sending it, so a
  # crash between send and commit still scans for the marker next time.
  defp count_attempt(claim) do
    %{num_rows: rows} =
      Repo.statement!(
        """
        UPDATE intake_items SET attempts = attempts + 1,
          first_attempt_at = COALESCE(first_attempt_at, clock_timestamp()),
          updated_at = clock_timestamp()
        WHERE id = $1::text::uuid AND issue_state = 'creating' AND generation = $2
          AND claim_run_id = $3::text::uuid
        """,
        [claim.id, claim.generation, claim.claim_run_id]
      )

    if rows == 1, do: :ok, else: :stale
  end

  defp adopt(claim, %{number: number, url: url}) do
    if issue_url?(url, claim.repository, number) do
      settle(claim, fn item, stamp ->
        reason =
          case Operations.link_issue!(item.task_id, url, @actor) do
            {:skipped, why} -> why
            _ -> nil
          end

        %{
          issue_state: "created",
          issue_url: url,
          issue_number: number,
          duplicate_issue_urls: [],
          reason: reason,
          last_error: nil,
          next_attempt_at: nil,
          resolved_at: stamp,
          updated_at: stamp
        }
      end)
    else
      park(claim, "unexpected_issue_url", [url])
    end
  end

  defp park(claim, reason, duplicates) do
    settle(claim, fn _item, stamp ->
      %{
        issue_state: "uncertain",
        reason: reason,
        last_error: reason,
        duplicate_issue_urls: duplicates || [],
        next_attempt_at: nil,
        updated_at: stamp
      }
    end)
  end

  defp defer(claim, reason, seconds) do
    delay = max(seconds, min(@max_backoff_s, 30 * Integer.pow(2, min(claim.generation - 1, 5))))

    settle(claim, fn _item, stamp ->
      %{
        issue_state: "pending",
        last_error: reason,
        next_attempt_at: DateTime.add(stamp, delay),
        updated_at: stamp
      }
    end)
  end

  defp settle(claim, attrs_fun) do
    Operations.transaction(fn ->
      Repo.statement!("SELECT id FROM intake_items WHERE id = $1::text::uuid FOR UPDATE", [
        claim.id
      ])

      item = Operations.fetch!(Item, claim.id, "Intake item not found")

      if item.issue_state == "creating" and item.generation == claim.generation and
           item.claim_run_id == claim.claim_run_id do
        attrs = attrs_fun.(item, Operations.now())
        Operations.update(item, :settle, attrs, @actor)
        %{"state" => attrs.issue_state, "reason" => attrs[:reason] || attrs[:last_error]}
      else
        %{"state" => "stale_claim"}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, code, message} -> %{"state" => "error", "reason" => code <> ": " <> message}
    end
  end

  # The card link must name exactly the issue in the item's repository.
  defp issue_url?(url, repository, number) do
    case Regex.run(~r{\Ahttps://github\.com/([^/]+/[^/]+)/issues/([1-9][0-9]*)\z}, url) do
      [_, repo, n] -> String.downcase(repo) == repository and n == Integer.to_string(number)
      _ -> false
    end
  end
end
