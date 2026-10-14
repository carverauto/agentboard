defmodule Agentboard.Intake.Slash do
  @moduledoc """
  The Mattermost `/board` command over the intake contract.

  A captain-configured allowlist maps each Mattermost user ID to a registered
  board identity, the filer. `/board file` calls `Intake.file/2` as that filer
  and `/board status` calls `Intake.show/2`, so the command has exactly the
  intake rules: scope, normalization, replay and rate limit. An unmapped user,
  a retired or reserved filer, or a malformed command creates nothing.

  The request key is derived from Mattermost's per-invocation `trigger_id`, so
  a redelivered invocation replays the original request instead of filing
  twice. Running the command again is a new invocation and a new request.
  """
  alias Agentboard.{Intake, RateLimits}
  alias Agentboard.Auth.APIAuthPolicy
  alias Agentboard.Board.Resources.Agent

  @usage """
  Usage:
  `/board file owner/repo "Title" [--body "Text"] [--priority N] [--label L]... [--issue|--no-issue]`
  `/board status REQUEST_ID`
  `/board help`
  A filing creates a board card and, unless `--no-issue`, a GitHub issue.\
  """

  # Mattermost user ID → filer agent ID, from AGENTBOARD_MATTERMOST_SLASH_FILERS.
  def filers, do: Application.get_env(:agentboard, :mattermost_slash_filers, %{})

  # Runs one invocation. Always returns a Mattermost command response map;
  # refusals are ephemeral so only the invoking user sees them.
  def run(%{"user_id" => user_id, "text" => text} = params)
      when is_binary(user_id) and is_binary(text) do
    with {:ok, command} <- parse(text),
         {:ok, actor} <- filer(user_id) do
      execute(command, actor, params)
    else
      {:help, message} -> ephemeral(message)
      {:refused, message} -> ephemeral(message)
    end
  end

  def run(_), do: ephemeral("Mattermost did not send a user and command text.")

  defp execute({:file, item}, actor, %{"trigger_id" => trigger})
       when is_binary(trigger) and trigger != "" do
    key = "mattermost-" <> Base.encode16(:crypto.hash(:sha256, trigger), case: :lower)

    with :ok <- rate_limit(actor),
         {:ok, %{"intake" => intake} = view} <-
           Intake.file(actor, %{"request_key" => key, "items" => [item]}) do
      in_channel(filed_text(intake, view["replayed"]))
    else
      {:error, code, message} -> ephemeral("Intake refused (#{code}): #{message}")
    end
  end

  defp execute({:file, _}, _actor, _params),
    do:
      ephemeral("Mattermost did not send a trigger ID, so the filing cannot be made retry-safe.")

  defp execute({:status, id}, actor, _params) do
    case Intake.show(id, actor) do
      {:ok, %{"intake" => intake}} -> ephemeral(status_text(intake))
      {:error, code, message} -> ephemeral("Status refused (#{code}): #{message}")
    end
  end

  defp rate_limit(actor) do
    case RateLimits.check_intake(actor["agent"]) do
      :ok -> :ok
      {:error, :rate_limited, seconds} -> {:error, "rate_limited", "try again in #{seconds}s"}
      {:error, :unavailable} -> {:error, "unavailable", "API limiter unavailable"}
    end
  end

  # The filer must be an ordinary, live registered identity; reserved system
  # and captain identities never file through chat.
  defp filer(user_id) do
    case Map.get(filers(), user_id) do
      nil -> {:refused, "Your Mattermost account is not on the board's filer list."}
      id -> live_filer(Ash.get!(Agent, id, not_found_error?: false))
    end
  rescue
    DBConnection.ConnectionError -> {:refused, "The board database is unavailable."}
  end

  defp live_filer(%Agent{retired_at: nil} = agent) do
    if APIAuthPolicy.reserved?(agent.id, agent.harness, agent.kind),
      do: live_filer(nil),
      else:
        {:ok,
         %{"agent" => agent.id, "model" => agent.model || "human", "harness" => agent.harness}}
  end

  defp live_filer(_),
    do: {:refused, "Your mapped board identity is not a live, ordinary agent."}

  defp parse(text) do
    case tokens(String.trim(text)) do
      {:ok, ["file", repository, title | flags]} -> file(repository, title, flags)
      {:ok, ["status", id]} -> {:ok, {:status, id}}
      {:ok, words} when words in [[], ["help"]] -> {:help, @usage}
      {:ok, _} -> {:help, "Unrecognized command.\n" <> @usage}
      :error -> {:help, "Unbalanced quotes.\n" <> @usage}
    end
  end

  defp file(repository, title, flags) do
    item = %{"repository" => repository, "title" => title, "labels" => []}

    case flags(flags, item) do
      {:ok, item} -> {:ok, {:file, Map.update!(item, "labels", &Enum.reverse/1)}}
      :error -> {:help, "Unrecognized file options.\n" <> @usage}
    end
  end

  defp flags([], item), do: {:ok, item}
  defp flags(["--issue" | rest], item), do: flags(rest, Map.put(item, "issue", true))
  defp flags(["--no-issue" | rest], item), do: flags(rest, Map.put(item, "issue", false))
  defp flags(["--body", body | rest], item), do: flags(rest, Map.put(item, "body", body))

  defp flags(["--label", label | rest], item),
    do: flags(rest, Map.update!(item, "labels", &[label | &1]))

  defp flags(["--priority", value | rest], item) do
    case Integer.parse(value) do
      {priority, ""} -> flags(rest, Map.put(item, "priority", priority))
      _ -> :error
    end
  end

  defp flags(_, _), do: :error

  # Whitespace-separated words; "double" or “curly” quotes group a word, and a
  # backslash escapes the next character inside quotes.
  defp tokens(text), do: tokens(String.graphemes(text), [], nil)

  defp tokens([], words, nil), do: {:ok, Enum.reverse(words)}
  defp tokens([], _words, _open), do: :error

  defp tokens([space | rest], words, nil) when space in [" ", "\t", "\n", "\r"],
    do: tokens(rest, words, nil)

  defp tokens([quote | rest], words, nil) when quote in ["\"", "“"],
    do: quoted(rest, words, "")

  defp tokens(chars, words, nil) do
    {word, rest} = Enum.split_while(chars, &(&1 not in [" ", "\t", "\n", "\r"]))
    tokens(rest, [Enum.join(word) | words], nil)
  end

  defp quoted([], _words, _acc), do: :error
  defp quoted(["\\", char | rest], words, acc), do: quoted(rest, words, acc <> char)

  defp quoted([close | rest], words, acc) when close in ["\"", "”"],
    do: tokens(rest, [acc | words], nil)

  defp quoted([char | rest], words, acc), do: quoted(rest, words, acc <> char)

  defp filed_text(intake, replayed?) do
    [item | _] = intake["items"]

    issue =
      if item["issue"],
        do:
          "GitHub issue: #{item["issue_state"]}#{issue_link(item)}; `/board status #{intake["id"]}` shows the link once it exists.",
        else: "GitHub issue: not requested."

    Enum.join(
      [
        "#{if replayed?, do: "Already filed", else: "Filed"} by `#{intake["filer_id"]}` in `#{item["repository"]}`: " <>
          "**#{item["title"]}** → #{card(item["task_id"])}",
        issue,
        "Intake request `#{intake["id"]}`."
      ],
      "\n"
    )
  end

  defp status_text(intake) do
    lines =
      Enum.map(intake["items"], fn item ->
        issue =
          if item["issue"],
            do: "issue #{item["issue_state"]}#{issue_link(item)}",
            else: "no issue"

        "- #{card(item["task_id"])} (#{item["task_status"] || "unknown"}): #{issue}"
      end)

    Enum.join(["Intake request `#{intake["id"]}` by `#{intake["filer_id"]}`:" | lines], "\n")
  end

  defp issue_link(%{"issue_url" => url}) when is_binary(url), do: " #{url}"
  defp issue_link(_), do: ""

  defp card(task_id) do
    case Application.get_env(:agentboard, :public_board_url) do
      base when is_binary(base) and base != "" ->
        "[`#{task_id}`](#{String.trim_trailing(base, "/")}/tasks/#{task_id})"

      _ ->
        "`#{task_id}`"
    end
  end

  defp in_channel(text), do: %{"response_type" => "in_channel", "text" => text}
  defp ephemeral(text), do: %{"response_type" => "ephemeral", "text" => text}
end
