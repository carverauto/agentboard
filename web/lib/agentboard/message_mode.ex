defmodule Agentboard.MessageMode do
  @moduledoc """
  Operator-selected conversation transport. Board stays authoritative until
  cutover capabilities have real producers and acceptance evidence. Neither
  the lifecycle bot nor operator-supplied readiness flags prove peer parity.
  """
  alias Agentboard.Mattermost.{Bridge, Delivery, Inbound}
  require Logger

  # Prerequisites with no measured readiness producer yet. Replace each with
  # its owning subsystem's measured readiness when it lands; never expose a
  # configuration boolean that bypasses them. 5.1 private recipient routes and
  # 5.3 inbound catch-up are measured below.
  @missing_capabilities [
    "delivery_adapter_readiness_unverified",
    "coordinator_decision_path_unavailable_80",
    "legacy_unread_disposition_unverified_80"
  ]

  def status do
    requested = Application.get_env(:agentboard, :message_mode, "board")
    blockers = bridge_blockers() ++ route_blockers() ++ inbound_blockers() ++ @missing_capabilities

    refused =
      requested not in ["board", "dual", "mattermost"] or
        (requested == "mattermost" and blockers != [])

    %{
      requested: requested,
      effective: if(refused, do: "board", else: requested),
      activation_refused: refused,
      cutover_ready: blockers == [],
      blockers:
        if(requested in ["board", "dual", "mattermost"],
          do: blockers,
          else: ["invalid_message_mode" | blockers]
        )
    }
  end

  def dual?, do: Application.get_env(:agentboard, :message_mode, "board") == "dual"

  def report_activation do
    case status() do
      %{activation_refused: true} = status ->
        Logger.warning(
          "Message mode activation refused; board remains primary: #{Enum.join(status.blockers, ", ")}"
        )

      _ ->
        :ok
    end
  end

  # Recipient-addressed messages reach Mattermost only through the shared
  # bot's private routes; without them dual mode cannot carry DMs.
  defp route_blockers do
    if Agentboard.Mattermost.AgentRoutes.enabled?(),
      do: [],
      else: ["private_recipient_routes_disabled"]
  end

  # 5.3 inbound catch-up: disabled, or opted in but unable to subscribe
  # (missing/invalid repository scope, history cutoff or bot config), means no
  # worker inbox is being captured.
  defp inbound_blockers do
    cond do
      Inbound.enabled?() != true -> ["mattermost_inbound_disabled"]
      blocker = Inbound.configuration_blocker() -> [blocker]
      true -> []
    end
  end

  defp bridge_blockers do
    if Bridge.enabled?() do
      case Delivery.config() do
        {:ok, _} -> []
        {:error, reason} -> ["bridge_#{reason}"]
      end
    else
      ["bridge_disabled"]
    end
  end
end
