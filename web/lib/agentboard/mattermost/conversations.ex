defmodule Agentboard.Mattermost.Conversations do
  @moduledoc """
  Worker identity registry and coverage receipts. The server maps stable
  agent IDs to Mattermost user IDs and verifies membership; message bodies
  stay authoritative in Mattermost and workers send with their own tokens.
  Sender attribution always derives from this mapping, never from text.
  """
  alias Agentboard.Board.Operations
  alias Agentboard.Mattermost.{ConversationCoverage, ConversationIdentity, Delivery, Transport, VerifyWorker}
  require Ash.Query

  @actor %{"agent" => "mattermost-conversations", "model" => "system", "harness" => "ash"}

  def team_id, do: Application.get_env(:agentboard, :mattermost_team_id)

  # Enrollment is provisioning, not self-signup: the controller gates it on
  # the captain token. Verification runs asynchronously via a verify job.
  def enroll(agent_id, mm_user_id, mm_username, credential_ref) do
    Operations.transaction(fn ->
      stamp = Operations.now()

      identity =
        Operations.create(
          ConversationIdentity,
          :enroll,
          %{
            agent_id: agent_id,
            mm_user_id: mm_user_id,
            mm_username: mm_username,
            credential_ref: credential_ref,
            created_at: stamp,
            updated_at: stamp
          },
          @actor
        )

      %{"agent_id" => agent_id} |> VerifyWorker.new() |> Oban.insert!()
      Operations.public(identity)
    end)
  end

  def revoke(agent_id, reason) do
    Operations.transaction(fn ->
      identity = Operations.fetch!(ConversationIdentity, agent_id, "Conversation identity not found")
      stamp = Operations.now()

      Operations.update(
        identity,
        :revoke,
        %{last_error: reason, updated_at: stamp},
        @actor
      )
      |> Operations.public()
    end)
  end

  # Server-side attribution: resolve the authenticated worker to its
  # Mattermost user. Unknown, suspended or revoked mappings never authorize
  # a send, and a handle rename never changes the stable user ID.
  def sender_for(agent_id) do
    case Ash.get!(ConversationIdentity, agent_id, not_found_error?: false) do
      %ConversationIdentity{status: "enrolled", mm_user_id: user_id} -> {:ok, user_id}
      %ConversationIdentity{status: status} -> {:error, status}
      nil -> {:error, "unknown"}
    end
  end

  def verify(agent_id) do
    with {:ok, cfg} <- Delivery.config(),
         %ConversationIdentity{} = identity <- fetch_enrolled(agent_id) do
      case Transport.fetch_user(cfg, identity.mm_user_id) do
        {:ok, %{username: username}} ->
          check_membership(cfg, identity, username)

        {:error, :not_found} ->
          suspend(identity, "user_not_found")

        {:error, :unauthorized} ->
          {:error, "bridge unauthorized; rotate the bridge token"}

        {:error, _} ->
          {:error, "verification unavailable"}
      end
    end
  end

  defp fetch_enrolled(agent_id) do
    case Ash.get!(ConversationIdentity, agent_id, not_found_error?: false) do
      nil -> Operations.reject("not_found", "Conversation identity not found")
      %ConversationIdentity{status: "revoked"} -> Operations.reject("invalid_context", "Conversation identity revoked")
      identity -> identity
    end
  end

  defp check_membership(cfg, identity, username) do
    case team_id() do
      nil ->
        note_verified(identity, username)

      team ->
        case Transport.team_member?(cfg, team, identity.mm_user_id) do
          {:ok, true} -> note_verified(identity, username)
          {:ok, false} -> suspend(identity, "team_membership_lost")
          {:error, :unauthorized} -> {:error, "bridge unauthorized; rotate the bridge token"}
          {:error, _} -> {:error, "verification unavailable"}
        end
    end
  end

  defp note_verified(identity, username) do
    Operations.transaction(fn ->
      stamp = Operations.now()

      attrs = %{membership_verified_at: stamp, last_error: nil, updated_at: stamp}
      attrs = if username != identity.mm_username, do: Map.put(attrs, :mm_username, username), else: attrs

      current = Operations.fetch!(ConversationIdentity, identity.agent_id, "Conversation identity not found")

      if current.status == "revoked", do: Operations.reject("invalid_context", "Conversation identity revoked")

      Operations.update(current, :note_verified, attrs, @actor)
      |> Operations.public()
      |> Map.put("renamed", username != identity.mm_username)
    end)
    |> unwrap()
  end

  defp suspend(identity, reason) do
    Operations.transaction(fn ->
      current = Operations.fetch!(ConversationIdentity, identity.agent_id, "Conversation identity not found")

      if current.status == "revoked", do: Operations.reject("invalid_context", "Conversation identity revoked")

      Operations.update(
        current,
        :suspend,
        %{last_error: reason, updated_at: Operations.now()},
        @actor
      )
      |> Operations.public()
    end)
    |> unwrap()
  end

  # Coverage receipts: exact post/version progress per worker per channel.
  # Reads never acknowledge; incomplete catch-up stays explicit with a reason.
  def report_coverage(agent_id, channel_id, last_post_id, last_version, opts \\ []) do
    with :ok <- validate_coverage_input(last_post_id, last_version),
         {:ok, version} <- normalize_coverage_version(last_version),
         {:ok, _} <- sender_for(agent_id) do
      case store_coverage(agent_id, channel_id, last_post_id, version, opts) do
        {:error, "conflict", _} -> store_coverage(agent_id, channel_id, last_post_id, version, opts)
        other -> other
      end
      |> unwrap()
    end
  end

  defp store_coverage(agent_id, channel_id, last_post_id, last_version, opts) do
    Operations.transaction(fn ->
      case Ash.get!(ConversationIdentity, agent_id, not_found_error?: false) do
        %ConversationIdentity{status: "enrolled"} -> :ok
        _ -> Operations.reject("invalid_context", "Conversation identity not enrolled")
      end

      stamp = Operations.now()
      caught_up = Keyword.get(opts, :caught_up, false)
      reason = Keyword.get(opts, :incomplete_reason)

      coverage =
        case fetch_coverage(agent_id, channel_id) do
          nil ->
            Operations.create(
              ConversationCoverage,
              :open,
              %{
                id: Ash.UUID.generate(),
                agent_id: agent_id,
                channel_id: channel_id,
                created_at: stamp,
                updated_at: stamp
              },
              @actor
            )

          row ->
            row
        end

        Operations.update(
          coverage,
          :report,
          %{
            last_post_id: last_post_id,
            last_version: last_version,
            caught_up: caught_up,
            incomplete_reason: if(caught_up, do: nil, else: reason || "catch_up_incomplete"),
            checked_at: stamp,
            updated_at: stamp
          },
          @actor
        )
        |> Operations.public()
      end)
    end
  end

  defp validate_coverage_input(last_post_id, last_version) do
    cond do
      not is_binary(last_post_id) or String.trim(last_post_id) == "" ->
        {:error, "invalid_input", "last_post_id is required"}
      not valid_coverage_version?(last_version) ->
        {:error, "invalid_input", "last_version must be a non-negative integer"}
      true ->
        :ok
    end
  end

  defp valid_coverage_version?(nil), do: true
  defp valid_coverage_version?(v) when is_integer(v) and v >= 0, do: true
  defp valid_coverage_version?(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> true
      _ -> false
    end
  end
  defp valid_coverage_version?(_), do: false

  defp normalize_coverage_version(nil), do: {:ok, 0}
  defp normalize_coverage_version(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp normalize_coverage_version(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "invalid_input", "last_version must be a non-negative integer"}
    end
  end

  def coverage(agent_id, channel_id) do
    case fetch_coverage(agent_id, channel_id) do
      nil -> {:error, "not_found"}
      row -> {:ok, Operations.public(row)}
    end
  end

  defp fetch_coverage(agent_id, channel_id) do
    ConversationCoverage
    |> Ash.Query.filter(agent_id == ^agent_id and channel_id == ^channel_id)
    |> Ash.read_one!()
  end

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, _code, message}), do: {:error, message}

  def actor, do: @actor
end
