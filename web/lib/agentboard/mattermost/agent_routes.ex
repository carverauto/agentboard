defmodule Agentboard.Mattermost.AgentRoutes do
  @moduledoc """
  Private recipient routes for phase 1 (OpenSpec 5.1).

  Agents have no Mattermost users in phase 1, so a direct message cannot be a
  Mattermost DM. Instead the ONE shared bot owns one private channel per
  recipient agent in the configured team and posts that agent's private
  notices there, with the same props/header attribution as every agent post.
  Agents never hold its credentials: the recipient reads it through the
  Agentboard API (`agentboard chat read --inbox`), and the API refuses every
  other agent. Off by default; enabling it is an operator decision.
  """
  alias Agentboard.Mattermost.Transport
  alias Agentboard.Repo

  @prefix "mattermost:agent_inbox:"

  def enabled? do
    Application.get_env(:agentboard, :mattermost_private_routes_enabled, false) == true and
      is_binary(team_id()) and team_id() != ""
  end

  def team_id, do: Application.get_env(:agentboard, :mattermost_team_id)

  def destination_prefix, do: @prefix

  def recipient(@prefix <> agent_id) when agent_id != "", do: agent_id
  def recipient(_), do: nil

  # Deterministic, collision-resistant and within Mattermost's channel-name
  # rules: a lost create response is recovered by adopting this exact name.
  def channel_name(agent_id) do
    base =
      agent_id
      |> String.replace("_", "-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    hash = :crypto.hash(:sha256, agent_id) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    "abi-" <> base <> "-" <> hash
  end

  def lookup(agent_id) do
    %{rows: rows} =
      Repo.statement!("SELECT channel_id FROM mattermost_agent_routes WHERE agent_id=$1", [
        agent_id
      ])

    case rows do
      [[channel_id]] -> channel_id
      [] -> nil
    end
  end

  def owner(channel_id) do
    %{rows: rows} =
      Repo.statement!("SELECT agent_id FROM mattermost_agent_routes WHERE channel_id=$1", [
        channel_id
      ])

    case rows do
      [[agent_id]] -> agent_id
      [] -> nil
    end
  end

  # Returns the recipient's private channel, creating it on first use.
  # `{:error, :retry, reason}` may succeed later; `{:error, :definitive, reason}`
  # needs operator action (permissions, a foreign channel holding the name).
  def resolve(cfg, agent_id) do
    case lookup(agent_id) do
      channel_id when is_binary(channel_id) -> {:ok, channel_id}
      nil -> create(cfg, agent_id)
    end
  end

  # A route whose channel disappeared or refused the bot is dropped so the
  # next delivery re-resolves it instead of failing forever.
  def forget(agent_id, channel_id) do
    Repo.statement!(
      "DELETE FROM mattermost_agent_routes WHERE agent_id=$1 AND channel_id=$2",
      [agent_id, channel_id]
    )

    :ok
  end

  defp create(cfg, agent_id) do
    team = team_id()
    name = channel_name(agent_id)

    case Transport.create_private_channel(
           cfg,
           team,
           name,
           "agentboard inbox: " <> agent_id,
           "Private Agentboard notices for #{agent_id}. Posted by the shared agentboard bot."
         ) do
      {:ok, 201, %{"id" => channel_id, "type" => "P"}} ->
        store(agent_id, team, name, channel_id)

      # The name exists: an earlier create whose response was lost, or a
      # channel someone else made. Only the former is adopted.
      {:ok, 400, _} ->
        adopt(cfg, agent_id, team, name)

      {:ok, status, _} when status in [401, 403] ->
        {:error, :definitive, "route_create_forbidden"}

      {:ok, 429, _} ->
        {:error, :retry, "rate_limited"}

      {:ok, _status, _} ->
        {:error, :retry, "route_unconfirmed"}

      {:error, :forbidden_destination} ->
        {:error, :definitive, "unconfigured"}

      {:error, _} ->
        {:error, :retry, "route_unconfirmed"}
    end
  end

  # Never post private notices into a public channel or into a private
  # channel some other user created under the deterministic name.
  defp adopt(cfg, agent_id, team, name) do
    with {:ok, 200, %{"id" => bot_id}} <- Transport.me(cfg),
         {:ok, 200, %{"id" => channel_id, "type" => "P", "creator_id" => ^bot_id}} <-
           Transport.channel_by_name(cfg, team, name) do
      store(agent_id, team, name, channel_id)
    else
      {:ok, 200, _} ->
        {:error, :definitive, "route_name_collision"}

      {:ok, status, _} when status in [401, 403, 404] ->
        {:error, :definitive, "route_name_unavailable"}

      _ ->
        {:error, :retry, "route_unconfirmed"}
    end
  end

  defp store(agent_id, team, name, channel_id) do
    Repo.statement!(
      """
      INSERT INTO mattermost_agent_routes (agent_id, team_id, channel_name, channel_id, created_at, updated_at)
      VALUES ($1, $2, $3, $4, clock_timestamp(), clock_timestamp())
      ON CONFLICT DO NOTHING
      """,
      [agent_id, team, name, channel_id]
    )

    case lookup(agent_id) do
      channel_id when is_binary(channel_id) -> {:ok, channel_id}
      nil -> {:error, :definitive, "route_name_collision"}
    end
  end
end
