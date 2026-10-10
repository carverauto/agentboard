defmodule Agentboard.Mattermost.Participation do
  @moduledoc "Current shared-bot channel authorization for authenticated participation."
  alias Agentboard.Auth.APIAuthPolicy
  alias Agentboard.Mattermost.{Delivery, Inbound, InboundHTTP}

  # Authorization is checked before any channel history/read/write. A participant
  # grant never uses generic chat's unrestricted-empty-allowlist semantics. The
  # returned configuration is server-only and must never enter a response/log.
  def authorize(principal, channel_id) do
    with :ok <- authorize_local(principal, channel_id),
         {:ok, cfg} <- Delivery.bot_config(),
         {:ok, cfg} <- Inbound.verify_bot(cfg),
         :ok <- membership(cfg, channel_id) do
      {:ok, cfg}
    else
      {:error, _, _} = error -> error
      _ -> {:error, "unavailable", "Shared-bot identity or channel membership is unavailable"}
    end
  end

  # Non-consuming receipt reads can inspect the retained destination without a
  # remote call. Callers must supply a currently verified credential principal.
  def authorize_local(principal, channel_id) do
    with :ok <- grant(principal, channel_id), do: global_channel(channel_id)
  end

  defp grant(%{scope: "coordinator_participant", agent_id: id} = principal, channel_id) do
    if Agentboard.Input.slug?(id) and id == Application.get_env(:agentboard, :coordinator_id) and
         APIAuthPolicy.valid_channel_grant?(principal.scope, Map.get(principal, :channel_ids)) and
         APIAuthPolicy.channel_id?(channel_id) and channel_id in principal.channel_ids,
       do: :ok,
       else: {:error, "forbidden", "Channel is outside the current participant grant"}
  end

  # The canonical requester also uses shared-bot verification for typed notices;
  # its identity/ownership/enrollment checks belong to that typed operation.
  defp grant(%{scope: "agent", agent_id: id}, channel_id) do
    if Agentboard.Input.slug?(id) and id != Application.get_env(:agentboard, :coordinator_id) and
         APIAuthPolicy.channel_id?(channel_id),
       do: :ok,
       else: {:error, "forbidden", "A current agent identity and valid channel are required"}
  end

  defp grant(_, _), do: {:error, "forbidden", "A participating credential is required"}

  defp global_channel(channel_id) do
    entries =
      case Application.get_env(:agentboard, :mattermost_channel_allowlist) do
        nil -> System.get_env("AGENTBOARD_MATTERMOST_CHANNEL_ALLOWLIST") || ""
        value -> value
      end

    entries =
      if is_binary(entries),
        do: entries |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")),
        else: entries

    if is_list(entries) and Enum.all?(entries, &APIAuthPolicy.channel_id?/1) and
         (entries == [] or channel_id in entries),
       do: :ok,
       else: {:error, "forbidden", "Channel is outside the current global channel policy"}
  end

  defp membership(cfg, channel_id) do
    with {:ok, channels} when is_list(channels) <- InboundHTTP.channels(cfg),
         true <- length(channels) <= 1000,
         true <- Enum.all?(channels, &(is_map(&1) and APIAuthPolicy.channel_id?(&1["id"]))) do
      if Enum.any?(channels, &(&1["id"] == channel_id and Map.get(&1, "delete_at", 0) == 0)),
        do: :ok,
        else: {:error, "forbidden", "Shared bot is not a current member of this channel"}
    else
      _ -> {:error, "unavailable", "Shared-bot channel membership is unavailable"}
    end
  end
end
